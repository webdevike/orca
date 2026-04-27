#!/usr/bin/env bash
# 🐋 orca/detect-state.sh — classify a pane snapshot into a generic signal.
#
# This is a fallback classifier. The orchestrator should match against its
# active playbook's `watch` patterns first; this script handles "I have no
# matching pattern, what's the rough state?" cases.
#
# Usage:
#   detect-state.sh <pane_ref>             # capture via backend, classify
#   detect-state.sh --stdin                # classify text on stdin
#
# Prints one of:
#   spawning | executing | waiting_input | phase_complete | task_complete
#   | error | idle | dead

set -euo pipefail

STATE=".orca/state.json"
LINES=30

mode=""
ref=""
case "${1:-}" in
  --stdin) mode="stdin" ;;
  "") echo "usage: detect-state.sh <pane_ref> | --stdin" >&2; exit 2 ;;
  *) mode="capture"; ref="$1" ;;
esac

capture_text() {
  local backend
  if [[ -f $STATE ]] && command -v jq >/dev/null 2>&1; then
    backend=$(jq -r '.backend' "$STATE")
  else
    backend="${ORCA_BACKEND:-cmux}"
  fi

  local window=""
  if [[ -f $STATE ]] && command -v jq >/dev/null 2>&1; then
    window=$(jq -r --arg ref "$ref" '.workers[] | select(.pane.ref == $ref) | .pane.window // ""' "$STATE")
  fi

  case "$backend" in
    cmux)
      if [[ -n $window && $window != "null" ]]; then
        cmux --window "$window" read-screen --surface "$ref" --lines "$LINES" 2>&1 || echo "(unreachable)"
      else
        cmux read-screen --surface "$ref" --lines "$LINES" 2>&1 || echo "(unreachable)"
      fi
      ;;
    tmux)
      tmux capture-pane -t "$ref" -p -S "-${LINES}" 2>&1 || echo "(unreachable)"
      ;;
  esac
}

if [[ $mode == "stdin" ]]; then
  text=$(cat)
else
  text=$(capture_text)
fi

# Order matters — most specific first.
if echo "$text" | grep -qiE "unreachable|no such surface|can't find pane"; then
  echo "dead"
elif echo "$text" | grep -qE "MILESTONE COMPLETE|QUICK TASK COMPLETE"; then
  echo "task_complete"
elif echo "$text" | grep -qE "PHASE [0-9]+ COMPLETE ✓|PHASE [0-9]+ COMPLETE"; then
  echo "phase_complete"
elif echo "$text" | grep -qE "Do you want to make this edit\?|Continue without context"; then
  echo "waiting_input"
elif echo "$text" | grep -qiE "error|failed|exception|traceback"; then
  echo "error"
elif echo "$text" | grep -qE "Spawning|Running…|Slithering|Pondering|Nesting|Sautéed|Churned|Harmonizing|thinking"; then
  echo "executing"
elif echo "$text" | grep -qE "▐▛███▜▌|Claude Code v"; then
  echo "spawning"
else
  echo "idle"
fi
