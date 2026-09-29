# 08 — Export: pacer Score Text, `TimingData`, and Rendering to `.mid` and `.it`

Status: Active — 2026-09-19. Part of the [tempura plan set](README.md). Owns **P106**
(`src/export/`). The score exporter is the midi set's [05](../../../specs-llm/plans/midi/05-score-import.md)
and the it set's `export-score` ([09](../../../specs-llm/plans/it/09-hosts-and-cli.md))
merged over one document; the two renderers are new.

Three consumers, three outputs, one `Doc` and one `TimeMap` in:

1. **pacer**: `exportScore(Doc, TimeMap, opts) → text`, a score a person then edits, that the
   studio's `skeletonAction` accepts verbatim (pacer `plans/it/03-exact-import.md` Phase 2).
2. **pstudio's import dialog**: `timingData(Doc) → TimingData`, the frozen provider seam
   (pacer `plans/it/03`, "Design"), the exact provider its Wave B is waiting for.
3. **DAWs and trackers**: `renderSmf(Doc) → Sequence` and `renderIt(Doc, Module?) → Module`,
   the native views of native content, with the residue attached by [04](04-residue.md).

## The pacer grid, from tempura's

pacer positions are ticks on `PPC = 720 720` per bar; tempura's are on `TPQ = 64 · PPC` per
quarter ([03](03-time-model.md)). For the score's meter `[n d]` (the first `meter-point` or
the conductor's first signature), a tempura tick `k` is a pacer tick iff `(256 n / d) | k`,
and then the pacer tick is `k / (256 n / d)`. Otherwise the nearest pacer tick, counted:
`rounded: N positions, max 0.000004b`. That is rung 4 of the ladder (00).

**Printing a position.** pacer converts a `b` literal by one `mul + floor`
(`pacer/src/TimeMap.zig:84-96, 148-152`): `tpb = PPC / n`, an exact integer computed once,
then `ticks = floor(beats · f64(tpb))`. A shortest-round-trip decimal of `beats` is **not**
safe: a triplet happens to land (`0.3333333333333333 · 180180` is exactly `60060.0` in f64),
but a quintuplet does not: `1.4 · 180180` is `252251.99999999997` and floors to `252251`, one
tick short of the exact `252252`, and about six percent of the ticks in a bar print short
this way. The exporter therefore prints, for the target pacer tick `T`, **the shortest
decimal `D` with `floor(f64(D) · f64(tpb)) == T`**, that is the shortest decimal in
`[T / tpb, (T + 1) / tpb)`, found by trying 1..17 fractional digits and checking with pacer's
own expression, evaluated in tempura in the same order. For the quintuplet that is
`1.400001b`; for a triplet `0.3333333333333333b` stands; for a 16th `0.25b`; for bar lines
`Nbar`. The node test runs every emitted position through the real `pacer.wasm` (`evalTicks`
on a probe score) and asserts the landing tick. This corrects the midi set's "shortest
round-trip decimal" rule (midi 05, "Grids"); the correction is recorded in
[11](11-demos-and-milestones.md).

**Beats versus quarters.** pacer's beat is `1 / n` of a bar, a `4 / d` note; tempura's tempo
is per quarter. So `:bpm = qpm · d / 4` (in `[6 8]` a beat is an eighth, twice the quarter
rate) and every position in beats is `quarters · d / 4`. midi 05 writes the factor as
`(4 / d)`, inverted; the corpus case `export-meter-6-8` pins the direction. Two bounds are
pacer's, not tempura's, and the exporter checks them before emitting: `bpm-value` is 1..1000
(`export_bpm_out_of_range`, an error: a `:qpm 600` piece in `[12 8]` is 1 200 beats per
minute and has no pacer spelling),
and `meter-component` is 1..16 for both components (`export_meter_unsupported`, a warning:
the score gets `:meter [4 4]` and positions in quarter notes, exact, with bar and phase lanes
wrong from the first bar).

## What is emitted

```
; exported from impulsos.sjon (conductor: impulse-04.it, 12 lanes, 4 sections) by tempura 0.1.0
; warning: meter changes to [3 4] at bar 32; pacer keeps [4 4]; positions stay exact, bar/phase lanes drift from there
(transport :bpm 125 :meter [4 4] :dur 128bar :end loop)
(tempo :at 64bar :bpm 150)
; cue "bar 41" — bar 40
(scene :name intro :at 0bar :dur 16bar)
(scene :name drop  :at 16bar :dur 32bar)
(trigger :target kick :at [0b 1b 2b 3b 4b …])
(track :target kick-vel (key :at 0b :value 0.86 :ease hold) …)        ; only with --velocity
(track :target glow
  (key :at 0b :value 0.2 :ease hold)
  (key :at 4b :value 0.9 :ease in-cubic)
  (key :at 8b :value [0.1 0.2 0.3] :ease (spring :damping 0.5)))
(track :target hats :pattern (euclid 3 8 1))
(track :target pulse :expr (sin (* beat 6.2832)))
(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)   ; pass-through, verbatim
(target :name glow :arity 1)                                                      ; pass-through, verbatim
```

