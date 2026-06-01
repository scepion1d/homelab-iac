# Repo init for Windows PowerShell.
#
# One-shot setup. Idempotent — safe to re-run after `git pull`.
#
# What it does:
#   1. Point git at the repo's versioned hooks (.github/hooks/).
#   2. Sanity-check required tools (git, yq).
#   3. Print a summary of what's now active.
#
# Re-run after pulling new commits if you want to make sure the hooks
# directory still resolves and tools are present.
#
# NOTE: the pre-commit hook is a zsh script. On Windows it runs inside
# git's bundled bash (msys2). That works out of the box because the file
# is committed with LF line endings (see .gitattributes).
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

Write-Host "==> homelab-iac init"

# 1. Git hooks path.
git config core.hooksPath .github/hooks | Out-Null
$path = git config core.hooksPath
Write-Host "  hooks path:  $path"

# 2. Tool checks (warn-only; hooks themselves fail loudly if a tool is missing).
$missing = @()
foreach ($tool in @('git', 'yq')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $missing += $tool
    }
}

if ($missing.Count -gt 0) {
    Write-Host "  tools:       MISSING -> $($missing -join ', ')"
    Write-Host "               install hint: winget install MikeFarah.yq"
} else {
    Write-Host "  tools:       git, yq present"
}

Write-Host "  done."
