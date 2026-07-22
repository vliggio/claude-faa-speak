#!/usr/bin/env bash
# bench-agentic.sh — measure the output-token levers that dominate real Claude
# Code usage but that scripts/bench.sh (single-response Q&A) cannot see:
# tool-call round-trips and edit size. The 2026-07 measurement found ~70% of
# output tokens are tool-call content — this is the harness that puts a number
# on the lean skill's "diffs-not-rewrites / read-once / minimize round-trips"
# rules on a real editing task.
#
# Each prompt runs in a FRESH temp git repo (edits must not compound across
# runs), once plain and once with bench/lean-plugin. Metrics per run, from
# `claude --print --output-format json`: output_tokens (primary), num_turns
# (round-trip proxy — the CLI json summary has no direct tool-call count),
# total_cost_usd.
#
# Requires a logged-in claude CLI; costs real tokens and RUNS TOOLS (it edits
# files in a throwaway dir). Usage:
#   scripts/bench-agentic.sh              # built-in edit tasks, 1 run each
#   scripts/bench-agentic.sh -n 3         # 3 runs per cell
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LEAN_ROOT="$PLUGIN_ROOT/bench/lean-plugin"
LEAN_SKILL="faa-speak-lean"

command -v claude >/dev/null 2>&1 || { echo "Error: claude CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Error: git not found" >&2; exit 1; }

RUNS=1
if [ "${1:-}" = "-n" ]; then RUNS="${2:?-n needs a count}"; shift 2; fi
case "$RUNS" in (*[!0-9]*|'') echo "Error: -n needs a positive integer" >&2; exit 1 ;; esac

# Each task: a seed file (written into the temp repo) + an edit instruction.
# Kept small and edit-shaped so the diff-vs-rewrite and round-trip levers show.
seed_and_prompt() { # task-id -> writes ./target file, echoes the prompt
  case "$1" in
    validate)
      cat > target.py <<'PY'
def divide(a, b):
    return a / b


def get_user(users, i):
    return users[i]
PY
      echo "Add input validation to both functions in target.py (guard against divide-by-zero and out-of-range index). Change only what is needed."
      ;;
    rename)
      cat > target.py <<'PY'
def calc(x):
    tmp = x * 2
    tmp = tmp + 1
    return tmp
PY
      echo "In target.py rename the local variable tmp to result throughout. Change only what is needed."
      ;;
    typo)
      cat > README.md <<'MD'
# Widget

This tool proccesses widgets and retruns a report.
It is fast and relaible.
MD
      echo "Fix the three spelling errors in README.md. Change only what is needed."
      ;;
  esac
}
TASKS=(validate rename typo)

# One agentic run in a fresh temp git repo. Echoes "output_tokens num_turns cost".
run_cell() { # task-id  mode(plain|lean)
  local task="$1" mode="$2" d out
  d=$(mktemp -d "${TMPDIR:-/tmp}/faa-agentic.XXXXXX")
  (
    cd "$d" || exit 1
    git init -q 2>/dev/null || true
    local prompt; prompt=$(seed_and_prompt "$task")
    if [ "$mode" = "lean" ]; then
      out=$(claude --print --output-format json --plugin-dir "$LEAN_ROOT" \
        --setting-sources project "/$LEAN_SKILL $prompt" 2>/dev/null) || out=""
    else
      out=$(claude --print --output-format json \
        --setting-sources project "$prompt" 2>/dev/null) || out=""
    fi
    printf '%s' "$out" | jq -r '"\(.usage.output_tokens // 0) \(.num_turns // 0) \(.total_cost_usd // 0)"' 2>/dev/null \
      || printf '0 0 0'
  )
  rm -rf "$d"
}

printf '%-10s %-6s %10s %8s %10s\n' "task" "mode" "out_tok" "turns" "cost_usd"
tp_tok=0; tp_turn=0; tl_tok=0; tl_turn=0
for task in "${TASKS[@]}"; do
  r=1
  while [ "$r" -le "$RUNS" ]; do
    read -r pt pturn pcost <<<"$(run_cell "$task" plain)"
    read -r lt lturn lcost <<<"$(run_cell "$task" lean)"
    printf '%-10s %-6s %10s %8s %10s\n' "$task" "plain" "$pt" "$pturn" "$pcost"
    printf '%-10s %-6s %10s %8s %10s\n' "$task" "lean"  "$lt" "$lturn" "$lcost"
    tp_tok=$((tp_tok + pt)); tp_turn=$((tp_turn + pturn))
    tl_tok=$((tl_tok + lt)); tl_turn=$((tl_turn + lturn))
    r=$((r + 1))
  done
done

echo
pct=0
if [ "$tp_tok" -gt 0 ]; then pct=$(( (tp_tok - tl_tok) * 100 / tp_tok )); fi
printf 'TOTAL output tokens: plain=%d lean=%d (%d%% fewer)\n' "$tp_tok" "$tl_tok" "$pct"
printf 'TOTAL turns (round-trip proxy): plain=%d lean=%d\n' "$tp_turn" "$tl_turn"
echo "Fewer turns + fewer output tokens on edit tasks = the lever bench.sh can't"
echo "see. Noisy at low N — use -n 3+ and read totals, not single cells."
