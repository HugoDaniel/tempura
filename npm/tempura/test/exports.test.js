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

/**
 * `Diag.Code`'s variants in ordinal order, read from the enum itself.
 * The ordinal IS the wire (it rides the `'TPDG'` blob) and the enum is
 * append-only from E3, so a test that wants to name a code reads it here
 * rather than hard-coding a number that means nothing to a reader.
 * Repo-root reads are test-only, the lockstep test's rule.
 */
const DIAG_CODES = (() => {
  const src = readFileSync(fromRepo('src/Diag.zig'), 'utf8');
  const body = src.slice(src.indexOf('pub const Code = enum(u16) {'));
  return [...body.slice(0, body.indexOf('\n};')).matchAll(/^ {4}([a-z][a-z0-9_]*),$/gm)].map(
    (m) => m[1],
  );
})();
const diagCode = (name) => {
  const at = DIAG_CODES.indexOf(name);
  assert.ok(at >= 0, `src/Diag.zig has no code named ${name}`);
  return at;
};

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
  assert.ok(pkg.files.includes('README.md'), 'files ships the README');
  assert.ok(existsSync(fromRoot('LICENSE')), 'LICENSE exists on disk');
  assert.match(readFileSync(fromRoot('LICENSE'), 'utf8'), /CC0 1\.0 Universal/);
  // The README is what a consumer sees on the registry page; an empty
  // one there is worse than none.
  assert.ok(existsSync(fromRoot('README.md')), 'README.md exists on disk');
  const readme = readFileSync(fromRoot('README.md'), 'utf8');
  assert.match(readme, /^# tempura$/m, 'the README names the package');
  assert.match(readme, /tempura\/tempura\.wasm/, 'and says where the wasm bytes come from');
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
    'tpr_exportScoreMap',
    'tpr_fileCap',
    'tpr_filePtr',
    'tpr_load',
    'tpr_loadFile',
    'tpr_mapCap',
    'tpr_mapPtr',
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
  assert.ok(t.caps.map >= 1 << 10, 'the map zone holds a real position map');
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

test('plan(): a refusal is the empty action list, and nothing is held to commit', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  // A well-formed operation the planner rejects: `Plan.text()` spells a
  // plan with no actions `[]`, and the reason rides the 'TPDG' blob.
  const planned = t.plan(ops.unbind('nope'));
  assert.equal(planned.actions, '[]\n');
  assert.equal(planned.diagnostics.length, 1);
  assert.equal(planned.diagnostics[0].severity, 'error');
  assert.equal(planned.diagnostics[0].code, diagCode('edit_range_empty'));

  // …and there is nothing to commit, so the `apply()` that follows is a
  // BAD CALL rather than a silent no-op reported as success.
  const applied = t.apply();
  assert.equal(applied.status, 2);
  assert.equal(t.text, DOC, 'the document stands');
});

test('apply(op): a plan the planner refused never reaches the document', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  const applied = t.apply(ops.retime({ sel: ops.sel({ lanes: ['nope'] }), delta: 1 }));
  assert.equal(applied.status, 1, 'diagnostics, not success');
  assert.equal(applied.ok, false);
  assert.deepEqual(
    applied.diagnostics.map((d) => [d.stage, d.severity, d.code]),
    [['operation', 'error', diagCode('edit_range_empty')]],
  );
  assert.equal(t.text, DOC, 'the document stands');
});

