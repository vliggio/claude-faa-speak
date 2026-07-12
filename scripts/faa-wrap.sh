#!/usr/bin/env bash
# faa-wrap: non-interactive faa-speak — runs `claude --print` with the plugin
# loaded and the /faa-speak skill invoked, then expands the compressed reply
# via apfel (code blocks pass through the shared splitter untouched).
#
# Usage:
#   faa-wrap.sh "explain database connection pooling"
#   echo "context" | faa-wrap.sh "summarize this"
#
# Env:
#   APFEL=/path/to/apfel      override apfel discovery
#   FAA_SHOW_COMPRESSED=1     print the raw compressed reply before the expansion
#   FAA_SHOW_SAVINGS=1        print a compression-savings line (to stderr) after expansion
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../lib/expansion.sh
. "$PLUGIN_ROOT/lib/expansion.sh"

if ! command -v claude >/dev/null 2>&1; then
  printf 'Error: claude CLI not found in PATH.\n' >&2
  exit 1
fi
if ! faa_locate_apfel >/dev/null; then
  printf 'Error: apfel not found. Build it:\n' >&2
  printf '  git clone https://github.com/Arthur-Ficial/apfel ~/git/apfel && cd ~/git/apfel && swift build -c release\n' >&2
  exit 1
fi
if [ $# -lt 1 ]; then
  printf 'Usage: faa-wrap.sh "your question"\n' >&2
  exit 1
fi

# Load the plugin for this run and invoke the skill explicitly — skills do not
# auto-trigger in --print mode.
COMPRESSED=$(claude --print --plugin-dir "$PLUGIN_ROOT" "/faa-speak $*")

# Same contract as the Stop hook (shared faa_gate): only a marker at the END
# of the reply triggers expansion — a reply that merely quotes the marker
# mid-text passes through verbatim, marker intact. On success TEXT holds the
# reply with the trailing marker stripped.
if faa_gate "$COMPRESSED"; then
  # Same failure honesty as the hook: per-chunk apfel failures fall back to
  # the compressed text AND are announced on stderr, never silently mixed in.
  FALLBACK_FLAG=$(mktemp "${TMPDIR:-/tmp}/faa-wrap-fellback.XXXXXX")
  APFEL_ERR=$(mktemp "${TMPDIR:-/tmp}/faa-wrap-apfel-err.XXXXXX")
  trap 'rm -f -- "$FALLBACK_FLAG" "$APFEL_ERR"' EXIT
  if [ "${FAA_SHOW_COMPRESSED:-0}" = "1" ]; then
    printf '%s\n\n' "$COMPRESSED"
  fi
  if [ "${FAA_SHOW_SAVINGS:-0}" = "1" ]; then
    # capture (rather than stream) so the full expansion is available for the
    # savings comparison; FAA_STREAM still gives progressive output on stderr
    if EXPANDED=$(FAA_STREAM=1 FAA_FALLBACK_FLAG="$FALLBACK_FLAG" FAA_APFEL_ERR="$APFEL_ERR" faa_expand_text "$TEXT"); then
      printf '%s' "$EXPANDED"
    else
      EXPANDED="$COMPRESSED"
      printf '%s' "$COMPRESSED"
    fi
    printf '\n'
    printf '%s\n' "$(faa_savings_line "$TEXT" "$EXPANDED")" >&2
  else
    if ! FAA_FALLBACK_FLAG="$FALLBACK_FLAG" FAA_APFEL_ERR="$APFEL_ERR" faa_expand_text "$TEXT"; then
      # apfel unavailable mid-run — fall back to the compressed reply
      printf '%s' "$COMPRESSED"
    fi
    printf '\n'
  fi
  if [ -s "$FALLBACK_FLAG" ]; then
    APFEL_REASON=$(head -1 -- "$APFEL_ERR" 2>/dev/null || true)
    printf '⚠ faa-speak: some segments could not be expanded (apfel error%s) — shown compressed\n' "${APFEL_REASON:+: ${APFEL_REASON}}" >&2
  fi
else
  printf '%s\n' "$COMPRESSED"
fi
