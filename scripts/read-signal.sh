#!/usr/bin/env bash
# 🐋 orca/read-signal.sh — read a worker's signal channel (orchestrator side).
#
# The orchestrator half of orca's signal channel. Replaces screen-scraping:
# instead of capturing the worker's TUI and regex-matching it, read the
# structured events the worker emitted via `orca-signal` (+ automatic
# heartbeats from the omp worker-signal hook).
#
# Usage:
#   read-signal.sh <worker_id>            # reads .orca/signals/<worker_id>.jsonl
#   read-signal.sh --file <path>          # explicit file
#
# Prints key=value lines (easy to eval / grep):
#   last_event=<name>                     # most recent SEMANTIC event (non-heartbeat)
#   last_event_at=<iso8601|->
#   last_event_json=<compact json|->      # full fields of that event (for {event.*} substitution)
#   last_heartbeat_at=<iso8601|->         # most recent event of ANY kind (incl heartbeat)
#   heartbeat_age_s=<int|->               # seconds since last_heartbeat_at (liveness)
#   event_count=<int>
#
# Exit codes:
#   0  signal file read
#   3  no signal file yet (caller should fall back to screen-scrape / poll.sh)
#   2  usage error

set -euo pipefail

file=""
case "${1:-}" in
  "") echo "usage: read-signal.sh <worker_id> | --file <path>" >&2; exit 2 ;;
  --file) file="${2:-}"; [ -z "$file" ] && { echo "read-signal.sh: --file needs a path" >&2; exit 2; } ;;
  *) file=".orca/signals/${1}.jsonl" ;;
esac

if [[ ! -f "$file" ]]; then
  echo "last_event=-"
  echo "no_signal_file=1"
  exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "read-signal.sh requires jq" >&2
  exit 1
fi

# Portable ISO8601-UTC ("...Z") -> epoch seconds. BSD (macOS) vs GNU date.
iso_to_epoch() {
  local ts="$1" e
  if e=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null); then
    echo "$e"
  elif e=$(date -u -d "$ts" +%s 2>/dev/null); then
    echo "$e"
  else
    echo ""
  fi
}

# Most recent line of ANY kind → heartbeat / liveness.
last_line=$(tail -1 "$file" 2>/dev/null || true)
last_hb_at=$(printf '%s' "$last_line" | jq -r '.ts // "-"' 2>/dev/null || echo "-")

# Most recent SEMANTIC event (skip heartbeats). jq reads jsonl line-by-line.
last_sem=$(jq -c 'select(.event != "heartbeat")' "$file" 2>/dev/null | tail -1 || true)
if [[ -n "$last_sem" ]]; then
  last_event=$(printf '%s' "$last_sem" | jq -r '.event // "-"')
  last_event_at=$(printf '%s' "$last_sem" | jq -r '.ts // "-"')
  last_event_json="$last_sem"
else
  last_event="-"; last_event_at="-"; last_event_json="-"
fi

event_count=$(grep -c '' "$file" 2>/dev/null || echo 0)

hb_age="-"
if [[ "$last_hb_at" != "-" ]]; then
  epoch=$(iso_to_epoch "$last_hb_at")
  if [[ -n "$epoch" ]]; then
    now=$(date -u +%s)
    hb_age=$(( now - epoch ))
  fi
fi

echo "last_event=$last_event"
echo "last_event_at=$last_event_at"
echo "last_event_json=$last_event_json"
echo "last_heartbeat_at=$last_hb_at"
echo "heartbeat_age_s=$hb_age"
echo "event_count=$event_count"
