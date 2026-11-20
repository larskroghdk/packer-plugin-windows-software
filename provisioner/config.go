// Package provisioner implements the native windows-software Packer provisioner.
package provisioner

import (
	"fmt"
	"github.com/hashicorp/hcl/v2/hcldec"
	"github.com/hashicorp/packer-plugin-sdk/common"
	"github.com/hashicorp/packer-plugin-sdk/template/config"
	"github.com/hashicorp/packer-plugin-sdk/template/interpolate"
	"github.com/larskroghdk/packer-plugin-windows-software/internal/catalog"
	"os"
	"time"
)

// Config defines host-side HCL options. Packages are installed in list order.
type Config struct {
	common.PackerConfig `mapstructure:",squash"`
	Packages            []string          `mapstructure:"packages"`
	Versions            map[string]string `mapstructure:"versions"`
	CatalogPath         string            `mapstructure:"catalog_path"`
	SkipInstalled       bool              `mapstructure:"skip_installed"`
	FailOnError         bool              `mapstructure:"fail_on_error"`
	ReportPath          string            `mapstructure:"report_path"`
	Timeout             string            `mapstructure:"timeout"`
	DownloadRetries     int               `mapstructure:"download_retries"`
}

// ConfigSpec exposes actual SDK configuration types to the HCL2 decoder.
func (p *Provisioner) ConfigSpec() hcldec.ObjectSpec {
	return p.config.FlatMapstructure().HCL2Spec()
}

// Prepare validates and resolves all records before opening a WinRM session.
func (p *Provisioner) Prepare(raws ...any) error {
	p.config = Config{}
	// The SDK resets the target while decoding HCL2 cty values. Decode defaults
	// as the first input so omitted HCL attributes retain the same defaults as JSON.
	defaults := map[string]any{"skip_installed": true, "fail_on_error": true, "timeout": "30m", "download_retries": 2, "catalog_path": "packages/catalog.json"}
	raws = append([]any{defaults}, raws...)
	if err := config.Decode(&p.config, &config.DecodeOpts{PluginType: "windows-software", Interpolate: true, InterpolateContext: &interpolate.Context{}}, raws...); err != nil {
		return err
	}
	c := p.config
	if len(c.Packages) == 0 {
		return fmt.Errorf("packages must not be empty")
	}
	duration, err := time.ParseDuration(c.Timeout)
	if err != nil || duration < time.Second || duration > 24*time.Hour {
		return fmt.Errorf("timeout must be between 1s and 24h")
	}
	p.timeout = duration
	if c.DownloadRetries < 0 || c.DownloadRetries > 5 {
		return fmt.Errorf("download_retries must be between 0 and 5")
	}
	p.catalog, err = catalog.Load(c.CatalogPath)
	if err != nil {
		return fmt.Errorf("load validated catalog: %w", err)
	}
	seen := map[string]bool{}
	p.packages = nil
	for _, id := range c.Packages {
		if seen[id] {
			return fmt.Errorf("duplicate package %s", id)
		}
		seen[id] = true
		record, err := p.catalog.Resolve(id, c.Versions[id])
		if err != nil {
			return err
		}
		p.packages = append(p.packages, record)
	}
	for id := range c.Versions {
		if !seen[id] {
			return fmt.Errorf("version supplied for unselected package %s", id)
		}
	}
	if c.ReportPath != "" {
		if info, err := os.Stat(c.ReportPath); err == nil && info.IsDir() {
			return fmt.Errorf("report_path is a directory")
		}
	}
	return nil
}
