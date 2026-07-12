#!/usr/bin/env bash
# faa-speak test suite — no model in the loop: apfel is stubbed via the APFEL
# env override, and the claude CLI is shimmed for the wrapper test.
# Bash 3.2 compatible. Run: bash test/run.sh
set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
STUB="$TEST_DIR/apfel-stub.sh"
HOOK="$ROOT/hooks/scripts/expand-output.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/faa-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 (missing: $3)" ;; esac
}
assert_empty() { # name value
  if [ -z "$2" ]; then ok "$1"; else fail "$1 (expected empty, got: ${2:0:80})"; fi
}
assert_eq() { # name actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got: ${2:0:120} | want: ${3:0:120})"; fi
}

# extra stubs
MARK_STUB="$TMP/apfel-mark"
printf '#!/usr/bin/env bash\nprintf "\xc2\xabE\xc2\xbb"; cat\n' > "$MARK_STUB"; chmod +x "$MARK_STUB"
FAIL_STUB="$TMP/apfel-fail"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAIL_STUB"; chmod +x "$FAIL_STUB"
COUNT_STUB="$TMP/apfel-count"   # replaces each chunk with «its word count»
cat > "$COUNT_STUB" <<'EOF'
#!/usr/bin/env bash
c=$(cat)
printf '\xc2\xab%s\xc2\xbb' "$(printf '%s' "$c" | wc -w | tr -d '[:space:]')"
EOF
chmod +x "$COUNT_STUB"
chunk_sizes() { # expansion output -> space-separated word counts of the chunks apfel received
  grep -o '«[0-9]*»' | tr -d '«»' | tr '\n' ' ' | sed 's/ $//'
}

run_hook() { # transcript-path [apfel] -> sets HOOK_OUT and HOOK_RC (no subshell at call site)
  local apfel="${2:-$STUB}" sdir
  sdir=$(mktemp -d "$TMP/state.XXXXXX")   # fresh dedupe state per invocation
  HOOK_OUT=$(printf '{"transcript_path":"%s"}' "$1" | FAA_STATE_DIR="$sdir" APFEL="$apfel" bash "$HOOK" 2>/dev/null)
  HOOK_RC=$?
}
record_types() { # first char of each \036-separated record
  awk 'BEGIN { RS = "\036" } length() { printf "%s", substr($0, 1, 1) }'
}
sysmsg() { printf '%s' "$1" | jq -r '.systemMessage // ""' 2>/dev/null; }

echo "=== lib: splitter classification ==="
. "$ROOT/lib/expansion.sh"

recs=$(printf 'prose here\n```js\ncode\n```\nafter\n' | faa_split_segments | record_types)
assert_eq "splitter tags prose/code/prose" "$recs" "PCP"

recs=$(printf 'list item:\n  ```js\n  indented code\n  ```\ndone\n' | faa_split_segments | record_types)
case "$recs" in *C*) ok "splitter recognizes indented fences" ;; *) fail "splitter recognizes indented fences (tags: $recs)" ;; esac

# CommonMark fence tracking: a ``` example inside a ````-fenced block is
# code, not prose — and an info-string line (```js) never closes a block.
NEST=$'prose stays before this\n````markdown\nouter doc\n```js\ninner code\n```\nmore outer\n````\nprose stays after this'
recs=$(printf '%s\n' "$NEST" | faa_split_segments | record_types)
assert_eq "splitter keeps 3-backtick fence nested in 4-backtick block as code (B3 regression)" "$recs" "PCP"
OUT=$(APFEL="$MARK_STUB" faa_expand_text "$NEST")
assert_contains "nested-fence block passes through byte-identical (B3 regression)" "$OUT" \
  $'````markdown\nouter doc\n```js\ninner code\n```\nmore outer\n````'

PURITY=$'prose stays before this\n```\ncontent line\n```js\nstill inside block\n```\nprose stays after this'
recs=$(printf '%s\n' "$PURITY" | faa_split_segments | record_types)
assert_eq "splitter: info-string line (\`\`\`js) does not close an open block" "$recs" "PCP"
OUT=$(APFEL="$MARK_STUB" faa_expand_text "$PURITY")
assert_contains "closing-fence purity: inner \`\`\`js content stays code" "$OUT" \
  $'```\ncontent line\n```js\nstill inside block\n```'

