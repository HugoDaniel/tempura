// Two contracts in one file: the PUBLISHED shape (what `npm pack` ships
// and what a consumer's `import` resolves), and the WASM surface — every
// `tpr_*` export exercised at least once against the real module, so an
// export that stopped existing, changed arity, or started trapping fails
// here rather than in a browser.
//
// Behaviour lives in blobs.test.js (the decoders), corpus.test.js (the
// parity walk) and roundtrip.test.js (the fresh-instance round trip).

import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { Tempura } from '../src/index.js';
import * as ops from '../src/ops.js';

const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const fromRoot = (rel) => fileURLToPath(new URL(`../${rel}`, import.meta.url));
const fromRepo = (rel) => fileURLToPath(new URL(`../../../${rel}`, import.meta.url));

const wasmBytes = readFileSync(fromRoot('tempura.wasm'));

const DOC = `(timeline :title "exports" :length 2bar)

(tempo-point :at 0bar :us 500000)
(meter-point :at 0bar :sig [4 4])

(section :name intro :at 0bar :dur 1bar)
(cue :name "drop" :at 1bar)

(lane :name flash :kind notes :target flash
  (note :at 0bar :dur 1q :key 36 :vel 110))
`;

test('publishable: ESM, side-effect free, ships the wasm + types + license', () => {
  assert.equal(pkg.type, 'module');
  assert.equal(pkg.sideEffects, false);
  assert.ok(pkg.version, 'has a version');
  assert.equal(pkg.license, 'CC0-1.0', 'declares the CC0-1.0 license');
  assert.ok(Array.isArray(pkg.files), 'has a files allowlist');
  assert.ok(pkg.files.includes('tempura.wasm'), 'files ships tempura.wasm');
  assert.ok(pkg.files.includes('types'), 'files ships the .d.ts');
  assert.ok(pkg.files.includes('LICENSE'), 'files ships the LICENSE');
  assert.ok(existsSync(fromRoot('LICENSE')), 'LICENSE exists on disk');
  assert.match(readFileSync(fromRoot('LICENSE'), 'utf8'), /CC0 1\.0 Universal/);
  assert.equal(pkg.exports['.'].types, './types/index.d.ts');
});

test('publishConfig points the publish at the self-hosted registry', () => {
  assert.ok(pkg.publishConfig, 'has a publishConfig');
  assert.match(
    pkg.publishConfig.registry,
    /^https:\/\/git\.hugodaniel\.com\/api\/packages\/hugo\/npm\/$/,
    'registry is the Gitea per-owner npm endpoint (trailing slash required)',
  );
});

test('the three subpath exports point at runtime files on disk', () => {
  // `.`, `./ops` and `./blobs` are plan 10's export list; every other
  // entry (the wasm, package.json) is a file too.
  for (const sub of ['.', './ops', './blobs']) {
    assert.ok(pkg.exports[sub], `exports["${sub}"] is declared`);
  }
  for (const [sub, target] of Object.entries(pkg.exports)) {
    const conds = typeof target === 'string' ? { default: target } : target;
    for (const [cond, rel] of Object.entries(conds)) {
      // `types` and the wasm are build outputs — verified by `npm run
      // build` + `npm pack`, not by a bare `node --test`.
      if (cond === 'types' || rel.endsWith('.wasm')) continue;
      assert.ok(existsSync(fromRoot(rel)), `exports["${sub}"].${cond} → ${rel} is missing`);
    }
  }
});

test('public API resolves through the package name (self-reference)', async () => {
  const mod = await import('tempura');
  assert.equal(typeof mod.Tempura, 'function');
  assert.equal(typeof mod.Tempura.load, 'function');

  const opsMod = await import('tempura/ops');
  assert.equal(typeof opsMod.retime, 'function');
  assert.equal(typeof opsMod.insertNote, 'function');

  const blobs = await import('tempura/blobs');
  assert.equal(typeof blobs.decodeTimeline, 'function');
  assert.equal(typeof blobs.decodePlayhead, 'function');
  assert.equal(typeof blobs.decodeDiagnostics, 'function');
});

test('version is in lockstep across package.json, build.zig.zon, and root.zig', () => {
  // The version is spelled by hand in three places; a release bump that
  // updates one but not the others ships a mislabeled package. Repo-root
  // reads are test-only (never published), pacer's rule verbatim.
  const readRoot = (rel) => readFileSync(fromRepo(rel), 'utf8');
  const zon = readRoot('build.zig.zon').match(/\.version\s*=\s*"([^"]+)"/);
  const root = readRoot('src/root.zig').match(/pub const version\s*=\s*"([^"]+)"/);
  assert.ok(zon, 'build.zig.zon declares a .version');
  assert.ok(root, 'src/root.zig declares a pub const version');
  assert.equal(zon[1], pkg.version, 'build.zig.zon .version matches package.json');
  assert.equal(root[1], pkg.version, 'src/root.zig version matches package.json');
});

