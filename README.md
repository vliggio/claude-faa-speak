# faa-speak

Claude Code plugin that makes Claude respond in FAA-inspired compressed format to reduce output tokens, then expands the compressed text back to readable English using Apple's on-device foundation model (via [apfel](https://github.com/vliggio/apfel)) at zero additional API cost.

## How It Works

```
You (normal English)
    → Claude API → Compressed response (fewer output tokens)
                        ↓
              Stop hook detects the <!-- faa --> marker at the end
                        ↓
              apfel expands prose locally (code blocks pass through untouched)
                        ↓
              Expanded English appears in the UI as a system message
```

1. **You write normally.** No changes to your input.
2. **Claude responds compressed** using 40 standard abbreviations, structural prefixes (`DX:` for diagnosis, `EX:` for explanation, `ARCH:` for architecture), and telegraphic style.
3. **The Stop hook fires**, extracts the compressed text, expands the prose through apfel, and shows the readable English below the response as a system message. Code blocks, fences, and their contents are never sent through the expander.

Measured savings: **~53% of output tokens** (10-prompt `scripts/bench.sh --ab` run, 2026-07-09: plain=15851 → faa=7413). The A/B's no-dictionary arm saved 45%, so telegraphic style does most of the work and the abbreviation table adds ~8 points on top (9 of 10 prompts favored it). Run the bench with your own prompts before relying on these numbers for your workload.

> **No Apple Silicon, or can't build apfel?** The compression half works on any platform — you get the full token savings either way; the hook just quietly skips the local re-expansion.
>
> **Scope notes:** expansion runs for the main conversation only (subagent output is not expanded), and the on-device expansion is best-effort — if apfel fails or is missing, you simply see the compressed text.

## Prerequisites

- **macOS 26+** with Apple Intelligence enabled
- **Xcode / Swift toolchain** (to build apfel)
- **apfel** built and available:
  ```bash
  git clone https://github.com/vliggio/apfel ~/git/apfel
  cd ~/git/apfel && swift build -c release
  # Either add the binary to PATH, set APFEL=/path/to/apfel, or leave it at
  # ~/git/apfel/.build/release/apfel (the default search location)
  ```
- **jq** installed (`brew install jq`)

## Installation

```bash
# Try it for one session (no install)
claude --plugin-dir /path/to/claude-faa-speak

# Install permanently via the bundled marketplace
claude plugin marketplace add vliggio/claude-faa-speak
claude plugin install faa-speak@faa-speak
```

Verify the plugin loads: `claude plugin validate /path/to/claude-faa-speak`.

## Usage

### Interactive (Claude Code)

Activate with any of:
- `/faa-speak`
- "faa mode"
- "tower mode"
- "compressed mode"

Deactivate with:
- "stop faa"
- "normal mode"

Compression persists only as long as the model keeps honoring the skill — if a response arrives without the trailing `<!-- faa -->` marker, that response is simply not expanded.

### Non-interactive (claude --print)

```bash
./scripts/faa-wrap.sh "explain database connection pooling"
```

The wrapper loads the plugin with `--plugin-dir` and invokes `/faa-speak` explicitly (skills do not auto-trigger in `--print` mode), then expands the reply and prints readable English to stdout.

### Environment variables

| Variable | Effect |
|----------|--------|
| `APFEL=/path/to/apfel` | Override apfel discovery (also how the test suite stubs it) |
| `FAA_DEBUG=1` | Hook logs the reason for any no-op to stderr (visible with `claude --debug`) |
| `FAA_SHOW_COMPRESSED=1` | Wrapper prints the raw compressed reply before the expansion |

## Compression Examples

**Error diagnosis (compressed):**
```
DX: auth mw reject valid tokens | expiry chk uses < not <= | fix: change to <= in token_validator.rs:47
```

**What the expansion shows you:**
> Diagnosis: the authentication middleware rejects valid tokens. The expiry check uses a strict less-than comparison instead of less-than-or-equal. Fix: change it to `<=` in `token_validator.rs:47`.

**Code explanation:**
```
EX: fn filter active users → extract emails | need clean mailing list from user db | filter where active=true, map to .email, ret str arr
```

**Architecture advice:**
```
ARCH: db conn pooling | more mem vs reduced latency | rec for high-load srv, skip for low-traffic
```

## Abbreviation Reference

The canonical dictionary lives in `lib/expansion.sh`; this table and the one in `skills/faa-speak/SKILL.md` are checked against it by `test/run.sh`. The stock entries are generic — the next section shows how to build a set measured against your own usage.

| Abbr | Meaning | | Abbr | Meaning |
|------|---------|---|------|---------|
| fn | function | | env | environment |
| ret | return | | srv | server |
| impl | implementation | | param | parameter |
| cfg | configuration | | arg | argument |
| db | database | | val | value |
| auth | authentication | | var | variable |
| req | request | | obj | object |
| res | response | | arr | array |
| err | error | | str | string |
| dep | dependency | | int | integer |
| pkg | package | | bool | boolean |
| idx | index | | iter | iteration |
| init | initialize | | tpl | template |
| del | delete | | cmp | component |
| upd | update | | rdr | render |
| chk | check | | cb | callback |
| vld | validate | | evnt | event |
| msg | message | | sig | signal |
| hdr | header | | async | asynchronous |
| endpt | endpoint | | mw | middleware |

