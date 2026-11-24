#Requires -Version 7.2

<#
.SYNOPSIS
    Has GitHub Copilot update documentation or GitHub automation, within a fixed scope.

.DESCRIPTION
    Runs the Copilot CLI headless with file writes allowed only for the WriteRules in settings.psd1 (Markdown, docs/ and .github/), and with commit, push, tag, reset, rebase, checkout, gh and .git writes denied.
    Copilot cannot run other state-changing commands, because nothing else is allowed and it cannot ask.

    The script holds the agent write lock while Copilot runs, so no second writing agent and no commit can start.
    Afterwards it verifies that HEAD did not move and that every changed file matches AllowedPathPatterns, and fails otherwise.
    The changes stay uncommitted for Claude to inspect; the pre-commit gate sends them to Codex like any other change.

.PARAMETER Task
    What Copilot should do.

.PARAMETER TaskFile
    A file that holds the task. Use it for long tasks or text that should not pass through a shell.

.EXAMPLE
    pwsh -NoProfile -File scripts/ai/Invoke-CopilotMaintenance.ps1 -TaskFile task.md

.OUTPUTS
    System.String. Copilot's reply.

.NOTES
    Author  : Lars Krogh
    Version : 1.0.0
#>


[CmdletBinding(DefaultParameterSetName = 'Text')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Text')]
    [string]$Task,
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$TaskFile
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentTools.ps1')

try {
    Assert-AINotNested
    $root = Get-AIRepositoryRoot
    $settings = Get-AIConfiguration -RepositoryRoot $root
    $copilot = Resolve-AICommand -Name $settings.Copilot.Command
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $Task = Get-Content -LiteralPath $TaskFile -Raw
    }
    if ([string]::IsNullOrWhiteSpace($Task)) {
        throw 'The task is empty.'
    }
    $lock = Enter-AIWriteLock -RepositoryRoot $root
    $work = Join-Path ([IO.Path]::GetTempPath()) ("ai-copilot-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work
    try {
        $taskPath = Join-Path $work 'task.md'
        $usagePath = Join-Path $work 'usage.json'
        $scope = $settings.Copilot.AllowedPathPatterns -join ', '
        Set-Content -LiteralPath $taskPath -Encoding utf8NoBOM -Value @"
You are the documentation and GitHub automation maintainer of this repository. Claude, the lead developer, gives you this task. Follow AGENTS.md and .github/copilot-instructions.md.

Change only files that match: $scope. Do not commit, push, tag or change Git state. If the task needs a change outside that scope, or a decision about the implementation, make no such change and say what Claude has to do instead. End with a list of the files you changed.

<task>
$Task
</task>
"@
        $arguments = @('-p', "Do the task described in the file $taskPath.", '-s', '--no-ask-user', '--no-auto-update', '--usage-output-file', $usagePath)
        foreach ($rule in $settings.Copilot.WriteRules) {
            $arguments += @('--allow-tool', "write($rule)")
        }
        foreach ($rule in $settings.Copilot.DenyTools) {
            $arguments += @('--deny-tool', $rule)
        }
        if ($settings.Copilot.Model) {
            $arguments += @('--model', $settings.Copilot.Model)
        }
        if ($settings.Copilot.MaxAiCredits -gt 0) {
            $arguments += @('--max-ai-credits', [string]$settings.Copilot.MaxAiCredits)
        }
        $headBefore = Invoke-AIGit -ArgumentList 'rev-parse', '--verify', '--quiet', 'HEAD' -WorkingDirectory $root -AllowFailure
        $before = Get-AIWorkingTreeId -RepositoryRoot $root
        Write-AIMessage 'Running Copilot'
        $started = [DateTime]::UtcNow
        $run = Invoke-AIProcess -FilePath $copilot -ArgumentList $arguments -WorkingDirectory $root -TimeoutSeconds $settings.Copilot.TimeoutSeconds -Agent
        $after = Get-AIWorkingTreeId -RepositoryRoot $root
        $headAfter = Invoke-AIGit -ArgumentList 'rev-parse', '--verify', '--quiet', 'HEAD' -WorkingDirectory $root -AllowFailure
        $changed = @(Get-AIChangedPath -RepositoryRoot $root -Before $before -After $after)
        $outside = @($changed | Where-Object { -not (Test-AIPathMatch -Path $_ -Pattern $settings.Copilot.AllowedPathPatterns) })
        $usage = @{ seconds = [int]([DateTime]::UtcNow - $started).TotalSeconds; exit_code = $run.ExitCode; timed_out = $run.TimedOut; files = $changed }
        if (Test-Path -LiteralPath $usagePath) {
            $report = Get-Content -LiteralPath $usagePath -Raw | ConvertFrom-Json
            foreach ($name in 'totalPremiumRequestCost', 'totalNanoAiu') {
                if ($report.PSObject.Properties[$name]) {
                    $usage[$name] = $report.$name
                }
            }
            if ($report.PSObject.Properties['tokenDetails']) {
                $usage['input_tokens'] = $report.tokenDetails.input.tokenCount
                $usage['output_tokens'] = $report.tokenDetails.output.tokenCount
            }
        }
        Add-AIUsage -RepositoryRoot $root -Agent 'copilot' -Operation 'maintenance' -Usage $usage
        if ($headAfter -ne $headBefore) {
            throw "Copilot moved HEAD from $headBefore to $headAfter. Inspect the new commits and reset them."
        }
        if ($outside.Count -gt 0) {
            throw "Copilot changed files outside its scope: $($outside -join ', '). Inspect and revert them."
        }
        if ($run.TimedOut) {
            throw "Copilot timed out after $($settings.Copilot.TimeoutSeconds) seconds. Changed so far: $($changed -join ', ')"
        }
        if ($run.ExitCode -ne 0) {
            throw "Copilot exited with code $($run.ExitCode): $((($run.StandardError -split "`n") | Select-Object -Last 5) -join "`n")"
        }
        Write-AIMessage "Copilot changed: $(if ($changed) { $changed -join ', ' } else { 'nothing' })"
        $run.StandardOutput.Trim()
    }
    finally {
        $lock.Dispose()
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}
catch {
    Write-AIMessage "Copilot maintenance failed: $($_.Exception.Message)"
    exit 1
}
