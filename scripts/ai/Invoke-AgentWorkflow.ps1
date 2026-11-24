#Requires -Version 7.2

<#
.SYNOPSIS
    Enforces the agent workflow from the Git hooks, and installs the hooks.

.DESCRIPTION
    PreCommit runs the deterministic checks and the Codex review for the staged changes and blocks the commit unless the exact staged changeset is approved.
    It refuses while another agent holds the write lock, and when it was started by an agent process.
    PrePush reads the refs that Git is about to push from standard input and blocks the push unless every outgoing commit is covered by approving review records: either one for exactly its changeset, or a chain of approved changesets from its first parent's tree to its tree, as an amended commit has.
    Merge commits are not exempt, because a merge tree can contain conflict resolutions or edits that no branch review saw.
    It does not start a review itself.

    Status shows whether the staged changes are approved.
    InstallHooks points core.hooksPath at .githooks.

    Local hooks can be skipped with --no-verify, so they are a safety net, not a security boundary.
    Server-side rules and CI are authoritative; see docs/ai-development.md.

.PARAMETER Stage
    PreCommit, PrePush, Status or InstallHooks.

.PARAMETER Remote
    The remote name, which Git passes to the pre-push hook.

.EXAMPLE
    pwsh -NoProfile -File scripts/ai/Invoke-AgentWorkflow.ps1 -Stage InstallHooks

.EXAMPLE
    pwsh -NoProfile -File scripts/ai/Invoke-AgentWorkflow.ps1 -Stage Status

.NOTES
    Author  : Lars Krogh
    Version : 1.1.0
#>


[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('PreCommit', 'PrePush', 'Status', 'InstallHooks')]
    [string]$Stage,
    [string]$Remote = 'origin'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentTools.ps1')

function Get-OutgoingCommit {
    <#
    .SYNOPSIS
        Lists the commits that a push would send.

    .DESCRIPTION
        Parses the lines Git writes to the pre-push hook ("<local ref> <local sha> <remote ref> <remote sha>").
        Deleted refs send nothing.
        For a new remote ref, the commits not yet on any ref of the remote are outgoing.

    .PARAMETER RepositoryRoot
        The repository root.

    .PARAMETER PushLine
        The lines from standard input.

    .PARAMETER RemoteName
        The remote being pushed to.

    .EXAMPLE
        Get-OutgoingCommit -RepositoryRoot $root -PushLine $lines -RemoteName 'origin'

    .OUTPUTS
        System.String. Commit IDs, oldest first.

    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,
        [AllowEmptyCollection()]
        [string[]]$PushLine,
        [Parameter(Mandatory)]
        [string]$RemoteName
    )
    $zero = '0' * 40
    foreach ($line in $PushLine) {
        $fields = $line.Trim() -split '\s+'
        if ($fields.Count -ne 4 -or $fields[1] -eq $zero) {
            continue
        }
        $range = if ($fields[3] -eq $zero) { @($fields[1], '--not', "--remotes=$RemoteName") } else { @("$($fields[3])..$($fields[1])") }
        $list = Invoke-AIGit -ArgumentList (@('rev-list', '--reverse') + $range) -WorkingDirectory $RepositoryRoot
        $list -split "`n" | Where-Object { $_ }
    }
}

try {
    $root = Get-AIRepositoryRoot
    switch ($Stage) {
        'InstallHooks' {
            $null = Invoke-AIGit -ArgumentList 'config', 'core.hooksPath', '.githooks' -WorkingDirectory $root
            Write-AIMessage 'Git hooks installed: core.hooksPath = .githooks'
            exit 0
        }
        'Status' {
            $changeset = Get-AIChangeset -RepositoryRoot $root
            $record = Get-AIReviewRecord -RepositoryRoot $root -Changeset $changeset
            if ($changeset.BaseTree -eq $changeset.Tree) {
                Write-AIMessage 'Nothing is staged.'
            }
            elseif (Test-AIApproval -Record $record -Changeset $changeset -BlockingSeverities (Get-AIConfiguration -RepositoryRoot $root -Tree $changeset.Tree).Codex.BlockingSeverities) {
                Write-AIMessage "Staged changeset $($changeset.Id) is approved."
            }
            elseif ($record) {
                Write-AIReview -Record $record
            }
            else {
                Write-AIMessage "Staged changeset $($changeset.Id) has not been reviewed."
            }
            exit 0
        }
        'PreCommit' {
            Assert-AINotNested
            if (Test-AIWriteLock -RepositoryRoot $root) {
                throw 'Another agent is changing files in this repository. Commit after it has finished.'
            }
            $changeset = Get-AIChangeset -RepositoryRoot $root
            if ($changeset.BaseTree -eq $changeset.Tree) {
                exit 0
            }
            $settings = Get-AIConfiguration -RepositoryRoot $root -Tree $changeset.Tree
            $record = Get-AIReviewRecord -RepositoryRoot $root -Changeset $changeset
            if (-not (Test-AIApproval -Record $record -Changeset $changeset -BlockingSeverities $settings.Codex.BlockingSeverities)) {
                $record = Invoke-AIReviewGate -RepositoryRoot $root -Changeset $changeset
                Write-AIReview -Record $record
            }
            if (-not $record.approved) {
                throw 'Codex rejected the staged changes. Fix the findings, stage the fixes and commit again.'
            }
            # Git commits the index as it is when this hook exits, so content staged during the review must not inherit the approval.
            $current = Get-AIChangeset -RepositoryRoot $root
            if ($current.Id -ne $changeset.Id) {
                throw "The staged changes changed during the review (reviewed $($changeset.Id), now $($current.Id)). Commit again to review the current changes."
            }
            Write-AIMessage "Commit allowed: changeset $($changeset.Id) is approved."
            exit 0
        }
        'PrePush' {
            Assert-AINotNested
            $lines = @([Console]::In.ReadToEnd() -split "`n" | Where-Object { $_.Trim() })
            $missing = foreach ($commit in @(Get-OutgoingCommit -RepositoryRoot $root -PushLine $lines -RemoteName $Remote)) {
                $changeset = Get-AIChangeset -RepositoryRoot $root -Commit $commit
                if ($changeset.BaseTree -eq $changeset.Tree) {
                    continue
                }
                $settings = Get-AIConfiguration -RepositoryRoot $root -Tree $changeset.Tree
                if (-not (Test-AIApprovedPath -RepositoryRoot $root -Changeset $changeset -BlockingSeverities $settings.Codex.BlockingSeverities)) {
                    $commit
                }
            }
            if (@($missing).Count -gt 0) {
                foreach ($commit in $missing) {
                    Write-AIMessage "  not approved: $commit"
                }
                throw 'These commits have no approving Codex review. Review each with: pwsh -NoProfile -File scripts/ai/Invoke-CodexReview.ps1 -Commit <sha>'
            }
            Write-AIMessage 'Push allowed: every outgoing commit is approved.'
            exit 0
        }
    }
}
catch {
    Write-AIMessage "$Stage blocked: $($_.Exception.Message)"
    exit 1
}