recs=$(printf 'text before here\n~~~py\ntilde code\n~~~\ntext after here\n' | faa_split_segments | record_types)
assert_eq "splitter recognizes tilde fences (B7 regression)" "$recs" "PCP"
TMIX=$'text before here\n~~~\ninner ``` fence line\nstill tilde code\n~~~\ntext after here'
recs=$(printf '%s\n' "$TMIX" | faa_split_segments | record_types)
assert_eq "backtick fence inside a tilde block stays code (fence char tracked)" "$recs" "PCP"
OUT=$(APFEL="$MARK_STUB" faa_expand_text "$TMIX")
assert_contains "tilde block passes through byte-identical" "$OUT" \
  $'~~~\ninner ``` fence line\nstill tilde code\n~~~'

# \x1e is the pipeline record separator — a stray one in model output must
# not corrupt the framing (the byte is dropped; everything else survives).
FRAME=$'prose has a stray \x1e framing byte here\n```js\ncode stays whole\n```\ntail prose is here'
OUT=$(APFEL="$STUB" faa_expand_text "$FRAME")
assert_contains "stray \\x1e byte: surrounding prose survives (B7 regression)" "$OUT" "prose has a stray  framing byte here"
assert_contains "stray \\x1e byte: code block still byte-identical" "$OUT" $'```js\ncode stays whole\n```'
assert_contains "stray \\x1e byte: trailing prose survives" "$OUT" "tail prose is here"

echo "=== lib: expansion pipeline (stub = cat) ==="
export APFEL="$STUB"
IN=$'DX: issue | cause | fix\nsecond prose line with several more words here\nsee `cfg/db_pool.toml` and rerun `make db-init` after\n\n```bash\ncode line one\ncode line two\n```\ntrailing prose after code block here'
OUT=$(faa_expand_text "$IN")
assert_contains "multi-line prose: first line survives"  "$OUT" "DX: issue | cause | fix"
assert_contains "multi-line prose: second line survives" "$OUT" "second prose line with several more words here"
assert_contains "inline code spans survive the pipeline (H10 regression)" "$OUT" 'see `cfg/db_pool.toml` and rerun `make db-init` after'
assert_contains "prose after code block survives"        "$OUT" "trailing prose after code block here"
CODE_ACTUAL=$(printf '%s\n' "$OUT" | awk '/^[ \t]*```/{print; f=!f; next} f{print}')
CODE_EXPECT=$'```bash\ncode line one\ncode line two\n```'
assert_eq "code block byte-identical" "$CODE_ACTUAL" "$CODE_EXPECT"

OUT=$(APFEL="$MARK_STUB" faa_expand_text "tiny msg")
assert_eq "<=3-word prose skips apfel" "$OUT" "tiny msg"

# The hard cap must bound every chunk even when a whole paragraph arrives as
# ONE line (markdown paragraphs usually do) — and the trailing newline must
# never become a whitespace-only apfel call (hallucination-splice hazard).
LONG=""
i=0
while [ $i -lt 520 ]; do LONG="${LONG}word$i "; i=$((i + 1)); done
SIZES=$(APFEL="$COUNT_STUB" faa_expand_text "$LONG" | chunk_sizes)
assert_eq "single-line 520-word wall: capped chunks, no empty chunk (B1/B2 regression)" "$SIZES" "450 70"

LONG=""
i=0
while [ $i -lt 2000 ]; do LONG="${LONG}word$i "; i=$((i + 1)); done
SIZES=$(APFEL="$COUNT_STUB" faa_expand_text "$LONG" | chunk_sizes)
assert_eq "single-line 2000-word wall: every chunk <=450 words (B1 regression)" "$SIZES" "450 450 450 450 200"

LONG2=""
i=0
while [ $i -lt 520 ]; do LONG2="${LONG2}word$i "; i=$((i + 1)); [ $((i % 10)) -eq 0 ] && LONG2="${LONG2}"$'\n'; done
SIZES=$(APFEL="$COUNT_STUB" faa_expand_text "$LONG2" | chunk_sizes)
assert_eq "multi-line 520-word wall: line-accumulated chunks stay capped" "$SIZES" "450 70"

OUT=$(APFEL="$FAIL_STUB" faa_expand_text "apfel died mid run but text must survive fully")
assert_contains "apfel failure falls back to original text" "$OUT" "apfel died mid run but text must survive fully"

