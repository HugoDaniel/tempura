// The three decoders, against blobs the real wasm wrote and against
// blobs built by hand for the cases a document cannot produce on demand
// (an unknown TLV section, a truncated buffer, a wrong magic).
//
// The encoders are pinned natively in `src/TprAbi.zig`; what is under
// test here is that this glue reads the same bytes the same way.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  DIAGS_MAGIC,
  decodeDiagnostics,
  decodePlayhead,
  decodeTimeline,
  PLAYHEAD_MAGIC,
  TIMELINE_MAGIC,
} from '../src/blobs.js';
import { Tempura } from '../src/index.js';

const fromRoot = (rel) => fileURLToPath(new URL(`../${rel}`, import.meta.url));
const fromRepo = (rel) => fileURLToPath(new URL(`../../../${rel}`, import.meta.url));
const wasmBytes = readFileSync(fromRoot('tempura.wasm'));

/** The raw bytes of a zone, copied out so a later call cannot move them. */
const zone = (t, ptrFn, len) =>
  new Uint8Array(t.exports.memory.buffer, t.exports[ptrFn](), len).slice();

test('the magics are the four-character codes read little-endian', () => {
  const le = (magic) =>
    String.fromCharCode(magic & 0xff, (magic >> 8) & 0xff, (magic >> 16) & 0xff, magic >>> 24);
  assert.equal(le(TIMELINE_MAGIC), 'TPTL');
  assert.equal(le(PLAYHEAD_MAGIC), 'TPPH');
  assert.equal(le(DIAGS_MAGIC), 'TPDG');
});

test("'TPTL': every list the derivation has, and the bar table's shape", async () => {
  const text = readFileSync(fromRepo('corpus/playhead-sections-cues/doc.sjon'), 'utf8');
  const t = await Tempura.load(wasmBytes, text);
  assert.equal(t.ok, true, JSON.stringify(t.diagnostics));
  const tl = decodeTimeline(zone(t, 'tpr_timelinePtr', t.exports.tpr_timeline()));

  assert.equal(tl.end, 'hold');
  assert.equal(typeof tl.integral, 'boolean');
  assert.equal(tl.segments.length, 1);
  assert.equal(tl.segments[0].tick, 0n);
  assert.equal(tl.segments[0].us, 500000);
  assert.equal(tl.segments[0].startSeconds, 0);
  // [3 4] for two bars then [4 4] — the fixture's own meter change.
  assert.deepEqual(
    tl.meters.map((m) => [m.tick, m.n, m.d, m.firstBar]),
    [
      [0n, 3, 4, 0n],
      [276756480n, 4, 4, 2n],
    ],
  );
  assert.equal(tl.bars.count, 5);
  assert.equal(tl.bars.lastStart, 645765120n);
  assert.deepEqual(
    tl.sections.map((s) => s.name),
    ['intro', 'swell', 'outro'],
  );
  assert.deepEqual(
    tl.cues.map((c) => [c.name, c.at]),
    [
      ['the drop', 276756480n],
      ['count in', 46126080n],
    ],
    'cues keep DOCUMENT order, not tick order',
  );
  assert.deepEqual(
    tl.lanes.map((l) => [l.name, l.kind, l.bound, l.onsets, l.steps]),
    [
      ['flash', 'notes', false, 3, 0],
      ['glow', 'curve', false, 0, 3],
    ],
  );
  assert.equal(tl.lanes[0].firstTick, 0n);
  assert.equal(tl.lanes[0].lastTick, 461260800n);
});

test("'TPTL': a document with no sections, cues or lanes omits those sections", async () => {
  const t = await Tempura.load(wasmBytes, '(timeline :length 1bar)\n');
  const tl = decodeTimeline(zone(t, 'tpr_timelinePtr', t.exports.tpr_timeline()));
  assert.deepEqual(tl.sections, []);
  assert.deepEqual(tl.cues, []);
  assert.deepEqual(tl.lanes, []);
  assert.equal(tl.segments.length, 1, 'a tempo segment there always is');
});

