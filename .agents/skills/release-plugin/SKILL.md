---
name: release-plugin
description: Prepare, debug and verify CI, GoReleaser packaging and authorized signed plugin releases.
---

# Release Plugin

Paths below are relative to the repository root.

Read `.github/workflows/release.yml`, the reusable check workflow, `.goreleaser.yml` or `.goreleaser.yaml`, and go.mod. Run project checks and generated-schema checks where defined. Use prebuilt pinned GoReleaser; build the API probe outside the checkout and derive API_VERSION from describe. Keep unsigned snapshots independent of secrets. Before authorized publication, verify the candidate, tag, existing assets and both signing-secret names. Never move tags or replace published assets without explicit authorization. Watch the release workflow, verify six ZIP checksums and the detached signature against the intended key, and run describe on a local-host binary. Vendor software releases and live guest operations require their own authorization.
