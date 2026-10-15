# 02 — The `tempura` SJON Vocabulary

Status: Active — 2026-09-19; Draft until 2026-09-29 (the manifest is implemented, generated
into `docs/timeline-language.md` and drift-gated, and frozen with the E3 surfaces). Part of the
[tempura plan set](README.md). Owns **P99**
(`schema/`, `src/plugin.zig`) and the tree half of **P102** (`src/doc/`).

Four manifests compose one project. `schema/tempura.sjon` is the timeline tier and the only
original vocabulary in the set: eight global heads and three slot-locals. `schema/midi.sjon`
and `schema/it.sjon` are the sibling sets' file vocabularies, hosted here under their own
namespaces so that a `.mid` or a `.it` dumped into a document is that set's dump, form for
form. `schema/pacer.sjon` is a verbatim copy of pacer's score manifest, so that tempura's
easing slots are typed by pacer's own `ease-spec` kind and any pacer form may sit in a
timeline document as pass-through. The four share no head (the collision table below), so
one `sjon-project.sjon` composes them and every bare head resolves.

## The document

```sjon
(timeline :title "impulsos" :length 128bar :end loop :conductor song)

(anchor :id song :kind it :file "impulse-04.it" :size 1284403 :sha256 "9f2a…")
(it/module :title "impulse 04"                       ; the module's dump, inline: editable here
  (it/timing :speed 6 :tempo 125 :highlight [4 16])
  (it/orders 0 1 2 1 skip 3 end)
  (it/pattern 0 :rows 64 (row 0 (ev 3 "C-5" :ins 2 :vol 64)) …)
  (it/sample 2 :name "bass loop" (data :bits 16 :enc it214 (bin :at 34600 :len 12842)))
  …)

(section :name intro :at 0bar :dur 16bar)            ; → pacer (scene …)
(section :name drop  :at 16bar :dur 32bar)           ; windows may overlap
(cue :name "bar 41" :at 40bar)                       ; a point: SMF marker; IT order comment

(lane :name kick :kind notes :from song :channel 3 :target kick)                    ; bound: content is the module's
(lane :name bass-vol :kind curve :from song :channel 5 :column vol :range [0 1])   ; bound: a tracker column as a curve

(lane :name flash :kind notes :target flash                                        ; native: content lives here
  (note :at 0q :dur 0.5q :key 36 :vel 110)
  (note :at 1q :dur 0.5q :key "C4" :vel 90)
  (clip :at 8bar :phrase fill :repeat 2))
(lane :name glow :kind curve :target glow
  (keyframe :at 0q :value 0.2 :ease hold)
  (keyframe :at 4q :value 0.9 :ease in-cubic)
  (keyframe :at 8q :value [0.1 0.2 0.3] :ease (spring :damping 0.5)))
(lane :name hats  :kind query   :target hats  :query (euclid 3 8 1))                ; SJON PatternQuery, one cycle per bar
(lane :name pulse :kind formula :target pulse :expr (sin (* beat 6.2832)))         ; pacer's expression environment

(phrase :name fill :length 1bar
  (lane :name flash
    (note :at 0q   :dur 0.25q :key 38 :vel 100)
    (note :at 0.5q :dur 0.25q :key 38 :vel 80)))

(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)   ; pacer's form, pass-through
(target :name glow :arity 1)                                                      ; pacer's compose-mode declaration
```

Rules, each a diagnostic with a span when broken. Positions are the `position` kind of
[03](03-time-model.md) (units `q t bar b s`, unit required).

