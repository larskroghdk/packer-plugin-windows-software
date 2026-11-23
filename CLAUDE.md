# Claude Code project instructions

@AGENTS.md

## Claude-specific

- Skills live in `.agents/skills`, not `.claude/skills`, so they aren't offered as `/` commands. Read the matching `SKILL.md` explicitly when a task fits one.
- `.claude/agents` holds three read-only reviewer subagents (`go-reviewer`, `powershell-reviewer`, `security-reviewer`). They return findings to the parent and never edit files, run guest operations or publish.
- `.claude/settings.json` allows the read-only checks and asks before pushing, tagging, releasing, dispatching workflows, building with Packer or publishing artifacts.
