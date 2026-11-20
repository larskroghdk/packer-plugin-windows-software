package provisioner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/hashicorp/packer-plugin-sdk/packer"
	"github.com/hashicorp/packer-plugin-sdk/uuid"

	"github.com/larskroghdk/packer-plugin-windows-software/internal/catalog"
)

// Provisioner coordinates validated host downloads and Windows guest installation.
type Provisioner struct {
	httpClient *http.Client
	config     Config
	version    string
	timeout    time.Duration
	catalog    *catalog.Catalog
	packages   []catalog.Package
}

// New returns a native Packer provisioner with its release version.
func New(version string) *Provisioner {
	return &Provisioner{version: version, httpClient: http.DefaultClient}
}

// Facts records the detected Windows platform.
type Facts struct {
	ServerCore   bool   `json:"server_core"`
	Name         string `json:"name"`
	Build        int    `json:"build"`
	Family       string `json:"family"`
	Architecture string `json:"architecture"`
	Error        string `json:"error,omitempty"`
}

// Result records one requested package, including skipped and failed installations.
type Result struct {
	ID               string  `json:"id"`
	Name             string  `json:"name"`
	RequestedVersion string  `json:"requested_version"`
	ResolvedVersion  string  `json:"resolved_version"`
	PreviousVersion  string  `json:"previous_version"`
	FinalVersion     string  `json:"final_version"`
	Status           string  `json:"status"`
	Source           string  `json:"installer_source"`
	SHA256           string  `json:"sha256"`
	DurationSeconds  float64 `json:"duration_seconds"`
	RebootRequired   bool    `json:"reboot_required"`
	ExitCode         *int    `json:"exit_code,omitempty"`
	Error            string  `json:"error,omitempty"`
}

// Report is persisted on the Packer host even when a guest operation fails.
type Report struct {
	PluginVersion   string    `json:"plugin_version"`
	StartedAt       time.Time `json:"started_at"`
	DurationSeconds float64   `json:"duration_seconds"`
	OS              Facts     `json:"operating_system"`
	Packages        []Result  `json:"packages"`
	Error           string    `json:"error,omitempty"`
}

var (
	errTransport = errors.New("guest transport failed")
	// errGuestUnusable marks guest results after which the VM state is unknown,
	// such as a still-running installer or an installer-initiated restart.
	errGuestUnusable = errors.New("guest state is unknown; discard this VM")
)

// observation is the guest's Inspect or Install result.
type observation struct {
	Version        string `json:"version"`
	Error          string `json:"error"`
	Fatal          bool   `json:"fatal"`
	RebootRequired bool   `json:"reboot_required"`
	ExitCode       *int   `json:"exit_code"`
}

// abortsBuild reports whether err must stop provisioning even when fail_on_error is false.
func abortsBuild(err error) bool {
	return errors.Is(err, errTransport) || errors.Is(err, errGuestUnusable) ||
		errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled)
}

// Provision installs in configured order and never initiates a reboot.
func (p *Provisioner) Provision(ctx context.Context, ui packer.Ui, comm packer.Communicator, data map[string]any) (runErr error) {
	if conn, _ := data["ConnType"].(string); conn != "" && conn != "winrm" {
		return fmt.Errorf("windows-software requires WinRM, not %s", conn)
	}
	report := Report{PluginVersion: p.version, StartedAt: time.Now().UTC(), Packages: []Result{}}
	r := &remote{comm: comm, ui: ui, dir: `C:\Windows\Temp\packer-windows-software-` + uuid.TimeOrderedUUID()}
	defer func() {
		// The build context may already be cancelled; cleanup gets its own deadline.
		cleanCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := r.cleanup(cleanCtx); err != nil {
			ui.Error("Guest temporary file cleanup failed: " + err.Error())
			runErr = errors.Join(runErr, err)
		}
		report.DurationSeconds = time.Since(report.StartedAt).Seconds()
		if runErr != nil {
			report.Error = runErr.Error()
		}
		if p.config.ReportPath != "" {
			runErr = errors.Join(runErr, writeReport(p.config.ReportPath, report))
		}
	}()
	if err := r.setup(ctx); err != nil {
		return fmt.Errorf("%w: %w", errTransport, err)
	}
	if err := r.action(ctx, "Facts", nil, &report.OS); err != nil {
		return fmt.Errorf("%w: %w", errTransport, err)
	}
	if report.OS.Error != "" {
		return fmt.Errorf("detect Windows platform: %s", report.OS.Error)
	}
	if report.OS.Architecture != "AMD64" || report.OS.Family == "" {
		return fmt.Errorf("unsupported Windows build %d (%s) on %s", report.OS.Build, report.OS.Name, report.OS.Architecture)
	}
	// Check all OS requirements before installing any package.
	for _, pkg := range p.packages {
		if report.OS.ServerCore && !pkg.ServerCore {
			return fmt.Errorf("%s requires Desktop Experience", pkg.ID)
		}
		if !slices.Contains(pkg.SupportedOS, report.OS.Family) {
			return fmt.Errorf("%s does not support %s", pkg.ID, report.OS.Family)
		}
	}
	var failures []error
	for _, pkg := range p.packages {
		if err := ctx.Err(); err != nil {
			return err
		}
		ui.Say(fmt.Sprintf("Windows software: %s %s", pkg.Name, pkg.Version))
		result, err := p.installPackage(ctx, r, pkg)
		report.Packages = append(report.Packages, result)
		if err != nil {
			err = fmt.Errorf("%s: %w", pkg.ID, err)
			ui.Error(err.Error())
			failures = append(failures, err)
			if p.config.FailOnError || abortsBuild(err) || ctx.Err() != nil {
				return errors.Join(failures...)
			}
		}
	}
	return ctx.Err()
}

