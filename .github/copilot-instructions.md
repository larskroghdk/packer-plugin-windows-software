# Repository instructions for GitHub Copilot

Follow [AGENTS.md](../AGENTS.md) and the [develop-windows-software skill](../.agents/skills/develop-windows-software/SKILL.md) when changing the provisioner, packages, guest engine or artifact workflows. Read the relevant implementation before editing, inspect the working tree and preserve existing user changes. Use [README.md](../README.md) for configuration and storage behavior, and [docs/sources.md](../docs/sources.md) for vendor compatibility and licensing references.

## Architecture and contracts

- `main.go` registers the Packer SDK default provisioner, exposed as `windows-software`. Preserve the SDK lifecycle, plugin protocol and release naming.
- `provisioner/` handles configuration, host downloads, transfers, guest actions and host reports. Use the builder's existing WinRM communicator and JSON protocol; do not create a separate WinRM client or send GitHub credentials into the guest.
- Keep configuration decoding and the HCL2 specification in `provisioner/config.go` aligned. Package list order is installation order; version selections are exact pins or `latest-validated`.
- `internal/catalog/` validates records, compares numeric versions and verifies streamed downloads. Reject unknown, missing, duplicate or unvalidated records before installation.
- `guest/Install.ps1` is embedded guest code. Keep it compatible with Windows PowerShell 5.1, with top-level functions and useful comment-based help. Keep JSON fields aligned with the Go protocol structs.
- `packages/<id>.json` defines acquisition and installation policy; `packages/catalog.json` stores immutable validated versions. Put vendor versions and download URLs in manifests, never Go constants. Ordinary EXE/MSI packages should require only a recipe.

## Installation safety

- Verify SHA-256 on both host and guest. Before execution, require Authenticode status `Valid` and an exact allowed certificate identity. Never bypass these checks to accommodate changed downloads or certificates.
- Detect installed software through registry or executable metadata, never `Win32_Product`. Compare versions numerically, including leading zeros and omitted trailing zero components. Exact pins must not silently accept another installed version; verify the final version after installation.
- Preserve OS family, build, native architecture and Server Core detection and package eligibility checks. GUI applications require Desktop Experience.
- Suppress installer restarts and leave reboots to the Packer build. Preserve exit codes and reboot observations: exit code 1641 always fails because a restart was initiated.
- Keep timeouts, cancellation and transport errors as build failures. Do not blindly retry installers or report timed-out work as successful, even when optional package failures may continue.
- Keep temporary files within generated per-run directories. Cleanup must not expand its roots, traverse reparse points or remove unrelated data. Attempt the requested host report on failure paths and preserve package errors, selected sources and final observed versions.
- Never execute installers on the developer workstation. Live installation testing requires an explicitly selected disposable Windows VM.

## Acquisition and publication

- Review `scripts/resolve.py`, `scripts/validate-artifacts.ps1`, `scripts/publish-artifacts.ps1` and their workflows together when changing the artifact pipeline.
- Select stable releases with a supported installer format. Download only from reviewed official hosts and verify the independently recorded hash. Review official vendor documentation before changing host allowlists or compatibility assumptions.
- Recipes default to vendor-only downloads. Upload installer bytes to GitHub only after explicit redistribution review and approval for that package.
- Preserve existing validated records and immutable release assets. Recover interrupted publication without overwriting known-good assets. If a moving vendor URL serves different bytes, fail hash validation.
- Declare and type reusable workflow inputs. Pass manual inputs through environment variables rather than interpolating them into shell code. Limit write permissions to publishing jobs, and reference a GitHub environment only when it exists or the user explicitly requests its setup.
- Editing automation does not authorize pushing commits, publishing releases or running installation tests. Follow the user's task scope for external actions.

## Verification and delivery

Use dependency versions from `go.mod` and `scripts/requirements.txt`; install Python dependencies in a local virtual environment. Run focused checks for changed behavior, then the repository checks:

```powershell
./scripts/check.ps1
staticcheck ./...
python -m unittest discover -s test -p 'test_*.py'
Invoke-Pester -Path test/pester
packer fmt -check examples
```

Keep Pester tests isolated with TestDrive fixtures. In restricted sessions, disable the unused TestRegistry plugin through Pester configuration instead of requesting real registry access. Use Actionlint for workflow changes and PowerShell parsing/PSScriptAnalyzer when available.

Report which checks ran and any failures or blocked checks. Clearly distinguish mock/protocol tests, download/signature validation and real VM installation results. Do not claim installation compatibility from mocks or signature validation. State whether live installation or GitHub publication occurred.
