# 🤝 Contributing

Thanks for helping improve windows-software. This project installs software into machine images, so changes are reviewed for trust and safety as well as correctness.

## 🧰 Prerequisites

- The Go version in `go.mod`
- PowerShell 7, plus Windows PowerShell 5.1 for guest engine tests
- Pester 5 and PSScriptAnalyzer
- Packer 1.11 or newer for the example
- Optional: staticcheck and actionlint (CI runs both)

## ✅ Before you open a pull request

```powershell
./scripts/check.ps1                                      # gofmt, go mod tidy -diff, tests, vet, build
staticcheck ./...
actionlint
Invoke-Pester -Path test/pester
powershell.exe -NoProfile -Command "Invoke-Pester -Path test/pester/Install.Tests.ps1"
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning, Error
packer fmt -check examples
```

In the pull request, say which checks you ran and which kind of evidence backs the change:

- 🧪 **mock or protocol tests**
- 🔏 **download and signature validation**
- 🖥️ **a real installation on a disposable VM**

## 🔐 Ground rules

- Never weaken SHA-256, Authenticode or exact signer checks to make a package pass.
- Keep guest code compatible with Windows PowerShell 5.1. Do not use `Win32_Product`, and never reboot the guest from the plugin.
- Versions and URLs belong in `packages/`, not in code. Do not edit `packages/catalog.json` by hand; the publication workflow appends to it.
- Do not upload vendor installers anywhere unless the package has an approved redistribution review.
- Never run the guest engine's install action on your own workstation. Live tests belong on a disposable VM.

## 📦 Adding a package

Most packages need only a recipe. Follow [the add-software-package guide](.agents/skills/add-software-package/SKILL.md), then validate the candidate download and signature without installing it:

```powershell
go run ./cmd/resolve-installers -package <id>
./scripts/validate-artifacts.ps1
```

## 🧭 Where things live

[AGENTS.md](AGENTS.md) describes the layout. The guides in [.agents/skills](.agents/skills/) cover each area in depth; they are written for coding agents but are equally useful to people.

## 🐛 Issues and security

Use the issue forms for bugs and package requests. Report security vulnerabilities privately through [GitHub security advisories](https://github.com/larskroghdk/packer-plugin-windows-software/security/advisories/new).
