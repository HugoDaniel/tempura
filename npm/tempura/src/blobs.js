// The four packed blobs `tempura.wasm` writes, decoded with one
// `DataView` pass each. Mirror of `src/TprAbi.zig`, which is the format's
// definition and its native test; read that header for the layouts.
//
//   'TPTL' (out) — the derivation: tempo segments, meters, the bar
//                  table's shape, sections, cues, the lane index
//   'TPPH' (out) — one playhead record, or the guard that refused it
//   'TPMP' (out): the position map of the score, one record per
//                  emitted position with its document spans
//   'TPDG' (out) — diagnostics, pacer's 'PACD' layout with tempura's
//                  `Diag.Code` ordinals and three severities
//
// Ticks are BigInt: the grid is `i64` on TPQ = 46 126 080 per quarter
// note, and a bar of a long piece leaves the double's exact range.
//
// Every decoder takes bytes (a `Uint8Array` — copy it out of wasm memory
// if you mean to keep it, since the buffer detaches when memory grows)
// and returns plain objects. A blob whose magic or version this glue
// does not know is a throw, never a wrong answer; a TLV section it does
// not know is skipped by its length, which is what makes the stream
// forwards compatible.

/** `"TPTL"` read little-endian. */
export const TIMELINE_MAGIC = 0x4c545054;
export const TIMELINE_VERSION = 1;
/** `"TPPH"` read little-endian. */
export const PLAYHEAD_MAGIC = 0x48505054;
export const PLAYHEAD_VERSION = 1;
/** `"TPMP"` read little-endian. */
export const MAP_MAGIC = 0x504d5054;
export const MAP_VERSION = 1;
/** `"TPDG"` read little-endian. */
export const DIAGS_MAGIC = 0x47445054;
export const DIAGS_VERSION = 1;

const TIMELINE_HEADER_LEN = 32;
const SECTION_HEADER_LEN = 8;
const SEGMENTS_ID = 0x47455354; // 'TSEG'
const SEGMENT_REC_LEN = 32;
const METERS_ID = 0x54454d54; // 'TMET'
const METER_REC_LEN = 32;
const BARS_ID = 0x52414254; // 'TBAR'
const SECTIONS_ID = 0x43455354; // 'TSEC'
const CUES_ID = 0x45554354; // 'TCUE'
const LANES_ID = 0x4e414c54; // 'TLAN'
const LANE_REC_LEN = 32;

const PLAYHEAD_LEN = 80;

const MAP_HEADER_LEN = 12;
const MAP_RECORD_LEN = 12;
const MAP_SPAN_LEN = 8;

const DIAGS_HEADER_LEN = 12;
const DIAG_RECORD_LEN = 16;

/** Mirror of `TimeMap.End` (array index = wire ordinal). */
const END_BEHAVIOURS = /** @type {const} */ (['loop', 'hold']);
/** Mirror of `Doc.LaneKind`. */
const LANE_KINDS = /** @type {const} */ (['notes', 'curve', 'query', 'formula']);
/** Mirror of `TprAbi.Refusal`; index 0 means "not refused". */
const REFUSALS = /** @type {const} */ ([null, 'tick-overflow', 'non-finite-time']);
/** Mirror of `TprAbi.Stage`. */
const STAGES = /** @type {const} */ (['document', 'derivation', 'operation']);
/** Mirror of `Diag.Severity`. */
const SEVERITIES = /** @type {const} */ (['error', 'warning', 'info']);

const decoder = new TextDecoder();

/** @typedef {import('./types.js').Timeline} Timeline */
/** @typedef {import('./types.js').Playhead} Playhead */
/** @typedef {import('./types.js').Diagnostic} Diagnostic */
/** @typedef {import('./types.js').PositionMap} PositionMap */

/**
 * Check a blob's frame: long enough, the right magic, a version this
 * glue knows. Returns a `DataView` over it.
 *
 * @param {Uint8Array} bytes
 * @param {number} magic
 * @param {number} version
 * @param {number} minLen
 * @param {string} what
 * @returns {DataView}
 */
function frame(bytes, magic, version, minLen, what) {
  if (bytes.length < minLen) {
    throw new Error(`tempura: ${what} blob is ${bytes.length} bytes, too short to be one`);
  }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (dv.getUint32(0, true) !== magic) throw new Error(`tempura: corrupt ${what} blob (magic)`);
  const got = dv.getUint32(4, true);
  if (got !== version) {
    throw new Error(`tempura: ${what} blob is version ${got}, this glue reads ${version}`);
  }
  return dv;
}

