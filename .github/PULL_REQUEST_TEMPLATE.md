## Summary

<!-- What changes and why. For behavior changes, describe the before and after. -->

## Related issues

<!-- `Closes #` / `Refs #`. Package requests should start with the package request form. -->

## Breaking changes and compatibility

- [ ] No breaking change, or the change to configuration, report output, catalog schema or behavior is described above
- [ ] Configuration change regenerates `provisioner/config.hcl2spec.go` with `go generate ./provisioner` and updates `provisioner/config_hcl2_test.go` and the README option table, or N/A
- [ ] Catalog format change keeps existing records loadable or increments `schema_version`, or N/A
- [ ] Changed `supported_os` or `server_core` declarations cite the vendor requirement in [docs/sources.md](https://github.com/larskroghdk/packer-plugin-windows-software/blob/main/docs/sources.md), or N/A

Affected packages and Windows releases:

## Testing

- [ ] `./scripts/check.ps1`, `staticcheck ./...` and `actionlint` pass
- [ ] `Invoke-Pester -Path test/pester` passes, and `test/pester/Install.Tests.ps1` also passes under Windows PowerShell 5.1
- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning, Error` and `packer fmt -check examples` pass
- [ ] Regression tests fail on the old behavior and pass on the new one, or N/A
- [ ] Download and signature validation: `go run ./cmd/resolve-installers -package <id>` and `./scripts/validate-artifacts.ps1`, or N/A
- [ ] Live installation on a disposable VM: guest release, edition, build, installation type, builder and attached report, or "Not run" with the reason

Mock and protocol tests don't prove a real installation, and validation without installation doesn't prove detection or exit-code handling.

## Installation behavior

- [ ] The installer runs silently and unattended with the recipe's `silent_arguments`, with no prompt, window or vendor updater dialog that blocks the session, or N/A
- [ ] Success and reboot exit codes match the vendor documentation; 3010 or a pending restart sets `reboot_required`, and 1641 still fails the build, or N/A
- [ ] The installer doesn't restart the guest, stop WinRM or the network, or outlast `timeout` in normal operation, or N/A
- [ ] Detection reads the installed version from the recipe's file or registry source, not `Win32_Product`, and the final version equals the selected record, or N/A
- [ ] A second run with `skip_installed = true` skips the package, and a newer installed version is never downgraded, or N/A
- [ ] Prerequisites on other packages are documented, and the example lists the packages in a working order, or N/A

## Integrity and security

- [ ] SHA-256, Authenticode status and exact signer checks are unchanged or stricter on the host, guest and publication paths
- [ ] Signer, URL host allowlist or installer type changes in a recipe are explained above, or N/A
- [ ] Versions and URLs live in `packages/`; `packages/catalog.json` is changed only by the publication workflow, and no existing record or release asset is altered
- [ ] Installer bytes are uploaded to GitHub only for a package with a completed redistribution review, or N/A
- [ ] Guest data passes through the JSON input files, not interpolated into PowerShell command text, and the guest working directory stays new and private to SYSTEM and Administrators, or N/A
- [ ] No credentials, tokens or internal host names in code, reports, logs, examples or artifacts, and no GitHub token reaches the guest
- [ ] Actions remain pinned to commit SHAs with minimum permissions, or N/A

Security, reliability and performance impact:

## Documentation

- [ ] README, `docs/`, examples, AGENTS.md and `.agents/skills` updated where behavior changed, or N/A
- [ ] User-visible changes have a commit subject that the release notes pick up (`docs:` and `test:` commits are excluded), or N/A