echo "=== lib: expansion deadline (P7 — partial result instead of timeout loss) ==="
DFLAG="$TMP/deadline-flag"
rm -f "$DFLAG"
OUT=$(FAA_DEADLINE=0 FAA_DEADLINE_FLAG="$DFLAG" APFEL="$MARK_STUB" faa_expand_text "deadline passthrough text must survive fully intact")
assert_contains "deadline: text passes through compressed, not lost" "$OUT" "deadline passthrough text must survive fully intact"
case "$OUT" in *"«E»"*) fail "deadline: apfel is not invoked past the deadline" ;; *) ok "deadline: apfel is not invoked past the deadline" ;; esac
if [ -s "$DFLAG" ]; then ok "deadline: flag file records the cutoff"; else fail "deadline: flag file records the cutoff"; fi

SAVINGS=$(faa_savings_line "short" "much longer expanded text here")
assert_contains "savings line reports word/char counts" "$SAVINGS" "words / 5 chars compressed"
assert_contains "savings line reports percent shorter" "$SAVINGS" "% shorter)"
SAVINGS=$(faa_savings_line "text" "")
assert_contains "savings line guards divide-by-zero on empty expansion" "$SAVINGS" "~0% shorter"

echo "=== hook: end to end (fixtures) ==="
run_hook "$TEST_DIR/fixtures/single-line.jsonl"
assert_eq "single-line: exit 0" "$HOOK_RC" "0"
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "single-line: systemMessage delivered" "$MSG" "auth mw reject valid tokens"
assert_contains "single-line: marker stripped" "x${MSG}x" "token_validator.rs:47"
case "$MSG" in *'<!-- faa -->'*) fail "single-line: marker stripped from output" ;; *) ok "single-line: marker not echoed back" ;; esac

run_hook "$TEST_DIR/fixtures/multiline-code.jsonl"
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "multiline: second prose line survives (C1 regression)" "$MSG" "second prose line with several more words here"
assert_contains "multiline: inline code span survives (H10 regression)" "$MSG" 'see `cfg/db_pool.toml` and rerun `make db-init` after'
assert_contains "multiline: trailing prose survives"                    "$MSG" "trailing prose after code block here"
CODE_ACTUAL=$(printf '%s\n' "$MSG" | awk '/^[ \t]*```/{print; f=!f; next} f{print}')
assert_eq "multiline: code block byte-identical (C1 regression)" "$CODE_ACTUAL" $'```bash\ncode line one\ncode line two\n```'

run_hook "$TEST_DIR/fixtures/no-marker.jsonl"
assert_eq "no-marker: exit 0" "$HOOK_RC" "0"
assert_empty "no-marker: no output" "$HOOK_OUT"

run_hook "$TEST_DIR/fixtures/mid-marker.jsonl"
assert_eq "mid-marker: exit 0" "$HOOK_RC" "0"
assert_empty "mid-marker: quoting the marker mid-text does not trigger expansion (M3 regression)" "$HOOK_OUT"

HOOK_OUT=$(printf '{"transcript_path":"%s"}' "$TEST_DIR/fixtures/single-line.jsonl" | FAA_STATE_DIR="$(mktemp -d "$TMP/state.XXXXXX")" FAA_SHOW_SAVINGS=1 APFEL="$STUB" bash "$HOOK" 2>/dev/null)
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "FAA_SHOW_SAVINGS=1: savings line appended to systemMessage" "$MSG" "faa-speak savings:"
HOOK_OUT=$(printf '{"transcript_path":"%s"}' "$TEST_DIR/fixtures/single-line.jsonl" | FAA_STATE_DIR="$(mktemp -d "$TMP/state.XXXXXX")" APFEL="$STUB" bash "$HOOK" 2>/dev/null)
MSG=$(sysmsg "$HOOK_OUT")
case "$MSG" in *'faa-speak savings:'*) fail "savings line hidden by default" ;; *) ok "savings line hidden by default" ;; esac

echo "=== hook: last_assistant_message (Stop/transcript race fix) ==="
IMSG=$'DX: fresh from hook input | direct source | no file race\nsecond line survives here as well\n\n<!-- faa -->'
HOOK_OUT=$(jq -n --arg m "$IMSG" '{last_assistant_message: $m}' | FAA_STATE_DIR="$(mktemp -d "$TMP/state.XXXXXX")" APFEL="$STUB" bash "$HOOK" 2>/dev/null)
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "hook-input message: expansion delivered with no transcript at all" "$MSG" "fresh from hook input"
assert_contains "hook-input message: multi-line text survives" "$MSG" "second line survives here as well"

