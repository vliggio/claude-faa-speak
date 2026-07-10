# faa-speak

Claude Code plugin that makes Claude respond in FAA-inspired compressed format to reduce output tokens, then expands the compressed text back to readable English using Apple's on-device foundation model (via [apfel](https://github.com/Arthur-Ficial/apfel)) at zero additional API cost.

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
  git clone https://github.com/Arthur-Ficial/apfel ~/git/apfel
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

### Desktop app

1. Open **Settings → Plugins → Marketplaces**.
2. Add marketplace: `vliggio/claude-faa-speak`.
3. Find **faa-speak** in the marketplace list and click **Install**.

No CLI needed — the desktop app has no `--plugin-dir` equivalent, so this is the only way to load it there.

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
| `FAA_SHOW_SAVINGS=1` | Reports compression savings (word/char counts) on expansion — appended to the hook's systemMessage, printed to stderr by the wrapper |

**These are read by the hook process, not your session** — they must be in the environment that *launches* `claude` (see [How to Debug](#how-to-debug)). Setting them in another terminal, or after Claude Code is already running, does nothing.

## Compression Examples

**Error diagnosis (compressed):**
```
DX: auth mw reject valid tokens | expiry chk uses < not <= | fix: change to <= in token_validator.rs:47
```

**What the expansion shows you:**
> Diagnosis: the authentication middleware rejects valid tokens. The expiry check uses a strict less-than comparison instead of less-than-or-equal-to. Fix: change it to `<=` in `token_validator.rs:47`.

**Code explanation (compressed):**
```
EX: fn filter active users → extract emails | need clean mailing list from user db | filter where active=true, map to .email, ret str arr
```

**What the expansion shows you:**
> What: a function that filters active users and extracts their emails. Why: to get a clean mailing list from the user database. How: filter where `active=true`, map to `.email`, and return an array of strings.

**Architecture advice (compressed):**
```
ARCH: db conn pooling | more mem vs reduced latency | rec for high-load srv, skip for low-traffic
```

**What the expansion shows you:**
> Pattern: database connection pooling. Tradeoff: uses more memory to maintain the pool, but significantly reduces latency under load. Recommendation: use it for high-load servers; skip it for low-traffic ones.

## Abbreviation Reference

The canonical dictionary lives in `lib/expansion.sh`; this table and the one in `skills/faa-speak/SKILL.md` are checked against it by `test/run.sh`. The stock entries are generic — the next section shows how to build a set measured against your own usage.

<div align="center">

| Abbr | Meaning | | Abbr | Meaning |
|:----:|---------|---|:----:|---------|
| arg | argument | | init | initialize |
| arr | array | | int | integer |
| async | asynchronous | | iter | iteration |
| auth | authentication | | msg | message |
| bool | boolean | | mw | middleware |
| cb | callback | | obj | object |
| cfg | configuration | | param | parameter |
| chk | check | | pkg | package |
| cmp | component | | rdr | render |
| db | database | | req | request |
| del | delete | | res | response |
| dep | dependency | | ret | return |
| endpt | endpoint | | sig | signal |
| env | environment | | srv | server |
| err | error | | str | string |
| evnt | event | | tpl | template |
| fn | function | | upd | update |
| hdr | header | | val | value |
| idx | index | | var | variable |
| impl | implementation | | vld | validate |

</div>

## Building a Custom Dictionary

The stock table is generic; your workload's vocabulary is not. Before changing it, read the field notes in [docs/custom-dictionary.md](docs/custom-dictionary.md): most stock entries save ~0 tokens per occurrence, **and yet** the stock table won eight consecutive whole-set A/B runs — against removal, replacement, and even pure augmentation (appending measured acronyms diluted the priming and collapsed the savings). The table's real job is *style priming*, not glyph substitution, so every change — additions included — is gated by a whole-set `bench.sh --ab` win:

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

## How to Debug

The hook is designed to fail quiet rather than break your session, so when something's off, you have to *ask* it why. Debugging is a **CLI-only** workflow: the `FAA_*` variables and the `--debug` flag both require control over how `claude` is launched, which you don't have in the desktop app (it doesn't inherit your shell's exports). If you normally use the desktop app, debug from a terminal — the plugin behaves identically.

**1. Launch with the variables on the command line** (this is the part that trips people up — the hook inherits the environment of the `claude` *process*, not whatever shell you happen to export things in later):

```bash
FAA_DEBUG=1 FAA_SHOW_SAVINGS=1 claude --debug
```

**2. Find the hook's log lines.** `--debug` prints a log path at session start (`~/.claude/debug/<session-id>.txt`). Everything the hook wants to tell you is in there:

```bash
grep 'faa-speak:' ~/.claude/debug/<session-id>.txt   # every no-op explains itself
grep -A3 'Hook Stop' ~/.claude/debug/<session-id>.txt # what the hook actually emitted
```

The `faa-speak:` lines tell you which text source was used (`last_assistant_message` vs the transcript fallback), why a response was skipped (no marker, marker mid-text, already expanded, jq/apfel missing), and the hook-input keys if a Claude Code update ever changes the schema.

**3. Check apfel independently.** If expansions come back identical to the compressed text, apfel is failing and falling back — the hook will say so in a `⚠` systemMessage with apfel's own error. Verify directly:

```bash
apfel --model-info                                    # is Apple Intelligence enabled + model downloaded?
printf 'db conn pool chk' | apfel -s "expand abbreviations"
```

**4. Rule out the plugin itself** — both run without a model or login:

```bash
bash test/run.sh          # 69 checks; all green means the pipeline is healthy
claude plugin validate .  # manifest loads
```

Quick symptom table:

| Symptom | Likely cause | Where it tells you |
|---|---|---|
| No expansion at all | plugin not loaded, or response had no trailing marker | debug log: `Registered 0 hooks` / `faa-speak: marker absent` |
| `⚠ apfel could not expand` | Apple Intelligence off, model not downloaded, apfel broken | the warning carries apfel's error; `apfel --model-info` |
| Expansion identical to compressed, ~0% savings | old plugin version pre-warning — same apfel cause as above | `apfel --model-info` |
| No savings line | `FAA_SHOW_SAVINGS=1` not in the launch environment | step 1 |

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

## How It Compares: Caveman Mode

[Caveman](https://github.com/JuliusBrussee/caveman) is the best-known project in this space — it makes agents "talk like a caveman," reports ~65% average output savings on its own 10-prompt benchmark, ships for 30+ agents, and is honest about its limits. If you're evaluating this category, evaluate both. The structural difference:

**Caveman compresses what the model says. faa-speak compresses what you pay for — and re-expands what you read.**

| | faa-speak | Caveman |
|---|---|---|
| What you read | Plain English (free on-device re-expansion via Apple Intelligence) | Caveman-speak — the compressed form *is* the output |
| Output savings | ~53% measured (10-prompt bench, tooling included) | ~65% claimed (their 10-prompt bench; methodologies differ) |
| Scope | Claude Code, deeply integrated (Stop hook, systemMessage delivery, savings reporting, never-blocks-your-session contract) | 30+ agents, broadly integrated (skill-file drop) |
| Input tokens | Untouched | Memory-file compression (~46% claimed) reduces future input |
| Dictionary | Measurement-gated: every change A/B-tested; tools to mine + verify your own entries | Fixed style with intensity levels (lite/full/ultra) |
| Auto-clarity | Compression auto-disengages for security warnings, irreversible ops, user confusion | Manual level toggle / "normal mode" |
| Failure honesty | Expansion failures announce themselves with the underlying error | n/a — nothing to fail; output is already final |
| Prerequisites | Compression: none. Expansion: macOS 26+, Apple Intelligence, [apfel](https://github.com/Arthur-Ficial/apfel) | Node ≥ 18 |
| Verification | 72-check suite, CI, published self-audit with receipts | Benchmark + eval directories |

**Why faa-speak, in one argument:** compressed output is only cheap if someone reads it, and with Caveman that someone is you, all day, every response. faa-speak closes the loop — the API bills you for the compressed tokens, and an on-device model (costing nothing and sending nothing anywhere) hands you readable English. You get the savings without adopting a dialect. The dictionary is also *earned* rather than assumed: every entry survived token-delta measurement, and the whole table survived eight adversarial A/B runs (documented in [docs/custom-dictionary.md](docs/custom-dictionary.md) — including the finding that compression tables work by style-priming, not glyph-swapping, which anyone building in this category will want to read).

**When Caveman is the better choice, honestly:** you work across many agents (faa-speak is Claude Code only), you're not on an Apple Intelligence Mac (you'd get faa-speak's compression but read it raw — at which point the two products converge), you want input-token savings via memory-file compression (faa-speak doesn't touch input), or you simply enjoy reading grug. Both are MIT; nothing stops you benchmarking one against the other with `scripts/bench.sh` — we'd genuinely like to see the numbers.

## License

MIT — see [LICENSE](LICENSE).
