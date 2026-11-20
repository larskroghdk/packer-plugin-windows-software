<#
.SYNOPSIS
Publishes validated versions without replacing release assets, then updates repository metadata.
.PARAMETER Directory
Validated candidate directory. Requires GH_TOKEN and GITHUB_REPOSITORY in the environment.
#>
param([string]$Directory = 'artifacts')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Invoke-GitHub {
    <# .SYNOPSIS Runs gh and treats every nonzero exit as a publication failure. #>
    param([string[]]$Arguments)
    $response = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh failed: $($Arguments[0])" }
    return $response
}
$catalog = Get-Content packages/catalog.json -Raw | ConvertFrom-Json
$records = [Collections.Generic.List[object]]::new()
$changed = $false
foreach ($record in $catalog.packages) { $records.Add($record) }
foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*-catalog.json') {
    $record = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).packages[0]
    $tag = "software/$($record.id)/$($record.version)"
    $recipe = Get-Content "packages/$($record.id).json" -Raw | ConvertFrom-Json
    $name = "$($record.id)-x64-$($record.version).$($record.installer_type)"
    $previous = @($records | Where-Object { $_.id -eq $record.id -and $_.version -eq $record.version })
    if ($previous.Count -gt 0) {
        if ($previous[0].sha256 -ne $record.sha256) { throw "Immutable version hash conflict: $tag" }
        $record = $previous[0]
    }
    elseif ($recipe.redistribution_approved) {
        $record.source = 'github-release'
        $record.url = "https://github.com/$env:GITHUB_REPOSITORY/releases/download/$tag/$name"
    }
    @{ schema_version = 1; packages = @($record) } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $file.FullName -Encoding utf8
    $checksum = Join-Path $Directory "$($record.id)-SHA256SUMS"
    "$($record.sha256)  $name" | Set-Content -LiteralPath $checksum -Encoding ascii
    $existing = & gh release view $tag --repo $env:GITHUB_REPOSITORY --json isDraft,assets 2>$null
    if ($LASTEXITCODE -eq 0) {
        # Recovery after a release succeeded but the catalog commit failed. Never overwrite assets.
        $verify = Join-Path $Directory "verify-$($record.id)"
        New-Item -ItemType Directory -Path $verify -Force | Out-Null
        Invoke-GitHub -Arguments @('release','download',$tag,'--repo',$env:GITHUB_REPOSITORY,'--pattern',"$($record.id)-catalog.json",'--dir',$verify) | Out-Null
        $remote = (Get-Content (Join-Path $verify "$($record.id)-catalog.json") -Raw | ConvertFrom-Json).packages[0]
        if ($remote.sha256 -ne $record.sha256 -or $remote.url -ne $record.url) { throw "Release metadata conflict: $tag" }
        $record = $remote
        $release = $existing | ConvertFrom-Json
        $expectedAssets = @($file.FullName, $checksum)
        if ($record.source -eq 'github-release') { $expectedAssets += (Join-Path $Directory $name) }
        foreach ($asset in $expectedAssets) {
            if (@($release.assets.name) -notcontains (Split-Path $asset -Leaf)) {
                if (-not $release.isDraft) { throw "Published release is incomplete: $tag" }
                Invoke-GitHub -Arguments @('release','upload',$tag,'--repo',$env:GITHUB_REPOSITORY,$asset) | Out-Null
            }
        }
        if ($release.isDraft) { Invoke-GitHub -Arguments @('release','edit',$tag,'--repo',$env:GITHUB_REPOSITORY,'--draft=false') | Out-Null }
    } else {
        $assets = @($file.FullName, $checksum)
        if ($record.source -eq 'github-release') { $assets += (Join-Path $Directory $name) }
        Invoke-GitHub -Arguments (@('release','create',$tag,'--repo',$env:GITHUB_REPOSITORY,'--draft','--title',"$($record.name) $($record.version)",'--notes',"Validated SHA-256 and Authenticode. Source: $($record.official_url).") + $assets) | Out-Null
        Invoke-GitHub -Arguments @('release','edit',$tag,'--repo',$env:GITHUB_REPOSITORY,'--draft=false') | Out-Null
    }
    if ($previous.Count -eq 0) { $records.Add($record); $changed = $true }
}
if (-not $changed) { return }
$updated = @{ schema_version = 1; packages = @($records.ToArray()) } | ConvertTo-Json -Depth 15
$updated | Set-Content packages/catalog.json -Encoding utf8
# Use the Contents API with an optimistic SHA; no credentials in git config, command lines or files.
$current = Invoke-GitHub -Arguments @('api',"repos/$env:GITHUB_REPOSITORY/contents/packages/catalog.json") | ConvertFrom-Json
$body = @{ message = 'Update validated software catalog'; sha = $current.sha; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($updated + "`n")) }
$bodyPath = Join-Path $Directory 'catalog-commit.json'
$body | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $bodyPath -Encoding utf8
Invoke-GitHub -Arguments @('api','--method','PUT',"repos/$env:GITHUB_REPOSITORY/contents/packages/catalog.json",'--input',$bodyPath) | Out-Null
