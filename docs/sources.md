# Vendor and SDK references

Reviewed on 2026-11-20. Package releases can change support; review new versions before approval.

- [Packer plugin SDK](https://github.com/hashicorp/packer-plugin-sdk): provisioner lifecycle and communicator.
- [Plugin loading specification](https://developer.hashicorp.com/packer/docs/plugins/creation/plugin-load-spec): binary naming and protocol metadata.
- [PowerShell installation](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows): supported MSI deployment and Windows platforms.
- [VC redistributable downloads](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist): current supported x64 runtime and official links.
- [Adobe Reader requirements](https://helpx.adobe.com/reader/desktop/system-requirements.html): x64 Windows client/server support.
- [Adobe distribution licensing](https://www.adobe.com/acrobat/pdf-reader/volume-distribution.html): redistribution requires separate review.
- [Chrome Enterprise requirements](https://support.google.com/chrome/a/answer/7100626): browser Windows platform requirements.
- [Edge supported systems](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-supported-operating-systems): Windows client and Server platform support.
- [Microsoft winget manifests](https://github.com/microsoft/winget-pkgs): discovery index, upstream hashes and vendor URLs; not itself the source of installer binaries.

The local review examined `../packer-plugin-windows-checkup`, `../packer-plugin-windows-cleanup` and `../packer-plugin-windows-features`. Their SDK registration, package layout, embedded scripts, guest JSON protocol, testing and release conventions informed this implementation. No unrelated cleanup or security-baseline payloads were copied.
