// T1's node proof: the position map of every golden score, read back
// through the two tools that own its ends.
//
// A map record is a span in the emitted text, a span (or several) in the
// document, and the claim that the first came from the second. The
// fixtures come from `zig build landing` (`tools/gen_landing.zig`) and
// are regenerated, never hand-edited.
//
//   * SJON's own wasm answers the score end (`sjon_node_table`: every
//     text span must be a node of the score, or a cue comment, which is
//     a comment and has none) and the document end
//     (`sjon_address_of_span`: every doc span of a fixture whose
//     document text is written beside it must name a node; a
//     constructed Doc has spans and no text, so only the span shape
//     above is checked for those).
//   * tempura's own wasm must produce the same bindings as the native
//     fixture for the cases whose document text is written beside it.
//
// SJON's wasm is built from the PINNED dependency by `zig build sjon-wasm`
// (`tools/zt sjon-wasm`), not read from a sibling checkout: the release
// archive carries source, and `../SJON/zig-out` may hold a different SJON.
// A direct `node --test` without the vendored artifact skips with a reason.

import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { decodeMap } from '../src/blobs.js';
import { Tempura } from '../src/index.js';

const fromRoot = (rel) => fileURLToPath(new URL(`../${rel}`, import.meta.url));
const scoresDir = fileURLToPath(new URL('./fixtures/scores/', import.meta.url));
const sjonWasmPath =
  process.env.TEMPURA_SJON_WASM ??
  fileURLToPath(new URL('../../../zig-out/sjon-wasm/sjon.wasm', import.meta.url));

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Every map fixture with the score and document text it was written beside. */
const cases = readdirSync(scoresDir)
  .filter((file) => file.endsWith('.pacer.map.json'))
  .sort()
  .map((file) => {
    const map = JSON.parse(readFileSync(`${scoresDir}${file}`, 'utf8'));
    const score = readFileSync(`${scoresDir}${file.replace(/\.map\.json$/, '')}`);
    const doc = map.doc === null ? null : readFileSync(`${scoresDir}${map.doc}`);
    return { file, map, score, doc };
  });

const wasmBytes = readFileSync(fromRoot('tempura.wasm'));

test('map: every fixture records a span in the text and a span in the document', () => {
  assert.ok(cases.length > 0, 'no map fixtures; run `zig build landing`');
  for (const c of cases) {
    assert.ok(c.map.entries.length > 0, `${c.file}: no entries`);
    for (const e of c.map.entries) {
      assert.ok(e.text[0] < e.text[1], `${c.file}: empty text span`);
      assert.ok(e.text[1] <= c.score.length, `${c.file}: text span past the score`);
      assert.ok(e.doc.length > 0, `${c.file}: a record with no document node`);
      for (const d of e.doc) {
        assert.ok(d[0] < d[1], `${c.file}: empty doc span`);
        if (c.doc) assert.ok(d[1] <= c.doc.length, `${c.file}: doc span past the document`);
      }
    }
  }
});

test('map: the glue decodes the blob and refuses a corrupt one', () => {
  assert.throws(() => decodeMap(new Uint8Array([1, 2, 3])), /too short|magic/);
});

const sjonAvailable = existsSync(sjonWasmPath);

