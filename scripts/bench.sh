#!/usr/bin/env bash
# bench.sh — measure faa-speak's actual output-token savings.
# Runs each benchmark prompt twice via `claude --print --output-format json`
# (once plain, once with the plugin + /faa-speak trigger) and compares
# usage.output_tokens. Requires a logged-in claude CLI; costs real tokens.
#
# Usage: scripts/bench.sh [extra prompts...]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

command -v claude >/dev/null 2>&1 || { echo "Error: claude CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 1; }

PROMPTS=(
  "explain database connection pooling"
  "diagnose: my auth middleware rejects tokens that should still be valid"
  "compare REST and GraphQL for a mobile app backend"
)
if [ $# -gt 0 ]; then PROMPTS=("$@"); fi

total_plain=0
total_faa=0
printf '%-52s %10s %8s %8s\n' "prompt" "plain" "faa" "delta"
for p in "${PROMPTS[@]}"; do
  plain=$(claude --print --output-format json "$p" | jq -r '.usage.output_tokens // 0')
  faa=$(claude --print --output-format json --plugin-dir "$PLUGIN_ROOT" "/faa-speak $p" | jq -r '.usage.output_tokens // 0')
  total_plain=$((total_plain + plain))
  total_faa=$((total_faa + faa))
  printf '%-52.52s %10s %8s %7s%%\n' "$p" "$plain" "$faa" \
    "$(( plain > 0 ? (plain - faa) * 100 / plain : 0 ))"
done
echo
printf 'TOTAL: plain=%d faa=%d savings=%d%%\n' "$total_plain" "$total_faa" \
  "$(( total_plain > 0 ? (total_plain - total_faa) * 100 / total_plain : 0 ))"
echo "Note: run several times and with your own prompts before updating any README claim."
