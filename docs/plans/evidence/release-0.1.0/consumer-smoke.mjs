// Consumer smoke test for the packed tempura tarball, run OUTSIDE the
// workspace: package/subpath imports, the shipped wasm, a timeline, an
// edit, a score with its position map, and both file round trips.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as blobs from 'tempura/blobs';
import { Tempura } from 'tempura';
import * as ops from 'tempura/ops';

const require = createRequire(import.meta.url);
const wasmPath = require.resolve('tempura/tempura.wasm');
const wasm = new WebAssembly.Module(readFileSync(wasmPath));
const doc = readFileSync(new URL('./doc.sjon', import.meta.url), 'utf8');

const t = await Tempura.load(wasm, doc);
assert.equal(t.ok, true, JSON.stringify(t.diagnostics));

const tl = t.timeline();
assert.ok(tl.segments.length > 0, 'tempo segments');
assert.ok(tl.meters.length > 0, 'meters');
assert.ok(tl.lanes.length > 0, 'lanes');

const at = t.at(1.5);
assert.ok(at.tick > 0n, 'playhead tick');
assert.ok(t.atTick(at.tick).bar >= 0n, 'atTick');

const score = t.exportScore();
assert.equal(typeof score, 'string');
const map = t.exportScoreMap();
assert.ok(map, 'position map');
assert.ok(map.entries.length > 0, 'map entries');
const scoreBytes = Buffer.byteLength(score, 'utf8');
for (const e of map.entries) {
  assert.ok(e.text[0] < e.text[1] && e.text[1] <= scoreBytes, 'text span inside score');
  assert.ok(e.doc.length > 0 && e.doc[0][0] < e.doc[0][1], 'doc span');
}
assert.throws(() => blobs.decodeMap(new Uint8Array([1, 2, 3])), /too short|magic/);

const planned = t.plan(ops.retime({ sel: ops.sel({ kinds: ['note'] }), delta: 46126080 }));
assert.equal(t.diagnostics.length, 0, JSON.stringify(t.diagnostics));
assert.notEqual(planned.actions, '');
t.apply();
const edited = t.text;
assert.notEqual(edited, doc, 'the edit reached the document');

for (const kind of ['mid', 'it']) {
  const bytes = t.build(kind);
  assert.ok(bytes instanceof Uint8Array && bytes.length > 0, `${kind} build`);

  // The native CLI is the authority when it is available: the packed wasm
  // and the released Zig build must produce the same bytes from this text.
  if (process.env.TEMPURA_CLI) {
    const dir = mkdtempSync(join(tmpdir(), 'tempura-consumer-'));
    try {
      writeFileSync(join(dir, 'doc.sjon'), edited);
      execFileSync(process.env.TEMPURA_CLI, ['build', 'doc.sjon', '--kind', kind, '-o', `out.${kind}`], {
        cwd: dir,
        stdio: ['ignore', 'ignore', 'pipe'],
      });
      assert.deepEqual(new Uint8Array(readFileSync(join(dir, `out.${kind}`))), bytes, `${kind} CLI parity`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  // A file in, its document out, a fresh instance that has seen neither:
  // the dump is reloaded, the file attached, and the build repeated.
  const first = await Tempura.load(wasm, bytes, { kind });
  assert.equal(first.ok, true, `${kind}: ${JSON.stringify(first.diagnostics)}`);
  const dump = first.text;
  assert.ok(dump.length > 0, `${kind} dump`);
  const firstBuild = first.build(kind);

  const second = await Tempura.load(wasm, dump);
  if (!second.ok) second.attachAnchor(bytes);
  assert.equal(second.text, dump, `${kind}: the document came back byte for byte`);
  assert.deepEqual(second.build(kind), firstBuild, `${kind}: fresh instance built the same bytes`);
}

console.log(`packed consumer ok: ${map.entries.length} map entries, ${edited.length} bytes of document`);
