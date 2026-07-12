#!/usr/bin/env bash
# measure-addressable.sh — how much of your REAL output could faa-speak touch?
#
# The bench prompts are prose-only Q&A: the technique's best case. In real
# Claude Code sessions, output tokens are dominated by tool calls, code, and
# thinking — all exempt from compression. This script reads your local
# transcript JSONL (the same shape the Stop hook parses) and decomposes the
# billed output into:
#   prose in text blocks   — the only part faa-speak compresses
#   code inside text blocks (fenced) — exempt by design
#   tool_use input JSON    — exempt (never compressed)
#   thinking + overhead    — billed in usage.output_tokens but char-invisible
#                            in the transcript; inferred as the remainder
# then reports the expected NET savings: measured compression x addressable
# share. Aggregate numbers only; no conversation content leaves the terminal.
#
# Usage:
#   scripts/measure-addressable.sh [transcript-dir ...]   # default: ~/.claude/projects
#   SAVINGS_PCT=53 scripts/measure-addressable.sh         # compression rate to project with
#
# Heuristic: visible chars are converted to tokens at chars/4. Crude but
# stated — the point is the ORDER of the addressable share, not its third
# significant digit.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { printf 'Error: jq not found\n' >&2; exit 1; }

SAVINGS_PCT="${SAVINGS_PCT:-53}"
DIRS=("$HOME/.claude/projects")
if [ $# -gt 0 ]; then DIRS=("$@"); fi

TMP=$(mktemp "${TMPDIR:-/tmp}/faa-addr.XXXXXX")
trap 'rm -f "$TMP"' EXIT

files=0
while IFS= read -r f; do
  files=$((files + 1))
  # one \x1e-framed record per content block: T<text> or U<tool_use JSON length>;
  # plus K<message id>\x1f<output_tokens> for usage (deduped later — every
  # content block of a message repeats the same usage object)
  jq -rj 'select(.message.role? == "assistant") |
    ("\u001eK" + (.message.id // "no-id") + "\u001f" + ((.message.usage.output_tokens // 0) | tostring)),
    (.message.content[]? |
      if .type == "text" then "\u001eT" + (.text // "")
      elif .type == "tool_use" then "\u001eU" + ((.input // {}) | tostring | length | tostring)
      else empty end)' "$f" 2>/dev/null || true
done < <(find "${DIRS[@]}" -name '*.jsonl' -type f 2>/dev/null) >> "$TMP"

if [ ! -s "$TMP" ]; then
  printf 'No assistant records found under: %s\n' "${DIRS[*]}" >&2
  exit 1
fi
printf 'corpus: %d transcript files under %s\n' "$files" "${DIRS[*]}"

awk -v savings="$SAVINGS_PCT" '
BEGIN { RS = "\036"; msgs = 0; tokens = 0; prose = 0; code = 0; tool = 0 }
{
  tag = substr($0, 1, 1)
  body = substr($0, 2)
  if (tag == "K") {
    split(body, kv, "\037")
    if (!(kv[1] in seen)) { seen[kv[1]] = 1; msgs++; tokens += kv[2] + 0 }
  } else if (tag == "U") {
    tool += body + 0
  } else if (tag == "T") {
    # simple fence toggle is enough for a share estimate
    n = split(body, lines, "\n")
    in_code = 0
    for (i = 1; i <= n; i++) {
      if (lines[i] ~ /^[ \t]*```/) { in_code = !in_code; code += length(lines[i]) + 1; continue }
      if (in_code) code += length(lines[i]) + 1
      else prose += length(lines[i]) + 1
    }
  }
}
END {
  visible = prose + code + tool
  if (visible == 0) { print "no visible assistant content found" > "/dev/stderr"; exit 1 }
  printf "assistant messages: %d · billed output tokens (usage, deduped): %d\n\n", msgs, tokens
  printf "visible content decomposition (chars):\n"
  printf "  prose in text blocks (faa-addressable):  %10d  (%d%%)\n", prose, prose * 100 / visible
  printf "  code inside text blocks (exempt):        %10d  (%d%%)\n", code, code * 100 / visible
  printf "  tool_use input JSON (exempt):            %10d  (%d%%)\n", tool, tool * 100 / visible
  if (tokens > 0) {
    vis_tok = visible / 4                    # chars/4 heuristic, stated in header
    # Old transcripts can lack usage while still carrying content, so the
    # visible estimate can exceed billed tokens; share everything over the
    # larger of the two so the split always sums to ~100%.
    denom = (tokens > vis_tok) ? tokens : vis_tok
    think = tokens - vis_tok; if (think < 0) think = 0
    prose_share = (prose / 4) * 100 / denom
    printf "\nestimated shares of output tokens (chars/4 heuristic):\n"
    printf "  prose (addressable):        ~%d%%\n", prose_share
    printf "  code + tool_use (exempt):   ~%d%%\n", ((code + tool) / 4) * 100 / denom
    printf "  thinking + overhead:        ~%d%%   (billed but char-invisible in transcripts)\n", think * 100 / denom
    if (vis_tok > tokens)
      printf "  (usage data incomplete for this corpus — shares computed over the visible-content estimate)\n"
    printf "\nexpected NET savings at %d%% prose compression: ~%.1f%% of output tokens\n", savings, savings * prose_share / 100
    printf "(the bench measures the prose slice only — this is what it means for your whole bill)\n"
  } else {
    printf "\n(no usage data in these transcripts — token-share estimate skipped)\n"
  }
}
' "$TMP"
