# packer-plugin-windows-software

Native HashiCorp Packer provisioner for installing validated x64 Windows software over WinRM. The package list controls installation order. Installers are never run before SHA-256 and Authenticode validation.

This repository implements the installation engine and publication pipeline. The checked-in catalog contains real installers validated for SHA-256, Authenticode publisher and embedded product version on 2026-11-20. Run the publication workflow in your own GitHub repository to create the corresponding persistent release metadata. No live installation certification is implied. Real VM installation certification is a separate, opt-in step; see [validation](docs/validation.md).

## Architecture

- `main.go` registers the default provisioner with the Packer Plugin SDK. Its external name is `windows-software`.
- `provisioner/` decodes HCL2, selects validated versions, downloads installers on the Packer host, transfers them through the builder's WinRM communicator, and writes host reports.
- `internal/catalog/` strictly validates release records, compares numeric versions, and streams bounded HTTPS downloads through SHA-256 verification.
- `guest/Install.ps1` is embedded into the binary. Windows PowerShell 5.1 performs OS and installed-version detection, Authenticode validation, silent installation and final version verification. No Win32_Product queries or reboots.
- `packages/*.json` are editable package recipes. `packages/catalog.json` contains immutable validated records produced by automation. Versions and URLs are data, never Go constants.
- `scripts/` resolves vendor downloads, validates signed packages on Windows, and publishes persistent metadata/assets to GitHub Releases.

The design follows the adjacent windows-checkup, windows-cleanup and windows-features plugins' SDK registration, embedded guest scripts, JSON protocol and host-side reports. It avoids inheriting their unrelated auditing or cleanup policies.

## Prerequisites and installation

Use Packer 1.11 or newer, the Go version in `go.mod`, and an elevated WinRM account on a disposable Windows image. Host access to GitHub and approved vendor endpoints is required. The guest needs Windows PowerShell 5.1, CIM, Windows Installer and certificate chain/revocation connectivity. Enable WinRM TLS and certificate validation in the builder. Guest architecture must be AMD64; ARM64 and x86 are rejected.

Build and inspect locally:

```powershell
go build -o bin/packer-plugin-windows-software.exe .
./bin/packer-plugin-windows-software.exe describe
packer plugins install --path ./bin/packer-plugin-windows-software.exe github.com/larskroghdk/windows-software
```

After publishing an approved plugin release, configure `required_plugins` as shown in [the example](examples/windows-software.pkr.hcl) and run `packer init`. The repository owner must publish the draft plugin release after reviewing its artifacts. Do not use the development plugin version constraint for production.

## Configuration

Inside an existing Windows build:

```hcl
provisioner "windows-software" {
  packages       = ["vcredist", "powershell7", "adobereader", "chrome", "edge"]
  catalog_path   = "packages/catalog.json"
  skip_installed = true
  fail_on_error  = true
  timeout        = "30m"
  report_path    = "reports/windows-software.json"
}
```

| Option | Default | Behavior |
| --- | --- | --- |
| `packages` | required | Unique package IDs, installed in list order |
| `catalog_path` | `packages/catalog.json` | Local trusted catalog on the Packer host |
| `versions` | `{}` | Map of package IDs to exact versions; omitted IDs use `latest-validated` |
| `skip_installed` | `true` | Skip equal or newer installed software for latest selection |
| `fail_on_error` | `true` | Stop and fail on package errors; false records failures and continues |
| `timeout` | `30m` | Per-package context deadline, including download and installation; 1 second to 24 hours |
| `download_retries` | `2` | Additional verified download attempts, at most 5; installers themselves are never blindly retried |
| `report_path` | empty | Optional JSON report on the Packer host |

An exact pin rejects a newer installed version because automatic downgrades are unsafe. `skip_installed = false` reinstalls an equal version; it still does not downgrade. Older versions are upgraded and the final version must match the selected record. Unparseable installed versions are errors. All selected packages are checked for OS compatibility before installation begins. If `fail_on_error = false`, inspect report statuses before accepting the image. Transport, cancellation, OS preflight and report-write errors fail the build.

