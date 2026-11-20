BeforeAll {
    $script:engine = (Resolve-Path "$PSScriptRoot/../../guest/Install.ps1").Path
    . $script:engine -Action Inspect -OutputPath unused
}

Describe 'Installer trust boundary' {
    BeforeEach {
        $script:package = [pscustomobject]@{
            sha256          = 'abc'
            signer_subjects = @('Microsoft Corporation')
        }
        Mock Get-FileHash { @{ Hash = 'abc' } }
        $script:certificate = [pscustomobject]@{}
        $script:certificate | Add-Member ScriptMethod GetNameInfo { 'Microsoft Corporation' }
        Mock Get-AuthenticodeSignature {
            @{
                Status            = 'Valid'
                SignerCertificate = $script:certificate
            }
        }
    }
    It 'accepts a trusted signer with the exact checksum' {
        { Assert-Installer -Package $package -Path 'TestDrive:/installer.exe' } | Should -Not -Throw
    }
    It 'rejects tampering before reading a signature' {
        Mock Get-FileHash { @{ Hash = 'different' } }
        { Assert-Installer -Package $package -Path 'TestDrive:/installer.exe' } | Should -Throw '*SHA-256*'
        Should -Invoke Get-AuthenticodeSignature -Times 0
    }
    It 'rejects untrusted signatures' {
        Mock Get-AuthenticodeSignature {
            @{
                Status            = 'NotTrusted'
                SignerCertificate = $script:certificate
            }
        }
        { Assert-Installer -Package $package -Path 'TestDrive:/installer.exe' } | Should -Throw '*Invalid Authenticode*'
    }
    It 'rejects a different publisher even when Windows trusts it' {
        $package.signer_subjects = @('Another Vendor')
        { Assert-Installer -Package $package -Path 'TestDrive:/installer.exe' } | Should -Throw '*Unexpected Authenticode signer*'
    }
    It 'compares signer names case-sensitively' {
        $package.signer_subjects = @('microsoft corporation')
        { Assert-Installer -Package $package -Path 'TestDrive:/installer.exe' } | Should -Throw '*Unexpected Authenticode signer*'
    }
}

Describe 'Installed version detection' {
    It 'reads file metadata without invoking the installer' {
        Mock Test-Path { $true }
        Mock Get-Item {
            @{ VersionInfo = @{ ProductVersion = '7.5.4 SHA:123' } }
        }
        Get-InstalledVersion -Detection @{ type = 'file'; path = 'TestDrive:/pwsh.exe' } | Should -Be '7.5.4'
    }
    It 'returns empty for absent software' {
        Mock Test-Path { $false }
        Get-InstalledVersion -Detection @{ type = 'file'; path = 'TestDrive:/missing.exe' } | Should -Be ''
    }
    It 'reads the VC runtime registry value including its v prefix' {
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [pscustomobject]@{ Version = 'v14.44.35211.00' } }
        Get-InstalledVersion -Detection @{ type = 'registry'; path = 'TestDrive:/runtime'; value = 'Version' } | Should -Be '14.44.35211.00'
    }
    It 'fails rather than reporting absence for an unparseable version' {
        Mock Test-Path { $true }
        Mock Get-Item { @{ VersionInfo = @{ ProductVersion = 'unknown' } } }
        { Get-InstalledVersion -Detection @{ type = 'file'; path = 'TestDrive:/app.exe' } } | Should -Throw '*Cannot parse*'
    }
}

