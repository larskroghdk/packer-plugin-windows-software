package provisioner

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hashicorp/packer-plugin-sdk/packer"

	"github.com/larskroghdk/packer-plugin-windows-software/internal/catalog"
)

var _ packer.Provisioner = (*Provisioner)(nil)

func testPackage() catalog.Package {
	return catalog.Package{ID: "chrome", Name: "Chrome", Publisher: "Google LLC", Version: "123.0.0.0", Architecture: "x64", InstallerType: "msi", SilentArguments: "/qn /norestart", Detection: catalog.Detection{Type: "file", Path: `C:\chrome.exe`}, SupportedOS: []string{"server2022"}, URL: "https://example.com/a.msi", OfficialURL: "https://example.com/a.msi", Source: "vendor", SHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", SignerSubjects: []string{"Google LLC"}, SuccessCodes: []int{0, 3010}, RebootCodes: []int{3010}, ValidatedAt: "2026-01-01T00:00:00Z"}
}

func configFixture(t *testing.T) map[string]any {
	t.Helper()
	path := filepath.Join(t.TempDir(), "catalog.json")
	data, _ := json.Marshal(catalog.Catalog{SchemaVersion: 1, Packages: []catalog.Package{testPackage()}})
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	return map[string]any{"packages": []string{"chrome"}, "catalog_path": path}
}

func readReport(t *testing.T, path string) Report {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var report Report
	if err = json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	return report
}

// fixtureCommunicator returns queued guest results and records uploaded JSON requests.
type fixtureCommunicator struct {
	packer.MockCommunicator
	responses     []string
	requests      []map[string]any
	downloadError bool
}

func (c *fixtureCommunicator) Upload(path string, r io.Reader, fi *os.FileInfo) error {
	if strings.HasSuffix(path, "-in.json") {
		var request map[string]any
		if err := json.NewDecoder(r).Decode(&request); err != nil {
			return err
		}
		c.requests = append(c.requests, request)
		return nil
	}
	return c.MockCommunicator.Upload(path, r, fi)
}

func (c *fixtureCommunicator) Download(_ string, w io.Writer) error {
	if c.downloadError {
		return io.ErrUnexpectedEOF
	}
	if len(c.responses) == 0 {
		return errors.New("unexpected download")
	}
	response := c.responses[0]
	c.responses = c.responses[1:]
	_, err := io.WriteString(w, response)
	return err
}

func TestPrepare(t *testing.T) {
	for name, option := range map[string]map[string]any{
		"no packages":       {"packages": []string{}},
		"bad timeout":       {"timeout": "forever"},
		"zero timeout":      {"timeout": "0s"},
		"too long timeout":  {"timeout": "25h"},
		"too many retries":  {"download_retries": 9},
		"negative retries":  {"download_retries": -1},
		"unknown pin":       {"versions": map[string]string{"chrome": "999.0"}},
		"non-numeric pin":   {"versions": map[string]string{"chrome": "latest"}},
		"unselected pin":    {"versions": map[string]string{"edge": "1.0"}},
		"duplicate package": {"packages": []string{"chrome", "chrome"}},
		"unknown package":   {"packages": []string{"firefox"}},
		"missing catalog":   {"catalog_path": filepath.Join(t.TempDir(), "absent.json")},
		"directory report":  {"report_path": t.TempDir()},
		"misspelled option": {"package": []string{"chrome"}},
	} {
		t.Run(name, func(t *testing.T) {
			raw := configFixture(t)
			for k, v := range option {
				raw[k] = v
			}
			if err := New("test").Prepare(raw); err == nil {
				t.Fatalf("%v accepted", option)
			}
		})
	}
	p := New("test")
	raw := configFixture(t)
	raw["versions"] = map[string]string{"chrome": "123.0"}
	if err := p.Prepare(raw); err != nil {
		t.Fatal(err)
	}
	if !p.config.SkipInstalled || !p.config.FailOnError {
		t.Fatal("safe defaults lost")
	}
	if p.packages[0].Version != "123.0.0.0" {
		t.Fatalf("pin resolved to %s", p.packages[0].Version)
	}
}

func TestProvisionSkipAndReport(t *testing.T) {
	p := New("test")
	raw := configFixture(t)
	path := filepath.Join(t.TempDir(), "report.json")
	raw["report_path"] = path
	if err := p.Prepare(raw); err != nil {
		t.Fatal(err)
	}
	comm := &fixtureCommunicator{responses: []string{`{"family":"server2022","architecture":"AMD64","build":20348,"name":"Windows Server 2022"}`, `{"version":"123.0.0.0"}`}}
	if err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, nil); err != nil {
		t.Fatal(err)
	}
	report := readReport(t, path)
	if report.PluginVersion != "test" || report.OS.Build != 20348 || len(report.Packages) != 1 || report.Packages[0].Status != "skipped" || !comm.UploadCalled {
		t.Fatalf("%+v", report)
	}
}

func TestProvisionRejectsSSH(t *testing.T) {
	p := New("test")
	if err := p.Prepare(configFixture(t)); err != nil {
		t.Fatal(err)
	}
	comm := &fixtureCommunicator{}
	if err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, map[string]any{"ConnType": "ssh"}); err == nil || comm.StartCalled {
		t.Fatal("non-WinRM communicator used")
	}
}

func TestUnsupportedPlatformBeforeInstallation(t *testing.T) {
	for name, facts := range map[string]string{
		"server core":  `{"family":"server2022","architecture":"AMD64","server_core":true}`,
		"unknown os":   `{"family":"","architecture":"AMD64","build":14393}`,
		"arm64":        `{"family":"windows11","architecture":"ARM64"}`,
		"unlisted os":  `{"family":"windows11","architecture":"AMD64"}`,
		"facts failed": `{"error":"CIM unavailable"}`,
	} {
		t.Run(name, func(t *testing.T) {
			p := New("test")
			if err := p.Prepare(configFixture(t)); err != nil {
				t.Fatal(err)
			}
			comm := &fixtureCommunicator{responses: []string{facts}}
			if err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, nil); err == nil {
				t.Fatal("unsupported platform accepted")
			}
			if len(comm.requests) != 0 {
				t.Fatal("package inspected before platform checks")
			}
		})
	}
}

func TestPinnedDowngradeRejected(t *testing.T) {
	p := New("test")
	raw := configFixture(t)
	raw["versions"] = map[string]string{"chrome": "123.0.0.0"}
	if err := p.Prepare(raw); err != nil {
		t.Fatal(err)
	}
	comm := &fixtureCommunicator{responses: []string{`{"version":"124.0.0.0"}`}}
	r := &remote{comm: comm, ui: &packer.BasicUi{Writer: io.Discard}, dir: `C:\Windows\Temp\fixture`}
	result, err := p.installPackage(context.Background(), r, testPackage())
	if err == nil || result.Status != "failed" {
		t.Fatalf("%+v %v", result, err)
	}
}

func TestTransportFailureAndCancellationReport(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		p := New("test")
		raw := configFixture(t)
		path := filepath.Join(t.TempDir(), "report.json")
		raw["report_path"] = path
		raw["fail_on_error"] = false
		if err := p.Prepare(raw); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		if cancelled {
			cancel()
		}
		err := p.Provision(ctx, &packer.BasicUi{Writer: io.Discard}, &fixtureCommunicator{downloadError: true}, nil)
		cancel()
		if err == nil {
			t.Fatal("transport failure swallowed")
		}
		if report := readReport(t, path); report.Error == "" {
			t.Fatal("report omits the build error")
		}
	}
}
