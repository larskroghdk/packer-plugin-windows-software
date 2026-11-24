---
description: Have Copilot update documentation or GitHub automation
argument-hint: <task>
---

Write the task below to a new file in your scratchpad directory. Include the facts Copilot needs from the code change, because it shouldn't have to infer the implementation. Then run:

```
pwsh -NoProfile -File scripts/ai/Invoke-CopilotMaintenance.ps1 -TaskFile <that file>
```

Use a Bash timeout of 20 minutes. Read `git diff` of every file Copilot changed and correct anything inaccurate. Copilot's changes stay uncommitted; they go through the Codex review with the rest of the changeset. If the script reports out-of-scope changes, inspect and revert them.

Task:

$ARGUMENTS
