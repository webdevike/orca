#!/usr/bin/env bash
# 🐋 orca installer — symlink this repo into ~/.claude/skills/orca/
#
# Backs up any existing skill at the target path before linking.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"
TARGET="$SKILLS_DIR/orca"
BACKUP_DIR="$HOME/.claude/.orca-backups"

echo "🐋 orca installer"
echo "  source:  $REPO_ROOT"
echo "  target:  $TARGET"
echo "  backups: $BACKUP_DIR"
echo

# Migrate any pre-existing backups that live under ~/.claude/skills/ — the
# skill scanner indexes them by frontmatter name (which is "orca") and the
# duplicate shadows the real symlink. Move them out of the skills dir.
shopt -s nullglob
legacy_backups=("$SKILLS_DIR"/orca.bak.*)
shopt -u nullglob
if (( ${#legacy_backups[@]} > 0 )); then
  mkdir -p "$BACKUP_DIR"
  for legacy in "${legacy_backups[@]}"; do
    dest="$BACKUP_DIR/$(basename "$legacy")"
    echo "🚚 Migrating legacy backup out of skills dir:"
    echo "     $legacy"
    echo "  → $dest"
    mv "$legacy" "$dest"
  done
  echo
fi

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
  mkdir -p "$BACKUP_DIR"
  backup="$BACKUP_DIR/orca.bak.$stamp"
  echo "📦 Existing skill dir at $TARGET"
  echo "   Backing it up to $backup (out of skills/ to avoid name collision)"
  mv "$TARGET" "$backup"
fi

mkdir -p "$SKILLS_DIR"
ln -s "$REPO_ROOT" "$TARGET"

echo "✅ Linked $TARGET → $REPO_ROOT"
echo

# Put the worker-side signal emitter on PATH so playbook prompts can call the
# bare `orca-signal` command. Mirrors the ~/.local/bin convention used elsewhere.
chmod +x "$REPO_ROOT/scripts/orca-signal" "$REPO_ROOT/scripts/read-signal.sh" 2>/dev/null || true
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
ln -sf "$REPO_ROOT/scripts/orca-signal" "$LOCAL_BIN/orca-signal"
echo "🔗 Linked orca-signal → $LOCAL_BIN/orca-signal"
case ":$PATH:" in
  *":$LOCAL_BIN:"*) : ;;
  *) echo "   ⚠  $LOCAL_BIN is not on your PATH — add it, or orca will reference the script absolutely." ;;
esac
echo
echo "Next steps:"
echo "  1. Restart Claude Code so the skill registry picks up the change."
echo "  2. Invoke with /orca."
echo "  3. (Optional) Copy bundled playbooks into ~/.orca/playbooks/ to customize them globally."
echo
if [[ -d "$BACKUP_DIR" ]]; then
  echo "📦 Previous installs (if any) are in $BACKUP_DIR — safe to delete once you're confident the new install works."
fi
