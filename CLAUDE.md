# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Claude Code plugin with three maintained components plus a shared library:
1. **SKILL.md** (`skills/faa-speak/SKILL.md`) — system prompt that makes Claude respond in FAA-inspired compressed format (40 abbreviations, structural prefixes, telegraphic style)
2. **Stop hook** (`hooks/scripts/expand-output.sh`) — extracts compressed output from the transcript JSONL, expands prose through `apfel` (Apple's on-device foundation model), and shows readable English to the user via a `systemMessage` on stdout
3. **Wrapper** (`scripts/faa-wrap.sh`) — non-interactive path: runs `claude --print --plugin-dir <root> "/faa-speak <question>"` and expands the reply to stdout
4. **Shared lib** (`lib/expansion.sh`) — the single source of truth for the abbreviation dictionary, expansion prompt, apfel discovery, the marker gate (`faa_gate`), and the split/expand pipeline; both scripts source it

The `<!-- faa -->` marker **at the end of the response** triggers expansion. A marker quoted mid-text does not — the hook and the wrapper both enforce this through the shared `faa_gate` in `lib/expansion.sh`.

## Architecture

```
SKILL.md controls Claude's output format
    → Claude emits compressed text + trailing <!-- faa --> marker
    → hooks.json wires Stop event to expand-output.sh (timeout: 30s)
    → hook: reads last_assistant_message from the hook input JSON
      (transcript-file fallback + per-session dedupe for older Claude Code —
      the transcript is written async and lags the Stop event)
    → lib: awk splits into \x1e-separated typed records (C=code, P=prose)
    → prose records piped through: apfel -s "$EXPANSION_PROMPT"; code records byte-identical
    → each segment streams to stderr as produced (partials survive a timeout kill)
    → full expansion delivered as {"systemMessage": ...} on stdout, exit 0
```

## Key Design Constraints

- **The hook must never block the stop.** `trap 'exit 0' EXIT` guarantees exit 0 on every path — a Stop hook exiting 2 would block Claude from stopping. All failures degrade to a silent no-op; set `FAA_DEBUG=1` to see the reason on stderr.
- **apfel has a 4096-token context window** (input + output). Prose is chunked at blank lines past 300 words with a hard cap of 450 words per chunk; a single line past the cap (markdown paragraphs usually arrive as one line) is sliced at word boundaries, so no chunk can ever exceed the window. Whitespace-only buffers are never sent to apfel.
- **Code blocks are never expanded.** The splitter passes fenced blocks (backtick or tilde, including indented fences and nested fences per CommonMark fence-length/char rules) through byte-identical — `test/run.sh` asserts this. Indented (4-space, unfenced) code blocks are *not* recognized; SKILL.md instructs fenced output.
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
- The primary text source is `last_assistant_message` from the Stop-hook input. **Never rely on the transcript for the current turn** — it is written asynchronously and documented to lag the Stop event (we shipped that bug once). The transcript path is fallback-only, guarded by a per-session dedupe state; its `"role":"assistant"` grep is pinned by the fixtures in `test/fixtures/`.
- Bash 3.2 (macOS default) — no `mapfile`, no associative arrays anywhere in this repo.
