# tempura

JS glue for **tempura.wasm** — the timeline as a value: one
[SJON](https://git.hugodaniel.com/hugo/SJON) document, `(timeline …)`, as the
authoritative arrangement of a piece in musical time, with the `.mid` and `.it`
cores that read and write those files as values.

tempura is a pure function from documents and files to values, text and bytes.
It never reads a clock, never owns a loop and never plays anything: it does not
evaluate a value at time `t` — it produces the [pacer](https://git.hugodaniel.com/hugo/pacer)
score that does. Same input ⇒ byte-identical output, in the browser and natively.

ESM-only. Ships JavaScript source + generated `.d.ts` types + `tempura.wasm`.

## Install

`tempura` publishes to a self-hosted registry, and it's unscoped (no per-scope
route), so point npm at the registry for this install:

```sh
npm install tempura --registry=https://git.hugodaniel.com/api/packages/hugo/npm/
```

Or persist it in a project `.npmrc`:

```ini
registry=https://git.hugodaniel.com/api/packages/hugo/npm/
```

## You supply the wasm bytes

The package ships `tempura.wasm`, but nothing here fetches it for you — you pass
the bytes (or a compiled `WebAssembly.Module`) to `Tempura.load`. Resolve the
shipped binary via the `tempura/tempura.wasm` subpath:

```js
// Browser (bundler) — import the asset URL, then fetch it. Use your
// bundler's URL suffix/loader: Vite/webpack `?url`, esbuild `file`, …
import wasmUrl from 'tempura/tempura.wasm?url';
const wasm = await fetch(wasmUrl).then((r) => r.arrayBuffer());
```

```js
// Node
import { readFileSync } from 'node:fs';
const wasm = readFileSync(new URL(import.meta.resolve('tempura/tempura.wasm')));
```

## A document in, answers out

```js
import { Tempura } from 'tempura';

const t = await Tempura.load(wasm, documentText);
if (!t.ok) console.warn(t.diagnostics); // spans into the document's own text

t.timeline(); // tempo segments, meters, sections, cues, the lane index
t.at(12.5); // where a clock lands: tick, bar, beat, the cues either side
t.atTick(184504320n); // the same answer, asked on the grid
t.snap(1000n, 'q16'); // the nearest grid line under the meter in force
t.exportScore(); // the pacer score this arrangement conducts
t.exportScoreMap(); // each emitted position: its score span and the document node it came from
t.build('mid'); // the document as a file, residue attached
```

Ticks are `BigInt`: the grid is `i64` on TPQ = 46 126 080 per quarter note, and
a bar of a long piece leaves a double's exact range.

## A file in, a document out

```js
const t = await Tempura.load(wasm, midiBytes, { kind: 'mid' });
t.text; // the file as a (timeline …) document — the dump ran in the wasm
```

There is **no filesystem** in wasm, so a document whose `(anchor …)` names a
file it cannot read says `anchor_unavailable` and stays loaded; hand the bytes
over and it reloads with every offset resolved:

```js
const t = await Tempura.load(wasm, savedDocumentText);
t.attachAnchor(theFileItNames); // checked against :size and :sha256
```

A saved document plus its file always reopens and rebuilds — that round trip is
gated in this package's tests, both kinds, against the native build.

## Editing

```js
import * as ops from 'tempura/ops';

const { actions } = t.plan(ops.retime({ sel: ops.sel({ kinds: ['note'] }), delta: 46126080 }));
// `actions` is the plan as SJON edit actions — show it, diff it, edit it
t.apply(); // commit the plan just shown
t.apply(actions); // …or a list a host has struck lines out of
t.apply(ops.transpose({ sel: ops.sel({ keys: [36] }), semitones: 12 })); // …or plan and commit in one call
t.text; // the edited document, its layout preserved
```

A plan the engine refused is the empty action list `[]` with the reason in
`diagnostics`, and it never reaches the document.

## The blobs

`tempura/blobs` exports the four decoders for a host that drives the `tpr_*`
exports itself through `t.exports`: `decodeTimeline` (`'TPTL'`),
`decodePlayhead` (`'TPPH'`), `decodeMap` (`'TPMP'`) and `decodeDiagnostics`
(`'TPDG'`). They mirror `src/TprAbi.zig`, which is the format's definition.

The map is the source-map seam: `t.exportScoreMap()` answers one record per
emitted position with a `text` span into the score and the `doc` span (or
spans, when the export merged onsets or tempo points) it came from. Hand a
`doc` span to SJON's `sjon_address_of_span` over the document text and the
edit engine has an address to land on; call `exportScore()` and
`exportScoreMap()` with the same options, because both run the same export.

## Licence

CC0-1.0.
