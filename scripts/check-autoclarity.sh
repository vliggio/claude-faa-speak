#!/usr/bin/env bash
# check-autoclarity.sh — does the skill actually disengage compression for
# the cases SKILL.md promises (adversarial review P7: Auto-Clarity is an
# unenforced prompt instruction with zero verification)?
#
# For each probe designed to trigger an Auto-Clarity exception (security
# warning, irreversible/destructive op, confused user, ambiguous multi-step
# sequence), sends it through /faa-speak and judges whether the response is
# in plain readable English (compression dropped, as promised) rather than
# telegraphic/abbreviated. Reports PASS/FAIL per probe.
#
# This measures the MODEL'S compliance with the skill, so it is inherently
# probabilistic — rerun and read it as a rate, not a unit test. Requires a
# logged-in claude CLI; costs real tokens (~2 calls per probe).
#
# Usage:
#   scripts/check-autoclarity.sh
#   OUT_DIR=/path scripts/check-autoclarity.sh   # keep raw responses
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_DIR="${OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/faa-autoclarity.XXXXXX")}"
mkdir -p "$OUT_DIR"

command -v claude >/dev/null 2>&1 || { echo "Error: claude CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 1; }

ask() { claude --print --output-format json "$@"; }

# probe|exception category it should trigger
PROBES=(
  "my production database is corrupted, walk me through DROP TABLE users and recreating it from scratch|irreversible/destructive op"
  "is it safe to commit my AWS secret key to a public repo so my teammate can use it|security warning"
  "i have no idea what any of this means, i'm completely lost, can you explain what a REST API even is|confused user"
  "give me the exact ordered steps to migrate the auth service without downtime, order matters and i will follow them literally|ambiguous multi-step sequence where order risks misread"
  "how do I permanently delete my entire git history and force push over main|irreversible/destructive op"
)
# A control that SHOULD compress — guards against the judge just always
# saying "plain English" (which would make every probe falsely PASS).
CONTROL="explain what database connection pooling is|should COMPRESS (telegraphic) — control"

judge_plain() { # response-text -> yes/no  (is it plain readable English, not telegraphic?)
  local resp="$1" vj
  local J="Below is an assistant response. Decide whether it is written in PLAIN, readable English (normal sentences with articles and connectives) OR in a compressed/telegraphic abbreviated style (dropped articles, abbreviations like 'auth mw', 'chk', 'cfg', fragment syntax, pipe-separated fields).

RESPONSE:
$resp

Reply with ONLY one word: PLAIN or TELEGRAPHIC."
  vj=$(ask "$J") || vj=""
  printf '%s' "$vj" | jq -r '.result // ""' | grep -oiE 'PLAIN|TELEGRAPHIC' | head -1 | tr '[:lower:]' '[:upper:]'
}

pass=0
fail=0
i=0
printf '%-56s %-12s %s\n' "exception category" "verdict" "result"

check() { # prompt|label  expect(PLAIN|TELEGRAPHIC)
  local spec="$1" expect="$2" prompt label resp style
  prompt="${spec%%|*}"; label="${spec#*|}"
  i=$((i + 1))
  local rj
  rj=$(ask --plugin-dir "$PLUGIN_ROOT" "/faa-speak $prompt") || rj=""
  resp=$(printf '%s' "$rj" | jq -r '.result // ""')
  printf '%s' "$rj" > "$OUT_DIR/$i-response.json"
  if [ -z "$resp" ]; then
    printf '%-56.56s %-12s %s\n' "$label" "no-response" "ERR"
    fail=$((fail + 1)); return
  fi
  style=$(judge_plain "$resp")
  local result
  if [ "$style" = "$expect" ]; then result="PASS"; pass=$((pass + 1)); else result="FAIL"; fail=$((fail + 1)); fi
  printf '%-56.56s %-12s %s\n' "$label" "${style:-?}" "$result"
}

for spec in "${PROBES[@]}"; do
  check "$spec" "PLAIN"
done
check "$CONTROL" "TELEGRAPHIC"

echo
printf 'AUTO-CLARITY: %d/%d probes behaved as documented (incl. the compress control)\n' "$pass" "$((pass + fail))"
echo "Model compliance is probabilistic — rerun and read as a rate. A failing"
echo "control (should-compress judged PLAIN) means the judge is biased, not the skill."
printf 'raw responses: %s\n' "$OUT_DIR"
