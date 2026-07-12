# shellcheck shell=bash
# faa-speak shared expansion library
# Single source of truth for the abbreviation dictionary, the apfel expansion
# prompt, apfel discovery, and the code/prose split + expand pipeline.
# Sourced by hooks/scripts/expand-output.sh and scripts/faa-wrap.sh.
# Bash 3.2 compatible (macOS default).
#
# Env:
#   APFEL            — path to the apfel binary (else PATH, else ~/git/apfel/.build/release/apfel)
#   FAA_STREAM       — 1 to stream each expanded segment to stderr as it is produced
#                       (preserves partial output if the hook is killed at its timeout)
#   FAA_SHOW_SAVINGS — 1 to report compression savings (word/char counts) on expansion

# The canonical dictionary. skills/faa-speak/SKILL.md and README.md render this
# same list as tables; test/run.sh fails if any copy drifts.
FAA_DICT="arg=argument arr=array async=asynchronous auth=authentication bool=boolean cb=callback cfg=configuration chk=check cmp=component db=database del=delete dep=dependency endpt=endpoint env=environment err=error evnt=event fn=function hdr=header idx=index impl=implementation init=initialize int=integer iter=iteration msg=message mw=middleware obj=object param=parameter pkg=package rdr=render req=request res=response ret=return sig=signal srv=server str=string tpl=template upd=update val=value var=variable vld=validate"

EXPANSION_PROMPT="Expand abbreviated technical text to clear English.
Abbreviations: ${FAA_DICT}
Arrows (→) mean \"leads to\" or \"causes\". DX: = diagnosis (symptom|cause|fix). EX: = explanation (what|why|how). ARCH: = architecture (pattern|tradeoff|recommendation).
Preserve code blocks, file paths, and commands exactly as-is. Do not modify anything inside backticks or fenced code blocks.
Add articles, conjunctions, and natural phrasing. Do not add opinions or extra information not present in the original."

# Locate apfel; prints the path, returns 1 if unavailable.
faa_locate_apfel() {
  if [ -n "${APFEL:-}" ]; then
    printf '%s' "$APFEL"
    return 0
  fi
  if command -v apfel >/dev/null 2>&1; then
    printf '%s' "apfel"
    return 0
  fi
  if [ -x "$HOME/git/apfel/.build/release/apfel" ]; then
    printf '%s' "$HOME/git/apfel/.build/release/apfel"
    return 0
  fi
  return 1
}

# Marker gate — the single definition of the expansion contract: accept only
# text that ENDS with the <!-- faa --> marker (a marker quoted mid-text never
# triggers); strips it and surrounding whitespace into TEXT. Returns 1 when
# the gate fails. Used by the Stop hook and the wrapper so both entry points
# enforce the same rule.
faa_gate() {
  local t="$1"
  while [ -n "$t" ] && [[ "$t" == *[$' \t\r\n'] ]]; do t=${t%?}; done
  if [[ "$t" != *'<!-- faa -->' ]]; then return 1; fi
  t=${t%'<!-- faa -->'}
  while [ -n "$t" ] && [[ "$t" == *[$' \t\r\n'] ]]; do t=${t%?}; done
  if [ -z "$t" ]; then return 1; fi
  # shellcheck disable=SC2034  # TEXT is the out-param read by the sourcing scripts
  TEXT="$t"
}

