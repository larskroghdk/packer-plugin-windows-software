<#
.SYNOPSIS
    Runs the repository's Go formatting, module, test, vet and build checks.

.DESCRIPTION
    Fails on the first problem.
    Builds the plugin into bin/ with the platform's executable name.
    Run from any directory; paths resolve from the repository root.

.EXAMPLE
    ./scripts/check.ps1

.NOTES
    Author  : Lars Krogh
    Version : 1.1.0
    Requires the Go toolchain named in go.mod.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    $files = @(git ls-files --cached --others --exclude-standard '*.go')
    if ($LASTEXITCODE -ne 0) {
        throw 'git ls-files failed'
    }
    if ($files.Count -gt 0) {
        $unformatted = & gofmt -l @files
        if ($LASTEXITCODE -ne 0 -or $unformatted) {
            throw "Go formatting required: $unformatted"
        }
    }
    $checks = @(
        , @('mod', 'tidy', '-diff')
        , @('test', './...')
        , @('vet', './...')
        , @('build', '-o', 'bin/', '.')
    )
    foreach ($arguments in $checks) {
        & go @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "go $arguments failed"
        }
    }
}
finally {
    Pop-Location
}
