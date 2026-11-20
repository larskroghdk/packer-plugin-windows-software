---
name: publish-software-artifacts
description: Change or troubleshoot the windows-software artifact pipeline - cmd/resolve-installers, internal/resolver, scripts/validate-artifacts.ps1, scripts/publish-artifacts.ps1 and the publish-software-artifacts and release workflows. Use for winget resolution, release asset immutability, catalog commits, workflow permissions or a failed publication run.
---

# Publish software artifacts

The pipeline runs in `.github/workflows/publish-software-artifacts.yml` (daily schedule and manual dispatch, one serialized concurrency group) on a Windows runner:

1. `go run ./cmd/resolve-installers -package <id|all>` (`internal/resolver`) reads winget-pkgs through the GitHub API by immutable tree and blob, picks the newest stable version with a compatible x64 machine installer, enforces the recipe's host and path allowlist, and downloads with SHA-256 verification into `artifacts/`. `GH_TOKEN` goes only to the API host.
2. `scripts/validate-artifacts.ps1` dot-sources `guest/Install.ps1` to require the hash, a valid Authenticode signature, an allowed signer and an embedded version equal to the candidate, then writes `<id>-catalog.json` with `validated_at`.
3. `scripts/publish-artifacts.ps1` creates release `software/<id>/<version>` as a draft with the catalog record and SHA256SUMS (the installer only when `redistribution_approved`), publishes it, then commits new records to `packages/catalog.json` through the Contents API using the checked-out file's blob SHA.

Review the three steps and the workflow together; a valid workflow can still fail in its scripts.

## Invariants

- Versions are immutable. An existing catalog version must keep its hash; published release assets are never replaced or deleted. An interrupted draft is completed; an incomplete published release fails.
- The catalog write must fail on concurrent change (HTTP 409), never overwrite. Do not switch to fetching the remote SHA just before writing.
- Vendor-only packages never upload installer bytes, not even as Actions artifacts. A moving vendor URL that serves different bytes fails the hash; keep the old record.
- Workflow permissions stay `contents: read` except the publishing job. Pass inputs through `env`, never `${{ }}` inside `run`. Pin actions to full commit SHAs with a version comment. Reference a GitHub environment only when it exists or the user asks for one.
- `release.yml` builds the plugin with GoReleaser on `v*` tags as a draft; the binary name embeds the API version from `describe`.

## Verify

```powershell
go test ./internal/resolver/ ./internal/catalog/
actionlint
Invoke-ScriptAnalyzer -Path scripts -Severity Warning, Error
```

A local resolve plus validate run (see the `add-software-package` skill) exercises real downloads and signatures without installing. `publish-artifacts.ps1` needs `GH_TOKEN`, `GITHUB_REPOSITORY` and `GITHUB_REF_NAME` and writes to GitHub; run it, dispatch the workflow, push tags or create releases only when the user explicitly asks in the current task.
