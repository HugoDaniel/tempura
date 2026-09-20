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

## Status board

| Milestone | Item | Status |
|---|---|---|
| E0 | repo + reader spikes + carrier check + walk spike + the measure | ☐ |
| E1 | manifests, both cores, bridges, TimeMap ×3, dump/build, generated docs | ☐ |
| E2 | export-score, landing proof, timing, the studio provider | ☐ |
| E3 | native lanes, residue ×2 carriers, renderers, edit engine, wasm, npm | ☐ |
| E4 | studio pane, transport display, payload kind, 0.1.0 | ☐ |

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
