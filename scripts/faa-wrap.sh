#!/usr/bin/env bash
# faa-wrap: Standalone wrapper for claude --print with faa-speak expansion.
# Captures Claude's compressed output and expands via apfel.
#
# Usage:
#   faa-wrap.sh "explain database connection pooling"
#   faa-wrap.sh -p "custom system prompt" "your question"
#   echo "context" | faa-wrap.sh "summarize this"

set -euo pipefail

# Locate apfel
APFEL="${APFEL:-}"
if [[ -z "$APFEL" ]]; then
  if command -v apfel &>/dev/null; then
    APFEL="apfel"
  elif [[ -x "$HOME/git/apfel/.build/release/apfel" ]]; then
    APFEL="$HOME/git/apfel/.build/release/apfel"
  else
    echo "Error: apfel not found. Build it: cd ~/git/apfel && swift build -c release" >&2
    exit 1
  fi
fi

EXPANSION_PROMPT='Expand abbreviated technical text to clear English.
Abbreviations: fn=function ret=return impl=implementation cfg=configuration db=database auth=authentication req=request res=response err=error dep=dependency pkg=package env=environment srv=server param=parameter val=value var=variable obj=object arr=array str=string mw=middleware endpt=endpoint hdr=header cmp=component rdr=render cb=callback init=initialize del=delete upd=update chk=check vld=validate idx=index iter=iteration tpl=template cmp=component evnt=event sig=signal bool=boolean int=integer async=asynchronous msg=message
Arrows (→) mean "leads to" or "causes". DX: = diagnosis (symptom|cause|fix). EX: = explanation (what|why|how). ARCH: = architecture (pattern|tradeoff|recommendation).
Preserve code blocks, file paths, and commands exactly as-is.
Add articles, conjunctions, and natural phrasing. Do not add opinions or extra information.'

# Capture compressed output from claude
COMPRESSED=$(claude --print "$@")

if [[ "$COMPRESSED" == *'<!-- faa -->'* ]]; then
  echo "$COMPRESSED" | sed 's/<!-- faa -->//' | "$APFEL" -s "$EXPANSION_PROMPT"
else
  echo "$COMPRESSED"
fi
