#!/usr/bin/env bash
# Repo init for macOS/Linux/git-bash shells.
#
# One-shot setup. Idempotent — safe to re-run after `git pull` to pick up
# new hooks or new tool requirements.
#
# What it does:
#   1. Point git at the repo's versioned hooks (`.github/hooks/`).
#   2. Make hooks executable locally (Windows git may strip the bit on clone).
#   3. Sanity-check required tools (`git`, `yq`).
#   4. Print a summary of what's now active.
#
# Re-run after pulling new commits if you want to make sure the hooks
# directory still resolves and tools are present.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> homelab-iac init"

# 1. Git hooks path.
git config core.hooksPath .github/hooks
echo "  hooks path:  $(git config core.hooksPath)"

# 2. Executable bit on hooks (Windows-friendly; no-op on POSIX if already +x).
chmod +x .github/hooks/* 2>/dev/null || true

# 3. Tool checks (warn-only; hooks themselves fail loudly if a tool is missing).
missing=()
for tool in git yq pwsh; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done

if (( ${#missing[@]} > 0 )); then
  echo "  tools:       MISSING -> ${missing[*]}"
  echo "               install hint (macOS):   brew install ${missing[*]}"
  echo "               install hint (Windows): winget install MikeFarah.yq"
else
  echo "  tools:       git, yq present"
fi

echo "  done."
