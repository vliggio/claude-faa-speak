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

if [[ "$COMPRESSED" == *'<!-- faa -->'* ]]; then
  if [ "${FAA_SHOW_COMPRESSED:-0}" = "1" ]; then
    printf '%s\n\n' "$COMPRESSED"
  fi
  TEXT=${COMPRESSED//'<!-- faa -->'/}
  if ! faa_expand_text "$TEXT"; then
    # apfel unavailable mid-run — fall back to the compressed reply
    printf '%s' "$COMPRESSED"
  fi
  printf '\n'
else
  printf '%s\n' "$COMPRESSED"
fi
