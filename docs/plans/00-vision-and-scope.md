# 00 — Vision and Scope

Status: Active — 2026-09-19. Part of the [tempura plan set](README.md).

## The question

pacer answers "what is every parameter at time `t`": a score compiles to a tick-grid table and
`eval(seconds)` returns packed writes, a pure function of time (`~/Dev/pacer/README.md:5-12`).
A `.mid` and a `.it` each answer "what happens when", in their own grids, for their own
players. Theatre.js answers "how does an editor hold keyframes on object props" for the web
(`~/llm/repositories/theatre`). None of them answers the question a demo, a live set or a
studio session actually asks first: **what is the piece, as one thing, in musical time, that
every one of those can be derived from and written back to?**

That thing is a timeline. This set builds its core: the document, its time, its edits, and
its two binary subsets. No UI. pacer plays it; pstudio draws it; a DAW or a tracker can open
the file it lives in and never know.

## The ledger

What each existing thing holds, and what tempura's document must therefore hold to be a
superset of all three. "Own" means the concept is native to tempura's tier; "file" means it
lives in the hosted `midi/` or `it/` tier 1:1 with the bytes ([02](02-timeline-schema.md)).

| Concept | Theatre core (`types/private/core.ts:29-46`, `types/public.ts:494-506`) | `.mid` (RP-001) | `.it` (ITTECH.TXT) | pacer score | tempura |
|---|---|---|---|---|---|
| time unit | seconds (`length`, `subUnitsPerUnit` for snapping) | ticks per quarter note, `division` 1..32767 | ticks of `2.5/tempo` s, rows of `speed` ticks | `PPC = 720 720` ticks per bar | one integer grid that contains all three exactly ([03](03-time-model.md)) |
| tempo | none | `set-tempo` events, µs per quarter | initial `IT` + `Txx` per row/tick, integer BPM | `(transport :bpm)` + `(tempo :at :bpm)`, ≤ 512 segments | own: `tempo-point` (`:us` or `:qpm`); or derived from the conductor file |
| meter | none | `time-signature` events, may change | highlight rows per beat/measure (display only) | one `:meter` per score | own: `meter-point`, may change |
| sections, markers | none | `marker`, `cue-point` metas | none (order list is the structure) | `(scene …)` windows | own: `section` (window), `cue` (point) |
| notes | none | note-on/off with velocity and channel | cells: note, instrument, volume column, effect | `(trigger …)` lanes: phase, count, gate, beats-since | own: `note` with duration; file: bound lanes over `mtrk` events or pattern channels |
| continuous parameters | keyframes: value, position, bezier handles, `hold` | CC, pitch bend, pressure, 7/14-bit steps | volume column, effect column, per row | `(track (key :at :value :ease))`, 18 easings + combinators | own: `keyframe` with pacer's easing names; file: bound curve lanes |
| generative | none | none | none | `:pattern` (SJON PatternQuery), `:expr` | own: `query` and `formula` lanes, passed through to pacer |
| reuse | none | none | patterns placed by orders | none | own: `phrase` placed by `clip`; file: orders |
| pins | static props (`staticOverrides`) | none | none | `(control …)`, pins are text | pass-through: pacer's `(control …)` verbatim, no form of tempura's own |
| playback | `play({rate, range, iterationCount, direction})` | a player's choice | the tracker | `eval(seconds)`, `:end loop\|hold` | none; pacer's, from the exported score |
| editing | the studio's undoable state | a DAW | a tracker | text edits through `'PACM'` spans (pacer plan 07) | own: operations as SJON edit actions ([07](07-edit-engine.md)) |
| the file | JSON project state | the `.mid` | the `.it` | `.score.sjon` | `.sjon`; **or** a `.mid` or `.it` carrying the residue ([04](04-residue.md)) |

