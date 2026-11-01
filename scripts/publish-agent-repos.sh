#!/usr/bin/env bash
# One-time local setup: publish the four agent workspaces as GitHub repos so
# the pipeline can clone them at runtime. Run from a machine that has both the
# workspace directories and `gh` authenticated against the factory org.
#
# Usage: scripts/publish-agent-repos.sh [org] [public|private]
#
# Excludes: .work/, node_modules/, and any git metadata of the source dir.
set -euo pipefail

# Stale VS Code js-debug env: NODE_OPTIONS may point at a deleted bootloader.js,
# which crashes any Node-based git askpass/credential helper mid-push. Harmless
# outside VS Code.
unset NODE_OPTIONS VSCODE_INSPECTOR_OPTIONS

ORG="${1:-lmck-factory}"
VIS="${2:-private}"
SRC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKSPACES=(product-manager solution-architect backend-developer web-developer)

command -v gh >/dev/null || { echo "gh CLI is required" >&2; exit 1; }
gh auth status >/dev/null || { echo "run 'gh auth login' first" >&2; exit 1; }

for ws in "${WORKSPACES[@]}"; do
  SRC="$SRC_ROOT/$ws"
  [ -d "$SRC" ] || { echo "workspace dir not found: $SRC" >&2; exit 1; }
  [ -d "$SRC/.opencode" ] || { echo "not an agent workspace (missing .opencode/): $SRC" >&2; exit 1; }

  REPO="$ORG/$ws"
  echo "==> publishing $SRC -> github.com/$REPO ($VIS)"
  gh repo create "$REPO" --"$VIS" --description "Factory stage workspace: $ws" 2>/dev/null \
    || echo "    repo $REPO already exists — pushing update"

  TMP=$(mktemp -d)
  # Copy workspace content without scratch/dependency dirs or local git meta.
  tar -C "$SRC" \
    --exclude='.work' \
    --exclude='node_modules' \
    --exclude='.git' \
    -cf - . | tar -C "$TMP" -xf -
  cd "$TMP"
  git init -q -b main
  git add -A
  git -c user.name="factory-setup" -c user.email="factory-setup@users.noreply.github.com" \
    commit -q -m "chore: publish $ws workspace"
  git push -q "https://github.com/${REPO}.git" main --force
  cd - >/dev/null
  rm -rf "$TMP"
  echo "    done"
done

echo
echo "All four agent repos published. Next: set the agent-runner repo secrets/vars"
echo "(see docs/setup.md)."
