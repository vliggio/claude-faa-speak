#!/usr/bin/env bash
# faa-speak Stop hook
# Extracts compressed assistant output, expands via apfel, prints to stderr.
# Non-blocking: always exits 0, never prevents the stop.

set -euo pipefail

# Read hook input from stdin
HOOK_INPUT=$(cat)

# --- Locate apfel binary ---
APFEL="${APFEL:-}"
if [[ -z "$APFEL" ]]; then
  if command -v apfel &>/dev/null; then
    APFEL="apfel"
  elif [[ -x "$HOME/git/apfel/.build/release/apfel" ]]; then
    APFEL="$HOME/git/apfel/.build/release/apfel"
  else
    # No apfel available — silently skip
    exit 0
  fi
fi

# --- Extract last assistant text from transcript ---
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""')

if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# Check for assistant messages
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  exit 0
fi

# Extract the most recent assistant text block (same pattern as ralph-loop)
LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100)
if [[ -z "$LAST_LINES" ]]; then
  exit 0
fi

set +e
LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs '
  map(.message.content[]? | select(.type == "text") | .text) | last // ""
' 2>&1)
JQ_EXIT=$?
set -e

if [[ $JQ_EXIT -ne 0 ]] || [[ -z "$LAST_OUTPUT" ]]; then
  exit 0
fi

# --- Check for faa-speak marker ---
if [[ "$LAST_OUTPUT" != *'<!-- faa -->'* ]]; then
  exit 0
fi

# Strip the marker
TEXT="${LAST_OUTPUT//<!-- faa -->/}"
# Trim trailing whitespace
TEXT=$(echo "$TEXT" | sed -e 's/[[:space:]]*$//')

if [[ -z "$TEXT" ]]; then
  exit 0
fi

# --- Expansion system prompt ---
EXPANSION_PROMPT='Expand abbreviated technical text to clear English.
Abbreviations: fn=function ret=return impl=implementation cfg=configuration db=database auth=authentication req=request res=response err=error dep=dependency pkg=package env=environment srv=server param=parameter val=value var=variable obj=object arr=array str=string mw=middleware endpt=endpoint hdr=header cmp=component rdr=render cb=callback init=initialize del=delete upd=update chk=check vld=validate idx=index iter=iteration tpl=template cmp=component evnt=event sig=signal bool=boolean int=integer async=asynchronous msg=message
Arrows (→) mean "leads to" or "causes". DX: = diagnosis (symptom|cause|fix). EX: = explanation (what|why|how). ARCH: = architecture (pattern|tradeoff|recommendation).
Preserve code blocks, file paths, and commands exactly as-is. Do not modify anything inside backticks or fenced code blocks.
Add articles, conjunctions, and natural phrasing. Do not add opinions or extra information not present in the original.'

# --- Separate code blocks from prose ---
# We pass code blocks through unchanged and only expand prose sections.
# Strategy: split into segments, tag each as "code" or "prose", expand prose only.

expand_prose() {
  local chunk="$1"
  if [[ -z "$chunk" ]]; then
    return
  fi
  # Approximate word count
  local wc
  wc=$(echo "$chunk" | wc -w | tr -d ' ')
  if [[ "$wc" -le 3 ]]; then
    # Too short to bother expanding
    echo "$chunk"
    return
  fi
  # Pipe through apfel
  local expanded
  expanded=$(echo "$chunk" | "$APFEL" -s "$EXPANSION_PROMPT" 2>/dev/null) || true
  if [[ -n "$expanded" ]]; then
    echo "$expanded"
  else
    # Expansion failed — return original
    echo "$chunk"
  fi
}

# Split text into code/prose segments and process
# Uses awk to emit tagged segments: CODE:... or PROSE:...
SEGMENTS=$(echo "$TEXT" | awk '
  BEGIN { in_code=0; buf="" }
  /^```/ {
    if (!in_code) {
      if (buf != "") { print "PROSE:" buf; buf="" }
      in_code=1; buf=$0 "\n"
    } else {
      buf=buf $0 "\n"
      print "CODE:" buf; buf=""
      in_code=0
    }
    next
  }
  {
    buf=buf $0 "\n"
  }
  END {
    if (in_code) {
      print "CODE:" buf
    } else if (buf != "") {
      print "PROSE:" buf
    }
  }
')

# Process segments and reassemble
EXPANDED_OUTPUT=""
while IFS= read -r segment; do
  if [[ "$segment" == CODE:* ]]; then
    # Code block — pass through unchanged
    EXPANDED_OUTPUT+="${segment#CODE:}"
  elif [[ "$segment" == PROSE:* ]]; then
    # Prose — expand via apfel
    prose_text="${segment#PROSE:}"
    # Chunk large prose at double-newline boundaries (~500 words per chunk)
    wc=$(echo "$prose_text" | wc -w | tr -d ' ')
    if [[ "$wc" -gt 500 ]]; then
      # Split on double newlines
      chunk=""
      chunk_wc=0
      while IFS= read -r line; do
        if [[ -z "$line" ]] && [[ "$chunk_wc" -gt 300 ]]; then
          EXPANDED_OUTPUT+="$(expand_prose "$chunk")"
          EXPANDED_OUTPUT+=$'\n\n'
          chunk=""
          chunk_wc=0
        else
          chunk+="$line"$'\n'
          line_wc=$(echo "$line" | wc -w | tr -d ' ')
          chunk_wc=$((chunk_wc + line_wc))
        fi
      done <<< "$prose_text"
      if [[ -n "$chunk" ]]; then
        EXPANDED_OUTPUT+="$(expand_prose "$chunk")"
      fi
    else
      EXPANDED_OUTPUT+="$(expand_prose "$prose_text")"
    fi
  fi
done <<< "$SEGMENTS"

# --- Print expanded output to stderr ---
if [[ -n "$EXPANDED_OUTPUT" ]]; then
  echo "" >&2
  echo "━━━ faa-speak expansion (via apfel) ━━━" >&2
  echo "$EXPANDED_OUTPUT" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
fi

exit 0
