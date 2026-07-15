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

# Iterate workers. Fields separated by US (0x1f), a non-whitespace char, so an
# empty window (window:null, the same-window split case) is NOT collapsed by
# read the way a tab would be.
jq -r '.workers[] | "\(.id)\u001f\(.pane.ref)\u001f\(.pane.window // "")\u001f\(.last_signal // "unknown")"' "$STATE" |
while IFS=$'\x1f' read -r id ref window last_signal; do
  sigfile=".orca/signals/${id}.jsonl"
  if [[ -f "$sigfile" ]]; then
    # Signal channel present — read structured events, no screen-scrape.
    summary=$("$SCRIPT_DIR/read-signal.sh" "$id" 2>/dev/null || true)
    signal=$(printf '%s\n' "$summary" | sed -n 's/^last_event=//p')
    [[ -z "$signal" || "$signal" == "-" ]] && signal="$last_signal"
    echo "=== $id ($ref) $signal [signal-channel] ==="
    printf '%s\n' "$summary"
    echo
  else
    # Fallback: capture the pane and classify heuristically.
    pane_output=$(capture "$BACKEND" "$ref" "$window")
    signal=$(echo "$pane_output" | "$SCRIPT_DIR/detect-state.sh" --stdin 2>/dev/null || echo "$last_signal")
    echo "=== $id ($ref) $signal [screen-scrape] ==="
    echo "$pane_output"
    echo
  fi
done
