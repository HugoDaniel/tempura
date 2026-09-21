// The fresh-instance round trip, both kinds (plan 10, P108 phase 5):
//
//     loadFile → text → NEW instance → load + attachAnchor → build
//
// byte-equal to the native build. This is the claim that a browser host
// can save a document beside the file it was dumped from, reopen both in
// a process that has never seen either, and rebuild the same bytes —
// which is what makes a saved document plus its file a complete piece.
//
// Three legs, and all three must hold:
//
//   1. the fresh instance's document is the first one's, byte for byte;
//   2. its build is the first instance's build, byte for byte;
//   3. …and the native CLI's build of that same document, byte for byte
//      (skipped with a printed reason when `zig-out/bin/tempura` has not
//      been built — a Zig-only checkout still gets legs 1 and 2).
//
// The second instance is a REAL second instance: its own `WebAssembly`
// memory, its own heap, its own preloaded schema. Nothing carries over
// but the two byte strings a host would have saved.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { Tempura } from '../src/index.js';

const fromRepo = (rel) => fileURLToPath(new URL(`../../../${rel}`, import.meta.url));
const wasmModule = new WebAssembly.Module(readFileSync(fromRepo('npm/tempura/tempura.wasm')));
const cliPath = fromRepo('zig-out/bin/tempura');

/**
 * The native authority: `tempura build DOC -o FILE`, run in a directory
 * holding the document and the file its anchor names — the CLI resolves
 * an anchor's `:file` relative to the document, which is exactly what
 * `attachAnchor` stands in for in the browser.
 *
 * Null when the CLI has not been built.
 *
 * @param {string} docText
 * @param {string} anchorName
 * @param {Uint8Array} anchorBytes
 * @param {'mid' | 'it'} kind
 * @returns {Uint8Array | null}
 */
function nativeBuild(docText, anchorName, anchorBytes, kind) {
  if (!existsSync(cliPath)) return null;
  const dir = mkdtempSync(join(tmpdir(), 'tempura-roundtrip-'));
  try {
    writeFileSync(join(dir, 'doc.sjon'), docText);
    writeFileSync(join(dir, anchorName), anchorBytes);
    const out = join(dir, `out.${kind}`);
    execFileSync(cliPath, ['build', 'doc.sjon', '--kind', kind, '-o', out], {
      cwd: dir,
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    return new Uint8Array(readFileSync(out));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/**
 * @param {'mid' | 'it'} kind
 * @param {string} fixture the corpus path of the file to start from
 * @param {string} anchorName what the dumped document's anchor calls it
 */
function roundTrip(kind, fixture, anchorName) {
  test(`fresh-instance round trip: a .${kind} through a second wasm instance`, async () => {
    const bytes = new Uint8Array(readFileSync(fromRepo(fixture)));

    // ---- the first instance: a file in, a document and a file out ----
    const first = await Tempura.instantiate(wasmModule);
    const loaded = first.loadFile(bytes, kind);
    assert.equal(loaded.ok, true, JSON.stringify(loaded.diagnostics));
    const text = first.text;
    assert.ok(text, 'the dump produced a document');
    const firstBuild = first.build(kind);
    assert.ok(firstBuild, `the first build: ${JSON.stringify(first.diagnostics)}`);

    // ---- a second instance that has seen neither ----
    const second = await Tempura.instantiate(wasmModule);
    assert.notEqual(second.exports, first.exports, 'a real second instance');

    const bare = second.reload(text);
    // Leg 0, plan 10's row: there is no filesystem in wasm, so a document
    // whose dump names a file it cannot read says `anchor_unavailable`
    // rather than going quiet — and it stays LOADED, which is what lets
    // the host answer with the bytes.
    if (!bare.ok) {
      assert.ok(
        bare.diagnostics.some((d) => d.message.includes(anchorName)),
        `it named the file it could not read: ${JSON.stringify(bare.diagnostics)}`,
      );
      assert.equal(second.text, text, 'and the document is loaded all the same');
    }

    const attached = second.attachAnchor(bytes);
    assert.equal(attached.ok, true, JSON.stringify(attached.diagnostics));

    // Leg 1: the document survived the journey untouched.
    assert.equal(second.text, text, 'the document came back byte for byte');

    // Leg 2: so did the file it builds.
    const secondBuild = second.build(kind);
    assert.ok(secondBuild, `the second build: ${JSON.stringify(second.diagnostics)}`);
    assert.deepEqual(secondBuild, firstBuild, 'the fresh instance built the same bytes');

    // Leg 3: and the native build agrees.
    const native = nativeBuild(text, anchorName, bytes, kind);
    if (native === null) {
      console.log(
        `roundtrip: zig-out/bin/tempura is missing — skipping the native leg for .${kind} ` +
          '(run `zig build cli`)',
      );
      return;
    }
    assert.deepEqual(secondBuild, native, 'wasm32 and native built the same bytes');
  });
}

roundTrip('mid', 'corpus/skeleton-smf/song.mid', 'song.mid');
roundTrip('it', 'corpus/skeleton-it/song.it', 'song.it');

test('a document that keeps its anchor by reference says so, and rebuilds once attached', async () => {
  // The other half of the same rule: a hand-written document with an
  // `(anchor …)` and NO inline dump is `anchor_unavailable` in wasm on
  // every load, because a resolver that is present and cannot produce the
  // bytes is a refusal and never a silent re-read (plan 02).
  const text = readFileSync(fromRepo('corpus/tempo-three-conductors-smf/doc.sjon'), 'utf8');
  const bytes = new Uint8Array(
    readFileSync(fromRepo('corpus/tempo-three-conductors-smf/song.mid')),
  );

  const t = await Tempura.instantiate(wasmModule);
  const bare = t.reload(text);
  assert.equal(bare.ok, false);
  assert.equal(bare.status, 1);
  assert.ok(bare.diagnostics.some((d) => d.message.includes('song.mid')));

  assert.equal(t.attachAnchor(bytes).ok, true);
  const built = t.build('mid');
  assert.ok(built, JSON.stringify(t.diagnostics));

  const native = nativeBuild(text, 'song.mid', bytes, 'mid');
  if (native === null) {
    console.log('roundtrip: zig-out/bin/tempura is missing — skipping the native leg');
    return;
  }
  assert.deepEqual(built, native, 'wasm32 and native built the same bytes');
});

test('the anchored document a build needs is verified, not assumed', async () => {
  // Attaching the WRONG file leaves the document as it was — the build
  // that follows is still the one the right bytes produce, not a mix.
  const text = readFileSync(fromRepo('corpus/tempo-three-conductors-smf/doc.sjon'), 'utf8');
  const right = new Uint8Array(
    readFileSync(fromRepo('corpus/tempo-three-conductors-smf/song.mid')),
  );
  const wrong = new Uint8Array(readFileSync(fromRepo('corpus/skeleton-smf/song.mid')));

  const t = await Tempura.instantiate(wasmModule);
  t.reload(text);
  assert.equal(t.attachAnchor(right).ok, true);
  const expected = t.build('mid');

  const refused = t.attachAnchor(wrong);
  assert.equal(refused.ok, false);
  assert.equal(refused.status, 1);
  assert.ok(refused.diagnostics.some((d) => d.message.includes('match no')));
  assert.deepEqual(t.build('mid'), expected, 'the document was left exactly as it was');
});
