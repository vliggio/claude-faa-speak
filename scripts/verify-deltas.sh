#!/usr/bin/env bash
# verify-deltas.sh — measure the REAL token delta of every dictionary entry
# and candidate, using the logged-in claude CLI (no API key needed).
#
# Method: two `claude --print` calls per pair with identical scaffolding —
# "use <full form> here" vs "use <abbreviation> here" — and diff the input
# token counts; the constant prompt overhead cancels, leaving
# tokens(full) − tokens(abbrev). An entry earns a dictionary slot only if
# that delta is >= 1 (see docs/custom-dictionary.md).
#
# Usage:
#   scripts/verify-deltas.sh                 # current FAA_DICT + built-in
#                                            #   devops candidate set
#   scripts/verify-deltas.sh my-pairs.txt    # custom list, lines of:
#                                            #   abbreviation|full form
#
# Cost: ~2 haiku calls per pair (uses --bare; cheap, but real API usage).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../lib/expansion.sh
. "$ROOT/lib/expansion.sh"

command -v claude >/dev/null 2>&1 || { printf 'Error: claude CLI not found\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'Error: jq not found\n' >&2; exit 1; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/faa-deltas.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
PAIRS="$TMPD/pairs"
RESULTS="$TMPD/results"
: > "$RESULTS"

if [ $# -ge 1 ]; then
  awk -F'|' '/^[^#]/ && NF >= 2 { print $1 "|" $2 "|custom" }' "$1" > "$PAIRS"
else
  # current dictionary entries
  # shellcheck disable=SC2086  # word-splitting FAA_DICT is the format
  for e in $FAA_DICT; do
    printf '%s|%s|current\n' "${e%%=*}" "${e#*=}"
  done > "$PAIRS"
  # devops candidate set (standard, widely-understood short forms only)
  cat >> "$PAIRS" <<'EOF'
k8s|kubernetes|candidate
PR|pull request|candidate
env var|environment variable|candidate
LB|load balancer|candidate
IaC|infrastructure as code|candidate
HA|high availability|candidate
DR|disaster recovery|candidate
SSO|single sign-on|candidate
MFA|multi-factor authentication|candidate
SLO|service level objective|candidate
SLA|service level agreement|candidate
RCA|root cause analysis|candidate
MTTR|mean time to recovery|candidate
HPA|horizontal pod autoscaler|candidate
PVC|persistent volume claim|candidate
CRD|custom resource definition|candidate
CI/CD|continuous integration and delivery|candidate
conn pool|connection pool|candidate
repo|repository|candidate
vuln|vulnerability|candidate
config|configuration|candidate
infra|infrastructure|candidate
perf|performance|candidate
regex|regular expression|candidate
o11y|observability|candidate
authz|authorization|candidate
EOF
fi

# Invocation mirrors scripts/bench.sh (known-good): no cwd change, no --bare.
# haiku keeps the run cheap; if the alias is rejected, fall back to the
# session default model (token counts are what we measure, not quality).
USE_HAIKU=1

call_claude() { # term -> raw result JSON on stdout, stderr to $TMPD/last.err
  local term="$1"
  if [ "$USE_HAIKU" = 1 ]; then
    claude --print --output-format json --model haiku \
      "Reply with only the word ok. Vocabulary sample: use $term here." 2>"$TMPD/last.err"
  else
    claude --print --output-format json \
      "Reply with only the word ok. Vocabulary sample: use $term here." 2>"$TMPD/last.err"
  fi
}

extract_tokens() { # result-json -> token count or empty
  jq -r '
    if .is_error == true then empty
    else ((.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0))
    end' 2>/dev/null
}

count() { # term -> total input tokens, or -1 on failure (3 tries)
  local term="$1" out n tries=0
  while [ "$tries" -lt 3 ]; do
    out=$(call_claude "$term") || out=""
    n=$(printf '%s' "$out" | extract_tokens) || n=""
    if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
      printf '%s' "$n"
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  printf '%s' "-1"
}

# --- preflight: verify one call works, surfacing the REAL error if not ---
probe_out=$(call_claude "probe") || probe_out=""
probe_n=$(printf '%s' "$probe_out" | extract_tokens) || probe_n=""
if [ -z "$probe_n" ] || ! [ "$probe_n" -gt 0 ] 2>/dev/null; then
  printf 'haiku-model probe failed; retrying with the default model...\n' >&2
  USE_HAIKU=0
  probe_out=$(call_claude "probe") || probe_out=""
  probe_n=$(printf '%s' "$probe_out" | extract_tokens) || probe_n=""
fi
if [ -z "$probe_n" ] || ! [ "$probe_n" -gt 0 ] 2>/dev/null; then
  printf 'Error: claude --print probe failed. Diagnostics:\n' >&2
  printf '  result: %s\n' "$(printf '%s' "$probe_out" | jq -r '.result // "no result field"' 2>/dev/null || printf '%.200s' "$probe_out")" >&2
  printf '  stderr: %s\n' "$(head -c 400 "$TMPD/last.err" 2>/dev/null || echo none)" >&2
  exit 1
fi
[ "$USE_HAIKU" = 1 ] || printf 'note: using the default session model (haiku alias rejected)\n' >&2

total=$(grep -c . "$PAIRS")
printf 'Measuring %s pairs (~%s haiku calls); dots are pairs completing...\n' "$total" "$((total * 2))" >&2

while IFS='|' read -r abbr full class; do
  [ -n "$abbr" ] || continue
  (
    cf=$(count "$full")
    ca=$(count "$abbr")
    if [ "$cf" -lt 0 ] || [ "$ca" -lt 0 ]; then
      printf 'ERR|%s|%s|%s|-|-\n' "$abbr" "$full" "$class" >> "$RESULTS"
    else
      printf '%s|%s|%s|%s|%s|%s\n' "$((cf - ca))" "$abbr" "$full" "$class" "$cf" "$ca" >> "$RESULTS"
    fi
    printf '.' >&2
  ) &
  while [ "$(jobs -r | grep -c .)" -ge 5 ]; do sleep 0.3; done
done < "$PAIRS"
wait
printf '\n\n' >&2

printf '%-7s %-9s %-14s %-38s %s\n' "delta" "verdict" "abbrev" "full form" "class"
sort -t'|' -k1,1nr "$RESULTS" | while IFS='|' read -r d abbr full class _cf _ca; do
  v="?"
  if [ "$d" = "ERR" ]; then v="ERR"
  elif [ "$class" = "current" ]; then
    if [ "$d" -ge 1 ]; then v="KEEP"; else v="CUT"; fi
  else
    if [ "$d" -ge 1 ]; then v="ADD"; else v="SKIP"; fi
  fi
  printf '%-7s %-9s %-14s %-38s %s\n' "$d" "$v" "$abbr" "$full" "$class"
done

cat >&2 <<'EOF'

Reading the results:
  KEEP/ADD (delta >= 1)  — earns a dictionary slot
  CUT      (current, <=0) — dead weight: same or worse token cost, plus
                            expansion-prompt bloat and ambiguity for free
  SKIP     (candidate,<=0) — do not add
Next: put KEEP+ADD entries in a bench variant and A/B before shipping
(docs/custom-dictionary.md steps 4-5). Deltas are per-occurrence; weight by
how often your responses actually use each term (scripts/mine-dict.sh).
EOF