/**
 * Decode a `'TPTL'` blob — what `tpr_timeline()` wrote.
 *
 * The bar TABLE is not on the wire: `bars` carries how many there are
 * and where the last one starts, and the rest is recomputed from the
 * meter map (each segment names its first bar and its own bar length).
 * See `src/TprAbi.zig`'s header for why.
 *
 * @param {Uint8Array} bytes
 * @returns {Timeline}
 */
export function decodeTimeline(bytes) {
  const dv = frame(bytes, TIMELINE_MAGIC, TIMELINE_VERSION, TIMELINE_HEADER_LEN, 'timeline');

  /** @type {Timeline} */
  const out = {
    length: dv.getBigInt64(8, true),
    loopSeconds: dv.getFloat64(16, true),
    end: END_BEHAVIOURS[dv.getUint8(24)] ?? 'hold',
    integral: dv.getUint8(25) !== 0,
    segments: [],
    meters: [],
    bars: { count: 0, lastStart: 0n },
    sections: [],
    cues: [],
    lanes: [],
  };

  // The section stream: TLV frames walked to the buffer's end. Dispatch
  // the known ids and skip the rest by length, so a blob from a newer
  // module decodes minus what it added.
  let off = TIMELINE_HEADER_LEN;
  while (off + SECTION_HEADER_LEN <= bytes.length) {
    const id = dv.getUint32(off, true);
    const plen = dv.getUint32(off + 4, true);
    const body = off + SECTION_HEADER_LEN;
    if (id === SEGMENTS_ID) {
      const count = dv.getUint32(body, true);
      for (let i = 0, p = body + 4; i < count; i++, p += SEGMENT_REC_LEN) {
        out.segments.push({
          tick: dv.getBigInt64(p, true),
          us: dv.getFloat64(p + 8, true),
          ticksPerSecond: dv.getFloat64(p + 16, true),
          startSeconds: dv.getFloat64(p + 24, true),
        });
      }
    } else if (id === METERS_ID) {
      const count = dv.getUint32(body, true);
      for (let i = 0, p = body + 4; i < count; i++, p += METER_REC_LEN) {
        out.meters.push({
          tick: dv.getBigInt64(p, true),
          firstBar: dv.getBigInt64(p + 8, true),
          beatsBefore: dv.getBigInt64(p + 16, true),
          n: dv.getUint8(p + 24),
          d: dv.getUint8(p + 25),
        });
      }
    } else if (id === BARS_ID) {
      out.bars = { count: dv.getUint32(body, true), lastStart: dv.getBigInt64(body + 8, true) };
    } else if (id === SECTIONS_ID) {
      const count = dv.getUint32(body, true);
      let p = body + 4;
      for (let i = 0; i < count; i++) {
        const nameLen = dv.getUint16(p + 16, true);
        out.sections.push({
          name: decoder.decode(bytes.subarray(p + 20, p + 20 + nameLen)),
          at: dv.getBigInt64(p, true),
          dur: dv.getBigInt64(p + 8, true),
        });
        p += 20 + nameLen;
      }
    } else if (id === CUES_ID) {
      const count = dv.getUint32(body, true);
      let p = body + 4;
      for (let i = 0; i < count; i++) {
        const nameLen = dv.getUint16(p + 8, true);
        out.cues.push({
          name: decoder.decode(bytes.subarray(p + 12, p + 12 + nameLen)),
          at: dv.getBigInt64(p, true),
        });
        p += 12 + nameLen;
      }
    } else if (id === LANES_ID) {
      const count = dv.getUint32(body, true);
      let p = body + 4;
      for (let i = 0; i < count; i++) {
        const nameLen = dv.getUint16(p + 2, true);
        out.lanes.push({
          name: decoder.decode(bytes.subarray(p + LANE_REC_LEN, p + LANE_REC_LEN + nameLen)),
          kind: LANE_KINDS[dv.getUint8(p)] ?? 'notes',
          bound: dv.getUint8(p + 1) !== 0,
          onsets: dv.getUint32(p + 4, true),
          steps: dv.getUint32(p + 8, true),
          firstTick: dv.getBigInt64(p + 12, true),
          lastTick: dv.getBigInt64(p + 20, true),
        });
        p += LANE_REC_LEN + nameLen;
      }
    }
    off = body + plen;
  }
  return out;
}

