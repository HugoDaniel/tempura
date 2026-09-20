# The Timeline as a Value — Plans Index

Planning set for **tempura** (`~/Dev/tempura`, cloned empty on 2026-09-19; remote
`git.hugodaniel.com/hugo/tempura`): the family's **timeline core**, a versatile timeline with
no UI. One SJON document, `(timeline …)`, is the authoritative arrangement of a piece in
musical time. Around it, four things in one Zig package:

1. **The document.** Tempo and meter maps, sections and cues, lanes of notes, keyframes,
   pattern queries and formulas, phrases placed as clips, pacer's controls passed through.
   Validated by schema, edited by structural actions, printed canonically
   ([02](02-timeline-schema.md)).
2. **The time.** One tick grid that contains SJON's and pacer's grid, every DAW's SMF division
   and Impulse Tracker's tick, exactly; a derived `TimeMap` for three kinds of conductor: the
   document's own tempo points, a `.mid`'s tempo events, a `.it`'s timing effects walked by
   the tracker's own state machine ([03](03-time-model.md)).
3. **Two subsets.** A Standard MIDI File and an Impulse Tracker module are read as values, 1:1
   with the bytes, in the vocabularies the [midi](../../../specs-llm/plans/midi/README.md)
   and [it](../../../specs-llm/plans/it/README.md) sets defined, and written back
   deterministically. A `.mid` or a `.it` is a tempura document with an empty timeline tier
   ([05](05-smf-core.md), [06](06-it-core.md)).
4. **The residue.** What the timeline says and the file cannot rides in the file's own
   metadata slots, so a `.mid` or a `.it` alone reconstructs the document, and a DAW or a
   tracker can still open it as if nothing were there ([04](04-residue.md)).

The consumer is **pacer** (`~/Dev/pacer`, 0.2.0), the deterministic playback kernel: tempura
never evaluates a value at time `t`; it exports the pacer score that does ([08](08-export.md))
and tells an editor where things are ([03](03-time-model.md), "Position queries"). The editor
is pstudio or any host that can apply SJON edit actions ([07](07-edit-engine.md)). The
comparison the set was started from is Theatre.js's core: keyframes with bezier handles on
object props, sequences in seconds, playback by rate and range, and nothing about musical
time, tempo, notes, patterns or files ([00](00-vision-and-scope.md), "The ledger").

Created 2026-09-19 from the midi and it plan sets (`~/llm/plans/midi/`, `~/llm/plans/it/`),
pacer (`~/Dev/pacer` at `63cd0ed`), SJON (`~/Dev/SJON` at `5c9a0a33`, release 1.4.2) and the
Theatre.js clone (`~/llm/repositories/theatre` at `6ea82b93`). On the machine this set was
written on, `~/Dev` is `~/Development` and `~/llm` is `~/Development/specs-llm`; the plans keep
the family's spellings.

## Ground truth and pins (2026-09-19)

