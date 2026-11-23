package provisioner

import "testing"

// TestPrepareUsesEmbeddedCatalog checks that omitting catalog_path resolves
// every shipped package from the catalog compiled into the binary.
func TestPrepareUsesEmbeddedCatalog(t *testing.T) {
	ids := []string{"vcredist", "powershell7", "adobereader", "chrome", "edge"}
	p := New("test")
	if err := p.Prepare(map[string]any{"packages": ids}); err != nil {
		t.Fatal(err)
	}
	if p.config.CatalogPath != "" {
		t.Fatalf("catalog_path = %q, want empty", p.config.CatalogPath)
	}
	if len(p.packages) != len(ids) {
		t.Fatalf("resolved %d packages, want %d", len(p.packages), len(ids))
	}
	for i, record := range p.packages {
		if record.ID != ids[i] {
			t.Fatalf("package %d = %s, want %s", i, record.ID, ids[i])
		}
	}
}