# Split stdin into \x1e-separated records, each prefixed with a one-char type:
# "C" = fenced code block (passed through verbatim), "P" = prose.
# Fences may be indented (list-nested code blocks) and use backticks or
# tildes. Fence tracking follows CommonMark: a block opened with N fence
# chars closes only on >= N of the SAME char with nothing after them — so a
# ```-fenced example inside a ````- or ~~~-fenced block stays code, and an
# info-string line (```js) never closes an open block. Indented (4-space,
# unfenced) code blocks are NOT recognized — SKILL.md instructs fenced output.
faa_split_segments() {
  awk '
    BEGIN { in_code = 0; buf = ""; fence = 0; fchar = "" }
    /^[ \t]*(```|~~~)/ {
      line = $0
      sub(/^[ \t]*/, "", line)
      c = substr(line, 1, 1)
      len = 0
      while (substr(line, len + 1, 1) == c) len++
      rest = substr(line, len + 1)
      if (!in_code) {
        if (buf != "") printf "P%s\036", buf
        buf = $0 "\n"; in_code = 1; fence = len; fchar = c
      } else if (c == fchar && len >= fence && rest ~ /^[ \t]*$/) {
        buf = buf $0 "\n"
        printf "C%s\036", buf
        buf = ""; in_code = 0
      } else {
        buf = buf $0 "\n"
      }
      next
    }
    { buf = buf $0 "\n" }
    END {
      if (buf != "") printf "%s%s\036", (in_code ? "C" : "P"), buf
    }
  '
}

# Expand one chunk through apfel; falls back to the original text on any
# failure so degradation is never data loss. Failures are NOT silent to the
# caller: when FAA_FALLBACK_FLAG names a file, each failed chunk appends to
# it, and apfel's stderr is preserved in FAA_APFEL_ERR (if set) so the caller
# can tell the user WHY (e.g. "Apple Intelligence not enabled").
_faa_apfel_chunk() {
  local chunk="$1" out
  out=$(printf '%s' "$chunk" | "$FAA_APFEL" -s "$EXPANSION_PROMPT" 2>>"${FAA_APFEL_ERR:-/dev/null}") || out=""
  if [ -n "$out" ]; then
    printf '%s' "$out"
  else
    if [ -n "${FAA_FALLBACK_FLAG:-}" ]; then
      printf '1' >> "$FAA_FALLBACK_FLAG" 2>/dev/null || true
    fi
    printf '%s' "$chunk"
  fi
}

# Expand a prose segment. Chunks long segments at blank lines once past 300
# words, with a hard cap of 450 words per chunk so no chunk can exceed
# apfel's 4096-token context — the cap holds even when a whole paragraph
# arrives as one line (markdown paragraphs usually do): such a line is
# sliced at word boundaries. Segments of <=3 words pass through unchanged
# (not worth an inference); whitespace-only buffers are emitted verbatim,
# never sent to apfel (a small model handed blank input can answer the
# expansion prompt itself, splicing hallucinated text into the output).
faa_expand_prose() {
  local chunk="$1" wc
  wc=$(printf '%s' "$chunk" | wc -w | tr -d '[:space:]')
  if [ "${wc:-0}" -le 3 ]; then
    printf '%s' "$chunk"
    return 0
  fi
  if [ "$wc" -le 450 ]; then
    _faa_apfel_chunk "$chunk"
    return 0
  fi
  # Blank/whitespace tests below use glob MATCHES (*[![:space:]]*), never
  # ${var//[[:space:]]/} substitution — bash 3.2's pattern substitution is
  # quadratic-or-worse on long strings (a 22KB paragraph takes minutes).
  local buf="" cnt=0 line n i
  while IFS= read -r line; do
    n=0
    # pure-bash word count: no subprocess per line
    local -a words
    words=()
    if [[ "$line" == *[![:space:]]* ]]; then
      IFS=$' \t' read -r -a words <<< "$line"
      n=${#words[@]}
    fi
    if [ "$n" -gt 450 ]; then
      # single line past the hard cap: flush pending text, then slice the
      # line itself into 450-word chunks (intra-line whitespace normalizes
      # to single spaces; it is prose bound for rewriting anyway)
      if [[ "$buf" == *[![:space:]]* ]]; then
        _faa_apfel_chunk "$buf"
        printf '\n'
      else
        printf '%s' "$buf"
      fi
      buf=""; cnt=0
      i=0
      while [ $((n - i)) -gt 450 ]; do
        _faa_apfel_chunk "${words[*]:i:450}"
        printf '\n'
        i=$((i + 450))
      done
      buf="${words[*]:i}"$'\n'
      cnt=$((n - i))
      continue
    fi
    if [ "$cnt" -gt 0 ] && [ $((cnt + n)) -gt 450 ]; then
      _faa_apfel_chunk "$buf"
      printf '\n'
      buf=""; cnt=0
    fi
    buf="$buf$line"$'\n'
    cnt=$((cnt + n))
    if [[ "$line" != *[![:space:]]* ]] && [ "$cnt" -ge 300 ]; then
      _faa_apfel_chunk "$buf"
      printf '\n'
      buf=""; cnt=0
    fi
  done <<< "$chunk"
  if [[ "$buf" == *[![:space:]]* ]]; then
    _faa_apfel_chunk "$buf"
  else
    printf '%s' "$buf"
  fi
}

# Builds a one-line compression-savings summary comparing compressed source
# text to its expanded form (word/char counts, percent shorter). Prints to
# stdout; callers redirect to a systemMessage, stderr, etc. as needed.
faa_savings_line() {
  local compressed="$1" expanded="$2" c_chars e_chars c_words e_words pct
  c_chars=${#compressed}
  e_chars=${#expanded}
  c_words=$(printf '%s' "$compressed" | wc -w | tr -d '[:space:]')
  e_words=$(printf '%s' "$expanded" | wc -w | tr -d '[:space:]')
  if [ "${e_chars:-0}" -gt 0 ]; then
    pct=$(( (e_chars - c_chars) * 100 / e_chars ))
  else
    pct=0
  fi
  printf 'faa-speak savings: %s words / %s chars compressed → %s words / %s chars expanded (~%s%% shorter)' \
    "${c_words:-0}" "$c_chars" "${e_words:-0}" "$e_chars" "$pct"
}

# Full pipeline: split text into code/prose segments, expand prose via apfel,
# pass code through byte-identical, print the reassembled result to stdout.
# With FAA_STREAM=1, each segment is also written to stderr as it completes.
# \x1e is the record separator, so any literal \x1e byte in the text is
# dropped up front — otherwise it would corrupt the framing (losing one
# never-legitimately-printable control byte beats mangling whole segments).
faa_expand_text() {
  local text="$1" seg type content piece
  FAA_APFEL=$(faa_locate_apfel) || return 1
  while IFS= read -r -d $'\x1e' seg; do
    type=${seg:0:1}
    content=${seg:1}
    if [ "$type" = "C" ]; then
      piece="$content"
    else
      piece="$(faa_expand_prose "$content")"$'\n'
    fi
    if [ "${FAA_STREAM:-0}" = "1" ]; then
      printf '%s' "$piece" >&2
    fi
    printf '%s' "$piece"
  done < <(printf '%s\n' "$text" | tr -d '\036' | faa_split_segments)
}
