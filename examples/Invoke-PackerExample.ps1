#requires -Version 7.4

<#
.SYNOPSIS
    Builds the local plugin and runs the existing Windows Packer example.

.DESCRIPTION
    Installs the local plugin in an isolated plugin directory, then runs Packer init, validate and build against windows-software.pkr.hcl.
    Uses the repository root as Packer's working directory so catalog and report paths keep their existing meaning.
    Native tool output and variable values are not logged, including in verbose/debug mode.
    Only the explicitly configured disposable Windows VM is provisioned.

.PARAMETER Variables
    Values for the existing HCL variables.
    Values are passed through child-process PKR_VAR environment variables, never command-line arguments.
    SecureString values are accepted.
    Existing PKR_VAR variables are inherited when not overridden here.

.PARAMETER VariableFile
    Optional .pkrvars.hcl files, applied in order.
    Relative paths are resolved from the caller's working directory.
    Files override environment-based variables.
    When omitted, examples/windows-software.pkrvars.hcl is used if present.

.PARAMETER NonInteractive
    Disables prompts for missing WinRM values.
    Supply values through Variables, PKR_VAR environment variables or variable files; Packer validates completeness.

.PARAMETER ValidateOnly
    Prepares the local plugin and runs init and validate without provisioning a VM.

.EXAMPLE
    ./examples/Invoke-PackerExample.ps1
    Prompts for missing connection values when no variable file is selected.

.EXAMPLE
    ./examples/Invoke-PackerExample.ps1 -VariableFile ./private.pkrvars.hcl -Verbose
    Runs the existing example using a private variable file.

.EXAMPLE
    ./examples/Invoke-PackerExample.ps1 -Variables @{ winrm_host = 'vm.example.test'; winrm_username = 'Administrator'; winrm_password = (Read-Host 'Password' -AsSecureString) } -NonInteractive
    Supplies connection variables without putting the password in command history.

.NOTES
    Author: Lars Krogh
    Version: 1.0.0
    Requires Packer, Go (see go.mod), and a disposable Windows VM with WinRM TLS.
    PowerShell -Debug enables runner diagnostics, not Packer's sensitive debug logs.
    Exit codes: failed native command's code, 1 for runner errors, 0 for success.
#>

[CmdletBinding()]
param(
    [hashtable]$Variables = @{},
    [string[]]$VariableFile = @(),
    [switch]$NonInteractive,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

function Invoke-ExampleStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Executable,
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory)]
        [hashtable]$Environment,
        [Parameter(Mandatory)]
        [string]$Step,
        [Parameter(Mandatory)]
        [string]$FailureAdvice,
        [switch]$CaptureOutput
    )
    Write-Verbose $Step
    Write-Debug "Starting step: $Step. Tool arguments and output are withheld."
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    foreach ($name in $Environment.Keys) {
        $startInfo.Environment[$name] = [string]$Environment[$name]
    }
    [void]$startInfo.Environment.Remove('PACKER_LOG')
    [void]$startInfo.Environment.Remove('PACKER_LOG_PATH')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Unable to start step: $Step."
        }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $outputTask.GetAwaiter().GetResult()
        $null = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $failure = [InvalidOperationException]::new("$Step failed (exit $($process.ExitCode)). $FailureAdvice Native output is withheld to protect sensitive values.")
            $failure.Data['ExitCode'] = $process.ExitCode
            throw $failure
        }
        if ($CaptureOutput) { return $output }
    }
    finally { $process.Dispose() }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$startedAt = [DateTimeOffset]::Now
$timer = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 1
$status = 'Failed'

