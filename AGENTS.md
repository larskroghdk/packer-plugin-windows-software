# Codex project instructions

This repository implements `windows-software`. Read the [project architecture and constraints](.agents/architecture/overview.md) and the owning module's AGENTS.md before editing. Existing invariants and domain-specific safeguards remain authoritative.

## Shared knowledge

- [Go standards](.agents/standards/go.md)
- [PowerShell standards](.agents/standards/powershell.md)
- [Testing requirements](.agents/standards/testing.md)
- [Security practices](.agents/standards/security.md)

## Skills

- `add-software-package`: [add-software-package](.agents/skills/add-software-package/SKILL.md).
- `code-review`: [code-review](.agents/skills/code-review/SKILL.md).
- `develop-windows-software`: [develop-windows-software](.agents/skills/develop-windows-software/SKILL.md).
- `go-development`: [go-development](.agents/skills/go-development/SKILL.md).
- `powershell-development`: [powershell-development](.agents/skills/powershell-development/SKILL.md).
- `publish-software-artifacts`: [publish-software-artifacts](.agents/skills/publish-software-artifacts/SKILL.md).
- `release-plugin`: [release-plugin](.agents/skills/release-plugin/SKILL.md).
- `run-packer-example`: [run-packer-example](.agents/skills/run-packer-example/SKILL.md).

Read only the relevant shared workflow. `.agents/skills` is the single source of skill instructions, not a general Codex configuration directory. See [agent guidance](docs/agent-guidance.md). Skill activation grants no additional publication or guest-operation authority.
