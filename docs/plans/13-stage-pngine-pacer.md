# 13: The Stage. A pngine square conducted by a tempura timeline, its movements as tracker channels

Status: Draft, 2026-09-29. Part of the [tempura plan set](README.md). Owns **P110**
(`examples/square/`, `demos/e5-stage/`, three items in `src/export/` and `src/residue/`) and
milestone **E5**. Written against tempura `cfe44a0`, pacer 0.2.0 (`63cd0ed`), pngine 4.0.0
(`0270f5d`; the npm version, its `build.zig.zon` says 0.1.0), pstudio `b8464f5`, animader
`ff0eb04` (`animader/docs/07-road.md`) and the expansible-player plan set (`~/llm` at
`23ef69d`), all read on 2026-09-29 and every citation re-read against the checkouts the same
day. Line citations are to those checkouts.

## The question

Can tempura, with pacer, make a pngine piece in which a square moves, where the movements are
defined in a tempura timeline and exported as Impulse Tracker channels, so that musicians
compose their own tracks in the same file and know where every movement fires?

**Yes, and the forward direction runs today with no code change.** A timeline document with
one lane per movement exports a pacer score whose targets are the shader's uniform fields, and
builds a `.it` in which each movement is one channel, with the section list and the channel
map in the module's song message. That was run on 2026-09-29 with the shipped CLI; the
transcript is under "The document" below.

**The return trip needs one measurement and four changes in tempura.** A musician's re-save
is expected to keep the song message and drop the trailing chunk, and that has never been
measured (plan 04's log, `conformance/CHECKLIST.md` section C). Rebuilding into the musicians'
file works today only from a `dump` of that file: `tempura inline` copies the file's tiers
without the reconciliation `dump` runs, so the by-reference shape (`square.sjon` naming the
file as an anchor, inlined, built `--in-place`) renders every movement beside its previous
channel even with the chunk intact — measured on 2026-09-29, and the `inline` defect plan 11
filed on 2026-09-21. When the chunk is gone the message names the movement lanes but not the
channels they were rendered onto (`src/residue/it.zig:528-531` writes `:from` and the address
for a bound lane only), so neither shape can put a movement back where it was. Patterns are 64
rows (`src/export/render_it.zig:80`, no CLI flag), so the order list does not read as the
section list. A vector keyframe renders its first component only
(`src/export/render_it.zig:621`). Each is one phase below.

Two things are out of scope and stay where they are. pstudio is not a host (ruled
2026-09-20), so the pacer-to-pngine glue that lives there today is rewritten as a small page
in `demos/`. Playing a `.it` in a browser is batida's (`ITMD` is a reserved payload kind
with no handler); the page plays the musicians' bounce and pacer's transport is the clock.

## What exists, verified 2026-09-29