## Building a Custom Dictionary

The stock table is generic; your workload's vocabulary is not. Two things are measured about it (details in [docs/custom-dictionary.md](docs/custom-dictionary.md)): most stock entries save ~0 tokens per occurrence, **and yet** removing them costs ~30 points of savings across six A/B runs — the table's real job is *style priming*, not glyph substitution. So the stock entries stay, additions are welcome, and both are gated by measurement, not intuition:

**1. Mine candidates from your own transcripts.** Assistant text only; code, URLs, stopwords, and already-covered terms are stripped — the output is vocabulary and counts, never conversation content:

```bash
scripts/mine-dict.sh ~/.claude/projects/<project-dir>   # scope to real work
TOP=60 MINCOUNT=10 scripts/mine-dict.sh                  # tuning knobs
```

Scope matters: agent-heavy sessions flood the ranking with their own vocabulary, and rows with suspiciously identical counts are one repeated artifact, not usage. Prefer the bigram/trigram phrase candidates (`environment variable → env var`) — phrases save more tokens per substitution than single words.

**2. Verify each candidate's token delta.** Most short common words are already a single token, so abbreviating them saves nothing — and some abbreviations cost *more* (`evnt` tokenizes worse than `event`). A candidate earns a slot only if `tokens(full) − tokens(abbrev) ≥ 1`, measured with the `count_tokens` API; expected value ≈ corpus frequency × token delta.

**3. Pick safe abbreviations.** Unambiguous, exactly one expansion each, no collisions with existing entries or with strings that appear as real identifiers in code (`ctx`, `txn`) — those are expansion-fidelity hazards.

**4. A/B before shipping.** Copy `bench/nodict-plugin` to `bench/extdict-plugin`, add your rows to its skill table, and compare plain / current / candidate in one command:

```bash
VARIANT_ROOT="$PWD/bench/extdict-plugin" VARIANT_SKILL=faa-speak-extdict \
  scripts/bench.sh --ab
```

Repeat a few times — ship only if the variant wins beyond run-to-run noise.

**5. Ship.** Add the entries to `FAA_DICT` in `lib/expansion.sh` plus the tables here and in `SKILL.md`; `test/run.sh`'s drift test fails until all three agree. Prune measured-neutral entries while you're at it — a leaner table is a better table.

Full details — corpus-hygiene rules, a ready-made `count_tokens` helper, and the decision gates — are in [docs/custom-dictionary.md](docs/custom-dictionary.md).

## Safety

Compression automatically disengages for:
- Security warnings
- Irreversible operation confirmations
- Multi-step sequences where abbreviation could cause misreading
- Any sign the user is confused

Fenced code blocks are never expanded (enforced structurally by the splitter). File paths, error messages, and inline code are additionally protected by the expansion prompt, but the on-device model is small — treat expanded prose as a convenience view and the compressed original as authoritative.

## Repository Layout

| Path | Role |
|------|------|
| `skills/faa-speak/` | The compression skill — system prompt and trigger surface |
| `hooks/` | Stop-hook wiring + `expand-output.sh` (transcript → apfel → systemMessage) |
| `lib/expansion.sh` | Single source of truth: dictionary, expansion prompt, code/prose splitter |
| `scripts/` | `faa-wrap.sh` (non-interactive), `bench.sh` (token benchmark), `mine-dict.sh` (dictionary candidate miner) |
| `bench/nodict-plugin/` | Benchmark-only variant without the dictionary — the `--ab` comparison arm |
| `test/` | Fixture-based suite; apfel stubbed via `APFEL`, `claude` shimmed — no login needed |
| `docs/` | [Custom-dictionary guide](docs/custom-dictionary.md), audit history |

## Testing

```bash
bash test/run.sh          # full suite: splitter, pipeline, hook, wrapper, manifest, dictionary drift
claude plugin validate .  # manifest check
```

The suite stubs apfel via `APFEL` and shims `claude`, so it runs without a model or login.

## Benchmarking

Measure the savings on your own workload (requires a logged-in `claude` CLI; spends real tokens):

```bash
scripts/bench.sh                      # plain vs /faa-speak, 3 bundled prompts
scripts/bench.sh "my prompt" "..."    # your own prompts
scripts/bench.sh --ab                 # + no-dictionary arm over 10 prompts —
                                      #   isolates the abbreviation table's contribution
```

The `--ab` comparison arm is swappable (`VARIANT_ROOT`/`VARIANT_SKILL`) — that's how candidate dictionaries get tested; see [Building a Custom Dictionary](#building-a-custom-dictionary).

## License

MIT — see [LICENSE](LICENSE).
