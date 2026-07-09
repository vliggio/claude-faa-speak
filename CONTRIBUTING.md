# Contributing to faa-speak

Thanks for trying the plugin. Bug reports with `FAA_DEBUG=1` output are gold;
PRs are welcome. Here's everything you need to know — it's a small repo with
strict, mechanical quality gates, so contributions tend to be quick.

## Development setup

No build step. You need `bash`, `jq`, and (only for live end-to-end runs)
[apfel](https://github.com/vliggio/apfel) on macOS 26+. The test suite needs
**neither apfel nor a Claude login** — apfel is stubbed via the `APFEL` env
override and the `claude` CLI is shimmed:

```bash
bash test/run.sh              # 48 checks: splitter, pipeline, hook, wrapper,
                              # manifest, dictionary drift
claude plugin validate .      # manifest check
claude --plugin-dir . ...     # live-test your working copy in a session
```

## Hard rules (CI enforces the first two)

1. **The suite must pass** and **shellcheck must be clean** on every script.
2. **Bash 3.2 compatible** — macOS's default bash. No `mapfile`, no
   associative arrays, and it must also run on Linux (CI is ubuntu: GNU
   tools + mawk — e.g. use `\036`-style octal escapes in awk, not `\x1e`).
3. **The Stop hook must never block the stop.** Every failure path exits 0
   (`trap 'exit 0' EXIT` is load-bearing; a Stop hook exiting 2 blocks the
   user's session). Failures degrade to a silent no-op with a `FAA_DEBUG=1`
   reason.
4. **Code blocks pass through the expander byte-identical.** The suite
   asserts this; don't weaken those tests.
5. **Dictionary changes are measured, not guessed.** The canonical list is
   `FAA_DICT` in `lib/expansion.sh`; the tables in `SKILL.md` and `README.md`
   must match it (the drift test fails otherwise). New entries follow the
   measurement gate in [docs/custom-dictionary.md](docs/custom-dictionary.md):
   mine → verify token delta → A/B with `scripts/bench.sh --ab` → ship.

## Repo tour

| Path | Role |
|------|------|
| `skills/faa-speak/` | The compression skill (system prompt + triggers) |
| `hooks/` | Stop hook: transcript → apfel → `systemMessage` |
| `lib/expansion.sh` | Single source of truth: dictionary, prompt, splitter |
| `scripts/` | wrapper, benchmark, transcript miner |
| `bench/nodict-plugin/` | A/B arm without the dictionary |
| `test/` | fixtures + suite (start here to understand behavior) |

`CLAUDE.md` documents the same constraints for agent-assisted development.

## Pull requests

Small and focused beats big and sweeping. Fill in the PR template checklist —
it's the same set of gates CI runs. If you're changing the expansion pipeline,
add a fixture that would have caught the bug you're fixing; that's how this
repo's test suite was built.