| Seam | Where it is | What it does |
|---|---|---|
| pacer writes into pngine uniforms | pstudio `editor/src/lib/preview/preview.ts:233, 514-546`; pngine `docs/journal.md:6902-6913` (§135) | `Pacer.load(wasm, score, {registries})`, then per frame `eval(t)` → `toUniforms(entries, 0)` (`pacer/npm/pacer/src/route.js:19-31`) → pngine `draw(p, {time, uniforms})` (`pngine/npm/pngine/src/anim.js:103-127`) → `setUniforms` (`gpu.js:984-990`, a loop over `setUniform` at 952-977). pstudio posts the same writes to its own worker rather than calling `draw`; the page calls `draw`. Registry 0 is the compiled program's uniform reflection (`pngine/src/bytecode/uniform_table.zig:1-24`; its coupling to the visual bus at 81-90); a target name is a bare field name, nested fields and array elements are dotted (`pngine/docs/sjon-reference.md:420-441, 462-463`). pngine has no dependency on pacer; the binding is a naming convention |
| the rule for a driven uniform | pngine `docs/journal.md:6950-6953` | a pacer-driven field lives in a dedicated `(buffer …)` with a unique bare name, never in `pngine-inputs`, which the frame overwrites after the host's write |
| a real piece on that seam | `~/Dev/2026_impulse/impulse.sjon`, `live.score.sjon`, `impulse-04.it` (on this machine; plan 11's E0 board, dated 2026-09-21, says the piece was absent then) | the impulsos trio: a `motion` buffer of four floats (`impulse.sjon:25, 50`) driven by bare-name tracks, a `denv` array of four `vec4f` (`impulse.sjon:26, 628`) driven by dotted vec4 tracks and triggers, `:emit [beat]` for the musical clock — the driving forms are `live.score.sjon`'s (tracks at 15, 32, 39; `:emit` at 11; triggers on `denv.0`/`denv.1` at 58, 62; vec4 tracks on `denv.2`/`denv.3` at 68, 88) — and a tracker module beside them with no timeline tier binding the three. This plan's square is that trio in miniature, with the timeline present |
| a trigger's value | pacer `docs/score-language.md:76`, `src/Eval.zig:583-597` | a notes lane becomes `(trigger …)`; each frame pacer writes (phase, count, gate, beats-since) truncated to the target's arity; before the first event the write is omitted and the uniform keeps its zeros; `gate` is 1 only on the event tick, so a shader detects an onset by `count` changing and shapes it from `beats-since` |
| timeline → score | plan 08, `src/export/score.zig`, `npm/tempura/test/landing.test.js` | every lane kind reaches pacer's vocabulary; every printed position lands through the real `pacer.wasm`; `--velocity` adds a `<name>-vel` hold track of `vel / 127` (`score.zig:516`) |
| timeline → `.it` | plan 08, `src/export/render_it.zig:1-40`, `examples/tracker/` | one channel per notes lane (more under polyphony), note cells with `^^^` cuts, the volume column for a curve lane, `Txx` for tempo points, both residue carriers attached, the sections and lane declarations in the message tail |
| a module conducting a timeline | plan 03, `examples/native.sjon` | `(anchor :id song :kind it :file …)` plus `:conductor song`: the module's timing walk gives the document its tempo and bars, and the movement lanes stay native in the document |
| the packed piece | plan 10, `demos/e4-packed/`, expansible-player 02 and 05 | `TMPU` is reserved on tempura's side only: expansible-player 02's kind registry ("the whole inventory", `02:41-57`, read 2026-09-29) lists `PACR` and `ITMD` and no `TMPU`, so the cross-set ask plan 10 assumes filed is still to file. The `score` handler that mounts pacer inside pngine's player is expansible-player 05's checkpoint C3, which lands at **X4** (`05:118-120`, `07:58-68`); X1 ships the `PNGB`, `PNGF`, `SNTU` and `META` handlers only (`02:59`). This plan's page is the interim host and becomes that handler's test piece when X4 lands |
| animader | `~/Dev/animader/animader/docs/07-road.md:63`, `examples/hello/player/player.js:23-24, 42-44` | no shape form yet (`shape` is parked until a piece wants one); the hello player's registry 0 is a hand-written name list (`[{heat}, {grain}]`) and the values are packed by position into a `params` buffer with `writeBuffer`, not set by name — so a score whose targets carry those names drives it once a runtime exists. Nothing to do here |

## The flow

```
square.sjon  (the timeline: one lane per movement, sections, tempo)
   │
   ├─ tempura export-score --velocity ─► square.score.sjon ─┐
   │                                                        │  page: pacer.eval(t) → setUniforms
   │      square.pngine.sjon ─ pngine compile ─► square.png ┴─► the square moves on the canvas
   │
   └─ tempura build --kind it ─► square.it   (silent: one channel per movement, the map in the message)
                                     │
                                     ▼  musicians, in OpenMPT or Schism: samples, their own channels, save
                                  song.it
                                     │
   square.sjon gains (anchor :id song :file "song.it") and :conductor song
                                     │
   tempura build --in-place ─► song.it re-rendered in place (the movement channels replaced, theirs untouched)
   tempura export-score      ─► the same score, now conducted by the module
   the page plays the musicians' bounce (song.flac) as the clock, and the same square
```

## The document: movements as lanes

`examples/square/square.sjon`, run through the shipped CLI on 2026-09-29 (`validate` clean,
`export-score` clean, `build --kind it` with the two expected warnings, `check-residue` with
every hash matching; re-run the same day from a clean directory, every line below
byte-identical):

```sjon
; A square on a stage: the movements a pngine shader plays, arranged in musical time.
(timeline :title "square" :length 8bar :end loop)
(tempo-point :at 0bar :qpm 120)
(meter-point :at 0bar :sig [4 4])

(section :name enter  :at 0bar :dur 2bar)
(section :name bounce :at 2bar :dur 4bar)
(section :name leave  :at 6bar :dur 2bar)
(cue :name "turn" :at 4bar)

; continuous parameters: one scalar curve lane per uniform field
(lane :name x :kind curve :target x :range [-1 1]
  (keyframe :at 0bar :value -0.8 :ease hold)
  (keyframe :at 2bar :value 0 :ease out-cubic)
  (keyframe :at 6bar :value 0)
  (keyframe :at 8bar :value 0.8 :ease in-cubic))
(lane :name size :kind curve :target size :range [0 1]
  (keyframe :at 0bar :value 0.1)
  (keyframe :at 2bar :value 0.3 :ease (spring :damping 0.4))
  (keyframe :at 8bar :value 0.3))

; triggered movements: one notes lane per movement; onset, duration, amplitude
(lane :name jump :kind notes :target jump
  (note :at 2bar :dur 1b :key 60 :vel 127)
  (note :at 3bar :dur 1b :key 60 :vel 96)
  (clip :at 4bar :phrase hops :repeat 2))
(lane :name spin :kind notes :target spin
  (note :at 4bar :dur 2b :key 62 :vel 110))

; the musical clock the shader reads, as a formula lane
(lane :name beat :kind formula :target beat :expr beat)

(phrase :name hops :length 1bar
  (lane :name jump
    (note :at 0b :dur 0.5b :key 60 :vel 80)
    (note :at 2b :dur 0.5b :key 60 :vel 80)))

; pacer's compose-mode declarations: the shader's uniform fields, one per target
(target :name x :arity 1)
(target :name size :arity 1)
(target :name jump :arity 4)
(target :name jump-vel :arity 1)
(target :name spin :arity 4)
(target :name spin-vel :arity 1)
(target :name beat :arity 1)
```

The rules the example follows, which the demo's README states for authors:

- **One lane per movement, and the lane's name is the shader's field.** A `notes` lane is a
  movement that fires: the note's `:at` is the onset, `:dur` how long it runs, `:vel` its
  amplitude. A `curve` lane is a parameter that moves: position, size, colour. The score
  side is fixed by plan 08 (a notes lane is a `(trigger …)` of arity 4, a curve lane a
  `(track …)`); the tracker side is fixed by the renderer (a notes lane is a channel of note
  cells with cuts, a curve lane a channel whose volume column holds the value).
- **Scalar lanes, one per axis.** `x` and `y` rather than a vec2 `pos`, because both
  renderers write a vector keyframe's first component only (`render_it.zig:621, 652`;
  `render_smf.zig:599, 641`) and a musician would see `x` and lose `y`. Phase 4 lifts this
  for vectors that must stay vectors (a colour); until then the example is scalar.