/**
 * Decode a `'TPPH'` record — what `tpr_at()` / `tpr_atTick()` wrote.
 *
 * `refused` is non-null exactly when the clock was one no map can
 * answer for (a NaN, an infinity, a value past the tick ceiling); every
 * other field is then zero or null.
 *
 * @param {Uint8Array} bytes
 * @returns {Playhead}
 */
export function decodePlayhead(bytes) {
  const dv = frame(bytes, PLAYHEAD_MAGIC, PLAYHEAD_VERSION, PLAYHEAD_LEN, 'playhead');
  const flags = dv.getUint8(48);
  const sectionCount = dv.getUint16(50, true);
  /** @type {number[]} */
  const sectionIds = [];
  for (let i = 0; i < sectionCount; i++) {
    sectionIds.push(dv.getUint32(PLAYHEAD_LEN + i * 4, true));
  }
  return {
    refused: REFUSALS[dv.getUint8(49)] ?? null,
    tick: dv.getBigInt64(8, true),
    bar: dv.getBigInt64(16, true),
    beat: dv.getBigInt64(24, true),
    subTicks: dv.getBigInt64(32, true),
    secondsIntoBar: dv.getFloat64(40, true),
    sectionIds,
    prevCue: flags & 1 ? dv.getUint32(52, true) : null,
    nextCue: flags & 2 ? dv.getUint32(56, true) : null,
    orderRow:
      flags & 4
        ? {
            order: dv.getUint32(60, true),
            row: dv.getUint32(64, true),
            tickInRow: dv.getBigInt64(72, true),
          }
        : null,
  };
}

/**
 * Decode a `'TPMP'` blob, what `tpr_exportScoreMap()` wrote.
 *
 * One entry per emitted position, in emission order. `text` is a
 * `[start, end]` byte span into the score text `tpr_exportScore()` handed
 * back under the same flags; `doc` is an array of `[start, end]` byte
 * spans into the document text (`Tempura.text`), one per document node
 * the position came from, several when the exporter's arithmetic merged
 * sources. Turn a doc span into an edit-engine address with SJON's
 * `sjon_address_of_span` over that text.
 *
 * @param {Uint8Array} bytes
 * @returns {PositionMap}
 */
export function decodeMap(bytes) {
  const dv = frame(bytes, MAP_MAGIC, MAP_VERSION, MAP_HEADER_LEN, 'map');
  const count = dv.getUint32(8, true);
  /** @type {Array<{text: [number, number], doc: Array<[number, number]>}>} */
  const entries = [];
  let off = MAP_HEADER_LEN;
  for (let i = 0; i < count; i++) {
    const text = /** @type {[number, number]} */ ([
      dv.getUint32(off, true),
      dv.getUint32(off + 4, true),
    ]);
    const docCount = dv.getUint32(off + 8, true);
    off += MAP_RECORD_LEN;
    /** @type {Array<[number, number]>} */
    const doc = [];
    for (let j = 0; j < docCount; j++) {
      doc.push([dv.getUint32(off, true), dv.getUint32(off + 4, true)]);
      off += MAP_SPAN_LEN;
    }
    entries.push({ text, doc });
  }
  return { entries };
}

/**
 * Decode a `'TPDG'` blob — what every verb that can complain wrote.
 *
 * An EMPTY buffer means nothing has been written to the zone yet (an
 * instance with nothing loaded), not that a blob is malformed: it
 * decodes to no diagnostics. Spans are byte offsets into whatever the
 * producer read — the document's text for a load, the file's bytes for a
 * dump — and the message says which.
 *
 * @param {Uint8Array} bytes
 * @returns {Diagnostic[]}
 */
export function decodeDiagnostics(bytes) {
  if (bytes.length === 0) return [];
  const dv = frame(bytes, DIAGS_MAGIC, DIAGS_VERSION, DIAGS_HEADER_LEN, 'diagnostics');
  const count = dv.getUint32(8, true);
  /** @type {Diagnostic[]} */
  const out = [];
  let off = DIAGS_HEADER_LEN;
  for (let i = 0; i < count; i++) {
    const msgLen = dv.getUint32(off + 12, true);
    out.push({
      stage: STAGES[dv.getUint8(off)] ?? 'document',
      severity: SEVERITIES[dv.getUint8(off + 1)] ?? 'error',
      code: dv.getUint16(off + 2, true),
      start: dv.getUint32(off + 4, true),
      end: dv.getUint32(off + 8, true),
      message: decoder.decode(
        bytes.subarray(off + DIAG_RECORD_LEN, off + DIAG_RECORD_LEN + msgLen),
      ),
    });
    off += DIAG_RECORD_LEN + msgLen;
  }
  return out;
}
