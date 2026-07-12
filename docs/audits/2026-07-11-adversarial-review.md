# faa-speak — Adversarial Review (2026-07-11)

> **Status (2026-07-12): mechanical findings remediated; premise findings open.**
> Every code defect below (B1–B7) was fixed the next day in two commits —
> `ca4dd42` (B1–B4) and `0d7848c` (B5–B7) — growing the suite from 72 to 93
> checks, all verified under bash 5.3 **and** stock macOS bash 3.2 plus
> shellcheck. The premise findings (P1–P7) are product/methodology questions
> that code cannot close; they are recorded here with what would resolve each.
> The report body describes the repo **as of `dc97041` (v0.2.0)**, the state
> that was reviewed.

> **Scan mode:** single-reviewer adversarial pass (Claude Fable 5), brief:
> *"assume nothing is right, that the whole premise is incorrect in the first
> place."* Every mechanical finding was reproduced empirically before being
> reported — pipeline functions executed directly with instrumented stubs, both
> entry points driven end-to-end with shims. Environment: macOS 25.5.0,
> bash 5.3.15 and /bin/bash 3.2.57, apfel v1.8.3 present (Apple Intelligence
> disabled on the review machine, so live-model behavior was out of scope —
> everything asserted below is about what the pipeline *sends and reassembles*,
> which is fully testable without the model).

Labels follow the 2026-07-08 audit: **FACT** = reproduced or verified at the
cited site during this review · **JUDGMENT** = opinion grounded in cited
evidence.

---

## 1. Verdict

The engineering hygiene is genuinely above hobby grade — quoting discipline
(no injection path found), graceful degradation, drift tests, an honest
published self-audit with a real remediation cycle. But the premise's evidence
does not survive scrutiny: **the project's own data shows 85% of the measured
savings comes from plain telegraphic style, the A/B that justifies the
remaining 15% is confounded, and nothing anywhere measures whether meaning
survives the compress→expand round trip.** On top of that, four mechanical
defects were confirmed empirically — including one whose regression test
passed for the wrong reason.

---

## 2. Premise findings (open)

**P1 — The benchmark measures brevity, not compression.** JUDGMENT (mechanism
FACT). `bench.sh` compares `usage.output_tokens` between arms with nothing
holding information content constant. The skill instructs dropping hedging,
pleasantries, and preferring short synonyms — i.e. *say less*. A response that
omits content scores as "savings"; the degenerate case (empty response = 100%)
is excluded only by hope. No quality arm, no information-parity check exists.
*Resolves with:* an information-parity rubric (or LLM-judge equivalence check)
run alongside the token counts.

**P2 — The project's own data undermines its distinctive machinery.** FACT
(their numbers). README reports 53% total savings; the no-dictionary arm saved
45% — so telegraphic style alone, achievable with a one-line "be terse"
instruction that stays *readable* and needs no marker/hook/apfel/dictionary,
delivers **85%** of the benefit. The 2026-07-08 audit's own Open Question 5
set the decision rule: *"if telegraphic style alone achieves ~90% of the
savings, the dictionary + sync burden may not earn its keep."* 85%, with the
remainder confounded (P3) and docs conceding the baseline "moved a few points
between runs," is not a clear pass of that gate — yet the README markets the
dictionary as "earned."

**P3 — The A/B isolating the dictionary is confounded.** FACT.
`bench/nodict-plugin`'s skill differs from the shipped one by more than the
table: it also **drops two of the three worked examples** (EX and ARCH) and
rewrites the remaining one in unabbreviated register. `docs/custom-dictionary.md`'s
own field notes conclude the causal mechanism is *register priming* — which
in-context examples drive at least as hard as tables. The "dictionary adds
~8 points" claim therefore attributes to the table what may belong to the
missing examples. The v2 experiment ("byte-identical skill, table-only swap")
shows the team knows how to do a controlled swap; the shipped nodict arm is
not one. *Resolves with:* a nodict arm that differs from the real skill by the
table rows only.

**P4 — The benchmark doesn't resemble the deployment.** JUDGMENT (prompt set
FACT). All bench prompts are prose-only Q&A — the technique's best case. The
plugin deploys into Claude Code, where output tokens are dominated by tool
calls, file edits, and code, all exempt from compression. No real agentic
coding session has been measured, and subscription users don't pay per output
token at all. *Resolves with:* a bench arm replaying representative coding
tasks, reporting the addressable-prose fraction.

