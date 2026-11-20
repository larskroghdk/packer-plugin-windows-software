# Repository instructions for GitHub Copilot

Follow [AGENTS.md](../AGENTS.md): it is the shared instruction file for every coding agent in this repository. Then read the skill in [.agents/skills](../.agents/skills/) that matches the task:

- `develop-windows-software` - provisioner, catalog or guest engine.
- `add-software-package` - package recipes.
- `publish-software-artifacts` - resolver, validation, publication and workflows.
- `run-packer-example` - the example runner and disposable-VM tests.

The rules that must never be broken, even when only this file is read:

- Never bypass SHA-256, Authenticode or exact signer checks, and never use `Win32_Product`.
- Never run installers on the developer workstation, or reboot the guest from the plugin.
- Never push, tag, publish releases or dispatch workflows unless the current task asks for it.
