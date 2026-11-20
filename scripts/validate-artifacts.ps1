<#
.SYNOPSIS
Validates installer signatures and generates immutable release catalogs.
.PARAMETER Directory
Directory containing downloaded installers and candidate metadata.
#>
param([string]$Directory = 'artifacts')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Load the same verifier used in the guest; this does not run an installer.
. "$PSScriptRoot\..\guest\Install.ps1" -Action Inspect -OutputPath unused
foreach ($candidate in Get-ChildItem -LiteralPath $Directory -Filter '*.candidate.json') {
    $package = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json
    $name = "$($package.id)-x64-$($package.version).$($package.installer_type)"
    $path = Join-Path $Directory $name
    Assert-Installer -Package $package -Path $path
    # Verify the installer contains the expected architecture/version, independently of the index.
    if ($package.installer_type -eq 'msi') {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.OpenDatabase((Resolve-Path -LiteralPath $path).Path, 0)
        $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductVersion'")
        $view.Execute()
        $row = $view.Fetch()
        $embedded = $row.StringData(1)
        $view.Close()
    } else {
        $embedded = (Get-Item -LiteralPath $path).VersionInfo.ProductVersion
    }
    if ([string]$embedded -notmatch '(\d+(?:\.\d+){1,3})') { throw "No embedded version in $name" }
    $actualVersion = $Matches[1]
    if ((ConvertTo-PackageVersion $actualVersion) -ne (ConvertTo-PackageVersion $package.version)) { throw "Embedded version $actualVersion differs from requested $($package.version)" }
    $package.validated_at = [DateTime]::UtcNow.ToString('o')
    @{ schema_version = 1; packages = @($package) } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $Directory "$($package.id)-catalog.json") -Encoding utf8
}
