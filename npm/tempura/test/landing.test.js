// The landing proof: every position tempura prints, read back by the
// REAL pacer.wasm.
//
// Plan 08's determinism seam runs through two implementations of one
// expression. `src/export/pos.zig` reproduces pacer's `mul + floor`
// (`tpb = PPC / n`, then `floor(beats · f64(tpb))`) to CHOOSE the
// shortest decimal that lands on a tick; `pacer.wasm` performs that
// expression for real when it reads the decimal back. Nothing on the
// Zig side can catch the two drifting apart — this file is where they
// meet.
//
// The assertion is sharp on purpose. A trigger's `gate` lane is 1.0
// EXACTLY on an event tick and 0.0 everywhere else (`pacer/src/Eval.zig`
// — "gate — 1.0 exactly on the event tick, else 0.0 (structural)"), and
// before its first event an ncomp-4 trigger writes nothing at all. So
// `evalTicks(T)` returning gate 1 says the printed position landed on T
// and on no other tick: a decimal that floors one tick SHORT puts the
// event at T−1, where `evalTicks(T)` finds the event behind it and
// reports gate 0, and one tick LATE leaves T before the first event
// entirely. Either way this test fails.
//
// The fixtures come from `zig build landing` (`tools/gen_landing.zig`)
// and are regenerated, never hand-edited.

import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import { Pacer } from 'pacer';

const require = createRequire(import.meta.url);

/** `pacer.wasm` as the pacer package exports it (`./pacer.wasm`). */
const wasmPath = require.resolve('pacer/pacer.wasm');
if (!existsSync(wasmPath)) {
  throw new Error(
    `pacer.wasm is missing at ${wasmPath} — run \`cd ../../../pacer && zig build wasm\` ` +
      "and copy it per pacer's `build:wasm-copy` (or `npm run pretest` here).",
  );
}
const wasmModule = new WebAssembly.Module(readFileSync(wasmPath));

const landing = JSON.parse(
  readFileSync(new URL('./fixtures/landing.json', import.meta.url), 'utf8'),
);

/** One probe target, ncomp 4, so all four trigger lanes come through. */
const REGISTRIES = [[{ name: 'probe', ncomp: 4 }]];

/**
 * How many positions ride in one probe score. Compiling is the cost
 * (a few tens of microseconds per position); batching keeps the whole
 * sweep inside a second while every position still gets its own
 * `evalTicks` assertion.
 */
const BATCH = 2000;

/** Group the fixture's rows by meter, deduplicated and ascending. */
function byMeter(positions) {
  /** @type {Map<string, {n: number, d: number, rows: Map<number, string>}>} */
  const groups = new Map();
  for (const p of positions) {
    const key = `${p.n}/${p.d}`;
    let g = groups.get(key);
    if (!g) {
      g = { n: p.n, d: p.d, rows: new Map() };
      groups.set(key, g);
    }
    // A tick may appear twice (a named case is also inside the sweep);
    // the spelling is a pure function of the tick, so agreement is a
    // property worth asserting rather than a collision to resolve.
    const seen = g.rows.get(p.tick);
    if (seen !== undefined) {
      assert.equal(seen, p.pos, `two spellings for tick ${p.tick} in [${p.n} ${p.d}]`);
    }
    g.rows.set(p.tick, p.pos);
  }
  return groups;
}

test('landing: every printed position lands on the tick tempura claims', async () => {
  assert.ok(landing.positions.length > 0, 'the fixture is empty — run `zig build landing`');
  let checked = 0;

  for (const g of byMeter(landing.positions).values()) {
    const ticks = [...g.rows.keys()].sort((a, b) => a - b);
    for (let start = 0; start < ticks.length; start += BATCH) {
      const slice = ticks.slice(start, start + BATCH);
      const at = slice.map((t) => g.rows.get(t)).join(' ');
      const score = `(transport :bpm 120 :meter [${g.n} ${g.d}])\n(trigger :target probe :at [${at}])`;
      const driver = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
      assert.deepEqual(
        driver.diagnostics,
        [],
        `[${g.n} ${g.d}] batch at ${slice[0]} did not compile`,
      );
      assert.equal(driver.ok, true);

      for (const tick of slice) {
        const writes = driver.evalTicks(tick);
        assert.equal(
          writes.length,
          1,
          `[${g.n} ${g.d}] ${g.rows.get(tick)} → tick ${tick}: the trigger never fired`,
        );
        assert.equal(
          writes[0].value[2],
          1,
          `[${g.n} ${g.d}] ${g.rows.get(tick)} did not land on tick ${tick} ` +
            `(gate ${writes[0].value[2]}, beats-since ${writes[0].value[3]})`,
        );
        checked++;
      }
    }
  }
  assert.equal(checked, landing.positions.length - dupes(landing.positions));
});