test('the wasm declares exactly the frozen tpr_* surface', () => {
  // The export set freezes at E3 and is append-only: this list is the
  // frozen one, so a REMOVED or RENAMED export fails here, and an added
  // one fails until it is written down.
  const exported = WebAssembly.Module.exports(new WebAssembly.Module(wasmBytes))
    .filter((e) => e.kind === 'function')
    .map((e) => e.name)
    .sort();
  assert.deepEqual(exported, [
    'tpr_abiVersion',
    'tpr_apply',
    'tpr_at',
    'tpr_atTick',
    'tpr_attachAnchor',
    'tpr_build',
    'tpr_diagLen',
    'tpr_diagPtr',
    'tpr_docCap',
    'tpr_docPtr',
    'tpr_exportScore',
    'tpr_fileCap',
    'tpr_filePtr',
    'tpr_load',
    'tpr_loadFile',
    'tpr_opCap',
    'tpr_opPtr',
    'tpr_outCap',
    'tpr_outPtr',
    'tpr_plan',
    'tpr_playheadPtr',
    'tpr_snap',
    'tpr_text',
    'tpr_textPtr',
    'tpr_timeline',
    'tpr_timelinePtr',
  ]);
});

test('the wasm imports nothing but SJON plugin dispatch', () => {
  // A freestanding artifact with a surprise import does not instantiate
  // in a browser; the one it does have is stubbed by the glue.
  const imports = WebAssembly.Module.imports(new WebAssembly.Module(wasmBytes));
  assert.deepEqual(
    imports.map((i) => `${i.module}.${i.name}`),
    ['env.sjon_host_invoke_plugin'],
  );
});

test('the handshake: abi version and every cap', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  assert.equal(t.abiVersion, 1);
  assert.ok(t.caps.doc >= 1 << 20, 'the doc zone holds a real document');
  assert.ok(t.caps.file >= t.caps.doc, 'the file zone holds a whole module');
  assert.ok(t.caps.op >= 1 << 10, 'the op zone holds an operation');
  assert.ok(t.caps.out >= t.caps.doc, 'the out zone holds a built file');
});

test('load → text → timeline → at → atTick → snap, one document', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  assert.equal(t.ok, true, `load: ${JSON.stringify(t.diagnostics)}`);
  assert.deepEqual(t.diagnostics, []);

  // `text` is the document's own source, byte for byte — not a re-print.
  assert.equal(t.text, DOC);

  const tl = t.timeline();
  assert.equal(tl.segments.length, 1);
  assert.equal(tl.segments[0].us, 500000);
  assert.equal(tl.meters.length, 1);
  assert.deepEqual([tl.meters[0].n, tl.meters[0].d], [4, 4]);
  assert.equal(tl.bars.count, 3, 'the bar table reaches the bar :length lands on');
  assert.equal(tl.end, 'hold');
  assert.deepEqual(
    tl.sections.map((s) => s.name),
    ['intro'],
  );
  assert.deepEqual(
    tl.cues.map((c) => c.name),
    ['drop'],
  );
  assert.deepEqual(
    tl.lanes.map((l) => [l.name, l.kind, l.onsets]),
    [['flash', 'notes', 1]],
  );
  // Cached until the next load.
  assert.equal(t.timeline(), tl);

  const oneBar = 184504320n;
  const at = t.atTick(oneBar);
  assert.equal(at.refused, null);
  assert.equal(at.tick, oneBar);
  assert.equal(at.bar, 1n);
  assert.equal(at.prevCue, 0, 'the cue at 1bar is the previous one');
  assert.equal(at.nextCue, null);
  assert.deepEqual(at.sectionIds, [], 'intro is [0bar, 1bar) and excludes 1bar');
  assert.equal(at.orderRow, null, 'no IT conductor, no tracker position');

  // Two seconds in at 500000 µs per quarter in [4 4] is one bar.
  const bySeconds = t.at(2);
  assert.equal(bySeconds.tick, oneBar);

  // The snap grid moves a tick that is off the lattice and leaves one
  // that is on it.
  assert.equal(t.snap(oneBar, 'bar'), oneBar);
  assert.equal(t.snap(oneBar + 1000n, 'bar'), oneBar);
  assert.equal(t.snap(0n, 'q16'), 0n);
});

test('at(): a clock no map can answer for comes back as a refusal', async () => {
  // A document that HOLDS clamps its clock with `@min`, which swallows a
  // NaN; one that LOOPS wraps with `@mod`, which does not. The refusal
  // is the looping document's, and the corpus pins it on this fixture.
  const looping = readFileSync(fromRepo('corpus/loop-wrap-seconds/doc.sjon'), 'utf8');
  const t = await Tempura.load(wasmBytes, looping);
  assert.equal(t.ok, true, JSON.stringify(t.diagnostics));
  assert.equal(t.at(Number.NaN).refused, 'non-finite-time');
  assert.equal(t.at(Number.POSITIVE_INFINITY).refused, 'non-finite-time');
  // A clock inside the loop is a position like any other.
  assert.equal(t.at(3.5).refused, null);
});

