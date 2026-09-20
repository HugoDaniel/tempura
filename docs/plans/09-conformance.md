# 09 — Conformance

Status: Active — 2026-09-19. Part of the [tempura plan set](README.md). Owns **P107**
(`conformance/`, `corpus/`) and the corpus discipline every other part follows. License
discipline lives here and nowhere else.

Five claims are gated, the ladder of [00](00-vision-and-scope.md): the writers are byte-exact
on their own output, content-exact on foreign files, essence-exact through the residue,
score-exact within pacer's grid, and deterministic native versus wasm. A sixth, the residue's
survival through foreign tools, is measured and logged, because no local oracle can assert it.

## Oracles

| Claim | Oracle | How it is used |
|---|---|---|
| the readers accept what the world writes | **foreign fixtures**: one `.mid` export from each DAW the user uses, OpenMPT's `mod2midi` of `impulse-04.it`, and a dozen wild `.it` modules of different provenance (IT 1.x–2.14, Schism, OpenMPT, ModPlug), committed when redistributable, else hash-pinned realism checks (it 08, midi 08) | `read` succeeds with no error-class diagnostic; rung 2 round-trip |
| the `.it` reader agrees with a mature implementation | **libopenmpt** (brew, test-time only, never vendored): `openmpt123 --info` reports duration, tempo and channel names | toleranced: duration within one IT tick; segment list equal; names equal |
| the `.mid` reader agrees with a mature implementation | **midicsv** (John Walker's `midicsv`/`csvmidi`, public domain, brew, test-time only): a `.mid` as one CSV row per event, and back. libopenmpt is **not** the `.mid` oracle: its `ReadMID` is compiled into tracker and fuzzing builds only and returns false in the library (`Load_mid.cpp:1416` at the pin, per the second review; the midi set's 08 relies on it, recorded in [11](11-demos-and-milestones.md)) | event lists equal after `tempura inspect --csv`; `csvmidi` of the CSV re-reads event-identical |
| the format tables are right | RP-001 and ITTECH.TXT restated in [05](05-smf-core.md) and [06](06-it-core.md); **hand-built fixtures** from in-test byte writers for every event kind, every header field, every pattern mask case | exact expectations |
| the IT walk is a player's walk | **hand-computed row maps** per timing corner ([06](06-it-core.md), phase 4); libopenmpt's duration; the OpenMPT wiki IT test cases that isolate timing (`PatternLoop`, `PatternDelays`, `TempoSlide`, and the rest of the timing subset), hash-pinned, fetched by script, never vendored; **batida's `Timeline.derive` goldens once batida T2 exists** (the cross-set gate) | row maps equal; duration toleranced |
| the grid contains every source | the exactness table of [03](03-time-model.md), enumerated | exact |
| tempura's positions land on pacer's | **pacer's own compiler**: every emitted position through `pacer.wasm`'s `evalTicks` on a probe score, every emitted skeleton compiled with zero errors (dev-dependency `file:../../pacer/npm/pacer`) | exact |
| the residue reconstructs the document | **self**: `dump(build(doc, kind)) ≡ doc` in the timeline tier, both kinds; the stale-hash paths against hand-edited files | form-equal; diagnostics equal |
| the residue is invisible to the format's own readers | libopenmpt loads a `.it` with the `TMPU` chunk and the message tail and reports the same duration and names as without; a `.mid` with `7D 'tem'` events reports the same | equal reports |
| edits are pure | **self**: `apply(plan(d, op))` on fixtures, plans as text | byte-equal |
| the vocabulary has no bare collisions | the **sibling manifests** in sibling checkouts | no `ambiguous_form` |
| the pacer schema copy is current | `../pacer/schema/pacer.sjon` when present | byte-equal |

