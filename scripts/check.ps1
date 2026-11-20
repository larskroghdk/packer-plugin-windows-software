<# .SYNOPSIS Runs the repository's Go formatting, tests, analysis and build checks. #>
$ErrorActionPreference = 'Stop'
$files = @(git ls-files '*.go') + @(git ls-files --others --exclude-standard '*.go')
if ($files.Count -gt 0) {
    $unformatted = & gofmt -l @files
    if ($LASTEXITCODE -ne 0 -or $unformatted) { throw "Go formatting required: $unformatted" }
}
foreach ($arguments in @(@('test', './...'), @('vet', './...'), @('build', '-o', 'bin/packer-plugin-windows-software.exe', '.'))) {
    & go @arguments
    if ($LASTEXITCODE -ne 0) { throw "go $arguments failed" }
}
