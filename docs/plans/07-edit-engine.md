# 07 — The Edit Engine: Operations as SJON Edit Actions

Status: Active — 2026-09-19; Draft until 2026-09-29 (every operation in the table is
implemented, `src/edit/Op.zig`, and pinned by the 26 `corpus/edit-*` cases). Part of the
[tempura plan set](README.md). Owns **P105**
(`src/edit/`).

A timeline editor is a set of operations: move this note, quantise that selection, split a
clip here, insert a tempo change there. tempura implements every one of them as a **pure
function from a document and an operation to a list of SJON edit actions**, and never as a
mutation of an in-memory model. The host applies the actions to the text with SJON's
structural editor (`docs/LANGUAGE.md` §11: eight operations, paths, `wrap`, layout-preserving
apply, SJON 1.4.0), re-parses, and the document is what it says. There is no undo stack in
tempura (the host keeps text history; pstudio has an action log), no dirty flag, no object
identity: an address is a path plus a root and is re-derived after every apply, SJON's own
rule (§11.2, "A path plus a root is an address, and an address is where a node is, not which
node it is").

## The contract

```zig
pub const Plan = struct { actions: []Action, diags: []Diagnostic, summary: Summary };
pub fn plan(gpa, doc: *const Doc, tree: *const Tree, op: Op) Error!Plan;   // pure; never mutates
pub fn apply(gpa, text: []const u8, p: Plan) Error!Applied;                 // sjon.applyEdit per action, addresses re-derived between actions
```

- `Action` is SJON's action grammar (`set_keyword`, `remove_keyword`, `replace`, `wrap`,
  `insert_positional`, `remove_positional`, `insert_root`, `remove_root`) as JSON values.
- `plan` is total: an operation that cannot be done yields an empty action list and a
  diagnostic with the span of the node it refused on; it never throws on user input.
