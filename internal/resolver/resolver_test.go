package resolver

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"

	"github.com/larskroghdk/packer-plugin-windows-software/internal/catalog"
)

func testRecipe() Recipe {
	return Recipe{
		ID: "example", Name: "Example", Publisher: "Vendor", Winget: "Vendor.Example",
		Architecture: "x64", InstallerType: "msi", SilentArguments: "/qn /norestart",
		Detection:      catalog.Detection{Type: "file", Path: `%ProgramFiles%\Example\example.exe`},
		SignerSubjects: []string{"Vendor"}, SupportedOS: []string{"server2022"},
		SuccessCodes: []int{0, 3010}, RebootCodes: []int{3010},
		AllowedHosts: []string{"download.example.com"},
	}
}

func TestApprove(t *testing.T) {
	recipe := testRecipe()
	recipe.AllowedPathPrefix = "/Vendor/Example/releases/"
	if err := recipe.Approve("https://download.example.com/Vendor/Example/releases/v1/example.msi"); err != nil {
		t.Fatal(err)
	}
	for _, rawURL := range []string{
		"http://download.example.com/Vendor/Example/releases/example.msi",
		"https://download.example.com.evil.test/Vendor/Example/releases/example.msi",
		"https://secret@download.example.com/Vendor/Example/releases/example.msi",
		"https://download.example.com/Attacker/Example/releases/example.msi",
		"https://download.example.com/Vendor/Example/releases/../../../Attacker/example.msi",
		"https://download.example.com/Vendor/Example/releases/%2e%2e/%2e%2e/%2e%2e/Attacker/example.msi",
	} {
		if recipe.Approve(rawURL) == nil {
			t.Errorf("%s approved", rawURL)
		}
	}
}