- **Amplitude is velocity.** `--velocity` prints a `jump-vel` hold track beside the trigger,
  which is the volume column of the same channel in the tracker. The musician sees "this
  hit, this hard" the way they see a drum.
- **`query` and `formula` lanes are invisible in the tracker** (`residue_only`): a `.it` has
  nowhere to hold them. They are for what the musicians need not see, such as `beat`.
- **Integer tempo.** `Txx` holds 32..255 as integers; a fractional `:qpm` is `tempo_inexact`
  and the module plays the nearest integer while the score keeps the authored value.

What the score carries (the exporter's output for the document above, abridged):

```
(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
(scene :name enter  :at 0bar :dur 2bar)
(scene :name bounce :at 2bar :dur 4bar)
(scene :name leave  :at 6bar :dur 2bar)
(track :target x (key :at 0bar :value -0.8 :ease hold) (key :at 2bar :value 0 :ease out-cubic) …)
(track :target size (key :at 0bar :value 0.1 :ease linear) (key :at 2bar :value 0.3 :ease (spring :damping 0.4)) …)
(trigger :target jump :at [2bar 3bar 4bar 18b 5bar 22b])
(track :target jump-vel (key :at 2bar :value 1 :ease hold) (key :at 3bar :value 0.7559055 :ease hold) …)
(trigger :target spin :at [4bar])
(track :target spin-vel (key :at 4bar :value 0.86614174 :ease hold))
(track :target beat :expr beat)
```

What the module carries (`check-residue square.it`):

```
chunk: present, read
tail: present
essence: 4115 bytes, envelope version 1
conductor: hash matches
lane x: channel 1 column vol, hash matches
lane size: channel 2 column vol, hash matches
lane jump: channel 3, hash matches
lane spin: channel 4, hash matches
```

and its song message, which is what a musician reads in OpenMPT's Comments tab or Schism's
message editor:

```
;; tempura
(timeline :title "square" :length 8bar :end loop)
(section :name enter :at 0bar :dur 2bar)
(section :name bounce :at 2bar :dur 4bar)
(section :name leave :at 6bar :dur 2bar)
(cue :name "turn" :at 4bar)
(lane :name x :kind curve :range [-1 1])
(lane :name size :kind curve :range [0 1])
(lane :name jump :kind notes)
(lane :name spin :kind notes)
(lane :name beat :kind formula :expr beat)
```

The lane lines name the movements and not the channels. That is the first gap, and phase 2
closes it.

## The pngine piece

`examples/square/square.pngine.sjon` is written in pngine's full form after the impulsos
piece: a dedicated uniform buffer, one fragment pass drawing a signed-distance box, and the
`pngine-inputs` buffer for the aspect. The `(pass …)` shorthand cannot be used because it
declares uniforms only for `pngine` and `pointer` (`pngine/docs/sjon-reference.md:1759-1790`).

```sjon
(buffer :name stage :size 64 :usage [uniform copy-dst])   ; every field below is a score target
```

```wgsl
struct Stage {
  x: f32,  size: f32,  beat: f32,  jump_vel: f32,   // 16 bytes
  jump: vec4f,                                       // phase, count, gate, beats-since
  spin: vec4f,
  spin_vel: f32, _p0: f32, _p1: f32, _p2: f32,
};
@group(0) @binding(0) var<uniform> stage: Stage;
```

The shader lifts the square by `jump_vel * exp(-4 * jump.w)` whenever `jump.y > 0` (a jump
has happened; `beats-since` is `jump.w`), turns it by an angle accumulated the same way from
`spin`, and places it at `stage.x` with side `stage.size`. All of that is the shader's
arithmetic over values pacer wrote; tempura evaluated nothing.

Three naming rules bind the three files, and a node test in phase 5 checks them:

1. **A lane's `:target` is a field of `Stage`, spelled the same.** Registry 0 is pngine's
   reflection of the compiled program; a name it does not know reaches `onError` with source
   `set-uniform` (`gpu.js:954-957`). `pngine square.pngine.sjon --types -o …` — the render
   command's sidecar (`render.zig:185, 455-463`); `compile` has no such flag — writes the
   field list as a `.d.ts`, which is the test's oracle.
2. **The `-vel` sibling is spelled `_vel` in WGSL.** A WGSL identifier cannot carry a hyphen
   and the exporter's suffix is fixed (`score.zig:516`), so the page renames `-` to `_` when
   it routes registry 0. A `:velocity-target` key on notes lanes is filed as a candidate and
   taken only if a second host needs it.
3. **A trigger's target has arity 4** and a velocity or curve target arity 1, both in the
   `(target …)` declarations and in the struct. Only some mismatches are loud: a track key
   wider than its target is pacer's `value has N component(s); target expects M`
   (`Compile.zig:1260`, the error `examples/native.sjon` once had), and a `(target …)`
   declaration that disagrees with registry 0 is `declared arity N for 'x' disagrees with
   the host's M` (`Compile.zig:1556`). A trigger carries no value and is truncated to its
   target's arity in silence (`Eval.zig:590-597`), so a `jump` declared `f32` in WGSL would
   receive its phase alone and no error. Phase 5's test therefore checks arities as well as
   names.

## The page

`demos/e5-stage/index.html` with a `package.json` naming the three sibling packages as
`file:` dependencies (`../../../pngine/npm/pngine`, `../../../pacer/npm/pacer`,
`../../npm/tempura`), which is the idiom `npm/tempura`'s own tests use for pacer. About 150
lines, modelled on pstudio's `preview.ts` and `registries.ts:108`, and the only host code in
the family that runs pacer against pngine outside pstudio:

1. Load `square.png` (the compiled program) through pngine's viewer; read its uniform
   reflection into registry 0.
2. Load `pacer.wasm` with `square.score.sjon` and `{registries: [registry0]}`.
3. Each frame: `t` from the master clock, `pacer.eval(t)`, `toUniforms(entries, 0)`, the
   `-vel` rename, then `draw(p, {time: t, uniforms})`.
4. The clock is pacer's `masterClock` (`pacer/npm/pacer/src/clock.js:33-50`, over
   `perfClock` at 14-17): it takes a host whose `clock()` answers `{seconds, playing}` and
   falls back to `performance.now()` while nothing plays. An `<audio>` element reaches it
   through `clockOnlyHost` (`audio.js:39-45`), which reads `currentTime` and a `playing`
   flag `HTMLAudioElement` does not have, so the page wraps the element in a few lines.
   pngine's own `requestAnimationFrame` clock is not used, so the picture and the music
   share one time.
