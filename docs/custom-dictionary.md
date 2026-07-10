# Building a Custom Dictionary

How to extend (or prune) faa-speak's abbreviation dictionary with entries
measured against **your** workload, instead of guessed. The whole process is
measurement-gated: a candidate earns a slot only if it survives three checks —
corpus frequency, token delta, and an end-to-end A/B.

Background: the 2026-07 A/B (issue #10) showed telegraphic style alone saves
~45% of output tokens and the 40-entry dictionary adds ~8 points on top. Any
extension is chasing a slice of what's left, so every entry must pay its way —
each one also grows apfel's expansion prompt (eating into its 4096-token
window) and adds an ambiguity the small on-device expander can get wrong.

## 1. Mine a corpus

The dictionary compresses Claude's **responses**, so mine assistant output,
not user prompts:

```bash
scripts/mine-dict.sh                                    # all local projects
scripts/mine-dict.sh ~/.claude/projects/<project-dir>   # scoped (preferred)
TOP=60 MINCOUNT=10 MINLEN=6 scripts/mine-dict.sh        # tuning knobs
```

The miner extracts assistant text from transcript JSONL, strips fenced code,
inline code, and URLs, and ranks unigram/bigram/trigram frequencies —
excluding stopwords and everything `FAA_DICT` already covers.

**Corpus hygiene (this decides whether the output means anything):**

- **Scope to real work.** Agent-heavy or meta sessions (audits, big workflow
  runs) flood the global ranking with their own vocabulary. Pass the project
  directories whose responses look like your day-to-day usage.
- **Suspiciously identical counts = one repeated artifact**, not vocabulary
  (e.g. an error message logged 1,224 times), — ignore those rows.
- **Privacy:** output is vocabulary + counts only, but the corpus itself is
  raw conversation text. Mine locally; never commit extracts. Commit only the
  final candidate word list.
- Prefer **bigram/trigram phrases** — multi-word compressions
  (`environment variable → env var`, `connection pool → conn pool`) save more
  tokens per substitution than any single word.

## 2. Verify the token delta

Frequency is not value. Most short common words are already one token, so
abbreviating them saves nothing (and some abbreviations cost *more* — `evnt`
tokenizes worse than `event`). The earning rule:

> tokens(full form) − tokens(abbreviation) ≥ 1, measured in context

The easy path — no API key needed, just a logged-in `claude` CLI:

```bash
scripts/verify-deltas.sh          # measures every current entry + a built-in
                                  # devops candidate set; prints KEEP/CUT/ADD/SKIP
scripts/verify-deltas.sh my.txt   # your own candidates (lines: abbrev|full form)
```

Or measure by hand with the `count_tokens` API. Constant message overhead
cancels when you subtract, and putting the word in a sentence keeps
tokenization realistic:

```bash
count() {
  curl -s https://api.anthropic.com/v1/messages/count_tokens \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"claude-sonnet-5\",\"messages\":[{\"role\":\"user\",\"content\":\"use $1 here\"}]}" \
  | jq .input_tokens
}
count "kubernetes deployment"   # full form
count "k8s deploy"              # candidate abbreviation — delta is the value
```

Expected value per entry ≈ corpus frequency × token delta. Sort by that.

## 3. Choose the abbreviations

- **Unambiguous, one expansion.** The expander is a small on-device model; an
  abbreviation with two plausible readings will eventually be expanded wrong.
- **No identifier collisions.** Strings that appear as real names in code or
  prose (`ctx`, `txn`, `env` is already taken) risk being "expanded" where
  they shouldn't. Backtick-protection helps but don't lean on it.
- **No collisions with existing entries** — check `FAA_DICT` in
  `lib/expansion.sh`.
- Prune while you add: if a measured-neutral entry exists (delta 0), retire it
  to keep the table and the expansion prompt lean.

## 4. Build a bench variant and A/B it

Never edit the shipped skill to test a hypothesis. Copy the benchmark variant:

```bash
cp -r bench/nodict-plugin bench/extdict-plugin
# then in bench/extdict-plugin:
#  - .claude-plugin/plugin.json: "name": "faa-speak-extdict"
#  - rename skills/faa-speak-nodict -> skills/faa-speak-extdict
#  - SKILL.md frontmatter name: faa-speak-extdict
#  - restore the Abbreviations section (copy from the real SKILL.md),
#    remove the "write every word in full" rule, add your candidate rows
claude plugin validate bench/extdict-plugin
```

Run the three-arm benchmark (plain / current faa / your variant):

```bash
VARIANT_ROOT="$PWD/bench/extdict-plugin" VARIANT_SKILL=faa-speak-extdict \
  scripts/bench.sh --ab
```

**Decision rule:** repeat the run a few times (single runs are noisy — the
#10 baseline moved a few points between runs). Ship the extension only if the
variant beats the current dictionary beyond run-to-run noise. Prompts should
resemble your workload; add your own as arguments.

## 5. Ship it

The dictionary has exactly one source of truth plus two rendered tables, all
drift-tested:

1. Add the entries to `FAA_DICT` in `lib/expansion.sh` (the expander learns
   them from here — nothing else needs code changes).
2. Add matching rows to the tables in `skills/faa-speak/SKILL.md` (what the
   model compresses with) and `README.md` (human reference).
3. `bash test/run.sh` — the drift test fails until all three agree; the suite
   also re-checks the expansion pipeline.
4. `claude plugin validate .` and update the README's measured-savings line
   with your new `--ab` numbers.

Keep `bench/extdict-plugin` around only while experimenting; the shipped
plugin should carry exactly one dictionary.

## Field notes: style priming beats glyph deltas (2026-07)

We ran this process end-to-end and the results overturned the naive model of
how the dictionary works. Short version: **the table's dominant mechanism is
register priming, not per-glyph token savings.**

What happened (all reproducible with the tools in this repo):

1. `verify-deltas.sh` over the shipped 40-entry table: **only `async` has a
   positive token delta.** Most entries are 0 (`fn`/`function` are each one
   token); several invented ones are negative (`vld`, `evnt`, `rdr`,
   `endpt`). Intuition failed in both directions — `k8s` measured **−2**.
2. Web-mined candidates produced a measured 34-entry set (every entry ≥ +1:
   `IAM`, `RBAC`, `SLA`, `PR`, `VM`, ... — see `bench/measured-plugin`).
3. Whole-set A/B, **eight runs — the legacy table won all eight**:
   - v1 (measured table, softened rules/examples): lost by 30–50 points
   - v2 (byte-identical skill, table-only swap): still lost — isolates the
     table contents as the causal variable
   - v3 (v2 + explicit truncation-license rules): recovered roughly half the
     gap, still lost (34%/14% vs 45%/38%)
   - v4 (**additive**: legacy table fully intact, measured acronyms merely
     *appended*): collapsed to 6%/3% vs 56%/37% — pure additions, each
     individually token-positive, destroyed the savings

Interpretation: a wall of aggressive truncations (`fn`, `chk`, `vld`) reads
as *"this dialect compresses everything"* and licenses terse output across
the whole response — worth ~30–50 points of savings. A list of professional
acronyms (`IAM`, `SLA`) reads as ordinary prose register — and v4 shows the
model **averages the register across the whole table**, so diluting the
weird entries with normal-looking ones breaks the priming even when nothing
is removed. The ~1-token-per-occurrence glyph deltas are noise by
comparison.

Practical rules this implies:

- **The table is a style artifact, not a glossary.** Keep it small, dense,
  and aggressive; its job is to set the register.
- **Any table change — additions included — ships only through a whole-set
  A/B win** (`bench.sh --ab`). Per-entry token deltas are necessary but
  nowhere near sufficient; v4 proved individually-positive additions can be
  collectively catastrophic.
- Invented truncations prime hardest but expand worst (apfel misreads `vld`
  far more often than it would `SLA`) — a real fidelity cost, currently paid
  willingly because the priming is where the savings live.
- The 2026-07 investigation tested removal, replacement, explicit-rule
  substitution, and augmentation: **no variant beat the original table.**
  The lab variants remain under `bench/` for reproduction.