**P5 — The trust chain inverts the quality gradient, and fidelity is never
tested.** JUDGMENT (test-coverage claim FACT). The user pays for a frontier
model, then reads a paraphrase from the weakest model in the chain. The docs
*admit* the hazard: invented truncations "prime hardest but expand worst —
apfel misreads `vld` far more often." The README's own example routes
precision-critical content (`<` vs `<=`) through the paraphraser, and its
escape hatch — "treat the compressed original as authoritative" — concedes the
readable text is unreliable, but the readable text is the product. Meanwhile
**every check in the suite stubs apfel**: the plumbing is well tested; the
semantic core (does expansion preserve meaning?) has zero verification, even a
manual golden file. *Resolves with:* a fidelity eval — golden compressed→
expanded pairs scored for meaning preservation, run whenever the dictionary or
expansion prompt changes.

**P6 — Conversation-state divergence.** FACT (mechanism), JUDGMENT (impact).
The expansion lives only in a `systemMessage`; it never enters the model's
context. The user reads apfel's phrasing; Claude remembers only the compressed
text. Follow-ups referencing the expansion's wording reference words the model
never produced — and if apfel paraphrased wrong, user and model now silently
disagree about what was said. Unaddressed anywhere. *Resolves with:* at
minimum, a documented caveat; structurally, there is no hook mechanism to fix
it today.

**P7 — The UX pitch overstates what users get.** FACT (each mechanism).
The user watches compressed text stream in first (the expansion arrives
afterward as a duplicate block); mid-turn text between tool calls is never
expanded (Stop fires once, on the final message); on a 30s timeout kill the
visible expansion is lost entirely — the "streamed partials" go to stderr,
i.e. a debug log nobody has open. Auto-Clarity, the flagship safety feature,
is an unenforced prompt instruction with no test and no machinery behind it.
*Resolves with:* honest README framing (partially present) and, for
Auto-Clarity, at least a live-model spot check.

---

## 3. Mechanical findings (all FACT, all remediated 2026-07-12)

**B1 — The 450-word "hard flush" did not bound chunk size; its regression test
passed for the wrong reason.** Words were counted per line and the flush check
ran only *after* a whole line was appended — but markdown paragraphs usually
arrive as **one** line. Reproduced: a 2000-word single-line paragraph reached
apfel as one 2000-word chunk (far past the 4096-token window the design
centers on), plus a degenerate 0-word chunk. The suite's hard-flush test
(520 words, one line, "≥2 chunks") passed only because the herestring's
trailing newline produced that empty second chunk — the test validated the
bug. This was an incomplete fix of the 2026-07-08 audit's M7.
*Fixed in `ca4dd42`:* over-cap lines are sliced at word boundaries;
accumulation flushes before an append could exceed the cap; tests assert exact
chunk sizes (`450 70`, `450 450 450 450 200`).

**B1a (found during remediation) — bash 3.2 pattern substitution is
quadratic-or-worse on long strings.** `${var//[[:space:]]/}` on a 22KB
paragraph takes minutes under /bin/bash 3.2 (microseconds under bash 5). The
construct predated this review in the original chunker — on a stock Mac
(where `bash` = 3.2) a long single-line paragraph would have spun the Stop
hook into its 30s timeout, silently losing the expansion. All blank-line
checks now use glob matches (`*[![:space:]]*`, ~1ms). The suite now runs
under both bash versions.

**B2 — Whitespace-only chunks were sent to apfel and its output spliced into
the expansion.** The `<=3-word` gate applied only to whole segments, not the
loop's residual buffer. Beyond a wasted inference, a small model handed an
instruction prompt and blank input can answer the *prompt itself* — and
whatever it emits was appended verbatim into the user-facing systemMessage.
*Fixed in `ca4dd42`:* whitespace-only buffers are emitted verbatim, never
sent to apfel.