HOOK_OUT=$(jq -n --arg m "$IMSG" --arg t "$TEST_DIR/fixtures/single-line.jsonl" '{last_assistant_message: $m, transcript_path: $t}' | FAA_STATE_DIR="$(mktemp -d "$TMP/state.XXXXXX")" APFEL="$STUB" bash "$HOOK" 2>/dev/null)
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "hook-input message takes precedence over the (laggy) transcript" "$MSG" "fresh from hook input"
case "$MSG" in *"auth mw reject"*) fail "hook-input precedence: stale transcript text leaked" ;; *) ok "hook-input precedence: stale transcript text not consulted" ;; esac

HOOK_OUT=$(jq -n '{last_assistant_message: "plain response with no marker"}' | FAA_STATE_DIR="$(mktemp -d "$TMP/state.XXXXXX")" APFEL="$STUB" bash "$HOOK" 2>/dev/null)
assert_empty "hook-input message without end marker: silent no-op" "$HOOK_OUT"

SDIR=$(mktemp -d "$TMP/state.XXXXXX")
OUT1=$(printf '{"transcript_path":"%s","session_id":"dedupe-test"}' "$TEST_DIR/fixtures/single-line.jsonl" | FAA_STATE_DIR="$SDIR" APFEL="$STUB" bash "$HOOK" 2>/dev/null)
OUT2=$(printf '{"transcript_path":"%s","session_id":"dedupe-test"}' "$TEST_DIR/fixtures/single-line.jsonl" | FAA_STATE_DIR="$SDIR" APFEL="$STUB" bash "$HOOK" 2>/dev/null)
case "$OUT1" in *systemMessage*) ok "fallback dedupe: first stop expands" ;; *) fail "fallback dedupe: first stop expands" ;; esac
assert_empty "fallback dedupe: lagging transcript can never re-show the same text" "$OUT2"

echo "=== hook: fallback staleness guard (resumed sessions) ==="
jq -c '. + {timestamp: "2020-01-01T00:00:00.000Z"}' "$TEST_DIR/fixtures/single-line.jsonl" > "$TMP/stale.jsonl"
run_hook "$TMP/stale.jsonl"
assert_eq "stale transcript: exit 0" "$HOOK_RC" "0"
assert_empty "stale transcript: prior-session history is never re-expanded" "$HOOK_OUT"

jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '. + {timestamp: $ts}' "$TEST_DIR/fixtures/single-line.jsonl" > "$TMP/fresh.jsonl"
run_hook "$TMP/fresh.jsonl"
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "fresh transcript: current-exchange text still expands" "$MSG" "auth mw reject valid tokens"

echo "=== hook: apfel failure is announced, not impersonated ==="
HOOK_OUT=$(printf '{"transcript_path":"%s"}' "$TEST_DIR/fixtures/single-line.jsonl" | FAA_STATE_DIR="$(mktemp -d "$TMP/state.XXXXXX")" FAA_SHOW_SAVINGS=1 APFEL="$FAIL_STUB" bash "$HOOK" 2>/dev/null)
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "total apfel failure: warning delivered instead of fake expansion" "$MSG" "apfel could not expand"
assert_contains "total apfel failure: diagnostic hint included" "$MSG" "apfel --model-info"
case "$MSG" in *'faa-speak savings:'*) fail "total apfel failure: bogus 0% savings line suppressed" ;; *) ok "total apfel failure: bogus 0% savings line suppressed" ;; esac

REASON_STUB="$TMP/apfel-reason"
printf '#!/usr/bin/env bash\necho "error: Model unavailable (Apple Intelligence not enabled)" >&2\nexit 5\n' > "$REASON_STUB"; chmod +x "$REASON_STUB"
HOOK_OUT=$(printf '{"transcript_path":"%s"}' "$TEST_DIR/fixtures/single-line.jsonl" | FAA_STATE_DIR="$(mktemp -d "$TMP/state.XXXXXX")" APFEL="$REASON_STUB" bash "$HOOK" 2>/dev/null)
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "total apfel failure: apfel's own error reason surfaced" "$MSG" "Apple Intelligence not enabled"

