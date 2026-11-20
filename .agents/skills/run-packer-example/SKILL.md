---
name: run-packer-example
description: Build the local windows-software plugin and run examples/windows-software.pkr.hcl through examples/Invoke-PackerExample.ps1 - validate-only, or a live installation smoke test against an explicitly selected disposable Windows VM over WinRM TLS. Use to prove real installation behavior or to debug the example runner.
---

# Run the Packer example

`examples/Invoke-PackerExample.ps1` builds the plugin for the host, installs it into an isolated `PACKER_PLUGIN_PATH` under `.cache/packer-example/`, verifies Packer resolves exactly that binary, then runs `packer init`, `validate` and (unless `-ValidateOnly`) `build`. See `examples/README.md` for variables and failure handling.

## Validate only

Safe without a VM; no connection is made:

```powershell
./examples/Invoke-PackerExample.ps1 -ValidateOnly -NonInteractive -Variables @{ winrm_host = 'vm.example.test'; winrm_username = 'Administrator'; winrm_password = 'unused' }
packer fmt -check examples
```

## Live installation

Run a build only when the user names the disposable VM in the current task and confirms it may be modified. The build installs every listed package on that VM. Never target the development workstation, a shared server or a VM someone still needs.

- Credentials come from the user: `-VariableFile` with an untracked `.pkrvars.hcl`, `PKR_VAR_*` variables, or prompts. Never write credentials to tracked files, command lines or logs.
- The runner withholds native output and strips `PACKER_LOG`; do not re-enable Packer logging to debug, since it can expose credentials. Use `reports/windows-software.json` instead.
- After a failure, timeout or `fatal` result, the VM must be discarded or reverted to a snapshot before retrying. Do not retry installers on the same VM.

Report which packages installed, were skipped or failed, the reported final versions and reboot requirements, and whether the VM was reverted. A successful validate-only run is not installation evidence.