- **`(timeline …)`** once, first (`timeline_duplicate`, a host check: SJON's `head-set`
  counts a form's children, not a document's roots, and pacer checks `transport_duplicate`
  the same way). `:title` string;
  `:length` a position (default: the end of the last event or clip, rounded up to a bar);
  `:end` `loop | hold` (default `hold`, pacer's `end-behavior`); `:conductor` an `anchor`
  id whose tempo and meter conduct ([03](03-time-model.md), "Three conductors"). With a
  conductor, `tempo-point` and `meter-point` forms are `conductor_conflict`; without one, a
  `tempo-point` and a `meter-point` at tick 0 are required (`tempo_map_invalid`,
  `meter_map_invalid`). `:fps` the document's frame rate for the `f` position unit —
  appended 2026-10-15 with that unit (the T2 ruling, [03](03-time-model.md), risks), so
  this row dates itself against the keys above, which froze at E1: an integer
  (`:fps 25`) or an exact `[num den]` rational (`:fps [30000 1001]`), never a bare
  decimal — the manifest's `frame-rate` kind refuses one (`sjon_diagnostic`; 29.97 would
  mean 2997/100, and NTSC does not). No default: an `f` position with no `:fps` is
  `frame_rate_missing` and is not placed; a declared rate with no `f` position is
  harmless, changes no position's spelling and prints only the header's `:fps`.
- **`(anchor …)`**: the it set's `(source …)` generalised to both formats (it 03, "The
  anchor"). `:id` symbol (a cross-ref target), `:kind` `smf | it`, `:file` resolved relative
  to the document, `:size` and `:sha256` verified before any `(bin …)` or bound lane is
  honoured (`anchor_mismatch`, never a silent re-read). An anchor is **by reference** when the
  document holds no dump for it and **inline** when a `(midi/smf …)` or `(it/module …)` root
  follows it in document order; the pairing is positional and one dump per anchor (an inline
  dump with no preceding anchor is `anchor_missing`; two dumps for one anchor
  `anchor_dump_duplicate`). A hosted `(it/source …)` inside an inline
  module is accepted when it agrees with the anchor and `anchor_conflict` when it does not.
- **`(tempo-point …)`**, **`(meter-point …)`**: [03](03-time-model.md). `:at` in `q`, `bar`,
  `b` or `t` only; exactly one of `:us` | `:qpm`; `:sig [n d]`.
- **`(section …)`**: `:name` symbol, unique; `:at`, `:dur` positions; overlap allowed. Exports
  to a pacer `(scene …)` of the same name ([08](08-export.md)).
- **`(cue …)`**: `:name` string; `:at`. A point, never a window. SMF markers and cue points
  dump to cues; pacer gets a comment.
- **`(lane …)`**: `:name` symbol, unique across the timeline's lanes; `:kind` is the
  discriminant and its value gates which keys exist (`(variant :when …)`, pacer's
  `(control :type …)` precedent): `notes` and `curve` take content or a binding, `query`
  takes `:query`, `formula` takes `:expr`. `:target` symbol, the pacer name the lane drives
  at export (default: `:name`); `:range [lo hi]` (`repr f32`) scales a bound curve's
  normalised value at export. **Binding**: `:from` names an anchor; the address keys depend
  on the anchor's kind and are checked host-side (`address_invalid`): an SMF lane takes
  `:track` (1-based file order) and `:ch` (1..16), a `notes` lane optionally `:key`
  (one key, a drum), a `curve` lane exactly one of `:cc N`, `:cc [msb lsb]`, `:bend true`,
  `:pressure true`, `:velocity true` (an `(exclusive-group …)`); an IT lane takes `:channel`
  (1..64) and a `curve` lane `:column vol | pan | fx` with `:fx "M"` (an effect letter)
  when the column is `fx` (`:fx :requires [:column]`). A bound lane has no children
  (`bound_lane_has_content`); a `query` or `formula` lane cannot bind (`bound_kind_invalid`).