test("'TPTL': a section this decoder predates is skipped by its length", () => {
  // Forwards compatibility is the whole point of the TLV stream: a blob
  // from a newer module still decodes, minus what it added.
  const header = new Uint8Array(32);
  const dv = new DataView(header.buffer);
  dv.setUint32(0, TIMELINE_MAGIC, true);
  dv.setUint32(4, 1, true);
  dv.setBigInt64(8, 123n, true);
  dv.setFloat64(16, 1.5, true);
  header[24] = 0; // loop
  header[25] = 1; // integral

  // One unknown section carrying seven bytes, then a real 'TCUE'.
  const unknown = new Uint8Array(8 + 7);
  const udv = new DataView(unknown.buffer);
  udv.setUint32(0, 0x5a5a5a5a, true);
  udv.setUint32(4, 7, true);

  const name = new TextEncoder().encode('late');
  const cue = new Uint8Array(8 + 4 + 12 + name.length);
  const cdv = new DataView(cue.buffer);
  cdv.setUint32(0, 0x45554354, true); // 'TCUE' read LE
  cdv.setUint32(4, 4 + 12 + name.length, true);
  cdv.setUint32(8, 1, true);
  cdv.setBigInt64(12, 99n, true);
  cdv.setUint16(20, name.length, true);
  cue.set(name, 24);

  const blob = new Uint8Array([...header, ...unknown, ...cue]);
  const tl = decodeTimeline(blob);
  assert.equal(tl.length, 123n);
  assert.equal(tl.loopSeconds, 1.5);
  assert.equal(tl.end, 'loop');
  assert.equal(tl.integral, true);
  assert.deepEqual(
    tl.cues.map((c) => [c.name, c.at]),
    [['late', 99n]],
  );
});

test("'TPTL': a wrong magic or version is a throw, not a wrong timeline", () => {
  const blob = new Uint8Array(32);
  const dv = new DataView(blob.buffer);
  dv.setUint32(0, TIMELINE_MAGIC, true);
  dv.setUint32(4, 99, true);
  assert.throws(() => decodeTimeline(blob), /corrupt|version/i);
  dv.setUint32(0, 0xdeadbeef, true);
  dv.setUint32(4, 1, true);
  assert.throws(() => decodeTimeline(blob), /corrupt|magic/i);
  assert.throws(() => decodeTimeline(new Uint8Array(8)), /short|corrupt/i);
});

test("'TPPH': a position, its cue pair, its section tail and a tracker row", async () => {
  const text = readFileSync(fromRepo('corpus/tempo-three-conductors-it/doc.sjon'), 'utf8');
  const bytes = readFileSync(fromRepo('corpus/tempo-three-conductors-it/song.it'));
  const t = await Tempura.load(wasmBytes, text);
  assert.equal(t.attachAnchor(bytes).ok, true);

  const at = decodePlayhead(zone(t, 'tpr_playheadPtr', t.exports.tpr_atTick(0n)));
  assert.equal(at.refused, null);
  assert.equal(at.tick, 0n);
  assert.equal(at.bar, 0n);
  assert.equal(at.beat, 0n);
  assert.equal(at.subTicks, 0n);
  assert.equal(at.secondsIntoBar, 0);
  assert.ok(at.orderRow, 'an IT conductor reports a tracker position');
  assert.deepEqual(at.orderRow, { order: 0, row: 0, tickInRow: 0n });
});

test("'TPPH': a refusal carries the guard and no position at all", async () => {
  // `:end loop` wraps in seconds with `@mod`, which keeps a NaN a NaN;
  // `:end hold` CLAMPS with `@min`, which swallows one — so the refusal
  // is a property of the looping document, and the corpus pins it on
  // this same fixture.
  const t = await Tempura.load(
    wasmBytes,
    readFileSync(fromRepo('corpus/loop-wrap-seconds/doc.sjon'), 'utf8'),
  );
  const at = decodePlayhead(zone(t, 'tpr_playheadPtr', t.exports.tpr_at(Number.NaN)));
  assert.equal(at.refused, 'non-finite-time');
  assert.equal(at.tick, 0n);
  assert.deepEqual(at.sectionIds, []);
  assert.equal(at.prevCue, null);
  assert.equal(at.nextCue, null);
  assert.equal(at.orderRow, null);
});

test("'TPDG': the stage, the severity, the code ordinal, the span, the message", async () => {
  // A document whose anchor this instance cannot read: one error from
  // the DOCUMENT stage, naming the file, with a span into the text.
  const text = readFileSync(fromRepo('corpus/tempo-three-conductors-smf/doc.sjon'), 'utf8');
  const t = await Tempura.load(wasmBytes, text);
  const diags = decodeDiagnostics(zone(t, 'tpr_diagPtr', t.exports.tpr_diagLen()));
  assert.ok(diags.length > 0);
  const d = diags[0];
  assert.equal(d.stage, 'document');
  assert.equal(d.severity, 'error');
  assert.equal(typeof d.code, 'number');
  assert.ok(d.end > d.start, 'the span is a real range');
  assert.ok(d.end <= text.length, 'the span is into the document text');
  assert.match(text.slice(d.start, d.end), /song/, 'and it points at the anchor');
  assert.match(d.message, /song\.mid/);
});

test("'TPDG': an empty zone decodes to no diagnostics", () => {
  assert.deepEqual(decodeDiagnostics(new Uint8Array(0)), []);
});
