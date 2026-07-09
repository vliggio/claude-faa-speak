# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Claude Code plugin with three maintained components plus a shared library:
1. **SKILL.md** (`skills/faa-speak/SKILL.md`) — system prompt that makes Claude respond in FAA-inspired compressed format (40 abbreviations, structural prefixes, telegraphic style)
2. **Stop hook** (`hooks/scripts/expand-output.sh`) — extracts compressed output from the transcript JSONL, expands prose through `apfel` (Apple's on-device foundation model), and shows readable English to the user via a `systemMessage` on stdout
3. **Wrapper** (`scripts/faa-wrap.sh`) — non-interactive path: runs `claude --print --plugin-dir <root> "/faa-speak <question>"` and expands the reply to stdout
4. **Shared lib** (`lib/expansion.sh`) — the single source of truth for the abbreviation dictionary, expansion prompt, apfel discovery, and the split/expand pipeline; both scripts source it

The `<!-- faa -->` marker **at the end of the response** triggers expansion. A marker quoted mid-text does not (the hook checks the text suffix).

## Architecture

```
SKILL.md controls Claude's output format
    → Claude emits compressed text + trailing <!-- faa --> marker
    → hooks.json wires Stop event to expand-output.sh (timeout: 30s)
    → hook: cheap marker pre-check (tail of transcript) → extract last assistant text via jq
    → lib: awk splits into \x1e-separated typed records (C=code, P=prose)
    → prose records piped through: apfel -s "$EXPANSION_PROMPT"; code records byte-identical
    → each segment streams to stderr as produced (partials survive a timeout kill)
    → full expansion delivered as {"systemMessage": ...} on stdout, exit 0
```

## Key Design Constraints

- **The hook must never block the stop.** `trap 'exit 0' EXIT` guarantees exit 0 on every path — a Stop hook exiting 2 would block Claude from stopping. All failures degrade to a silent no-op; set `FAA_DEBUG=1` to see the reason on stderr.
- **apfel has a 4096-token context window** (input + output). Prose is chunked at blank lines past 300 words with a hard flush at 450 words, so a blank-line-free wall of text can never exceed the window.
- **Code blocks are never expanded.** The splitter passes fenced blocks (including indented fences) through byte-identical — `test/run.sh` asserts this.
- **`systemMessage` is capped at 10k chars** — the hook truncates beyond ~9.5k (the full expansion always streamed to stderr).
- **Auto-clarity exceptions**: SKILL.md drops compression for security warnings, irreversible operations, ambiguous multi-step sequences, and user confusion.
- **The dictionary lives in exactly one place:** `lib/expansion.sh` (`FAA_DICT`). The tables in `SKILL.md` and `README.md` are human-facing copies; `test/run.sh` fails if either drifts. To add an abbreviation: edit `FAA_DICT`, then both tables. New entries must be measured first — the process (mine → token-delta → A/B) is in `docs/custom-dictionary.md`.

## Testing

```bash
bash test/run.sh          # full suite — apfel stubbed via APFEL env, claude shimmed; no login needed
claude plugin validate .  # manifest must pass (author must be an object, not a string)

# Live compression check (requires login; skills do NOT auto-trigger in --print):
claude --print --plugin-dir . "/faa-speak explain database connection pooling"

# Live end-to-end (requires apfel built):
./scripts/faa-wrap.sh "explain database connection pooling"

# Token-savings measurement (README carries the latest measured number):
./scripts/bench.sh
./scripts/bench.sh --ab   # + no-dictionary arm (bench/nodict-plugin) — issue #10 dictionary A/B
```

## Prerequisites

- macOS 26+ with Apple Intelligence
- `apfel` binary: `APFEL` env var, PATH, or `~/git/apfel/.build/release/apfel`
- `jq` for transcript parsing (hook silently no-ops without it)

## Gotchas

- Expansion runs for the main conversation only — `SubagentStop` is intentionally not wired.
- The transcript extraction greps for the literal `"role":"assistant"` — a Claude Code transcript-serialization change would silently disable expansion; the fixtures in `test/fixtures/` pin the assumed shape.
- Bash 3.2 (macOS default) — no `mapfile`, no associative arrays anywhere in this repo.
