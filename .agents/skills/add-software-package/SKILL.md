---
name: add-software-package
description: Add or change a package recipe in packages/<id>.json for the windows-software provisioner - winget ID, signer names, vendor host allowlist, silent arguments, detection and supported OS - and validate a candidate download without installing it. Use when supporting a new EXE/MSI application or reviewing a vendor's changed host, signer or installer format.
---

# Add a software package

Ordinary x64 EXE and MSI packages need only a recipe; do not add package-specific Go or guest code. Read `docs/sources.md` and the vendor's official deployment documentation first.

## Write the recipe

Copy an existing recipe of the same installer type (`packages/chrome.json` for MSI, `packages/vcredist.json` for EXE) to `packages/<id>.json`. The file name must equal `id` (lowercase, digits, hyphens). Unknown fields are rejected.

| Field | How to choose it |
| --- | --- |
| `winget` | Exact `PackageIdentifier` from `microsoft/winget-pkgs`; it is the version index, not the trust source. |
| `installer_type` | `msi` matches winget `msi`/`wix`; `exe` matches `exe`/`burn`/`inno`/`nullsoft`. A newer MSIX-only version is skipped, never substituted. |
| `silent_arguments` | Vendor-documented silent switches including restart suppression (`/norestart` or `REBOOT=ReallySuppress`). For MSI, omit `/i` and logging; the engine adds them. |
| `detection` | `file` with a `%ProgramFiles%` executable path, or `registry` with `path` and `value`. Must report the same version the installer embeds. Never `Win32_Product`. |
| `signer_subjects` | Certificate simple names, case-sensitive, taken from `Get-AuthenticodeSignature` on a downloaded installer. List a second name only for a confirmed vendor rotation. |
| `allowed_hosts` | Exact official download hosts, including redirect origins named in winget manifests. `allowed_path_prefix` narrows a shared host, as `powershell7` does for GitHub. |
| `success_codes`, `reboot_codes` | Usually `[0, 3010]` and `[3010]`. Never list 1641. |
| `supported_os`, `server_core` | Families from vendor requirements: `server2019`, `server2022`, `server2025`, `windows10`, `windows11`. `server_core` only for packages without a GUI dependency. |
| `redistribution_approved` | Keep `false`. Changing it needs the user's explicit licence review; `internal/resolver/packages_test.go` enforces this. |

Add the ID to the `package` choice list in `.github/workflows/publish-software-artifacts.yml` and the package table in `README.md`, and record the vendor sources in `docs/sources.md`.

## Validate without installing

```powershell
go test ./internal/resolver/
go run ./cmd/resolve-installers -package <id>
./scripts/validate-artifacts.ps1
```

The resolver checks the winget hash and the host allowlist; validation checks Authenticode, signer and embedded version on Windows. Inspect `artifacts/<id>-catalog.json`. Fix a failure in the recipe from vendor evidence, never by loosening a check. Do not commit `artifacts/` or hand-edit `packages/catalog.json`; publication appends records.

Download and signature validation is not installation testing. Use the `run-packer-example` skill on a disposable VM to prove the silent arguments and detection.
