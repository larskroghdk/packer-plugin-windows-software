---
name: develop-windows-software
description: Change or debug the windows-software Packer provisioner, its catalog validation, or the embedded PowerShell guest engine (provisioner/, internal/catalog/, guest/Install.ps1). Use for Go or guest-script changes in packer-plugin-windows-software, not for adding packages, publishing artifacts or general Windows administration.
---

# Develop windows-software

Read `AGENTS.md` and inspect the working tree before editing. Preserve concurrent user changes.

## Find the relevant contract

- `main.go` registers the SDK default provisioner; Packer exposes it as `windows-software`. Keep `describe`, release binary naming (`.goreleaser.yml`) and the SDK protocol consistent.
- `provisioner/config.go` owns option decoding; `provisioner/config.hcl2spec.go` is generated from it with `go generate ./provisioner` (`packer-sdc`). Update both, the README option table and `provisioner/config_hcl2_test.go` when options change. `packages` order is installation order; `versions` holds numeric pins or `latest-validated`.
- `provisioner/provisioner.go` orchestrates host download, upload, guest actions and the host report. `provisioner/remote.go` runs guest actions through the builder's communicator. Never open another WinRM client or send GitHub credentials into the guest.
- `internal/catalog/` decodes validated records strictly, compares numeric versions, resolves pins and streams SHA-256-verified downloads. Unknown, missing, duplicate or unvalidated records fail in `Prepare`, before any guest work.
- `guest/Install.ps1` is embedded (`guest/guest.go`) and runs under Windows PowerShell 5.1. Keep top-level functions with comment-based help, and the dot-source guard that `scripts/validate-artifacts.ps1` and Pester rely on.

## Guest JSON protocol

Each action writes one JSON result. Keep Go structs (`Facts`, `observation`) and guest hashtables aligned:

- `Facts`: `name`, `build`, `family`, `architecture`, `server_core`, `error`.
- `Inspect`/`Install`: `version`, `error`, `fatal`, `reboot_required`, `exit_code`.

`fatal` means the VM is in an unknown state (installer still running after timeout, or exit code 1641). The host wraps it in `errGuestUnusable` and aborts even with `fail_on_error = false`; so do transport errors, cancellation and deadlines (`abortsBuild`). Ordinary package errors may continue when `fail_on_error = false`.

## Preserve the installation boundary

- Verify SHA-256 on the host and again in the guest. Require Authenticode status `Valid` and a case-sensitive exact signer name before execution. Never weaken either to accommodate a changed download or certificate rotation.
- Detect versions from registry values or file metadata, never `Win32_Product`. Compare numerically (leading zeros and missing trailing zeros are equal) in both `catalog.Compare` and `ConvertTo-PackageVersion`. A pin must not accept a newer installed version; verify the final version after installation.
- GUI packages require Desktop Experience. Do not assume every Windows Server edition has it.
- Suppress installer restarts and leave reboots to the Packer build. The guest receives only the time remaining on the package deadline and never kills a timed-out installer.
- Keep temporary files in the per-run host and guest directories. Cleanup must not widen its root, follow reparse points or recurse. Write the host report on failure paths too.

## Verify

```powershell
./scripts/check.ps1
staticcheck ./...
Invoke-Pester -Path test/pester
```

Run `test/pester/Install.Tests.ps1` under Windows PowerShell 5.1 (`powershell.exe`), not only `pwsh`. In restricted sessions disable the TestRegistry plugin through `New-PesterConfiguration` rather than touching real registry keys. Run `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning, Error` after PowerShell changes.

Mocks prove protocol behavior only. Live installation needs the `run-packer-example` skill and an explicitly selected disposable VM. Never run the guest engine's Install action on the development workstation.
