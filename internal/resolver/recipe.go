// Package resolver turns package recipes into downloaded, hash-verified
// installer candidates using Microsoft's winget-pkgs manifests as the version index.
package resolver

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"

	"github.com/larskroghdk/packer-plugin-windows-software/internal/catalog"
)

// Recipe is the reviewed acquisition and installation policy in packages/<id>.json.
type Recipe struct {
	ID                     string            `json:"id"`
	Name                   string            `json:"name"`
	Publisher              string            `json:"publisher"`
	Winget                 string            `json:"winget"`
	Architecture           string            `json:"architecture"`
	InstallerType          string            `json:"installer_type"`
	SilentArguments        string            `json:"silent_arguments"`
	Detection              catalog.Detection `json:"detection"`
	SignerSubjects         []string          `json:"signer_subjects"`
	SupportedOS            []string          `json:"supported_os"`
	ServerCore             bool              `json:"server_core"`
	SuccessCodes           []int             `json:"success_codes"`
	RebootCodes            []int             `json:"reboot_codes"`
	AllowedHosts           []string          `json:"allowed_hosts"`
	AllowedPathPrefix      string            `json:"allowed_path_prefix,omitempty"`
	RedistributionApproved bool              `json:"redistribution_approved"`
}

// Candidate returns the catalog record for a downloaded installer. ValidatedAt
// stays empty until Windows signature and embedded-version validation succeeds.
func (r Recipe) Candidate(version, installerURL, sha256Hex string) catalog.Package {
	return catalog.Package{
		ServerCore:      r.ServerCore,
		ID:              r.ID,
		Name:            r.Name,
		Publisher:       r.Publisher,
		Version:         version,
		Architecture:    r.Architecture,
		InstallerType:   r.InstallerType,
		SilentArguments: r.SilentArguments,
		Detection:       r.Detection,
		SupportedOS:     r.SupportedOS,
		URL:             installerURL,
		OfficialURL:     installerURL,
		Source:          "vendor",
		SHA256:          strings.ToLower(sha256Hex),
		SignerSubjects:  r.SignerSubjects,
		SuccessCodes:    r.SuccessCodes,
		RebootCodes:     r.RebootCodes,
	}
}

// Validate checks the recipe against the same execution contract the catalog enforces.
func (r Recipe) Validate() error {
	if r.Winget == "" || len(r.AllowedHosts) == 0 {
		return fmt.Errorf("%s: winget ID and allowed_hosts are required", r.ID)
	}
	if r.AllowedPathPrefix != "" && !strings.HasPrefix(r.AllowedPathPrefix, "/") {
		return fmt.Errorf("%s: allowed_path_prefix must start with /", r.ID)
	}
	// A placeholder release proves the policy is complete before anything is downloaded.
	probe := r.Candidate("0.0", "https://"+r.AllowedHosts[0]+"/", strings.Repeat("0", 64))
	probe.ValidatedAt = "1970-01-01T00:00:00Z"
	return probe.Validate()
}

// Approve accepts only HTTPS installer URLs on the recipe's reviewed hosts and path prefix.
func (r Recipe) Approve(rawURL string) error {
	if err := catalog.CheckHTTPSURL(rawURL); err != nil {
		return fmt.Errorf("%s: %s: %w", r.ID, rawURL, err)
	}
	u, _ := url.Parse(rawURL)
	if !slices.Contains(r.AllowedHosts, strings.ToLower(u.Hostname())) {
		return fmt.Errorf("%s: host of %s is not in allowed_hosts", r.ID, rawURL)
	}
	// Compare the decoded, dot-segment-free path so "../" or "%2e%2e/" cannot leave the prefix.
	if u.Path != path.Clean(u.Path) || !strings.HasPrefix(u.Path, r.AllowedPathPrefix) {
		return fmt.Errorf("%s: path of %s is outside %s", r.ID, rawURL, r.AllowedPathPrefix)
	}
	return nil
}

// LoadRecipes strictly decodes every packages/<id>.json recipe in dir, skipping catalog.json.
func LoadRecipes(dir string) ([]Recipe, error) {
	paths, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}
	var recipes []Recipe
	for _, path := range paths {
		if filepath.Base(path) == "catalog.json" {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.DisallowUnknownFields()
		var recipe Recipe
		if err = decoder.Decode(&recipe); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if want := strings.TrimSuffix(filepath.Base(path), ".json"); recipe.ID != want {
			return nil, fmt.Errorf("%s: id %q must match the file name", path, recipe.ID)
		}
		if err = recipe.Validate(); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		recipes = append(recipes, recipe)
	}
	if len(recipes) == 0 {
		return nil, fmt.Errorf("no recipes in %s", dir)
	}
	return recipes, nil
}
