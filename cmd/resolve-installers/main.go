// Command resolve-installers downloads the newest compatible vendor installer
// for each selected package recipe and writes a candidate record for Windows
// signature validation (scripts/validate-artifacts.ps1). It never runs an installer.
//
// Usage:
//
//	go run ./cmd/resolve-installers [-package all|<id>] [-packages packages] [-output artifacts]
//
// GH_TOKEN, when set, authenticates GitHub API requests for a higher rate limit.
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"time"

	"github.com/larskroghdk/packer-plugin-windows-software/internal/resolver"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "resolve-installers:", err)
		os.Exit(1)
	}
}

func run() error {
	packageID := flag.String("package", "all", "package ID to resolve, or all")
	recipeDir := flag.String("packages", "packages", "directory containing package recipes")
	output := flag.String("output", "artifacts", "directory for installers and candidate records")
	flag.Parse()

	recipes, err := resolver.LoadRecipes(*recipeDir)
	if err != nil {
		return err
	}
	var selected []resolver.Recipe
	for _, recipe := range recipes {
		if *packageID == "all" || recipe.ID == *packageID {
			selected = append(selected, recipe)
		}
	}
	if len(selected) == 0 {
		return fmt.Errorf("unknown package %q", *packageID)
	}
	if err = os.MkdirAll(*output, 0755); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	r := &resolver.Resolver{
		HTTP:    &http.Client{Timeout: 30 * time.Minute},
		APIBase: resolver.GitHubAPI,
		Token:   os.Getenv("GH_TOKEN"),
		Log:     os.Stdout,
	}
	for _, recipe := range selected {
		candidate, err := r.Resolve(ctx, recipe, *output)
		if err != nil {
			return err
		}
		fmt.Printf("%s %s: SHA-256 %s verified against the winget manifest\n", candidate.ID, candidate.Version, candidate.SHA256)
	}
	return nil
}