- **`(note …)`**, slot-local to `lane`: `:at`, `:dur` positions; `:key` an integer 0..127 or
  a note-name string (`"C4"` = 60, sharps `#`, flats `b`, the midi set's convention, midi 02);
  `:vel` 1..127 (default 100); `:ch` 1..16 (default: the lane's `:ch` or 1) and `:off-vel`
  for MIDI rendering only. Two notes on one key overlapping in one lane are
  `note_overlap` (the midi set's `note_overlaps_self`).
- **`(keyframe …)`**, slot-local to `lane`: `:at`; `:value` a number or a 1..4 vector
  (`repr f32`, pacer's `key-value` shape); `:ease` typed **`pacer/ease-spec`**, so a name
  (`in-cubic`) or a pacer easing form (`(spring …)`, `(steps …)`, `(cubic-bezier …)`,
  `(seq …)`, `(chain …)`) validates through pacer's own manifest and cannot drift from it.
  Semantics are pacer's: the easing applies over the segment ending at this keyframe; before
  the first the lane holds its first value, after the last its last. No Theatre-style handles
  (`theatre/packages/core/src/types/public.ts:503`): a curve is named, never drawn, pacer's rule.
- **`(clip …)`**, slot-local to `lane`: `:at`; `:phrase` a cross-ref to a `phrase :name`;
  `:repeat` integer ≥ 1 (default 1); `:offset` a position into the phrase (default 0);
  `:length` the playback window from `:offset` (default: the phrase's length times `:repeat`
  minus `:offset`; content past the window is not placed, which is what a split clip's left
  half needs); `:transpose` integer semitones (notes only). A clip places the phrase's lane of the same
  `:name` as this lane; a phrase with no such lane is `clip_lane_missing`.
- **`(phrase …)`**: `:name` symbol (the cross-ref target); `:length` position; positional
  children are `(lane …)` forms with content only: `:from` is `phrase_lane_bound`, a `clip`
  inside is `clip_nested`, `:target` is ignored (the placing lane's target applies).
- **pacer forms** (`control`, `target`, `transport`, `tempo`, `scene`, `track`, `trigger` and
  the easing forms) are legal roots and **pass through** `export-score` verbatim, after
  tempura's own emissions ([08](08-export.md), "Pass-through"). tempura never derives from
  them and never edits them; positions inside them are pacer's, against the transport tempura
  emits. A pass-through `(transport …)` or `(tempo …)` is `passthrough_conducts` (tempura
  emits those). A `(scene …)` whose name a `section` also uses is `scene_duplicate`.

Every form's catalog entry (`schema/tempura-catalog.sjon`) names where the concept comes
from: Theatre's keyframe and sequence types, RP-001's meta events, ITTECH's order list and
pattern rows, or pacer's form of the same meaning. The both-ways coverage test fails if a form
lacks provenance or a catalog entry lacks a form.

## The hosted tiers

- **`schema/midi.sjon`** is the midi set's file vocabulary, **core tier only**: `smf`, `mtrk`,
  the 28 event heads, `ease-hint` (midi 02, "The file document, core tier"; midi 03's tables
  restated in [05](05-smf-core.md)). The `note` verb and the map forms (`midi-input`,
  `midi-output`, `midi-clock`) are midivia's live tier and are not hosted; a `(midi/smf …)`
  written by hand here uses `note-on`/`note-off`, and the timeline tier's `note` is the sugar.
- **`schema/it.sjon`** is the it set's vocabulary whole (it 02 with its 2026-08-25
  amendments: slot-locals for `row`/`ev`/`node`/`range`/`ch`/`macro`/`vibrato`/`data`/
  `source`/`timing`/`options`, hex literals on `bin` offsets, `:requires`, positional counts,
  `scalar-or-ref` for `:ins`). tempura's bridge **materialises the timing subset** (header
  fields, orders, patterns, message) and keeps instruments and samples as opaque records with
  their names and a `(bin …)` per body ([06](06-it-core.md)); a document that spells an
  instrument field tempura did not materialise is `it_field_not_materialized` at build, so a
  batida dump validates here but its instrument edits wait for batida (or `--full`, an E4
  candidate). One owner per manifest is a cross-set decision filed at E0
  ([11](11-demos-and-milestones.md)).
- **`schema/pacer.sjon`** is copied from `~/Dev/pacer/schema/pacer.sjon` at the pinned
  commit, header comment naming it; `zig build verify` diffs it against the sibling checkout
  when one exists ([01](01-part-map.md)).

## Collisions, checked

Global heads this set declares: `timeline`, `anchor`, `tempo-point`, `meter-point`,
`section`, `cue`, `lane`, `phrase`; slot-locals `note`, `keyframe`, `clip` under `lane`. A test
loads the four project manifests plus every sibling manifest present in a sibling checkout
(`pngine/schema/pngine.sjon`, animader's five, batida's and midivia's once they exist) and
asserts no `ambiguous_form`. Names known to be taken and avoided: `track`, `key`, `scene`,
`tempo`, `transport`, `trigger`, `control`, `target`, `seq`, `stage`, `chain`, `steps`,
`cubic-bezier`, `spring` (pacer; `key` and `stage` are slot-locals there,
`pacer/schema/pacer.sjon:280,356`, and would not collide, avoided anyway); `session`, `down`,
`move`, `up`, `cancel`, `wheel`, `custom`, `input`, `mark`, `tap`, `drag`, `key-press`,
`hit-area`, `listener`, `layer`, `state`, `transition`, `output`, `route`, `on`, `hold`,
`toggle`, `follow`, `piece`, `kernel`, `sample`, `simulate`, `paint`, `remember`, `compose`,
`warp` (animader); `module`, `source`, `timing`, `options`, `channels`, `ch`, `orders`,
`message`, `midi`, `macro`, `instrument`, `midi-out`, `notemap`, `range`, `node`, `sample`,
`vibrato`, `data`, `bin`, `wav`, `pattern`, `row`, `ev`, `foreign`, `edit-history`
(batida, hosted here as `it/`); `smf`, `mtrk`, the event heads, `ease-hint`, `note`,
`midi-input`, `midi-output`, `midi-clock`, `meta` (midivia; hosted here without `note`);
`data`, `frame`, `pass`, `bytes` (pngine); `text`, `font`, `curve` (canto, laranjuice).
`tempo-point` rather than `tempo`, `section` rather than `scene`, `cue` rather than `mark` or
`marker`, `anchor` rather than `source` or `binary`, `keyframe` rather than `key` or `point`:
each name exists because a shorter one was taken or is likely to be (`point` in a geometry
vocabulary, `binary` in pngine's data tier).

**The `note` collision with midivia** is real and deliberate: midivia's `note` is a verb its
hand-written `(smf …)` documents use (midi 02); tempura's `note` is the timeline's event form.
A project loading midivia's full manifest beside tempura's must qualify one of them
(`midi/note`), which SJON supports (`docs/LANGUAGE.md` §5.3). The cross-set note filed at E0
asks midivia to spell its verb qualified in mixed projects or rename it; tempura's hosted
copy simply omits it.

## SJON 1.1–1.4 features used

Cross-refs with `:name-key` (`clip :phrase → phrase`, `lane :from → anchor`, `timeline
:conductor → anchor`); `(variant :when …)` on `lane :kind`; `(exclusive-group …)` for
`:us | :qpm` and the curve address keys; `:requires` for `:fx`; positional slot-locals for
`note`, `keyframe`, `clip` (pacer's B2 precedent); `(head-set …)` counts for a phrase's
`lane` children; `(repr-shape :type f32)` on `:value`, `:range`, `:vel`;
`(unit-shape :required true :allowed [q t bar b s])` on positions (pacer's `time-pos`
spelling, `pacer/schema/pacer.sjon:28-31`); a cross-plugin kind reference
`pacer/ease-spec` (`docs/LANGUAGE.md` §6.7); `:default`s read back through `EffectiveView`;
`:description`s rendered into `docs/timeline-language.md`. `:expr` and `:query` are `:type
any` and validated host-side: the expression against pacer's environment names (`t`, `tick`,
`beat`, `bar`, `cycle`, `phase`, `bpm`, `dur` plus every `control` id, `docs/score-language.md`),
the query by compiling it through `PatternQuery.compileTree` (`SJON/src/PatternQuery.zig:532`).
No lowering hook in v1: export is text ([08](08-export.md)); a `tempura/score-v1` hook that
emits pacer forms so a host with both manifests compiles a timeline directly is an E4
candidate, recorded in the decision log.

## Phases (P99 + the tree half of P102)

1. **The timeline manifest (RED first).** Load: `pacer/schema/pacer.sjon` as the style
   reference, 03's units. Reds: every form validates a minimal instance and rejects one
   malformed key each; `timeline_duplicate`; the variant keys per `:kind`; the exclusive
   groups; the cross-refs resolve and fail (`not_cross_ref`); the catalog coverage test.
   Green: `schema/tempura.sjon`, `schema/tempura-catalog.sjon`, `src/plugin.zig`,
   `Schema.load` preloaded (pacer 12 Wave A: spans are document coordinates). Gate: test.
2. **Hosted tiers and the project file.** Reds: `schema/midi.sjon` validates midi 02's
   two-track example verbatim with `midi/` qualification and bare; `schema/it.sjon` validates
   it 02's examples; all four manifests load in one `Schema.init` with no collision; the
   sibling-heads test; the `sjon.loadProject` lockstep test against the preloaded set (pacer
   12 C1); the pacer-copy drift check. Green: the three files, `sjon-project.sjon`. Gate: test.
3. **`fromSjon` / `toSjon`.** Reds: the example above dumps to itself; `fromSjon(toSjon(d))
   ≡ d`; the anchor pairing rules; host-side checks (`address_invalid`, `bound_lane_has_content`,
   `phrase_lane_bound`, `clip_nested`, `note_overlap`, `conductor_conflict`); position
   spellings by the printer's rule. Green: `src/doc/`. Gate: test + `audit-diagnostics`.
4. **Generated docs.** `zig build docs` renders `docs/timeline-language.md`; `verify` diffs.
   Gate: verify.

## Risks / open questions

- **Verbosity of inline dumps.** A `.it` with sixty patterns dumps long; a `.mid` with dense
  automation dumps very long. That is the sibling sets' accepted size (it 02's row-major
  risk; midi 02's verbosity risk) and by-reference anchors keep a timeline document small
  when the file is not being edited. `--patterns=bin` (it 03) is the compaction for `it/`.
- **Two spellings for one thing.** A native `note` lane and a bound SMF lane say the same
  music two ways. The rule that content has one home ([04](04-residue.md), "One home") keeps
  them from coexisting for the same events; the edit engine refuses an operation that would
  create the second spelling (`edit_would_duplicate`, [07](07-edit-engine.md)).
- **The pacer copy is a foreign vocabulary inside the LSP's composed schema.** Authors get
  completion for `(track …)` in a timeline document, which is right (pass-through is legal)
  and confusing (most of the time they want `lane`). The generated docs say which is which;
  a lint (`passthrough_preferred_native`, a warning) points a pass-through `(track (key …))`
  at `(lane :kind curve …)`.

- **Drift, read against the tree on 2026-09-29 (`cfe44a0`).** Left as written, dated here:
  `src/plugin.zig` is `src/Schema.zig`. The curve lane's controller keys are an
  `(exclusive-group :cardinality at-most-one …)` (`schema/tempura.sjon:472`), not exactly-one,
  because a native curve lane and an IT-bound lane name none. A note's `:ch` defaults to 1 and
  never to the lane's (`schema/tempura.sjon:397`; the `default_note_ch` ruling in
  `doc/fromSjon.zig`, [11](11-demos-and-milestones.md) 2026-09-21). `passthrough_preferred_native`
  is the one `Diag.Code` nothing raises (`tools/zt audit-diagnostics`: 88 of 89 covered, 1
  pending). **A live gap, not prose drift:** `:expr` and `:query` are kept as source text
  (`src/doc/fromSjon.zig:1237-1242`) and never compiled or checked against pacer's
  environment or `PatternQuery` — nothing in `src/` references either — while the manifest's
  own `:query` description says "compiled at build" and the generated `docs/timeline-language.md`
  repeats it. Either the loader compiles them (a diagnostic with a span, as the description
  promises) or the description says "carried verbatim; pacer compiles it". Filed for the user;
  the schema text is the smaller change and the wrong one if the exporter is meant to refuse a
  query that will not compile.