5. `tempura.wasm` in the page, loaded with `square.sjon`, answers `tpr_at(t)` per frame for a
   bar, beat and section readout under the canvas. This is the transport display E4 dropped
   with pstudio, at the size it deserves, and it is the one place tempura is visible in the
   demo rather than upstream of it.

The page is deliberately not the expansible-player `score` handler: that handler mounts
pacer inside pngine's player and takes its registries from the GPU handler (expansible-player
05, "pacer as the router"), and it does not exist: it is checkpoint 05.C3 at X4, three
milestones past X1's four handlers. When X4 lands, the page's three files are packed as
`PNGB` + `PACR` + `TMPU` (once that kind is in the sibling registry, which it is not yet) and
the page's loop is the handler's; nothing in the files changes.

## The tracker view and the musicians' round trip

What a musician opens is `square.it`: speed 6 and 120 BPM, so a row is a sixteenth and a bar
is 16 rows; channels 1..4 hold the movements; every cell names instrument 1 and the module
carries no sample (`it_no_instrument`). Their first action is to load a click into instrument
1, so the movements are audible as hits while they write. tempura writes no sample, by plan
00's non-goal, and the demo's README says so in its first line. They compose from channel 5
up, add samples and instruments, and save as `.it` (not `.mptm`).

The round trip, step by step, with what tempura reports at each step:

1. `tempura build square.sjon --kind it -o square.it`, as above.
2. The musician re-saves as `song.it`. **Expected**: the message survives (it is a
   first-class field), the `TMPU` chunk does not (trailing bytes past the last parapointer).
   **Measured**: never. Phase 0 measures it on this machine with Schism Tracker and
   `openmpt123`, per `conformance/CHECKLIST.md` section C.
3. `tempura check-residue song.it` shows what survived. On the tail-only path the 2026-09-29
   run (the chunk cut off the built file by hand) reports `residue_partial` and dumps the
   lane lines exactly as the message holds them, with no address:

   ```
   ; partial: the IT message tail alone — the shape of the piece, none of its content
   (timeline :title "square" :length 8bar :end loop :conductor song)
   (lane :name x :kind curve :range [-1 1])
   (lane :name jump :kind notes)
   (anchor :id song :kind it :file "song.it" :size … :sha256 "…")
   ```

   The channels' cells stay in the `it/` tier belonging to no lane. The diagnostic's text
   says "every rendered lane stays bound", and `reconcile.zig:710` explains that this is
   about lanes that were bound already; a lane that was native when the file was built has
   no `:from` line to keep. Phase 2's rule: the tail line of a rendered native lane carries
   the address it was rendered to, so the tail-only dump binds it there.
4. The document that rebuilds the musicians' file is the dump of that file, not
   `square.sjon`: `tempura dump song.it -o square.sjon`. With the chunk intact, rule 2
   consumes the movement channels, the lanes come back native with their content, the
   musicians' channels stay in the `it/` tier and the anchor line names `song.it` — the fixed
   point `demos/e3-one-file/` shows. The author edits the lanes there. To let the module
   conduct, the author adds `:conductor song` to the timeline and REMOVES the tempo and meter
   points: a conducted document that keeps its own is `conductor_conflict` on each of them
   (measured 2026-09-29), and the module's `Txx` cells and header are what tempura wrote
   from those points, so nothing moves. The by-reference shape — `square.sjon` naming the
   file as an anchor and `tempura inline` pulling the tiers in, the shape of
   `examples/native.sjon` — does NOT rebuild in place today, with the chunk intact or not:
   `inline` consumes nothing (plan 11, filed 2026-09-21), so step 5 renders beside. Measured
   2026-09-29 on both shapes; phase 2 closes it.