Write-Information -InformationAction Continue "Packer example started: $($startedAt.ToString('o'))"
try {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $template = Join-Path $PSScriptRoot 'windows-software.pkr.hcl'
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
        throw 'The existing windows-software.pkr.hcl example is missing.'
    }
    $packer = Get-Command packer -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $packer) {
        throw 'Packer is unavailable. Install Packer and add it to PATH.'
    }
    $go = Get-Command go -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $go) {
        throw 'Go is unavailable. Install the Go version specified by go.mod and add it to PATH.'
    }
    $variablePaths = @()
    if ($VariableFile.Count -eq 0) {
        $defaultVariableFile = Join-Path $PSScriptRoot 'windows-software.pkrvars.hcl'
        if (Test-Path -LiteralPath $defaultVariableFile -PathType Leaf) {
            $VariableFile = @($defaultVariableFile)
        }
    }
    foreach ($path in $VariableFile) {
        if (-not $path.EndsWith('.pkrvars.hcl', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Each VariableFile must be an existing .pkrvars.hcl file.'
        }
        $variablePaths += (Resolve-Path -LiteralPath $path).ProviderPath
    }
    $childEnvironment = @{}
    foreach ($name in $Variables.Keys) {
        if ([string]$name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw 'Variable names must be valid HCL identifiers.'
        }
        $value = $Variables[$name]
        if ($null -eq $value) {
            throw 'Variable values cannot be null.'
        }
        if ($value -is [Security.SecureString]) {
            $value = [Net.NetworkCredential]::new('', $value).Password
        }
        $childEnvironment["PKR_VAR_$name"] = [string]$value
    }
    if (-not $NonInteractive -and $variablePaths.Count -eq 0) {
        foreach ($name in @('winrm_host', 'winrm_username', 'winrm_password')) {
            $environmentName = "PKR_VAR_$name"
            if (-not $childEnvironment.ContainsKey($environmentName) -and -not [Environment]::GetEnvironmentVariable($environmentName)) {
                if ($name -eq 'winrm_password') {
                    $secret = Read-Host 'Disposable VM WinRM password' -AsSecureString
                    $childEnvironment[$environmentName] = [Net.NetworkCredential]::new('', $secret).Password
                }
                else { $childEnvironment[$environmentName] = Read-Host "Disposable VM $name" }
            }
        }
    }
    $runDirectory = Join-Path $repositoryRoot ".cache/packer-example/$([guid]::NewGuid().ToString('N'))"
    $pluginDirectory = Join-Path $runDirectory 'plugins'
    $null = New-Item -ItemType Directory -Path $pluginDirectory -Force
    $childEnvironment['PACKER_PLUGIN_PATH'] = $pluginDirectory
    $stepOptions = @{ WorkingDirectory = $repositoryRoot; Environment = $childEnvironment }
    $hostPlatform = Invoke-ExampleStep @stepOptions -Executable $go.Source -Arguments @('env', '-json', 'GOHOSTOS', 'GOHOSTARCH') -Step 'Detect Go host platform' -FailureAdvice 'Check your Go toolchain installation.' -CaptureOutput | ConvertFrom-Json
    $childEnvironment['GOOS'] = $hostPlatform.GOHOSTOS
    $childEnvironment['GOARCH'] = $hostPlatform.GOHOSTARCH
    $binaryName = if ($hostPlatform.GOHOSTOS -eq 'windows') {
        'packer-plugin-windows-software.exe'
    }
    else {
        'packer-plugin-windows-software'
    }
    $binary = Join-Path $runDirectory $binaryName
    Write-Information -InformationAction Continue 'Preparing the local plugin...'
    Invoke-ExampleStep @stepOptions -Executable $go.Source -Arguments @('build', '-ldflags=-X main.versionPrerelease=', '-o', $binary, '.') -Step 'Build local plugin' -FailureAdvice 'Check go.mod dependencies and run go build from the repository root.'
    $description = Invoke-ExampleStep @stepOptions -Executable $binary -Arguments @('describe') -Step 'Inspect local plugin' -FailureAdvice 'The built binary must implement the Packer plugin protocol.' -CaptureOutput | ConvertFrom-Json
    if (-not $description.version -or -not $description.api_version) {
        throw 'The local plugin returned incomplete describe metadata.'
    }
    Invoke-ExampleStep @stepOptions -Executable $packer.Source -Arguments @('plugins', 'install', '-path', $binary, 'github.com/larskroghdk/windows-software') -Step 'Install local plugin' -FailureAdvice 'Check Packer version and permissions on the isolated plugin directory.'
    Write-Information -InformationAction Continue 'Initializing the existing Packer example...'
    Invoke-ExampleStep @stepOptions -Executable $packer.Source -Arguments @('init', $template) -Step 'Packer init' -FailureAdvice 'Check the required_plugins block and network access for other required plugins.'
    $required = Invoke-ExampleStep @stepOptions -Executable $packer.Source -Arguments @('plugins', 'required', $template) -Step 'Verify example plugin resolution' -FailureAdvice 'Check the example version constraint against the local plugin version.' -CaptureOutput
    $installed = @(Get-ChildItem -LiteralPath $pluginDirectory -Recurse -File | Where-Object { $_.Name -match '^packer-plugin-windows-software_v' -and $_.Name -notlike '*SHA256SUM*' })
    if ($installed.Count -ne 1 -or -not $required.Contains($installed[0].FullName) -or (Get-FileHash -LiteralPath $binary).Hash -ne (Get-FileHash -LiteralPath $installed[0].FullName).Hash) {
        throw 'The example did not resolve exclusively to the locally built plugin. Inspect the isolated plugin directory and required_plugins constraint.'
    }
    Write-Verbose "Verified local plugin version $($description.version)."
    $variableArguments = @($variablePaths | ForEach-Object { "-var-file=$_" })
    Write-Information -InformationAction Continue 'Validating the Packer example...'
    Invoke-ExampleStep @stepOptions -Executable $packer.Source -Arguments (@('validate') + $variableArguments + @($template)) -Step 'Packer validate' -FailureAdvice 'Check required WinRM variables, variable file syntax and the validated package catalog.'
    if ($ValidateOnly) {
        $status = 'Validated; build not requested'
    }
    else {
        Write-Information -InformationAction Continue 'Building against the configured disposable Windows VM...'
        Invoke-ExampleStep @stepOptions -Executable $packer.Source -Arguments (@('build', '-on-error=abort', '-color=false') + $variableArguments + @($template)) -Step 'Packer build' -FailureAdvice 'Check VM reachability, WinRM TLS credentials and reports/windows-software.json. Discard a failed installation VM before retrying.'
        $status = 'Succeeded'
    }
    $exitCode = 0
}
catch {
    if ($_.Exception.Data.Contains('ExitCode')) {
        $exitCode = [int]$_.Exception.Data['ExitCode']
    }
    Write-Information -InformationAction Continue "Packer example failed: $($_.Exception.Message)"
}
finally {
    $timer.Stop()
    Write-Information -InformationAction Continue "Packer example ended: $([DateTimeOffset]::Now.ToString('o'))"
    Write-Information -InformationAction Continue "Duration: $($timer.Elapsed.ToString('c')); status: $status; exit code: $exitCode"
}
exit $exitCode
