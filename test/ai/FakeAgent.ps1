#Requires -Version 7.2

<#
.SYNOPSIS
    Stands in for the codex, gemini and copilot CLIs in the agent workflow tests.

.DESCRIPTION
    The first argument names the agent; the rest are the arguments the workflow passed.
    They are read from $args, unbound, so options such as -p reach the fake unchanged.
    Each call is appended to the file named by FAKE_AGENT_LOG.
    FAKE_CODEX_MODE, FAKE_GEMINI_MODE and FAKE_COPILOT_MODE choose the behavior, so a test can produce approvals, rejections, malformed answers, failures, timeouts, out-of-scope changes and commit attempts without any network access.

.EXAMPLE
    pwsh -File FakeAgent.ps1 codex exec --sandbox read-only

.NOTES
    Author  : Lars Krogh
    Version : 1.0.0
#>


$ErrorActionPreference = 'Stop'

$Agent = [string]$args[0]
$Arguments = [string[]]@($args | Select-Object -Skip 1)

function Get-ArgumentValue {
    <#
    .SYNOPSIS
        Returns the value that follows an option.

    .DESCRIPTION
        Finds the first occurrence of the option and returns the next argument, or $null.

    .PARAMETER Name
        The option, for example -o.

    .EXAMPLE
        Get-ArgumentValue -Name '-o'

    .OUTPUTS
        System.String

    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) { $Arguments[$index + 1] } else { $null }
}

if ($env:FAKE_AGENT_LOG) {
    Add-Content -LiteralPath $env:FAKE_AGENT_LOG -Value ("$Agent " + ($Arguments -join ' ')) -Encoding utf8NoBOM
}
if ($Arguments -contains '--version') {
    "$Agent fake 1.0.0"
    exit 0
}
if ($Agent -eq 'codex' -and $Arguments.Count -ge 2 -and $Arguments[0] -eq 'login') {
    'Logged in (fake)'
    exit 0
}
$stdin = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }

switch ($Agent) {
    'codex' {
        $mode = if ($env:FAKE_CODEX_MODE) { $env:FAKE_CODEX_MODE } else { 'approve' }
        $output = Get-ArgumentValue -Name '-o'
        $finding = @{ severity = 'high'; file = 'main.txt'; line = 1; title = 'Fake defect'; impact = 'Breaks things.'; remediation = 'Fix it.' }
        switch ($mode) {
            'approve' { $review = @{ verdict = 'approve'; summary = 'Looks correct.'; findings = @() } }
            'approve-and-stage' {
                Set-Content -LiteralPath (Join-Path $env:FAKE_STAGE_REPO 'late.txt') -Value 'staged during review'
                $null = & git -C $env:FAKE_STAGE_REPO add -- late.txt
                $review = @{ verdict = 'approve'; summary = 'Looks correct.'; findings = @() }
            }
            'approve-with-high' { $review = @{ verdict = 'approve'; summary = 'Approved anyway.'; findings = @($finding) } }
            'reject' { $review = @{ verdict = 'reject'; summary = 'Has a defect.'; findings = @($finding) } }
            'malformed' { Set-Content -LiteralPath $output -Value '{"verdict":"maybe","summary":"unsure","findings":[]}'; exit 0 }
            'fail' { [Console]::Error.WriteLine('401 Unauthorized: not logged in'); exit 1 }
            'hang' { Start-Sleep -Seconds 60; exit 0 }
        }
        if ($stdin -notmatch '<diff>') {
            [Console]::Error.WriteLine('no diff on standard input')
            exit 2
        }
        Set-Content -LiteralPath $output -Value ($review | ConvertTo-Json -Depth 4) -Encoding utf8NoBOM
        [Console]::Error.WriteLine("tokens used`n1,234")
        exit 0
    }
    'gemini' {
        $mode = if ($env:FAKE_GEMINI_MODE) { $env:FAKE_GEMINI_MODE } else { 'answer' }
        switch ($mode) {
            'modify' { Set-Content -LiteralPath 'gemini-was-here.txt' -Value 'changed' }
            'fail' { '{"error":{"type":"AuthError","message":"API key not valid"}}'; exit 41 }
        }
        @{ response = "## Summary`nFake research answer."; stats = @{ models = @{ 'fake-model' = @{ tokens = @{ prompt = 1000; candidates = 200; thoughts = 50; cached = 100 } } } } } | ConvertTo-Json -Depth 6
        exit 0
    }
    'copilot' {
        $mode = if ($env:FAKE_COPILOT_MODE) { $env:FAKE_COPILOT_MODE } else { 'docs' }
        $usage = Get-ArgumentValue -Name '--usage-output-file'
        switch ($mode) {
            'docs' { $null = New-Item -ItemType Directory -Path 'docs' -Force; Set-Content -LiteralPath 'docs/fake.md' -Value '# Fake' }
            'outside' { Set-Content -LiteralPath 'main.txt' -Value 'changed by copilot' }
            'commit' { Set-Content -LiteralPath 'docs.md' -Value 'x'; & git add docs.md; & git -c core.hooksPath=/dev/null commit -q -m 'copilot commit' }
            'fail' { [Console]::Error.WriteLine('Copilot request failed'); exit 1 }
        }
        if ($usage) {
            Set-Content -LiteralPath $usage -Value '{"totalPremiumRequestCost":1,"tokenDetails":{"input":{"tokenCount":10},"output":{"tokenCount":5}}}'
        }
        'Done.'
        exit 0
    }
}
