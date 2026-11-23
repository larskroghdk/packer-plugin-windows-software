# Agent guidance

How the instruction files are laid out and how each coding agent finds them.

| File | Owns | Loaded by |
| --- | --- | --- |
| [AGENTS.md](../AGENTS.md) | Module map, coding rules, checks, skill index | Codex natively; Claude Code through `@AGENTS.md`; Copilot through a link |
| `.agents/skills/<name>/SKILL.md` | Task procedures (`develop-windows-software`, `add-software-package`, `publish-software-artifacts`, `run-packer-example`, `release-plugin`) | Codex as repository skills; others read the file explicitly |
| [CLAUDE.md](../CLAUDE.md) | Imports the root files and adds Claude-only notes | Claude Code |
| `.claude/agents/*.md` | Three read-only reviewer subagents | Claude Code |
| `.claude/settings.json` | Permissions: allows the checks, asks before publishing or touching a VM | Claude Code |
| [.github/copilot-instructions.md](../.github/copilot-instructions.md) | Points Copilot at AGENTS.md | GitHub Copilot |

Each rule has one home. Don't copy rules into a skill or a tool-specific file. Link to them instead.

Claude Code's native skill directory is `.claude/skills`. This repository doesn't keep one, because a second copy of each skill would drift. Claude therefore reads skills as files and doesn't offer them as `/` commands. No MCP servers or hooks are configured for the project.

## Checking a change

- Each skill needs `name` (equal to its folder name) and `description` frontmatter.
- Every local Markdown link and every `@` import in `CLAUDE.md` must resolve.
- `test/pester/AgentConfiguration.Tests.ps1` checks the skill frontmatter, the skill index in AGENTS.md, the CLAUDE.md imports, the reviewers and the repository paths named in the agent documents.
- Check Codex discovery without a model turn: send `initialize` and then `skills/list` with the repository as `cwds` to `codex app-server`. Every skill should come back with `scope: repo` and no errors.
- In Claude Code, the three reviewers should appear in `/agents`.

These checks show that the files are found. They don't show that a model will pick or follow the right skill.
