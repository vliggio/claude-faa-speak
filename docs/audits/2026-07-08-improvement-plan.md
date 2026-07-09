# faa-speak — Repo Audit & Improvement Plan (2026-07-08, finalized 2026-07-09)

> **Status (2026-07-09): historical.** This audit describes **v0.1.0**. Every finding was remediated in [v0.2.0](https://github.com/vliggio/claude-faa-speak/releases/tag/v0.2.0) — tracked as issues #2–#14 (epic #1) and landed in PRs #15–#18; the Critical manifest and pipeline bugs described below no longer exist, and the token-savings claims were subsequently measured (~53%, A/B-verified). The report is kept unedited as the record of what was found and how it was fixed.

> **Scan mode:** ultra (ultracode) · **Explorers:** opus (mode default) · **Verifiers:** opus (mode default) · **Orchestrator:** Claude Fable 5 at session effort (skill's opus-1M pin applies only to slash-command invocation)
> **Verification tally (final, across 4 workflow runs):** 538 agents launched, 490 completed, 48 errored on usage-rate limits and were re-run to completion in follow-up workflows (final two runs: 56/56 and 18/18, zero errors); ~16.6M subagent tokens. Two independent full explorer samples ran (all 9 dimensions hit the 4-round loop-until-dry cap in both). **Every Critical/High/Medium finding below survived a 3-lens adversarial opus panel** (splits noted inline); the two headline Criticals were additionally reproduced empirically by the orchestrator executing real code/CLI. Panel-refuted along the way: 7 findings (dropped; notable ones listed in §3.5), plus 1 hedged refutation overturned with direct CLI evidence. **Completeness critic:** 3 rounds, 7 targeted gap investigations — the critic materially changed the audit's headline (it found C0, H9, H10, which all nine dimension explorers had missed).

---

## 1. Executive Summary

**Overall health: D+** (initially graded C- before the critic discovered the plugin does not load at all). The concept is genuinely clever — compress Claude's paid output tokens with a METAR-style skill, then re-expand locally for free with an on-device LLM — and the shell hygiene and prompt design are good. But the audit's bottom line is stark: **the plugin is entirely inert in current Claude Code.** One schema violation in `plugin.json` (`author` must be an object, not a string) makes Claude Code v2.1.199 reject the whole manifest — skill, hook, everything — logging "Registered 0 hooks." Behind that loader wall sit three more independently fatal defects: the expansion pipeline **silently destroys every line after the first in each segment, including all code-block bodies** (reproduced empirically three separate ways); the expansion is delivered to **Stop-hook stderr on exit 0, a channel the interactive UI never displays**; and the non-interactive wrapper **can never trigger compression** in its documented usage. The good news is proportionality: a one-line manifest fix revives the product, a small stdout-JSON change makes it visible, and the pipeline is trivially testable once fixtures exist. **Top 3 risks:** (1) shipping artifact doesn't load (C0), (2) segment data-loss bug (C1), (3) docs and agent docs assert behavior the code demonstrably lacks, misleading users and every future agent session. **Top 3 opportunities:** (1) the one-line `author` fix plus `claude plugin validate` as a standing gate, (2) fixture tests with a stubbed `APFEL` (the env override already makes this free), (3) measuring the token-savings claim to decide whether the abbreviation dictionary earns its four-copy maintenance burden at all.

---

## 2. Repo Map

- **Purpose:** Claude Code plugin. `skills/faa-speak/SKILL.md` makes Claude respond in FAA-inspired compressed format (~40 abbreviations, `DX:`/`EX:`/`ARCH:` prefixes, telegraphic style), ending responses with an `<!-- faa -->` marker. A Stop hook (`hooks/scripts/expand-output.sh`, wired by `hooks/hooks.json`) extracts the last assistant text from the transcript JSONL, splits code from prose with awk, expands prose through `apfel` (Apple on-device LLM CLI, 4096-token context) and prints readable English to stderr. `scripts/faa-wrap.sh` wraps `claude --print` for non-interactive use.
- **Stack:** bash + jq + awk; JSON config; Markdown skill. macOS-only (apfel requires Apple Intelligence). No CI, no tests, single author.
- **Files (523 lines total):** `.claude-plugin/plugin.json` (manifest v0.1.0) · `hooks/hooks.json` (Stop → script) · `hooks/scripts/expand-output.sh` (173, core logic) · `scripts/faa-wrap.sh` (38) · `skills/faa-speak/SKILL.md` (106) · `README.md` (115) · `CLAUDE.md` (56) · `.gitignore` · `.claude/settings.local.json` (local-only, correctly untracked).
- **Maturity:** personal prototype / weekend experiment. Severities are calibrated to that — but correctness bugs in the core path still rate Critical/High because the plugin has exactly one job.
- **Surprises:** the single most important finding (C0) came not from the nine dimension explorers but from the completeness-critic loop, which was the only stage to actually run `claude plugin validate` and load the plugin with `--debug`.

---

## 3. Audit Report

Labels: **FACT** = verified at the cited line/command during this audit · **JUDGMENT** = opinion grounded in cited evidence · **HYPOTHESIS** = suspected, not fully verified. All Critical/High/Medium findings are 3-lens panel-verified.

### 3.1 Critical

**C0 — The plugin does not load: one manifest field fails schema validation and Claude Code drops the entire plugin.** FACT; panel 3-0 (×2 findings, merged); empirically reproduced by orchestrator and by a controlled experiment.
`.claude-plugin/plugin.json:5` declares `"author": "vliggio"` — a string — but the plugin-manifest schema requires an object (`{"name": ...}`). `claude plugin validate` fails: `author: Invalid input: expected object, received string → Validation failed` (orchestrator-reproduced on claude v2.1.199). The runtime consequence is total: loading via `claude --plugin-dir .` logs `[ERROR] Plugin ... has an invalid manifest file`, `[WARN] Failed to load session plugin`, and `Registered 0 hooks` — the **skill, the hook, everything is rejected wholesale**. Causality was proven, not inferred: changing *only* `author` to `{"name":"vliggio"}` flips the log to `Registered 1 hooks`.
*Why it matters:* every other finding in this report describes behavior behind a door that currently doesn't open. The fix is one line (**T0**), and `claude plugin validate` belongs in CI (**T9**) so this class of drift (the manifest presumably predates stricter validation) can't silently recur.
*Corollary (validate warning):* root-level `CLAUDE.md` is not shipped as plugin context (dev-only) — fine as-is, just don't expect users to receive it.

**C1 — Segment reassembly silently discards all but the first line of every segment; code blocks are destroyed.** FACT; verified three independent ways: orchestrator's empirical repro, an independent rediscovery + end-to-end repro by a critic-round gap finder, and two full 3-lens panels (one 3-0, one 3-0 with an impact-lens note).
`hooks/scripts/expand-output.sh:104-163`. The awk splitter accumulates multi-line segments into `buf` and prints each as one record with **embedded newlines** (`print "PROSE:" buf` / `print "CODE:" buf`, lines 110/113/121-125). The consumer, `while IFS= read -r segment` (line 131), reads **one physical line at a time**; only the first line carries the `CODE:`/`PROSE:` prefix, and every continuation line matches neither branch of the `if/elif` (lines 132-137, no `else`) and is silently dropped.
**Reproduction** (hook lines 102-163 executed verbatim, `expand_prose` stubbed):

Input:
```
DX: issue | cause | fix
second prose line with several words here

```bash
code line one
code line two
```
trailing prose after code
```

Output:
```
<<P:DX: issue | cause | fix>>```bash<<P:trailing prose after code>>
```

Second prose line: gone. Code block body: gone (an *unclosed* ` ```bash ` fence survives). Paragraph structure: collapsed. Only single-line responses — exactly the README's demo examples — survive intact. One panel lens noted that because the mangled output lands on invisible stderr (H1), "Critical" arguably reads "High" today; the label is kept because this is the core path's core invariant, and fixing H1 immediately exposes C1 to every user. Fix in **T2**, guarded by **T1**.

### 3.2 High

**H1 — The expanded English is delivered to a channel the user never sees.** Mechanism FACT, channel-semantics JUDGMENT confirmed against hooks docs; panel-kept three separate times (2-1, 3-0, 3-0).
`hooks/scripts/expand-output.sh:167-173` writes the expansion to stderr and exits 0. Per the hooks reference, on exit 0 only **stdout** is parsed (and shown only in transcript mode); stderr on exit 0 is written to the debug log and never displayed; stderr reaches the user only on non-zero/non-2 exits. So in the documented interactive flow (README:44-51) the user sees compressed telegraphic text as the canonical response and the readable English goes nowhere visible. "Expanded English printed below" (README:15) is false in practice. Docs-supported fix: emit `{"systemMessage": "..."}` on stdout (**T3**). One dissenting lens (run 1) correctly noted the token-saving half of the value proposition survives regardless.

**H2 — `faa-wrap.sh` can never produce compressed output in its documented usage; the expansion branch is dead code.** FACT; panel-kept 3-0 twice.
`scripts/faa-wrap.sh:32` runs bare `claude --print "$@"` — no `--plugin-dir`, no system-prompt injection, no trigger phrase in the documented invocations (README:61, header line 7). Skills don't auto-trigger in `--print` mode (docs-confirmed; they must be invoked as `/skill-name` in the prompt) and sessions don't persist. The `<!-- faa -->` guard at line 34 is effectively always false; the script degrades to a plain passthrough. Bonus defect (panel 3-0): the header's `-p "custom system prompt"` usage cannot work — `-p` is claude's alias for `--print`. Fix or delete in **T4** (Open Question 3).

**H3 — When it does fire, `faa-wrap.sh` pipes the *entire* output — fenced code included — through apfel in one un-chunked call, with no failure fallback.** FACT; panel-kept (3-0 and 2-1).
`scripts/faa-wrap.sh:35`: no CODE/PROSE split (contradicting the invariant the hook implements and CLAUDE.md documents) and no size guard against apfel's 4096-token window. Additionally (panel 3-0): under `set -euo pipefail` (line 10) the pipeline has no `|| echo "$COMPRESSED"` fallback — an apfel failure aborts the script with *nothing* on stdout, unlike the hook's careful `|| true` degradation. Latent behind H2. Fix in **T4** via the shared splitter from **T2**.

**H4 — CLAUDE.md asserts the splitter passes code blocks through unchanged; it demonstrably destroys them.** FACT (`CLAUDE.md:20` vs. C1). Agent docs are executed as instructions every session; this claim points future agents at the exact code path that is broken. Fix in **T6** (after T2 makes it true).

**H5 — Zero executable tests on the core text pipeline.** FACT.
The awk splitter + reassembly loop is pure text-in/text-out and trivially testable via the existing `APFEL` env override (line 12) — yet no test, fixture, or harness exists. C0 *and* C1 would each have been caught by the first fixture run. Fix in **T1**/**T9**.

**H6 — None of the four documented manual test commands exercises the expand path.** FACT (`CLAUDE.md:38-50`).
`claude --print --plugin-dir . "explain..."` carries no `/faa-speak` trigger; the standalone apfel test pipes a *truncated stub* of the real prompt; the wrapper test is H2-dead — and per C0, even the plugin-load test currently fails. The maintainer's own verification playbook green-lights a broken pipeline. Fix in **T6**/**T1**.

**H7 — Seven silent `exit 0` no-op paths and no debug facility.** FACT.
`expand-output.sh:20,28,33,39,50,55,64` exit silently; apfel stderr is discarded (line 93). Combined with H1 and C0, a user whose expansion "doesn't appear" (i.e., everyone) cannot distinguish: plugin not loaded / apfel missing / jq failed / marker absent / stderr invisible. Fix in **T7** (`FAA_DEBUG`).

**H8 — The deliverable's fidelity rests entirely on a small on-device model, unguarded.** JUDGMENT; panel-kept.
`expand-output.sh:93`. The only guard on "keeping full technical accuracy" (SKILL.md:4) is a prose instruction to a ~3B-class model expanding dense abbreviations. Mitigation is measurement (**T8**) and honest doc framing.

**H9 — A transcript-file race can make the "never blocks" hook actively block the stop.** FACT; critic-round discovery; panel 3-0 with empirical verification of each link.
`expand-output.sh:37`: `LAST_LINES=$(grep ... "$TRANSCRIPT_PATH" | tail -n 100)` is an *unguarded* command substitution under `set -euo pipefail`. If the transcript is deleted/rotated/unreadable between the checks at lines 27/32 and the read at 37 (TOCTOU), `grep` exits **2**, `pipefail` propagates it, `set -e` aborts the hook with exit code 2 — and for Stop hooks, **exit 2 means "block the stop and feed stderr back to the model"**. grep's own error message becomes the "reason to continue." The guarded jq at lines 42-47 shows the author knows the pattern; it just wasn't applied here (jq's parse-error exit is 5, not 2, so line 25 aborts non-blockingly). Fix in **T7**: `trap 'exit 0' EXIT` or the same `set +e` guard.

**H10 — Inline verbatim content (single-backtick spans, file paths, error messages in prose) has no structural protection.** FACT; critic-round discovery; panel 3-0.
README:111 promises "code blocks, **file paths, error messages, and commands** are never abbreviated"; the hook structurally protects only *fenced* blocks (`expand-output.sh:106`). Inline code spans and paths ride through apfel guarded only by a prompt clause — and `faa-wrap.sh:28`'s drifted prompt **omits the "inside backticks" clause entirely** (panel 3-0, Medium, folded here), so the path with zero structural protection also lost its only soft protection. Fix in **T2**/**T5** (single-source prompt keeps the clause; add an inline-span fixture to T1).

### 3.3 Medium

**M1 — The abbreviation dictionary exists in four copies, all drifted.** FACT, empirically counted.
SKILL.md (`:23-44`): 40 entries incl. `arg=argument`. Both shell prompts (`expand-output.sh:69`, `faa-wrap.sh:26`): omit `arg`, list `cmp=component` twice each. README (`:83-102`): 36 entries, missing `arg`,`int`,`iter`,`tpl`. faa-wrap's prompt additionally dropped the backtick-protection clause (see H10). CLAUDE.md:32's sync note says "three places" and omits README. Fix in **T5**.

**M2 — README's install command doesn't exist as documented.** FACT (CLI-help evidence; overturned a hedged panel refutation).
`README.md:36` `claude plugin install /path` — but `install` takes marketplace ids; no `marketplace.json` exists for that route. Working mechanisms: `--plugin-dir` (session-only, correctly documented at README:39) or the skills-dir scaffold. Fix in **T6**/**T12**.

**M3 — The marker contract is fragile in both directions.** JUDGMENT; panel-kept.
A single prose instruction (SKILL.md:19) gated by a substring check (`expand-output.sh:54`): a dropped marker silently no-ops (indistinguishable per H7); and `<!-- faa -->` appears in ordinary content (this repo's own docs), so an uncompressed response quoting it triggers "expansion" of normal prose. Mitigate in **T2**/**T7** (end-of-text match).

**M4 — Tight coupling to Claude Code's undocumented transcript serialization.** FACT.
Whitespace-sensitive `grep '"role":"assistant"'` (`:32,:37`) + assumed `.message.content[]` block shape. Any serialization change silently disables the plugin. Fixtures (**T1**) make the contract testable.

**M5 — "The response" is defined as only the last assistant text block.** FACT.
`expand-output.sh:43-45`: multi-block turns get only their final block expanded. Document or tighten in **T2**.

**M6 — The "always exits 0" contract is violated by its own `set -euo pipefail`; jq is never preflighted.** FACT.
Header (`:4`) vs. line 6: missing jq (required, README:30, unchecked — unlike apfel) aborts at line 25 nonzero, surfacing stderr noise on every stop; and see H9 for the exit-2 escalation of the same root cause. Fix in **T7**.

**M7 — Chunking thresholds contradict every documented number; chunk size is unbounded without blank lines.** FACT.
Docs say ~500-word chunks (CLAUDE.md:29); code enters chunking only past 500 (`:140`) then flushes only at an **empty line** past **300** words (`:145`) — a long blank-line-free paragraph goes to apfel whole, blowing the 4096-token window the design centers on. Related Lows: `CLAUDE.md:29`'s "~150 tokens" prompt estimate is materially low; ≤3-word chunks (`:86`) skip expansion entirely, leaving raw abbreviations in the "expanded" output. Fix in **T2**/**T6**.

**M8 — Only column-0 code fences are recognized.** FACT.
`expand-output.sh:106` (`/^```/`): list-indented fenced code is classified as prose and sent to apfel. Fix alongside **T2**.

**M9 — Hook hot-path hygiene.** FACT, minor.
Full transcript grep-scanned twice before the cheap marker check; per-line `wc` forks in the chunk loop. Cheap fixes in **T7**.

**M10 — Un-timed, serial, all-or-nothing expansion inside a stop-gating hook.** FACT/JUDGMENT; panel 3-0 (×2, critic round).
`hooks/hooks.json:7` declares no `timeout`, inheriting the 60s default; Stop hooks gate session completion; apfel calls are synchronous and serial (`:93`); `EXPANDED_OUTPUT` accumulates and prints once at the very end (`:166-171`) — a timeout kill loses the *entire* expansion rather than partial output; and concurrent sessions contend for the single on-device model, stacking latency. Fix in **T7** (timeout + incremental emission).

**M11 — README claims MIT; no LICENSE file, no `license` field in plugin.json.** FACT. Fix in **T10**.

**M12 — Dependency and compatibility posture is personal-machine-only.** JUDGMENT; panel-kept (incl. critic round).
apfel: personal source-only repo, personal fallback path (`:16-17`), unpinned `-s` interface, missing clone/toolchain steps (README:25-29), unchecked macOS-26 requirement. Plus (critic round, panel 3-0): `plugin.json` declares no Claude Code version floor / compatibility field and there is no update-delivery path — exactly the drift class that produced C0. Address per Open Question 1; version floor in **T12**.

**M13 — CLAUDE.md's sync instruction is wrong on both counts; its testing section is self-contradictory.** FACT/JUDGMENT. `CLAUDE.md:32` ("three places", "kept in sync") and `:42-43` (trigger advice impossible in `--print`). Fix in **T6**.

**M14 — "Mode persist until changed or session end" is unenforceable.** JUDGMENT. No component holds state; persistence is model compliance (see M3, H7). Document in **T6**.

**M15 — The efficiency claim is unmeasured, inconsistent, and the dictionary may not be doing the work.** JUDGMENT; kept in run 1, refuted by one run-2 panel on framing — retained as JUDGMENT with that dissent noted.
README:19 "~70-80%" vs SKILL.md:4 "~75%"; nothing measures either. Many table entries are BPE-token-neutral (`fn`/`function`) or negative (`evnt` vs `event`); the telegraphic style does the heavy lifting; the skill costs ~1k input tokens/session. Measure before optimizing (**T8**).

### 3.4 Low (sweep — verified citations; panels not required for Lows by design)

- `echo "$var"` where `printf` is safe against leading `-n`/`-e` (`expand-output.sh:85,93,104,139,152`).
- `faa-wrap.sh:35` marker strip lacks sed's `g` flag.
- jq stderr merged into captured value via `2>&1` (`expand-output.sh:43`).
- In-band `CODE:`/`PROSE:` prefixes can collide with real content lines (`:132-137`).
- Trailing-whitespace trim runs before the code/prose split, mutating code-block trailing spaces (`:61`).
- `faa-wrap.sh:32` unguarded `claude` call; no existence check for `claude`.
- `APFEL` env override — the key to testability — documented nowhere.
- `hooks/hooks.json:5` `matcher:""` on a Stop hook is dead config (Stop doesn't support matchers; silently ignored).
- `SubagentStop` is not wired — subagent responses are never expanded (decide intentionality, note in docs).
- No UTF-8 locale export; harmless on BSD tools, latent abort risk with Homebrew GNU sed in C locale under `set -e` (`:61`).
- `expand-output.sh:104` is a second unguarded command substitution (same class as H9, non-2 exit).
- Prompt-injection into apfel via crafted content — low impact for a local single-user tool.
- README shows no example of *expanded* output; Safety section omits SKILL.md's "user confused" trigger; "Apple's on-device LLM" mislabels a third-party wrapper around Apple's Foundation Models.
- `/faa-speak` slash availability relies on skills-as-commands behavior (works currently; worth a doc note).
- `CLAUDE.md:8` "two components" vs. three maintained artifacts; `CLAUDE.md:29` "~150 tokens" underestimate.

### 3.5 Panel-refuted along the way (dropped; listed for transparency)

Abbreviation-ambiguity/losslessness (arch, run 2) · value-prop framing variant (arch, run 2) · >500-word chunk-path framing (testing, run 2) · word-count-as-token-proxy (critic round) · SKILL.md:64 protective-clause scoping (critic round) · pipe-separator undefined-for-apfel (critic round) · install-commands-as-"unverified" (documentation; refuted as hedged, then **overturned and reinstated as M2** with direct CLI evidence).

### 3.6 Strengths (worth preserving)

- **Shell hygiene:** every expansion of untrusted data is quoted; transcript text is only ever passed as data — no injection path into the shell (multiple panels tried).
- **Plugin skeleton (post-C0):** hooks auto-discovery layout, `${CLAUDE_PLUGIN_ROOT}` usage, valid skill frontmatter, 0755 bits in git, portable shebangs.
- **Graceful-degradation instinct:** apfel-missing → silent skip; per-chunk fallback to original text; 3-word threshold; `APFEL` env override (which enables the whole test strategy).
- **Honest, right-sized CLAUDE.md:** admits no tests; documents cross-file constraints rather than restating code; "~40 abbreviations" is exactly right.
- **Consistent activation story** across README/SKILL.md; the Auto-Clarity safety exceptions are thoughtful prompt design.
- **`.gitignore` hygiene:** local settings confirmed untracked.

---

## 4. Improvement Strategy

**Theme 0 — The door doesn't open (C0, M12).** One schema-invalid field disables everything, and nothing in the repo would ever notice. *Target:* manifest passes `claude plugin validate`; validation runs in CI and before any release; a version floor declares what Claude Code the plugin expects. *Principle:* a plugin's manifest is its most load-bearing file; validate it mechanically, never by assumption.

**Theme 1 — The delivery channel defeats the product (H1, H7, H9).** *Target:* expansion arrives via stdout `systemMessage` (visible), failures are diagnosable (`FAA_DEBUG`), and no failure path can block the stop (`trap 'exit 0'`). *Principle:* output must land where the audience looks; failure must never be louder than success.

**Theme 2 — The core pipeline is unverified and wrong (C1, H5, H6, H10, M4, M7, M8).** *Target:* fixture transcripts + stubbed `APFEL` make the pipeline's contract executable — including code-block byte-identity and inline-span survival — and the segmentation rewrite lands on that safety net. *Principle:* text pipelines are the cheapest code in the world to test.

**Theme 3 — Four copies of the truth, all different (M1, M13, H4, M2, M14).** *Target:* one sourced `lib/expansion.sh`; tables checked by a drift test; docs say only true things. *Principle:* docs that are executed (CLAUDE.md) or followed (README) are code and drift like code.

**Theme 4 — A dead entry point advertised as a feature (H2, H3).** *Target:* `faa-wrap.sh` actually activates the skill (`claude --print --plugin-dir <root> "/faa-speak <question>"`), shares the splitter, and degrades gracefully — or it is deleted along with its README section. *Principle:* a feature that silently no-ops is worse than no feature.

**Theme 5 — Unquantified value proposition (M15, H8).** *Target:* a measured savings number (and expansion-fidelity spot-check) replaces "~70-80%"; the dictionary stays only if measurement justifies its maintenance cost.

**Explicitly NOT fixing:** runtime macOS/Apple-Intelligence checks (document instead) · prompt-injection hardening of apfel input (local tool) · per-line `wc` micro-perf beyond the trivial reorder · marketplace packaging until distribution intent is confirmed (OQ1) · M5's multi-block subtlety beyond a doc note · SubagentStop wiring until intent is decided (OQ7).

**Definition of done:** `claude plugin validate` passes and runs in CI · fixture suite green (byte-identical code blocks, inline-span survival, indented fence, exit-code guards) with shellcheck · expansion visibly appears in a plain interactive session · wrapper produces compressed→expanded output end-to-end or is deleted · one dictionary source with a drift test · every command in CLAUDE.md/README runs as documented · README carries a measured savings number or none.

---

## 5. Task Plan

### Milestone 0 — Revival & safety net

| # | Task | Effort | Risk | Deps |
|---|------|--------|------|------|
| T0 | **Fix `plugin.json` author → object; make `claude plugin validate` pass** (C0) | **S** (one line + verify) | none | — |
| T1 | Fixture test harness for the hook (H5) | **M** | none | — |

**T0** — change `"author": "vliggio"` to `"author": {"name": "vliggio"}`; acceptance: `claude plugin validate .` passes and `claude --plugin-dir . --debug` logs `Registered 1 hooks`. This single line revives the entire product.
**T1** — commit `test/fixtures/*.jsonl` (single-line, multi-paragraph, fenced code, indented fence, inline-span, no-marker, multi-block) + `test/run.sh` invoking the hook with `APFEL` pointed at a stub; assert marker gating, prose integrity, **code-block byte-identity**, inline-span survival, and exit codes (0 always — covers H9/M6). The audit's repro harness is the seed. Gotcha: bash 3.2 on macOS.

### Milestone 1 — Correctness

| # | Task | Effort | Risk | Deps |
|---|------|--------|------|------|
| T2 | Fix segment split/reassembly (C1; +M7/M8/H10 fixture coverage) | **M** | medium, mitigated by T1 | T1 |
| T3 | Deliver expansion visibly via stdout `systemMessage` (H1) | **S** | low | T0 |
| T4 | Fix or delete `faa-wrap.sh` (H2, H3) | **M** | low | T2, OQ3 |

**T2** — replace in-band line-tagging with record-based processing (awk emits `\x1e`-separated typed records; consume with `while IFS= read -r -d $'\x1e'`, bash-3.2-safe) or a single-awk dispatch; hard word-cap chunk flushes (not blank-line-only); optionally recognize indented fences; keep the backtick-protection clause. Acceptance: all T1 fixtures pass. Gotchas: command substitution strips trailing newlines; macOS awk is POSIX.
**T3** — print `{"systemMessage": "━━━ faa-speak expansion ━━━\n<expanded>"}` (jq -Rs escaped) to stdout, exit 0; keep stderr copy for debug. Acceptance: expansion appears in a normal interactive session. Verify the current Stop-hook JSON field name against the hooks reference first.
**T4** — if kept: `claude --print --plugin-dir "$(cd "$(dirname "$0")/.." && pwd)" "/faa-speak $*"` (docs-confirmed headless invocation), preflight `claude`, fix the `-p` header, route output through the shared splitter, add `|| echo "$COMPRESSED"` fallback. Acceptance: README's exact example yields compressed→expanded output with an intact code block. If deleted: remove README:56-62, CLAUDE.md:49-50.

### Milestone 2 — High-leverage improvements

| # | Task | Effort | Risk | Deps |
|---|------|--------|------|------|
| T5 | Single source of truth for prompt + dictionary (M1, H10) | **M** | low | T1 |
| T6 | Docs truth pass: CLAUDE.md + README (H4, H6, M2, M7, M13, M14, doc Lows) | **S** | none | T2, T3 |
| T7 | Hook hygiene: `trap 'exit 0' EXIT`, jq preflight, `FAA_DEBUG`, hook `timeout` field, incremental emission, marker pre-check (H7, H9, M3, M6, M9, M10) | **S/M** | low | — |
| T8 | Measure the savings claim; decide the dictionary's fate (M15, H8) | **M** | none | T4 |

**T7 detail:** the `trap 'exit 0' EXIT` single-handedly closes H9, M6, and the "always exits 0" contract violation; add `timeout` in hooks.json (e.g. 30) and emit expansion incrementally (or per-chunk) so a kill preserves partial output; `command -v jq || exit 0`; `FAA_DEBUG=1` logs each early-exit reason; cheap `tail -c 4096 | grep -qF '<!-- faa -->'` pre-check.

### Milestone 3 — Quality & polish

| # | Task | Effort | Deps |
|---|------|--------|------|
| T9 | CI: `claude plugin validate` + shellcheck + T1 suite (C0-class regression gate) | **S** | T0, T1 |
| T10 | LICENSE file + `license` field in plugin.json (M11) | **S** | — |
| T11 | Low sweep: printf-over-echo, sed `g`, jq stderr capture, `APFEL` docs, trim-after-split, `LC_ALL` export, drop dead `matcher` | **S** | T2 |
| T12 | Distribution decision: `marketplace.json`, version floor/compat field, apfel install story (M2, M12) | **S** | OQ1 |

### Quick wins (do immediately, all S)

1. **T0** — one line revives the entire plugin. Nothing else matters until this lands.
2. **T7's `trap 'exit 0'` + jq preflight** — eliminates the stop-blocking race and broken-env noise.
3. **T3** — makes the feature visible for the first time.
4. **T10** — LICENSE file; **T6's** README install fix + apfel clone step.

---

## 6. Open Questions

1. **Audience:** personal tool or publishable plugin? Drives T10/T12, apfel packaging, and how much of M12 matters.
2. **Was stderr intentional** for a personal workflow (tmux pane, `--debug` runs)? If yes, H1 drops to Low and T3 becomes optional — the README should say so either way.
3. **Keep `faa-wrap.sh`?** Real niche, but it duplicates the hook with a second copy of everything. Keep only if `--print` usage matters; otherwise delete.
4. **Is compressed-primary UX acceptable?** Hooks cannot rewrite the assistant message; the user always sees compressed text first. If that defeats the purpose, the honest product may be the fixed wrapper or a plain "concise output" skill with no expansion machinery.
5. **What savings number justifies the mode?** T8 provides data; if telegraphic style alone achieves ~90% of the savings, the dictionary + four-copy sync burden may not earn its keep.
6. **Which Claude Code version tightened manifest validation?** C0 implies the plugin either never loaded or silently stopped loading after an upgrade — worth knowing which, since it decides whether a version floor (T12) or a CI gate (T9) is the primary defense.
7. **Should subagent output be expanded** (wire `SubagentStop`), or is main-loop-only intentional?
