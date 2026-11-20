package resolver

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"go.yaml.in/yaml/v3"

	"github.com/larskroghdk/packer-plugin-windows-software/internal/catalog"
)

// GitHubAPI is the default winget-pkgs index endpoint.
const GitHubAPI = "https://api.github.com"

// Resolver reads winget-pkgs manifests through the GitHub REST API and downloads vendor installers.
type Resolver struct {
	HTTP    *http.Client
	APIBase string
	// Token is sent only to APIBase to raise GitHub's rate limit. net/http drops
	// it on redirects to other hosts, so vendor downloads never receive it.
	Token string
	// Log receives progress lines; nil discards them.
	Log io.Writer
}

// Installer is one winget installer entry with manifest-level defaults applied.
type Installer struct {
	Architecture    string `yaml:"Architecture"`
	InstallerType   string `yaml:"InstallerType"`
	Scope           string `yaml:"Scope"`
	InstallerLocale string `yaml:"InstallerLocale"`
	InstallerURL    string `yaml:"InstallerUrl"`
	InstallerSHA256 string `yaml:"InstallerSha256"`
}

type installerManifest struct {
	Installer  `yaml:",inline"`
	Installers []Installer `yaml:"Installers"`
}

// compatibleTypes maps a recipe installer type to the winget types the guest engine can run.
var compatibleTypes = map[string][]string{
	"msi": {"msi", "wix"},
	"exe": {"exe", "burn", "inno", "nullsoft"},
}

// compatibleInstallers returns x64, machine-scope, en-US installers the recipe's engine path supports.
func compatibleInstallers(recipe Recipe, manifest installerManifest) []Installer {
	var matches []Installer
	for _, installer := range manifest.Installers {
		if installer.Architecture == "" {
			installer.Architecture = manifest.Architecture
		}
		if installer.InstallerType == "" {
			installer.InstallerType = manifest.InstallerType
		}
		if installer.Scope == "" {
			installer.Scope = manifest.Scope
		}
		if installer.InstallerLocale == "" {
			installer.InstallerLocale = manifest.InstallerLocale
		}
		scopeOK := installer.Scope == "" || installer.Scope == "machine"
		localeOK := installer.InstallerLocale == "" || strings.EqualFold(installer.InstallerLocale, "en-US")
		if installer.Architecture == "x64" && slices.Contains(compatibleTypes[recipe.InstallerType], installer.InstallerType) && scopeOK && localeOK {
			matches = append(matches, installer)
		}
	}
	return matches
}

type contentEntry struct {
	Name   string `json:"name"`
	Type   string `json:"type"`
	GitURL string `json:"git_url"`
}

type treeEntry struct {
	Path string `json:"path"`
	URL  string `json:"url"`
}

