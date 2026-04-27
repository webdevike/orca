#!/usr/bin/env bash
# 🐋 orca/poll.sh — capture each tracked worker pane, classify signal.
#
# Reads .orca/state.json, dispatches to backend (cmux or tmux), prints one
# block per worker:
#
#   === <worker_id> (<pane_ref>) <signal> ===
#   <last 30 lines of pane output>
#
# Does NOT update state.json. The orchestrator does that after parsing.
#
# Usage: poll.sh [--lines N]
#   --lines N   Override default capture depth (30).

set -euo pipefail

LINES=30
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lines) LINES="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

STATE=".orca/state.json"
if [[ ! -f $STATE ]]; then
  echo "no .orca/state.json in $(pwd)" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "poll.sh requires jq" >&2
  exit 1
fi

BACKEND=$(jq -r '.backend' "$STATE")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

capture() {
  # Args: backend, pane_ref, [window_ref or empty]
  local backend="$1"
  local ref="$2"
  local window="${3:-}"
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
    *)
      echo "(unknown backend: $backend)"
      ;;
  esac
}

# Iterate workers. Each line: id\tref\twindow\tlast_signal
jq -r '.workers[] | "\(.id)\t\(.pane.ref)\t\(.pane.window // "")\t\(.last_signal // "unknown")"' "$STATE" |
while IFS=$'\t' read -r id ref window last_signal; do
  pane_output=$(capture "$BACKEND" "$ref" "$window")
  signal=$(echo "$pane_output" | "$SCRIPT_DIR/detect-state.sh" --stdin 2>/dev/null || echo "$last_signal")
  echo "=== $id ($ref) $signal ==="
  echo "$pane_output"
  echo
done
