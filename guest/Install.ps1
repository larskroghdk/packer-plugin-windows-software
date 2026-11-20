<#
.SYNOPSIS
    Detects Windows and installs a checksum- and Authenticode-validated package.

.DESCRIPTION
    Embedded in the windows-software Packer provisioner and run over the builder's WinRM session as an administrator under Windows PowerShell 5.1.
    Each invocation performs one action and writes a JSON result to OutputPath.
    Never reboots and never queries Win32_Product.

.PARAMETER Action
    Facts returns the Windows platform. Inspect returns the installed version.
    Install verifies and runs the installer, then verifies the installed version.

.PARAMETER InputPath
    JSON request with the package record, installer_path and timeout_seconds.
    Required for Inspect and Install.

.PARAMETER OutputPath
    JSON result file inside the per-run working directory.

.EXAMPLE
    powershell.exe -File Install.ps1 -Action Facts -OutputPath C:\Windows\Temp\run\001-out.json

.NOTES
    Author  : Lars Krogh
    Version : 1.1.0
    A result with fatal = true means the guest is in an unknown state (installer still running or restart initiated); the host aborts the build.
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

function Get-WindowsPlatform {
    <#
    .SYNOPSIS
        Returns OS family, build, native architecture and Server Core status.
    .DESCRIPTION
        family is empty for releases the package catalog does not recognise.
    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
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
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $architecture) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }
    return @{
        name         = $os.Caption
        build        = $build
        family       = $family
        architecture = $architecture
        server_core  = ($installation -eq 'Server Core')
    }
}

function Get-InstalledVersion {
    <#
    .SYNOPSIS
        Reads the installed version from file metadata or a registry value.
    .DESCRIPTION
        Returns an empty string when the software is absent.
        Throws when a version is present but not numeric, so an unknown state never looks like "absent".
    .PARAMETER Detection
        The package's detection record: type (file or registry), path and value.
    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
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
        $property = (Get-ItemProperty -LiteralPath $path).PSObject.Properties[[string]$Detection.value]
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
    <#
    .SYNOPSIS
        Converts a numeric vendor version to a comparable four-part [version].
    .DESCRIPTION
        Missing trailing components become zero and leading zeros are ignored, matching the host's catalog comparison.
    .PARAMETER Version
        Numeric version with two to four components.
    .EXAMPLE
        (ConvertTo-PackageVersion '26.003.22110') -eq (ConvertTo-PackageVersion '26.3.22110.0')
    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
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
    <#
    .SYNOPSIS
        Requires the catalog SHA-256, a valid Authenticode signature and an allowed signer.
    .DESCRIPTION
        The hash is checked first so a tampered file is never parsed for a signature.
        The signer certificate's simple name must match signer_subjects exactly (case-sensitive).
    .PARAMETER Package
        Catalog record with sha256 and signer_subjects.
    .PARAMETER Path
        Installer file to verify.
    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
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
    <#
    .SYNOPSIS
        Runs an EXE or MSI installer silently and returns its exit code.
    .DESCRIPTION
        MSI packages run through msiexec with verbose logging next to the installer.
        A timeout throws System.TimeoutException and leaves the installer running killing Windows Installer mid-transaction would make the image less trustworthy.
    .PARAMETER Package
        Catalog record with installer_type and silent_arguments.
    .PARAMETER Path
        Verified installer file.
    .PARAMETER TimeoutSeconds
        Maximum time to wait for the installer process.
    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
    param(
        [Parameter(Mandatory)]
        $Package,
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds
    )
    $arguments = [string]$Package.silent_arguments
    $executable = $Path
    if ($Package.installer_type -eq 'msi') {
        $executable = "$env:SystemRoot\System32\msiexec.exe"
        $log = [IO.Path]::ChangeExtension($Path, '.log')
        $arguments = "/i `"$Path`" $arguments /L*v `"$log`""
    }
    $process = Start-Process -FilePath $executable -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw [TimeoutException]::new("Installer timeout after $TimeoutSeconds seconds; installation may still be running; discard this VM")
    }
    if ($null -eq $process.ExitCode) {
        throw 'Installer exit code is unavailable'
    }
    return [int]$process.ExitCode
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Returns true when Windows records a pending restart.
    .NOTES
        Author  : Lars Krogh
        Version : 1.0.0
    #>
    return (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or ($null -ne (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue))
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$result = @{
    error           = ''
    fatal           = $false
    version         = ''
    reboot_required = $false
    exit_code       = $null
}

try {
    if ($Action -eq 'Facts') {
        $result = Get-WindowsPlatform
    }
    else {
        $request = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $package = $request.package
        $result.version = Get-InstalledVersion -Detection $package.detection
        if ($Action -eq 'Install') {
            $platform = Get-WindowsPlatform
            if ($platform.architecture -ne 'AMD64' -or @($package.supported_os) -notcontains $platform.family) {
                throw 'Unsupported operating system or architecture'
            }
            if ($platform.server_core -and -not $package.server_core) {
                throw 'Package requires Desktop Experience'
            }
            Assert-Installer -Package $package -Path $request.installer_path
            $result.exit_code = Invoke-Installer -Package $package -Path $request.installer_path -TimeoutSeconds $request.timeout_seconds
            $result.reboot_required = (@($package.reboot_codes) -contains $result.exit_code) -or (Test-PendingReboot)
            if ($result.exit_code -eq 1641) {
                $result.fatal = $true
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
    if ($_.Exception -is [TimeoutException]) {
        $result.fatal = $true
    }
}
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