echo "=== hook: expansion deadline (P7) ==="
HOOK_OUT=$(printf '{"transcript_path":"%s"}' "$TEST_DIR/fixtures/single-line.jsonl" | FAA_STATE_DIR="$(mktemp -d "$TMP/state.XXXXXX")" FAA_DEADLINE=0 APFEL="$STUB" bash "$HOOK" 2>/dev/null)
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "hook deadline: time-budget notice appended" "$MSG" "time budget"
assert_contains "hook deadline: compressed text still delivered" "$MSG" "auth mw reject valid tokens"
run_hook "$TEST_DIR/fixtures/single-line.jsonl"
MSG=$(sysmsg "$HOOK_OUT")
case "$MSG" in *"time budget"*) fail "hook deadline: no notice when expansion finishes in time" ;; *) ok "hook deadline: no notice when expansion finishes in time" ;; esac

echo "=== hook: scratch-file hygiene (B7) ==="
SDIR=$(mktemp -d "$TMP/state.XXXXXX")
printf '{"transcript_path":"%s"}' "$TEST_DIR/fixtures/single-line.jsonl" | FAA_STATE_DIR="$SDIR" APFEL="$FAIL_STUB" bash "$HOOK" >/dev/null 2>&1
LEFT=$(find "$SDIR" \( -name 'faa-fellback-*' -o -name 'faa-apfel-err-*' \) -type f 2>/dev/null | grep -c . || true)
assert_eq "hook removes its scratch files on exit (B7 regression)" "$LEFT" "0"

SDIR=$(mktemp -d "$TMP/state.XXXXXX")
touch "$SDIR/faa-last-deadsession" "$SDIR/faa-fellback-99999"
touch -t 202001010000 "$SDIR/faa-last-deadsession" "$SDIR/faa-fellback-99999"
printf '{"transcript_path":"%s"}' "$TEST_DIR/fixtures/single-line.jsonl" | FAA_STATE_DIR="$SDIR" APFEL="$STUB" bash "$HOOK" >/dev/null 2>&1
if [ ! -e "$SDIR/faa-last-deadsession" ] && [ ! -e "$SDIR/faa-fellback-99999" ]; then
  ok "hook purges week-old state/scratch from dead sessions (B7 regression)"
else
  fail "hook purges week-old state/scratch from dead sessions"
fi

