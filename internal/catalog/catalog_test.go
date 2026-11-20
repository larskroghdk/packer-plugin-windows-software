package catalog

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture() Package {
	hash := sha256.Sum256([]byte("installer"))
	return Package{ID: "example", Name: "Example", Publisher: "Vendor", Version: "1.2.3", Architecture: "x64", InstallerType: "msi", SilentArguments: "/qn /norestart", Detection: Detection{Type: "file", Path: `C:\example.exe`}, SupportedOS: []string{"server2022"}, URL: "https://example.com/install.msi", OfficialURL: "https://example.com/install.msi", Source: "vendor", SHA256: hex.EncodeToString(hash[:]), SignerSubjects: []string{"Vendor"}, SuccessCodes: []int{0, 3010}, RebootCodes: []int{3010}, ValidatedAt: time.Now().UTC().Format(time.RFC3339)}
}

func TestValidate(t *testing.T) {
	for name, mutate := range map[string]func(*Package){
		"checksum":     func(p *Package) { p.SHA256 = "bad" },
		"insecure":     func(p *Package) { p.URL = "http://example.com/a" },
		"credentials":  func(p *Package) { p.URL = "https://secret@example.com/a" },
		"signature":    func(p *Package) { p.SignerSubjects = nil },
		"empty-signer": func(p *Package) { p.SignerSubjects = []string{""} },
		"restart":      func(p *Package) { p.SuccessCodes = []int{0, 1641} },
		"detection":    func(p *Package) { p.Detection.Type = "Win32_Product" },
		"registry":     func(p *Package) { p.Detection = Detection{Type: "registry", Path: `HKLM:\SOFTWARE\Example`} },
		"unvalidated":  func(p *Package) { p.ValidatedAt = "" },
		"version":      func(p *Package) { p.Version = "latest" },
		"architecture": func(p *Package) { p.Architecture = "arm64" },
		"source":       func(p *Package) { p.Source = "mirror" },
	} {
		t.Run(name, func(t *testing.T) {
			p := fixture()
			mutate(&p)
			if p.Validate() == nil {
				t.Fatal("invalid record accepted")
			}
		})
	}
	if err := fixture().Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestResolve(t *testing.T) {
	a, b := fixture(), fixture()
	b.Version = "1.10.0"
	c := Catalog{SchemaVersion: 1, Packages: []Package{a, b}}
	for _, tt := range []struct{ request, want string }{
		{"", "1.10.0"},
		{LatestValidated, "1.10.0"},
		{"1.2.3", "1.2.3"},
		{"1.10", "1.10.0"},
		{"1.2.3.0", "1.2.3"},
	} {
		p, err := c.Resolve("example", tt.request)
		if err != nil || p.Version != tt.want {
			t.Fatalf("Resolve(%q) = %s, %v; want %s", tt.request, p.Version, err, tt.want)
		}
	}
	for _, request := range []string{"9.0", "latest", "1.x"} {
		if _, err := c.Resolve("example", request); err == nil {
			t.Fatalf("Resolve(%q) accepted", request)
		}
	}
	if _, err := c.Resolve("other", ""); err == nil {
		t.Fatal("unknown package accepted")
	}
}

func TestCompare(t *testing.T) {
	for _, tt := range []struct {
		a, b string
		want int
	}{{"1.2", "1.2.0", 0}, {"26.003.22110", "26.3.22110.0", 0}, {"1.9", "1.10", -1}, {"14.44.2", "14.43.99", 1}} {
		if got := Compare(tt.a, tt.b); got != tt.want {
			t.Fatalf("Compare(%q, %q) = %d; want %d", tt.a, tt.b, got, tt.want)
		}
	}
}

func TestDecode(t *testing.T) {
	c := Catalog{SchemaVersion: 1, Packages: []Package{fixture()}}
	data, _ := json.Marshal(c)
	if _, err := Decode(strings.NewReader(string(data))); err != nil {
		t.Fatal(err)
	}
	for name, input := range map[string]string{
		"empty":    `{"schema_version":1,"packages":[]}`,
		"trailing": string(data) + ` {}`,
		"unknown":  strings.Replace(string(data), `"schema_version":1`, `"unknown":1,"schema_version":1`, 1),
		"schema":   strings.Replace(string(data), `"schema_version":1`, `"schema_version":2`, 1),
	} {
		if _, err := Decode(strings.NewReader(input)); err == nil {
			t.Fatalf("%s input accepted", name)
		}
	}
	c.Packages = append(c.Packages, c.Packages[0])
	data, _ = json.Marshal(c)
	if _, err := Decode(strings.NewReader(string(data))); err == nil {
		t.Fatal("duplicate accepted")
	}
}

func TestDownload(t *testing.T) {
	for _, tt := range []struct {
		name, body string
		status     int
		wantError  bool
	}{{"valid", "installer", 200, false}, {"tampered", "wrong", 200, true}, {"missing", "", 404, true}} {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tt.status)
				w.Write([]byte(tt.body))
			}))
			defer server.Close()
			path := filepath.Join(t.TempDir(), "installer.msi")
			err := Download(context.Background(), server.Client(), server.URL, fixture().SHA256, path)
			if (err != nil) != tt.wantError {
				t.Fatalf("%v", err)
			}
			if _, statErr := os.Stat(path); tt.wantError != os.IsNotExist(statErr) {
				t.Fatalf("installer retained=%t after error=%v", statErr == nil, err)
			}
		})
	}
}

func TestDownloadRejectsInsecureRedirect(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://example.com/installer.msi", http.StatusFound)
	}))
	defer server.Close()
	path := filepath.Join(t.TempDir(), "installer.msi")
	if err := Download(context.Background(), server.Client(), server.URL, fixture().SHA256, path); err == nil {
		t.Fatal("redirect to HTTP accepted")
	}
}

func TestDownloadCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if Download(ctx, http.DefaultClient, fixture().URL, fixture().SHA256, filepath.Join(t.TempDir(), "file")) == nil {
		t.Fatal("cancellation ignored")
	}
}
