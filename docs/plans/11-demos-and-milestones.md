# 11 — Demos and Milestones

Status: Active — 2026-09-19. Part of the [tempura plan set](README.md). Owns **P109**
(`demos/`) and the execution ladder. Start here when picking up work.

## The ladder

| Milestone | Name | Exit criteria | Parts |
|---|---|---|---|
| **E0** | the spike | the repo exists with `zig build verify` green on the readers alone; both carriers proven invisible to the formats' own readers; the grid table asserted; a throwaway `export-score` of `impulse-04.it` through the IT walk loads in the studio and matches the TS importer's onsets; the premise measured (below); name, license and letter decided | P100 (reader half), P101 (reader + walk spike), a throwaway exporter |
| **E1** | the value | `dump`/`build` round-trip on every committed fixture (rungs 1 and 2, both formats); the four manifests, the project file, `validate`, `inspect`; the `(timeline …)` tier with bound lanes and the derived skeleton; the `TimeMap` for three conductors and `timeline`; generated `docs/timeline-language.md`; the grid, the spellings and the writers' layouts frozen | P99, P100, P101, P102, P103, P107 (round-trip gates), P108 (phase 1) |
| **E2** | the pacer door | `export-score` for every lane kind within the budget, every skeleton compiling through the real `pacer.wasm`, every position landing (the floor-interval rule); `timing` and the pstudio exact provider for `.it` and `.mid` (pacer 03 P3–P4, unblocked here); `at`; three provisional wasm exports | P106 (score, timing), P108 (phases 2–3) |
| **E3** | the superset | native lanes, phrases, clips, pass-through pacer forms; the residue in both carriers with the reconciliation table corpus-pinned (rung 3); `build` rendering native lanes to `.mid` and `.it`; survival measured per tool; the edit engine with plans as text; `tempura.wasm` and `npm/tempura` with the corpus parity walk; residue payloads, wasm exports and the diagnostic-code enum frozen | P104, P105, P106 (renderers), P108 (phases 4–5) |
| **E4** | the studio | pstudio's timeline pane over `'TPTL'` and `tpr_plan`/`tpr_apply` with the fenced-region model; the transport display from `tpr_at`; a packed demo with the `TMPU` payload after expansible-player X1; 0.1.0 tagged, the E3 freezes confirmed at the tag | P108 (phases 6–7), P109 |

Each milestone's demo is the proof; a milestone without its demo is not closed.

## E0, the spike, in detail

The set stands or falls on two things it can measure in a week: whether the carriers are
invisible to the players that matter, and whether a real piece has a timeline tier worth
carrying.

1. Create `~/Dev/tempura` from pacer's build graph (`test`, `wasm`, `corpus`, `fuzz`,
   `verify`), CC0, `../SJON` path dependency wired but unused. `zig build verify` green on
   zero features. Copy this plan set into `docs/plans/` (done 2026-09-19).
2. SMF reader spike ([05](05-smf-core.md) phase 1) and IT header-orders-patterns reader
   spike ([06](06-it-core.md) phase 1) on hand-built fixtures; the grid table test
   ([03](03-time-model.md) phase 1).
3. **The carrier check.** Take three wild `.it` modules, append a `TMPU` chunk and a message
   tail by hand; load each in libopenmpt (`openmpt123 --info`), OpenMPT, Schism and IT 2.14
   in DOSBox; record: loads, duration unchanged, message shown, re-save keeps the tail, drops
   the chunk. Take one export from each DAW the user uses, insert a `7D 'tem'` event at tick 0
   of track 0; reopen in the DAW; re-export; record what survives. Both tables go into
   [04](04-residue.md)'s progress log and decide whether the essence needs a size split.
