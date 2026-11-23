# Agent instructions

`windows-software` is a native Packer provisioner that installs SHA-256- and Authenticode-validated x64 Windows software over the builder's WinRM communicator. The repository is Go and PowerShell only.

## Layout

| Path | Role |
| --- | --- |
| `main.go`, `provisioner/` | SDK plugin, configuration, guest orchestration (`remote.go`), host report |
| `internal/catalog/` | Validated catalog records, version comparison, verified downloads |
| `internal/resolver/`, `cmd/resolve-installers/` | winget-based discovery of new installer versions |
| `guest/Install.ps1` | Embedded guest engine (Windows PowerShell 5.1) |
| `packages/` | `<id>.json` recipes and the validated records in `catalog.json` |
| `scripts/` | Checks, artifact validation and publication |
| `examples/` | Packer example and its runner |

## Rules

- Use the Packer SDK lifecycle and the JSON protocol over the builder's communicator. Keep guest code compatible with Windows PowerShell 5.1. Don't use `Win32_Product`, reboot the guest or run installers on the development workstation.
- Never bypass installer hashes, Authenticode trust or the exact signer identity to make a package pass.
- Versions and download URLs belong in recipes and the catalog, not in code. Validated versions and published release assets are immutable.
- The guest working directory is private to SYSTEM and Administrators and must be new. Keep it that way, because the guest verifies installers there before running them.
- Uploading installer bytes to GitHub requires an explicit redistribution review for that package.
- Don't push, tag, dispatch workflows, publish releases or provision VMs unless the user asks for that action in the current task.

## Checks

Run these before delivery. CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs the same checks with pinned tool versions and adds govulncheck.

```powershell
./scripts/check.ps1                      # gofmt, go mod tidy -diff, test, vet, build
staticcheck ./...
actionlint
Invoke-Pester -Path test/pester          # Install.Tests.ps1 also under powershell.exe 5.1
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning, Error
packer fmt -check examples
```

Live installation testing is allowed only against an explicitly selected disposable VM. When reporting, keep mock and protocol tests, download and signature validation, and real installation results apart, and say which checks didn't run.

## Skills

Task procedures live in `.agents/skills/<name>/SKILL.md`. Read only the one that matches the task:

- `develop-windows-software`: [provisioner, catalog or guest engine changes](.agents/skills/develop-windows-software/SKILL.md).
- `add-software-package`: [new or changed package recipes](.agents/skills/add-software-package/SKILL.md).
- `publish-software-artifacts`: [resolver, validation, publication and release workflows](.agents/skills/publish-software-artifacts/SKILL.md).
- `run-packer-example`: [validate the example or run it against a disposable VM](.agents/skills/run-packer-example/SKILL.md).
- `release-plugin`: [CI, packaging and authorized signed plugin releases](.agents/skills/release-plugin/SKILL.md).

Activating a skill grants no authority to publish or to operate on a guest. [docs/agent-guidance.md](docs/agent-guidance.md) explains how each tool finds these files.
