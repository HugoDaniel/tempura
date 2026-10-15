# 03 — The Time Model

Status: Active — 2026-09-19. Part of the [tempura plan set](README.md). Owns **P103**
(`src/time/`) and the grid every other part converts to. The grid, the position units and
the printer's spelling rule **freeze at E1**.

Three sources measure time three ways: pacer in ticks per bar (`PPC = 720 720`,
`~/Dev/SJON/src/Pattern.zig:34`), a Standard MIDI File in ticks per quarter note (`division`,
1..32767), an Impulse Tracker module in ticks of `2.5 / tempo` seconds grouped into rows of
`speed` ticks (it 06, "Timing state machine"). tempura's document must hold any of them
without rounding and export to pacer without rounding. This doc fixes one integer grid that
does both, the spellings a document uses for positions on it, the tempo and meter maps that
give it seconds and bars, and the derivations for the three kinds of conductor.

## The grid

**`TPQ = 46 126 080` ticks per quarter note** `= 2¹⁰ · 3² · 5 · 7 · 11 · 13 = 64 · PPC`.
Positions are `i64` ticks (`Tick`), the same type SJON's pattern engine uses, with the same
portable ceiling (`MAX_TICK = 2^53`, `Pattern.zig:51`): 195 273 460 quarter notes, about
27 000 hours at 120 quarter notes per minute. Past it is a `tick_overflow` diagnostic, never
a wrap.

What lands exactly, verified by a test that enumerates each row (P103, phase 1):

| Source | Its unit | In tempura ticks | Exact when |
|---|---|---|---|
| SMF, division `PPQ` | `1 / PPQ` quarter | `TPQ / PPQ` | `PPQ` divides `TPQ`: 24, 48, 96, 120, 192, 240, 384, 480, 960, 1024, 1920, 3840, 7680, 15360 and every other divisor; **not** 500, 1000, 30720 (nearest tick, counted in the dump's diagnostics as `division_inexact`) |
| Impulse Tracker | one tick, `1 / 24` quarter (it 06: beats accumulate as `ticks / 24`) | `1 921 920` | always; a row of speed `s` is `s · 1 921 920` |
| pacer, meter `[n d]` | one pacer tick, `1 / PPC` bar; a bar is `n` beats of `4 / d` quarters | a bar is `(256 n / d) · PPC` ticks; one pacer tick is `256 n / d` tempura ticks | a tempura tick is a pacer tick iff it is a multiple of `256 n / d`, an integer for every meter tempura allows (`d` a power of two, below); pacer bounds **both** components to integers 1..16 (`pacer/schema/pacer.sjon:41-45`) and also accepts a `d` that is not a power of two, which tempura never emits ([08](08-export.md), `export_meter_unsupported`) |
| SJON `PatternQuery`, one cycle | `1 / PPC` cycle | one cycle is one bar: the meter's row above | as pacer's |
| tuplets | `1 / (2^a · 3^b · 5 · 7 · 11 · 13)` of a quarter | integer | `a ≤ 10`, `b ≤ 2`; any DAW's quantise menu |

Worked divisors: `[4 4]` and `[2 2]` and `[16 16]` → 256; `[3 4]` and `[6 8]` → 192; `[5 4]` →
320; `[7 8]` → 224; `[9 8]` → 288; `[12 8]` → 384; `[11 8]` → 352; `[13 16]` → 208. So a
tempura document's positions convert to pacer's by one exact integer division whenever they
sit on pacer's lattice, and `export-score` reports the count and the maximum error otherwise
(rung 4 of the ladder, 00). This corrects a claim in the midi set: at 480 PPQ a 32nd note is
tick 60, not a multiple of 8, so it is *not* on pacer's grid (midi 05's table says it is);
on tempura's grid it is tick `TPQ / 8 = 5 765 760`, exact, and rounds only at export.

Why per quarter note and not per bar: a bar's length changes with the meter, a quarter's does
not; SMF and IT both count quarters; pacer's per-bar grid is reached by the divisor above.
Why `64 · PPC` and not a larger multiple: `2¹⁰` covers 1024 PPQ and every binary subdivision a
DAW offers; the odd part is SJON's and pacer's, kept whole so the family shares one set of
tuplets; and 2^53 headroom stays in the tens of thousands of hours.

## Positions

The `position` value kind is a number with a required unit. Five units:

