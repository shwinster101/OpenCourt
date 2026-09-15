#!/usr/bin/env bash
# One-shot: initialize git, commit, create the GitHub repo, push, enable Pages.
# Requires: git, and the GitHub CLI (`brew install gh` then `gh auth login`).
# Usage: ./push-to-github.sh [repo-name]   (default: opencourt-la)
set -euo pipefail

REPO="${1:-opencourt-la}"

# --- Safety checks -----------------------------------------------------------
if grep -q "YOUR_GOOGLE_MAPS_API_KEY" index.html; then
  echo "⚠️  index.html still has the placeholder Maps key. The site will deploy but the map"
  echo "    won't render. Add a referrer-restricted key first (docs/SETUP.md §3) or continue."
  read -rp "Continue anyway? [y/N] " ans; [[ "${ans:-N}" =~ ^[Yy]$ ]] || exit 1
fi
if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1 && git status --porcelain | grep -Eq '\.env'; then
  echo "❌ A .env file is staged or untracked-visible. Aborting."; exit 1
fi
python3 -c "import json;json.load(open('assets/data/courts.json'));json.load(open('assets/data/grand-slams.json'))" \
  && echo "✓ JSON valid"

# --- Git ---------------------------------------------------------------------
[ -d .git ] || git init -q
git add .
git commit -qm "OpenCourt LA v1.0.1 — Phase 1 dashboard + consolidated SRS" || echo "(nothing new to commit)"
git branch -M main

# --- GitHub ------------------------------------------------------------------
if command -v gh >/dev/null; then
  if ! gh repo view "$REPO" >/dev/null 2>&1; then
    gh repo create "$REPO" --public --source=. --remote=origin --push \
      --description "Find open tennis & pickleball courts in LA County"
  else
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "$(gh repo view "$REPO" --json sshUrl -q .sshUrl)"
    git push -u origin main
  fi
  # Point Pages at the Actions workflow
  gh api -X POST "repos/{owner}/$REPO/pages" -f build_type=workflow >/dev/null 2>&1 \
    || gh api -X PUT "repos/{owner}/$REPO/pages" -f build_type=workflow >/dev/null 2>&1 || true
  echo "✓ Pushed. Pages will build in ~30 s:"
  echo "  https://$(gh api user -q .login).github.io/$REPO/"
else
  echo "gh CLI not found. Create the repo at https://github.com/new, then:"
  echo "  git remote add origin git@github.com:YOUR_USERNAME/$REPO.git"
  echo "  git push -u origin main"
  echo "Then Settings → Pages → Source: GitHub Actions."
fi
