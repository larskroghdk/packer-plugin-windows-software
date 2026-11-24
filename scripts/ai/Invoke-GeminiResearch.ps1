#Requires -Version 7.2

<#
.SYNOPSIS
    Asks Gemini a read-only research or architecture question about the repository.

.DESCRIPTION
    Runs the Gemini CLI headless in plan mode, which is read-only, with JSON output.
    The question goes through standard input, never the command line.
    The working tree is fingerprinted before and after the call, and the script fails if any file changed, so a research run can never modify the repository unnoticed.

    Answers are cached per question, model and working-tree content (staged, unstaged and untracked files) for the configured number of days, so repeating a question costs nothing.
    Token counts, and costs when rates are configured in settings.psd1, are printed and logged to <git common dir>/ai/usage.jsonl.

    Gemini uses the authentication configured for the CLI.
    The pay-as-you-go setup reads the key from the GEMINI_API_KEY environment variable; it is never written to a file or a log.

.PARAMETER Question
    The research question.

.PARAMETER QuestionFile
    A file that holds the question.
    Use it for long questions or text that should not pass through a shell.

.PARAMETER Model
    A Gemini model that overrides the setting.

.PARAMETER Refresh
    Ignores a cached answer.

.EXAMPLE
    pwsh -NoProfile -File scripts/ai/Invoke-GeminiResearch.ps1 -QuestionFile question.md

.OUTPUTS
    System.String. Gemini's answer in Markdown.

.NOTES
    Author  : Lars Krogh
    Version : 1.1.0
#>