| Unit | Meaning | Resolution |
|---|---|---|
| `q` | quarter notes, decimal | `tick = round_half_even(value · TPQ)`, one multiply, one round |
| `t` | tempura ticks, integer | as written; a fraction is `position_not_integer` |
| `bar` | bars, decimal, from the meter map | integer part through the bar table, fraction scaled by that bar's length |
| `b` | beats counted from 0 across the meter map, decimal | the bar table carries the cumulative beat count at each bar line; the integer part finds bar `m` and beat `k` in it, at `bar_start(m) + k · (4 / d) · TPQ` for that bar's `d`; the fraction scales by that beat's length |
| `s` | seconds, decimal, through the tempo map | `TimeMap.tickFromSeconds`, below; **forbidden** on `tempo-point` and `meter-point` (circular, pacer's rule for `(tempo :at …)`) |

Rules: a plain number in a position slot is `unit_required` (SJON's `(unit-shape :required
true …)`, pacer's `time-pos` spelling); `bar` and `b` count from 0 like pacer's; a negative
position is `position_negative`. The literal-to-tick conversion for `q`, `bar` and `b` is
**one multiply and one round to nearest, ties to even**: a literal names the nearest tick, so
every literal is exact by definition and a printed `q` value round-trips because the printer
checks it (below). This is the one place tempura rounds where pacer floors
(`pacer/src/TimeMap.zig:7-17`); a clock value floors, a literal rounds, and the two never
meet because `s` literals go through the clock path.

Durations (`:dur`, `:length`, `:offset`) are positions measured from the form's own `:at`; an
`s` duration resolves at that anchor through the tempo map (pacer's it-wave rule, `plans/it/01`
Phase 3).

**The printer's rule** (canonical `toSjon`, frozen at E1): a tick prints as `Nbar` when it is
a bar line, else as `Nq` when `9009` divides it (`TPQ / 9009 = 5120 = 2¹⁰ · 5`, so `k / TPQ`
is a terminating decimal iff `9009 | k`; the printer emits the shortest decimal that
round-trips, at most 10 fractional digits since the reduced denominator divides `5120`),
else as `Nt`. Dumps of quantised material read as
music (`16bar`, `2.5q`); triplets and freely played material read as ticks. A hand-written
document may use any unit anywhere; only the printer is constrained.

## Tempo

```sjon
(tempo-point :at 0q    :qpm 125)        ; quarter notes per minute, fractional legal
(tempo-point :at 64bar :us 400000)      ; microseconds per quarter note, SMF's own field
```

- One `tempo-point` at tick 0 is required when the document has no `:conductor`
  ([02](02-timeline-schema.md)); the rest are strictly ascending in `q`, `bar`, `b` or `t`
  (`tempo_map_invalid` with the form's span, pacer's discipline; two at one tick are the same
  diagnostic, pacer's rule).
- Exactly one of `:us` (integer, 1..16 777 215, the SMF `set-tempo` range) or `:qpm`
  (1..1000, fractional legal, the IT `Txx` range 32..255 inside it), an `(exclusive-group …)`.
  The authored spelling is preserved by the printer; a document imported from a `.mid` says
  `:us`, from a `.it` says `:qpm`, and both stay exact in text.
- Tempo is a step function. `:ramp` is parked (00's non-goals); a source that slides (IT's
  `T0x`/`T1x` per tick) yields one segment per tick and coalescing happens at export.

**The segment table.** `Time.derive` turns the points into `{tick_i, us_i, tps_i,
start_sec_i}` with `us_i = :us` or `60 000 000 / :qpm` (one f64 division), and the table in
**pacer's own shape** (`TimeMap.zig:18-40`: a seconds origin per segment and a ticks-per-second
rate), never a microseconds origin that is scaled by `1e6` on the way in and out:

```
tps_i            = (TPQ · 1e6) / us_i                       ; one mul, one div
start_sec_0      = 0
start_sec_{i+1}  = start_sec_i + Δtick / tps_i              ; Δtick exact i64→f64, one div, one add, never reassociated
seconds(tick)    = start_sec_i + (tick − tick_i) / tps_i    ; the active segment by linear scan (≤ 4096 segments)
tick(seconds)    = tick_i + max(0, floor((seconds − start_sec_i) · tps_i))
```

Two float seams, each one shape; same document + same f64 seconds ⇒ same tick on every host.
A segment start is exact by construction: `seconds(tick_{i+1})` **is** `start_sec_{i+1}`, the
table entry, so `tick(seconds(tick_{i+1}))` returns `tick_{i+1}` (a microseconds table does
not have this property: `:qpm 97.3` then `150` at `13q` returns the boundary tick minus one
after the `/ 1e6 · 1e6` round trip, the fixture in phase 2). Interior ticks make no such
claim: a seconds value floors to the last tick begun, and `seconds(k)` may sit one ulp below
`k`'s true start, which is the accepted meaning of a clock value. The `max(0, …)` clamp covers
a seconds value that selected segment `i` and lands an ulp before its origin.

When every `us_i` is an integer (an SMF conductor, or a document whose tempo points all say
`:us`), the origins are instead accumulated **undivided** as exact integers, `T_i = Σ_{j<i}
Δtick_j · us_j` in i128 (midi 04's integer table, `midi/04-fold-runtime.md`, "Time"), with
`seconds(tick) = (T_i + (tick − tick_i) · us_i) / (TPQ · 1e6)` (one division) and
`tick(seconds) = tick_i + max(0, floor((seconds · (TPQ · 1e6) − T_i) / us_i))`, the same clamp
doing the same job at a boundary. A single `:qpm` point makes a `us_i` fractional and the whole
table takes the f64 path above. Both paths are corpus-pinned and a document never mixes them
at run time. The segment cap is `MAX_TEMPO_SEGMENTS = 4096` (a per-tick IT slide over a whole
song is a few thousand; pacer's 512 is the *export* budget, 08).

Loop and hold: `(timeline :end loop)` wraps seconds first, then converts (pacer's mapped-score
rule, `TimeMap.zig:34-37`); `hold` clamps at `seconds(length)`. `Playhead.at` is the only
caller; `evalTicks`-style callers pass ticks and wrap ticks.

## Meter

```sjon
(meter-point :at 0bar  :sig [4 4])
(meter-point :at 32bar :sig [3 4])
```

- One at tick 0 required without a `:conductor`; the rest ascending, and each must sit on a
  bar line of the meter before it (`meter_off_bar`, the form's span): a meter change mid-bar
  is not a thing in any source format.
- `:sig [n d]`: `n` 1..64, `d` in {1, 2, 4, 8, 16, 32} (SMF's `dd` is a power of two; a
  `d` that is not one has no source and no exact bar length here). pacer bounds both
  components to 1..16 (`docs/score-language.md`, `meter-component`), so `export-score`
  refuses `n > 16` and `d = 32` with `export_meter_unsupported` and falls back to `[4 4]`
  over quarter notes ([08](08-export.md)). SMF's extra fields (`:clocks`,
  `:thirty-seconds`) belong to the `midi/` tier, not here.
- **The bar table**: from the meter segments, `bar_start(m)` for every bar up to `:length`,
  built once per derive; `barOf(tick)` is a binary search, `beatOf(tick)` divides the
  remainder by `(4 / d) · TPQ`. A bar is `(4 n / d)` quarters; in ticks `(256 n / d) · PPC`,
  the pacer divisor row above.

## Three conductors

`Time.derive(Doc) → TimeMap` builds the segment table, the bar table, the sections and cues
in ticks, the per-lane onset lists, the length and the loop point. Where the tempo and meter
come from depends on `(timeline :conductor …)`:

1. **None**: the document's own `tempo-point`s and `meter-point`s.
2. **An SMF anchor**: every `set-tempo` in every track merged by tick (stable; equal ticks keep
   file order and the last wins), each `us` as written; `time-signature` events likewise, `nn`
   and `2^dd` as `[n d]`; SMF tick `k` → `k · TPQ / PPQ` (exact, or nearest with
   `division_inexact` counted once per dump). The midi set's rule that tempo on any track is
   honoured (midi 04, "Time") stands. A file with **SMPTE division** is one segment at 120
   quarter notes per minute over the converted PPQ and its `set-tempo` events are ignored for
   timing (`smpte_tempo_ignored`, a warning): SMPTE ticks are wall-clock by definition and
   that segment reproduces them exactly ([05](05-smf-core.md), "Chunks").
3. **An IT anchor**: **the timing walk** (`itf/walk.zig`, it 06's `Timeline.derive` with the
   audio chain off, copied whole into [06](06-it-core.md)): the order walk with every
   timing-affecting effect (`Axx` speed, `Txx` tempo set and `T0x`/`T1x` slides per non-row
   tick, `S6x` frame delay, `SEx` row delay, `Bxx` jump, `Cxx` break, `SBx` pattern loop,
   `+++` skip and `---` end, restart at the end). Output per played row: `(order, row) →
   start tick` in IT ticks, the tempo at every tick, the loop point. tempura ticks are
   `IT ticks · 1 921 920`; segments are one per tempo change (a slide yields one per tick);
   `qpm` is the IT tempo (the 24-ticks-per-quarter convention, it 06). Bars come from the
   module's highlight `[minor major]` when set (rows per beat and per measure) as one
   `meter-point` at 0 with `[major / minor, 4]`, else `[4 4]`, and a speed change moves the
   row grid, never the bar grid; the residue may carry a real meter map on top.

The three produce the same `TimeMap` shape, and the corpus pins each ([09](09-conformance.md)).
An SMF or IT conductor makes the document's own `tempo-point`s and `meter-point`s an error
(`conductor_conflict`): one owner of time per document.

## Position queries (`Playhead`)

What an editor or a host asks, all lookups over `TimeMap` and `Doc`, none of them evaluation:

| Query | Answer |
|---|---|
| `at(seconds)` | `{tick, bar, beat, sub_ticks, seconds_into_bar, section_ids[], prev_cue, next_cue}` after the end-behaviour wrap |
| `secondsOf(pos)` | the inverse, for a scrub bar |
| `snap(tick, grid, opts)` | the nearest grid line for a subdivision (`1/16`, `1/12`, `1bar`) under the meter in force; `opts.swing` offsets odd lines; deterministic tie rule (down) |
| `sounding(lane, tick)` | notes whose `[at, at + dur)` contains `tick`, in onset order |
| `onsets(lane, from, to)` | onset ticks in a window, the census for `export-score` and the studio dialog |
| `curveAt(lane, tick)` | the two keyframes around `tick` and the easing name between them; **not** the interpolated value (00's non-goal) |
| `orderRowAt(tick)` | for an IT conductor, the `(order, row, tick_in_row)` at a tick, so the studio shows the tracker position with no renderer readback (it 09's rule) |

The wasm exports mirror these ([10](10-hosts-and-cli.md)).

## Phases (P103)

1. **Grid and positions (RED first).** Load: nothing. Reds: the exactness table above, row by
   row (every listed PPQ divides `TPQ`; 500 does not; IT's tick; every pacer meter's divisor);
   literal parsing for the five units with the round-half-even rule and the `unit_required`,
   `position_not_integer`, `position_negative` diagnostics; the printer's rule (bar, `q` when
   `9009 | k`, else `t`) with a round-trip property test over random ticks. Green:
   `time/Pos.zig`, `time/Grid.zig`. Gate: `zig build test`.
2. **Tempo and meter maps.** Reds: the op-order table on a three-segment map, boundary-exact
   both ways and at the boundary, including `:qpm 97.3` then `150` at `13q` (tick
   `599 639 040` comes back from its own seconds) on both the f64 and the integer path;
   `:us` versus `:qpm` giving the same segment when they agree
   (`480000` and `125`); `meter_off_bar`; the bar table under a `[3 4]` → `[4 4]` change;
   loop wrap into the early segment; hold; `tick_overflow` and `NonFiniteTime`. Green:
   `time/TimeMap.zig`. Gate: test.
3. **Three conductors.** Reds: the same three-segment map authored natively, as an SMF with
   tempo on track 2, and as an IT module with `Txx` rows produces byte-identical `TimeMap`
   text; an IT module with `T0x` slides yields one segment per tick; `conductor_conflict`.
   Green: `time/derive.zig` over `itf/walk.zig` and `smf/`. Gate: test + first corpus cases.
4. **Playhead.** Reds: every query above on a fixture with overlapping sections, two cues
   and a meter change; snap with and without swing; `orderRowAt` against the walk's row map.
   Green: `time/Playhead.zig`. Gate: test + corpus.

## Risks / open questions

- **Round versus floor.** Two conventions in one repo invite a bug. The rule is mechanical
  (literals round, clocks floor) and each has one function; a lint test greps for `@floor`
  and `@round` outside those two functions.
- **Readability of `t` positions.** A dump of humanised MIDI is a wall of nine-digit ticks.
  That is the honest size of the data; a `--print q` option that prints the nearest `q`
  decimal *and* the exact `t` in a trailing comment is the E1 answer if hand-editing such
  dumps proves common.
- **Tempo precision through `.mid`.** A native `:qpm 143` builds to `set-tempo` `419580` (the
  nearest integer µs); re-read, that is `:us 419580`, not `:qpm 143`. Essence-exactness holds
  because the residue carries the authored form ([04](04-residue.md)); the *audible* tempo
  differs by under one part per million, stated in the build's diagnostics.
- **Non-power-of-two SMF denominators** cannot occur (`dd` is a power); a `.it` highlight of
  `[3 12]` (12 rows per measure, 3 per beat) gives `[4 4]` in quarters only if the rows-per-beat
  matches the speed's quarter; the derivation states the convention and the residue overrides
  it when a real meter map exists.

- **Drift, read against the tree on 2026-09-29 (`cfe44a0`).** `TimeMap` has no `beatOf`:
  `barOf` answers `{bar, beat, sub_ticks, meter}` (`src/time/TimeMap.zig:299-316`) and the
  beat is its field. The "lint test greps for `@floor` and `@round` outside those two
  functions" does not exist: `tools/lint.zig`'s rules (`:57-70`) name no such check, and the
  two builtins sit at thirteen production sites (`export/pos.zig:117, 314, 365`,
  `export/quantize.zig:27`, `export/render_it.zig:853`, `export/render_smf.zig:748`,
  `edit/ops_quantize.zig:39`, `edit/ops_bound.zig:1831`, `doc/toSjon.zig:572, 593`,
  `residue/it.zig:662`, `corpus_runner.zig:747`), each on a documented seam or a printer.
  Whether the rule should become a lint (listing those sites as its allowlist, which plan 12's
  "no allowlist" ruling forbids) or the sentence should say "each seam is named in its file's
  header" is filed for the user; the determinism gate today is the corpus and the wasm parity
  walk, not a grep.

- **Ask T2 from animader (2026-09-29): a frame unit.** tempura is meant as the timeline core
  for any timeline, an After Effects or Blender one included, and those count frames. Wanted:
  a sixth position unit `f`, frames through a declared rate, with the rate's spelling to
  decide (a `:fps` on `(timeline …)`, or a fourth conductor kind) and an off-grid frame a
  `frame_inexact` diagnostic, never a wrap. The units and the printer's spelling rule froze at
  E1, so this is a deliberate append, and the printer writes `f` only for a document that
  wrote it. Arithmetic checked on 2026-09-29, not code: with five quarters a second
  (`:qpm 300`) a frame is `5 · TPQ / fps` ticks, an integer at 24, 25, 30, 48, 50, 60, 90,
  100, 120, 144 and 240; 29.97 and 23.976 never land, as in SMF. Not built; waits on a piece
  that counts frames.

- **T2 ruled, built and corrected (2026-10-15).** The ask above is built (`c6f72b2` the
  schema key and the two codes, `a2d308d` the resolution, `da84f68` the printer's rule,
  `ecc777b` the exact judgment, `dc57775` the frame-free edit spellings); the "waits on a
  piece that counts frames" gate was waived by the owner on 2026-10-14, recorded here rather
  than deleted. The ruling: the rate is `:fps` on `(timeline …)` — an integer or an exact
  rational `[num den]` (`[30000 1001]`; a bare decimal is refused, 29.97 would mean
  2997/100) — and NOT a fourth conductor kind; frames resolve through whatever map conducts
  (`fromSjon.mapOf` threads `Doc.frames()` beside the conductor's tables). No default rate:
  an `f` position with no `:fps` is `frame_rate_missing` and is not placed; a declared rate
  with no `f` position is harmless and changes no spelling. An off-grid frame floors to the
  tick beneath and warns `frame_inexact` — never a wrap. Exactness is now two declared
  regimes: on the integral map (whole-`:us` segments inside `EXACT_US_MAX`) the literal, the
  duration and the printer's frame line judge in exact integers end to end — integer
  cross-multiplication over the segment table, the frame value reduced and dyadic-or-none —
  after a review showed both f64 directions lying one ulp apart (frame 35 at the fallback
  tempo answered one tick short; `:at 20f :dur 1f` at `:fps 25`/`:qpm 300` warned on an
  exact one-frame span); the f64 path (a fractional `us`) keeps its one float seam and is
  determinism-only, the declared limit. The printer writes `f` only for a document that
  wrote it (`Doc.wrote_frames`, authored intent — set even where the literal is refused,
  excluded from `eql`), a frame line ahead of `Nbar`, checked by reading back; tempo and
  meter points — `grid-position`, which refuses `f` as it refuses `s` — stay frame-free in
  print and in edits (`TimeMap.spellGrid`, `edit/value.positionGrid`), so a frames document
  survives its own tempo and meter edits. A rate alone leaves every position byte as the
  frozen rule spelled it; the only new bytes are the header's `:fps`. Dated correction of
  the ask's arithmetic: "29.97 and 23.976 never land, as in SMF" is false — at `:qpm 300` a
  `[30000 1001]` frame is `192 384 192/25` ticks, so every 25th frame lands (frame 25 IS
  tick 192 384 192) and a `[24000 1001]` frame is `48 096 048/5`, so every 5th one does
  (frame 5 IS tick 48 096 048); both are pinned by test. Not fully complete: the
  `frames-25` and `frames-ntsc` corpus cases, plan 02's `:fps` key row and plan 11's ledger
  are the remaining sweep — no corpus case uses `f` today, so no golden moved.

- **T2 completed (2026-10-15).** The remaining sweep the entry above named is done, this
  correction appended beside it. `corpus/frames-25/` is the exact regime: at `:fps 25`
  under `:qpm 300` a frame is `230 630 400/25 = 9 225 216` ticks, `:at 20f :dur 1f`
  spans 184 504 320 → 193 729 536 with ZERO `frame_inexact` (the repro's silence, now a
  golden), and the dump re-spells a `1q` note as `5f` — the frame branch ahead of `Nbar`.
  `corpus/frames-ntsc/` is the rational rate: a `[30000 1001]` frame is `192 384 192/25`
  ticks, so `1f` floors to 7 695 367 with one warning per literal (position and duration)
  while `25f` IS tick 192 384 192 — the exact multiple of an otherwise off-grid rate —
  printed `25f` with no warning and asked back by `(at :tick 192384192)`. Both goldens
  generated by `tools/zt corpus -- --update` (`0911345`); no preexisting golden moved (86
  regenerated, 84 byte-identical), a one-tick perturbation of either new golden fails the
  gate and the byte-identical restore goes green, and the wasm parity walk re-derives both
  through `tempura.wasm`. Plan 02's header-key list gained its dated `:fps` row; plan 11's
  asks ledger carries the same correction. The implementation is LOCAL, committed on
  `agent/animader-init`, and NOT published to or accepted by animader — no integration,
  browser verification or independent review has run.

- **T2's tiny-regime defect ruled and fixed (2026-10-15).** The final ruling's finding 1
  (`.agent/control/t2-final-ruling.md`): `frameParts`' `shift > 100` cutoff was an i128
  guard wearing a semantic flag — it answered the anchor for any literal under `2^-48`
  frames, though the instant is `n·den/num` seconds and can be millions of ticks wide at
  schema-legal extremes. Red, reproduced twice (the production CLI in
  `.agent/control/runs/t2-final-rule-cli.log`, then the named unit tests): at `:fps
  [1 100]` under `:us 1` — one tick is `1/(TPQ·1e6) s ≈ 2.17e-14 s`; the ruling's prose
  said `1/46126080 s`, missing the microseconds-to-seconds `1e6`, but its numeric value
  and its floors are right — the literal `2e-15f` is `2e-13 s = 9.225216` ticks and was
  answered `tick 0` while the clock (`--seconds 2e-13`) said 9; the `1q` note's `2e-15f`
  duration collapsed to span 0 and lost its sounding line. Fixed by the two-arm exact
  test seated in `exactFloor` (`26ffa26`): tiny ⟺ `r_num/r_den < us_a`, arm A PROVING
  `num·2^shift` cannot fit i128 (`r_den > 2^127 > r_num < 2^123`) and arm B the
  floor-shift compare `(r_num >> shift) < us_a·num` — no threshold, no tolerance, no
  widening, no f64 fallback, and the non-tiny `r_den` now proven to fit rather than
  guarded; the walk's `dt + r_num` became a sign-split compare after a constructed
  envelope-edge anchor PANICKED red (`integer overflow`, Debug). The reviewer's
  `shift > 121` repair stays REJECTED — `num << 121` wraps i128 for every schema-legal
  `num > 64`. `corpus/frames-tiny/` pins the regime: the position prints `9t`, both
  durations span `9t`, the clock's `(times "3D4C25C268497682")` answers tick 9 — the two
  routes in agreement — generated by `tools/zt corpus -- --update`; no preexisting
  golden moved (87 regenerated, 86 byte-identical), native corpus 87/87 and the wasm
  parity walk both green. The ruling's remaining findings (2-5, the kind rename, the
  vendored-player sync) are later slices' owns, not this one.

- **T2's final sweep ruled and fixed (2026-10-15).** The final ruling's findings 2-5 and
  the integration collision, discharged in two commits beside the tiny-regime fix above.
  Findings 2-5 (`00fd35c`, docs and comments only): plan 11's false "T1, the source map,
  remains an ask" superseded by a dated correction — T1 is BUILT and consumed (ruled
  2026-10-04 in [08](08-export.md), built 2026-10-08 by `f2e8c43`..`ee21c33`, consumed
  the same day by animader `7e14dfa`..`88a370c`), and the LOCAL/not-published sentences
  stand for T2 only; the schema's `:fps` description now says the true thing (a rate
  alone changes no position's spelling; the header keeps `:fps`) with
  `docs/timeline-language.md` regenerated by `tools/zt docs`, idempotent; two stale
  TimeMap comments corrected (`tick 193 729 536`'s grouping; `spellDuration`'s frame
  branch exists and writes `f` only when both ends read back exactly) and `frameLine`'s
  doc now states its standing — no in-crate production caller, retained deliberately as
  the public frame-line oracle, `isBarLine`'s integer twin. The collision
  (`frame-rate`, claimed by tempura's `c6f72b2` and animader's earlier `ff6c57d`):
  tempura's union kind RENAMED `timeline-frame-rate` (helpers stay; no animader edit;
  [02](02-timeline-schema.md)'s dated note carries the full verdict), and tempura gained
  the regression the ruling demanded — a sibling-composition leg
  (`src/schema_tests.zig`) that loads animader's five live `schema/*.sjon` manifests
  with tempura's bundle through the real SJON aggregate and requires ZERO diagnostics.
  Fail-first: red on the day it was written with both diagnostic identities recorded —
  `ambiguous_element_kind` on `timeline`'s `:fps :type` and on `frame-clock`'s
  `:positional`, "defined by [tempura, animader]" — full suite 1006/1007; green after
  the rename, 1007/1007. Mutation-tested: the old name restored goes red again and the
  byte-identical restore goes green; a `TEMPURA_ANIMADER` that points nowhere prints
  one line naming the override and the default `../animader/animader` and skips that
  single check (160/161, 1 skipped); an override at a checkout with an EMPTY `schema/`
  fails rather than skips (`EmptySiblingSchemaDir`) so a broken sibling can never
  compose nothing and claim clean. Gates at the final tree: corpus 87/87 with no golden
  moved, lint 90 files clean, wasm 1 417 077 B (95% of ceiling) with the rename
  embedded, npm `node --test` 137/137, `verify` 1022/1022 tests / 25 steps with the one
  documented environmental cli-golden failure, whose real leg through the sanctioned
  shim is green. The vendored-player sync stays DEFERRED per the ruling's ordering
  (sync once, after the rename stage's rebuild) and is the next task's with the
  animader-side verification — no integration, browser or publish claim is made here.
  The ruling itself is now committed history: an UNEDITED byte-exact copy (cmp) lives
  at [evidence/t2-final-ruling.md](evidence/t2-final-ruling.md), superseding the
  control-plane citations in the entries above only as a POINTER — the entries' text
  stands. Two known defects in that copy are history, corrected where they were made:
  its source-line references are pre-fix (the tiny-regime fix shifted TimeMap's lines),
  and its "one tick is `1/46126080 s`" misses the µs→seconds `1e6` — the correction is
  the tiny-regime entry above, which the copy's own numeric value agreed with.
  **Standing: T1 is built and consumed. T2 is BUILT, ruled and fixed — committed
  LOCALLY on `agent/animader-init`, not published to or accepted by animader; the
  animader-side rebuild, vendor sync and consumer gates are the next task's, and until
  they run, T2's integration is pending, not claimed.** README's corpus count stays 87.

- **T2's final LOCAL verification and acceptance record (appended 2026-10-16; every
  run it cites is dated 2026-10-15).** The standing sentence two entries above —
  "the animader-side rebuild, vendor sync and consumer gates are the next task's,
  and until they run, T2's integration is pending, not claimed" — is superseded
  here: those three have run, LOCALLY, and so have the browser verification, the
  independent confirm review and the design acceptance. Nothing is published,
  merged upstream, tagged or released. The evidence is control-plane fresh runs
  read from logs, not worker claims; every hash below was re-derived at this close
  with Python `hashlib` (the host `sha256sum` is broken). Tips: tempura `2a72105`
  (tracked tree clean; only the preexisting `zig-pkg/` scratch), animader `284f66d`,
  pacer `5f28aaa`, pngine `741ce92b`. Artifacts: `tempura.wasm` 1 417 077 B, sha256
  `8014cc8a6ff4e194bc24cec19a7970bc224372e0174b6ab5a45720aa93f3c33b`;
  `animader.wasm` 1 176 321 B, sha256
  `00f923da8e5a46b3fa2ca49e3b82aba44efc61fd6ae35f84339170836f373262`; the
  hello-player vendor copy was re-synced locally and is byte-identical to `zig-out`
  — a local sync, not a deployment or a release. tempura gates at `2a72105`:
  native 1024/1024, corpus 87/87, npm 137/137 with 0 skipped, wasm 95% of its
  ceiling — and the aggregate `verify` is NOT a pass on this host: 25/27 steps,
  the one failure the environmental `cli_golden.sh` (obs ksh93, missing `shasum`),
  whose sanctioned bash+t2-shim leg is green ("CLI output is current", exit 0).
  animader: 18/18 steps, 403/403 tests, npm 112/112 with 0 skipped, corpora
  log 8 / machine 7 / session 3 / piece 4, and the composed probe PROBE PASS
  through the real `PieceHost.score`/`scoreMap` → pacer → run core. The two
  rounding semantics, kept apart all the way through: a tempura frame's exactness
  is tempura's own — NTSC `25f` IS tick 192 384 192 — while pacer's grid rounds
  (`mul + floor`): that exact tick maps UP to pacer tick 751 501, the wall-clock
  floor of 1001/1200 s is 751 500 (one pacer tick under the event), and the
  floored `1f` lane begins at pacer 300 60. T1, the source map, stays BUILT and
  consumed (2026-10-08), its `'TPMP'` spans verified against the document by the
  probe; the frame-clock world provider's part in the matrix is a clean identity
  load (`scoreMap` state `identity+null`) — its provider EXECUTION remains
  unimplemented, exactly as before. Real-browser matrix, Chromium and WebKit at
  1280x900 and 390x844: tempura 8/8 and the composed consumer 4/4 on every engine
  and viewport, every artifact digest equal to the disk pins — the report is
  copied verbatim to
  [evidence/t2-browser-verification.md](evidence/t2-browser-verification.md) (line
  references as measured; the eight screenshots live only in the ignored `.agent/`;
  the copy note beside it corrects the acceptance log's concluding phrase "T1
  frame-clock consumer", which conflates the source map with the provider and is
  repeated nowhere as a claim). Design acceptance: PASS, no blocker or important
  finding, two optional fixture nits (a benign favicon 404; mid-token wrap of
  long monospace lines at 390px). Independent confirm review: MERGE-WORTHY at
  `3345301` with one LOW test-helper finding, fixed AFTER the review by `2a72105`
  with both fail-first tests (a segfault red and a leak red, then 1009/1009 on the
  full suite, 1024/1024 with lint in the fresh verify) — the verdict's exact tail
  with its annotations is
  [evidence/t2-confirm-review-verdict.md](evidence/t2-confirm-review-verdict.md).
  The consumer-side kind collision that the composed-manifest guard exists for was
  resolved by the rename to `timeline-frame-rate` (`3345301`,
  [02](02-timeline-schema.md)). And nothing above adds or implies a default rate:
  an `f` position with no `:fps` is still `frame_rate_missing`, and a rate alone
  still spells nothing. The ruling stays committed at
  [evidence/t2-final-ruling.md](evidence/t2-final-ruling.md). **Standing: T2 is
  built, ruled, fixed, locally integrated and locally verified — not published,
  not accepted by animader beyond this machine, no artwork or GPU-motion claim,
  and the aggregate tempura `verify` stays host-red on the one environmental CLI
  leg.** README's corpus count stays 87.
