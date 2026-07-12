#!/usr/bin/env bash
# faa-speak Stop hook
# Expands the compressed assistant response via apfel and shows the result to
# the user as a systemMessage (stdout JSON, exit 0). Each expanded segment is
# also streamed to stderr so a timeout kill preserves partials.
#
# Message source: the hook input's `last_assistant_message` field. The
# transcript file is only a fallback for older Claude Code versions — it is
# written asynchronously and can lag the conversation (documented), so at
# Stop time it may not yet contain the current turn. A per-session dedupe
# state keeps the fallback from ever showing the same text twice.
#
# Contract: never blocks the stop. The EXIT trap forces exit 0 on every path
# (a Stop hook exiting 2 would block Claude from stopping; other nonzero exits
# surface stderr noise). Pipeline failures degrade to a silent no-op — set
# FAA_DEBUG=1 to see the reason on stderr — EXCEPT total apfel failure, which
# produces a visible warning with apfel's error instead of impersonating a
# working expansion. Set FAA_SHOW_SAVINGS=1 to append a compression-savings
# line to the systemMessage.
set -euo pipefail
# Never block the stop, and never litter: every exit path — including a
# TERM/INT from the hook timeout — removes this invocation's scratch files.
# (The dedupe STATE file intentionally survives: it must persist across
# stops within a session; stale ones are purged below.)
FALLBACK_FLAG=""
APFEL_ERR=""
DEADLINE_FLAG=""
# shellcheck disable=SC2329,SC2317  # invoked from the EXIT trap string below (older shellchecks flag the body as unreachable)
faa_scratch_cleanup() {
  if [ -n "$FALLBACK_FLAG" ]; then rm -f -- "$FALLBACK_FLAG" 2>/dev/null || true; fi
  if [ -n "$APFEL_ERR" ]; then rm -f -- "$APFEL_ERR" 2>/dev/null || true; fi
  if [ -n "$DEADLINE_FLAG" ]; then rm -f -- "$DEADLINE_FLAG" 2>/dev/null || true; fi
  return 0
}
trap 'faa_scratch_cleanup; exit 0' EXIT
trap 'exit 0' TERM INT HUP

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

# --- read hook input ---
HOOK_INPUT=$(cat)
if [ "$FAA_DEBUG" = "1" ]; then
  dbg "hook input keys: $(printf '%s' "$HOOK_INPUT" | jq -r 'keys | join(",")' 2>/dev/null || echo unparseable)"
fi
SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""

# Marker gate: faa_gate (lib/expansion.sh) — accepts only text that ENDS
# with the marker, strips it and surrounding whitespace into TEXT.

# Dedupe state: never expand the same text twice in one session (the
# transcript fallback can only see the PREVIOUS turn, so without this it
# would re-surface stale text on every stop).
STATE_DIR="${FAA_STATE_DIR:-${TMPDIR:-/tmp}}"
STATE="$STATE_DIR/faa-last-${SESSION_ID:-nosession}"
sig_of() { printf '%s' "$1" | cksum | tr -d ' \t'; }
# Opportunistic purge: dedupe state from dead sessions and scratch files
# orphaned by a SIGKILLed run (the EXIT trap can't fire on SIGKILL).
find "$STATE_DIR" -maxdepth 1 \( -name 'faa-last-*' -o -name 'faa-fellback-*' -o -name 'faa-apfel-err-*' \) -mtime +7 -delete 2>/dev/null || true