- **Transport and tempo.** `:bpm` from segment 0; `:meter` from the first meter; `:dur` the
  timeline's `:length`; `:end` the timeline's. One `(tempo :at :bpm)` per segment after the
  first, adjacent equal tempi coalesced (a `T0x` slide's per-tick segments collapse where
  equal), each `:bpm` printed as the shortest decimal reproducing `qpm · d / 4` in f64. More
  than pacer's `MAX_TEMPO_SEGMENTS = 512` (`pacer/src/TrackTable.zig:49`) ⇒ coalesce segments
  closer than `--tempo-eps` (default 0.01 BPM) and, failing that, emit `s` positions with a
  warning (it 09's fallback; a per-tick slide over a song is the case).
- **Sections → scenes**, same names, `:at`/`:dur` printed by the rule above. **Cues →
  comments** (`; cue "name" — bar N`), never scenes: a cue is a point.
- **`notes` lanes → triggers**, one `(trigger :target :at [onsets…])` per lane with every
  onset exact-nominal (never quantised; pacer 06 Phase 2's rule stands); warn past 1 000
  onsets (pacer's parked `:at`-list cap). Onsets are aggregated **after** conversion to pacer
  ticks: equal ticks (a chord, or two onsets that rounded onto one tick) become one event,
  because pacer refuses an `:at` list that is not strictly ascending
  (`pacer/src/Compile.zig:1120-1124`, `trigger_invalid`), and the header comment counts the
  aggregations. With `--velocity`, a sibling `(track :target <name>-vel (key … :ease hold))`
  of `vel / 127`, the loudest of an aggregated set. A bound lane's onsets are the bridge's
  pairs ([05](05-smf-core.md), [06](06-it-core.md)); a native lane's are its notes and the
  expansion of its clips (`:repeat`, `:offset`, `:transpose` applied).
- **`curve` lanes → tracks.** Native keyframes are printed as `(key …)` with the `:ease`
  spelled exactly as authored (it is pacer's own kind). A bound lane's steps are `hold` keys
  by default or `linear` with the lane's `:ease linear` (the ramp the DAW's automation
  sampled, a better signal than the file carries); a segment with a verified easing hint
  (a midivia `ease-hint`, or a tempura lane record restoring a stale lane, [04](04-residue.md))
  collapses to its two endpoints with the hinted `:ease`, after **verification**: the steps
  inside the segment must lie within `--eps` of the named curve between the endpoints, else
  the hint is dropped with `ease_hint_mismatch` and the steps win. Values are `:range`-scaled
  (bound: normalised 0..1 or −1..1; native: literal).
- **`query` lanes → `:pattern`**, the query form verbatim (pacer runs the same engine, one
  cycle per bar; tempura's bar is pacer's bar under the first meter). **`formula` lanes →
  `:expr`**, verbatim (the environment names are pacer's, [02](02-timeline-schema.md)).
- **Pass-through.** Every pacer root in the document is printed after tempura's emissions,
  verbatim, comments included; a `(scene …)` colliding with a section is `scene_duplicate`, a
  pass-through `(transport …)` or `(tempo …)` `passthrough_conducts`.
- **Names.** A lane's `:target` (default its name) is the score's target; `(target …)`
  declarations pass through so a timeline compiles standalone (pacer's compose mode).

Every emitted score is compiled through the real `pacer.wasm` in `node --test` (dev-dependency
`file:../../pacer/npm/pacer`, midi 05's idiom) with zero error diagnostics, and the position
landing test above runs on the same instance.

## The key budget (midi 05, verbatim)

pacer caps keys at `MAX_KEYS = 4096` per score and tracks at `MAX_TRACKS = 256`
(`TrackTable.zig:42-43`). A DAW automation lane at 480 PPQ holds a point per tick when drawn
freehand. The exporter budgets bound curve lanes:

1. **Equal-run collapse**, always: consecutive keys with the same value keep the first on a
   `hold` lane and the first **and last** on a `linear` lane (a plateau's endpoints; dropping
   the last would turn `(0, 0) (1, 0) (2, 1)` into `(0, 0) (2, 1)` and read `0.5` at beat 1,
   past `eps` before simplification even runs).
2. **Ramp simplification**, `--eps` (default `1/127`, the CC quantum): Ramer–Douglas–Peucker
   over `(beat, value)`, deterministic (fixed recursion order, exact comparisons); with
   `linear` the polyline reproduces the lane within `eps`, with `hold` the steps that exceed
   `eps` are kept. A verified hint collapses its segment to two keys whatever the step count.
3. **Counts** in the header comment and in the warnings when a track exceeds
   `--max-keys-per-track` (default 512).
4. **Triggers** keep every onset and warn past 1 000.

Native lanes are never simplified: the author wrote every keyframe.

## `TimingData` for pstudio

pacer's it-wave froze the seam: `TimingProvider = { id, label, available(), analyze(bytes) }`
producing `TimingData = { title, warnings, tempoSegments: [{beat, bpm}], orders: [{index,
pattern, startBeat}], channels: [{index, label, onsetBeats, playedCount}], songBeats, meter?,
summary }` (`pstudio/editor/src/lib/score/timing-provider.ts`, not on this machine; pacer
`plans/it/03-exact-import.md`, "Design"). `timingData(Doc)` fills it:

- for an IT conductor, from the walk: `orders` from the played order list (`index`,
  `pattern`, `startBeat` exact, including every repeat), `channels` from note cells per
  channel with `playedCount`, `tempoSegments` from the segments (coalesced), `meter` from the
  highlight, `warnings` for `SDx`-shifted onsets and `walk_runaway`; **this is the exact
  provider pacer's 03 P3–P4 waits for**, and the Txx fixture the approx provider gets wrong is
  the red;
- for an SMF conductor, midi 05's mapping (`orders` from markers, `channels` per `(channel,
  key)` with note-ons, labelled from `sequence-name`);
- for a native document, `orders` from sections, `channels` from `notes` lanes.

`beat` values are pacer beats (`quarters · d / 4`), printed by the studio's emitter as
`Nb`; the emitter is the studio's and stays the one text generator for what it generates
(pacer decision (3), 2026-07-19); everything richer reaches the studio through the
skeleton-file path with `tempura export-score`.

## Rendering to `.mid` (`renderSmf`)

The native view of a document, for a DAW. Track 0 is the conductor: `set-tempo` from the
tempo points (`:us` verbatim, `:qpm` → `round(60e6 / qpm)`), `time-signature` from the meter
points (`nn`, `dd = log2 d`, `cc 24`, `bb 8`), a `marker` per cue and, with
`--section-markers`, one per section start; the essence at tick 0 ([04](04-residue.md)).
Then, per native lane, one `mtrk` named by the lane with a lane record at tick 0:

- `notes`: `note-on` / `note-off` pairs on `:ch` at `k · PPQ / TPQ` (`--ppq` default 960;
  exact iff `TPQ / PPQ` divides the tick, else nearest and counted in `render_inexact`);
  clips expanded; overlapping notes on one key are the lane's `note_overlap` already.
- `curve`: `control-change` on `--cc` (or the lane's `:cc`, required for a native curve
  rendered to MIDI: `render_cc_missing` otherwise), the value `round((v − lo) / (hi − lo) ·
  127)` with the lane's `:range` (default `[0 1]`); one event per keyframe with `hold`, and
  for a `linear` segment one event per `--cc-rate` (default a 32nd) computing the line
  exactly (integer ticks, f64 value, one rounding). **Every other easing renders as its
  keyframes only** (steps): tempura never evaluates a named curve (00's non-goal), the DAW
  hears the steps, and the essence restores the curve. The lane record marks the segments
  rendered as steps.
- `query`, `formula`: essence only, `residue_only`.

Bound lanes over the same anchor are the anchor's own tracks and are not rendered again; a
document with an SMF anchor renders **into** that `Sequence` (new tracks appended), so
`build` of a dumped `.mid` with an added native lane is the original file plus tracks. A
format 0 anchor has one track by definition: appending promotes the file to format 1 with
`render_format_promoted` (a warning), unless `--format 0` merges everything into the one
track ([05](05-smf-core.md), the writer's option).

## Cross-kind builds

v1 builds a document into its own anchor's kind or, for a native document, into either kind.
Building an IT-anchored document into a `.mid`, or an SMF-anchored one into a `.it`, is
refused with `build_cross_kind`. The mechanism is not mysterious (bound lanes through the
bridge's note pairs and column values, the conductor's segments into `set-tempo` events or
`Txx` cells, the anchor's own content left behind) but it has no consumer yet, and its
residue story (a `.mid` whose music is a rendering of a `.it`) is a second reconciliation
table. Parked in [11](11-demos-and-milestones.md); `export-score` from either kind is the
door that exists.

## Rendering to `.it` (`renderIt`)

The native view for a tracker, into the anchor's `Module` when there is one (new channels
above the module's highest used channel, `render_channels_exhausted` past 64), or into a
fresh module (header defaults: speed 6, tempo from segment 0 as an integer 32..255 or
`tempo_inexact`, 64-row patterns, instrument mode off, one order per bar-aligned pattern):

- Positions land on the row grid: a row is `speed` IT ticks; a position that is a multiple
  of the IT tick (`1 921 920`) but not of the row uses `SDx` (delay `x ≤ 15` ticks) when the
  cell's effect column is free, else nearest row and `render_inexact`.
- `notes` → cells: note number (`C4` = `C-5`), `:ins 1` and `it_no_instrument` when the
  module has none (the file carries timing and silence; a tracker adds samples; the residue
  remembers), `:vol` from velocity, a cut at the note's end when the next cell is farther
  than the duration (`^^^`, note cut 254) so durations survive. A cell holds one note, so a
  lane takes as many channels as its **maximum polyphony**: voices are allocated
  deterministically (lowest free channel of the lane's set; a note that would cut a sounding
  one on its channel moves to the next), capped by `--voices` (default 4) with
  `render_polyphony_exceeded` naming the tick beyond it, and the lane record names the channel
  set ([04](04-residue.md)).
- `curve` → `:column vol` values at rows (`hold`; `linear` sampled per row), or `--fx "Z"`
  parameter bytes; other easings as steps, as for MIDI.
- Tempo points → `Txx` at their rows (integers; a fractional `qpm` is `tempo_inexact` and
  the essence keeps it); meter points → the highlight for the first, the essence for the
  rest; sections and cues → the message tail ([04](04-residue.md)).
- Phrases and clips → the pattern and order structure when a clip is bar-aligned and its
  phrase's length is a whole number of rows; otherwise flattened into the patterns the clip
  spans, with the structure in the essence.

## Phases (P106)

1. **Positions and the landing test (RED first).** Load: 03's grid, `pacer/src/TimeMap.zig`
   op order. Reds: the shortest-floor-decimal rule on triplets, quintuplets (`1.4b` →
   `1.400001b`), 32nds, bar lines, and a sweep of every tick in two bars of `[4 4]` and
   `[7 8]`; `rounded` counts for off-lattice ticks; `qpm · d / 4` in `[6 8]`;
   `export_bpm_out_of_range`; `export_meter_unsupported` with the `[4 4]` fallback; the node
   test against `pacer.wasm` landing every printed position. Green: `export/pos.zig`. Gate:
   test + node.
2. **`exportScore`.** Reds: the golden above for a native fixture, an SMF-conducted one and an
   IT-conducted one; coalescing; the 512 fallback; the meter warning; every skeleton loads
   clean through `pacer.wasm`; `scene_duplicate`, `passthrough_conducts`. Green:
   `export/score.zig`. Gate: test + CLI goldens + node.
3. **Lanes and the budget.** Reds: hold and linear steps; a hinted segment; mismatch drop;
   equal-run collapse keeping a linear plateau's endpoints; the combined collapse-then-RDP
   pipeline within `eps` on a synthetic lane; per-track warning; a chord aggregating to one
   onset with the loudest velocity and two near onsets rounding onto one pacer tick;
   `--velocity`; native keyframes untouched; queries and formulas verbatim. Green:
   `export/lanes.zig`, `export/simplify.zig`. Gate: test.
4. **`timingData`.** Reds: the IT Txx fixture the approx provider gets wrong (pacer 03 P3's
   red) yields the true `startBeat`s; the SMF mapping; JSON byte-equal native and wasm.
   Green: `export/timing.zig`. Gate: test + node.
5. **Renderers.** Reds: a native fixture renders to a `.mid` that `dump`s back essence-exact
   with every hash matching; a `linear` curve's CC steps at the rate; steps-only for
   `in-cubic`; the IT render's `SDx`, cut cells, `it_no_instrument`, `tempo_inexact`;
   rendering into an anchored module leaves its regions byte-equal; a three-voice chord lane
   renders across three channels and a fifth voice trips `render_polyphony_exceeded`; a
   format 0 anchor is promoted; `build_cross_kind`. Green:
   `export/render_smf.zig`, `export/render_it.zig`. Gate: test + corpus + the residue gates
   ([09](09-conformance.md)).

## Risks / open questions

- **One meter per pacer score.** A multi-meter timeline exports with positions exact and bar
  anchors drifting after the first change. A `(meter :at …)` form in pacer would remove the
  warning; the ask is filed only if a real piece needs it (midi 00's parked ask stands).
- **The floor-interval decimal depends on pacer's exact op order.** It is pinned by pacer's
  CLAUDE.md as a determinism seam and re-checked by the node landing test on every `verify`;
  if pacer ever changes its conversion, the test fails before a wrong skeleton ships.
- **Rendering curves as steps** is honest but a DAW user may expect ramps for every easing.
  Sampling named easings would mean evaluating them here; the alternative is to ask pacer's
  CLI (`pacer eval`, `docs/cli.md`) at render time when a sibling checkout exists, an
  optional `--sample-with-pacer` flag recorded as a candidate, never a dependency.
- **Simplification changes the music** for bound lanes above the CC quantum. The default is
  the quantum; the header comment states the tolerance used.

- **Drift, read against the tree on 2026-09-29 (`cfe44a0`).** "Three consumers, three
  outputs" is two: `TimingData` and `export/timing.zig` were dropped with pstudio on
  2026-09-20 ([11](11-demos-and-milestones.md), ruling 2) and nothing in `src/` spells them;
  the "`TimingData` for pstudio" section and phase 4's green list stand as the E0 design. The
  renderer knobs spelled as flags — `--cc-rate` (a 32nd), `--voices` (4), `--fx "Z"` — are
  `render_smf.Options.cc_rate` (`src/export/render_smf.zig:97-115`), `render_it.Options.voices`
  and `.fx` (`src/export/render_it.zig:81-85`) at their defaults on every CLI and wasm path;
  `Args.zig` never grew them (`:273-310`), so a document that needs one today cannot ask. Each
  is one `Args.zig` row plus a golden; plan 13's `--pattern-per-section` is the first render
  flag and the template. pacer's dev dependency is `file:../../../pacer/npm/pacer`.

- **Ask T1 from animader (2026-09-29): a source map beside the score text.** animader
  edits the score's picture (a key in its Timeline) and must land the edit on the timeline
  node the key came from. SJON provenance covers animader's own lowering, and this export is
  text, so the join is missing at exactly one stage. Wanted: on `Result`, beside `landings`,
  one record per emitted position, not per form: each `(key …)`, each element of a
  `(trigger …)`'s `:at` (two notes export as one trigger with two onsets, checked 2026-09-29),
  each `(scene …)` and the transport's points, giving its byte span in `text` and the address
  of the `Doc` node it came from (root index plus path, the edit engine's spelling,
  [07](07-edit-engine.md)), several addresses when aggregation merged onsets, and a
  pass-through root mapping to itself; reaching hosts the way
  `landings` does today (the value, and `tools/zt landing`'s fixtures), then the CLI as an
  `export-score --map` output and the wasm as a fourth blob appended after `'TPDG'` when a
  host needs it, an append under the E3 rule with `tpr_abiVersion` unchanged. Text path only:
  the lowering hook stays parked ([11](11-demos-and-milestones.md), 2026-09-29). Not built.
  Its first consumer is animader's arc 2, step 12; plan 13's page could show it earlier as a
  key dragged on the canvas naming its lane.
- **A zero-length timeline exports a transport pacer refuses (2026-09-29).** `(timeline)`
  with a tempo point and a meter point at the origin and no lanes validates and exports
  `(transport :bpm 60 :meter [4 4] :dur 0bar :end hold)`, and `pacer check` answers
  `transport_invalid: :dur must be positive`. `validate` and `export-score` are green one
  stage before the score is refused. Ruled 2026-09-29 (user): diagnose it at score export.
  The default-length rule ([02](02-timeline-schema.md), "the end of the last event or clip,
  rounded up to a bar"; `src/doc/fromSjon.zig:259`, `defaultLength`) stands: an empty
  document has length zero and is tested so, and a one-bar floor would change every
  consumer's reading while leaving an explicit `:length 0bar` unresolved. `export-score`
  raises an error at `:length`, or at the `(timeline …)` header when the length was
  inferred, instead of returning a score pacer refuses. Implemented as
  `export_zero_length` (ordinal 89): the core returns an error diagnostic and empty score
  text, the CLI exits 1, and the wasm host gets no score. `corpus/export-zero-length`
  pins the native and wasm answers; unit tests also cover explicit zero and the one-bar
  identity. animader's identity timeline writes `:length 1bar` regardless.