test('map: SJON answers both ends, a score node per text span and a document node per doc span', {
  skip: sjonAvailable ? false : 'no vendored SJON wasm (run `tools/zt sjon-wasm`)',
}, () => {
  const sjon = loadSjon(readFileSync(sjonWasmPath));
  for (const c of cases) {
    const scoreText = decoder.decode(c.score);
    const table = sjon.nodeTable(scoreText);
    // The score text is real SJON and parses clean: the observation the
    // record is argued from, not just the node spans it yields.
    assert.equal(table.diagnostics.length, 0, `${c.file}: score diagnostics`);
    const rows = new Set(table.nodes.map((n) => `${n.span[0]}:${n.span[1]}`));
    const docText = c.doc === null ? null : decoder.decode(c.doc);
    for (const e of c.map.entries) {
      const key = `${e.text[0]}:${e.text[1]}`;
      if (!rows.has(key)) {
        // The one shape the ruling names as a scope note: a cue is
        // emitted as a comment, and a comment has no node. Spans are
        // UTF-8 bytes, so the slice comes from the bytes.
        const token = decoder.decode(c.score.subarray(e.text[0], e.text[1]));
        assert.ok(
          token.startsWith('; cue '),
          `${c.file}: no score node covers ${key} (${JSON.stringify(token)})`,
        );
        continue;
      }
      // A constructed Doc has no text to address: its spans were
      // shape-checked above, and this end cannot be resolved without
      // the bytes.
      if (docText === null) continue;
      for (const d of e.doc) {
        const answer = sjon.addressOfSpan(docText, d[0], d[1]);
        assert.notEqual(answer, null, `${c.file}: doc span ${d} names no node`);
        assert.deepEqual(answer.span, d, `${c.file}: doc span ${d} resolved elsewhere`);
        assert.equal(typeof answer.root, 'number', `${c.file}: doc span ${d} has no root`);
        assert.ok(Array.isArray(answer.path), `${c.file}: doc span ${d} has no path`);
      }
    }
  }

  // The observation native.pacer carries in the T1 record, committed in
  // full: the score table is 75 rows, one per form (20), per `(key …)`,
  // per `:at` element (14 number_with_unit) and per scene, with no
  // diagnostics; and the 8.5b phrase-note binding is answered by SJON
  // at both ends, the score node first and the document node it came
  // from second.
  const native = cases.find((c) => c.file === 'native.pacer.map.json');
  assert.ok(native, 'native.pacer.map.json is missing');
  const nativeText = decoder.decode(native.score);
  const nativeTable = sjon.nodeTable(nativeText);
  assert.equal(nativeTable.diagnostics.length, 0, 'native.pacer: score diagnostics');
  assert.equal(nativeTable.nodes.length, 75, 'native.pacer: node table rows');
  const kindCount = (kind) => nativeTable.nodes.filter((n) => n.kind === kind).length;
  assert.equal(kindCount('form'), 20, 'native.pacer: form rows');
  assert.equal(kindCount('number_with_unit'), 14, 'native.pacer: number_with_unit rows');

  const nativeDoc = decoder.decode(native.doc);
  const phrase = native.map.entries.find(
    (e) =>
      e.text[0] === 368 &&
      e.text[1] === 372 &&
      e.doc.length === 1 &&
      e.doc[0][0] === 879 &&
      e.doc[0][1] === 921,
  );
  assert.ok(phrase, 'native.pacer: the 8.5b phrase-note entry');
  assert.equal(decoder.decode(native.score.subarray(...phrase.text)), '8.5b');
  assert.deepEqual(sjon.addressOfSpan(nativeText, 368, 372), {
    root: 3,
    path: ['at', 3],
    span: [368, 372],
    kind: 'number_with_unit',
  });
  assert.deepEqual(sjon.addressOfSpan(nativeDoc, 879, 921), {
    root: 10,
    path: [0, 1],
    span: [879, 921],
    kind: 'form',
  });
});

test('map: the wasm produces the native fixture bindings byte for byte', async () => {
  let checked = 0;
  for (const c of cases) {
    // Only a document that came from finite text can be reloaded; a
    // constructed `Doc` has spans but no bytes to hand the loader.
    if (c.doc === null) continue;
    const t = await Tempura.load(wasmBytes, decoder.decode(c.doc));
    const opts = c.map.options;
    const score = t.exportScore(opts);
    const map = t.exportScoreMap(opts);
    assert.ok(score, `${c.file}: the wasm exported no score`);
    assert.ok(map, `${c.file}: the wasm exported no map (${JSON.stringify(t.diagnostics)})`);
    assert.equal(map.entries.length, c.map.entries.length, `${c.file}: entry count differs`);
    // The header names a source the wasm does not carry, so the offsets
    // differ; what must agree is what each span SLICES and the document
    // nodes behind it. Spans are UTF-8 bytes, so the wasm's text is
    // re-encoded before slicing.
    const wasmScore = encoder.encode(score);
    for (let i = 0; i < map.entries.length; i++) {
      const mine = map.entries[i];
      const fixture = c.map.entries[i];
      assert.deepEqual(mine.doc, fixture.doc, `${c.file}[${i}]: doc spans differ`);
      assert.equal(
        decoder.decode(wasmScore.subarray(...mine.text)),
        decoder.decode(c.score.subarray(...fixture.text)),
        `${c.file}[${i}]: the text spans slice different tokens`,
      );
    }
    checked++;
  }
  assert.ok(checked > 0, 'no fixture carried a document text to reload');
});

/**
 * SJON's own wasm, called through its framed ABI: `sjon_node_table` and
 * `sjon_address_of_span` over UTF-8 bytes. Two stubs cover the imports
 * every SJON document reaches but these calls never do.
 */
function loadSjon(bytes) {
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
    env: { sjon_host_resolve: () => 0, sjon_host_invoke_plugin: () => 0 },
  });
  const ex = instance.exports;
  const view = () => new DataView(ex.memory.buffer);

  /** `fn(textPtr, textLen, args…)` → the framed payload's text. */
  const call = (name, text, ...args) => {
    const input = encoder.encode(text);
    const ptr = ex.sjon_alloc(input.length);
    new Uint8Array(ex.memory.buffer, ptr, input.length).set(input);
    const out = ex[name](ptr, input.length, ...args);
    let payload = null;
    if (out !== 0) {
      const ok = view().getUint32(out, true);
      const len = view().getUint32(out + 4, true);
      payload = decoder.decode(new Uint8Array(ex.memory.buffer, out + 8, len));
      ex.sjon_free(out, 8 + len);
      assert.equal(ok, 1, `sjon_${name} refused: ${payload}`);
    }
    ex.sjon_free(ptr, input.length);
    return payload === null ? null : JSON.parse(payload);
  };

  return {
    nodeTable: (text) => call('sjon_node_table', text),
    addressOfSpan: (text, start, end) => call('sjon_address_of_span', text, start, end),
  };
}