Describe 'Silent execution and reboot policy' {
    BeforeEach {
        $script:process = [pscustomobject]@{ ExitCode = 3010; Handle = [IntPtr]1 }
        $script:process | Add-Member ScriptMethod WaitForExit { $true }
        Mock Start-Process { $script:process }
    }
    It 'uses msiexec with the declared silent arguments and a per-package log' {
        $code = Invoke-Installer -Package @{
            installer_type   = 'msi'
            silent_arguments = '/qn /norestart REBOOT=ReallySuppress'
        } -Path 'C:\test\chrome.msi' -TimeoutSeconds 60
        $code | Should -Be 3010
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $FilePath -like '*msiexec.exe' -and
            $ArgumentList -like '/i "C:\test\chrome.msi" /qn /norestart REBOOT=ReallySuppress*' -and
            $ArgumentList -like '*/L`*v "C:\test\chrome.log"'
        }
    }
    It 'runs EXE installers directly with their silent arguments' {
        $null = Invoke-Installer -Package @{ installer_type = 'exe'; silent_arguments = '/quiet /norestart' } -Path 'C:\test\example.exe' -TimeoutSeconds 60
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -eq 'C:\test\example.exe' -and $ArgumentList -eq '/quiet /norestart' }
    }
    It 'captures failed installation exit codes for the caller' {
        $process.ExitCode = 1603
        Invoke-Installer -Package @{ installer_type = 'exe'; silent_arguments = '/quiet /norestart' } -Path 'C:\test\example.exe' -TimeoutSeconds 60 | Should -Be 1603
    }
    It 'never reports a missing exit code as success' {
        $process.ExitCode = $null
        { Invoke-Installer -Package @{ installer_type = 'exe'; silent_arguments = '/quiet' } -Path 'C:\test\example.exe' -TimeoutSeconds 60 } |
            Should -Throw '*exit code is unavailable*'
    }
    It 'raises a timeout exception without killing the installer' {
        $process | Add-Member ScriptMethod WaitForExit { $false } -Force
        $failure = $null
        try {
            Invoke-Installer -Package @{ installer_type = 'exe'; silent_arguments = '/quiet /norestart' } -Path 'C:\test\example.exe' -TimeoutSeconds 1
        }
        catch { $failure = $_.Exception }
        $failure | Should -BeOfType [TimeoutException]
    }
    It 'detects a pending reboot marker' {
        Mock Test-Path { $true }
        Test-PendingReboot | Should -BeTrue
    }
}

Describe 'Windows platform detection' {
    It 'returns Server Core as an explicit capability flag' {
        Mock Get-CimInstance { [pscustomobject]@{ Caption = 'Windows Server 2022'; BuildNumber = '20348'; ProductType = 3 } }
        Mock Get-ItemProperty { [pscustomobject]@{ InstallationType = 'Server Core' } }
        $platform = Get-WindowsPlatform
        $platform.family | Should -Be 'server2022'
        $platform.server_core | Should -BeTrue
    }
    It 'distinguishes Desktop Experience from Server Core' {
        Mock Get-CimInstance { [pscustomobject]@{ Caption = 'Windows Server 2025'; BuildNumber = '26100'; ProductType = 3 } }
        Mock Get-ItemProperty { [pscustomobject]@{ InstallationType = 'Server' } }
        (Get-WindowsPlatform).server_core | Should -BeFalse
    }
    It 'leaves unrecognised server builds without a family' {
        Mock Get-CimInstance { [pscustomobject]@{ Caption = 'Windows Server 2016'; BuildNumber = '14393'; ProductType = 3 } }
        Mock Get-ItemProperty { [pscustomobject]@{ InstallationType = 'Server' } }
        (Get-WindowsPlatform).family | Should -Be ''
    }
    It 'normalizes vendor version component differences' {
        (ConvertTo-PackageVersion '26.003.22110') | Should -Be (ConvertTo-PackageVersion '26.3.22110.0')
    }
}

Describe 'JSON action protocol' {
    It 'reads a UTF-8 request and writes the Inspect result' {
        $request = Join-Path $TestDrive 'request.json'
        $response = Join-Path $TestDrive 'response.json'
        $body = @{ package = @{ name = "Pr$([char]0x00FC)fung"; detection = @{ type = 'file'; path = (Join-Path $TestDrive 'missing.exe') } } } | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($request, $body, [Text.UTF8Encoding]::new($false))
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:engine -Action Inspect -InputPath $request -OutputPath $response
        $LASTEXITCODE | Should -Be 0
        $result = Get-Content -LiteralPath $response -Raw -Encoding UTF8 | ConvertFrom-Json
        $result.error | Should -Be ''
        $result.fatal | Should -BeFalse
        $result.version | Should -Be ''
    }
    It 'reports errors in the result instead of failing the process' {
        $response = Join-Path $TestDrive 'error.json'
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:engine -Action Inspect -InputPath (Join-Path $TestDrive 'absent.json') -OutputPath $response
        $LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath $response -Raw -Encoding UTF8 | ConvertFrom-Json).error | Should -Not -BeNullOrEmpty
    }
}
