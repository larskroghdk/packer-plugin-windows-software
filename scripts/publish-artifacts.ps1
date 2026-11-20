<#
.SYNOPSIS
    Publishes validated software versions to GitHub Releases and appends them to the catalog.

.DESCRIPTION
    Reads each <id>-catalog.json written by validate-artifacts.ps1 and publishes release software/<id>/<version> with that catalog record and a SHA256SUMS file.
    The installer itself is uploaded only when the package recipe sets redistribution_approved.
    Versions are immutable: a version already in packages/catalog.json must keep its hash, and published release assets are never replaced.
    A draft left by an interrupted run is completed; a published release that is missing assets fails the run.
    New records are committed to packages/catalog.json through the GitHub Contents API, based on the blob SHA of the checked-out catalog.
    If the branch changed meanwhile, GitHub rejects the write (HTTP 409) instead of losing the other change.

.PARAMETER Directory
    Directory containing validated <id>-catalog.json files and installers.

.EXAMPLE
    ./scripts/publish-artifacts.ps1 -Directory artifacts

.NOTES
    Author  : Lars Krogh
    Version : 1.1.0
    Runs in GitHub Actions. Requires gh and the GH_TOKEN, GITHUB_REPOSITORY and GITHUB_REF_NAME environment variables.
    The token is never written to disk or git config.
#>

[CmdletBinding()]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Directory = 'artifacts'
)

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

function Invoke-GitHub {
    <#
    .SYNOPSIS
        Runs gh with the given arguments and throws on a nonzero exit code.
    .NOTES
        Author  : Lars Krogh
        Version : 1.1.0
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )
    $response = & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments[0..1] -join ' ') failed with exit code $LASTEXITCODE"
    }
    return $response
}

foreach ($name in 'GH_TOKEN', 'GITHUB_REPOSITORY', 'GITHUB_REF_NAME') {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        throw "$name must be set"
    }
}

$repository = $env:GITHUB_REPOSITORY
$catalogPath = 'packages/catalog.json'
$baseSha = git hash-object -- $catalogPath
if ($LASTEXITCODE -ne 0) {
    throw "git hash-object $catalogPath failed"
}

$records = [Collections.Generic.List[object]]::new()
foreach ($existingRecord in (Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json).packages) {
    $records.Add($existingRecord)
}
$added = [Collections.Generic.List[string]]::new()
foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*-catalog.json') {
    $record = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).packages[0]
    $tag = "software/$($record.id)/$($record.version)"
    $installerName = "$($record.id)-x64-$($record.version).$($record.installer_type)"
    $recipe = Get-Content -LiteralPath "packages/$($record.id).json" -Raw | ConvertFrom-Json
    $previous = @($records | Where-Object { $_.id -eq $record.id -and $_.version -eq $record.version })
    if ($previous.Count -gt 0) {
        if ($previous[0].sha256 -ne $record.sha256) {
            throw "Immutable version hash conflict: $tag"
        }
        $record = $previous[0]
    }
    elseif ($recipe.redistribution_approved) {
        $record.source = 'github-release'
        $record.url = "https://github.com/$repository/releases/download/$tag/$installerName"
    }
    [ordered]@{ schema_version = 1; packages = @($record) } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $file.FullName -Encoding utf8
    $checksumPath = Join-Path $Directory "$($record.id)-SHA256SUMS"
    "$($record.sha256)  $installerName" | Set-Content -LiteralPath $checksumPath -Encoding ascii
    $assets = @($file.FullName, $checksumPath)
    if ($record.source -eq 'github-release') {
        $assets += Join-Path $Directory $installerName
    }
    $existing = & gh release view $tag --repo $repository --json isDraft, assets 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-GitHub -Arguments (@('release', 'create', $tag, '--repo', $repository, '--draft', '--title', "$($record.name) $($record.version)", '--notes', "Validated SHA-256 and Authenticode. Source: $($record.official_url).") + $assets) | Out-Null
        $isDraft = $true
    }
    else {
        $release = $existing | ConvertFrom-Json
        $isDraft = [bool]$release.isDraft
        $publishedAssets = @($release.assets | ForEach-Object name)
        $catalogAsset = $file.Name
        if ($publishedAssets -contains $catalogAsset) {
            $verifyDirectory = Join-Path $Directory "verify-$($record.id)"
            $null = New-Item -ItemType Directory -Path $verifyDirectory -Force
            Invoke-GitHub -Arguments @('release', 'download', $tag, '--repo', $repository, '--pattern', $catalogAsset, '--dir', $verifyDirectory, '--clobber') | Out-Null
            $remote = (Get-Content -LiteralPath (Join-Path $verifyDirectory $catalogAsset) -Raw | ConvertFrom-Json).packages[0]
            if ($remote.sha256 -ne $record.sha256 -or $remote.url -ne $record.url) {
                throw "Release metadata conflict: $tag"
            }
            $record = $remote
        }
        foreach ($asset in $assets) {
            if ($publishedAssets -notcontains (Split-Path -Leaf $asset)) {
                if (-not $isDraft) {
                    throw "Published release is incomplete: $tag"
                }
                Invoke-GitHub -Arguments @('release', 'upload', $tag, '--repo', $repository, $asset) | Out-Null
            }
        }
    }
    if ($isDraft) {
        Invoke-GitHub -Arguments @('release', 'edit', $tag, '--repo', $repository, '--draft=false') | Out-Null
    }
    if ($previous.Count -eq 0) {
        $records.Add($record)
        $added.Add("$($record.id) $($record.version)")
    }
}

if ($added.Count -eq 0) {
    Write-Information -InformationAction Continue 'Catalog already contains every validated version.'
    return
}
$updated = ([ordered]@{ schema_version = 1; packages = $records.ToArray() } | ConvertTo-Json -Depth 15) + "`n"
$body = [ordered]@{
    message = "Add validated software: $($added -join ', ')"
    content = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($updated))
    sha     = $baseSha
    branch  = $env:GITHUB_REF_NAME
}
$bodyPath = Join-Path $Directory 'catalog-commit.json'
$body | ConvertTo-Json | Set-Content -LiteralPath $bodyPath -Encoding utf8
Invoke-GitHub -Arguments @('api', '--method', 'PUT', "repos/$repository/contents/$catalogPath", '--input', $bodyPath) | Out-Null
Write-Information -InformationAction Continue "Committed $($added.Count) catalog record(s) to $env:GITHUB_REF_NAME."
