#!/usr/bin/env bash
# lean-wrap: non-interactive driver for the v2 "lean" prototype
# (bench/lean-plugin). Unlike faa-wrap.sh — which runs the FAA dialect and
# re-expands prose through apfel — this exercises the output-token levers the
# 2026-07 measurement showed actually dominate the bill, and renders the
# optional structured-field format with a DETERMINISTIC, model-free template
# (faa_render_text). No apfel, no Apple Intelligence, works on any platform.
#
# Harness levers (what `claude --print` actually supports — verified):
#   LEAN_MODEL=haiku      route to a cheaper/terser model (--model). Terse tasks
#                         cost less per token AND draw shorter output by default.
#   LEAN_MAXWORDS=120     soft output cap: appends "answer in <=N words, most
#                         important first" to the system prompt. NOTE: a HARD
#                         max_tokens cap and native structured outputs /
#                         tool_choice are SDK-only — the --print CLI exposes
#                         neither, so this is a prompt-level cap, not an API one.
#
# Usage:
#   scripts/lean-wrap.sh "explain database connection pooling"
#   LEAN_MODEL=haiku LEAN_MAXWORDS=120 scripts/lean-wrap.sh "diagnose: 502 under load"
#
# Env:
#   FAA_SHOW_COMPRESSED=1   print the raw structured reply before the render
#   FAA_SHOW_SAVINGS=1      print a savings line (structured vs rendered) to stderr
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LEAN_ROOT="$PLUGIN_ROOT/bench/lean-plugin"
LEAN_SKILL="faa-speak-lean"
MARKER="<!-- faa2 -->"
# shellcheck source=../lib/expansion.sh
. "$PLUGIN_ROOT/lib/expansion.sh"

if ! command -v claude >/dev/null 2>&1; then
  printf 'Error: claude CLI not found in PATH.\n' >&2
  exit 1
fi
if [ $# -lt 1 ]; then
  printf 'Usage: lean-wrap.sh "your question"\n' >&2
  exit 1
fi

# Build the claude invocation. The lean skill does not auto-trigger in --print,
# so invoke it explicitly, same as faa-wrap.sh.
CLAUDE_ARGS=(--print --plugin-dir "$LEAN_ROOT")
if [ -n "${LEAN_MODEL:-}" ]; then
  CLAUDE_ARGS+=(--model "$LEAN_MODEL")
fi
if [ -n "${LEAN_MAXWORDS:-}" ]; then
  CLAUDE_ARGS+=(--append-system-prompt "Answer in at most ${LEAN_MAXWORDS} words, most important information first.")
fi

COMPRESSED=$(claude "${CLAUDE_ARGS[@]}" "/$LEAN_SKILL $*")

# Same end-of-text marker contract as the hook, but for the v2 marker. On a
# hit, TEXT holds the reply with the trailing marker stripped; render it
# deterministically. A reply that only quotes the marker mid-text is left as-is.
if faa_gate "$COMPRESSED" "$MARKER"; then
  if [ "${FAA_SHOW_COMPRESSED:-0}" = "1" ]; then
    printf '%s\n\n' "$COMPRESSED"
  fi
  RENDERED=$(FAA_STREAM=0 faa_render_text "$TEXT")
  printf '%s\n' "$RENDERED"
  if [ "${FAA_SHOW_SAVINGS:-0}" = "1" ]; then
    printf '%s\n' "$(faa_savings_line "$TEXT" "$RENDERED")" >&2
  fi
else
  printf '%s\n' "$COMPRESSED"
fi