TEXT=""
# --- primary source: the response text delivered in the hook input ---
LAST_OUTPUT=$(printf '%s' "$HOOK_INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null) || LAST_OUTPUT=""
if [ -n "$LAST_OUTPUT" ]; then
  if ! faa_gate "$LAST_OUTPUT"; then
    dbg "last_assistant_message present but marker absent or not at end"
    exit 0
  fi
  dbg "using last_assistant_message from hook input"
else
  # --- fallback (older Claude Code): the transcript file, which is written
  # asynchronously and may still be missing the current turn at Stop time ---
  dbg "no last_assistant_message in hook input — falling back to transcript"
  TRANSCRIPT_PATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""
  if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    dbg "no transcript at '${TRANSCRIPT_PATH}'"
    exit 0
  fi
  # cheap no-op gate before any full-file parsing
  if ! tail -c 65536 -- "$TRANSCRIPT_PATH" 2>/dev/null | grep -qF '<!-- faa -->'; then
    dbg "no marker in transcript tail"
    exit 0
  fi
  set +e
  LAST_LINES=$(grep '"role":"assistant"' -- "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 100)
  REC=$(printf '%s\n' "$LAST_LINES" | jq -rs '
    map(select([.message.content[]? | select(.type == "text")] | length > 0))
    | last // empty
    | (.timestamp // "") + "\u001f"
      + ([.message.content[]? | select(.type == "text") | .text] | join(""))
  ' 2>/dev/null)
  set -e
  case "$REC" in
    *$'\x1f'*) TS=${REC%%$'\x1f'*}; RAW=${REC#*$'\x1f'} ;;
    *)         TS="";               RAW="$REC" ;;
  esac
  if [ -z "$RAW" ]; then
    dbg "no assistant text found in transcript"
    exit 0
  fi
  # Staleness guard: a resumed session's transcript starts full of PRIOR
  # conversation — never expand history. Anything older than ~2 minutes is
  # not the response that triggered this Stop. (Fixtures without timestamps
  # are exempt; real transcripts always carry one.)
  if [ -n "$TS" ]; then
    CUTOFF=$(date -u -v-120S +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '-120 seconds' +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")
    if [ -n "$CUTOFF" ] && [[ "${TS%%.*}" < "$CUTOFF" ]]; then
      dbg "newest transcript text is stale (${TS}) — resumed session? skipping"
      exit 0
    fi
  fi
  if ! faa_gate "$RAW"; then
    dbg "marker absent or not at end of newest transcript text"
    exit 0
  fi
  if [ "$(sig_of "$TEXT")" = "$(cat "$STATE" 2>/dev/null || true)" ]; then
    dbg "newest transcript text already expanded (transcript lags Stop) — skipping"
    exit 0
  fi
fi

# --- expand (streams segments to stderr; accumulates for systemMessage) ---
# FAA_DEADLINE: internal budget in seconds (since hook start) after which
# remaining chunks pass through compressed — always less than hooks.json's
# 30s timeout, so a slow expansion delivers a partial result instead of
# being killed with nothing visible.
FAA_DEADLINE="${FAA_DEADLINE:-22}"
FALLBACK_FLAG="$STATE_DIR/faa-fellback-$$"
APFEL_ERR="$STATE_DIR/faa-apfel-err-$$"
DEADLINE_FLAG="$STATE_DIR/faa-deadline-$$"
rm -f -- "$FALLBACK_FLAG" "$APFEL_ERR" "$DEADLINE_FLAG" 2>/dev/null || true
printf '━━━ faa-speak expansion (apfel paraphrase) ━━━\n' >&2
EXPANDED=$(FAA_STREAM=1 FAA_DEADLINE="$FAA_DEADLINE" FAA_DEADLINE_FLAG="$DEADLINE_FLAG" FAA_FALLBACK_FLAG="$FALLBACK_FLAG" FAA_APFEL_ERR="$APFEL_ERR" faa_expand_text "$TEXT") || EXPANDED=""
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' >&2

if [ -z "$EXPANDED" ]; then
  dbg "expansion produced no output"
  exit 0
fi
sig_of "$TEXT" > "$STATE" 2>/dev/null || true

# --- deliver visibly: systemMessage on stdout (exit 0) ---
if [ -s "$FALLBACK_FLAG" ] && [ "$(sig_of "$EXPANDED")" = "$(sig_of "$TEXT")" ]; then
  # Every chunk failed and the "expansion" is just the original text: say so
  # instead of impersonating a working expansion with a 0% savings line.
  APFEL_REASON=$(head -1 -- "$APFEL_ERR" 2>/dev/null || true)
  jq -n --arg msg "⚠ faa-speak: apfel could not expand this response${APFEL_REASON:+ — ${APFEL_REASON}}
Compressed text shown as-is. Diagnose with: apfel --model-info" '{systemMessage: $msg}'
  exit 0
fi
MSG="━━━ faa-speak expansion (apfel paraphrase — the compressed original above is authoritative) ━━━
$EXPANDED"
if [ -s "$FALLBACK_FLAG" ]; then
  MSG="$MSG

⚠ some segments could not be expanded (apfel error) — shown compressed"
fi
if [ -s "$DEADLINE_FLAG" ]; then
  MSG="$MSG

⚠ expansion time budget (~${FAA_DEADLINE}s) reached — remaining segments shown compressed"
fi
if [ "${FAA_SHOW_SAVINGS:-0}" = "1" ]; then
  MSG="$MSG

$(faa_savings_line "$TEXT" "$EXPANDED")"
fi
# systemMessage is capped at 10k chars; the full expansion always went to
# stderr — but stderr reaches the debug log only under `claude --debug`, so
# the notice must not promise a log that usually doesn't exist.
if [ ${#MSG} -gt 9500 ]; then
  MSG="${MSG:0:9500}
… [truncated at ~9.5k chars — the compressed response above is complete; the full expansion is logged only when running \`claude --debug\`]"
fi
jq -n --arg msg "$MSG" '{systemMessage: $msg}'
exit 0
