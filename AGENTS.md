# Working on windows-software

For provisioner, package, guest engine or artifact workflow work, use the project skill at [.agents/skills/develop-windows-software/SKILL.md](.agents/skills/develop-windows-software/SKILL.md).

Use the Packer SDK lifecycle and the existing JSON protocol over the builder's WinRM communicator. Keep guest code compatible with Windows PowerShell 5.1. Do not use Win32_Product, reboot the guest or execute installers on the developer workstation.

Never bypass installer hashes, Authenticode trust or exact publisher identity to make a package pass. Versions and download URLs belong in manifests. Preserve immutable validated versions. Package recipes require explicit redistribution review before uploading installers to GitHub.

Run scripts/check.ps1, Python tests and isolated Pester tests before delivery. Live installation testing is allowed only against an explicitly selected disposable VM. Clearly distinguish mock/protocol validation, download/signature validation and real installation results.
