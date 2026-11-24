#Requires -Version 7.2

<#
.SYNOPSIS
    Runs the checks and the independent Codex review for the staged changes or a commit.

.DESCRIPTION
    Identifies the changeset by its base and result trees, reuses an approving record for the identical changeset, and otherwise runs the matching deterministic checks and a read-only Codex review on an exported snapshot.
    Prints the findings and exits 0 only when the changeset is approved: no critical or high finding and the verdict approve.
    Any failure exits 1, so an unavailable reviewer blocks instead of approving.

.PARAMETER Commit
    Reviews this commit against its first parent instead of the staged changes.
    Use it for commits made without the pre-commit hook, for example after an amend or a rebase that changed content, before pushing them.

.PARAMETER Force
    Reviews again even when an approving record for the changeset exists.

.EXAMPLE
    pwsh -NoProfile -File scripts/ai/Invoke-CodexReview.ps1

.EXAMPLE
    pwsh -NoProfile -File scripts/ai/Invoke-CodexReview.ps1 -Commit HEAD

.NOTES
    Author  : Lars Krogh
    Version : 1.0.0
#>


[CmdletBinding()]
param(
    [string]$Commit,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentTools.ps1')

try {
    Assert-AINotNested
    $root = Get-AIRepositoryRoot
    $changeset = Get-AIChangeset -RepositoryRoot $root -Commit $Commit
    if ($changeset.BaseTree -eq $changeset.Tree) {
        Write-AIMessage 'The changeset is empty; there is nothing to review.'
        exit 0
    }
    if ($changeset.Commit -and (Test-AIPredatesWorkflow -RepositoryRoot $root -Commit $changeset.Commit)) {
        Write-AIMessage "Commit $($changeset.Commit) predates the review workflow and needs no review."
        exit 0
    }
    $settings = Get-AIConfiguration -RepositoryRoot $root -Tree $changeset.Tree
    $record = Get-AIReviewRecord -RepositoryRoot $root -Changeset $changeset
    if (-not $Force -and (Test-AIApproval -Record $record -Changeset $changeset -BlockingSeverities $settings.Codex.BlockingSeverities)) {
        Write-AIMessage "Changeset $($changeset.Id) was already approved at $($record.reviewed_at)."
        exit 0
    }
    $record = Invoke-AIReviewGate -RepositoryRoot $root -Changeset $changeset
    Write-AIReview -Record $record
    if ($record.approved) { exit 0 } else { exit 1 }
}
catch {
    Write-AIMessage "Review blocked: $($_.Exception.Message)"
    exit 1
}