| Source | Role | Pin |
|---|---|---|
| `~/Dev/SJON` | the substrate: parser, validator, `Pattern.PPC`, `PatternQuery`, `Edit` (eight actions, `wrap`, layout-preserving apply), Binary IR v5, lowering hooks | `5c9a0a33` (1.4.2, 2026-09-11) |
| `~/Dev/pacer` | the consumer: the score language (`docs/score-language.md`, generated), the tempo map (`src/TimeMap.zig`), the caps (`src/TrackTable.zig:42-49`), the easing enum (`src/Easing.zig:55-84`), the `'PACM'` sections (`src/Abi.zig`), the studio importer seam (`plans/it/03-exact-import.md`), the timeline editor plan (`plans/07-timeline-editor.md`) | `63cd0ed` (0.2.0, 2026-09-04) |
| `~/llm/plans/midi/` | the SMF vocabulary and format (02, 03), the integer tempo table (04), the grid math and key budget (05), the conformance shape (08); **copied and adapted** here, cited by doc | set dated 2026-08-28 |
| `~/llm/plans/it/` | the binary model (03), the reader and writer tables (04, 05), the timing state machine (06), `export-score` (09); **copied and adapted** here, cited by doc | set dated 2026-07-13, re-verified 2026-08-27 |
| `~/llm/repositories/theatre` | the comparison: `packages/core/src/types/public.ts:494-506` (keyframes), `types/private/core.ts:29-46` (sequences), `sequences/TheatreSequence.ts:29-36` (playback) | `6ea82b93` (0.7.0-39) |
| MMA *Standard MIDI Files 1.0* (RP-001) | normative for `.mid`; byte tables restated in [05](05-smf-core.md) from midi 03 | 1996, unchanged |
| `ITTECH.TXT` (`~/llm/repositories/impulsetracker`) and OpenMPT (`~/llm/repositories/openmpt`) | normative and reference for `.it`; **not checked out on this machine** on 2026-09-19 (empty submodules), so every `.it` claim below is inherited from the it set's 2026-08-27 verification and marked so | impulsetracker `9fcee05b`; openmpt `6ef84997` |
| `~/Dev/pstudio`, `~/Dev/animader/plans` | the studio and the sibling emitter; **not on this machine**; paths cited as the midi set cites them | pstudio `b8464f5`; animader `f014db4` |

Every claim about pacer, SJON and Theatre was verified against the pins above on 2026-09-19.
Line citations use `file.ext:NNN`. Claims about OpenMPT and ITTECH cite the it set's lines
and carry the it set's date. Re-verify before building on them if significant time has passed.

## Sibling plan sets

This is the fourteenth set under `~/llm/plans/`. Parts continue the family numbering:
**P99–P109**, milestones **E0–E4**. The next free part number family-wide is **P110**.

- **[midi](../../../specs-llm/plans/midi/README.md)** (midivia, P69–P78, N0–N4) and
  **[it](../../../specs-llm/plans/it/README.md)** (batida, P33–P41, T0–T4) are the two sets
  this one is built from. What each already covers, and what moves here, is in the table
  below. Neither repo exists yet (2026-09-19).
- **pacer's own plans** (`~/Dev/pacer/plans/it/`): Wave B is blocked on batida T2 for the
  exact `.it` provider and on batida P40 for the audio bus. tempura's E2 supplies the exact
  provider for `.it` **and** `.mid` with no batida, because the IT timing walk lives here
  ([08](08-export.md), [11](11-demos-and-milestones.md)).
- **[audzio](../../../specs-llm/plans/audzio/README.md)**, **[expansible-player](../../../specs-llm/plans/expansible-player/README.md)**:
  unaffected; one payload kind is reserved ([10](10-hosts-and-cli.md)).
- The laranjuice sets, post-fx, slug, font-api, gpu-ui and xleditor are unrelated.

## What the midi and it sets cover, and what moves here

| Concern | midi (midivia) | it (batida) | tempura |
|---|---|---|---|
| binary ⇄ SJON | `.mid` ⇄ `(smf …)`, inline payloads (midi 02, 03) | `.it` ⇄ `(module …)` with `(bin …)` refs (it 02, 03) | **both**, the core tiers hosted as the `midi` and `it` namespaces; the same forms, one owner per manifest ([02](02-timeline-schema.md)) |
| the time map | a fold over `set-tempo` (midi 04) | the timing state machine (it 06) | **both**, plus the document's own points, on one grid ([03](03-time-model.md)) |
| pacer skeleton | `export-score` with CC lanes (midi 05) | `export-score` with anchors (it 09) | **one exporter** for every lane kind ([08](08-export.md)) |
| the live wire, the fold, native I/O | the whole set (midi 04, 06, 07) | — | **not here**; midivia's, unchanged |
| the player, the mixer, the codec, instruments | — | the whole set (it 06, 07) | **not here**; batida's, unchanged; PCM and instruments are opaque bytes |
| a timeline above the file | — | — | the whole set |
| metadata carrying pacer vocabulary | one 25-byte easing hint (midi 03, decision 14) | — | the residue: the timeline tier itself, in both formats ([04](04-residue.md)) |

