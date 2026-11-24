@{
    Codex               = @{
        Command            = 'codex'
        Model              = ''
        TimeoutSeconds     = 900
        MaxAttempts        = 2
        MaxDiffBytes       = 400000
        BlockingSeverities = @('critical', 'high')
    }
    Gemini              = @{
        Command                   = 'gemini'
        Model                     = ''
        TimeoutSeconds            = 600
        MaxAttempts               = 2
        CacheDays                 = 7
        InputUsdPerMillionTokens  = 0
        OutputUsdPerMillionTokens = 0
    }
    Copilot             = @{
        Command             = 'copilot'
        Model               = ''
        TimeoutSeconds      = 900
        MaxAiCredits        = 0
        WriteRules          = @('*.md', 'docs/**', '.github/**')
        AllowedPathPatterns = @('*.md', 'docs/*', '.github/*')
        DenyTools           = @('shell(git commit)', 'shell(git push)', 'shell(git tag)', 'shell(git reset)', 'shell(git rebase)', 'shell(git checkout)', 'shell(gh:*)', 'write(.git/**)')
    }
    CheckTimeoutSeconds = 1200
    Checks              = @(
        @{ Name = 'gofmt'; Paths = @('*.go'); Command = @('gofmt', '-l', '.'); FailOnOutput = $true }
        @{ Name = 'go mod tidy'; Paths = @('*.go', 'go.mod', 'go.sum'); Command = @('go', 'mod', 'tidy', '-diff') }
        @{ Name = 'go vet'; Paths = @('*.go', 'go.mod', 'go.sum'); Command = @('go', 'vet', './...') }
        @{ Name = 'staticcheck'; Paths = @('*.go', 'go.mod', 'go.sum'); Command = @('sh', '-c', 'GOTOOLCHAIN=$(go env GOVERSION) go run honnef.co/go/tools/cmd/staticcheck@v0.7.0 ./...') }
        @{ Name = 'govulncheck'; Paths = @('go.mod', 'go.sum'); Command = @('go', 'run', 'golang.org/x/vuln/cmd/govulncheck@v1.10.0', './...') }
        @{ Name = 'go test'; Paths = @('*.go', 'go.mod', 'go.sum', 'guest/*', 'internal/*', 'packages/*'); Command = @('go', 'test', './...') }
        @{ Name = 'go build'; Paths = @('*.go', 'go.mod', 'go.sum'); Command = @('go', 'build', './...') }
        @{ Name = 'PSScriptAnalyzer'; Paths = @('*.ps1', '*.psd1'); Command = @('pwsh', '-NoProfile', '-Command', '$ErrorActionPreference = "Stop"; $r = @(Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning, Error); $r; if ($r) { exit 1 }') }
        @{ Name = 'guest Pester'; Paths = @('guest/*', 'test/pester/Install.Tests.ps1'); Command = @('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', '$ErrorActionPreference = "Stop"; $env:PSModulePath = (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WindowsPowerShell\Modules") + ";" + [Environment]::GetEnvironmentVariable("PSModulePath", "Machine"); Import-Module Pester -MinimumVersion 5.0; $c = New-PesterConfiguration; $c.Run.Path = "test/pester/Install.Tests.ps1"; $c.Run.Exit = $true; $c.Output.Verbosity = "Normal"; Invoke-Pester -Configuration $c') }
        @{ Name = 'Pester'; Paths = @('examples/*', 'test/pester/*', 'scripts/*'); Command = @('pwsh', '-NoProfile', '-Command', '$ErrorActionPreference = "Stop"; git init -q; Import-Module Pester -MinimumVersion 5.6.1; $c = New-PesterConfiguration; $c.Run.Path = "test/pester/PackerExample.Tests.ps1", "test/pester/AgentConfiguration.Tests.ps1"; $c.Run.Exit = $true; Invoke-Pester -Configuration $c') }
        @{ Name = 'agent workflow Pester'; Paths = @('scripts/ai/*', 'test/ai/*', '.githooks/*'); Command = @('pwsh', '-NoProfile', '-Command', '$ErrorActionPreference = "Stop"; Import-Module Pester -MinimumVersion 5.6.1; $c = New-PesterConfiguration; $c.Run.Path = "test/ai"; $c.Run.Exit = $true; $c.Output.Verbosity = "Normal"; Invoke-Pester -Configuration $c') }
        @{ Name = 'packer fmt'; Paths = @('*.hcl'); Command = @('packer', 'fmt', '-check', 'examples') }
        @{ Name = 'actionlint'; Paths = @('.github/workflows/*'); Command = @('sh', '-c', 'go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7 .github/workflows/*.yml') }
    )
}