5. `tempura build square.sjon --kind it --in-place` renders the movement lanes back into
   `song.it`. With the chunk intact and the document a dump, each lane lands on the channel
   the dump emptied (measured: channels 1..4 again, every hash matching) and the musicians'
   channels are untouched; the anchor's `:size` and `:sha256` are stale from that moment and
   the next `dump` refreshes them. **With the chunk gone, today's renderer takes channels
   above the highest used one** (`render_it.zig:33-41`, "Into an anchor") and leaves the old
   rendering in place — measured: the movements on channels 5..8 beside their old cells on
   1..4 — because a tail-only dump restores the lanes as empty declarations with no address.
   Phase 2's second rule: a native lane whose name a tail line declares at channel N is
   rendered onto channel N, replacing that channel's cells in every played pattern (the
   scope of `tmpu/lane/it/1`), with `residue_rerendered` naming the lane and channel.
6. `tempura export-score square.sjon --velocity` is the same score as before, now conducted
   by the module (measured: the two texts differ in the header's `conductor:` alone); the
   page loads it beside the musicians' bounce.

The contract this gives the musicians: **channels 1..k are the timeline's and are rewritten
by the next build; the message says which lane each holds; everything above is theirs.** A
musician who wants a movement moved asks the author, or the author runs `tempura dump song.it`
and reads the bound lane the musician left. Two-way editing of a movement channel needs a
hash the tail does not carry today; it is filed under decisions, not built.

## What changes in tempura (P110)

1. **The tail carries a rendered lane's address, and a tail-only dump binds by it.** For
   every native lane the build rendered, the message line gains the binding keys a bound
   lane's line already has: `(lane :name jump :kind notes :from song :channel 3)`,
   `(lane :name x :kind curve :from song :channel 1 :column vol :range [-1 1])`. A reader of
   this build parses the line as a bound lane, which is the right reading of a file whose
   records are gone. `docs/residue.md`'s table describes `:from` as a bound lane's binding
   address; a rendered native lane has no binding, so the writer (`it.zig:528-531`) has
   nothing to write for it today, and the table gains the rendered address as a second
   reading of the same keys. Then, on a build into an anchored module whose residue is
   tail-only, a native lane renders onto the channel its tail line names and replaces that
   channel's cells; `residue_rerendered` is appended to `Diag.Code`.
2. **`inline` consumes as `dump` does.** Plan 11's filed defect (2026-09-21):
   `edit.inlineAnchor` (`src/edit/inline_anchor.zig`) copies the tiers as the file holds
   them, so a document inlined from a file tempura built rebuilds every lane beside its
   rendering. The inlined tier goes through the reconciliation `dump` runs — the rendered
   channels consumed for the lanes the essence restores, `became_bound` where a hash says a
   musician edited one — so the by-reference authoring shape and the dump shape rebuild the
   same file. Measured 2026-09-29: today they differ (channels 1..4 from a dump, 5..8 beside
   them from an inline).
3. **Patterns sized to sections**, behind `--pattern-per-section` (default off, so no
   committed fixture or golden moves). When the sections tile `[0, length)` without overlap
   and each is a whole number of rows, one pattern per section in section order, split at
   bar lines into patterns of at most 200 rows (IT's ceiling), so the order list reads as
   the section list; otherwise the 64-row grid and `render_sections_unfit`, a warning. This
   also absorbs the meter-sizing gap plan 11 filed on 2026-09-21 (a bar that does not divide
   64 rows), since a section is a whole number of bars of the meter in force. The
   2026-09-29 run shows why it matters even for `[4 4]`: an 8-bar piece became three 64-row
   patterns, because the count is `length / rows + 1` (`render_it.zig:326`) and the `8bar`
   keyframes land on row 128, the third pattern's first row.
4. **A vector curve lane renders one channel per component**, each with its own lane record
   and hash, the way a polyphonic notes lane takes one channel per voice; the tail line names
   the channel set. Until then the renderer's first-component rule stands and is stated in
   the example's comments.
5. **Optional, filed:** `:emit` on `(timeline …)`, passed to the transport, so a shader gets
   `beat` without a formula lane (a schema key and a printer line, no wire change); a
   `:velocity-target` key so a velocity track can be named for WGSL.

Nothing changes in pacer or pngine. The expansible-player payload kind stays E4's.

## Phases (P110)

0. **The measurement.** Install a tracker on this machine (`brew install schismtracker
   libopenmpt`; the formula names are to be checked) and run `conformance/CHECKLIST.md`
   section C over `examples/tracker/piece.it` and the square: open, add a channel with a
   sample, save, `check-residue`; the same through `openmpt123 --info` for the load and the
   duration. Record the rows in the checklist and in plan 04's log. Half a session with the
   user at the tracker. **This decides phase 2's weight**: if the chunk survives a re-save,
   the musicians' round trip needs item 2 alone (the dump shape already works) and item 1's
   re-render rule is exercised by the tail-only corpus case; if the chunk is dropped, item
   1 is the whole return trip.
1. **The example and its corpus case (RED first).** `examples/square/square.sjon` and
   `examples/square/README.md`; `corpus/examples-square/` pinning the score, both builds and
   rung 3; the score through `pacer.wasm` in `landing.test.js` with every position landing;
   a CLI test that `--velocity` prints the two `-vel` tracks. Gate: `tools/zt verify`.
2. **The tail address, the re-render and `inline`.** Reds: a built module's tail names
   every rendered lane's channel; the tail-only dump binds each lane at that channel and the
   channels' cells leave the tier (`consumed`); `build --in-place` into a tail-only anchor
   replaces the channel rather than appending; a tail line naming a channel the module no
   longer has is `residue_stale`; a fuzz seed for a tail line with a channel above 63;
   `tempura inline` over a file tempura built, then `build --in-place`, writes the bytes the
   dump shape writes. Green: `residue/it.zig`, `residue/reconcile.zig`,
   `export/render_it.zig`, `edit/inline_anchor.zig`, `Diag.zig` (append).
   `corpus/residue-tail-only/` is regenerated and the diff reviewed. Gate: verify + fuzz.
3. **Patterns by section.** Reds: three tiling sections become three patterns with the order
   list `0 1 2 end`; a 13-bar section splits at bar 12; overlapping sections fall back with
   the warning; the square's `.it` under the flag has three patterns of 32, 64 and 32 rows;
   a `[7 8]` document sizes its patterns from its bars. Green: `export/render_it.zig`,
   `cli/Args.zig`. Gate: verify; the committed fixtures unchanged with the flag off.
4. **Vector lanes per component.** Reds: a vec3 colour lane takes three channels with three
   records; `check-residue` lists them; the dump restores one lane. Green: `render_it.zig`,
   `records.zig`'s address (unchanged wire: one record per channel, as for polyphony). Gate:
   verify.
5. **The pngine piece and the page.** `examples/square/square.pngine.sjon`,
   `demos/e5-stage/` with the page, its `package.json`, and a node test that compiles the
   program with pngine's compiler wasm, reads the reflected field names, and asserts the
   score's registry-0 targets (after the `-vel` rename) are a subset of them, so the
   timeline and the shader cannot drift apart without the gate saying so. A screenshot at
   `t` of every section start from pngine's native `--frame -t`, with the uniforms of that
   `t` written by the page's own routine, is the visual golden. Gate: `node --test` in the
   demo directory, run by `verify` when `node_modules` is present and announced skipped
   otherwise.
6. **The musicians' leg.** With a real tracker: the re-save as `song.it` with a click on
   instrument 1 and one bass channel; `check-residue`, the anchored document, `build
   --in-place`, `export-score`; a bounce beside the page. `demos/e5-stage/README.md` carries
   every command and its output. Gate: the README's transcript reproduced.

Phases 1 and 5 touch `examples/` and `demos/` only and run beside 2 to 4.

## Effort

| Phase | Sessions |
|---|---|
| 0 | ½, with the user at a tracker |
| 1 | 1 |
| 2 | 3 |
| 3 | 1 |
| 4 | 1 |
| 5 | 2 |
| 6 | 1 |

Nine sessions, about two weeks part-time; phase 5 is the widest (three wasm modules in one
page) and phase 2 the one that changes what a file says.

## Decisions filed for the user

1. **A new key on an existing tail line, inside the append-only rule?** The residue payloads
   are frozen from E3. The chunk's records do not change; the message tail gains keys on a
   line an older reader already parses as a lane declaration, and a bound lane is a legal
   one. Recommended: yes, as an append, with `docs/residue.md`'s table already saying so.
2. **Movement channels are one-way** (the timeline's, rewritten by every build) for E5.
   Two-way needs a hash per lane in the tail (one 64-hex `(record …)` line per lane, under
   the 4096-byte cap) so a musician's edit binds the lane instead of being overwritten.
   Filed; phase 0's result says whether it is needed at all.
3. **`--pattern-per-section` defaults off**, so nothing committed moves; the square turns it
   on. Making it the default is a fixture regeneration and a reviewed diff, later.
4. **The `-vel` spelling** is renamed in the page. A tempura key is filed, not built.
5. **The page lives in tempura's `demos/`**, with `file:` dependencies on the three sibling
   packages; pngine and pacer gain no code and no dependency.
6. **No click sample from tempura.** The musician's first action, stated in the README.
7. **The `tempura/score-v1` lowering hook stays parked** (ruled 2026-09-29). Nothing here needs
   it: the page consumes score text, offline from `tempura export-score` or in the browser from
   `tpr_exportScore`, and the tracker side never sees pacer forms. A hook emits form trees, so
   it would restate the exporter's rules (the floor-interval decimal, `qpm · d / 4`, onset
   aggregation, the key budget, the hint verification) over a second owner, while only the text
   path is proven through `pacer.wasm`. No host could run it: pacer links no tempura code and
   pngine's guest seam is expansible-player X3. Reopen at X3, when the guest contract freezes
   (expansible-player `04:58-69`): a guest supplies both a `registerHooks` and an `emit`, and
   tempura's can register nothing and emit the score text as `PACR`, so the hook may never be
   needed.

## Risks / open questions

- **Survival is unmeasured**, and the whole return trip rests on the message tail surviving
  a re-save. Phase 0 is first for that reason, and it needs a tracker this machine does not
  have.
- **Named easings render as steps.** The `size` lane's spring is two volume-column values
  in the tracker and a spring on the canvas. A musician hears a step where the square
  springs. The README says so; the essence restores the spring; nothing else can be done
  without evaluating a curve, which plan 00 refuses.
- **The volume column holds 65 levels.** A curve lane is quantised to `0..64` in the file
  and exact in the essence; the score prints the authored values as long as the lane is
  native. After a foreign edit binds the lane, the score reads the 65 levels.
- **One meter per score** (plan 08's risk) and integer tempo in the module; the example
  keeps `[4 4]` and 120.
- **The registry can drift from the shader.** Phase 5's subset test is the only gate; a
  renamed field in WGSL fails there rather than as a silent zero on the canvas.
- **pacer's caps**: 256 tracks and 4096 keys per score. Two tracks per triggered movement
  with `--velocity`, so a piece has room for about a hundred movements.
- **The clock.** pngine's `requestAnimationFrame` is replaced by pacer's master clock in the
  page; `AudioContext` time advances per render quantum, which is the granularity every
  audio-synced demo has. pngine's `scene-time-inputs` (the 12-byte time, width, height
  prefix of `pngine-inputs` since pngine `25c8d28`) is unused here; the shader reads `beat`
  from the score.
- **The browser cannot play the `.it`.** The page plays a bounce. batida's player is the
  answer and is not this set's.

- **animader names this stage as its proof (2026-09-29).** `07-road.md`'s parked table has
  the timeline document waiting on "tempura's stage, its plan 13, proving the seam on pngine
  and pacer", and asks that the page also show a key dragged on the canvas naming the lane
  it came from, which is [08](08-export.md)'s ask T1. Not a phase here until T1 is ruled; the
  forward direction needs nothing.

- **T1 is ruled (2026-10-04).** [08](08-export.md)'s section "T1 ruled (2026-10-04)" settles the
  ask the bullet above records, so its condition, "not a phase here until T1 is ruled", is
  discharged: the ruling leaves the phase question to this plan. Whether the page takes up the
  key-drag read is this plan's to decide; the forward direction still needs nothing.
