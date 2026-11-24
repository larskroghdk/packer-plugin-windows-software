#Requires -Version 7.2
<#
.SYNOPSIS
    Reports whether the agent CLIs, their authentication and the Git hooks are ready.

.DESCRIPTION
    Checks each agent CLI named in settings.psd1 for installation and version, and checks authentication without printing credentials: Codex through 'codex login status', Gemini through the GEMINI_API_KEY variable or the CLI's own login, and Copilot only with -Live, because its CLI has no status command.
    Also checks PowerShell, Git, Pester, actionlint and whether core.hooksPath points at .githooks.

    -Live sends one minimal prompt to each installed agent, which proves authentication and costs a few tokens.
    Exits 1 when Codex or the hooks are not ready, because commits are blocked without them. Gemini and Copilot are optional.

.PARAMETER Live
    Sends a minimal prompt to each installed agent.

.EXAMPLE
    pwsh -NoProfile -File scripts/ai/Test-AgentEnvironment.ps1

.EXAMPLE
    pwsh -NoProfile -File scripts/ai/Test-AgentEnvironment.ps1 -Live

.NOTES
    Author  : Lars Krogh
    Version : 1.0.0
#>


[CmdletBinding()]
param(
    [switch]$Live
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentTools.ps1')

function ConvertTo-EnvironmentResult {
    <#
    .SYNOPSIS
        Creates one row of the environment report.

    .DESCRIPTION
        Collects a component's readiness and a short explanation.

    .PARAMETER Component
        The component name.

    .PARAMETER Role
        What the component does in the workflow.

    .PARAMETER Ready
        Whether it can be used.

    .PARAMETER Required
        Whether commits are blocked without it.

    .PARAMETER Detail
        Version, authentication state or the fix.

    .EXAMPLE
        ConvertTo-EnvironmentResult -Component 'git' -Role 'version control' -Ready $true -Required $true -Detail '2.43'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Component,
        [Parameter(Mandatory)]
        [string]$Role,
        [Parameter(Mandatory)]
        [bool]$Ready,
        [Parameter(Mandatory)]
        [bool]$Required,
        [Parameter(Mandatory)]
        [string]$Detail
    )
    [PSCustomObject]@{ Component = $Component; Role = $Role; Ready = $Ready; Required = $Required; Detail = $Detail }
}

function Get-FirstLine {
    <#
    .SYNOPSIS
        Returns the first non-empty line of a process result.

    .DESCRIPTION
        Used for version output, which some CLIs write to standard error.

    .PARAMETER Result
        The result of Invoke-AIProcess.

    .EXAMPLE
        Get-FirstLine -Result $run

    .OUTPUTS
        System.String

    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result
    )
    $line = ($Result.StandardOutput + "`n" + $Result.StandardError) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1
    if ($line) { $line.Trim() } else { '' }
}

