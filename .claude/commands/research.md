---
description: Ask Gemini a read-only research or architecture question
argument-hint: <question>
---

Write the question below to a new file in your scratchpad directory, then run:

```
pwsh -NoProfile -File scripts/ai/Invoke-GeminiResearch.ps1 -QuestionFile <that file>
```

Use a Bash timeout of 15 minutes. Evaluate the answer against the code before acting on it: check the cited evidence, say where you disagree, and tell the user which recommendations you adopt and why. If the script fails, report the error; don't retry more than once.

Question:

$ARGUMENTS
