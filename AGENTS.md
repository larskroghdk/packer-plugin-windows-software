# packer-plugin-windows-software

Native Packer provisioner (`windows-software`) that installs SHA-256- and Authenticode-validated x64 Windows software over the builder's WinRM communicator. The repository is Go and PowerShell only.

## Layout

- `main.go`, `provisioner/` - SDK plugin, configuration, guest orchestration, host report.
- `internal/catalog/` - validated catalog records, version comparison, verified downloads.
- `internal/resolver/`, `cmd/resolve-installers/` - winget-based discovery of new installer versions.
- `guest/Install.ps1` - embedded guest engine (Windows PowerShell 5.1).
- `packages/<id>.json` recipes and `packages/catalog.json` validated records.
- `scripts/` - checks, artifact validation and publication. `examples/` - Packer example and runner.

## Skills

Use the matching skill in `.agents/skills/`:

- `develop-windows-software` - provisioner, catalog or guest engine changes.
- `add-software-package` - new or changed package recipes.
- `publish-software-artifacts` - resolver, validation, publication and release workflows.
- `run-packer-example` - validate the example or run it against a disposable VM.

## Rules

- Use the Packer SDK lifecycle and the JSON protocol over the builder's communicator. Keep guest code compatible with Windows PowerShell 5.1. Do not use `Win32_Product`, reboot the guest or run installers on the developer workstation.
- Never bypass installer hashes, Authenticode trust or exact signer identity to make a package pass.
- Versions and download URLs belong in recipes and the catalog, not code. Validated versions and published release assets are immutable.
- Uploading installer bytes to GitHub requires an explicit redistribution review for that package.
- Do not push, tag, dispatch workflows, publish releases or provision VMs unless the user asks for that action in the current task.

## Verify before delivery

```powershell
./scripts/check.ps1                      # gofmt, go mod tidy -diff, test, vet, build
staticcheck ./...
actionlint
Invoke-Pester -Path test/pester          # Install.Tests.ps1 also under powershell.exe 5.1
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning, Error
packer fmt -check examples
```

Live installation testing is allowed only against an explicitly selected disposable VM. When reporting, distinguish mock/protocol tests, download/signature validation and real installation results, and state which checks did not run.
