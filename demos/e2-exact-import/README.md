# E2 — the pacer door

Every position tempura prints lands on the tick tempura claims, read back
by the real `pacer.wasm`. Every score a shipped example exports loads
clean through pacer's own CLI. The trigger lanes fire.

Plan 11's E2 demo asks for the studio importing a `.it` through the exact
provider with its trigger lanes flashing a quad. **pstudio is not a
host** (ruled 2026-09-20): the studio provider, the timeline pane and the
transport display are dropped, and with them the studio half of this
demo. What is left is the part that was always the real proof — the
landing measurement and the score actually compiling — and it runs here
with no studio at all.

## The landing proof

`npm/tempura/test/landing.test.js` renders a golden score from
`examples/native.sjon`, loads it through the real `pacer.wasm`, and reads
every printed position back as a tick. tempura's own tests cannot catch
its model of pacer's `mul + floor` drifting from pacer's own; this is
where a printed position is read by the driver that will play it.

```
$ cd npm/tempura && node --test
…
✔ landing: every printed position lands on the tick tempura claims (151.554785ms)
✔ landing: a position one tick short is caught (the mutation the proof exists for) (4.124667ms)
✔ scores: every golden skeleton loads clean through pacer.wasm (33.232838ms)
✔ scores: every golden trigger lands on the tick the exporter claims (22.096768ms)
…
ℹ tests 118
ℹ suites 0
ℹ pass 118
ℹ fail 0
```

The second line is the one that makes the first mean something: the
mutation test moves one printed position one tick short and the proof
catches it. A gate that cannot fail is not a gate.

The suite needs `npm install` in `npm/tempura` (one `file:` dev
dependency on the sibling pacer package) and `tempura.wasm`, which
`tools/zt wasm` copies in beside the glue. `tools/zt verify` runs the
same suite and announces a printed skip when either is missing.

## Three scores through pacer's CLI

The three shipped examples, exported and checked:

```
tools/zt cli
zig-out/bin/tempura export-score examples/tracker/piece.sjon -o demos/e2-exact-import/tracker.score.sjon
zig-out/bin/tempura export-score examples/daw/piece.sjon -o demos/e2-exact-import/daw.score.sjon
zig-out/bin/tempura export-score examples/native.sjon -o demos/e2-exact-import/native.score.sjon

cd ../pacer && ../tempura/tools/zt cli
```

(`tools/zt` is tempura's build lock and it serialises `zig build` on the
whole machine, so pacer's build goes through it too.)

The block below is literally runnable from the tempura checkout: pacer's
binary lands in its own `zig-out/bin`, and these scores are named
relative to here.

```
$ ../pacer/zig-out/bin/pacer --version
pacer 0.2.0
$ ../pacer/zig-out/bin/pacer check demos/e2-exact-import/tracker.score.sjon
demos/e2-exact-import/tracker.score.sjon: no diagnostics
$ ../pacer/zig-out/bin/pacer check demos/e2-exact-import/daw.score.sjon
demos/e2-exact-import/daw.score.sjon: no diagnostics
$ ../pacer/zig-out/bin/pacer check demos/e2-exact-import/native.score.sjon
demos/e2-exact-import/native.score.sjon: no diagnostics
```

All three are compose-mode scores: they declare their own targets with
`(target …)`, so they load with no host registry at all. Two of the three
exports print a diagnostic of their own on the way out, and neither is
pacer's:

* `examples/daw/piece.sjon` warns `export_meter_unsupported` — the
  document changes meter to `[3 4]` at bar 6 and pacer's transport holds
  one meter. Positions stay exact ticks; a pacer lane asking for the bar
  phase drifts after bar 6.
* `examples/native.sjon` errors `anchor_unavailable` — `impulse-04.it` is
  not shipped beside it, on purpose. The score is still written and still
  loads clean, because the two lanes bound to that anchor contribute
  nothing and the four native ones need no file. The CLI exits 1 on the
  document, not on the score.

## The trigger lanes

`tracker.eval.json` is pacer evaluating the tracker score at three times,
half a beat apart at 125 bpm:

```
pacer eval demos/e2-exact-import/tracker.score.sjon --at 0 --at 0.48 --at 0.96 > demos/e2-exact-import/tracker.eval.json
```

```
{"t":0,"tick":0,…"writes":[
  {"target":"sweep","value":[0]},
  {"target":"hats","value":[1]},
  {"target":"bass","value":[0,0,1,0]},
  {"target":"chord","value":[1,0,1,0]}
]},
{"t":0.48,"tick":180180,…"writes":[
  {"target":"sweep","value":[0.125]},
  {"target":"hats","value":[1]},
  {"target":"bass","value":[0,1,1,0]},
  {"target":"chord","value":[1,0,0,1]}
]},
```

A notes lane became a `(trigger …)`, which writes four components, and
the second of them is the onset index: `bass` fires index 0 at t=0 and
index 1 at t=0.48, which are the document's `(note :at 0bar …)` and
`(note :at 1b …)`. `chord`'s three simultaneous notes aggregated into one
onset, as the export's header says (`onsets: 2 aggregated`). `sweep` is a
curve lane and reads 0 then 0.125 along its linear ramp. `hats` is a
pattern query and pacer runs the `euclid` itself.

That is the trigger lane flashing a quad, minus the quad. Whatever host
declares `bass` gets those four components at those ticks, whether the
host is a studio, a canvas or a GPU.
