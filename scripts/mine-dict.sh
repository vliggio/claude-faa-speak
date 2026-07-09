#!/usr/bin/env bash
# mine-dict.sh — mine local Claude Code transcripts for dictionary candidates.
#
# Extracts assistant response text from transcript JSONL files (the same
# shape the Stop hook parses), strips fenced code / inline code / URLs, and
# ranks unigram + bigram + trigram frequencies — excluding stopwords and the
# terms FAA_DICT already covers. Output is vocabulary and counts only; no
# prompt or response content leaves the terminal.
#
# Ranking is frequency-only. Before promoting a candidate, verify its token
# delta with the count_tokens API — a word earns a dictionary slot only if
# tokens(full form) > tokens(abbreviation) — then add it to a
# bench/extdict-plugin variant and A/B it with scripts/bench.sh.
#
# Usage:
#   scripts/mine-dict.sh [transcript-dir ...]    # default: ~/.claude/projects
#   TOP=60 MINCOUNT=10 MINLEN=6 scripts/mine-dict.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../lib/expansion.sh
. "$ROOT/lib/expansion.sh"

command -v jq >/dev/null 2>&1 || { printf 'Error: jq not found\n' >&2; exit 1; }

TOP="${TOP:-40}"
MINCOUNT="${MINCOUNT:-5}"
MINLEN="${MINLEN:-5}"
DIRS=("$HOME/.claude/projects")
if [ $# -gt 0 ]; then DIRS=("$@"); fi

# words the dictionary already handles (both full forms and abbreviations)
DICT_FULL=$(printf '%s' "$FAA_DICT" | tr ' ' '\n' | cut -d= -f2 | tr '\n' ' ')
DICT_ABBR=$(printf '%s' "$FAA_DICT" | tr ' ' '\n' | cut -d= -f1 | tr '\n' ' ')

TMP=$(mktemp "${TMPDIR:-/tmp}/faa-mine.XXXXXX")
COUNTS="$TMP.counts"
trap 'rm -f "$TMP" "$COUNTS"' EXIT

files=0
while IFS= read -r f; do
  files=$((files + 1))
  jq -rR 'fromjson? | .message? | select(.role? == "assistant")
          | .content[]? | select(.type? == "text") | .text' "$f" 2>/dev/null || true
done < <(find "${DIRS[@]}" -name '*.jsonl' -type f 2>/dev/null) >> "$TMP"

if [ ! -s "$TMP" ]; then
  printf 'No assistant text found under: %s\n' "${DIRS[*]}" >&2
  exit 1
fi
printf 'corpus: %d transcript files, %s bytes of assistant text\n' \
  "$files" "$(wc -c < "$TMP" | tr -d ' ')" >&2

awk -v minlen="$MINLEN" -v full="$DICT_FULL" -v abbr="$DICT_ABBR" '
BEGIN {
  nf = split(full, fa, " "); for (i = 1; i <= nf; i++) covered[fa[i]] = 1
  na = split(abbr, aa, " "); for (i = 1; i <= na; i++) covered[aa[i]] = 1
  ns = split("the a an and or but if then else of to in on at by for with " \
    "from as is are was were be been being it its this that these those " \
    "there their they them you your we our i he she his her not no yes can " \
    "could should would will shall may might must have has had do does did " \
    "done just like also very more most much many some any all each both " \
    "few own same so than too only over under again once here when where " \
    "why how what which who whom whose while about against between through " \
    "during before after above below up down out off into onto use used " \
    "using get got make made see need want way thing things something " \
    "anything nothing rather every still since however therefore because " \
    "without within already actually", sa, " ")
  for (i = 1; i <= ns; i++) stop[sa[i]] = 1
}
/^[ \t]*```/ { in_code = !in_code; next }
in_code { next }
{
  line = tolower($0)
  gsub(/`[^`]*`/, " ", line)              # inline code spans
  gsub(/https?:\/\/[^ ]*/, " ", line)     # URLs
  gsub(/[.,;:!?()<>{}]+/, " zzzbrk ", line)   # punctuation = n-gram boundary
  n = split(line, tk, /[^a-z]+/)
  p1 = "zzzbrk"; p2 = "zzzbrk"
  for (i = 1; i <= n; i++) {
    w = tk[i]
    if (w == "") continue
    total++
    if (w != "zzzbrk") {
      if (length(w) >= minlen && !(w in stop) && !(w in covered)) uni[w]++
      if (p1 != "zzzbrk" && length(w) >= 3 && length(p1) >= 3 && \
          !((w in stop) && (p1 in stop))) bi[p1 " " w]++
      if (p1 != "zzzbrk" && p2 != "zzzbrk" && \
          !((w in stop) && (p1 in stop) && (p2 in stop))) tri[p2 " " p1 " " w]++
    }
    p2 = p1; p1 = w
  }
}
END {
  for (w in uni) printf "U\t%d\t%s\n", uni[w], w
  for (w in bi)  printf "B\t%d\t%s\n", bi[w], w
  for (w in tri) printf "T\t%d\t%s\n", tri[w], w
  printf "tokens scanned: %d\n", total > "/dev/stderr"
}
' "$TMP" > "$COUNTS"

show() { # tag title
  printf '\n=== %s (top %s, count >= %s) ===\n' "$2" "$TOP" "$MINCOUNT"
  awk -F'\t' -v t="$1" -v m="$MINCOUNT" \
    '$1 == t && $2 >= m { printf "%7d  %s\n", $2, $3 }' "$COUNTS" \
    | sort -rn | head -n "$TOP"
}

show U "unigram candidates (length >= $MINLEN, FAA_DICT-covered words excluded)"
show B "bigram phrase candidates"
show T "trigram phrase candidates"

cat <<'EOF'

Next steps (see issue #10 discussion):
  1. Verify each candidate's token delta with the count_tokens API —
     it earns a slot only if tokens(full) > tokens(abbreviation).
  2. Pick unambiguous abbreviations; avoid strings that appear as real
     identifiers in code (ctx, txn, ...) — expansion-fidelity hazard.
  3. Copy bench/nodict-plugin to bench/extdict-plugin, add the surviving
     candidates to its skill table, and A/B against the current dictionary
     with scripts/bench.sh before shipping anything.
EOF
