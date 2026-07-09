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

The canonical dictionary lives in `lib/expansion.sh`; this table and the one in `skills/faa-speak/SKILL.md` are checked against it by `test/run.sh`. To extend it with entries measured against your own usage (transcript mining → token-delta verification → A/B), see [docs/custom-dictionary.md](docs/custom-dictionary.md).

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

## Benchmarking & Dictionary Tuning

Measure the savings on your own workload (requires a logged-in `claude` CLI; spends real tokens):

```bash
scripts/bench.sh                      # plain vs /faa-speak, 3 bundled prompts
scripts/bench.sh "my prompt" "..."    # your own prompts
scripts/bench.sh --ab                 # + no-dictionary arm over 10 prompts —
                                      #   isolates the abbreviation table's contribution
```

The `--ab` arm is swappable, so a candidate dictionary variant is one command to test:

```bash
VARIANT_ROOT="$PWD/bench/extdict-plugin" VARIANT_SKILL=faa-speak-extdict \
  scripts/bench.sh --ab
```

To find candidates worth testing, mine your own local transcripts — assistant text only, with code, URLs, stopwords, and already-covered terms stripped; output is vocabulary and counts, never conversation content:

```bash
scripts/mine-dict.sh ~/.claude/projects/<project-dir>   # scope to real work
TOP=60 MINCOUNT=10 scripts/mine-dict.sh                  # tuning knobs
```

The full measurement-gated process — corpus hygiene, `count_tokens` delta verification, abbreviation-selection rules, and the A/B decision gate — is documented in [docs/custom-dictionary.md](docs/custom-dictionary.md).

## License

MIT — see [LICENSE](LICENSE).
