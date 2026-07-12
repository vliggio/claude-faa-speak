#!/usr/bin/env bash
# Deterministic reference expander for fidelity-harness PLUMBING tests.
# Substitutes FAA_DICT abbreviations word-for-word and echoes everything
# else — no model in the loop. This validates the harness and the pair
# files in CI; it says nothing about apfel's real fidelity (run the
# harness against real apfel for that).
# Ignores the -s <prompt> arguments, like apfel's CLI shape.
set -u
REF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$REF_DIR/../../lib/expansion.sh"
awk -v dict="$FAA_DICT" '
BEGIN {
  n = split(dict, entries, " ")
  for (i = 1; i <= n; i++) { split(entries[i], kv, "="); m[kv[1]] = kv[2] }
}
{
  nw = split($0, w, " ")
  line = ""
  for (i = 1; i <= nw; i++) {
    tok = (w[i] in m) ? m[w[i]] : w[i]
    line = (i == 1) ? tok : line " " tok
  }
  print line
}'
