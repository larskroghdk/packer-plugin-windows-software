# AI-assisted development

Four agent CLIs work on this repository with fixed roles. The rules for agents are in [AGENTS.md](../AGENTS.md#agent-workflow); this page covers setup, the scripts, enforcement and troubleshooting.

```text
Claude Code (lead) ──▶ Gemini (on-demand research, read-only)
       │           ──▶ Copilot (docs and .github, scoped writes)
       ▼
deterministic checks ──▶ Codex review (pre-commit) ──▶ commit ──▶ pre-push check ──▶ CI
```

## Setup

| Tool | Version tested | Install | Authenticate |
| --- | --- | --- | --- |
| PowerShell | 7.2 or later | `winget install Microsoft.PowerShell` | — |
| Codex CLI | 0.167.0 | See the [Codex CLI docs](https://developers.openai.com/codex/cli) | `codex login` |
| Gemini CLI | 0.67.0 | `npm install -g @google/gemini-cli` | Set `GEMINI_API_KEY` as a user environment variable (pay-as-you-go key) |
| Copilot CLI | 1.0.114 | `npm install -g @github/copilot` | Run `copilot` once and sign in |
| Pester | 5.6.1 or later | `Install-Module Pester -RequiredVersion 5.6.1 -Scope CurrentUser` | — |

Then, from the repository root:

```powershell
pwsh -NoProfile -File scripts/ai/Invoke-AgentWorkflow.ps1 -Stage InstallHooks
pwsh -NoProfile -File scripts/ai/Test-AgentEnvironment.ps1 -Live
```

`Test-AgentEnvironment.ps1` checks installation, versions, authentication and the hooks without printing credentials. `-Live` sends one short prompt to each agent. Codex and the hooks are required; Gemini and Copilot are optional, and only their scripts fail without them.

Never put a key in the repository, in `settings.psd1` or on a command line. The scripts pass prompts on standard input or in temporary files, and the usage log holds counts only.

## Scripts

All scripts are in `scripts/ai`, need PowerShell 7.2, and read their limits from [settings.psd1](../scripts/ai/settings.psd1).

| Script | Does |
| --- | --- |
| `Invoke-CodexReview.ps1 [-Commit <sha>] [-Force]` | Runs the matching checks and the Codex review on the staged changes or one commit, and stores the result |
| `Invoke-AgentWorkflow.ps1 -Stage PreCommit\|PrePush\|Status\|InstallHooks` | The hook entry points, the approval status of the staged changes, and hook installation |
| `Invoke-GeminiResearch.ps1 -Question <text> \| -QuestionFile <path>` | Read-only research with caching and token accounting |
| `Invoke-CopilotMaintenance.ps1 -Task <text> \| -TaskFile <path>` | Documentation and `.github/` changes with enforced scope |
| `Test-AgentEnvironment.ps1 [-Live]` | Readiness report |

In Claude Code, `/research`, `/docs` and `/review` run the first, third and fourth scripts.

### Codex review

The pre-commit hook identifies the staged changeset by two Git trees: the tree of `HEAD` and the tree of the index. It exports the index tree with `git archive` into a temporary directory, so unstaged edits and untracked files are neither checked nor reviewed. There it runs every check from `settings.psd1` whose path patterns match a changed file, stopping at the first failure. When all pass, it runs `codex exec --sandbox read-only --ephemeral` in the snapshot with [review-prompt.md](../scripts/ai/review-prompt.md), the diff on standard input and [review-schema.json](../scripts/ai/review-schema.json) as the required output format. The settings, prompt and schema are read from the snapshot, not the working tree, so unstaged edits can't remove a check, change the blocking severities or alter the reviewer's instructions. A change to those files is part of the reviewed diff, and the response must match the schema exactly, with no missing or extra fields and no wrong types.

The changeset is approved only when the verdict is `approve` and no finding is critical or high. The policy is applied by the script, not taken from Codex. A non-zero exit code, a timeout, a missing CLI or an answer that does not match the schema blocks the commit; nothing approves by default. Each completed review is stored as `.git/ai/reviews/<base tree>-<result tree>.json`. A record approves only its own changeset, so any change to the staged content needs a new review, and committing the same content again does not.

Diffs over `MaxDiffBytes` are refused; split the commit.

### Pre-push

The pre-push hook lists the outgoing commits and requires approving records that lead from each commit's first parent tree to its tree. Usually that is the commit's own record. An amended commit is covered by the chain of the original commit's record and the amendment's record, which the pre-commit hook created; each of those reviews saw the complete resulting tree. The hook never starts a review. Commits made with `--no-verify`, and rebases that changed a commit's parent, need `Invoke-CodexReview.ps1 -Commit <sha>` before they can be pushed. Merge commits need approval too, because a merge tree can contain conflict resolutions that no branch review saw. A merge concluded with `git commit` after a conflict is reviewed by the pre-commit hook. Git runs `pre-merge-commit`, not `pre-commit`, for an automatic merge, so review that merge with `Invoke-CodexReview.ps1 -Commit <sha>` before pushing it.

### Gemini research

Gemini runs headless with `--approval-mode plan` (read-only), `-o json` and `--skip-trust`, which trusts this workspace for that session only. It reads [GEMINI.md](../GEMINI.md), which imports AGENTS.md. The script fingerprints the working tree before and after with a temporary index and fails if any file changed. Answers are cached in `.git/ai/research` per question, model and working-tree content for `CacheDays`, so any local edit asks again. Token counts are always logged. Set `InputUsdPerMillionTokens` and `OutputUsdPerMillionTokens` to your model's prices to get cost estimates; they are 0 by default because prices change.

### Copilot maintenance

Copilot runs headless with `--no-ask-user`, writes allowed only for `WriteRules`, and `DenyTools` (commit, push, tag, reset, rebase, checkout, `gh`, `.git` writes) denied. Deny rules win over allow rules, and without a prompt any other state-changing command is refused. The script holds `.git/ai/agent.lock` during the run, which blocks a second writing agent and the pre-commit hook. Afterwards it fails if `HEAD` moved or a file outside `AllowedPathPatterns` changed. Copilot's changes stay uncommitted and are reviewed by Codex with the rest of the changeset. Premium requests and tokens are logged.

### Loops, retries and costs

- Every agent process gets `AI_AGENT_ACTIVE=1`. The scripts and hooks refuse to run when it is set, so an agent cannot start another agent or commit through the hooks.
- Each call has a timeout and at most `MaxAttempts` attempts. A timeout is not retried.
- `.git/ai/usage.jsonl` has one line per call with tokens, premium requests, duration and outcome. Summarize it with:

  ```powershell
  Get-Content .git/ai/usage.jsonl | ConvertFrom-Json | Group-Object agent | Select-Object Name, Count
  ```

- Gemini and Copilot run only when Claude asks them. Codex runs once per distinct staged changeset.

## Enforcement and its limits

Local hooks are a safety net. `git commit --no-verify`, another `core.hooksPath` or an edited review record bypasses them, and the records are not signed. `.claude/settings.json` denies these bypasses to Claude Code, but that only governs Claude.

The authoritative controls are on GitHub:

- `ci.yml` runs the repository checks on every push and pull request, and its `agent-workflow` job analyzes and tests the agent scripts. CI does not trust local review records.
- Protect `main` so that changes arrive through pull requests with the `go (ubuntu-latest)`, `go (windows-2025)`, `powershell`, `agent-workflow` checks passing. This is a repository setting that needs an administrator. To create the ruleset:

  ```powershell
  gh api --method POST repos/larskroghdk/packer-plugin-windows-software/rulesets --input ruleset.json
  ```

  with `ruleset.json`:

  ```json
  {
    "name": "main",
    "target": "branch",
    "enforcement": "active",
    "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
    "rules": [
      { "type": "deletion" },
      { "type": "non_fast_forward" },
      { "type": "pull_request", "parameters": { "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": true } },
      { "type": "required_status_checks", "parameters": { "strict_required_status_checks_policy": true, "required_status_checks": [
      { "context": "go (ubuntu-latest)" },
      { "context": "go (windows-2025)" },
      { "context": "powershell" },
      { "context": "agent-workflow" }
    ] } }
    ]
  }
  ```

- An independent Codex review in CI needs an OpenAI API key as a repository secret, because the local CLI uses a ChatGPT login. The repository has no such secret, so CI doesn't run one.

## Testing the workflow

`Invoke-Pester -Path test/ai` under PowerShell 7 runs [test/ai/AgentWorkflow.Tests.ps1](../test/ai/AgentWorkflow.Tests.ps1). Each test builds a throwaway repository with a bare remote in Pester's TestDrive and puts [FakeAgent.ps1](../test/ai/FakeAgent.ps1) on PATH as `codex`, `gemini` and `copilot`. The tests make real commits and pushes and cover approval, rejection, a high finding with an approve verdict, Codex failure, malformed answers, timeouts, a missing CLI, failing checks, unstaged edits, approval reuse and invalidation, nested agents, the write lock, pushes with missing or rejected reviews, Gemini plan mode, caching, file changes and API errors, Copilot scope, deny rules and commits, and the environment check. They make no network calls.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `pre-commit blocked: PowerShell 7 (pwsh) is required` | Install PowerShell 7 and make sure `pwsh` is on PATH for Git's shell. |
| `codex is not installed or not on PATH` | Install the Codex CLI, or set `Codex.Command` in `settings.psd1`. |
| `Codex exited with code 1: ... 401` | Run `codex login`. |
| `Codex timed out` | Large changesets take longer. Split the commit, or raise `Codex.TimeoutSeconds`. |
| `Check '<name>' failed` | Run the check locally (the commands in the Checks section of AGENTS.md) and fix it. Checks run on the staged snapshot, so stage the fix. |
| `These commits have no approving Codex review` on push | Run `Invoke-CodexReview.ps1 -Commit <sha>` for each listed commit. |
| Hooks don't run on Linux or macOS | The hooks must be executable; they are stored with mode 100755. Check `ls -l .githooks`. |
| `Another agent is changing files` | A Copilot run is in progress. If none is, the lock is stale; it is removed automatically when no process holds it. |
| `started by an agent process` | An agent tried to commit or start another agent. Return the result to Claude and commit from there. |
| Gemini exits with code 55 | The workspace is not trusted; the script passes `--skip-trust`, so check that you run a current Gemini CLI. |
| `Gemini changed files during read-only research` | Inspect `git status`, revert the listed files and report the run. |
