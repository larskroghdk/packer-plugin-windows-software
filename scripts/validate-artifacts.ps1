<#
.SYNOPSIS
    Validates downloaded installers and writes catalog records for publication.

.DESCRIPTION
    For each <id>.candidate.json written by cmd/resolve-installers, requires the recorded SHA-256, a valid Authenticode signature with an allowed signer and an embedded product version equal to the candidate version.
    On success it writes <id>-catalog.json with validated_at set.
    Uses the guest engine's own verification functions and never runs an installer.

.PARAMETER Directory
    Directory containing installers and candidate records.

.EXAMPLE
    go run ./cmd/resolve-installers -package powershell7
    ./scripts/validate-artifacts.ps1

.NOTES
    Author  : Lars Krogh
    Version : 1.1.0
    Requires Windows for Authenticode and Windows Installer APIs.
#>

[CmdletBinding()]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Directory = 'artifacts'
)

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

function Get-EmbeddedVersion {
    <#
    .SYNOPSIS
        Returns the ProductVersion embedded in an MSI database or EXE version resource.
    .PARAMETER Path
        Installer file.
    .PARAMETER InstallerType
        msi or exe.
    .NOTES
        Author  : Lars Krogh
        Version : 1.1.0
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('msi', 'exe')]
        [string]$InstallerType
    )
    if ($InstallerType -eq 'exe') {
        return [string](Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
    }
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Path, 0)
    $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductVersion'")
    try {
        $null = $view.Execute()
        $row = $view.Fetch()
        if ($null -eq $row) {
            return ''
        }
        return [string]$row.StringData(1)
    }
    finally {
        $null = $view.Close()
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($database)
    }
}

. "$PSScriptRoot\..\guest\Install.ps1" -Action Inspect -OutputPath unused

$candidates = @(Get-ChildItem -LiteralPath $Directory -Filter '*.candidate.json')
if ($candidates.Count -eq 0) {
    throw "No *.candidate.json files in $Directory; run go run ./cmd/resolve-installers first."
}

foreach ($candidate in $candidates) {
    $package = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json
    $name = "$($package.id)-x64-$($package.version).$($package.installer_type)"
    $path = (Resolve-Path -LiteralPath (Join-Path $Directory $name)).ProviderPath
    Assert-Installer -Package $package -Path $path
    $embedded = Get-EmbeddedVersion -Path $path -InstallerType $package.installer_type
    if ($embedded -notmatch '(\d+(?:\.\d+){1,3})') {
        throw "No embedded version in $name"
    }
    $actualVersion = $Matches[1]
    if ((ConvertTo-PackageVersion $actualVersion) -ne (ConvertTo-PackageVersion $package.version)) {
        throw "Embedded version $actualVersion of $name differs from $($package.version)"
    }
    $package.validated_at = [DateTime]::UtcNow.ToString('o')
    [ordered]@{ schema_version = 1; packages = @($package) } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $Directory "$($package.id)-catalog.json") -Encoding utf8
    Write-Information -InformationAction Continue "$($package.id) $($package.version): signature and embedded version validated."
}
