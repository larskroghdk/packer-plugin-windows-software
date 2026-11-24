# Security policy

## Supported versions

Only the latest release receives security fixes. Fixes ship in a new release, not as backports. Because the project is pre-1.0, a release with a fix can also contain breaking changes.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |
| Unreleased `main` | Fixed in the next release |

Each release embeds the catalog as it was at build time. A security-relevant catalog change, such as removing a record whose installer or signer is no longer trusted, reaches users in a new release. Until then, users can point `catalog_path` at `packages/catalog.json` from the fixing commit.

## Reporting a vulnerability

Don't open a public issue, pull request or discussion.

Use [private vulnerability reporting](https://github.com/larskroghdk/packer-plugin-windows-software/security/advisories/new): the "Report a vulnerability" button on the repository's Security tab. If that button isn't available, [open an issue](https://github.com/larskroghdk/packer-plugin-windows-software/issues/new/choose) that asks the maintainer for a private channel and contains no vulnerability details.

Include:

- Plugin version (`describe`), Packer version, builder and WinRM settings (HTTP or HTTPS, authentication type).
- Guest edition, version, build and installation type (Server Core or Desktop Experience).
- The `windows-software` provisioner block, the affected package IDs and versions, and whether `catalog_path` was set.
- Steps to reproduce, the impact, and what an attacker needs (network position, guest account, write access to the catalog, a recipe or the build host).
- The relevant parts of the JSON report or `PACKER_LOG=1` output.

Remove passwords, tokens, signing material, host names, IP addresses and internal URLs first. Don't test against systems you don't own or aren't authorized to test. Reproduce on a disposable VM, never on a workstation or production system.

## Scope

The plugin downloads installers on the Packer host, uploads them over the builder's WinRM communicator and runs them in an elevated Windows PowerShell 5.1 session. In scope:

- An installer that runs without a matching SHA-256 hash, a `Valid` Authenticode signature, or a signer name in the record's `signer_subjects`, on any code path, including `skip_installed`, retries and `fail_on_error = false`.
- A way to replace or alter an installer, `Install.ps1` or a JSON input file between verification and execution, including through weak permissions on the guest working directory `C:\Windows\Temp\packer-windows-software-<uuid>` or through reparse points.
- Package IDs, versions, paths or other catalog and configuration data reaching PowerShell command text instead of the JSON input files of the guest contract.
- A download that follows a non-HTTPS URL, accepts URL credentials, exceeds the size bound, or produces a file that is used before its hash is checked.
- The resolver or publication workflow writing a catalog record that wasn't validated, changing the hash of an existing version, replacing a published release asset, or uploading installer bytes for a package without `redistribution_approved`.
- Credentials or tokens exposed in reports, Packer output, files uploaded to the guest or release artifacts, or a GitHub token reaching the guest or a vendor host.
- A downgrade, a restart started by the plugin, or a failure that `fail_on_error = false` hides when the guest state is unknown (installer still running, exit code 1641, transport loss).
- Weaknesses in the CI, publication or release workflows, such as unpinned Actions or excessive token permissions, that could compromise the catalog or published plugin binaries.

Out of scope:

- Vulnerabilities in the vendor software the catalog installs. Report these to the vendor.
- Vulnerabilities in Windows, Windows Installer, WinRM or Windows PowerShell. Report these to the [Microsoft Security Response Center](https://msrc.microsoft.com/report).
- Vulnerabilities in Packer or the Packer plugin SDK. Report these through [HashiCorp's security policy](https://www.hashicorp.com/security).
- The effect of a custom catalog supplied through `catalog_path`. That file is trusted input; see [Security considerations](#security-considerations).
- A compromised vendor signing key or a vendor that signs malicious installers with its own certificate.

## Process

The maintainer acknowledges the report, confirms or rejects it, and agrees a disclosure date with the reporter. This is a single-maintainer project, so response times are best effort.

Fixes are released in a new version and disclosed through a GitHub Security Advisory. A CVE is requested through GitHub when appropriate. Reporters are credited unless they prefer not to be.

## Security considerations

These follow from how the plugin works. They aren't vulnerabilities, but they affect the images you build.

- **Elevated execution.** Each guest action runs `powershell.exe -File` in an elevated session through the builder's communicator, and installers run with administrator rights. Use dedicated build credentials, pass them as sensitive Packer variables or environment variables, and build on disposable guests.
- **WinRM transport.** The plugin uses the builder's communicator and doesn't change the WinRM configuration. Use HTTPS (`winrm_use_ssl = true`) with certificate validation outside isolated build networks; `winrm_insecure = true` disables that validation.
- **Installer trust.** The Packer host checks the SHA-256 hash of every download. The guest checks the hash again, requires a `Valid` Authenticode signature and compares the signer's simple name, case-sensitively, with the record's `signer_subjects` before it runs the installer. The guest needs certificate chain and revocation connectivity for that check. The publication workflow also checks the signature and the embedded product version before a record enters the catalog.
- **Catalog and recipes are code.** A catalog record sets the download URL, hash, allowed signers, detection and the `silent_arguments` passed to the installer. The plugin validates the record's shape, not its intent. Review recipe and catalog changes like code changes, and load `catalog_path` only from a reviewed commit on a location that untrusted users can't write.
- **Discovery isn't trust.** The resolver uses `microsoft/winget-pkgs` to find versions and restricts downloads to the recipe's host allowlist. Trust comes from the hash, the signature and the exact signer, not from the index.
- **Download sources.** Vendor URLs can change content. A hash mismatch then fails the build, as intended. Installers are published to GitHub only after a redistribution review, and published release assets are never replaced.
- **Reboots.** The plugin never restarts the guest. Exit code 3010 or a pending restart sets `reboot_required`; exit code 1641 fails the build. Add a `windows-restart` provisioner where needed, and discard a VM whose state is reported as unknown.
- **Reports.** Reports contain the guest's OS facts, package versions, installer URLs, hashes and errors. Treat them as build artifacts, write them outside shared directories, and redact them before attaching them to an issue.

## Verifying releases

Download `packer-plugin-windows-software_v<VERSION>_SHA256SUMS` and its detached `.sig` from the GitHub release. Verify the signature with GPG using the maintainer's release signing key, then check the plugin ZIP against the checksums.