Two rows decide the shape. **Time unit**: tempura's grid is `TPQ = 46 126 080` ticks per
quarter note, `64 × PPC`, so pacer's grid is a sub-lattice reached by an integer divisor for
every meter it accepts, every DAW's SMF division divides it, and IT's tick is exactly
`TPQ / 24` ([03](03-time-model.md), "The grid"). **The file**: the timeline tier is small text;
both binary formats have a metadata slot that every reader is obliged to skip (SMF
sequencer-specific meta events; bytes past the last IT parapointer) and one that every writer
preserves (an SMF track's metas; the IT song message). The residue rides both, graded by
survival ([04](04-residue.md)).

## The subset argument

A `.mid` is a tempura document whose only roots are `(midi/smf …)` and its `(midi/mtrk …)`
tracks: the dump the midi set specifies (midi 02), hosted here under the `midi` namespace,
lossless on that set's fidelity ladder (midi 00). A `.it` is a tempura document whose only
roots are `(it/module …)` with `(bin …)` references for the bytes nobody edits: the dump the it
set specifies (it 02, 03). The timeline tier above them is what neither format can say. So:

- **Dump** is total: every readable `.mid` or `.it` becomes a document, with a timeline tier
  that is either restored from the residue or derived as a skeleton (one bound lane per used
  address, sections from markers, cues from orders).
- **Build** is total for a native document and for a document built into its own anchor's
  kind: every such document becomes a file. What the format can say is written natively;
  what it cannot is rendered (a native `note` lane becomes MIDI events or pattern cells) and
  recorded in the residue so it comes back exactly; what cannot be rendered at all (a formula
  lane into a `.it`) is residue only, with a diagnostic naming it. Building an IT-anchored
  document into a `.mid`, or the reverse, is refused in v1 (`build_cross_kind`) and parked
  ([08](08-export.md), "Cross-kind builds").
- **The file's native content is the truth for what the file can say; the residue is the
  truth for what it cannot; a hash says whether the two were written together.** That one
  rule ([04](04-residue.md), "Reconciliation") is what lets a DAW edit the notes of a file
  tempura wrote without tempura's sections, easing or pins being lost or lying.

pacer's score is not a subset in the same sense: it is a *target*. tempura exports it
([08](08-export.md)) and never reads it. pacer's vocabulary is designed for evaluation (a
score compiles to a table); tempura's is designed for arrangement (a document is edited). The
two share names where the meaning is identical (easing names, the expression environment,
`:end loop|hold`) so that export is a spelling change, never a translation.

## Mission

Make the timeline a value of the family, in one Zig repo (`~/Dev/tempura`, [01](01-part-map.md)):

1. **The document**: the `tempura` SJON vocabulary, hosting the `midi` and `it` core tiers;
   `Doc ⇄ (timeline …)` with schema diagnostics ([02](02-timeline-schema.md)).
2. **The time**: `Time.derive(Doc) → TimeMap` for three conductors and the position queries
   an editor needs ([03](03-time-model.md)).
3. **The formats**: `.mid` and `.it` in and out, byte-deterministic, with the residue
   ([04](04-residue.md), [05](05-smf-core.md), [06](06-it-core.md)).
4. **The edits**: every operation a timeline editor performs, as a pure function from a
   document to SJON edit actions ([07](07-edit-engine.md)).
5. **The export**: pacer score text, pstudio's `TimingData`, rendered `.mid` and `.it`
   ([08](08-export.md)).

Every piece is a pure function of its inputs and usable alone: the format cores without SJON,
the time map without a file, the edit engine without an editor, the exporter without pstudio
([01](01-part-map.md), the layering rule).

## Design values

