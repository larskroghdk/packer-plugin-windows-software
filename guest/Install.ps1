<#
.SYNOPSIS
    Detects Windows and installs a checksum- and Authenticode-validated package.

.DESCRIPTION
    Runs through Packer WinRM as an administrator.
    Never reboots. Uses no Win32_Product queries.

.PARAMETER Action
    Facts, Inspect or Install.

.PARAMETER InputPath
    JSON request containing the immutable package record and installer path.

.PARAMETER OutputPath
    JSON response file inside the per-run directory.

.NOTES
    Author  : Lars Krogh
    Version : 1.0.0
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'Facts',
        'Inspect',
        'Install'
    )]
    [string]$Action,
    [string]$InputPath,
    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

function Get-WindowsFacts {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $family = ''
    $installation = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType
    if ($os.ProductType -eq 1) {
        if ($build -ge 22000) {
            $family = 'windows11'
        }
        elseif ($build -ge 17763) {
            $family = 'windows10'
        }
    }
    else {
        switch ($build) {
            17763 {
                $family = 'server2019'
            }
            20348 {
                $family = 'server2022'
            }
            26100 {
                $family = 'server2025'
            }
        }
    }
    $architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $architecture) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }
    return @{
        name         = $os.Caption;
        build        = $build;
        family       = $family;
        architecture = $architecture;
        server_core  = ($installation -eq 'Server Core')
    }
}

function Get-InstalledVersion {
    param(
        [Parameter(Mandatory)]
        $Detection
    )
    $path = [Environment]::ExpandEnvironmentVariables([string]$Detection.path)
    if ($Detection.type -eq 'file') {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return ''
        }
        $value = (Get-Item -LiteralPath $path).VersionInfo.ProductVersion
    }
    else {
        if (-not (Test-Path -LiteralPath $path)) {
            return ''
        }
        $item = Get-ItemProperty -LiteralPath $path
        $property = $item.PSObject.Properties[[string]$Detection.value]
        if ($null -eq $property) {
            return ''
        }
        $value = $property.Value
    }
    if ([string]$value -notmatch '^\s*v?(\d+(?:\.\d+){1,3})') {
        throw "Cannot parse installed version at $path"
    }
    return $Matches[1]
}

function ConvertTo-PackageVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )
    if ($Version -notmatch '^\d+(?:\.\d+){1,3}$') {
        throw "Invalid numeric package version: $Version"
    }
    $parts = @($Version.Split('.'))
    while ($parts.Count -lt 4) {
        $parts += '0'
    }
    return [version]($parts -join '.')
}

function Assert-Installer {
    param(
        [Parameter(Mandatory)]
        $Package,
        [Parameter(Mandatory)]
        [string]$Path
    )
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Package.sha256) {
        throw 'SHA-256 mismatch'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw "Invalid Authenticode signature: $($signature.Status)"
    }
    $signer = $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if (@($Package.signer_subjects) -cnotcontains $signer) {
        throw "Unexpected Authenticode signer: $signer"
    }
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory)]
        $Package,
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )
    $arguments = [string]$Package.silent_arguments
    $executable = $Path
    if ($Package.installer_type -eq 'msi') {
        $executable = "$env:SystemRoot\System32\msiexec.exe"
        $arguments = '/i "' + $Path + '" ' + $arguments + ' /L*v "' + (Join-Path (Split-Path $Path) 'msi.log') + '"'
    }
    $process = Start-Process -FilePath $executable -ArgumentList $arguments -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw "Installer timeout after $TimeoutSeconds seconds; installation may still be running; discard this VM"
    }
    $process.Refresh()
    return [int]$process.ExitCode
}

function Test-PendingReboot {
    return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or ($null -ne (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue))
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$result = @{
    error           = '';
    version         = '';
    reboot_required = $false;
    exit_code       = $null
}

try {
    if ($Action -eq 'Facts') {
        $result = Get-WindowsFacts
    }
    else {
        $request = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
        $package = $request.package
        $result.version = Get-InstalledVersion -Detection $package.detection
        if ($Action -eq 'Install') {
            $facts = Get-WindowsFacts
            if ($facts.architecture -ne 'AMD64' -or @($package.supported_os) -notcontains $facts.family) {
                throw 'Unsupported operating system or architecture'
            }
            if ($facts.server_core -and -not $package.server_core) {
                throw 'Package requires Desktop Experience'
            }
            Assert-Installer -Package $package -Path $request.installer_path
            $result.exit_code = Invoke-Installer -Package $package -Path $request.installer_path -TimeoutSeconds $request.timeout_seconds
            $result.reboot_required = (@($package.reboot_codes) -contains $result.exit_code) -or (Test-PendingReboot)
            if ($result.exit_code -eq 1641) {
                throw 'Installer initiated a reboot despite suppression; build cannot be trusted'
            }
            if (@($package.success_codes) -notcontains $result.exit_code) {
                throw "Installer exited with code $($result.exit_code)"
            }
            $result.version = Get-InstalledVersion -Detection $package.detection
            if (-not $result.version -or (ConvertTo-PackageVersion $result.version) -ne (ConvertTo-PackageVersion $package.version)) {
                throw "Installation verification failed: expected $($package.version), observed $($result.version)"
            }
        }
    }
}
catch {
    $result.error = $_.Exception.Message
}
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
