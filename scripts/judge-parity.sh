#!/usr/bin/env bash
# judge-parity.sh — information-parity check between plain and faa-speak
# answers (adversarial review P1: token "savings" without content parity is
# just omission — an empty answer saves 100%).
#
# For each prompt: one plain call, one /faa-speak call, then a judge call
# that lists the plain answer's distinct technical points and counts how
# many survive in the compressed answer (any wording counts). Reports
# per-prompt coverage next to token savings — the savings number only means
# something where coverage holds.
#
# Requires a logged-in claude CLI; costs real tokens (~3 calls per prompt).
#
# Usage:
#   scripts/judge-parity.sh [prompts...]   # default: the 10 bench --ab prompts
#   OUT_DIR=/path scripts/judge-parity.sh  # keep raw responses (default: tmp)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# Which skill to grade: defaults to the shipped FAA dialect; override to test a
# variant (e.g. the v2 lean prototype):
#   VARIANT_ROOT="$PWD/bench/lean-plugin" VARIANT_SKILL=faa-speak-lean scripts/judge-parity.sh
CAND_ROOT="${VARIANT_ROOT:-$PLUGIN_ROOT}"
CAND_SKILL="${VARIANT_SKILL:-faa-speak}"
OUT_DIR="${OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/faa-parity.XXXXXX")}"
mkdir -p "$OUT_DIR"

command -v claude >/dev/null 2>&1 || { echo "Error: claude CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 1; }

PROMPTS=(
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
if [ $# -gt 0 ]; then PROMPTS=("$@"); fi

ask() { claude --print --output-format json "$@"; }

# Pull the first {...} JSON object out of a possibly chatty judge reply.
extract_json() {
  sed -n 's/.*\({"points_total".*}\).*/\1/p' | head -1
}

sum_total=0
sum_present=0
sum_plain=0
sum_faa=0
i=0
printf '%-52s %7s %7s %6s %10s\n' "prompt" "plain" "faa" "save%" "coverage"
for p in "${PROMPTS[@]}"; do
  i=$((i + 1))
  pj=$(ask "$p")
  fj=$(ask --plugin-dir "$CAND_ROOT" "/$CAND_SKILL $p")
  printf '%s' "$pj" > "$OUT_DIR/$i-plain.json"
  printf '%s' "$fj" > "$OUT_DIR/$i-faa.json"
  pa=$(printf '%s' "$pj" | jq -r '.result // ""')
  fa=$(printf '%s' "$fj" | jq -r '.result // ""')
  pt=$(printf '%s' "$pj" | jq -r '.usage.output_tokens // 0')
  ft=$(printf '%s' "$fj" | jq -r '.usage.output_tokens // 0')

  JUDGE="You are grading information parity between two answers to the same question.

QUESTION: $p

ANSWER A (reference):
$pa

ANSWER B (candidate — may be terse prose, a telegraphic abbreviated dialect, or compact PREFIX: field | field | field lines; decode/expand it before judging):
$fa

List the distinct technical points ANSWER A makes, then decide for each whether its substance is present in ANSWER B in any wording. Reply with ONLY a compact single-line JSON object, no code fences, shaped exactly like:
{\"points_total\": N, \"points_present\": M, \"missing\": [\"short description of each missing point\"]}"

  verdict=""
  tries=0
  while [ "$tries" -lt 2 ] && [ -z "$verdict" ]; do
    vj=$(ask "$JUDGE") || vj=""
    verdict=$(printf '%s' "$vj" | jq -r '.result // ""' | tr '\n' ' ' | extract_json)
    if ! printf '%s' "$verdict" | jq -e '.points_total' >/dev/null 2>&1; then verdict=""; fi
    tries=$((tries + 1))
  done
  if [ -z "$verdict" ]; then
    printf '%-52.52s %7s %7s %6s %10s\n' "$p" "$pt" "$ft" "-" "judge-ERR"
    continue
  fi
  printf '%s' "$verdict" > "$OUT_DIR/$i-verdict.json"
  n_total=$(printf '%s' "$verdict" | jq -r '.points_total')
  n_present=$(printf '%s' "$verdict" | jq -r '.points_present')
  save="-"
  if [ "$pt" -gt 0 ] 2>/dev/null; then save=$(( (pt - ft) * 100 / pt )); fi
  cov="-"
  if [ "$n_total" -gt 0 ] 2>/dev/null; then cov="$((n_present * 100 / n_total))% ($n_present/$n_total)"; fi
  printf '%-52.52s %7s %7s %5s%% %10s\n' "$p" "$pt" "$ft" "$save" "$cov"
  missing=$(printf '%s' "$verdict" | jq -r '.missing[]? // empty' | head -4)
  if [ -n "$missing" ]; then
    printf '%s\n' "$missing" | sed 's/^/        missing: /'
  fi
  sum_total=$((sum_total + n_total))
  sum_present=$((sum_present + n_present))
  sum_plain=$((sum_plain + pt))
  sum_faa=$((sum_faa + ft))
done

echo
if [ "$sum_total" -gt 0 ]; then
  save=0
  if [ "$sum_plain" -gt 0 ]; then save=$(( (sum_plain - sum_faa) * 100 / sum_plain )); fi
  printf 'PARITY: %d of %d reference points survive compression (%d%%) · token savings %d%%\n' \
    "$sum_present" "$sum_total" "$((sum_present * 100 / sum_total))" "$save"
  echo "Read them together: savings bought by missing points is omission, not compression."
fi
printf 'raw responses: %s\n' "$OUT_DIR"
