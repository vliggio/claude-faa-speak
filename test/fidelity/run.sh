#!/usr/bin/env bash
# Fidelity gate: does the compressed→expanded round trip preserve meaning?
#
# Runs each golden pair in test/fidelity/pairs/ through the real expansion
# pipeline (faa_expand_text → apfel) and applies deterministic checks:
#
#   generic (derived from the input, no configuration):
#     - every `backtick span` appears byte-identical in the expansion
#     - every number appears in the expansion
#     - every fenced code block appears byte-identical
#   per-pair:
#     - "must-contain" literals (e.g. the full forms of dictionary hazard
#       words: vld→valid…, evnt→event…)
#     - "must-not-contain" literals (meaning inversions)
#
# This is the release gate for dictionary or expansion-prompt changes —
# run it on a machine with Apple Intelligence enabled. Without a usable
# expander it SKIPs (exit 0) rather than failing, so it can run anywhere.
# The main suite exercises this harness's plumbing with a deterministic
# reference expander (ref-expander.sh); a real-model run is still required
# before shipping prompt/dictionary changes.
#
# Pair file format (lines before the first marker are comments):
#   === input ===
#   ...compressed text...
#   === must-contain ===       (optional; one literal per line)
#   === must-not-contain ===   (optional; one literal per line)
#
# Usage:
#   bash test/fidelity/run.sh          # real apfel (APFEL env overrides)
set -u

FID_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$FID_DIR/../.." && pwd)
. "$ROOT/lib/expansion.sh"

APFEL_BIN=$(faa_locate_apfel) || { echo "SKIP: apfel not found (APFEL env, PATH, ~/git/apfel)"; exit 0; }
PROBE=$(printf 'db conn chk' | "$APFEL_BIN" -s "expand abbreviations" 2>&1) || PROBE=""
if [ -z "$PROBE" ]; then
  echo "SKIP: expander produced no output — Apple Intelligence enabled? (apfel --model-info)"
  exit 0
fi

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/faa-fidelity.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

PASS=0
FAIL=0
for pair in "$FID_DIR"/pairs/*.txt; do
  name=$(basename "$pair" .txt)
  rm -f "$TMPD/input" "$TMPD/must" "$TMPD/mustnot"
  awk -v dir="$TMPD" '
    /^=== input ===$/ { sec = "input"; next }
    /^=== must-contain ===$/ { sec = "must"; next }
    /^=== must-not-contain ===$/ { sec = "mustnot"; next }
    sec != "" { print > (dir "/" sec) }
  ' "$pair"
  INPUT=$(cat "$TMPD/input" 2>/dev/null)
  if [ -z "$INPUT" ]; then
    printf 'FAIL %-18s (empty input section)\n' "$name"
    FAIL=$((FAIL + 1))
    continue
  fi
  OUT=$(faa_expand_text "$INPUT" 2>/dev/null)
  errs=""

  # generic: backtick spans byte-identical
  while IFS= read -r span; do
    [ -n "$span" ] || continue
    case "$OUT" in *"$span"*) : ;; *) errs="$errs
    missing backtick span: $span" ;; esac
  done <<EOF
$(printf '%s' "$INPUT" | grep -o '`[^`]*`' | sort -u)
EOF

  # generic: numbers preserved
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    case "$OUT" in *"$num"*) : ;; *) errs="$errs
    missing number: $num" ;; esac
  done <<EOF
$(printf '%s' "$INPUT" | grep -oE '[0-9]+(\.[0-9]+)?' | sort -u)
EOF

  # generic: fenced code blocks byte-identical
  while IFS= read -r -d $'\x1e' seg; do
    [ "${seg:0:1}" = "C" ] || continue
    block=${seg:1}
    case "$OUT" in *"$block"*) : ;; *) errs="$errs
    fenced block not byte-identical" ;; esac
  done < <(printf '%s\n' "$INPUT" | faa_split_segments)

  # per-pair literals
  if [ -s "$TMPD/must" ]; then
    while IFS= read -r needle; do
      [ -n "$needle" ] || continue
      case "$OUT" in *"$needle"*) : ;; *) errs="$errs
    must-contain missing: $needle" ;; esac
    done < "$TMPD/must"
  fi
  if [ -s "$TMPD/mustnot" ]; then
    while IFS= read -r needle; do
      [ -n "$needle" ] || continue
      case "$OUT" in *"$needle"*) errs="$errs
    must-not-contain present: $needle" ;; esac
    done < "$TMPD/mustnot"
  fi

  if [ -z "$errs" ]; then
    printf 'PASS %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s%s\n' "$name" "$errs"
    FAIL=$((FAIL + 1))
  fi
done

echo
printf 'fidelity: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