func TestRecipeValidate(t *testing.T) {
	for name, mutate := range map[string]func(*Recipe){
		"winget":      func(r *Recipe) { r.Winget = "" },
		"hosts":       func(r *Recipe) { r.AllowedHosts = nil },
		"prefix":      func(r *Recipe) { r.AllowedPathPrefix = "Vendor/" },
		"signer":      func(r *Recipe) { r.SignerSubjects = nil },
		"restart":     func(r *Recipe) { r.SuccessCodes = []int{0, 1641} },
		"arch":        func(r *Recipe) { r.Architecture = "arm64" },
		"installer":   func(r *Recipe) { r.InstallerType = "msix" },
		"detection":   func(r *Recipe) { r.Detection.Type = "Win32_Product" },
		"supportedOS": func(r *Recipe) { r.SupportedOS = nil },
	} {
		recipe := testRecipe()
		mutate(&recipe)
		if recipe.Validate() == nil {
			t.Errorf("%s: invalid recipe accepted", name)
		}
	}
	if err := testRecipe().Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestCompatibleInstallers(t *testing.T) {
	const manifest = `
PackageVersion: 1.0.0
InstallerType: wix
Scope: machine
Installers:
- Architecture: x86
  InstallerUrl: https://download.example.com/x86.msi
- Architecture: x64
  Scope: user
  InstallerUrl: https://download.example.com/user.msi
- Architecture: x64
  InstallerLocale: de-DE
  InstallerUrl: https://download.example.com/de.msi
- Architecture: x64
  InstallerType: msix
  InstallerUrl: https://download.example.com/app.msix
- Architecture: x64
  InstallerUrl: https://download.example.com/machine.msi
  InstallerSha256: ABC
`
	var parsed installerManifest
	if err := yaml.Unmarshal([]byte(manifest), &parsed); err != nil {
		t.Fatal(err)
	}
	matches := compatibleInstallers(testRecipe(), parsed)
	if len(matches) != 1 || matches[0].InstallerURL != "https://download.example.com/machine.msi" || matches[0].InstallerType != "wix" {
		t.Fatalf("%+v", matches)
	}
	exe := testRecipe()
	exe.InstallerType = "exe"
	if got := compatibleInstallers(exe, parsed); len(got) != 0 {
		t.Fatalf("MSI accepted for an EXE recipe: %+v", got)
	}
}

// wingetFixture serves a winget-pkgs contents listing, trees, blobs and installers.
type wingetFixture struct {
	server       *httptest.Server
	manifests    map[string]string // version -> installer manifest YAML
	installer    []byte
	tokenLeaked  bool // Authorization sent with an installer download
	tokenMissing bool // Authorization absent from an API request
}

func newWingetFixture(t *testing.T, manifests map[string]string) *wingetFixture {
	f := &wingetFixture{manifests: manifests, installer: []byte("installer")}
	f.server = httptest.NewTLSServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

func (f *wingetFixture) serve(w http.ResponseWriter, r *http.Request) {
	base := f.server.URL
	switch {
	case r.URL.Path == "/repos/microsoft/winget-pkgs/contents/manifests/v/Vendor/Example":
		entries := []map[string]string{{"name": "latest", "type": "dir", "git_url": base + "/tree/latest"}, {"name": "README.md", "type": "file"}}
		for version := range f.manifests {
			entries = append(entries, map[string]string{"name": version, "type": "dir", "git_url": base + "/tree/" + version})
		}
		json.NewEncoder(w).Encode(entries)
	case strings.HasPrefix(r.URL.Path, "/tree/"):
		version := strings.TrimPrefix(r.URL.Path, "/tree/")
		json.NewEncoder(w).Encode(map[string]any{"tree": []map[string]string{
			{"path": "Vendor.Example.locale.en-US.yaml", "url": base + "/blob/locale"},
			{"path": "Vendor.Example.installer.yaml", "url": base + "/blob/" + version},
		}})
	case strings.HasPrefix(r.URL.Path, "/blob/"):
		content := base64.StdEncoding.EncodeToString([]byte(f.manifests[strings.TrimPrefix(r.URL.Path, "/blob/")]))
		// GitHub wraps base64 blob content at 60 characters.
		var wrapped strings.Builder
		for len(content) > 60 {
			wrapped.WriteString(content[:60] + "\n")
			content = content[60:]
		}
		wrapped.WriteString(content)
		json.NewEncoder(w).Encode(map[string]string{"content": wrapped.String(), "encoding": "base64"})
	case strings.HasPrefix(r.URL.Path, "/download/"):
		if r.Header.Get("Authorization") != "" {
			f.tokenLeaked = true
		}
		w.Write(f.installer)
	default:
		http.NotFound(w, r)
	}
	if !strings.HasPrefix(r.URL.Path, "/download/") && r.Header.Get("Authorization") != "Bearer test-token" {
		f.tokenMissing = true
	}
}

func (f *wingetFixture) manifest(t *testing.T, version, installerType string) string {
	t.Helper()
	hash := sha256.Sum256(f.installer)
	return fmt.Sprintf("Installers:\n- Architecture: x64\n  InstallerType: %s\n  InstallerUrl: %s/download/%s\n  InstallerSha256: %s\n",
		installerType, f.server.URL, version, strings.ToUpper(hex.EncodeToString(hash[:])))
}

func TestResolveSkipsIncompatibleNewerVersion(t *testing.T) {
	f := newWingetFixture(t, map[string]string{})
	f.manifests["2.0.0"] = f.manifest(t, "2.0.0", "msix")
	f.manifests["1.10.0"] = f.manifest(t, "1.10.0", "msi")
	f.manifests["1.9.0"] = f.manifest(t, "1.9.0", "msi")
	recipe := testRecipe()
	recipe.AllowedHosts = []string{"127.0.0.1"}
	r := &Resolver{HTTP: f.server.Client(), APIBase: f.server.URL, Token: "test-token"}
	dir := t.TempDir()
	candidate, err := r.Resolve(context.Background(), recipe, dir)
	if err != nil {
		t.Fatal(err)
	}
	if candidate.Version != "1.10.0" || candidate.Source != "vendor" || candidate.ValidatedAt != "" || candidate.SHA256 != strings.ToLower(candidate.SHA256) {
		t.Fatalf("%+v", candidate)
	}
	if f.tokenLeaked || f.tokenMissing {
		t.Fatal("token missing from API requests or sent with the installer download")
	}
	if _, err = os.Stat(filepath.Join(dir, "example-x64-1.10.0.msi")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "example.candidate.json"))
	if err != nil {
		t.Fatal(err)
	}
	var written map[string]any
	if err = json.Unmarshal(data, &written); err != nil {
		t.Fatal(err)
	}
	// validate-artifacts.ps1 assigns validated_at, so the property must exist.
	if value, ok := written["validated_at"]; !ok || value != "" {
		t.Fatalf("validated_at = %v, present=%t", value, ok)
	}
}

func TestResolveRejectsUnapprovedHostAndBadHash(t *testing.T) {
	f := newWingetFixture(t, map[string]string{})
	f.manifests["1.0.0"] = f.manifest(t, "1.0.0", "msi")
	r := &Resolver{HTTP: f.server.Client(), APIBase: f.server.URL, Token: "test-token"}
	if _, err := r.Resolve(context.Background(), testRecipe(), t.TempDir()); err == nil || !strings.Contains(err.Error(), "allowed_hosts") {
		t.Fatalf("unapproved host: %v", err)
	}
	recipe := testRecipe()
	recipe.AllowedHosts = []string{"127.0.0.1"}
	f.installer = []byte("tampered")
	dir := t.TempDir()
	if _, err := r.Resolve(context.Background(), recipe, dir); err == nil {
		t.Fatal("hash mismatch accepted")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("files left after a failed download: %v", entries)
	}
}

func TestResolveWithoutCompatibleInstaller(t *testing.T) {
	f := newWingetFixture(t, map[string]string{})
	f.manifests["1.0.0"] = f.manifest(t, "1.0.0", "msix")
	r := &Resolver{HTTP: f.server.Client(), APIBase: f.server.URL, Token: "test-token"}
	if _, _, err := r.FindInstaller(context.Background(), testRecipe()); err == nil {
		t.Fatal("MSIX-only package resolved")
	}
}