The three sets never depend on each other's code. Two cross-set notes are filed at E0 on the
sibling sets' side ([11](11-demos-and-milestones.md), "Sequencing"): the `midi` and `it`
core-tier manifests get one owner, and midivia's `note` verb gets a qualified spelling beside
tempura's `note` form.

## Reading order

New reader: `00 → 01 → 03 → 02 → 04`, then `05 → 06 → 07 → 08`, then `09 → 10`, then `11`
(the execution ladder; start there when picking up work). 03 before 02 because the time model
motivates the vocabulary, the batida order.

| Plan | Scope | Status |
|---|---|---|
| [00-vision-and-scope.md](00-vision-and-scope.md) | mission, the ledger against Theatre and pacer, the subset argument, design values, the fidelity ladder, non-goals | Active |
| [01-part-map.md](01-part-map.md) | parts P99–P109, the layering rule, repo tree, build verbs, conventions | Active |
| [02-timeline-schema.md](02-timeline-schema.md) | the `tempura` vocabulary; the hosted `midi` and `it` core tiers; collisions; SJON features used | Draft |
| [03-time-model.md](03-time-model.md) | the grid, positions and their spellings, tempo and meter maps, the `TimeMap` for three conductors, seams, position queries | Active |
| [04-residue.md](04-residue.md) | the metadata hack: the essence, lane records, the SMF and IT carriers, reconciliation, survival | Draft |
| [05-smf-core.md](05-smf-core.md) | the SMF reader and writer and the `midi/` bridge (from midi 03, 02) | Active |
| [06-it-core.md](06-it-core.md) | the IT timing core: header, orders, patterns, pass-through refs, the writer, the timing walk, the `it/` bridge (from it 03–06) | Active |
| [07-edit-engine.md](07-edit-engine.md) | operations as SJON edit actions: retime, quantize, split, tempo insertion, selection, snapping | Draft |
| [08-export.md](08-export.md) | pacer score text, `TimingData`, rendering native lanes to `.mid` and `.it`, the key budget | Active |
| [09-conformance.md](09-conformance.md) | oracles, the golden corpus, round-trip and residue gates, determinism, licenses | Active |
| [10-hosts-and-cli.md](10-hosts-and-cli.md) | the `tempura` CLI, wasm exports, the npm package, pstudio integration, the payload kind | Active |
| [11-demos-and-milestones.md](11-demos-and-milestones.md) | E0–E4, the spike, demos, sequencing against the family, effort, decision log | Active |

Statuses: **Active** (guiding current work), **Draft** (proposed, still moving), **Reference**,
**Complete**. When a plan completes, mark it in its header and in this table. Decisions changed
later are appended as dated notes, never silently rewritten.

## Hygiene

- Working plans, not specs. Each numbered doc ends with a **Risks / open questions** section;
  every risk lives in exactly one doc.
- Contracts that freeze are named where they appear: the tick grid and the position spellings
  freeze at E1 ([03](03-time-model.md)); the canonical writers' layouts at E1 ([05](05-smf-core.md),
  [06](06-it-core.md)); the residue payloads, the wasm exports and the diagnostic-code enum
  at E3 ([04](04-residue.md), [10](10-hosts-and-cli.md)). Everything else is revisable.
- Global part numbering is the one hard cross-set contract. Parts follow the five-field
  discipline: purpose, public contract, dependencies, isolated validation, standalone demo.
- No bare head collisions with pacer, pngine, animader, batida, midivia or the laranjuice
  vocabularies; the check is a test against the sibling manifests ([02](02-timeline-schema.md)).
- License discipline lives in [09](09-conformance.md): OpenMPT and the IT source are BSD
  (portable with attribution); Schism is GPL (doctrine only); the MMA specification is cited,
  never reproduced beyond the byte tables needed to implement it; tempura is CC0 (decided at E0).
- Prose follows the family's direct style: define before use, one idea per sentence, no
  decorative punctuation.
