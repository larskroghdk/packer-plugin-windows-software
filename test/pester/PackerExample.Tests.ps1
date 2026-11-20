BeforeAll {
    . "$PSScriptRoot/../../examples/Invoke-PackerExample.ps1"
    $script:powerShellExecutable = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $script:stepOptions = @{
        Executable       = $script:powerShellExecutable
        WorkingDirectory = $TestDrive
        Environment      = @{}
        Step             = 'Fixture command'
        FailureAdvice    = 'Check the fixture.'
    }
}

Describe 'Packer example native command boundary' {
    It 'captures successful tool output only when requested' {
        $result = Invoke-ExampleStep @stepOptions -Arguments @('-NoProfile', '-Command', 'Write-Output "fixture-output"') -CaptureOutput
        $result.Trim() | Should -Be 'fixture-output'
    }
    It 'withholds standard output and standard error by default' {
        $result = @(Invoke-ExampleStep @stepOptions -Arguments @('-NoProfile', '-Command', '[Console]::Out.WriteLine("private-output"); [Console]::Error.WriteLine("private-error")') *>&1)
        ($result -join '') | Should -Not -Match 'private-output|private-error'
    }
    It 'preserves native exit codes without exposing tool error text' {
        $failure = $null
        try {
            Invoke-ExampleStep @stepOptions -Arguments @('-NoProfile', '-Command', '[Console]::Error.WriteLine("private-credential"); exit 17')
        }
        catch { $failure = $_.Exception }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Data['ExitCode'] | Should -Be 17
        $failure.Message | Should -Match 'Fixture command failed'
        $failure.Message | Should -Not -Match 'private-credential'
    }
    It 'passes variables only to the child environment' {
        $options = $stepOptions.Clone()
        $options.Environment = @{ PKR_VAR_example_fixture = 'fixture-value' }
        $result = Invoke-ExampleStep @options -Arguments @('-NoProfile', '-Command', '[Console]::Write($env:PKR_VAR_example_fixture)') -CaptureOutput
        $result | Should -Be 'fixture-value'
        [Environment]::GetEnvironmentVariable('PKR_VAR_example_fixture') | Should -BeNullOrEmpty
    }
    It 'removes inherited Packer logging settings from child processes' {
        $options = $stepOptions.Clone()
        $options.Environment = @{ PACKER_LOG = '1'; PACKER_LOG_PATH = 'sensitive.log' }
        $result = Invoke-ExampleStep @options -Arguments @('-NoProfile', '-Command', '[Console]::Write("log=" + $env:PACKER_LOG + ";path=" + $env:PACKER_LOG_PATH)') -CaptureOutput
        $result | Should -Be 'log=;path='
    }
    It 'keeps arguments out of verbose and debug diagnostics' {
        $result = @(Invoke-ExampleStep @stepOptions -Arguments @('-NoProfile', '-Command', 'Write-Output "private-argument-value"') -Verbose -Debug *>&1)
        ($result -join '') | Should -Not -Match 'private-argument-value'
    }
}