test('apply(actions): the list a plan handed back commits in a fresh instance', async () => {
  // Plan 10's own spelling for `tpr_apply`: "actions as JSON → the
  // document re-loaded". A host plans, shows the actions, and commits
  // them — possibly in a process that has only the document and the text
  // of the plan.
  const retime = ops.retime({ sel: ops.sel({ kinds: ['note'] }), delta: 46126080 });

  const held = await Tempura.load(wasmBytes, DOC);
  const planned = held.plan(retime);
  assert.match(planned.actions, /^\[\n\{"op":"set_keyword"/, 'the actions are the JSON array');
  assert.equal(held.apply().status, 0, 'the held plan commits');

  const fresh = await Tempura.load(wasmBytes, DOC);
  const applied = fresh.apply(planned.actions);
  assert.equal(applied.status, 0, JSON.stringify(applied.diagnostics));
  assert.equal(fresh.text, held.text, 'the action list and the held plan are the same edit');
});

test('apply(actions): a host that struck a line out applies the rest', async () => {
  // Three notes, so a plan has three actions and striking two out is a
  // real edit to the plan rather than to the whole of it.
  const three = `(timeline :title "struck" :length 2bar)

(tempo-point :at 0bar :us 500000)
(meter-point :at 0bar :sig [4 4])

(lane :name flash :kind notes :target flash
  (note :at 0bar :dur 1q :key 36 :vel 110)
  (note :at 1q :dur 1q :key 38 :vel 90)
  (note :at 2q :dur 1q :key 41 :vel 80))
`;
  const t = await Tempura.load(wasmBytes, three);
  const planned = t.plan(ops.transpose({ sel: ops.sel({ kinds: ['note'] }), semitones: 12 }));
  const lines = planned.actions.trimEnd().split('\n');
  assert.equal(lines.length, 5, '`[`, three actions, `]`');

  // Keep the first action, drop the other two — the array a host hands
  // back after deleting lines in an editor.
  const edited = `${lines[0]}\n${lines[1].replace(/,$/, '')}\n]\n`;
  const applied = t.apply(edited);
  assert.equal(applied.status, 0, JSON.stringify(applied.diagnostics));
  assert.match(t.text, /:key 48/, 'the action that was kept landed');
  assert.match(t.text, /:key 38/, 'and the two struck out did not');
  assert.match(t.text, /:key 41/);
});

test('apply(actions): a list that is not an action list is diagnostics, document intact', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  for (const payload of [
    '[{"op":"nope","root":0,"path":[]}]',
    '[{"op":"set_keyword","root":0}]',
    '[1]',
    '[',
  ]) {
    const applied = t.apply(payload);
    assert.equal(applied.status, 1, `${payload} is refused`);
    assert.equal(applied.diagnostics.length, 1);
    assert.equal(applied.diagnostics[0].code, diagCode('sjon_diagnostic'));
    assert.equal(t.text, DOC, `${payload} left the document alone`);
  }
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

test('exportScore(): a conducted document whose file is not here yields nothing, and says why', async () => {
  // The CLI's refusal (`src/cli/export_score.zig`), in the wasm: a score
  // IS its transport, and the placeholder's `:bpm 120` under a header
  // naming the conductor is a wrong score, not a score with a warning.
  // Before this was pinned the module handed that score out AND replaced
  // the load's `anchor_unavailable` with the exporter's empty list — a
  // clean score, as far as a host could tell.
  const text = readFileSync(fromRepo('src/cli/testdata/conducted-absent.sjon'), 'utf8');
  const t = await Tempura.load(wasmBytes, text);
  assert.equal(t.ok, false, 'the load says the conductor is not here');
  assert.ok(t.diagnostics.some((d) => d.code === diagCode('anchor_unavailable')));

  assert.equal(t.exportScore(), null, 'no score leaves the module');
  assert.deepEqual(
    t.diagnostics.map((d) => [d.stage, d.severity, d.code]),
    [['operation', 'error', diagCode('anchor_unavailable')]],
  );
  assert.match(t.diagnostics[0].message, /tpr_attachAnchor/, 'and it names the way out');
  assert.equal(t.text, text, 'the document stands');

  // …and the way out works. The fixture declares the :size and :sha256
  // of `corpus/tempo-by-reference-conductor/song.mid`; attached, the
  // conductor is read and the transport is the FILE's 125, not 120.
  const bytes = readFileSync(fromRepo('corpus/tempo-by-reference-conductor/song.mid'));
  const attached = t.attachAnchor(bytes);
  assert.equal(attached.ok, true, JSON.stringify(attached.diagnostics));
  const score = t.exportScore();
  assert.ok(score !== null, 'a score, once the conductor is here');
  assert.match(score, /\(transport :bpm 125/);
  assert.deepEqual(t.diagnostics, []);
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
  // …and an empty answer says why. Every zero-length answer publishes its
  // reason, nothing loaded included, so the blob is always the CALL's.
  assert.deepEqual(
    bare.diagnostics.map((d) => [d.stage, d.severity, d.code]),
    [['operation', 'error', diagCode('sjon_diagnostic')]],
  );
  assert.match(bare.diagnostics[0].message, /no document is loaded/);
});

test('a zero-length answer says its own reason, never the previous report', async () => {
  const t = await Tempura.load(wasmBytes, DOC);
  // A refusal first, so the blob holds something a stale zero would leave.
  assert.equal(t.plan(ops.unbind('nope')).diagnostics[0].code, diagCode('edit_range_empty'));

  // An ask past the op zone answers nothing — and says so, replacing the
  // refusal above rather than leaving it to be read as this call's.
  const big = t.plan('x'.repeat(t.caps.op + 1));
  assert.equal(big.actions, '');
  assert.deepEqual(
    big.diagnostics.map((d) => [d.stage, d.severity, d.code]),
    [['operation', 'error', diagCode('sjon_diagnostic')]],
  );
  assert.match(big.diagnostics[0].message, /zone holds/);
});