| Value | Concretely |
|---|---|
| Nothing invented twice | the `midi` and `it` tiers are the sibling sets' vocabularies, not new ones; pacer's easing names, expression environment and end behaviour are reused by name; Theatre's keyframe shape is cited where tempura's differs (no handles: easing is a name, pacer's rule) |
| Time is an integer | positions are `i64` ticks on `TPQ`; seconds exist only at the two documented float seams, pacer's discipline (`pacer/src/TimeMap.zig:1-40`); a musical position never moves because a tempo changed |
| One clock, no loop | tempura never reads a clock and never owns a frame loop; `Playhead.at(seconds)` is a lookup; pacer evaluates, an editor draws |
| Text is the document | every edit is an SJON edit action applied to text with layout preserved (SJON 1.4.0, `docs/LANGUAGE.md` §11); the document is what the LSP validates and git diffs; there is no in-memory truth an editor could hold that the text does not |
| Bytes are sacred | unedited binary regions of a `.it` round-trip byte-exact behind `(bin …)` refs (it 03); a `.mid`'s event list round-trips event-exact (midi 00); tempura's writers are deterministic |
| The file still plays | a `.mid` or `.it` that carries the residue opens in any DAW or tracker with no visible difference; the residue is skipped by the format's own rules, never by luck |
| Honest fidelity | the ladder below names what is promised; survival of the residue through foreign tools is measured and logged, never promised (midi 08's discipline) |
| Diagnostics, never errors | a malformed document, file or edit yields diagnostics with spans and a best-effort value (SJON's collection over abort); user input is never asserted on |

## The fidelity ladder (public claims)

1. **Byte-exact**: for any `.mid` or `.it` tempura's canonical writers produced,
   `build(dump(f)) == f`; unedited `.it` regions behind `(bin …)` refs are copied verbatim.
2. **Content-exact**: any readable foreign `.mid` survives `dump → build → read` with an
   identical event list (absolute ticks, channels, data bytes) and tempo map; any readable
   foreign `.it` survives it with a field-identical timing module (header, orders, patterns)
   and byte-identical pass-through regions; layouts may differ.
3. **Essence-exact**: for any document, `dump(build(doc, kind)) ≡ doc` in the timeline tier,
   when the residue survives; when it does not, the skeleton is derived and the loss is a
   diagnostic list, never silence ([04](04-residue.md)).
4. **Score-exact within the grid**: `export-score` positions are exact pacer ticks where the
   tempura tick is a multiple of the meter's divisor ([03](03-time-model.md), "pacer's
   lattice") and rounded to the nearest pacer tick otherwise, with the rounding counted in
   the emitted warnings.
5. **Deterministic**: same document + same f64 seconds ⇒ bit-identical `TimeMap` answers,
   score text, edit actions and rendered bytes, native and wasm32, pinned by the golden corpus.

## Non-goals (v1)

- **A UI.** pstudio draws and drags; tempura answers "where is it" and "what does this drag
  become as text".
- **Evaluation.** No `eval(t) → writes`, no easing arithmetic, no write buffer. pacer does
  that from the exported score. A host that wants a value at `t` loads the score into pacer.
  (`Playhead` answers positions, active sections and sounding notes, which are lookups, not
  evaluations.)
- **Sound.** No player, no mixer, no codec, no synthesis. The `.it` tier keeps PCM and
  instrument bodies as opaque bytes; batida owns their meaning (it 06, 07).
- **Live MIDI.** No ports, no scheduler, no fold. midivia owns the wire (midi 04, 06, 07).
- **A DAW's feature list.** No audio clips, no mixer routing, no plugins. Lanes hold events,
  keyframes, queries and formulas; that is what pacer can consume.
- **Tempo ramps.** Tempo is a step function in v1, as it is in every source format; a
  `:ramp` on `tempo-point` is parked ([03](03-time-model.md)).
- **Byte-exact round-trip of foreign layouts.** Rung 2, not rung 1, for files others wrote.
- **Other formats.** No MOD/S3M/XM/MPTM, no MIDI 2.0 Clip Files (midi 03's parking stands),
  no MusicXML.

## Risks / open questions

- **The premise.** The set is worth building only if a piece is authored in a DAW or a
  tracker *and* needs a timeline above it that pacer cannot hold in its score alone. The E0
  spike ([11](11-demos-and-milestones.md)) takes the impulsos piece (`impulse-04.it` plus its
  `live.score.sjon`, the same measure midi N0 uses) and classifies its structure: how much is
  sections and cues (tempura's tier), how much is notes and automation (the file's tier),
  how much is expression (pacer's). If the first is empty, the residue and the edit engine
  are re-scoped and tempura is the two format cores plus one exporter. (The two structural
  risks that follow from building the sibling sets' halves here, one owner per manifest and
  per format core, and the walk's missing Zig oracle, live in [01](01-part-map.md) and
  [09](09-conformance.md).)

- **Drift, read against the tree on 2026-09-29.** "pstudio draws it" and "pstudio's
  `TimingData`" above predate the 2026-09-20 ruling that pstudio is not a host
  ([11](11-demos-and-milestones.md), ruling 2): there is no `TimingData` in `src/`, and the
  export is score text and the two renderers (`src/export/export.zig`). The hosts that count
  are the CLI, `npm/tempura` over `tempura.wasm`, expansible-player's payload kind and
  animader's piece format; the picture is drawn by whatever pacer drives, which for plan 13 is
  a pngine canvas.