Schism Tracker's `fmt/it.c`, `player/*.c` and `fmt/mid.c` (GPL-2) are read to cross-check a
rule when the specification and OpenMPT disagree; nothing is ported, and each consultation is a
comment citing file and line (the it set's discipline, it 09).

## The golden corpus

`corpus/<case>/` holds one of `doc.sjon` (a timeline document, possibly with an inline dump),
`song.mid` or `song.it` (a committed fixture), plus `times.sjon` (rows of seconds or ticks and
directives: `at`, `snap`, `plan <op>`, `export-score`, `timing`, `build <kind>`, `dump`), and
the generated `expected.sjon`. The runner (`src/corpus_runner.zig`, native) renders one
canonical text per case: the `TimeMap` echo (segments, meters, bars, sections, cues, lanes),
then per row the query's answer, the plan's actions, the exported text's hash and first lines,
the built file's hash, or the re-dumped document's timeline tier. `npm/tempura/test/corpus.test.js`
re-derives the same text from `tempura.wasm`. Native green + wasm green ⇒ byte-identical
answers, pacer's rule verbatim (`pacer/CLAUDE.md`, "The golden corpus"). `zig build corpus --
--update` regenerates; goldens are never hand-edited.

`times.sjon` has its own schema (`schema/tempura-corpus.sjon`), pacer's harness idiom: shape is
SJON's, sequence is the runner's, and the manifest stays out of the LSP project file because
it declares a `target` form ([01](01-part-map.md)).

Cases planned, each landing with its feature: `grid-table`, `positions-units`, `printer-rule`,
`tempo-three-conductors`, `tempo-us-vs-qpm`, `meter-change`, `loop-wrap-seconds`, `walk-*`
(one per timing corner), `smf-vlq-edges`, `smf-running-status`, `smf-smpte`, `smf-format0`,
`it-minimal`, `it-patterns-masks`, `it-passthrough`, `residue-smf-exact`, `residue-it-exact`,
`residue-stale-lane`, `residue-stale-conductor`, `residue-newer-version`, `residue-corrupt`,
`residue-tail-only`, `edit-*` (one per operation), `export-quintuplets`, `export-meter-6-8`,
`export-meter-unsupported`, `export-budget`, `export-512`,
`render-smf`, `render-it`, `diag-*` (one per diagnostic code), `examples-*` (every shipped
example is a symlinked corpus case, pacer 12 D1).

## Round-trip gates

- **Rung 1**: for every file the canonical writers produced (the corpus's `doc.sjon` cases
  built to bytes), `write(read(bytes)) == bytes`, both formats.
- **Rung 2**: for every foreign fixture, `read(write(read(f))) ≡ read(f)`: event by event for
  `.mid` (tempo map equal, foreign chunks preserved); field by field for the `.it` timing
  module with every pass-through region byte-equal.
- **Rung 3**: `dump(build(doc, kind))` timeline-tier-equal for every native corpus document,
  both kinds; the four reconciliation paths on hand-edited twins of the built files.
- **Fuzz**: `zig build fuzz` runs both readers, the VLQ decoder, the pattern unpacker and the
  residue unpacker on arbitrary bytes with a never-panic property.

## Determinism gates

- The corpus, native versus wasm (above).
- **Seams**: `seconds(tick)` at segment boundaries for a three-segment map against values
  computed by hand in the documented op order; the literal-rounding rule at half-way ticks;
  the floor-interval decimal rule against `pacer.wasm`.
- **Plans**: every `edit-*` case's actions are text, so a change in ordering is a diff.
- **Builds**: same document ⇒ same bytes, x86_64, aarch64, wasm32 (hashes in the golden).

## The measured, not gated

- **Residue survival**: per DAW and tracker the user uses, a file with residue is loaded,
  re-saved or re-exported, and re-read; the count of payloads that survive (essence, lane
  records, IT chunk, IT message tail) per tool and version goes in [04](04-residue.md)'s
  progress log. Repeated at every tag.
- **Foreign fixtures are personal.** A DAW export of the user's own piece and the impulsos
  module are realism checks logged by hash and outcome, never committed (pacer 06's rule);
  committed fixtures are hand-built or generated from CC0 material.

## CI shape

`zig build verify` = test + corpus + `node --test` (wasm parity, the pacer landing test and
the skeleton compile when `../pacer` exists) + generated-docs drift + the pacer-copy drift
(hermetic apart from the sibling checkout). `zig build conform` adds libopenmpt and the wiki
cases (brew deps and pinned downloads; a nightly job, not per commit).
`conformance/CHECKLIST.md` carries the manual gates: a built `.it` loads and plays in OpenMPT,
Schism and IT 2.14 in DOSBox with the residue attached (E0 and every tag); a built `.mid`
opens in each DAW.

## License discipline (the one place it lives)

| Source | License | Discipline |
|---|---|---|
| Impulse Tracker source and docs (`~/llm/repositories/impulsetracker`) | BSD-3-style (Jeffrey Lim, 2014; `LICENSE.TXT` governs, it 09) | portable; copyright notice in `THIRD_PARTY_NOTICES`; no-endorsement clause noted |
| OpenMPT (`~/llm/repositories/openmpt`) | BSD-3-Clause | portable with attribution: the history-block guard, the SMPTE division rule, the pattern packing scheme, the CP437 table, each with a source comment and a notice entry; libopenmpt binaries are test-time assets from brew, pinned by version in `conformance/PINS.md`, never vendored |
| Schism Tracker | GPL-2.0-or-later | **doctrine only, never port code**; cite file:line for behaviour claims |
| MMA RP-001 and the MIDI 1.0 specification | cited by document and section | the byte tables in [05](05-smf-core.md) are the minimal restatement needed to implement, in the plan's own words |
| OpenMPT wiki IT test cases | no explicit license | hash-pinned fetch script, never vendored |
| Theatre.js (`~/llm/repositories/theatre`) | Apache-2.0 | cited for its data model in [00](00-vision-and-scope.md); nothing ported |
| SJON | local | path dependency, like pacer |
| pacer | CC0-1.0 | `schema/pacer.sjon` copied verbatim (no attribution required, header names the source anyway); npm package as a dev-dependency of the tests |
| tempura itself | CC0-1.0 | pacer's dedication; decided at E0 |

## Risks / open questions

- **Tolerance calibration** for libopenmpt's duration report: a `.mid` is quantised into a
  tracker module by libopenmpt, so its duration carries that quantisation; the comparison is
  on segments and names, the duration window one tick.
- **The walk has no Zig oracle until batida T2.** Hand-computed row maps are small and
  fallible; the wiki timing cases are the arbiter and the batida gate is the eventual proof.
  Every walk corner that lands without a wiki case is marked `unverified-by-oracle` in the
  corpus manifest until one exists.
- **DOSBox and DAW checks are manual.** They gate tags, not commits; the checklist records
  the version and the outcome each time.
