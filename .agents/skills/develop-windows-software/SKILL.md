---
name: develop-windows-software
description: Develop and troubleshoot this repository's native Packer windows-software provisioner, package manifests, PowerShell installation engine, and GitHub artifact workflows. Use for changes to packer-plugin-windows-software, not general Windows administration or installing software on the developer workstation.
---

# Develop windows-software

Read the repository's `AGENTS.md` and inspect the working tree before editing. Preserve concurrent user changes. Resolve repository paths from the project root; this skill lives at `.agents/skills/develop-windows-software/SKILL.md`.

## Find the relevant contract

- `main.go` registers the SDK default provisioner; Packer exposes it as `windows-software`. Keep `describe`, release binary naming and the SDK protocol consistent.
- `provisioner/config.go` owns SDK configuration decoding and the HCL2 spec. Update both when changing options. `packages` order is installation order; `versions` contains exact pins or `latest-validated`.
- `provisioner/` orchestrates host downloads, WinRM transfers, JSON guest actions and host reports. Reuse the builder's communicator; do not create another WinRM client or transfer GitHub credentials into the guest.
- `internal/catalog/` owns strict validated-record decoding, numeric version selection and streamed SHA-256 verification. Unknown, missing, duplicate or unvalidated records fail before installation.
- `guest/Install.ps1` is embedded. Keep it compatible with Windows PowerShell 5.1, with top-level functions and useful comment-based help. Review both dispatch behavior and helper behavior when changing it.
- `packages/<id>.json` contains acquisition and installation policy; `packages/catalog.json` contains validated versions. Put vendor versions and URLs in data, never Go source. Ordinary EXE/MSI packages should need only a recipe.

Read `README.md` for supported options and storage behavior. Read `docs/sources.md` when changing vendor compatibility, acquisition or licensing assumptions. Check the current implementation rather than assuming a documented feature already works.

## Preserve the installation boundary

Verify SHA-256 on the host and again in the guest. Require Windows Authenticode status `Valid` and an exact allowed certificate identity before execution. Do not weaken either check to accommodate a failed download or certificate rotation.

Use registry or executable metadata for detection, never `Win32_Product`. Compare numeric versions consistently, including leading zeros and omitted trailing zero components. Explicit pins must not silently accept a different installed version. Verify the installed version after installation.

Return OS family, build, native architecture and Server Core status from detection. Keep their JSON fields aligned with Go structs and package eligibility checks. GUI applications require Desktop Experience; do not infer that all Windows Server editions support them.

Suppress installer restarts. Preserve exit codes and reboot observations; 1641 means the installer initiated a restart and must fail the build. Leave actual restarts to the Packer build. Timeouts must not become successful package results or trigger blind installer retries. Keep cancellation and transport failures as build failures even when optional package failures may continue.

Keep temporary files inside the generated per-run host/guest directories. Cleanup must not expand its roots, traverse reparse points or remove unrelated data. Write the requested host report on failure paths and preserve package errors, selected sources and final observed versions.

## Change acquisition and publishing

Inspect `scripts/resolve.py`, `scripts/validate-artifacts.ps1` and `scripts/publish-artifacts.ps1` together with the workflow. A syntactically valid workflow can still fail in its scripts.

Select an actually supported stable installer format; a newer MSIX-only upstream version does not satisfy an MSI recipe. Download only from reviewed official hosts and verify the independently recorded hash. Investigate changed vendor hosts using official documentation before adjusting allowlists.

Recipes default to vendor-only downloads. Upload installer bytes to GitHub only when the package's redistribution approval is established. Keep versioned release assets immutable, preserve old records, and recover interrupted publication without overwriting known-good assets. A moving vendor URL cannot guarantee historical availability; retain its hash and fail if the bytes change.

Keep reusable workflow inputs declared and typed. Pass manual inputs through environment variables rather than interpolating them into shell code. Grant write permissions only to publishing jobs. Do not reference a GitHub environment unless it exists or the user explicitly requests that setup; concurrency groups do not require an environment.

Editing automation does not itself authorize running a publication, pushing commits, creating releases or installing software. Follow the user's current task scope for those external actions.

## Verify the affected behavior

Use focused checks first, then run the repository checks required by `AGENTS.md`:

```powershell
./scripts/check.ps1
staticcheck ./...
python -m unittest discover -s test -p 'test_*.py'
Invoke-Pester -Path test/pester
packer fmt -check examples
```

Use the dependency versions in `go.mod` and `scripts/requirements.txt`. Install Python dependencies in a local virtual environment. Use Actionlint when changing workflows, and PowerShell parsing/PSScriptAnalyzer when available. For restricted Pester sessions, disable the unused TestRegistry plugin through Pester configuration rather than requesting access to real registry keys; retain isolated TestDrive fixtures.

Cover the changed observable behavior: malformed manifests, artifact lookup/hash failures, signature and publisher rejection, detection/version comparison, upgrades, silent arguments, exit codes, reboot handling, failure reporting or SDK communicator integration as applicable. Mocks prove protocol behavior, not actual installation compatibility.

Download/signature validation may run without installing software. Run installation smoke tests only against an explicitly selected disposable Windows VM using `examples/windows-software.pkr.hcl`. Never run the package engine against the development workstation. State which checks actually ran, what failed or was blocked, and whether live Windows installation or GitHub publication was exercised.