if ($Live) {
    # Live probes start the agents, which an agent process must never do.
    Assert-AINotNested
}
$root = Get-AIRepositoryRoot
$settings = Get-AIConfiguration -RepositoryRoot $root
$results = [Collections.Generic.List[object]]::new()
$results.Add((ConvertTo-EnvironmentResult -Component 'pwsh' -Role 'runs the workflow scripts' -Ready ($PSVersionTable.PSVersion -ge [version]'7.2') -Required $true -Detail $PSVersionTable.PSVersion.ToString()))
try {
    $git = Resolve-AICommand -Name 'git'
    $results.Add((ConvertTo-EnvironmentResult -Component 'git' -Role 'version control' -Ready $true -Required $true -Detail (Get-FirstLine (Invoke-AIProcess -FilePath $git -ArgumentList '--version' -TimeoutSeconds 30))))
}
catch {
    $results.Add((ConvertTo-EnvironmentResult -Component 'git' -Role 'version control' -Ready $false -Required $true -Detail $_.Exception.Message))
}
$hooksPath = Invoke-AIGit -ArgumentList 'config', '--get', 'core.hooksPath' -WorkingDirectory $root -AllowFailure
$results.Add((ConvertTo-EnvironmentResult -Component 'git hooks' -Role 'pre-commit review gate, pre-push verification' -Ready ($hooksPath -eq '.githooks') -Required $true -Detail $(if ($hooksPath -eq '.githooks') { 'core.hooksPath = .githooks' } else { 'Run: pwsh -NoProfile -File scripts/ai/Invoke-AgentWorkflow.ps1 -Stage InstallHooks' })))
$pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
$results.Add((ConvertTo-EnvironmentResult -Component 'Pester' -Role 'agent workflow tests' -Ready ($null -ne $pester -and $pester.Version -ge [version]'5.6.1') -Required $false -Detail $(if ($pester) { $pester.Version.ToString() } else { 'Install-Module Pester -RequiredVersion 5.6.1 -Scope CurrentUser' })))
$agents = @(
    @{ Name = 'codex'; Role = 'mandatory independent reviewer'; Required = $true; Command = $settings.Codex.Command }
    @{ Name = 'gemini'; Role = 'on-demand read-only research'; Required = $false; Command = $settings.Gemini.Command }
    @{ Name = 'copilot'; Role = 'documentation and GitHub automation'; Required = $false; Command = $settings.Copilot.Command }
)
foreach ($agent in $agents) {
    try {
        $path = Resolve-AICommand -Name $agent.Command
        $versionRun = Invoke-AIProcess -FilePath $path -ArgumentList '--version' -TimeoutSeconds 60
        if ($versionRun.ExitCode -ne 0) {
            throw "'$($agent.Command) --version' failed: $(Get-FirstLine $versionRun)"
        }
        $detail = Get-FirstLine $versionRun
        $ready = $true
        switch ($agent.Name) {
            'codex' {
                $status = Invoke-AIProcess -FilePath $path -ArgumentList 'login', 'status' -TimeoutSeconds 60
                $ready = $status.ExitCode -eq 0
                $detail += "; $(if ($ready) { Get-FirstLine $status } else { 'not logged in: run codex login' })"
            }
            'gemini' {
                $hasKey = -not [string]::IsNullOrEmpty($env:GEMINI_API_KEY)
                $detail += "; $(if ($hasKey) { 'GEMINI_API_KEY is set' } else { 'GEMINI_API_KEY is not set (another configured login may still work; check with -Live)' })"
            }
            'copilot' {
                $detail += '; authentication is checked with -Live'
            }
        }
        if ($Live -and $ready) {
            $probe = switch ($agent.Name) {
                'codex' { Invoke-AIProcess -FilePath $path -ArgumentList 'exec', '--sandbox', 'read-only', '--ephemeral', '--skip-git-repo-check', '-' -InputText 'Reply with the single word OK.' -TimeoutSeconds 180 -Agent }
                'gemini' { Invoke-AIProcess -FilePath $path -ArgumentList '-p', 'Reply with the single word OK.', '--approval-mode', 'plan', '-o', 'json', '--skip-trust' -TimeoutSeconds 180 -Agent }
                'copilot' { Invoke-AIProcess -FilePath $path -ArgumentList '-p', 'Reply with the single word OK.', '-s', '--no-ask-user', '--no-auto-update' -TimeoutSeconds 180 -Agent }
            }
            $ready = -not $probe.TimedOut -and $probe.ExitCode -eq 0
            $detail += "; live call $(if ($ready) { 'succeeded' } else { "failed: $(Get-FirstLine $probe)" })"
        }
        $results.Add((ConvertTo-EnvironmentResult -Component $agent.Name -Role $agent.Role -Ready $ready -Required $agent.Required -Detail $detail))
    }
    catch {
        $results.Add((ConvertTo-EnvironmentResult -Component $agent.Name -Role $agent.Role -Ready $false -Required $agent.Required -Detail $_.Exception.Message))
    }
}
$results | Format-Table -Property Component, Ready, Required, Role, Detail -AutoSize -Wrap | Out-Host

if (@($results | Where-Object { $_.Required -and -not $_.Ready }).Count -gt 0) {
    exit 1
}
exit 0