echo "=== hook: oversized expansion (systemMessage cap) ==="
BIG=""
i=0
while [ $i -lt 400 ]; do BIG="${BIG}filler line $i with several padding words to overflow the cap"$'\n'; i=$((i + 1)); done
BIG="$BIG"$'\n<!-- faa -->'
HOOK_OUT=$(jq -n --arg m "$BIG" '{last_assistant_message: $m}' | FAA_STATE_DIR="$(mktemp -d "$TMP/state.XXXXXX")" APFEL="$STUB" bash "$HOOK" 2>/dev/null)
MSG=$(sysmsg "$HOOK_OUT")
assert_contains "oversized expansion: truncation notice is honest about --debug (B6 regression)" "$MSG" 'claude --debug'
if [ ${#MSG} -le 9700 ]; then ok "oversized expansion: systemMessage capped at ~9.5k chars"; else fail "oversized expansion: systemMessage capped (got ${#MSG} chars)"; fi

run_hook "$TMP/definitely-missing.jsonl"
assert_eq "missing transcript: exit 0" "$HOOK_RC" "0"
assert_empty "missing transcript: no output" "$HOOK_OUT"

OUT=$(printf 'this is not json' | APFEL="$STUB" bash "$HOOK" 2>/dev/null); HOOK_RC=$?
assert_eq "garbage stdin: exit 0" "$HOOK_RC" "0"
assert_empty "garbage stdin: no output" "$OUT"

if [ "$(id -u)" != "0" ]; then
  cp "$TEST_DIR/fixtures/single-line.jsonl" "$TMP/unreadable.jsonl"
  chmod 000 "$TMP/unreadable.jsonl"
  run_hook "$TMP/unreadable.jsonl"
  assert_eq "unreadable transcript: exit 0, never exit 2 (H9 regression)" "$HOOK_RC" "0"
  assert_empty "unreadable transcript: no output" "$HOOK_OUT"
  chmod 644 "$TMP/unreadable.jsonl"
fi

echo "=== wrapper: end to end (claude shimmed) ==="
SHIM_ARGS="$TMP/claude-args"
cat > "$TMP/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$SHIM_ARGS"
printf 'DX: wrapped q | shim answered | ok\nmore prose from the shim here\n\n\`\`\`py\nprint(1)\nprint(2)\n\`\`\`\n\n<!-- faa -->\n'
EOF
chmod +x "$TMP/claude"
OUT=$(PATH="$TMP:$PATH" APFEL="$STUB" bash "$ROOT/scripts/faa-wrap.sh" "test question" 2>/dev/null); RC=$?
assert_eq "wrapper: exit 0" "$RC" "0"
ARGS=$(cat "$SHIM_ARGS" 2>/dev/null || true)
assert_contains "wrapper: loads plugin via --plugin-dir" "$ARGS" "--plugin-dir"
assert_contains "wrapper: invokes the skill explicitly (H2 regression)" "$ARGS" "/faa-speak test question"
assert_contains "wrapper: prose expanded" "$OUT" "more prose from the shim here"
CODE_ACTUAL=$(printf '%s\n' "$OUT" | awk '/^[ \t]*```/{print; f=!f; next} f{print}')
assert_eq "wrapper: code block byte-identical (H3 regression)" "$CODE_ACTUAL" $'```py\nprint(1)\nprint(2)\n```'

ERR=$(PATH="$TMP:$PATH" APFEL="$STUB" FAA_SHOW_SAVINGS=1 bash "$ROOT/scripts/faa-wrap.sh" "test question" 2>&1 >/dev/null)
assert_contains "wrapper: FAA_SHOW_SAVINGS=1 reports savings on stderr" "$ERR" "faa-speak savings:"

# Same marker contract as the hook (M3): a reply that merely QUOTES the
# marker mid-text is not expanded, and the quoted marker is not deleted.
mkdir -p "$TMP/shim-midmarker"
cat > "$TMP/shim-midmarker/claude" <<'EOF'
#!/usr/bin/env bash
printf 'The plugin appends a marker that looks like <!-- faa --> to responses.\nThis reply merely quotes it mid-text and has no trailing marker.\n'
EOF
chmod +x "$TMP/shim-midmarker/claude"
OUT=$(PATH="$TMP/shim-midmarker:$PATH" APFEL="$MARK_STUB" bash "$ROOT/scripts/faa-wrap.sh" "test question" 2>/dev/null); RC=$?
assert_eq "wrapper: mid-text marker exit 0" "$RC" "0"
case "$OUT" in *"«E»"*) fail "wrapper: quoting the marker mid-text does not trigger expansion (B4 regression)" ;; *) ok "wrapper: quoting the marker mid-text does not trigger expansion (B4 regression)" ;; esac
assert_contains "wrapper: quoted marker survives verbatim (B4 regression)" "$OUT" 'looks like <!-- faa --> to responses'

# Same failure honesty as the hook: apfel fallbacks are announced, not silent.
ERR=$(PATH="$TMP:$PATH" APFEL="$FAIL_STUB" bash "$ROOT/scripts/faa-wrap.sh" "test question" 2>&1 >/dev/null)
assert_contains "wrapper announces apfel fallback on stderr (B7 regression)" "$ERR" "could not be expanded"
OUT=$(PATH="$TMP:$PATH" APFEL="$FAIL_STUB" bash "$ROOT/scripts/faa-wrap.sh" "test question" 2>/dev/null)
assert_contains "wrapper fallback still delivers the compressed text" "$OUT" "more prose from the shim here"

echo "=== manifest ==="
if jq -e '.author | type == "object"' "$ROOT/.claude-plugin/plugin.json" >/dev/null 2>&1; then
  ok "plugin.json author is an object (C0 regression)"
else
  fail "plugin.json author is an object (C0 regression)"
fi
if jq -e '.name and .version and .license' "$ROOT/.claude-plugin/plugin.json" >/dev/null 2>&1; then
  ok "plugin.json has name/version/license"
else
  fail "plugin.json has name/version/license"
fi

echo "=== dictionary drift (lib is canonical; SKILL.md/README tables must match) ==="
# shellcheck disable=SC2086  # word-splitting FAA_DICT into entries is the point
dict_sorted() { printf '%s\n' $FAA_DICT | sort; }
table_entries() { # file
  awk -F'|' '/^\| [a-z]/ {
    gsub(/ /, "", $2); gsub(/^ +| +$/, "", $3)
    gsub(/ /, "", $5); gsub(/^ +| +$/, "", $6)
    if ($2 != "") print $2 "=" $3
    if ($5 != "") print $5 "=" $6
  }' "$1" | sort
}
if [ "$(table_entries "$ROOT/skills/faa-speak/SKILL.md")" = "$(dict_sorted)" ]; then
  ok "SKILL.md table matches lib dictionary"
