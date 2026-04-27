#!/usr/bin/env bash
# 🐋 orca installer — symlink this repo into ~/.claude/skills/orca/
#
# Backs up any existing skill at the target path before linking.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HOME/.claude/skills/orca"

echo "🐋 orca installer"
echo "  source: $REPO_ROOT"
echo "  target: $TARGET"
echo

if [[ -L "$TARGET" ]]; then
  current="$(readlink "$TARGET")"
  if [[ "$current" == "$REPO_ROOT" ]]; then
    echo "✅ Already linked correctly. Nothing to do."
    exit 0
  fi
  echo "↩  Existing symlink points elsewhere → $current"
  echo "   Removing it (link only, no data loss)."
  rm "$TARGET"
elif [[ -e "$TARGET" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$TARGET.bak.$stamp"
  echo "📦 Existing skill dir at $TARGET"
  echo "   Backing it up to $backup"
  mv "$TARGET" "$backup"
fi

mkdir -p "$(dirname "$TARGET")"
ln -s "$REPO_ROOT" "$TARGET"

echo "✅ Linked $TARGET → $REPO_ROOT"
echo
echo "Next steps:"
echo "  1. Restart Claude Code so the skill registry picks up the change."
echo "  2. Invoke with /orca."
echo "  3. (Optional) Copy bundled playbooks into ~/.orca/playbooks/ to customize them globally."