test('plan → apply → text, and the plan is held between them', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  const op = ops.retime({ sel: ops.sel({ kinds: ['note'] }), delta: 46126080 });

  const planned = t.plan(op);
  assert.ok(planned.actions.startsWith('['), 'actions are a JSON array');
  assert.ok(planned.actions.includes('set_keyword'), 'a retime sets :at');
  assert.deepEqual(planned.diagnostics, []);

  // `apply()` with no argument commits the very plan just shown.
  const applied = t.apply();
  assert.equal(applied.ok, true, JSON.stringify(applied.diagnostics));
  assert.notEqual(t.text, DOC, 'the document moved');
  assert.match(t.text, /:at 1q/, 'the note is a quarter later');

  // …and an operation passed straight in plans and applies in one call.
  const again = t.apply(ops.transpose({ sel: ops.sel({ kinds: ['note'] }), semitones: 12 }));
  assert.equal(again.ok, true, JSON.stringify(again.diagnostics));
  assert.match(t.text, /:key 48/);
});

test('plan(): an ask that is not an operation is diagnostics, never a throw', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  const planned = t.plan({ op: 'nonsense' });
  assert.equal(planned.actions, '');
  assert.ok(planned.diagnostics.length > 0, 'it said why');
  assert.equal(planned.diagnostics[0].severity, 'error');
});

test('exportScore(): a pacer score, and the velocity switch reaches it', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  const plain = t.exportScore();
  assert.match(plain, /\(transport/, 'a pacer score opens with its transport');
  assert.match(plain, /\(trigger :target flash/, 'a notes lane is a pacer trigger');
  assert.ok(!plain.includes('flash-vel'));
  assert.match(t.exportScore({ velocity: true }), /flash-vel/);
});

test('build(): both kinds, and a document with no anchor builds either', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  const mid = t.build('mid');
  assert.ok(mid instanceof Uint8Array);
  assert.equal(new TextDecoder().decode(mid.subarray(0, 4)), 'MThd');
  const it = t.build('it');
  assert.equal(new TextDecoder().decode(it.subarray(0, 4)), 'IMPM');
});

test('loadFile(): a .mid becomes a document in the wasm', async () => {
  const bytes = readFileSync(fromRepo('corpus/skeleton-smf/song.mid'));
  const t = await Tempura.load(wasmBytes, bytes, { kind: 'mid' });
  assert.equal(t.ok, true, JSON.stringify(t.diagnostics));
  assert.match(t.text, /\(timeline/);
  assert.match(t.text, /\(anchor :id song :kind smf/);
  assert.ok(t.timeline().lanes.length > 0, 'the skeleton stated some lanes');
});

test('attachAnchor(): the bytes are verified, and a mismatch changes nothing', async () => {
  const bytes = readFileSync(fromRepo('corpus/tempo-three-conductors-it/song.it'));
  const text = readFileSync(fromRepo('corpus/tempo-three-conductors-it/doc.sjon'), 'utf8');
  const t = await Tempura.load(wasmBytes, text);
  // No filesystem in wasm, so the anchor's own dump has no bytes yet.
  assert.equal(t.ok, false);
  assert.ok(
    t.diagnostics.some((d) => d.message.includes('song.it')),
    'it named the file it could not read',
  );

  const wrong = t.attachAnchor(new Uint8Array([1, 2, 3]));
  assert.equal(wrong.ok, false);
  assert.equal(wrong.status, 1);
  assert.ok(wrong.diagnostics.some((d) => d.message.includes('match no')));

  const right = t.attachAnchor(bytes);
  assert.equal(right.ok, true, JSON.stringify(right.diagnostics));
  assert.equal(t.text, text, 'attaching bytes never rewrites the document');
});

test('a bad call changes nothing, and an unloaded instance answers empty', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  // Over the op cap is a host bug: status 2, the document untouched.
  const big = 'x'.repeat(t.caps.op + 1);
  assert.equal(t.apply(big).status, 2);
  assert.equal(t.text, DOC);

  // An instance with nothing loaded answers with nothing rather than
  // trapping — every query is total.
  const bare = await Tempura.instantiate(wasmBytes);
  assert.equal(bare.text, null);
  assert.equal(bare.timeline(), null);
  assert.equal(bare.at(0), null);
  assert.equal(bare.atTick(0n), null);
  assert.equal(bare.snap(17n, 'bar'), 17n, 'a snap with no map leaves the tick alone');
  assert.equal(bare.build('mid'), null);
  assert.equal(bare.exportScore(), null);
  assert.deepEqual(bare.diagnostics, []);
});
