#!/usr/bin/env bash
# bench.sh — measure faa-speak's actual output-token savings.
# Runs each benchmark prompt via `claude --print --output-format json` and
# compares usage.output_tokens. Requires a logged-in claude CLI; costs real
# tokens.
#
# Usage:
#   scripts/bench.sh [prompts...]        plain vs /faa-speak
#   scripts/bench.sh --ab [prompts...]   adds a variant arm; by default the
#                                        no-dictionary variant (issue #10) to
#                                        isolate the dictionary's contribution
#
# The --ab arm is overridable — to A/B a candidate dictionary extension
# (see docs/custom-dictionary.md):
#   VARIANT_ROOT="$PWD/bench/extdict-plugin" VARIANT_SKILL=faa-speak-extdict \
#     scripts/bench.sh --ab
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_ROOT="${VARIANT_ROOT:-$PLUGIN_ROOT/bench/nodict-plugin}"
VARIANT_SKILL="${VARIANT_SKILL:-faa-speak-nodict}"

command -v claude >/dev/null 2>&1 || { echo "Error: claude CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 1; }

AB=0
if [ "${1:-}" = "--ab" ]; then
  AB=1
  shift
fi

DEFAULT_PROMPTS=(
  "explain database connection pooling"
  "diagnose: my auth middleware rejects tokens that should still be valid"
  "compare REST and GraphQL for a mobile app backend"
)
AB_PROMPTS=(
  "explain database connection pooling"
  "diagnose: my auth middleware rejects tokens that should still be valid"
  "compare REST and GraphQL for a mobile app backend"
  "explain how a bloom filter works and when to use one"
  "diagnose: nginx returns 502 only under load, upstream looks healthy"
  "what are the tradeoffs of monorepo vs polyrepo for a 10-person team"
  "explain optimistic vs pessimistic locking in SQL databases"
  "diagnose: kubernetes pod stuck in CrashLoopBackOff after a config change"
  "how should I structure retries with exponential backoff for a flaky API"
  "explain the difference between processes and threads for a junior developer"
)

if [ $# -gt 0 ]; then
  PROMPTS=("$@")
elif [ "$AB" = 1 ]; then
  PROMPTS=("${AB_PROMPTS[@]}")
else
  PROMPTS=("${DEFAULT_PROMPTS[@]}")
fi

tokens() { # claude args... -> output token count
  claude --print --output-format json "$@" | jq -r '.usage.output_tokens // 0'
}
pct_saved() { # new base -> integer percent saved vs base
  if [ "$2" -gt 0 ]; then
    printf '%d' $(( ($2 - $1) * 100 / $2 ))
  else
    printf '0'
  fi
}

total_plain=0
total_faa=0
total_variant=0

if [ "$AB" = 1 ]; then
  printf '%-52s %8s %8s %8s %7s %7s\n' "prompt" "plain" "faa" "variant" "faa%" "var%"
else
  printf '%-52s %10s %8s %8s\n' "prompt" "plain" "faa" "delta"
fi

for p in "${PROMPTS[@]}"; do
  plain=$(tokens "$p")
  faa=$(tokens --plugin-dir "$PLUGIN_ROOT" "/faa-speak $p")
  total_plain=$((total_plain + plain))
  total_faa=$((total_faa + faa))
  if [ "$AB" = 1 ]; then
    variant=$(tokens --plugin-dir "$VARIANT_ROOT" "/$VARIANT_SKILL $p")
    total_variant=$((total_variant + variant))
    printf '%-52.52s %8s %8s %8s %6s%% %6s%%\n' "$p" "$plain" "$faa" "$variant" \
      "$(pct_saved "$faa" "$plain")" "$(pct_saved "$variant" "$plain")"
  else
    printf '%-52.52s %10s %8s %7s%%\n' "$p" "$plain" "$faa" "$(pct_saved "$faa" "$plain")"
  fi
done

echo
if [ "$AB" = 1 ]; then
  printf 'TOTAL: plain=%d faa=%d (%d%%) %s=%d (%d%%)\n' \
    "$total_plain" "$total_faa" "$(pct_saved "$total_faa" "$total_plain")" \
    "$VARIANT_SKILL" "$total_variant" "$(pct_saved "$total_variant" "$total_plain")"
  delta=$((total_variant - total_faa))
  if [ "$VARIANT_SKILL" = "faa-speak-nodict" ]; then
    printf 'dictionary contribution: %d tokens (%d%% of plain) beyond telegraphic style alone\n' \
      "$delta" "$(pct_saved "$total_faa" "$total_variant")"
    echo "If that contribution is within run-to-run noise (rerun a few times), the"
    echo "abbreviation table and its sync machinery are not earning their keep (#10)."
  else
    printf 'faa minus %s: %d tokens (positive = current dictionary wins, negative = variant wins)\n' \
      "$VARIANT_SKILL" "$delta"
    echo "Repeat the run a few times — ship the variant only if it wins beyond noise."
  fi
else
  printf 'TOTAL: plain=%d faa=%d savings=%d%%\n' "$total_plain" "$total_faa" \
    "$(pct_saved "$total_faa" "$total_plain")"
fi
echo "Note: single runs are noisy — repeat and use your own prompts before updating any README claim."
