package provisioner

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/hashicorp/packer-plugin-sdk/packer"
	"github.com/larskroghdk/packer-plugin-windows-software/internal/catalog"
	"io"
	"os"
	"path/filepath"
	"testing"
)

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
func TestPrepare(t *testing.T) {
	for _, option := range []map[string]any{{}, {"packages": []string{}}, {"timeout": "forever"}, {"timeout": "0s"}, {"download_retries": 9}, {"versions": map[string]string{"chrome": "999.0"}}, {"versions": map[string]string{"edge": "1.0"}}, {"packages": []string{"chrome", "chrome"}}} {
		raw := configFixture(t)
		for k, v := range option {
			raw[k] = v
		}
		p := New("test")
		err := p.Prepare(raw)
		if (err == nil) != (len(option) == 0) {
			t.Fatalf("%v: %v", option, err)
		}
	}
	p := New("test")
	if err := p.Prepare(configFixture(t)); err != nil {
		t.Fatal(err)
	}
	if !p.config.SkipInstalled || !p.config.FailOnError {
		t.Fatal("safe defaults lost")
	}
}

type fixtureCommunicator struct {
	packer.MockCommunicator
	responses     []string
	downloadError bool
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
	var report Report
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	if report.PluginVersion != "test" || len(report.Packages) != 1 || report.Packages[0].Status != "skipped" || !comm.UploadCalled {
		t.Fatalf("%+v", report)
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
		defer cancel()
		err := p.Provision(ctx, &packer.BasicUi{Writer: io.Discard}, &fixtureCommunicator{downloadError: true}, nil)
		if err == nil {
			t.Fatal("transport failure swallowed")
		}
		data, err := os.ReadFile(path)
		if err != nil || !json.Valid(data) {
			t.Fatalf("report %v", err)
		}
	}
}

var _ packer.Provisioner = (*Provisioner)(nil)
