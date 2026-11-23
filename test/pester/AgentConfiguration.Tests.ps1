BeforeDiscovery {
    $root = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:skills = @(Get-ChildItem -LiteralPath (Join-Path $root '.agents/skills') -Directory | ForEach-Object { @{ Name = $_.Name } })
    $script:documents = @('AGENTS.md', 'CLAUDE.md', 'CONTRIBUTING.md', 'README.md', 'examples/README.md', '.github/copilot-instructions.md') +
    @(Get-ChildItem -LiteralPath (Join-Path $root '.agents') -Recurse -Filter SKILL.md | ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') }) | ForEach-Object { @{ Path = $_ } }
}

BeforeAll {
    $script:root = (Resolve-Path "$PSScriptRoot/../..").Path
    function Get-SkillFrontmatter {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )
        $text = Get-Content -LiteralPath $Path -Raw
        if ($text -notmatch '(?s)\A---\r?\n(.*?)\r?\n---\r?\n') {
            throw "$Path has no frontmatter"
        }
        $fields = @{}
        foreach ($line in $Matches[1] -split '\r?\n') {
            if ($line -match '^(\w+):\s*(.+)$') {
                $fields[$Matches[1]] = $Matches[2]
            }
        }
        return $fields
    }
}

Describe 'Shared agent skill <Name>' -ForEach $skills {
    BeforeAll {
        $script:shared = Join-Path $root ".agents/skills/$Name/SKILL.md"
    }
    It 'names itself after its directory' {
        (Get-SkillFrontmatter $shared).name | Should -Be $Name
        (Get-SkillFrontmatter $shared).description | Should -Not -BeNullOrEmpty
    }
    It 'is listed in AGENTS.md' {
        Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw | Should -Match ([regex]::Escape("``$Name``"))
    }
}

Describe 'Agent configuration' {
    It 'keeps reusable skills in one shared location' {
        Test-Path -LiteralPath (Join-Path $root '.claude/skills') | Should -BeFalse
    }
    It 'imports shared architecture and standards into CLAUDE.md' {
        $text = Get-Content -LiteralPath (Join-Path $root 'CLAUDE.md') -Raw
        foreach ($path in @('architecture/overview.md', 'standards/go.md', 'standards/powershell.md', 'standards/testing.md', 'standards/security.md')) {
            $text | Should -Match ([regex]::Escape("@.agents/$path"))
            Join-Path $root ".agents/$path" | Should -Exist
        }
    }
    It 'has read-only Claude reviewers for Go, PowerShell and security' {
        foreach ($name in @('go', 'powershell', 'security')) {
            $path = Join-Path $root ".claude/agents/$name-reviewer.md"
            $path | Should -Exist
            $fields = Get-SkillFrontmatter $path
            $fields.name | Should -Be "$name-reviewer"
            $fields.tools | Should -Be 'Read, Glob, Grep'
            Get-Content -LiteralPath $path -Raw | Should -Match ([regex]::Escape(".agents/standards/$name.md"))
        }
    }
}

Describe 'Repository paths referenced in <Path>' -ForEach $documents {
    It 'exist' {
        $text = Get-Content -LiteralPath (Join-Path $root $Path) -Raw
        $references = [regex]::Matches($text, '`((?:\.?[\w.-]+/)+[\w.-]+\.(?:go|ps1|json|yml|yaml|md|hcl|py|txt))`') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $documentDirectory = Split-Path -Parent (Join-Path $root $Path)
        $missing = @($references | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $root $_)) -and
                -not (Test-Path -LiteralPath (Join-Path $documentDirectory $_))
            } | Where-Object {
                & git -C $root check-ignore -q --no-index -- $_
                $LASTEXITCODE -ne 0
            })
        $missing | Should -BeNullOrEmpty -Because "$Path references files that do not exist"
    }
}