Use `versions = { powershell7 = "<validated numeric version>" }` with an actual version from your catalog. For a reproducible build, pin every package and use a catalog from a reviewed Git commit. `latest-validated` deliberately changes as the catalog changes. Browser self-updaters can change installed versions after provisioning; control them separately through your organization's policies.

## Packages and Windows compatibility

| ID | Package | Installer | Installed-version detection |
| --- | --- | --- | --- |
| `vcredist` | Microsoft Visual C++ 2015-2022 x64 runtime | EXE | VC runtime x64 registry `Version` |
| `powershell7` | Microsoft PowerShell 7 stable | MSI | `pwsh.exe` product version |
| `adobereader` | Adobe Acrobat Reader x64 unified package | EXE | `Acrobat.exe` product version |
| `chrome` | Google Chrome Enterprise x64 | MSI | `chrome.exe` product version |
| `edge` | Microsoft Edge for Business x64 | MSI | `msedge.exe` product version |

Recipes cover Windows Server 2019, 2022 and 2025 with Desktop Experience, Windows 10 1809 or newer, and Windows 11. Browser and Adobe packages are not approved for Server Core. PowerShell and VC runtime are usable on Server Core. OS lifecycle, patch level, vendor release compatibility and license terms still apply; the OS-family declaration is not live installation certification. Review recipe compatibility when approving a new major release. [Vendor references](docs/sources.md) document the basis for compatibility.

Exit codes 0 and 3010 are accepted. 3010 and Windows reboot markers set `reboot_required`. Exit code 1641 always fails because it indicates a restart was initiated. Schedule a builder-owned `windows-restart` step after this provisioner when needed. Installation must be verifiable before that reboot. A timed out installer may remain running: discard the failed VM, rather than killing Windows Installer or continuing the build.

## Installer storage and publication

`publish-software-artifacts.yml` supports manual selection of one package or all packages. `update-software-artifacts.yml` invokes the same pipeline daily at 05:23 UTC. Both serialize publication. No GitHub environment needs to be created. Protect recipe/catalog changes before enabling automated publishing. If your organization requires deployment approvals, create a GitHub environment first and then reference its actual name in the publishing job.

The resolver uses Microsoft's `microsoft/winget-pkgs` stable version index to select the newest stable release with a supported installer format (MSIX-only versions are skipped), reads installer metadata by immutable Git blob, downloads from recipe-approved official vendor hosts, and verifies the index SHA-256. The index is a discovery source, not a vendor endorsement. A Windows runner independently requires a valid Authenticode signature, exact approved certificate identity and matching embedded product version. A mismatch fails closed and preserves known-good records. This is trust validation, not an unattended installation smoke test.

All recipes initially set `redistribution_approved` to false. This stores validated metadata in Releases and downloads the exact vendor URL during provisioning. Review the license and change that package's flag only when you hold appropriate redistribution rights. Adobe's distribution agreement must be reviewed for your use; a free download does not grant permission to put the installer on a public GitHub release. The pipeline does not upload vendor-only installers even as temporary Actions artifacts.

For approved redistribution, persistent assets use:

```text
vcredist-x64-<version>.exe
powershell7-x64-<version>.msi
adobereader-x64-<version>.exe
chrome-x64-<version>.msi
edge-x64-<version>.msi
```

Each version gets `software/<id>/<version>` and a package catalog plus checksum file. Releases are created as drafts, populated, then published. Existing assets are never overwritten. Repeated publication checks the old hash and recovers a previously published record if a catalog update failed. New records are appended to the repository catalog through the GitHub Contents API with optimistic concurrency. Branch protection may require adapting that final write to your organization's pull request process; write failures do not delete releases. Actions artifacts retain validation metadata for 30 days. GitHub Releases retain approved installers and metadata until explicitly deleted.