else
  fail "SKILL.md table drifted from lib dictionary (M1 regression)"
  diff <(table_entries "$ROOT/skills/faa-speak/SKILL.md") <(dict_sorted) | head -8
fi
if [ "$(table_entries "$ROOT/README.md")" = "$(dict_sorted)" ]; then
  ok "README.md table matches lib dictionary"
else
  fail "README.md table drifted from lib dictionary (M1 regression)"
  diff <(table_entries "$ROOT/README.md") <(dict_sorted) | head -8
fi
if grep -c 'cmp=component' "$ROOT/lib/expansion.sh" | grep -qx '1'; then
  ok "no duplicate dictionary entries in lib"
else
  fail "duplicate cmp=component in lib"
fi

echo "=== bench: no-dictionary A/B variant (issue #10) ==="
NODICT="$ROOT/bench/nodict-plugin"
if jq -e '(.author | type) == "object" and .name == "faa-speak-nodict"' "$NODICT/.claude-plugin/plugin.json" >/dev/null 2>&1; then
  ok "nodict variant manifest structurally valid"
else
  fail "nodict variant manifest structurally valid"
fi
NODSKILL="$NODICT/skills/faa-speak-nodict/SKILL.md"
if [ -f "$NODSKILL" ]; then ok "nodict variant skill exists"; else fail "nodict variant skill exists"; fi
rows=$(grep -cE '^\| [a-z]+ +\| [a-z]' "$NODSKILL" 2>/dev/null || true)
assert_eq "nodict variant carries no abbreviation table (the A/B's whole point)" "${rows:-0}" "0"
if grep -q 'write every word in full' "$NODSKILL"; then
  ok "nodict variant forbids spontaneous abbreviation"
else
  fail "nodict variant forbids spontaneous abbreviation"
fi
if grep -qF '<!-- faa -->' "$NODSKILL"; then ok "nodict variant keeps the marker contract"; else fail "nodict variant keeps the marker contract"; fi
MEAS="$ROOT/bench/measured-plugin"
if jq -e '(.author | type) == "object" and .name == "faa-speak-measured"' "$MEAS/.claude-plugin/plugin.json" >/dev/null 2>&1; then
  ok "measured variant manifest structurally valid"
else
  fail "measured variant manifest structurally valid"
fi
MEASSKILL="$MEAS/skills/faa-speak-measured/SKILL.md"
if grep -qF '<!-- faa -->' "$MEASSKILL" 2>/dev/null; then ok "measured variant keeps the marker contract"; else fail "measured variant keeps the marker contract"; fi
meas_entries=$(awk -F'|' '/^\| [A-Za-z]/ && $2 !~ /Short|Prefix|Abbr/ { c += ($2 ~ /[A-Za-z]/) + ($5 ~ /[A-Za-z]/) } END { print c + 0 }' "$MEASSKILL")
assert_eq "measured variant (v4 additive) carries legacy 40 + measured 34, deduped (async overlaps)" "$meas_entries" "73"

echo "=== bench: tableless controlled arm (P3 — table-only isolation) ==="
TABLELESS="$ROOT/bench/tableless-plugin"
if jq -e '(.author | type) == "object" and .name == "faa-speak-tableless"' "$TABLELESS/.claude-plugin/plugin.json" >/dev/null 2>&1; then
  ok "tableless variant manifest structurally valid"
else
  fail "tableless variant manifest structurally valid"
fi
TLSKILL="$TABLELESS/skills/faa-speak-tableless/SKILL.md"
if grep -qF '<!-- faa -->' "$TLSKILL" 2>/dev/null; then ok "tableless variant keeps the marker contract"; else fail "tableless variant keeps the marker contract"; fi
# The controlled-arm guarantee: the body must be EXACTLY the shipped skill
# with only the abbreviation table removed (and the sentence that references
# it). Regenerate the expected body from the shipped skill and compare — if
# the shipped skill changes without this variant, the A/B silently stops
# isolating the table and this fails.
strip_fm() { awk 'BEGIN { fm = 0 } /^---$/ && fm < 2 { fm++; next } fm < 2 { next } { print }' "$1"; }
tableless_expected() {
  awk 'BEGIN { fm = 0 } /^---$/ && fm < 2 { fm++; next } fm < 2 { next } /^## Abbreviations$/ { skip = 1; next } /^## / { skip = 0 } !skip { print }' \
    "$ROOT/skills/faa-speak/SKILL.md" | sed 's/ from table below\./\./'
}
if [ "$(tableless_expected)" = "$(strip_fm "$TLSKILL")" ]; then
  ok "tableless variant differs from shipped skill by the table ONLY (controlled-arm drift test)"
