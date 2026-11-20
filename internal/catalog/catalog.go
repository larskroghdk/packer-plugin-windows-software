// Package catalog validates immutable software release records.
package catalog

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

var identifier = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
var versionPattern = regexp.MustCompile(`^[0-9]+(\.[0-9]+){1,3}$`)

// Detection describes registry or file-version based detection on the guest.
type Detection struct {
	Type  string `json:"type"`
	Path  string `json:"path"`
	Name  string `json:"name"`
	Value string `json:"value"`
}

// Package is a validated, immutable installer record, including its execution policy.
type Package struct {
	ServerCore      bool      `json:"server_core"`
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	Publisher       string    `json:"publisher"`
	Version         string    `json:"version"`
	Architecture    string    `json:"architecture"`
	InstallerType   string    `json:"installer_type"`
	SilentArguments string    `json:"silent_arguments"`
	Detection       Detection `json:"detection"`
	SupportedOS     []string  `json:"supported_os"`
	URL             string    `json:"url"`
	OfficialURL     string    `json:"official_url"`
	Source          string    `json:"source"`
	SHA256          string    `json:"sha256"`
	SignerSubjects  []string  `json:"signer_subjects"`
	SuccessCodes    []int     `json:"success_codes"`
	RebootCodes     []int     `json:"reboot_codes"`
	ValidatedAt     string    `json:"validated_at"`
}

// Catalog retains every validated version; selection never uses a moving installer URL without a hash.
type Catalog struct {
	SchemaVersion int       `json:"schema_version"`
	Packages      []Package `json:"packages"`
}

// HTTPS rejects credential-bearing and non-HTTPS installer locations.
func HTTPS(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
		return fmt.Errorf("expected an HTTPS URL without credentials or fragment")
	}
	return nil
}

// Validate checks the complete execution contract before any guest mutation.
func (p Package) Validate() error {
	if !identifier.MatchString(p.ID) || p.Name == "" || p.Publisher == "" || !versionPattern.MatchString(p.Version) {
		return fmt.Errorf("invalid identity or numeric version for %q", p.ID)
	}
	if p.Architecture != "x64" {
		return fmt.Errorf("%s: only x64 installers are supported", p.ID)
	}
	if p.InstallerType != "msi" && p.InstallerType != "exe" {
		return fmt.Errorf("%s: unsupported installer type", p.ID)
	}
	if p.SilentArguments == "" || len(p.SupportedOS) == 0 || len(p.SignerSubjects) == 0 || p.ValidatedAt == "" || len(p.SuccessCodes) == 0 {
		return fmt.Errorf("%s: missing validation or execution policy", p.ID)
	}
	if p.Source != "vendor" && p.Source != "github-release" {
		return fmt.Errorf("%s: unsupported source", p.ID)
	}
	if err := HTTPS(p.URL); err != nil {
		return fmt.Errorf("%s URL: %w", p.ID, err)
	}
	if err := HTTPS(p.OfficialURL); err != nil {
		return fmt.Errorf("%s official URL: %w", p.ID, err)
	}
	if _, err := time.Parse(time.RFC3339, p.ValidatedAt); err != nil {
		return fmt.Errorf("%s: invalid validation timestamp", p.ID)
	}
	hash, err := hex.DecodeString(p.SHA256)
	if err != nil || len(hash) != 32 {
		return fmt.Errorf("%s: invalid SHA-256", p.ID)
	}
	if p.Detection.Path == "" || (p.Detection.Type != "registry" && p.Detection.Type != "file") || (p.Detection.Type == "registry" && p.Detection.Value == "") {
		return fmt.Errorf("%s: invalid detection", p.ID)
	}
	for _, s := range p.SignerSubjects {
		if s == "" {
			return fmt.Errorf("%s: empty signer", p.ID)
		}
	}
	if slices.Contains(p.SuccessCodes, 1641) {
		return fmt.Errorf("%s: restart-initiated exit code 1641 is forbidden", p.ID)
	}
	return nil
}

// Load reads a strict JSON catalog and rejects ambiguous duplicate records.
func Load(path string) (*Catalog, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Decode(f)
}

// Decode validates catalog data from a bounded input stream.
func Decode(r io.Reader) (*Catalog, error) {
	d := json.NewDecoder(io.LimitReader(r, 16<<20))
	d.DisallowUnknownFields()
	var c Catalog
	if err := d.Decode(&c); err != nil {
		return nil, err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return nil, fmt.Errorf("trailing catalog data")
	}
	if c.SchemaVersion != 1 || len(c.Packages) == 0 {
		return nil, fmt.Errorf("expected schema_version 1 and validated package records; run the publication workflow first")
	}
	seen := map[string]bool{}
	for _, p := range c.Packages {
		if err := p.Validate(); err != nil {
			return nil, err
		}
		key := p.ID + "/" + p.Version + "/" + p.Architecture
		if seen[key] {
			return nil, fmt.Errorf("duplicate record %s", key)
		}
		seen[key] = true
	}
	return &c, nil
}

// Compare compares numeric vendor versions, treating missing trailing components as zero.
func Compare(a, b string) int {
	aa, bb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < max(len(aa), len(bb)); i++ {
		var x, y uint64
		if i < len(aa) {
			x, _ = strconv.ParseUint(aa[i], 10, 64)
		}
		if i < len(bb) {
			y, _ = strconv.ParseUint(bb[i], 10, 64)
		}
		if x < y {
			return -1
		}
		if x > y {
			return 1
		}
	}
	return 0
}

// Resolve selects a pinned version or the highest validated numeric version.
func (c *Catalog) Resolve(id, version string) (Package, error) {
	var selected Package
	for _, p := range c.Packages {
		if p.ID == id && (version == "" || version == "latest-validated" || p.Version == version) && (selected.ID == "" || Compare(p.Version, selected.Version) > 0) {
			selected = p
		}
	}
	if selected.ID == "" {
		return Package{}, fmt.Errorf("no validated version %q for %s", version, id)
	}
	return selected, nil
}

// Download streams a bounded installer to disk and verifies its digest before upload.
func Download(ctx context.Context, client *http.Client, p Package, path string) error {
	if err := p.Validate(); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.URL, nil)
	if err != nil {
		return err
	}
	clone := *client
	clone.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return fmt.Errorf("too many redirects")
		}
		return HTTPS(req.URL.String())
	}
	resp, err := clone.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("installer download returned HTTP %d", resp.StatusCode)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	valid := false
	defer func() {
		f.Close()
		if !valid {
			os.Remove(path)
		}
	}()
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, (2<<30)+1))
	if err != nil {
		return err
	}
	if n > 2<<30 {
		return fmt.Errorf("installer exceeds 2 GiB")
	}
	if !strings.EqualFold(hex.EncodeToString(h.Sum(nil)), p.SHA256) {
		return fmt.Errorf("%s: SHA-256 mismatch", p.ID)
	}
	if err = f.Close(); err != nil {
		return err
	}
	valid = true
	return nil
}
