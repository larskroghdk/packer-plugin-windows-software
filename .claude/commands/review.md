---
description: Run the checks and the Codex review on the staged changes
---

Run, with a Bash timeout of 20 minutes:

```
pwsh -NoProfile -File scripts/ai/Invoke-CodexReview.ps1
```

Report the verdict and every finding with its severity and location. Fix critical and high findings, stage the fixes and run the review again. Don't write review records yourself.