/** How many rows repeat a (tick, meter) another row already carried. */
function dupes(positions) {
  const seen = new Set();
  let n = 0;
  for (const p of positions) {
    const key = `${p.n}/${p.d}/${p.tick}`;
    if (seen.has(key)) n++;
    else seen.add(key);
  }
  return n;
}

test('landing: a position one tick short is caught (the mutation the proof exists for)', async () => {
  // The same probe, with the decimal deliberately spelled the way a
  // shortest-ROUND-TRIP rule would spell it: `1.4b`, which pacer's
  // `mul + floor` reads as 252 251 — one tick short of the 252 252 the
  // exporter targets. If this assertion ever stops failing, the test
  // above has stopped proving anything.
  const score = '(transport :bpm 120 :meter [4 4])\n(trigger :target probe :at [1.4b])';
  const driver = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  assert.equal(driver.ok, true);
  assert.equal(driver.evalTicks(252252).length, 1);
  assert.equal(driver.evalTicks(252252)[0].value[2], 0, 'gate at the intended tick');
  assert.equal(driver.evalTicks(252251)[0].value[2], 1, 'the event really landed one tick short');

  // …and the position the exporter prints instead lands where it says.
  const fixed = '(transport :bpm 120 :meter [4 4])\n(trigger :target probe :at [1.400001b])';
  const ok = await Pacer.load(wasmModule, fixed, { registries: REGISTRIES });
  assert.equal(ok.evalTicks(252252)[0].value[2], 1);
});

/**
 * A score's own `(target …)` declarations, as host registries.
 *
 * pacer's compose mode merges declared targets with the host's, and a
 * name the host also provides is host-authoritative — so handing back
 * exactly what the score declares gives the driver a flat registry whose
 * entries carry NAMES, which is what the landing assertion selects by.
 */
function registriesOf(text) {
  const targets = [...text.matchAll(/\(target :name (\S+) :arity (\d+)\)/g)].map(
    ([, name, arity]) => ({
      name,
      ncomp: Number(arity),
    }),
  );
  assert.ok(targets.length > 0, 'a golden score declares no targets');
  return [targets];
}

/**
 * Every golden score `exportScore` produces, through the real driver.
 *
 * The list is `tools/gen_landing.zig`'s: the three conductors of plan
 * 03, the `--velocity` variant, the 512-segment seconds fallback, and
 * `examples/native.sjon` — the SHIPPED example, compiled from its own
 * bytes. That last one is why this loop is worth more than a Zig test:
 * an example nobody compiles is an example nobody can trust, and the
 * one it caught was a three-component keyframe on an arity-1 target.
 */
test('scores: every golden skeleton loads clean through pacer.wasm', async () => {
  assert.ok(
    Array.isArray(landing.scores) && landing.scores.length > 0,
    'no golden scores — run `zig build landing`',
  );

  for (const { file } of landing.scores) {
    const text = readFileSync(new URL(`./fixtures/scores/${file}`, import.meta.url), 'utf8');
    const driver = await Pacer.load(wasmModule, text, { registries: registriesOf(text) });
    const errors = driver.diagnostics.filter((d) => d.severity === 'error');
    assert.deepEqual(errors, [], `${file} did not load clean`);
    assert.equal(driver.ok, true, `${file}: ok is false`);
  }
});

test('scores: every golden trigger lands on the tick the exporter claims', async () => {
  // The other half of the position proof, on real emissions rather than
  // on probes — and the only place `slide-seconds.pacer` is checked at
  // all, since its positions are SECONDS and ride pacer's degenerate
  // `ticks_per_second` path instead of `ticks_per_beat`.
  let checked = 0;
  for (const { file, landings } of landing.scores) {
    const text = readFileSync(new URL(`./fixtures/scores/${file}`, import.meta.url), 'utf8');
    const driver = await Pacer.load(wasmModule, text, { registries: registriesOf(text) });
    assert.equal(driver.ok, true, `${file}: ok is false`);

    for (const { target, ticks } of landings) {
      for (const tick of ticks) {
        const write = driver.evalTicks(tick).find((e) => e.name === target);
        assert.ok(write, `${file}: ${target} never fired at tick ${tick}`);
        assert.equal(
          write.value[2],
          1,
          `${file}: ${target} did not land on tick ${tick} (gate ${write.value[2]}, beats-since ${write.value[3]})`,
        );
        checked++;
      }
    }
  }
  assert.ok(checked > 0, 'no trigger landings to check');
});