[CmdletBinding(DefaultParameterSetName = 'Text')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Text')]
    [string]$Question,
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$QuestionFile,
    [string]$Model,
    [switch]$Refresh
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentTools.ps1')

try {
    Assert-AINotNested
    $root = Get-AIRepositoryRoot
    $settings = Get-AIConfiguration -RepositoryRoot $root
    $gemini = Resolve-AICommand -Name $settings.Gemini.Command
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $Question = Get-Content -LiteralPath $QuestionFile -Raw
    }
    if ([string]::IsNullOrWhiteSpace($Question)) {
        throw 'The question is empty.'
    }
    if (-not $Model) {
        $Model = $settings.Gemini.Model
    }
    $workingTree = Get-AIWorkingTreeId -RepositoryRoot $root
    $keyText = "$Model`n$workingTree`n$Question"
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyText))).ToLowerInvariant()
    $cachePath = Join-Path (Get-AIStateDirectory -RepositoryRoot $root -Name 'research') "$key.json"
    if (-not $Refresh -and (Test-Path -LiteralPath $cachePath) -and (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddDays(-$settings.Gemini.CacheDays)) {
        $cached = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        Write-AIMessage "Cached Gemini answer from $($cached.answered_at) (use -Refresh to ask again)."
        Add-AIUsage -RepositoryRoot $root -Agent 'gemini' -Operation 'research-cached' -Usage @{ cache_key = $key }
        $cached.response
        exit 0
    }
    $prompt = @"
Research request from Claude, the lead developer of this repository. You are the research and architecture challenger. You only read: do not create, change or delete files, and do not run commands that change state.

Investigate the repository and, where it helps, official external documentation. Challenge the assumptions in the request instead of confirming them. Base each statement on evidence: a repository path with a line number, or a URL. Say when evidence is missing.

Answer in Markdown with these sections: Summary, Findings (each with its evidence), Risks, Recommendations (ranked, with trade-offs), Open questions.

<request>
$Question
</request>
"@
    $arguments = @('-p', 'Answer the research request given on standard input.', '--approval-mode', 'plan', '-o', 'json', '--skip-trust')
    if ($Model) {
        $arguments += @('-m', $Model)
    }
    $before = $workingTree
    $result = $null
    $failure = $null
    for ($attempt = 1; $attempt -le $settings.Gemini.MaxAttempts -and -not $result; $attempt++) {
        Write-AIMessage "Asking Gemini (attempt $attempt of $($settings.Gemini.MaxAttempts))"
        $started = [DateTime]::UtcNow
        $run = Invoke-AIProcess -FilePath $gemini -ArgumentList $arguments -InputText $prompt -WorkingDirectory $root -TimeoutSeconds $settings.Gemini.TimeoutSeconds -Agent
        $after = Get-AIWorkingTreeId -RepositoryRoot $root
        if ($after -ne $before) {
            $changed = @(Get-AIChangedPath -RepositoryRoot $root -Before $before -After $after)
            Add-AIUsage -RepositoryRoot $root -Agent 'gemini' -Operation 'research' -Usage @{ attempt = $attempt; violation = 'modified files'; files = $changed }
            throw "Gemini changed files during read-only research: $($changed -join ', '). Inspect and revert them."
        }
        $usage = @{ attempt = $attempt; seconds = [int]([DateTime]::UtcNow - $started).TotalSeconds; exit_code = $run.ExitCode; timed_out = $run.TimedOut }
        if ($run.TimedOut) {
            Add-AIUsage -RepositoryRoot $root -Agent 'gemini' -Operation 'research' -Usage $usage
            $failure = "Gemini timed out after $($settings.Gemini.TimeoutSeconds) seconds."
            break
        }
        try {
            $parsed = $run.StandardOutput | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $parsed = $null
        }
        if ($run.ExitCode -ne 0 -or -not $parsed -or -not $parsed.PSObject.Properties['response'] -or [string]::IsNullOrWhiteSpace($parsed.response)) {
            Add-AIUsage -RepositoryRoot $root -Agent 'gemini' -Operation 'research' -Usage $usage
            $detail = if ($parsed -and $parsed.PSObject.Properties['error']) { $parsed.error | ConvertTo-Json -Compress -Depth 4 } else { (($run.StandardError -split "`n") | Select-Object -Last 5) -join "`n" }
            $failure = "Gemini exited with code $($run.ExitCode): $detail"
            continue
        }
        $inputTokens = 0L
        $outputTokens = 0L
        $cachedTokens = 0L
        $models = @()
        if ($parsed.PSObject.Properties['stats'] -and $parsed.stats.PSObject.Properties['models']) {
            $models = @($parsed.stats.models.PSObject.Properties.Name)
            foreach ($entry in $parsed.stats.models.PSObject.Properties) {
                $tokens = $entry.Value.tokens
                $inputTokens += [long]$tokens.prompt
                $outputTokens += [long]$tokens.candidates + [long]$tokens.thoughts
                $cachedTokens += [long]$tokens.cached
            }
        }
        $cost = ($inputTokens * $settings.Gemini.InputUsdPerMillionTokens + $outputTokens * $settings.Gemini.OutputUsdPerMillionTokens) / 1000000
        $usage += @{ input_tokens = $inputTokens; output_tokens = $outputTokens; cached_tokens = $cachedTokens; estimated_usd = [Math]::Round($cost, 4); models = $models }
        Add-AIUsage -RepositoryRoot $root -Agent 'gemini' -Operation 'research' -Usage $usage
        $costText = if ($cost -gt 0) { ", estimated USD $([Math]::Round($cost, 4))" } else { '' }
        Write-AIMessage "Gemini used $inputTokens input and $outputTokens output tokens ($cachedTokens cached)$costText."
        $result = $parsed.response
    }
    if (-not $result) {
        throw "Gemini research failed. $failure"
    }
    $cache = [ordered]@{ question = $Question; model = $Model; working_tree = $workingTree; answered_at = [DateTime]::UtcNow.ToString('o'); response = $result }
    Set-Content -LiteralPath $cachePath -Value ($cache | ConvertTo-Json -Depth 3) -Encoding utf8NoBOM
    $result
    exit 0
}
catch {
    Write-AIMessage "Research failed: $($_.Exception.Message)"
    exit 1
}