else
  fail "tableless variant differs from shipped skill by the table ONLY (controlled-arm drift test)"
  diff <(tableless_expected) <(strip_fm "$TLSKILL") | head -8
fi

echo "=== tier-1 tooling: bench flags, addressable measure, fidelity harness ==="
mkdir -p "$TMP/shim-bench"
cat > "$TMP/shim-bench/claude" <<'EOF'
#!/usr/bin/env bash
printf '{"usage":{"output_tokens":100}}\n'
EOF
chmod +x "$TMP/shim-bench/claude"
BOUT=$(PATH="$TMP/shim-bench:$PATH" bash "$ROOT/scripts/bench.sh" --runs 2 --concise "sample question" 2>/dev/null); BRC=$?
assert_eq "bench --runs: exit 0 (claude shimmed)" "$BRC" "0"
assert_contains "bench --runs: multi-run summary with spread" "$BOUT" "SUMMARY over 2 runs"
assert_contains "bench --concise: readable-baseline arm reported" "$BOUT" "concise:"

mkdir -p "$TMP/addr"
cat > "$TMP/addr/t.jsonl" <<'EOF'
{"message":{"role":"assistant","id":"m1","usage":{"output_tokens":100},"content":[{"type":"text","text":"prose words here\n```\ncode here\n```"}]}}
{"message":{"role":"assistant","id":"m1","usage":{"output_tokens":100},"content":[{"type":"tool_use","input":{"cmd":"12345678901234567890"}}]}}
EOF
AOUT=$(bash "$ROOT/scripts/measure-addressable.sh" "$TMP/addr" 2>/dev/null); ARC=$?
assert_eq "measure-addressable: exit 0" "$ARC" "0"
assert_contains "measure-addressable: usage deduped across blocks of one message" "$AOUT" "billed output tokens (usage, deduped): 100"
assert_contains "measure-addressable: reports the NET savings projection" "$AOUT" "NET savings"

FOUT=$(APFEL="$ROOT/test/fidelity/ref-expander.sh" bash "$ROOT/test/fidelity/run.sh" 2>/dev/null); FRC=$?
assert_eq "fidelity harness: all pairs pass under the reference expander" "$FRC" "0"
assert_contains "fidelity harness: 8 golden pairs run" "$FOUT" "8 passed, 0 failed"
FOUT=$(APFEL="$FAIL_STUB" bash "$ROOT/test/fidelity/run.sh" 2>/dev/null); FRC=$?
assert_eq "fidelity harness: unusable expander skips with exit 0" "$FRC" "0"
assert_contains "fidelity harness: skip explains itself" "$FOUT" "SKIP"
if bash -n "$ROOT/scripts/bench.sh" 2>/dev/null; then ok "bench.sh parses"; else fail "bench.sh parses"; fi
if bash -n "$ROOT/scripts/mine-dict.sh" 2>/dev/null; then ok "mine-dict.sh parses"; else fail "mine-dict.sh parses"; fi
if bash -n "$ROOT/scripts/verify-deltas.sh" 2>/dev/null; then ok "verify-deltas.sh parses"; else fail "verify-deltas.sh parses"; fi
mkdir -p "$TMP/mine"
printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"the kubernetes deployment rollout needs a readiness probe and the connection pool exhausts quickly\n```bash\nignore_this_code_token\n```\n"}]}}' > "$TMP/mine/mine-fixture.jsonl"
MINED=$(TOP=5 MINCOUNT=1 MINLEN=5 bash "$ROOT/scripts/mine-dict.sh" "$TMP/mine" 2>/dev/null)
assert_contains "mine-dict finds unigram candidates" "$MINED" "kubernetes"
assert_contains "mine-dict finds bigram phrases" "$MINED" "connection pool"
case "$MINED" in *ignore_this_code_token*) fail "mine-dict strips code blocks" ;; *) ok "mine-dict strips code blocks" ;; esac

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
