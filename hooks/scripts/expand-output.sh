#!/usr/bin/env bash
# faa-speak Stop hook
# Extracts compressed assistant output, expands via apfel, and shows the
# result to the user as a systemMessage (stdout JSON, exit 0). Each expanded
# segment is also streamed to stderr so a timeout kill preserves partials.
#
# Contract: never blocks the stop. The EXIT trap forces exit 0 on every path
# (a Stop hook exiting 2 would block Claude from stopping; other nonzero exits
# surface stderr noise). All failures degrade to a silent no-op — set
# FAA_DEBUG=1 to see the reason for any no-op on stderr.
set -euo pipefail
trap 'exit 0' EXIT

# GNU tools in the C locale can abort on UTF-8 bytes; pin a UTF-8 locale.
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

FAA_DEBUG="${FAA_DEBUG:-0}"
dbg() {
  if [ "$FAA_DEBUG" = "1" ]; then printf 'faa-speak: %s\n' "$*" >&2; fi
}

# --- preflight ---
if ! command -v jq >/dev/null 2>&1; then
  dbg "jq not found — skipping"
  exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/expansion.sh
. "$SCRIPT_DIR/../../lib/expansion.sh"

if ! faa_locate_apfel >/dev/null; then
  dbg "apfel not found — skipping"
  exit 0
fi

# --- read hook input, locate transcript ---
HOOK_INPUT=$(cat)
TRANSCRIPT_PATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  dbg "no transcript at '${TRANSCRIPT_PATH}'"
  exit 0
fi

# Cheap no-op gate: if the marker isn't near the end of the transcript, skip
# before any full-file parsing.
if ! tail -c 65536 -- "$TRANSCRIPT_PATH" 2>/dev/null | grep -qF '<!-- faa -->'; then
  dbg "no marker in transcript tail"
  exit 0
fi

# --- extract the most recent assistant text ---
set +e
LAST_LINES=$(grep '"role":"assistant"' -- "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 100)
LAST_OUTPUT=$(printf '%s\n' "$LAST_LINES" | jq -rs '
  map(.message.content[]? | select(.type == "text") | .text) | last // ""
' 2>/dev/null)
set -e

if [ -z "$LAST_OUTPUT" ]; then
  dbg "no assistant text found"
  exit 0
fi

# --- marker gate: only expand when the marker terminates the response ---
TEXT="$LAST_OUTPUT"
while [ -n "$TEXT" ] && [[ "$TEXT" == *[$' \t\r\n'] ]]; do TEXT=${TEXT%?}; done
if [[ "$TEXT" != *'<!-- faa -->' ]]; then
  dbg "marker absent or not at end of response"
  exit 0
fi
TEXT=${TEXT%'<!-- faa -->'}
while [ -n "$TEXT" ] && [[ "$TEXT" == *[$' \t\r\n'] ]]; do TEXT=${TEXT%?}; done
if [ -z "$TEXT" ]; then
  dbg "nothing left after stripping marker"
  exit 0
fi

# --- expand (streams segments to stderr; accumulates for systemMessage) ---
printf '━━━ faa-speak expansion (via apfel) ━━━\n' >&2
EXPANDED=$(FAA_STREAM=1 faa_expand_text "$TEXT") || EXPANDED=""
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' >&2

if [ -z "$EXPANDED" ]; then
  dbg "expansion produced no output"
  exit 0
fi

# --- deliver visibly: systemMessage on stdout (exit 0) ---
MSG="━━━ faa-speak expansion (via apfel) ━━━
$EXPANDED"
# systemMessage is capped at 10k chars; the full expansion always went to stderr
if [ ${#MSG} -gt 9500 ]; then
  MSG="${MSG:0:9500}
… [truncated — full expansion in the debug log]"
fi
jq -n --arg msg "$MSG" '{systemMessage: $msg}'
exit 0
