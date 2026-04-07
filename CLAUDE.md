# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Claude Code plugin with two components:
1. **SKILL.md** (`skills/faa-speak/SKILL.md`) — system prompt that makes Claude respond in FAA-inspired compressed format (~40 abbreviations, structural prefixes, telegraphic style)
2. **Stop hook** (`hooks/scripts/expand-output.sh`) — extracts compressed output from the JSONL transcript, pipes prose through `apfel` (Apple's on-device LLM) for expansion, prints readable English to stderr

The `<!-- faa -->` HTML comment at the end of compressed responses is the machine-readable marker that triggers expansion. Without it, the hook no-ops.

## Architecture

```
SKILL.md controls Claude's output format
    → Claude emits compressed text + <!-- faa --> marker
    → hooks.json wires Stop event to expand-output.sh
    → expand-output.sh reads transcript JSONL, extracts last assistant text
    → awk splits into CODE/PROSE segments (code blocks pass through unchanged)
    → prose chunks piped through: apfel -s "$EXPANSION_PROMPT"
    → expanded text printed to stderr
```

The hook follows the same pattern as the `ralph-loop` plugin's stop hook: reads JSON from stdin (contains `transcript_path`, `session_id`), extracts assistant text via `jq`, outputs nothing to stdout (exit 0 = allow stop).

## Key Design Constraints

- **apfel has a 4096-token context window** (input + output combined). The expansion system prompt uses ~150 tokens. Prose chunks must stay under ~500 words to leave room for expanded output.
- **Code blocks are never compressed or expanded.** The awk splitter tags segments as `CODE:` or `PROSE:` — only prose goes through apfel.
- **Auto-clarity exceptions**: SKILL.md instructs Claude to drop compression for security warnings, irreversible operations, and ambiguous multi-step sequences.
- The expansion prompt and abbreviation dictionary are duplicated in three places: `SKILL.md`, `expand-output.sh`, and `faa-wrap.sh`. Keep them in sync when modifying abbreviations.

## Testing

No automated test suite. Manual verification:

```bash
# Test plugin loads
claude --plugin-dir .

# Test compression (need to trigger /faa-speak first in session)
claude --print --plugin-dir . "explain database connection pooling"

# Test expansion standalone (requires apfel built)
echo 'DX: auth mw reject valid tokens | expiry chk uses < not <= | fix: change to <= in token_validator.rs:47' | apfel -s "Expand abbreviated technical text to clear English..."

# Test wrapper script
./scripts/faa-wrap.sh "explain database connection pooling"
```

## Prerequisites

- macOS 26+ with Apple Intelligence
- `apfel` binary: either in PATH or at `~/git/apfel/.build/release/apfel`
- `jq` for transcript parsing in the hook
