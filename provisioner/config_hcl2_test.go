package provisioner

import (
	"fmt"
	"github.com/hashicorp/hcl/v2/hcldec"
	"github.com/hashicorp/hcl/v2/hclparse"
	"testing"
)

func TestPrepareHCL2DefaultsAndExplicitFalse(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		t.Run(fmt.Sprintf("explicit=%t", explicit), func(t *testing.T) {
			fixture := configFixture(t)
			source := fmt.Sprintf("packages = [\"chrome\"]\ncatalog_path = %q\n", fixture["catalog_path"])
			if explicit {
				source += "skip_installed = false\nfail_on_error = false\ndownload_retries = 0\n"
			}
			file, diags := hclparse.NewParser().ParseHCL([]byte(source), "example.pkr.hcl")
			if diags.HasErrors() {
				t.Fatal(diags)
			}
			p := New("test")
			raw, diags := hcldec.Decode(file.Body, p.ConfigSpec(), nil)
			if diags.HasErrors() {
				t.Fatal(diags)
			}
			if err := p.Prepare(raw); err != nil {
				t.Fatal(err)
			}
			if p.config.SkipInstalled == explicit || p.config.FailOnError == explicit || p.config.Timeout != "30m" {
				t.Fatalf("HCL2 defaults/overrides lost: %+v", p.config)
			}
			expectedRetries := 2
			if explicit {
				expectedRetries = 0
			}
			if p.config.DownloadRetries != expectedRetries {
				t.Fatalf("retries=%d", p.config.DownloadRetries)
			}
		})
	}
}