4. **The walk spike.** A throwaway `timeline` and `export-score` (transport, tempo segments,
   order cues, note triggers only) over the IT walk; insert the `impulse-04.it` skeleton into
   the studio through "Load skeleton text…" (pacer `plans/it/03` Phase 2); compare against the
   TS importer's output: onsets equal where the approx importer is right, the bar 41 anchor
   present, and the odd-row swing from its 1024 `Axx` visible in the exact onsets (pacer 03
   Phase 3's realism check, done here).
5. **The measure.** Read the impulsos piece (`~/Dev/2026_impulse/live.score.sjon` and the
   WGSL `const B_*` knobs, 48 on 2026-08-28 per midi 10) and classify each beat-level fact
   of the piece as (a) structure a `section` or `cue` carries, (b) an event or a step a bound
   lane carries, (c) a curve or a formula only pacer's tier says. Record the three counts in
   the decision log. If (a) is empty, the residue and the edit engine are re-scoped to E4 and
   E1–E2 ship as the two format cores plus the exporter, which are useful alone; if (a) is a
   third or more of the timing facts, the ladder stands.
6. Decide the name (tempura stands unless the check on `PATH` fails), the license (CC0), the
   milestone letter (E).

## Demos (P109)

| Milestone | Demo | Artifact |
|---|---|---|
| E0 | `demos/e0-carriers/` | the two survival tables; the impulsos skeleton and its comparison; the knob census |
| E1 | `demos/e1-two-files-one-document/` | `impulse-04.it` and a DAW export of the same piece dumped, each a document with a derived skeleton; a hand-written native timeline validated in the LSP; `tempura timeline` of all three printing the same tempo map |
| E2 | `demos/e2-exact-import/` | the studio importing the `.it` through the exact provider, its trigger lanes flashing a quad on the snare channel (batida T2's demo, done from here); the same for the `.mid`; the floor-interval landing proof in the node test output |
| E3 | `demos/e3-one-file/` | a native timeline with sections, a curve lane with springs, a query lane, built to a `.mid` that plays in a DAW and dumps back essence-exact; the DAW quantises the rendered notes, the re-dump shows the bound lane and the `residue_stale` list; the same document built into `impulse-04.it`, reopened in OpenMPT with the message tail visible, re-saved, re-dumped with `residue_partial` naming what the tail lacks |
| E4 | `demos/e4-studio/` | a short recording of pstudio: the timeline pane over an imported `.it`, a section dragged, the score's fenced region regenerated, the cube following; `e4-packed/`: a `.png` with `PNGB` + `PACR` + `TMPU` |

The December Inércia demo (the launch set, `~/llm/plans/hugodaniel.com/PLAN-schedule.md`) is
the target composition for E2 and E3: the tracker module conducts, pacer plays the exported
score, and the piece's sections and cues live in the module's own file.

## Sequencing against the family

- **No upstream dependency.** tempura depends on SJON (shipped) and consumes pacer's schema
  and text. It waits on nothing. The one cross-set gate is E4's payload kind (expansible-player
  X1's envelope); everything else ships without it.
- **It unblocks finished work.** pacer's it-wave left the exact-provider branch of pstudio's
  importer blocked on batida T2 and the audio bus on batida P40 (`pacer/plans/it/00-strategy.md`,
  Wave B). E2 exercises the provider branch for `.it` and `.mid` with no batida: the IT walk
  is here. The audio bus stays batida's. The midi set claimed the same for `.mid` alone
  (midi 10); with tempura the two providers are one.
- **The pinned demoscene order is untouched**: `pacer Wave A → T0 → T1 → T2 → pacer 03 P3–P4
  → batida P40 → pacer 04 → T3 → T4` (`~/llm/plans/README.md`, "The demoscene audio stack").
  tempura's E2 lands "pacer 03 P3–P4" early, and batida T2's `Timeline.derive` becomes a
  differential gate for the walk rather than the provider's source. tempura's natural slot is
  **before batida T0**: E0–E2 are two readers, a walk and an exporter, and E2 hands the studio
  a tracker and a DAW as front-ends whether or not batida's player exists by November.
- **Cross-set notes to file at E0**, on the sibling sets' side, none blocking:
  1. **it**: the `midi` and `it` core-tier manifests get one owner; batida adopts
     `tempura/schema/it.sjon` or tempura re-points to batida's once it exists; the `:raw`
     opaque-body key; the `Cwt/v` nibble `0xB` split (batida `0xB000–0xB7FF`, tempura
     `0xB800–0xBFFF`); batida T2's `Timeline.derive` goldens as the walk's oracle.
  2. **midi**: the same manifest rule for `schema/midi.sjon`; midivia's `note` verb spelled
     `midi/note` in mixed projects or renamed; the `7D 'tem'` envelope with `kind 04`
     reserved for the easing hint; three corrections found while writing this set (below).
  3. **pacer**: nothing to ask today; `(meter :at …)` stays parked (08).
  4. **animader**: nothing; tempura is not a `'PACW'` emitter and logs no session records.
- **Corrections to the midi set, applied there on 2026-09-20**: (i) midi 05's
  grid table lists 32nds at 480 PPQ as exact; tick 60 is not a multiple of 8, so they round
  ([03](03-time-model.md)); (ii) midi 05's `:bpm = 60 000 000 / us · (4 / d)` is inverted;
  pacer's beat is a `4 / d` note so the factor is `d / 4` ([08](08-export.md)); (iii) midi 05's
  "shortest round-trip decimal" for positions floors one tick short for about six percent
  of the ticks in a bar (a quintuplet `1.4b` is the smallest musical case; some of midi 05's
  own "exact" 480 PPQ ticks are among them); the shortest decimal in pacer's floor interval
  is the safe print ([08](08-export.md)); (iv) midi 03 lists "a status byte in a meta
  payload" as a reader diagnostic, which would refuse `FF 51 03 07 A1 20`, ordinary 120 BPM;
  payload bytes are arbitrary ([05](05-smf-core.md)); (v) midi 08 uses libopenmpt as the
  `.mid` oracle, whose `ReadMID` is compiled out of the library build at the pin
  ([09](09-conformance.md)).

## Effort

Sized in bounded sessions of the family's kind (one phase per context window, reds first):

| Milestone | Sessions | Calendar, one person part-time |
|---|---|---|
| E0 | 3–4 | 4–5 days |
| E1 | 12–15 | 3 weeks |
| E2 | 6–8 (of which 2 in pstudio) | 1.5–2 weeks |
| E3 | 14–18 | 4 weeks |
| E4 | 8–10 (of which 5–6 in pstudio) | 2.5–3 weeks |

Roughly three months to 0.1.0, with E2 (the studio imports a tracker module exactly) about
four weeks in. The uncertain items are E0's survival tables and E3's edit engine over inline
IT tiers; everything else is the family's known loop (schema → diagnostics → derive → corpus
→ npm parity).

## Decision log

- 2026-09-19 — Set created. Decisions frozen at creation, each owned by its doc: (1) tempura
  is the arrangement tier and never evaluates a value at `t`; pacer plays the exported score
  (00). (2) One grid, `TPQ = 64 · PPC` per quarter note; literals round to nearest, clocks
  floor; the printer spells `bar`, then `q` when `9009 | k`, else `t` (03). (3) The file
  tiers are the sibling sets' vocabularies hosted by namespace, the midi one core-tier only;
  one owner per manifest; pacer's manifest is copied verbatim and drift-gated; pacer forms
  pass through export untouched (02). (4) Content has one home; bound lanes derive from the
  file, native lanes live in the document; rendered lanes carry a hash; the reconciliation
  rule: the file's native content is the truth for what the file can say, the residue for
  what it cannot, the hash for whether they agree (04). (5) One SMF carrier (`7D 'tem'`
  sequencer-specific events) and two IT carriers graded by survival (the `TMPU` trailing
  chunk, the message tail); midivia's `pau` hint is read (04). (6) Tempo is a step function;
  `:us` and `:qpm` are both exact in text and both allowed, exclusively; the origin table is
  exact integers when every tempo is integral and f64 in one documented order otherwise
  (03). (7) Every edit
  is an SJON edit action with layout preserved; no in-memory authority; a move is a
  `set_keyword` when order allows and remove + insert otherwise (07). (8) Export prints the
  shortest decimal in pacer's floor interval, verified through `pacer.wasm` (08). (9)
  Renderers sample `hold` and `linear` only; other easings render as steps and are restored
  from the essence (08). (10) `itf/` restates the it set's timing subset with PCM and
  instruments opaque behind `:raw`; the walk is it 06's timing state machine (06). (11) The
  midi-set corrections above are recorded here, not applied there. (12) The name, license
  and letter are confirmed at E0.
- 2026-09-19 — Parked: `:ramp` on `tempo-point`; `--full` IT materialisation; `materialize`
  for IT lanes; a `tempura/score-v1` lowering hook emitting pacer forms; a text-meta carrier
  for SMF; a `move` edit action ask to SJON; `(meter :at …)` for pacer; cross-kind builds;
  `--sample-with-pacer` for rendering named easings; MIDI 2.0 Clip Files.
- 2026-09-20 — Second review pass (against pacer `63cd0ed`, SJON `5c9a0a33`, OpenMPT
  `6ef84997` fetched remotely by the reviewer), thirteen findings, all taken: (13) the segment
  table takes pacer's seconds-and-rate shape, the microseconds shape misses a boundary tick
  (03); (14) a SMPTE file is one 120-qpm segment and its tempo events are ignored for timing
  (03, 05); (15) payload bytes are never status-checked (05); (16) residue hashes are over
  tempura ticks and the conductor record covers `division`, `format` and tempo events on
  every track (04); (17) trigger onsets aggregate after grid conversion (08); (18) a
  polyphonic lane renders across channels with a `--voices` cap (08); (19) sample extents
  dispatch on encoding, ADPCM included (06); (20) the walk carries `T00`/`S00` memories and
  the `SD0` and out-of-range delay rules (06); (21) `insert-meter` respells `bar`/`b`
  literals in the same plan (07); (22) `clip` gains `:length` so a split is expressible
  (02, 07); (23) `tpr_attachAnchor` ships at E3 (10); (24) equal-run collapse keeps a linear
  plateau's endpoints (08); (25) `midicsv` is the `.mid` oracle, libopenmpt the `.it` one
  (09). Two numbers corrected: a 32nd is `TPQ / 8` (03) and the out-of-range tempo example is
  `600 qpm` in `[12 8]` (08). Corrections (iv) and (v) to the midi set added above.

- 2026-09-20 — Applied the three midi-set corrections above to midi 05, its repeated grid
  claim in midi 00, and the conformance gates in midi 08; recorded the change in midi 10.
  This closes creation decision (11)'s deferred application. Changes remain uncommitted.

- 2026-09-20/21 — **Implementation rulings (E0–E3).** Every ruling the execution ledger
  holds, copied here as the decision log of record, in the order they were made. The two
  USER lines are the user's own instructions and are copied verbatim. Each ruling names what
  it would cost if it turns out wrong, which is the form the ledger keeps.

  1. Work happens on branch `impl/e0-e3` in the repo directory, not a worktree — the build
     depends on `../SJON` as a sibling path and a worktree elsewhere would break it; the repo
     was empty apart from docs — costs nothing if wrong (branch is local, reversible).
  2. **pstudio is not a host** (memory `pstudio-not-a-target`, user 2026-09-20). Dropped:
     `timingData`/`timing` verb/`tpr_timing`, the studio provider (10 touch point 1), the
     timeline pane and transport display (touch points 2–3), E4's studio demo. Hosts that
     count: CLI, npm/tempura + tempura.wasm, expansible-player `TMPU` payload (registry row
     only; X1 not here), animader piece format. — cost if wrong: TimingData is ~1 session to
     add.
  3. E0's measured items (DAW/tracker residue survival, the impulsos measure) cannot run
     here: no openmpt123/midicsv/DAW, no `2026_impulse` piece, no wild fixtures. They are
     recorded as unmeasured with the procedure kept (`demos/e0-carriers/README.md`). All
     conformance oracles beyond self-consistency are hand-built fixtures; `zig build conform`
     skips with a reason. — cost if wrong: none to code; the survival claim stays unmeasured.
  4. Parallel implementers are allowed for parts with disjoint directories and no shared
     file edits (the plan's layering makes P100/P101/P103.1/P99 leaves). Parallel
     implementers DO NOT commit; the controller commits per part after each returns. Only one
     agent per wave may edit build.zig/src/root.zig (named in its brief). `src/Diag.zig` is
     append-only; an agent re-reads before appending. — cost if wrong: a clobbered edit shows
     up in review.
  5. One shared diagnostic enum `src/Diag.zig` (`Code = enum(u16)`, append-only, seeded in
     Task 1 with every code the plans name) rather than per-part enums, so the `'TPDG'` blob
     and the audit script have one source. — cost if wrong: renumbering before E3.
  6. Each part directory has an aggregator `src/<part>/<part>.zig` re-exporting its files and
     a `test {}` block; `src/root.zig` imports one file per part; `zig build test
     -Dtest-root=<file>` runs a subtree without editing root.zig. — cost: none.
  7. **The 0.1.0 tag is left to the user** (a release signal); the code reaches E3 with the
     freezes documented.
  8. Layering inside P103/P102 — `time/Pos`, `time/Grid`, `time/TimeMap` depend only on Diag
     and are imported by `doc/` (the printer needs the bar table to spell `Nbar`);
     `time/derive` and `time/Playhead` import `doc/`. The plan's "P103 ← P102" holds for the
     derive/Playhead half. — cost if wrong: an import cycle, caught at compile.
  9. Task 8 (P102) is split: 8a native documents (Doc, fromSjon, toSjon/print, resolver), 8b
     the two bridges + the skeleton derivation, sequential in one directory.
  10. The printer's `q` spelling is the EXACT terminating decimal of `k/TPQ` (the brief's
      reading of plan 03's "shortest decimal that round-trips … at most 10 fractional
      digits"), not the shortest decimal that merely rounds to `k`. Frozen at E1 with the rest
      of the rule. — cost if wrong: dumps print a few more digits than strictly needed; never
      a wrong tick.
  11. System common/real-time bytes inside a track are tolerated (skipped by their known data
      lengths with one `smf_status_invalid` warning each; the track continues); only a data
      byte with no running status aborts. Plan 05 says those bytes "do not update running
      status" and the reader keeps what it parsed. — cost if wrong: a foreign file with stray
      clock bytes yields a few more events than a strict reader would.
  12. Plan drift ([09](09-conformance.md) and [01](01-part-map.md) say the corpus manifest
      collides on `target`; it is `timing`) is corrected by a dated note at Task 19, not
      then. `:range` lives in the `curve` variant only (accepted deviation from plan 02's
      prose). — cost if wrong: one key on notes lanes. *(Both corrections are appended in
      those two documents, dated 2026-09-21.)*
  13. A bar line past the bar table is still a bar line — `isBarLine` extrapolates the last
      meter like `tickFromLiteral(.bar)` does, so `spell` and `parse` agree past `:length`.
      — cost if wrong: none (positions past length are transient while a default length is
      computed).
  14. Task 10 split into 10a (runner + fixture generator + format/walk cases; runs now, in
      parallel with 8a) and 10b (document/time cases after Task 9).
  15. A `Cxx`/`Bxx`+`Cxx` row past the target pattern's end lands on row 0 of the TARGET
      pattern (IT/OpenMPT behaviour), not the next order — fixed in walk.zig by Task 10a and
      pinned by `walk-cxx-past-end`. — cost if wrong: one row map differs on malformed break
      rows.
  16. Task 8b starts in parallel with 8a's review; it builds bridges/skeleton in NEW files
      first and touches fromSjon/toSjon only for the anchored hooks, re-reading before each
      edit.
  17. Task 9 (derive + Playhead) starts against 8a's Doc, in parallel with 8b; bound-lane
      onsets go through 8b's bridges when their files exist, else a marked hook with a test to
      fill when the controller says 8b landed. — cost if wrong: one rebase of derive.zig onto
      8b's API.
  18. `length_lit` is informational, excluded from `Doc.eql`; the canonical printer
      normalises `:length` (plan 03: only the printer is constrained). — cost if wrong: an
      authored `512q` prints as `128bar`, never a wrong tick.
  19. A `(rung1 :ok false)` line in a golden on a fixture whose harness explains why is a
      pinned fact, not a failed gate; the corpus verdict is byte-equality with the golden.
  20. Task 14 (edit engine, native) starts in parallel (src/edit/ only), Select over Doc
      directly, hooks into Playhead/8b optional and last. — cost if wrong: one rebase onto
      8a's fix.
  21. The document layer owns the conductor rules and the default-length rule; `derive` calls
      fromSjon's `smfConductor`/`itConductor`/`contentEnd` and an agreement test pins
      `fromSource`'s map == `derive`'s map for the same document. Where they differed,
      fromSjon's reading stands except the overflow guard (added to fromSjon). — cost if
      wrong: one function to move later.
  22. Task 15 split into 15a (reconcile + dump pipeline + check-residue) and 15b (renderers +
      build pipeline; after Task 12 lands in src/export).
  23. The document layer owns the map for edits too — `fromSjon.mapOf(gpa, doc)` (single
      owner, conductor branch included) feeds `plan`; `planWith(…, map, …)` for callers
      holding the map. `plan`'s signature unchanged (Task 16 in flight). — cost if wrong: one
      helper to move.
  24. **USER (2026-09-20)**: reduce parallelism — at most 4 subagents at once (reviewers
      count). In-flight agents finish; no new dispatch until ≤ 4 are running. Priority order
      for the queue: fix rounds and re-reviews first (they close tasks), then reviews, then
      new implementers on the critical path (15b → 17 → 18 → 19).
  25. **USER (2026-09-20)**: "zig test just eats all my memory". Cause: parallel Debug test
      builds. Actions: stopped Task 16 (at scaffolding) and Task 15a (mid reconcile.zig) to
      reach the cap of 4 — their partial files stay uncommitted for the re-dispatch, which
      must read them first; added `tools/zt` (mkdir lock + `-j4`) and told the four running
      agents to use it; the global constraints now require it.
  26. `examples/native.sjon` must compile through pacer (Task 12 concern 4: `glow` arity 1
      against a 3-component keyframe — the plan's example is inconsistent); Task 17 fixes the
      example (arity 3 or scalar keyframes) and adds the compile check to the node test. —
      cost if wrong: an example edit.
  27. Any edit to a cell in a pattern played more than once is `edit_pattern_shared` unless
      `:allow-shared` (plan 07's diagnostics table); with it, every occurrence changes. —
      cost if wrong: an extra flag on tracker edits.
  28. Task 19 split — 19a (the `src/fuzz.zig` harnesses, `docs/residue.md`,
      `THIRD_PARTY_NOTICES` per-item entries, `conformance/{CHECKLIST,PINS}.md` and the
      conform script without the build.zig verb) then 19b (demos, examples as corpus cases,
      README, CLAUDE.md, the `conform` verb, these dated plan notes, final verify).
  29. **USER (2026-09-21)**: increase parallelism again, but zig tests with parsimony. Cap
      lifted (judged per wave); `tools/zt` stays mandatory (one build at a time, `-j4`);
      briefs now say: subtree tests while iterating, whole tree plus `verify` once before
      reporting.

- 2026-09-21 — **Filed and routed at the E3 close.** Findings the implementation raised that
  are not rulings: each is a real divergence between this plan set and the code, recorded
  here rather than fixed under a closing task.

  - **`:cc` on a native curve lane** is accepted by `schema/tempura.sjon` and DROPPED by the
    loader. `build --cc N` plus `render_cc_missing` is the faithful reading today: a curve
    lane with no controller rides in the residue alone. Either the key becomes load-bearing
    per lane or the manifest loses it. **Closed** 2026-09-21 in the backlog pass below: the
    key is load-bearing per lane.
  - **Five it-manifest asks** from the bridge work: the reserved header fields, the MIDI
    macro binary blob, the ADPCM sample encoding, an unused-channel marker, and a channel
    prefix above 15. None is implemented; `schema/it.sjon` is the owner when batida decides
    one.
  - **`it.choose` prefers a readable message tail over a NEWER-version `TMPU` chunk.** Plan
    04's rule 5 lists only absent, corrupt and truncated. Pinned by
    `corpus/residue-newer-version/` and recorded in [04](04-residue.md)'s progress log.
    **Closed** the same day by the ten-defect wave below (item 4): the rule gained the case,
    in `docs/residue.md`'s words, and plan 04's rule 5 now says so.
  - **The phrases→patterns structured branch is not implemented.** A clip is always
    flattened into rows when a `.it` is rendered; the essence keeps the phrase and the clip,
    so a dump restores the structure. What is missing is the `.it` holding a phrase AS a
    reused pattern.
  - **A conducted anchor BY REFERENCE derives length 0.** When the document names a
    conductor it cannot read, the derived length is zero rather than a diagnostic. The
    by-reference path is what `tempura inline` exists to avoid, and a browser host meets it
    on every anchor, so the missing diagnostic is worth having.
  - **The two renderers' tie rules differ** — where the SMF renderer and the IT renderer
    break a tie between two events at one position is not the same rule. Neither is wrong;
    they are not stated as one.
  - **A newer IT `TMPU` payload is kept out of `foreign` by the reader**, so a later `build`
    cannot re-emit it. Routed and pinned by a CLI test rather than the corpus.
  - **`export-schema` does not compose the project on SJON 1.4.2**, so
    `docs/timeline-language.md` is rendered by concatenating the manifests' own
    `:description`s. The drift gate is unaffected.

- 2026-09-21 — **Filed and routed at the whole-branch review's fix wave.** Two more
  divergences, and the close of one filed above.

  - **A meter whose bar does not divide 64 rows is a gap in the IT renderer's pattern
    sizing.** `src/export/render_it.zig:78` fixes `rows: u16 = 64`, which is four bars of
    `[4 4]` at speed 6 and 24 ticks to the quarter — so a `[3 4]` or a `[7 8]` document
    renders patterns whose bar lines do not fall on a pattern boundary. `examples/tracker/`
    keeps `[4 4]` on purpose and says so in its README and in both of its documents; what
    is missing is the renderer choosing its row count from the meter in force.
  - **`conform` runs the oracle SCRIPT and not plan 09's comparison.** `zig build conform`
    invokes `conformance/conform.sh`, which checks tempura's readers against libopenmpt and
    midicsv over the committed fixtures and the fetched OpenMPT wiki cases. The `inspect
    --csv` ⇄ midicsv row comparison plan 09 describes has no implementation: the verb does
    not even hand the script the built CLI (`addArtifactArg`), so nothing in the tree could
    run it. The script's header now says so rather than describing the intent.
  - **Closed** — "A conducted anchor BY REFERENCE derives length 0", filed above, is fixed.
    `doc/fromSjon.zig`'s `conductorOf` is one owner for plan 03's rules 2 and 3 over an
    inline tier and over the anchor's own verified bytes alike, `Doc.conductor_bytes`
    carries the file with the document so `mapOf` and `time/derive.conduct` cannot answer
    differently, and a conductor nobody could read is `anchor_unavailable` as an ERROR with
    `export-score` refusing on it. Pinned by `corpus/tempo-by-reference-conductor/`, whose
    `(echo …)` header is byte-identical to the three `tempo-three-conductors*` cases'.

- 2026-09-21 — **Ruled at the final review's fix wave: an SMF binding names a SET of
  channels on one track.** A native `.mid` lane whose notes name several channels writes
  one lane record per channel, and a DAW edit to one of them bound the lane at that
  channel alone, leaving the other channel's notes in the tier and in no lane. The lane
  now binds at its records' track and at the union of their channels — `:ch 2` stays a
  single, `:ch [1 2]` is several (`Doc.Channels`, `midi-channels` in the manifest) — and
  every record of a binding lane reports `became_bound` with its own hash verdict, so the
  consumption never takes a bound lane's untouched channel out of the tier. The record
  wire is unchanged: a record names one channel, and a set encodes as its lowest. Plan
  04's log has the detail; `docs/residue.md` states the rule;
  `corpus/residue-stale-lane-partial/` pins it. A native lane's `:ch` is NOT read as its
  notes' default (`fromSjon`'s `default_note_ch` is 0 by ruling) even though `note`'s
  manifest description said it was — the two descriptions (`note :ch`, `lane :ch`) now
  say what the ruling says, and the behaviour is unchanged.

- 2026-09-21 — **The final review's ten defects, fixed in one wave** (reviewed range
  `22037391…5533a02`; "NOT READY for 0.1.0"). Every one reproduced before it was touched;
  each fix is one commit, and each is pinned by a test that fails without it.
  1. **Rebuild duplicated native notes** (P1) — rule 2's "consumed" made literal:
     `reconcile.consumeSmf` / `consumeIt`, `render_smf` onto the empty named track;
     `build → dump → build` is byte-identical in both kinds. `pipeline.zig`'s fixed-point
     tests; `(consumed …)` in six goldens. Plan 04's log has the detail.
  2. **A partial DAW edit lost the lane's other channels** (P1) — an SMF binding is a
     channel set, `:ch [1 2]`; the ruling above. `corpus/residue-stale-lane-partial/`.
  3. **SMPTE conversion changed the wall clock** — `Division.tempoOnGrid`, one seam beside
     `pulsesPerQuarter`, used by the writer and the `midi/` bridge; `fromSjon.smfConductor`
     reads the same constant. `corpus/smf-smpte/` re-pinned with `(dump)` and `(build)`.
  4. **A newer Binary IR wire version was detached and then replaced unasked** —
     `essence.newerWire` read off the header before the tier is printed; `newerSmf` /
     `newerIt` answer envelope OR wire; `smf.attach` replaces its own version's payloads
     rather than stacking; `it.choose` gives the tail a chunk of either unknown version,
     closing plan 04's rule-5 note.
  5. **IT MIDI macros erased silently** — `(it/midi (macro sf0 "…") …)` round-trips the
     4896-byte block (`Module.midi_config_bytes`, `it_midi_macro_invalid` appended as code
     88). `corpus/it-midi-macros/`.
  6. **A valid large clip crashed selection** — `Select.clipWindow` is the derivation's
     saturating window, pinned at the ceiling; `test_support.Reloaded` applies a plan and
     reloads the result, the step the review said was missing.
  7. **`insert-tempo` / `insert-meter` landed out of order** — `insertRootInOrder`; an
     occupied tick is refused with the code the reload would raise.
  8. **`resize` accepted a forbidden overlap** — through the same `refuseOverlaps` a move
     uses. And a string where an op wants a tick is `sjon_diagnostic`, not tick 0.
  9. **wasm exported the placeholder score** — `tpr_exportScore` refuses as the CLI does,
     said in `'TPDG'`; a node test loads `conducted-absent.sjon` and attaches the file.
  10. **`export-score -` read stdin twice** — `Ctx.loadDocFrom`; the golden script can pipe
      (`export-score-stdin.txt`). No other verb double-read.
  `npm run lint` is clean again (it blocked the publish hook). `tools/zt verify` green on
  the merged tree; `demos/e3-one-file/` regenerated by the CLI's own commands.
  **Filed, not changed:** `tempura inline` inlines a residue-carrying file's carrier events
  as `sequencer-specific` hex and consumes nothing, so a by-reference document over a file
  tempura built would, once inlined, rebuild the lane beside its rendering — `inline` wants
  the same reconciliation `dump` runs; a macro slot holding a byte outside printable ASCII
  is not spelled and rebuilds empty (`it_midi_macro_invalid` says so), and bytes after a
  slot's NUL survive the bytes path but not the text path.

- 2026-09-21 — **The backlog pass over "Filed and routed at the E3 close".** Each open item
  re-checked against the tree after the ten-defect wave; `it.choose` was already closed by
  it (marked above), the phrases→patterns branch is unchanged and stays a design job (plan
  08's rule, the meter-sizing gap folded in), and two are closed here.
  - **A `nudge` with an absurd count hung rather than refused** — never in this ledger
    before today. The count narrows to an `i32` and `ops_quantize.nudged` walks grid lines
    one by one, about 4 µs a line per target: 1,000,000 sixteenths took 3.9 s, 20,000,000
    took 76 s, and the 2,147,483,647 the field admits is hours. `Op.Delta.max_steps` (65536,
    either way) is the walk's bound, refused by name where the count is read
    (`sjon_diagnostic`, as every number no field can hold). The closed form — whole bars
    jumped through the bar table, the meter past the map's end one repeating window — would
    make any count legal and is the follow-up if a real edit ever wants more than 4096 bars
    of sixteenths.
  - **`:cc` on a native curve lane is load-bearing** — plan 08's own rule ("`--cc` or the
    lane's `:cc`"), which the schema accepted and the loader dropped. `Lane.cc` is read by
    `fromSjon` (one reader, `ccAddress`, for the bound address and the native key), printed
    by `toSjon`, compared by `Doc.eql`, and `render_smf` renders onto it ahead of `--cc`,
    which now reaches only a lane that names none — so two native curves no longer collide
    on one controller of channel 0. A `[msb lsb]` pair on a native lane is kept but not
    written (`render_cc_missing` says so; `--cc` does not stand in for what the author
    named), and `materialize` keeps `:cc`, so a materialized curve rebuilds onto the
    controller it came from. `corpus/native-curve-cc/` pins it. Still dropped on a native
    lane: `:bend`, `:pressure` and `:velocity`, surfaces no renderer writes.
- 2026-09-21 — **The Zig mastery wave** ([12](12-zig-mastery.md)): the tree audited
  against `~/llm/mastery/zig/` and brought to it — an `invariants()` on every core value at
  its write and read sides, every production function under 70 lines, every line under 100
  columns, arena/gpa allocator names, bounded loops, a proof on every `catch unreachable`,
  a `FailingAllocator` sweep on every allocating entry point, and the fuzz gate carried on
  through `derive`, the playhead and the score exporter. Fifteen defects in shipped code
  came out of it and are fixed with tests, three of them reachable from a document: the
  integer tempo accumulator trapped `fromSource` on `:qpm 1e-30`; a refused meter `[4 17]`
  reached `Grid.beatTicks` in the IT renderer through `tpr_build`; a `:qpm 1e300` overflowed
  the score's bpm spelling. The wire surfaces, the corpus and the CLI goldens are
  byte-identical, and the wasm is 10 KB smaller (93% of its ceiling to 92%). Plan 12 lists the follow-ups; one is a ruling for plan 10 — `tpr_build`
  builds a document that loaded with errors where the CLI refuses.

## Status board

| Milestone | Item | Status |
|---|---|---|
| E0 | repo + reader spikes + carrier check + walk spike + the measure | ☑ code — the measured items UNMEASURED |
| E1 | manifests, both cores, bridges, TimeMap ×3, dump/build, generated docs | ☑ |
| E2 | export-score, landing proof, timing, the studio provider | ☑ minus pstudio |
| E3 | native lanes, residue ×2 carriers, renderers, edit engine, wasm, npm | ☑ |
| E4 | studio pane, transport display, payload kind, 0.1.0 | ☐ minus pstudio |

**2026-09-21 (Task 19, E3 close)** — what each row above means. The "What's next" line
below this board predates this entry.

- **E0 ☑ code, UNMEASURED gates.** The repo, the build graph, both reader spikes and the
  grid table landed and are superseded by the full cores. The name (tempura), the license
  (CC0-1.0) and the milestone letter (E) are confirmed. **The carrier check (step 3), the
  walk spike (step 4) and the impulsos measure (step 5) are UNMEASURED**: no
  `openmpt123`, no `midicsv`, no OpenMPT, no Schism, no DOSBox, no DAW, and the
  `2026_impulse` piece is not on this machine. Nothing was estimated and no conclusion was
  drawn from an unmeasured number — the ladder was built on the design rather than on the
  census. The two tables, the procedure and the honest statement of that are in
  `demos/e0-carriers/README.md`; the log of record is `conformance/CHECKLIST.md`; the dated
  survival table is in [04](04-residue.md)'s progress log. The walk spike's studio half is
  moot: pstudio is not a host.
- **E1 ☑.** Four manifests plus the harness one, the project file, both format cores with
  their pass-through regions, the two bridges and the derived skeleton, `TimeMap` for all
  three conductors, `dump`/`build`/`validate`/`inspect`/`timeline`, generated
  `docs/timeline-language.md` drift-gated by `verify`. Rungs 1 and 2 hold on every committed
  fixture. The grid, the spellings and the writers' layouts are frozen.
  `demos/e1-two-files-one-document/` is the demo, with one substitution: the piece is a
  shipped example rather than `impulse-04.it` and a DAW export of it, because foreign
  fixtures are personal and there is no DAW here.
- **E2 ☑ minus pstudio.** `export-score` for every lane kind within the budget, every
  skeleton compiling through the real `pacer.wasm`, every printed position landing on the
  tick tempura claims with a mutation test that fails on a one-tick error, `at`, and the
  wasm exports (26, not three provisional ones — E3's set landed early).
  **`timing`/`TimingData` and the studio provider are DROPPED, not pending** (the
  2026-09-20 ruling in the decision log above). `demos/e2-exact-import/` is the demo, with
  no studio at all: the landing proof's output, three shipped examples' scores through
  pacer's own CLI, and the trigger lanes evaluated.
- **E3 ☑.** Native lanes, phrases, clips and pass-through pacer forms; the residue in both
  carriers with the reconciliation table corpus-pinned; `build` rendering native lanes to
  `.mid` and `.it`; the edit engine with plans as text; `tempura.wasm` and `npm/tempura`
  with the corpus parity walk. Residue payloads, the `tpr_*` set, the three blob layouts and
  `Diag.Code` are frozen and append-only from here. `docs/residue.md`, `THIRD_PARTY_NOTICES.md`,
  `conformance/{CHECKLIST,PINS}.md`, the never-panic harnesses and the `conform` verb are in.
  **"Survival measured per tool" is the one exit criterion NOT met** — see E0 above.
  `demos/e3-one-file/` is the demo: essence-exact in both kinds, then a foreign edit
  simulated at the byte level and the `residue_stale` path walked. The OpenMPT re-save leg is
  UNMEASURED.
- **E4 ☐ minus pstudio.** The timeline pane, the transport display and `demos/e4-studio/`
  are dropped with pstudio. What remains of E4 is the **payload kind**: `TMPU` is reserved in
  expansible-player 02's registry with no handler in v1, and the packed demo waits on
  **expansible-player X1** assigning the envelope — nothing in tempura blocks it
  (`demos/e4-packed/README.md`). **0.1.0 is not tagged**: the tag is a release signal left to
  the user (ruling 7 in the decision log above), and the freezes it would confirm are
  documented.

## What's next

→ **E0 step 1**: create the build graph in `~/Dev/tempura` from pacer's and get `zig build
verify` green on zero features. Then step 2, the reader spikes and the grid table.

## Risks / open questions

- **Studio work competes with the launch calendar** (`~/llm/plans/hugodaniel.com/PLAN-schedule.md`):
  E2's touch point is small and lands the exact importer November's production wants; E4's
  pane is not small and lands only after the December demo unless the pane is what the demo
  needs.
- **Scope creep toward a DAW.** Every "could a lane hold audio" or "could phrases have
  sends" idea is a DAW feature; the answer is that pacer consumes events, keys, queries and
  formulas, and tempura arranges exactly those.