Vendor-only moving URLs may stop serving old bytes. A hash mismatch fails safely; historical reproducibility then requires an approved immutable vendor URL or a legally authorized retained installer. The plugin cannot make retention guarantees for vendor-owned URLs. Private authenticated release assets are not supported by the downloader; use public assets or vendor downloads. No GitHub token is sent into the VM.

## Adding a package

Copy a recipe into `packages/<id>.json`. Declare its stable winget ID, exact signer names, official download host allowlist, x64 installer type, silent/no-restart arguments, file or registry detection, success/reboot codes and supported OS families. The resolver is generic for these EXE/MSI cases. Do not add execution code to Go for a new ordinary package. Packages requiring a different detection strategy or custom installer format require a reviewed engine extension.

Validate a candidate locally without installation (PowerShell 7 on a Windows validation machine):

```powershell
python -m venv .venv
./.venv/Scripts/python.exe -m pip install --require-hashes -r scripts/requirements.txt
./.venv/Scripts/python.exe scripts/resolve.py --package powershell7
./scripts/validate-artifacts.ps1
```

Inspect `artifacts/powershell7-catalog.json`, the signature and vendor terms before publishing. The generated `validated_at`, SHA-256, source, official URL and immutable version are mandatory in a provisionable catalog. Empty or malformed catalogs fail in Packer's `Prepare` phase.

## Reports and troubleshooting

The optional host JSON report records OS/build/architecture, plugin version, UTC start time, elapsed time and each package's requested/resolved version, previous/final installed version, status, source URL, checksum, installer exit code, reboot requirement, duration and error. A report is attempted even after a guest error; report failures themselves fail provisioning. Do not point multiple simultaneous builds at the same report path.

- Empty catalog: run the publication workflow and use its reviewed catalog commit.
- Hash mismatch: the vendor URL changed or a download was corrupted. Never bypass verification; republish a newly validated version.
- Signature failure: check Windows trust roots, revocation connectivity and vendor certificate rotation. Review signer changes before editing recipes.
- Embedded version mismatch: review upstream metadata and installer version conventions. Do not strip the check to make publishing pass.
- Installed version mismatch: inspect the host report, vendor logs and guest state in a disposable VM. MSI logging is enabled inside the per-run temporary directory; retrieve it during troubleshooting before cleanup.
- Exit code 1603: investigate vendor prerequisites or installer logs. 1618 means another Windows Installer transaction is running; resolve that in the image build before retrying.
- WinRM loss, cancellation or timeout: discard the VM and fix connectivity/deadline configuration.
- Publication API failure: check token permissions and branch protection. Previous releases remain available.

Temporary files use a per-run UUID directory under `C:\Windows\Temp` and host OS temporary storage. Cleanup removes only that run's direct files and refuses unexpected subdirectories/reparse-point roots. It never reboots, changes WinRM or modifies unrelated files. SDK Upload/Download have no context argument; cancellation is checked around them, while remote execution and HTTP use contexts.

## Development and release

Run the existing Packer example with `./examples/Invoke-PackerExample.ps1`. See [examples/README.md](examples/README.md) for local plugin preparation, connection variables and validation without provisioning.

```powershell
./scripts/check.ps1
staticcheck ./...
python -m unittest discover -s test -p 'test_*.py'
Invoke-Pester -Path test/pester
```

CI runs Go tests/vet/build on Linux and Windows, Staticcheck, Python recipe/resolver tests and isolated Windows PowerShell Pester tests. `release.yml` runs on `v*` tags, derives the Packer protocol from `describe`, and creates multi-platform ZIPs and SHA256SUMS through GoReleaser. Review and publish its draft. Signing release checksums with your organization key can be added to the release environment; no signing key is bundled.

See [docs/validation.md](docs/validation.md) for commands actually executed and the explicit live VM test boundary. Project license is in [LICENSE](LICENSE); third-party software remains subject to its vendor license.