**B3 — Nested fences broke the "code is never expanded" invariant.** The
splitter toggled on any ```` ``` ```` line. Reproduced: a 4-backtick fence
containing a 3-backtick block — a shape Claude produces routinely when showing
markdown — had its inner content classified **prose** and sent to apfel for
rewriting. *Fixed in `ca4dd42`:* CommonMark fence-length tracking (open with
N, close only on ≥N of the same kind with nothing after them; info-string
lines never close a block), with byte-identity tests.

**B4 — The wrapper violated the marker contract the hook's own fixtures
enforce.** `faa-wrap.sh` gated on *contains* (not ends-with) and stripped
**all** marker occurrences. Reproduced: a reply that merely quoted
`<!-- faa -->` mid-text — the exact M3 case in `test/fixtures/mid-marker.jsonl` —
was expanded anyway, and the quoted marker was deleted from the content.
*Fixed in `ca4dd42`:* `faa_gate` moved to `lib/expansion.sh` as the single
definition of the contract; both entry points use it.

**B5 — Documentation numbers drifted.** README said "69 checks" in one place
and "72-check suite" in another (actual: 72); SKILL.md claimed "~50% measured"
against the README's ~53%. The repo's drift-test paranoia stopped at the
dictionary tables. *Fixed in `ca4dd42`/`0d7848c`:* counts and the savings
figure aligned (a check-count drift test was not added; the number will drift
again — accepted).

**B6 — The truncation notice made a false promise.** "full expansion in the
debug log" is only true when the session was launched with `claude --debug`;
otherwise the tail is simply gone. *Fixed in `0d7848c`:* the notice states
the condition and that the compressed response above is complete; the
truncation path gained its first test.

**B7 — Minor pile.** (a) A literal `\x1e` byte in model output corrupted
record framing (it is the pipeline's record separator) — now dropped at the
pipeline entrance. (b) `~~~` tilde fences were invisible to the splitter —
now recognized with fence-char tracking; indented (4-space, unfenced) blocks
remain unrecognized *by design* and CLAUDE.md now says so. (c) Scratch
flag/error files leaked into TMPDIR on timeout kills — cleanup moved into the
EXIT trap (TERM/INT/HUP route through it) with a startup purge for
SIGKILL-orphaned files and week-old dedupe state. (d) The wrapper silently
mixed compressed chunks into "expanded" output on per-chunk apfel failure
while the hook announced it — the wrapper now prints the same ⚠ warning with
apfel's own reason. All in `0d7848c`.

Not fixed, judged acceptable: `cksum` (CRC32) as the dedupe signature can
collide — the consequence is one skipped expansion.

---

## 4. What held up under attack

- **Quoting discipline:** every expansion of untrusted data quoted, `jq --arg`
  throughout — no shell-injection path found.
- **The never-block-the-stop contract:** airtight for everything short of
  SIGKILL (and now also cleans up after itself).
- **Degradation never loses data:** every failure path falls back to the
  compressed original.
- **The transcript-race fix** (last_assistant_message primary, staleness
  guard, per-session dedupe) is careful work.
- **Honest docs culture:** eight losing A/B runs published rather than buried;
  the 2026-07-08 audit-to-remediation cycle was real, not theater.

---

## 5. Bottom line

As shell engineering, the repo is well above its weight class — and after
`ca4dd42`/`0d7848c`, the mechanical layer matches its own documentation. As a
*product claim*, it still stands on an 8-point token delta whose measurement
is confounded (P3), whose deployment context was never benchmarked (P4), and
whose user-facing output has never been checked for meaning preservation
(P5). The defensible core — "telegraphic style saves ~45% on prose Q&A" —
requires none of the expansion machinery, because plain terse English doesn't
need to be decompressed. The cheapest experiments that would move the needle,
in order: a table-only nodict arm (P3), a golden-pair fidelity eval (P5), and
one real coding-session measurement (P4).

## 6. Remediation record

| Finding | Commit | Guarding tests |
|---|---|---|
| B1 / B1a | `ca4dd42` | exact chunk-size assertions; suite run under bash 3.2 + 5.3 |
| B2 | `ca4dd42` | no-empty-chunk assertions in the chunk-size tests |
| B3 | `ca4dd42` | nested-fence + closing-fence-purity byte-identity |
| B4 | `ca4dd42` | wrapper mid-marker no-expansion + marker-survival |
| B5 | `ca4dd42`, `0d7848c` | (doc alignment; no drift test) |
| B6 | `0d7848c` | oversized-expansion truncation notice + cap |
| B7a–d | `0d7848c` | \x1e framing, tilde fences, scratch hygiene/purge, wrapper ⚠ |

Suite: 72 → 81 (`ca4dd42`) → 93 (`0d7848c`) checks, all green under bash
5.3 and /bin/bash 3.2, shellcheck clean.
