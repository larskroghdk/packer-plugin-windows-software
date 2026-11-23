# 📦 packer-plugin-windows-software

[![CI](https://github.com/larskroghdk/packer-plugin-windows-software/actions/workflows/ci.yml/badge.svg)](https://github.com/larskroghdk/packer-plugin-windows-software/actions/workflows/ci.yml)

Native HashiCorp Packer provisioner that installs validated x64 Windows software over the builder's WinRM connection. Packages install in list order. No installer runs before its SHA-256 hash and Authenticode signer are verified on both the Packer host and the guest.

The checked-in catalog holds real vendor installers validated on 2026-11-20 for SHA-256, Authenticode signer and embedded product version. That is trust validation, not proof of a working installation; run the example against a disposable VM for that.

## 🏗️ Architecture

- `main.go` registers the provisioner with the Packer Plugin SDK; Packer names it `windows-software`.
- `provisioner/` decodes configuration, selects catalog versions, downloads installers on the host, uploads them through the builder's communicator, runs guest actions and writes the host report.
- `internal/catalog/` strictly decodes validated records, compares numeric versions and streams size-bounded, hash-verified HTTPS downloads.
- `guest/Install.ps1` is embedded in the binary and runs under Windows PowerShell 5.1: platform detection, installed-version detection, hash and Authenticode checks, silent installation and final version verification. It never queries `Win32_Product` and never reboots.
- `packages/<id>.json` recipes hold reviewed acquisition and installation policy; `packages/catalog.json` holds immutable validated records written by automation and is embedded in the plugin binary at build time.
- `internal/resolver/` and `cmd/resolve-installers/` find new versions; `scripts/` validates and publishes them.

## 🧰 Prerequisites and installation

Packer 1.11 or newer, the Go version in `go.mod`, and an administrative WinRM account on a disposable Windows image. The Packer host needs HTTPS access to the vendor download hosts. The guest needs Windows PowerShell 5.1, CIM, Windows Installer and certificate chain and revocation connectivity. Use WinRM over TLS with certificate validation. The guest must be AMD64; ARM64 and x86 are rejected.

Build and install locally:

```powershell
go build -o bin/ .
./bin/packer-plugin-windows-software describe
packer plugins install --path ./bin/packer-plugin-windows-software.exe github.com/larskroghdk/windows-software
```

For a released version, configure `required_plugins` as in [the example](examples/windows-software.pkr.hcl) and run `packer init`. Releases are created as drafts and published after review.

## ⚙️ Configuration

```hcl
provisioner "windows-software" {
  packages       = ["vcredist", "powershell7", "adobereader", "chrome", "edge"]
  skip_installed = true
  fail_on_error  = true
  timeout        = "30m"
  report_path    = "reports/windows-software.json"
}
```

| Option | Default | Behavior |
| --- | --- | --- |
| `packages` | required | Unique package IDs, installed in list order |
| `catalog_path` | empty | Empty uses the catalog embedded in the plugin. A path loads a catalog file on the Packer host instead, relative to Packer's working directory |
| `versions` | `{}` | Package ID to numeric version; `1.2` matches a `1.2.0` record. Omitted IDs use `latest-validated` |
| `skip_installed` | `true` | Skip a package whose installed version equals the selected version (or is newer, for `latest-validated`) |
| `fail_on_error` | `true` | Stop at the first package failure; `false` records the failure and continues |
| `timeout` | `30m` | Per-package deadline covering inspection, download, upload and installation; 1s to 24h |
| `download_retries` | `2` | Extra host download attempts, at most 5. Installers are never retried |
| `report_path` | empty | JSON report written on the Packer host |

A pin rejects a newer installed version, because automatic downgrades are unsafe. `skip_installed = false` reinstalls the same version but still never downgrades. Older versions are upgraded, and the final installed version must equal the selected record. An unparseable installed version is an error. Every selected package is checked against the detected OS before anything is installed.

`fail_on_error = false` continues only after ordinary package failures. These failures always stop the build:

- transport errors, cancellation or an expired deadline;
- OS preflight failures;
- report write failures;
- a guest left in an unknown state (an installer still running after its timeout, or exit code 1641).

The embedded catalog is a snapshot taken when the plugin was built, so a plugin release always resolves the same versions. Versions validated after that release need a newer plugin, or a `catalog_path` pointing to `packages/catalog.json` from a reviewed commit. For reproducible builds, pin every package and the plugin version; with a `catalog_path`, `latest-validated` changes as that file grows. Browser self-updaters can change versions after provisioning; manage them through policy.

## 🪟 Packages and Windows compatibility

| ID | Package | Installer | Installed-version detection |
| --- | --- | --- | --- |
| `vcredist` | Microsoft Visual C++ 2015-2022 x64 runtime | EXE | VC runtime x64 registry `Version` |
| `powershell7` | Microsoft PowerShell 7 stable | MSI | `pwsh.exe` product version |
| `adobereader` | Adobe Acrobat Reader x64 unified package | EXE | `Acrobat.exe` product version |
| `chrome` | Google Chrome Enterprise x64 | MSI | `chrome.exe` product version |
| `edge` | Microsoft Edge for Business x64 | MSI | `msedge.exe` product version |

All recipes declare Windows Server 2019, 2022 and 2025 with Desktop Experience, Windows 10 1809 or newer, and Windows 11. Only `powershell7` and `vcredist` are allowed on Server Core. These declarations come from vendor requirements ([sources](docs/sources.md)), not from live installation tests.

Exit codes 0 and 3010 succeed. Exit code 3010 or a pending-restart marker sets `reboot_required`. Exit code 1641 means the installer started a restart, so it always fails the build. Add a `windows-restart` provisioner after this one when needed. A timed-out installer is left running rather than killed mid-transaction; discard that VM.

## 🚚 Installer storage and publication

`publish-software-artifacts.yml` runs daily at 05:23 UTC and on manual dispatch for one package or all of them. Runs are serialized, and no GitHub environment is required.

1. `go run ./cmd/resolve-installers` picks the newest stable version in Microsoft's `microsoft/winget-pkgs` index that has a supported x64 machine-scope installer, skipping MSIX-only versions. It reads manifests by immutable Git blob, downloads only from hosts allowed by the recipe, and verifies the index SHA-256. The index is for discovery; it is not a trust anchor.
2. `scripts/validate-artifacts.ps1` runs on Windows and requires a valid Authenticode signature from an allowed signer and an embedded product version equal to the candidate's.
3. `scripts/publish-artifacts.ps1` creates release `software/<id>/<version>` containing the catalog record and a SHA256SUMS file. It then appends the record to `packages/catalog.json` through the GitHub Contents API.

Every recipe has `redistribution_approved` set to false, so only metadata is published and Packer downloads from the vendor URL. Set the flag only after confirming you hold redistribution rights. Adobe's distribution agreement in particular must be reviewed: a free download does not permit republishing on GitHub. Vendor-only installers are never uploaded, not even as Actions artifacts. Approved installers are published as `<id>-x64-<version>.<msi|exe>`.

Releases are immutable. A version already in the catalog must keep its hash, assets are never replaced, and a draft left by an interrupted run is completed on the next run. The catalog commit is based on the checked-out file's blob SHA, so a concurrent change fails with HTTP 409 instead of being overwritten. Branch protection may require replacing that direct write with a pull request. Validation metadata is kept as an Actions artifact for 30 days.

A moving vendor URL can stop serving old bytes; the hash check then fails safely. Historical reproducibility needs an immutable vendor URL or an installer you are licensed to keep. Private release assets are not supported. No GitHub token reaches the VM or any vendor host.

## ➕ Adding a package

Add `packages/<id>.json` with the winget ID, exact signer names, vendor host allowlist, installer type, silent and no-restart arguments, file or registry detection, exit codes and supported OS families. Ordinary EXE/MSI packages need no code. Validate a candidate on Windows without installing it:

```powershell
go run ./cmd/resolve-installers -package powershell7
./scripts/validate-artifacts.ps1
```

Review the resulting `<id>-catalog.json` in `artifacts/`, the signature and the vendor terms. Do not edit `packages/catalog.json` by hand. `.agents/skills/add-software-package/SKILL.md` describes each recipe field.

## 🩺 Reports and troubleshooting

The report records plugin version, start time, duration, OS name, build, family and architecture. For each package it records the requested and resolved versions, previous and final installed versions, status, source URL, SHA-256, exit code, reboot requirement, duration and error. It is written even after a failure, and a failed write fails the build. Do not share one report path between concurrent builds.

- 📭 **Empty or invalid catalog:** `Prepare` fails. Use a catalog from a reviewed publication commit.
- 🔢 **Hash mismatch:** the vendor URL now serves different bytes, or a download was corrupted. Never bypass the check; publish a newly validated version.
- 🔏 **Signature failure:** check trust roots, revocation connectivity and vendor certificate rotation. Review a signer change before editing the recipe.
- 🏷️ **Embedded version mismatch:** review upstream metadata; do not remove the check.
- 🔍 **Installed version mismatch:** inspect the report and the guest. Each MSI writes a verbose log named `<id>.log` in the per-run directory; collect it before cleanup.
- ⛔ **1603 / 1618:** check vendor prerequisites, or another Windows Installer transaction that is still running.
- 🔌 **WinRM loss, cancellation, timeout or `guest state is unknown`:** discard the VM and fix connectivity or the deadline.

Guest files live in `C:\Windows\Temp\packer-windows-software-<uuid>`; host files live in the OS temporary directory. Cleanup deletes only that directory's files, refuses subdirectories and reparse points, and never changes WinRM or reboots.

## 🛠️ Development and release

```powershell
./scripts/check.ps1          # gofmt, go mod tidy -diff, tests, vet, build
staticcheck ./...
actionlint
Invoke-Pester -Path test/pester
```

Run `test/pester/Install.Tests.ps1` under Windows PowerShell 5.1 as well. CI runs the Go checks on Linux and Windows, Staticcheck, actionlint, Pester on both PowerShell editions and PSScriptAnalyzer. Run the example with `./examples/Invoke-PackerExample.ps1` ([guide](examples/README.md)).

`release.yml` runs on `v*` tags. It reads the Packer API version from `describe` and uses GoReleaser to build a draft release with multi-platform ZIPs and SHA256SUMS. No signing key is bundled.

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). 🤝

## 📄 License

The project license is in [LICENSE](LICENSE); third-party software remains under its vendor licenses.
