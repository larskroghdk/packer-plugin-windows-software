# Agent guidance ownership

AGENTS.md is the Codex instruction entrypoint; CLAUDE.md is the Claude Code entrypoint. Both route to the same standards, architecture and reusable skills under .agents. Keep hard constraints in their existing authoritative source; keep executable checks in the existing scripts, Makefile and CI.

Claude-specific reviewers live in .claude/agents with read-only tools. Existing settings remain tool-specific. There are no duplicate .claude/skills adapters. Claude reads shared workflows through explicit file references; its documented native skill location is .claude/skills, so slash-command discovery is not promised. See [Claude skill locations](https://code.claude.com/docs/en/skills#choose-where-skills-load) and [reviewer format](https://code.claude.com/docs/en/sub-agents).

Validate frontmatter, local links, imports and project checks when changing this structure. Structural validation does not establish model behavior, native reviewer invocation or live guest compatibility.