- `apply` sequences the actions so that each address is valid when it is reached: removals
  right to left within a form, inserts after removals, roots last; between actions the tree is
  re-parsed (SJON's `Edit` reports the node under a byte and its address, 1.4.0), so a plan
  never relies on an address surviving a prior action. Layout is `preserve`: trivia outside
  the touched sub-trees survives (§11.5, §11.6).
- Determinism: same document + same operation ⇒ the same action list in the same order
  (lanes in document order, then tick, then kind); the corpus pins plans as text.
- Diagnostics (`Edit.Code`, u16, append-only): `edit_target_bound` (content of a by-reference
  anchor; inline it first), `edit_would_duplicate` (the operation would give one content two
  homes, [04](04-residue.md)), `edit_overlap` (a note would overlap on its key), `edit_off_bar`
  (a meter point off a bar line), `edit_pattern_shared` (an IT cell in a pattern played more
  than once, without `:allow-shared`), `edit_range_empty`, `edit_inexact` (a stretch or a
  wall-clock retime that rounded, with the count), `edit_readonly_passthrough` (a pacer form).

## Selection

`Select{ lanes: []name | all, range: [from, to) in ticks | all, kinds: {note, keyframe, clip,
section, cue}, keys: ?[]u7 }` resolves against `Doc` to an ordered list of **targets**: for a
native lane, the addresses of its child forms; for a bound inline SMF lane, the addresses of
the `note-on`/`note-off` pairs or the controller events on its address; for a bound inline IT
lane, the `(ev …)` cells on its channel in the patterns the range covers, each with the
`(order, row)` it was reached through. Resolution is a `Playhead` query
([03](03-time-model.md)); a by-reference anchor resolves to nothing editable and
`edit_target_bound`.

## The operations

| Op | On | Actions, in words |
|---|---|---|
| `insert` | note, keyframe, clip (children of a lane); section, cue, lane, phrase, tempo-point, meter-point (roots) | children: `insert_positional` into the parent at the sorted index (children are kept sorted by `:at` for readability; the schema does not require it); roots: `insert_root` after the last root of the same head |
| `remove` | a selection | `remove_positional` for each target, right to left; a lane emptied stays (an empty lane is legal) |
| `retime` | a selection, by `delta` or `to` | `set_keyword :at` when the sorted order is unchanged (the common drag; the node keeps its comments); otherwise `remove_positional` + `insert_positional` at the new index (comments on the moved node are lost, the risk below). For a note pair in an SMF tier, both events move; for a cell in an IT tier, `remove` from one `(row …)` and `insert` into another, creating the row form when absent and removing an emptied one |
| `revalue` | keyframes | `set_keyword :value` |
| `ease` | keyframes | `set_keyword :ease` with a pacer `ease-spec` (a name or a form) |
| `resize` | notes, clips, sections | `set_keyword :dur` / `:repeat` |
| `velocity` | notes (native or SMF) | `set_keyword :vel`, or the `note-on` `:vel` |
| `split` | a clip at a position | `replace` the clip by two clips: the left keeps `:at` and `:offset` and gets `:length` up to the split, the right starts at the split with `:offset` advanced and the remaining `:length`; `:repeat` is folded into the two windows |
| `merge` | two adjacent clips of one phrase | the inverse |
| `duplicate` | a selection, to a position | inserts of copies, retimed |
| `quantize` | a selection, `grid` (a subdivision or `1bar`), `strength` 0..1, `swing` | `retime` to `Snap` lines; `strength` moves a fraction of the way (rounded to a tick); onsets only, durations kept unless `:dur-too` |
| `nudge` | a selection, by a subdivision or ticks | `retime` by delta |
| `transpose` | notes | `set_keyword :key` (`:transpose` on clips) |
| `stretch` | a range, by a rational `p/q` | every `:at` and `:dur` in the range scaled; a position that leaves the integer grid is rounded and counted in `edit_inexact`; positions after the range shift by the range's growth |
| `insert-tempo` | a tempo point, `mode: musical` (default) or `wall-clock` | `musical`: one `insert_root` (a musical position never moves because a tempo changed, [03](03-time-model.md)); `wall-clock`: additionally `retime` every event after the point so its seconds are preserved: `tick' = tickFromSeconds_new(secondsFromTick_old(tick))`, rounded and counted |
| `insert-meter` | a meter point | `insert_root`, plus a `set_keyword :at` (and `:dur`, `:length`, `:offset`) for every literal after the point that is spelled in `bar` or `b`, respelled from its resolved tick under the new map in the same plan; without that respelling a cue at `2bar` in `[4 4]` (`8q`) would read as `7q` the moment a `[3 4]` point lands at `1bar`. `q`, `t` and `s` literals stand. The point must be on a bar line (`edit_off_bar`) |
| `rename` | a lane, a section, a phrase, a target | `set_keyword` on the form and on every cross-ref to it (`clip :phrase`, `timeline :conductor`) |
| `bind` / `unbind` | a lane | `set_keyword :from` and the address keys; `unbind` refuses unless the lane is empty (`edit_would_duplicate`) |
| `materialize` | a bound SMF lane (inline) | copies the paired notes or the controller steps into native `note` / `keyframe` children **and** removes the source events from the `mtrk` (one home); IT lanes are parked (a channel's cells serve every order that plays the pattern) |
| `inline` | an anchor | not an edit action: the CLI verb `tempura inline` dumps the anchor's tiers into the document ([10](10-hosts-and-cli.md)) |

Operations on pass-through pacer forms are refused (`edit_readonly_passthrough`): the studio
edits those through pacer's own `'PACM'` spans (pacer plan 07).

## Snapping

`Snap.lines(grid, from, to)` lists the grid lines under the meter map for a subdivision
(`1/4`, `1/8`, `1/12`, `1/16`, `1/32`, `1bar`, `1b`) between two ticks; `Snap.nearest(tick,
grid, swing)` picks the nearest with ties resolved down; `swing` in −1..1 offsets every second
line by that fraction of the subdivision, the DAW convention. All integer arithmetic on
[03](03-time-model.md)'s grid; a subdivision that does not divide a bar exactly (a `1/12` in a
`[7 8]` bar) snaps to the nearest exact tick and reports nothing (the grid is finer than
audible).

## Bound content, precisely

- **SMF, inline.** A note is the pair `(note-on, note-off)` the bridge paired ([05](05-smf-core.md)).
  `retime` moves both by the delta; `resize` moves the off; `velocity` sets the on's `:vel`;
  `remove` removes both. The `mtrk`'s events are kept non-decreasing in `:at`, so a move past
  a neighbour is remove + insert at the sorted index; equal ticks keep the moved event after
  existing ones (the canonical writer's stable sort makes this the only stable choice).
  Controller steps are single events.
- **IT, inline.** A note is a cell; its position is `(order, row)` through the walk. `retime`
  to a tick that is not a row start uses `SDx` (delay `x` ticks, `x ≤ 15`) when the delta
  fits and the cell has no effect column, else `edit_inexact`; `retime` across a pattern
  boundary moves the cell to the pattern the target order plays, and if that pattern is also
  played by another order the plan refuses with `edit_pattern_shared` unless `:allow-shared`
  (then every occurrence changes, which is what the tracker would do). `velocity` writes the
  volume column (`round(vel × 64 / 127)`). Effects on the moved cell travel with it.
- **The residue** is untouched by edits; it is recomputed at build.

## Phases (P105)

1. **Plan, apply, selection (RED first).** Load: `SJON/docs/LANGUAGE.md` §11, `src/Edit.zig`
   surface. Reds: `apply` of a hand-written plan reproduces an expected document byte for byte
   with comments intact; address re-derivation across a remove + insert; `Select` over a
   native fixture and an inline SMF fixture; `edit_target_bound` on a by-reference anchor.
   Green: `edit/Plan.zig`, `edit/apply.zig`, `edit/Select.zig`. Gate: test.
2. **Native operations.** Reds: one fixture per row of the table above; the retime-as-replace
   versus remove-insert branch; `stretch` with an inexact factor counted; `insert-tempo`
   in both modes against hand-computed ticks; `insert-meter` off a bar refused; `rename`
   follows cross-refs. Green: `edit/ops_native.zig`. Gate: test + corpus (plans as text).
3. **Snapping and quantize.** Reds: lines under a meter change; ties; swing; strength 0.5;
   `nudge`. Green: `edit/Snap.zig`, `edit/ops_quantize.zig`. Gate: test.
4. **Bound operations.** Reds: SMF pair moves across neighbours; IT cell moves with `SDx`,
   across patterns, shared-pattern refusal; `materialize` leaves one home and the residue
   unaffected; `edit_would_duplicate`. Green: `edit/ops_bound.zig`. Gate: test + corpus.
5. **Wasm.** `tpr_plan` / `tpr_apply` round-trip through `node --test`
   ([10](10-hosts-and-cli.md)). Gate: verify.

## Risks / open questions

- **Comments on a moved node are lost when the move is remove + insert.** SJON's JSON bridge
  carries no comments, so an `insert_positional` cannot carry the removed node's trivia; only
  `wrap` clones a node with its comments (1.4.0). Two mitigations, in order: the plan uses
  `set_keyword :at` whenever the sorted order allows (most drags), and a `move` action (a
  ninth op: remove at one address, insert the same node at another, trivia intact) is filed
  as an ask to SJON at E3 if the loss bites in practice; the ask is recorded, not assumed.
- **Sorted children are a convention the printer enforces and the schema does not.** A
  hand-written lane with unsorted notes is valid; `plan` sorts by `:at` as it reads and its
  inserts land at the index that keeps the *existing* order, so it never reorders a document
  it did not write.
- **Wall-clock retime is lossy by construction** (seconds are floats; ticks are integers). It
  is opt-in, counted, and the counts are pinned by corpus so a change in the seam is loud.
- **IT `SDx` for sub-row positions** competes with an existing effect in the cell (one effect
  column). The plan refuses rather than dropping the effect; the editor can quantise to rows
  instead. A `:dur` on an IT note is not writable at all (the end is the next cell); `resize`
  on an IT lane is `edit_inexact` with the reason.

- **Drift, read against the tree on 2026-09-29 (`cfe44a0`).** There is no `Edit.Code`: the
  `edit_*` codes are variants of the one `Diag.Code` (`src/Diag.zig:103-110`), by
  [11](11-demos-and-milestones.md)'s ruling 5 (one shared enum, seeded whole). The
  diagnostics table above reads the same with that substitution.
