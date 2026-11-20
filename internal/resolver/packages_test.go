package resolver

import (
	"strings"
	"testing"

	"github.com/larskroghdk/packer-plugin-windows-software/internal/catalog"
)

// TestRepositoryPackages checks the checked-in recipes and catalog together.
func TestRepositoryPackages(t *testing.T) {
	recipes, err := LoadRecipes("../../packages")
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]Recipe{}
	for _, recipe := range recipes {
		byID[recipe.ID] = recipe
		t.Run(recipe.ID, func(t *testing.T) {
			args := strings.ToLower(recipe.SilentArguments)
			if !strings.Contains(args, "norestart") && !strings.Contains(args, "reboot=reallysuppress") {
				t.Errorf("silent arguments %q do not suppress restarts", recipe.SilentArguments)
			}
			// Uploading installer bytes to GitHub needs an explicit licence review;
			// change this assertion only together with that review.
			if recipe.RedistributionApproved {
				t.Error("redistribution_approved is set")
			}
		})
	}
	validated, err := catalog.Load("../../packages/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, record := range validated.Packages {
		recipe, ok := byID[record.ID]
		if !ok {
			t.Errorf("catalog record %s %s has no recipe", record.ID, record.Version)
			continue
		}
		if record.Source == "vendor" {
			if err := recipe.Approve(record.URL); err != nil {
				t.Errorf("catalog record %s %s: %v", record.ID, record.Version, err)
			}
		}
	}
}
