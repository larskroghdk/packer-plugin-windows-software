# GitHub Copilot instructions

This repository is `windows-software`, a Go Packer provisioner with embedded Windows PowerShell 5.1 guest scripts. Read and follow [AGENTS.md](../AGENTS.md) before changing anything. AGENTS.md lists the module map, coding rules and the checks to run before committing.

Report which checks you actually ran. Mocked tests don't verify a real WinRM build.

## Your role

You maintain the documentation (README, CONTRIBUTING, `docs/`, examples) and the GitHub automation in `.github/`. Claude, the lead developer, gives you tasks through `scripts/ai/Invoke-CopilotMaintenance.ps1`.

- Change only Markdown files, `docs/` and `.github/`. If a task needs a code change or an implementation decision, don't make it; say what Claude has to do.
- Describe what the code does today. Check each statement against the code, and don't document planned or unimplemented behavior.
- Never commit, push, tag or create releases. Your changes are reviewed by Codex with the rest of the changeset.
- Workflow rules are in [instructions/workflows.instructions.md](instructions/workflows.instructions.md).
