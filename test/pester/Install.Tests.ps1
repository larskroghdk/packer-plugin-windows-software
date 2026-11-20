BeforeAll {
    . "$PSScriptRoot/../../guest/Install.ps1" -Action Inspect -OutputPath unused
}

Describe 'Installer trust boundary' {
    BeforeEach {
        $script:package = [pscustomobject]@{
            sha256          = 'abc';
            signer_subjects = @('Microsoft Corporation')
        }
        Mock Get-FileHash { @{ Hash = 'abc' } }
        $script:certificate = [pscustomobject]@{}
        $script:certificate | Add-Member ScriptMethod GetNameInfo { param($kind, $issuer) 'Microsoft Corporation' }
        Mock Get-AuthenticodeSignature { @{
                Status            = 'Valid';
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
        Mock Get-AuthenticodeSignature { @{
                Status            = 'NotTrusted';
                SignerCertificate = $script:certificate
            }
        }
        { Assert-Installer -Package $package -Path 'TestDrive:/installer.exe' } | Should -Throw '*Invalid Authenticode*'
    }
    It 'rejects a different publisher even when Windows trusts it' {
        $package.signer_subjects = @('Another Vendor')
        { Assert-Installer -Package $package -Path 'TestDrive:/installer.exe' } | Should -Throw '*Unexpected Authenticode signer*'
    }
}

Describe 'Installed version detection' {
    It 'reads file metadata without invoking the installer' {
        Mock Test-Path { $true }
        Mock Get-Item { @{
                VersionInfo = @{
                    ProductVersion = '7.5.4 SHA:123'
                }
            }
        }
        Get-InstalledVersion -Detection @{
            type = 'file';
            path = 'TestDrive:/pwsh.exe'
        } | Should -Be '7.5.4'
    }
    It 'returns empty for absent software' {
        Mock Test-Path { $false }
        Get-InstalledVersion -Detection @{
            type = 'file';
            path = 'TestDrive:/missing.exe'
        } | Should -Be ''
    }
    It 'reads the VC runtime registry value including its v prefix' {
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [pscustomobject]@{ Version = 'v14.44.35211.00' } }
        Get-InstalledVersion -Detection @{
            type  = 'registry';
            path  = 'TestDrive:/runtime';
            value = 'Version'
        } | Should -Be '14.44.35211.00'
    }
}

Describe 'Silent execution and reboot policy' {
    BeforeEach {
        $script:process = [pscustomobject]@{ ExitCode = 3010 }
        $script:process | Add-Member ScriptMethod WaitForExit { param($milliseconds) $true }
        $script:process | Add-Member ScriptMethod Refresh { }
        Mock Start-Process { $script:process }
    }
    It 'uses msiexec with the declared silent and reboot suppression arguments' {
        $code = Invoke-Installer -Package @{
            installer_type   = 'msi';
            silent_arguments = '/qn /norestart REBOOT=ReallySuppress'
        } -Path 'C:\test\example.msi' -TimeoutSeconds 60
        $code | Should -Be 3010
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $ArgumentList -like '*/qn /norestart REBOOT=ReallySuppress*' -and $FilePath -like '*msiexec.exe' }
    }
    It 'captures failed installation exit codes for the caller' {
        $process.ExitCode = 1603
        Invoke-Installer -Package @{
            installer_type   = 'exe';
            silent_arguments = '/quiet /norestart'
        } -Path 'C:\test\example.exe' -TimeoutSeconds 60 | Should -Be 1603
    }
    It 'fails a timed out installer without killing Windows Installer' {
        $process | Add-Member ScriptMethod WaitForExit { param($milliseconds) $false } -Force
        { Invoke-Installer -Package @{
                installer_type   = 'exe';
                silent_arguments = '/quiet /norestart'
            } -Path 'C:\test\example.exe' -TimeoutSeconds 1
        } | Should -Throw '*timeout*'
    }
    It 'detects a pending reboot marker' {
        Mock Test-Path { $true }
        Test-PendingReboot | Should -BeTrue
    }
}

Describe 'Windows platform detection' {
    BeforeAll {
        . "$PSScriptRoot/../../guest/Install.ps1" -Action Facts -OutputPath unused
    }
    It 'returns Server Core as an explicit capability flag' {
        Mock Get-CimInstance { [pscustomobject]@{
                Caption     = 'Windows Server 2022';
                BuildNumber = '20348';
                ProductType = 3
            }
        }
        Mock Get-ItemProperty { [pscustomobject]@{
                InstallationType = 'Server Core'
            }
        }
        $facts = Get-WindowsFacts
        $facts.family | Should -Be 'server2022'
        $facts.server_core | Should -BeTrue
    }
    It 'distinguishes Desktop Experience from Server Core' {
        Mock Get-CimInstance { [pscustomobject]@{
                Caption     = 'Windows Server 2025';
                BuildNumber = '26100';
                ProductType = 3
            }
        }
        Mock Get-ItemProperty { [pscustomobject]@{
                InstallationType = 'Server'
            }
        }
        (Get-WindowsFacts).server_core | Should -BeFalse
    }
    It 'normalizes vendor version component differences' {
        (ConvertTo-PackageVersion '26.003.22110') | Should -Be (ConvertTo-PackageVersion '26.3.22110.0')
    }
}
