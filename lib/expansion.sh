# shellcheck shell=bash
# faa-speak shared expansion library
# Single source of truth for the abbreviation dictionary, the apfel expansion
# prompt, apfel discovery, and the code/prose split + expand pipeline.
# Sourced by hooks/scripts/expand-output.sh and scripts/faa-wrap.sh.
# Bash 3.2 compatible (macOS default).
#
# Env:
#   APFEL       — path to the apfel binary (else PATH, else ~/git/apfel/.build/release/apfel)
#   FAA_STREAM  — 1 to stream each expanded segment to stderr as it is produced
#                 (preserves partial output if the hook is killed at its timeout)

# The canonical dictionary. skills/faa-speak/SKILL.md and README.md render this
# same list as tables; test/run.sh fails if any copy drifts.
FAA_DICT="fn=function ret=return impl=implementation cfg=configuration db=database auth=authentication req=request res=response err=error dep=dependency pkg=package idx=index init=initialize del=delete upd=update chk=check vld=validate msg=message hdr=header endpt=endpoint env=environment srv=server param=parameter arg=argument val=value var=variable obj=object arr=array str=string int=integer bool=boolean iter=iteration tpl=template cmp=component rdr=render cb=callback evnt=event sig=signal async=asynchronous mw=middleware"

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

# Split stdin into \x1e-separated records, each prefixed with a one-char type:
# "C" = fenced code block (passed through verbatim), "P" = prose.
# Fences may be indented (list-nested code blocks).
faa_split_segments() {
  awk '
    BEGIN { in_code = 0; buf = "" }
    /^[ \t]*```/ {
      if (!in_code) {
        if (buf != "") printf "P%s\036", buf
        buf = $0 "\n"; in_code = 1
      } else {
        buf = buf $0 "\n"
        printf "C%s\036", buf
        buf = ""; in_code = 0
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
# failure so degradation is never silent data loss.
_faa_apfel_chunk() {
  local chunk="$1" out
  out=$(printf '%s' "$chunk" | "$FAA_APFEL" -s "$EXPANSION_PROMPT" 2>/dev/null) || out=""
  if [ -n "$out" ]; then
    printf '%s' "$out"
  else
    printf '%s' "$chunk"
  fi
}

# Expand a prose segment. Chunks long segments at blank lines once past 300
# words, with a hard flush at 450 words so a blank-line-free wall of text can
# never exceed apfel's 4096-token context. Segments of <=3 words pass through
# unchanged (not worth an inference).
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
  local buf="" cnt=0 line n
  while IFS= read -r line; do
    n=0
    if [ -n "${line//[[:space:]]/}" ]; then
      # pure-bash word count: no subprocess per line
      local -a words
      IFS=$' \t' read -r -a words <<< "$line"
      n=${#words[@]}
    fi
    buf="$buf$line"$'\n'
    cnt=$((cnt + n))
    if { [ -z "${line//[[:space:]]/}" ] && [ "$cnt" -ge 300 ]; } || [ "$cnt" -ge 450 ]; then
      _faa_apfel_chunk "$buf"
      printf '\n'
      buf=""; cnt=0
    fi
  done <<< "$chunk"
  if [ -n "$buf" ]; then
    _faa_apfel_chunk "$buf"
  fi
}

# Full pipeline: split text into code/prose segments, expand prose via apfel,
# pass code through byte-identical, print the reassembled result to stdout.
# With FAA_STREAM=1, each segment is also written to stderr as it completes.
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
  done < <(printf '%s\n' "$text" | faa_split_segments)
}
