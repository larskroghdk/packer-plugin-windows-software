package provisioner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/hashicorp/packer-plugin-sdk/packer"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

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
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "installer") }))
			defer server.Close()
			p := New("test")
			raw := configFixture(t)
			path := filepath.Join(t.TempDir(), "report.json")
			raw["report_path"] = path
			if err := p.Prepare(raw); err != nil {
				t.Fatal(err)
			}
			hash := sha256.Sum256([]byte("installer"))
			p.packages[0].SHA256 = hex.EncodeToString(hash[:])
			p.packages[0].URL = server.URL
			p.httpClient = server.Client()
			comm := &fixtureCommunicator{responses: []string{`{"family":"server2022","architecture":"AMD64"}`, `{"version":"122.0.0.0"}`, tt.response}}
			err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, nil)
			if (err != nil) != tt.wantError {
				t.Fatalf("%v", err)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var report Report
			if err = json.Unmarshal(data, &report); err != nil {
				t.Fatal(err)
			}
			result := report.Packages[0]
			if result.Status != tt.status || result.PreviousVersion != "122.0.0.0" {
				t.Fatalf("%+v", result)
			}
			if !tt.wantError && (!result.RebootRequired || result.ExitCode == nil || *result.ExitCode != 3010) {
				t.Fatalf("reboot status lost: %+v", result)
			}
		})
	}
}
func TestFailedPackageCanContinue(t *testing.T) {
	p := New("test")
	raw := configFixture(t)
	raw["fail_on_error"] = false
	if err := p.Prepare(raw); err != nil {
		t.Fatal(err)
	}
	comm := &fixtureCommunicator{responses: []string{`{"family":"server2022","architecture":"AMD64"}`, `{"error":"Cannot parse installed version"}`}}
	if err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, nil); err != nil {
		t.Fatal(err)
	}
}
func TestUnsupportedOSBeforeInstallation(t *testing.T) {
	p := New("test")
	if err := p.Prepare(configFixture(t)); err != nil {
		t.Fatal(err)
	}
	comm := &fixtureCommunicator{responses: []string{`{"family":"server2022","architecture":"AMD64","server_core":true}`}}
	if err := p.Provision(context.Background(), &packer.BasicUi{Writer: io.Discard}, comm, nil); err == nil {
		t.Fatal("GUI package accepted on Server Core")
	}
}
