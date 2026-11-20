package provisioner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hashicorp/packer-plugin-sdk/packer"
)

const platformFacts = `{"family":"server2022","architecture":"AMD64"}`

// installFixture prepares a provisioner whose single package downloads from a local TLS server.
func installFixture(t *testing.T, options map[string]any) (*Provisioner, string) {
	t.Helper()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "installer") }))
	t.Cleanup(server.Close)
	p := New("test")
	raw := configFixture(t)
	report := filepath.Join(t.TempDir(), "report.json")
	raw["report_path"] = report
	for k, v := range options {
		raw[k] = v
	}
	if err := p.Prepare(raw); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256([]byte("installer"))
	p.packages[0].SHA256 = hex.EncodeToString(hash[:])
	p.packages[0].URL = server.URL
	p.httpClient = server.Client()
	return p, report
}

func TestUpgradeFailureAndRebootReports(t *testing.T) {
	for _, tt := range []struct {
		name, response, status string
		wantError              bool
	}{
		{"upgrade", `{"version":"123.0.0.0","reboot_required":true,"exit_code":3010}`, "installed", false},
		{"installer-failure", `{"version":"122.0.0.0","error":"Installer exited with code 1603","exit_code":1603}`, "failed", true},
		{"verification-failure", `{"version":"122.0.0.0","exit_code":0}`, "failed", true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			p, path := installFixture(t, nil)
			comm := &fixtureCommunicator{responses: []string{platformFacts, `{"version":"122.0.0.0"}`, tt.response}}
			err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, nil)
			if (err != nil) != tt.wantError {
				t.Fatalf("%v", err)
			}
			result := readReport(t, path).Packages[0]
			if result.Status != tt.status || result.PreviousVersion != "122.0.0.0" {
				t.Fatalf("%+v", result)
			}
			if !tt.wantError && (!result.RebootRequired || result.ExitCode == nil || *result.ExitCode != 3010) {
				t.Fatalf("reboot status lost: %+v", result)
			}
		})
	}
}

func TestInstallRequestCarriesRemainingTimeout(t *testing.T) {
	p, _ := installFixture(t, map[string]any{"timeout": "10m"})
	comm := &fixtureCommunicator{responses: []string{platformFacts, `{"version":""}`, `{"version":"123.0.0.0","exit_code":0}`}}
	if err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, nil); err != nil {
		t.Fatal(err)
	}
	if len(comm.requests) != 2 {
		t.Fatalf("requests: %+v", comm.requests)
	}
	install := comm.requests[1]
	if seconds, _ := install["timeout_seconds"].(float64); seconds < 1 || seconds > 600 {
		t.Fatalf("timeout_seconds = %v; want 1..600", install["timeout_seconds"])
	}
	if path, _ := install["installer_path"].(string); !strings.HasPrefix(path, `C:\Windows\Temp\packer-windows-software-`) || !strings.HasSuffix(path, `\chrome.msi`) {
		t.Fatalf("installer_path = %q", path)
	}
}

func TestFailedPackageCanContinue(t *testing.T) {
	p := New("test")
	raw := configFixture(t)
	raw["fail_on_error"] = false
	if err := p.Prepare(raw); err != nil {
		t.Fatal(err)
	}
	comm := &fixtureCommunicator{responses: []string{platformFacts, `{"error":"Cannot parse installed version"}`}}
	if err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, nil); err != nil {
		t.Fatal(err)
	}
}

func TestUnusableGuestAbortsDespiteContinueOnError(t *testing.T) {
	for name, response := range map[string]string{
		"timeout": `{"version":"","fatal":true,"error":"Installer timeout after 60 seconds; installation may still be running; discard this VM"}`,
		"restart": `{"version":"","fatal":true,"exit_code":1641,"error":"Installer initiated a reboot despite suppression; build cannot be trusted"}`,
	} {
		t.Run(name, func(t *testing.T) {
			p, path := installFixture(t, map[string]any{"fail_on_error": false})
			comm := &fixtureCommunicator{responses: []string{platformFacts, `{"version":""}`, response}}
			err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, nil)
			if !errors.Is(err, errGuestUnusable) {
				t.Fatalf("error = %v; want errGuestUnusable", err)
			}
			if result := readReport(t, path).Packages[0]; result.Status != "failed" || result.Error == "" {
				t.Fatalf("%+v", result)
			}
		})
	}
}
