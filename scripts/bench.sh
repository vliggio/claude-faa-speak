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
#   scripts/bench.sh --concise [...]     adds a "be concise" arm: the plain
#                                        prompt behind a one-line terseness
#                                        instruction, no plugin — the readable
#                                        baseline any dialect must beat
#   scripts/bench.sh --runs N [...]      repeat the whole set N times and
#                                        report mean and min-max per arm
#                                        (single runs move several points)
#
# The --ab arm is overridable — to A/B a candidate dictionary extension
# (see docs/custom-dictionary.md):
#   VARIANT_ROOT="$PWD/bench/extdict-plugin" VARIANT_SKILL=faa-speak-extdict \
#     scripts/bench.sh --ab
# To isolate the abbreviation TABLE's contribution use the controlled arm
# (identical to the shipped skill except the table itself is removed):
#   VARIANT_ROOT="$PWD/bench/tableless-plugin" VARIANT_SKILL=faa-speak-tableless \
#     scripts/bench.sh --ab --runs 5
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_ROOT="${VARIANT_ROOT:-$PLUGIN_ROOT/bench/nodict-plugin}"
VARIANT_SKILL="${VARIANT_SKILL:-faa-speak-nodict}"
CONCISE_PREFIX="Answer concisely: no pleasantries, no hedging, no filler."

command -v claude >/dev/null 2>&1 || { echo "Error: claude CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 1; }

AB=0
CONCISE=0
RUNS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --ab) AB=1; shift ;;
    --concise) CONCISE=1; shift ;;
    --runs) RUNS="${2:?--runs needs a count}"; shift 2 ;;
    --runs=*) RUNS="${1#--runs=}"; shift ;;
    *) break ;;
  esac
done
case "$RUNS" in (*[!0-9]*|'') echo "Error: --runs needs a positive integer" >&2; exit 1 ;; esac
[ "$RUNS" -ge 1 ] || { echo "Error: --runs needs a positive integer" >&2; exit 1; }

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
stats() { # "p1 p2 ..." -> "mean=M min=A max=B"
  printf '%s\n' "$1" | awk '{
    n = 0
    for (i = 1; i <= NF; i++) { s += $i; if (!n || $i < min) min = $i; if (!n || $i > max) max = $i; n++ }
    if (n) printf "mean=%d%% min=%d%% max=%d%%", s / n, min, max
  }'
}

header() {
  printf '%-52s %8s %8s' "prompt" "plain" "faa"
  if [ "$AB" = 1 ]; then printf ' %8s' "variant"; fi
  if [ "$CONCISE" = 1 ]; then printf ' %8s' "concise"; fi
  printf ' %6s' "faa%"
  if [ "$AB" = 1 ]; then printf ' %6s' "var%"; fi
  if [ "$CONCISE" = 1 ]; then printf ' %6s' "con%"; fi
  printf '\n'
}

FAA_PCTS=""
VAR_PCTS=""
CON_PCTS=""

run=1
while [ "$run" -le "$RUNS" ]; do
  if [ "$RUNS" -gt 1 ]; then printf '— run %d/%d —\n' "$run" "$RUNS"; fi
  header
  total_plain=0
  total_faa=0
  total_variant=0
  total_concise=0
  for p in "${PROMPTS[@]}"; do
    plain=$(tokens "$p")
    faa=$(tokens --plugin-dir "$PLUGIN_ROOT" "/faa-speak $p")
    total_plain=$((total_plain + plain))
    total_faa=$((total_faa + faa))
    printf '%-52.52s %8s %8s' "$p" "$plain" "$faa"
    if [ "$AB" = 1 ]; then
      variant=$(tokens --plugin-dir "$VARIANT_ROOT" "/$VARIANT_SKILL $p")
      total_variant=$((total_variant + variant))
      printf ' %8s' "$variant"
    fi
    if [ "$CONCISE" = 1 ]; then
      concise=$(tokens "$CONCISE_PREFIX $p")
      total_concise=$((total_concise + concise))
      printf ' %8s' "$concise"
    fi
    printf ' %5s%%' "$(pct_saved "$faa" "$plain")"
    if [ "$AB" = 1 ]; then printf ' %5s%%' "$(pct_saved "$variant" "$plain")"; fi
    if [ "$CONCISE" = 1 ]; then printf ' %5s%%' "$(pct_saved "$concise" "$plain")"; fi
    printf '\n'
  done

  echo
  printf 'TOTAL: plain=%d faa=%d (%d%%)' "$total_plain" "$total_faa" "$(pct_saved "$total_faa" "$total_plain")"
  FAA_PCTS="$FAA_PCTS $(pct_saved "$total_faa" "$total_plain")"
  if [ "$AB" = 1 ]; then
    printf ' %s=%d (%d%%)' "$VARIANT_SKILL" "$total_variant" "$(pct_saved "$total_variant" "$total_plain")"
    VAR_PCTS="$VAR_PCTS $(pct_saved "$total_variant" "$total_plain")"
  fi
  if [ "$CONCISE" = 1 ]; then
    printf ' concise=%d (%d%%)' "$total_concise" "$(pct_saved "$total_concise" "$total_plain")"
    CON_PCTS="$CON_PCTS $(pct_saved "$total_concise" "$total_plain")"
  fi
  printf '\n'
  if [ "$AB" = 1 ] && [ "$VARIANT_SKILL" = "faa-speak-nodict" ]; then
    delta=$((total_variant - total_faa))
    printf 'dictionary contribution: %d tokens (%d%% of plain) beyond telegraphic style alone\n' \
      "$delta" "$(pct_saved "$total_faa" "$total_variant")"
  fi
  echo
  run=$((run + 1))
done

if [ "$RUNS" -gt 1 ]; then
  printf 'SUMMARY over %d runs (savings vs plain):\n' "$RUNS"
  printf '  faa:     %s\n' "$(stats "$FAA_PCTS")"
  if [ "$AB" = 1 ]; then printf '  %s: %s\n' "$VARIANT_SKILL" "$(stats "$VAR_PCTS")"; fi
  if [ "$CONCISE" = 1 ]; then printf '  concise: %s\n' "$(stats "$CON_PCTS")"; fi
  echo "If arms overlap within min-max spread, the difference is inside run-to-run noise."
else
  echo "Note: single runs are noisy — use --runs 5 (and your own prompts) before updating any README claim."
fi
