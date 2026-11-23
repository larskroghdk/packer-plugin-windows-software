---
name: code-review
description: Review requested changes for correctness, security, maintainability and test gaps.
---

# Code Review

Paths below are relative to the repository root.

Read `.agents/architecture/overview.md`, the relevant shared standards, the requested scope and current diff. Trace concrete failures at JSON, transport, cancellation, credential and recovery boundaries. Return findings with severity, location, trigger and consequence. Implement fixes only when requested. Use existing test seams; distinguish mocked tests from live guest verification.
