# PowerShell standards

Guest code targets Windows PowerShell 5.1 over the supplied Packer communicator. Follow [project constraints](../architecture/overview.md), existing JSON contracts and .gitattributes for encoding and line endings.

Keep incidental output off the success pipeline. Check native exit codes and dispose owned handles. Test absent, empty, singleton and multiple-item collections against the Go consumer. Preserve each plugin's existing mutation, reboot and recovery boundaries; do not import another plugin's operations.

Use [powershell-development](../skills/powershell-development/SKILL.md) and [testing](testing.md). Host PowerShell 7 analysis is not a guest-runtime test.