// FindInstaller selects the newest stable version that has a compatible installer.
// Versions without one (for example MSIX-only releases) are skipped.
func (r *Resolver) FindInstaller(ctx context.Context, recipe Recipe) (string, Installer, error) {
	segments := strings.Split(recipe.Winget, ".")
	for i, segment := range segments {
		segments[i] = url.PathEscape(segment)
	}
	root := r.APIBase + "/repos/microsoft/winget-pkgs/contents/manifests/" + strings.ToLower(recipe.Winget[:1]) + "/" + strings.Join(segments, "/")
	var entries []contentEntry
	if err := r.getJSON(ctx, root, &entries); err != nil {
		return "", Installer{}, err
	}
	var versions []contentEntry
	for _, entry := range entries {
		if entry.Type == "dir" && catalog.IsVersion(entry.Name) {
			versions = append(versions, entry)
		}
	}
	slices.SortFunc(versions, func(a, b contentEntry) int { return catalog.Compare(b.Name, a.Name) })
	for _, version := range versions {
		// Tree and blob objects are immutable, unlike a branch that may move during validation.
		var tree struct {
			Tree []treeEntry `json:"tree"`
		}
		if err := r.getJSON(ctx, version.GitURL, &tree); err != nil {
			return "", Installer{}, err
		}
		index := slices.IndexFunc(tree.Tree, func(e treeEntry) bool { return strings.HasSuffix(e.Path, ".installer.yaml") })
		if index < 0 {
			continue
		}
		var blob struct {
			Content  string `json:"content"`
			Encoding string `json:"encoding"`
		}
		if err := r.getJSON(ctx, tree.Tree[index].URL, &blob); err != nil {
			return "", Installer{}, err
		}
		if blob.Encoding != "base64" {
			return "", Installer{}, fmt.Errorf("%s %s: unexpected blob encoding %q", recipe.Winget, version.Name, blob.Encoding)
		}
		data, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(blob.Content, "\n", ""))
		if err != nil {
			return "", Installer{}, fmt.Errorf("%s %s: %w", recipe.Winget, version.Name, err)
		}
		var manifest installerManifest
		if err = yaml.Unmarshal(data, &manifest); err != nil {
			return "", Installer{}, fmt.Errorf("%s %s installer manifest: %w", recipe.Winget, version.Name, err)
		}
		if matches := compatibleInstallers(recipe, manifest); len(matches) > 0 {
			return version.Name, matches[0], nil
		}
		r.logf("%s %s: no compatible %s installer; checking the previous stable version", recipe.Winget, version.Name, recipe.InstallerType)
	}
	return "", Installer{}, fmt.Errorf("no compatible x64 machine installer for %s", recipe.Winget)
}

// Resolve downloads the newest compatible installer into dir as
// <id>-x64-<version>.<type> and writes <id>.candidate.json beside it.
func (r *Resolver) Resolve(ctx context.Context, recipe Recipe, dir string) (catalog.Package, error) {
	version, installer, err := r.FindInstaller(ctx, recipe)
	if err != nil {
		return catalog.Package{}, err
	}
	if err = recipe.Approve(installer.InstallerURL); err != nil {
		return catalog.Package{}, err
	}
	candidate := recipe.Candidate(version, installer.InstallerURL, installer.InstallerSHA256)
	r.logf("%s %s: downloading %s", recipe.ID, version, installer.InstallerURL)
	path := filepath.Join(dir, fmt.Sprintf("%s-x64-%s.%s", recipe.ID, version, recipe.InstallerType))
	if err = catalog.Download(ctx, r.HTTP, candidate.URL, candidate.SHA256, path); err != nil {
		return catalog.Package{}, fmt.Errorf("%s %s: %w", recipe.ID, version, err)
	}
	data, err := json.MarshalIndent(candidate, "", "  ")
	if err != nil {
		return catalog.Package{}, err
	}
	if err = os.WriteFile(filepath.Join(dir, recipe.ID+".candidate.json"), append(data, '\n'), 0644); err != nil {
		return catalog.Package{}, err
	}
	return candidate, nil
}

func (r *Resolver) getJSON(ctx context.Context, rawURL string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "packer-plugin-windows-software-resolver")
	if r.Token != "" && sameOrigin(rawURL, r.APIBase) {
		req.Header.Set("Authorization", "Bearer "+r.Token)
	}
	resp, err := r.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: HTTP %d", rawURL, resp.StatusCode)
	}
	if err = json.NewDecoder(io.LimitReader(resp.Body, 32<<20)).Decode(out); err != nil {
		return fmt.Errorf("GET %s: %w", rawURL, err)
	}
	return nil
}

func sameOrigin(a, b string) bool {
	ua, errA := url.Parse(a)
	ub, errB := url.Parse(b)
	return errA == nil && errB == nil && ua.Scheme == ub.Scheme && strings.EqualFold(ua.Host, ub.Host)
}

func (r *Resolver) logf(format string, args ...any) {
	if r.Log != nil {
		fmt.Fprintf(r.Log, format+"\n", args...)
	}
}