func (p *Provisioner) installPackage(ctx context.Context, r *remote, pkg catalog.Package) (result Result, err error) {
	started := time.Now()
	requested := p.config.Versions[pkg.ID]
	if requested == "" {
		requested = catalog.LatestValidated
	}
	result = Result{ID: pkg.ID, Name: pkg.Name, RequestedVersion: requested, ResolvedVersion: pkg.Version, Source: pkg.URL, SHA256: pkg.SHA256, Status: "failed"}
	defer func() {
		result.DurationSeconds = time.Since(started).Seconds()
		if err != nil {
			result.Error = err.Error()
		}
	}()
	ctx, cancel := context.WithTimeout(ctx, p.timeout)
	defer cancel()

	input := map[string]any{"package": pkg}
	var observed observation
	if err = r.action(ctx, "Inspect", input, &observed); err != nil {
		return result, fmt.Errorf("%w: %w", errTransport, err)
	}
	if observed.Error != "" {
		return result, errors.New(observed.Error)
	}
	result.PreviousVersion = observed.Version
	result.FinalVersion = observed.Version
	if observed.Version != "" {
		comparison := catalog.Compare(observed.Version, pkg.Version)
		pinned := requested != catalog.LatestValidated
		if comparison > 0 && pinned {
			return result, fmt.Errorf("installed %s is newer than pin %s; downgrades are forbidden", observed.Version, pkg.Version)
		}
		if comparison > 0 || (comparison == 0 && p.config.SkipInstalled) {
			result.Status = "skipped"
			return result, nil
		}
	}

	guestPath, err := p.transferInstaller(ctx, r, pkg)
	if err != nil {
		return result, err
	}
	// The guest waits only for the time left on this package's deadline.
	deadline, _ := ctx.Deadline()
	remaining := int(time.Until(deadline).Seconds())
	if remaining < 1 {
		return result, context.DeadlineExceeded
	}
	input["installer_path"] = guestPath
	input["timeout_seconds"] = remaining
	observed = observation{}
	if err = r.action(ctx, "Install", input, &observed); err != nil {
		return result, fmt.Errorf("%w: %w", errTransport, err)
	}
	result.ExitCode = observed.ExitCode
	result.RebootRequired = observed.RebootRequired
	result.FinalVersion = observed.Version
	if observed.Fatal {
		return result, fmt.Errorf("%w: %s", errGuestUnusable, observed.Error)
	}
	if observed.Error != "" {
		return result, errors.New(observed.Error)
	}
	if observed.Version == "" || catalog.Compare(observed.Version, pkg.Version) != 0 {
		return result, fmt.Errorf("installed version %q does not match %s", observed.Version, pkg.Version)
	}
	result.Status = "installed"
	return result, nil
}

// transferInstaller downloads and verifies the installer on the host, uploads it
// to the guest working directory and returns its guest path.
func (p *Provisioner) transferInstaller(ctx context.Context, r *remote, pkg catalog.Package) (string, error) {
	dir, err := os.MkdirTemp("", "packer-windows-software-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	local := filepath.Join(dir, "installer."+pkg.InstallerType)
	for attempt := 0; ; attempt++ {
		err = catalog.Download(ctx, p.httpClient, pkg.URL, pkg.SHA256, local)
		if err == nil {
			break
		}
		if attempt == p.config.DownloadRetries {
			return "", fmt.Errorf("download %s: %w", pkg.URL, err)
		}
		timer := time.NewTimer(time.Duration(attempt+1) * time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return "", ctx.Err()
		case <-timer.C:
		}
	}
	file, err := os.Open(local)
	if err != nil {
		return "", err
	}
	defer file.Close()
	guestPath := r.path(pkg.ID + "." + pkg.InstallerType)
	if err = r.comm.Upload(guestPath, file, nil); err != nil {
		return "", fmt.Errorf("%w: upload installer: %w", errTransport, err)
	}
	return guestPath, ctx.Err()
}

// writeReport atomically replaces path with the JSON report.
func writeReport(path string, report Report) error {
	data, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err = os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".software-report-*.json")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name) // no-op after a successful rename
	if _, err = f.Write(append(data, '\n')); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
