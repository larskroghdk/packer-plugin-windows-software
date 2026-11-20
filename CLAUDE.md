@AGENTS.md

## Claude Code

`AGENTS.md` and `.agents/skills/` are the shared instructions for Claude Code and Codex. `.claude/skills/<name>/SKILL.md` only points Claude Code at `.agents/skills/<name>/SKILL.md`, with an identical `name` and `description`. When adding or changing a skill, edit the `.agents` copy and keep the pointer's frontmatter in sync; `test/pester/AgentConfiguration.Tests.ps1` enforces this.

`.claude/settings.json` asks before publishing, pushing or running a Packer build. Personal overrides belong in `.claude/settings.local.json`, which is not committed.
