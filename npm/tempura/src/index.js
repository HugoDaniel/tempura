// tempura — JS glue around tempura.wasm.
//
// The module is a pure function of its linear memory: write a document's
// text or a file's bytes into a zone, call a `tpr_*` verb, read text or a
// packed blob back. This file owns the zones and the lifecycle; the wire
// formats live in `./blobs` (mirroring `src/TprAbi.zig`) and the
// operation grammar in `./ops` (mirroring `src/edit/edit.zig`).
//
// Memory views are re-taken from `exports.memory.buffer` on every call —
// the buffer detaches when wasm memory grows, so a cached view is a
// crash waiting for a big file. Anything handed back to the caller
// (`build`'s bytes) is copied out of wasm memory for the same reason.
//
// Statuses, from the entry's header: 0 ok, 1 diagnostics, 2 bad call
// (nothing changed), 3 out of memory. Status 1 still leaves the document
// LOADED — tempura's producers are total, so a defective document is
// still a value an editor can show, and it is what lets a host attach an
// anchor's bytes to a document that just told it they were missing.

import { decodeDiagnostics, decodePlayhead, decodeTimeline } from './blobs.js';

// sjon.wasm's executable-plugin dispatch import. tempura documents never
// declare `:impl "wasm:…"` plugins, so this is never called for a valid
// document; returning null (0) maps to a clean diagnostic on the Zig side
// rather than a trap.
const IMPORTS = { env: { sjon_host_invoke_plugin: () => 0 } };

const ABI_VERSION = 1;

/** Mirror of `Playhead.SnapGrid` (array index = the wire ordinal). */
const SNAP_GRIDS = /** @type {const} */ (['q4', 'q8', 'q12', 'q16', 'q32', 'bar', 'beat']);
/** Mirror of `Doc.AnchorKind`, spelled the way a file is (`build --kind`). */
const KINDS = /** @type {const} */ (['mid', 'it']);

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** @typedef {import('./types.js').TempuraExports} TempuraExports */
/** @typedef {import('./types.js').Diagnostic} Diagnostic */
/** @typedef {import('./types.js').LoadResult} LoadResult */
/** @typedef {import('./types.js').PlanResult} PlanResult */
/** @typedef {import('./types.js').Timeline} Timeline */
/** @typedef {import('./types.js').Playhead} Playhead */
/** @typedef {import('./types.js').Kind} Kind */
/** @typedef {import('./types.js').SnapGrid} SnapGrid */
/** @typedef {import('./types.js').ScoreOptions} ScoreOptions */

export class Tempura {
  /** @type {TempuraExports} The pinned tpr_* ABI surface. */
  #exports;
  /** @type {Timeline | null} Decoded 'TPTL', cached until the next load. */
  #timeline = null;
  /** @type {string | null} The document's own text, cached until the next load. */
  #text = null;

  /** Whether a document is loaded and nothing is wrong with it. @type {boolean} */
  ok = false;
  /**
   * The report of the last call that produced one — a load, a plan, an
   * export, a build. Decoded from 'TPDG'.
   * @type {ReadonlyArray<Diagnostic>}
   */
  diagnostics = [];

  /**
   * Instantiate tempura.wasm and load a document or a file.
   *
   * @param {BufferSource | WebAssembly.Module} wasmSource
   * @param {string | Uint8Array} source A `(timeline …)` document as text,
   *   or a `.mid` / `.it` file's bytes (then `kind` is required).
   * @param {{ kind?: Kind, anchor?: Uint8Array }} [opts]
   *   `anchor` attaches the loaded document's own file straight away —
   *   the browser's substitute for a filesystem.
   * @returns {Promise<Tempura>} check `.ok` / `.diagnostics`.
   */
  static async load(wasmSource, source, { kind, anchor } = {}) {
    const self = await Tempura.instantiate(wasmSource);
    if (typeof source === 'string') self.reload(source);
    else self.loadFile(source, kind ?? kindOfBytes(source));
    if (anchor) self.attachAnchor(anchor);
    return self;
  }

  /**
   * Instantiate tempura.wasm with nothing loaded. Every query then
   * answers empty (null, or `[]`) rather than throwing — the module is
   * total, and so is this.
   *
   * @param {BufferSource | WebAssembly.Module} wasmSource
   * @returns {Promise<Tempura>}
   */
  static async instantiate(wasmSource) {
    const instance =
      wasmSource instanceof WebAssembly.Module
        ? await WebAssembly.instantiate(wasmSource, IMPORTS)
        : (await WebAssembly.instantiate(wasmSource, IMPORTS)).instance;
    return new Tempura(instance);
  }

  /** @param {WebAssembly.Instance} instance */
  constructor(instance) {
    // The wasm exports are untyped at the boundary; cast once to the
    // pinned `tpr_*` ABI so every call site type-checks against it.
    this.#exports = /** @type {TempuraExports} */ (/** @type {unknown} */ (instance.exports));
    const got = this.#exports.tpr_abiVersion();
    if (got !== ABI_VERSION) throw new Error(`tempura: unsupported ABI version ${got}`);
  }

  /** The raw `tpr_*` surface, for hosts that want the zones themselves. */
  get exports() {
    return this.#exports;
  }

  /** The ABI generation this module implements. */
  get abiVersion() {
    return this.#exports.tpr_abiVersion();
  }

  /**
   * Every zone's ceiling, in bytes. A host that would write past one
   * checks here rather than being refused.
   * @returns {{ doc: number, file: number, op: number, out: number }}
   */
  get caps() {
    const e = this.#exports;
    return { doc: e.tpr_docCap(), file: e.tpr_fileCap(), op: e.tpr_opCap(), out: e.tpr_outCap() };
  }

  /**
   * (Re)load a document from its text. Safe at any time; the previous
   * document, its derivation and any pending plan go.
   *
   * @param {string} text
   * @returns {LoadResult}
   */
  reload(text) {
    const e = this.#exports;
    const bytes = encoder.encode(text);
    if (bytes.length > e.tpr_docCap()) {
      throw new Error(`tempura: the document exceeds tpr_docCap (${e.tpr_docCap()} bytes)`);
    }
    new Uint8Array(e.memory.buffer).set(bytes, e.tpr_docPtr());
    return this.#settle(e.tpr_load(bytes.length));
  }

  /**
   * Load a `.mid` or `.it` file: the dump happens inside the wasm, and
   * `text` reads the document back. The bytes stay attached as the
   * anchor, so an `it/` dump's `(bin …)` regions resolve.
   *
   * @param {Uint8Array} bytes
   * @param {Kind} kind
   * @returns {LoadResult}
   */
  loadFile(bytes, kind) {
    const e = this.#exports;
    if (bytes.length > e.tpr_fileCap()) {
      throw new Error(`tempura: the file exceeds tpr_fileCap (${e.tpr_fileCap()} bytes)`);
    }
    new Uint8Array(e.memory.buffer).set(bytes, e.tpr_filePtr());
    return this.#settle(e.tpr_loadFile(kindOrdinal(kind), bytes.length));
  }

  /**
   * Hand the loaded document the bytes of the file its `(anchor …)`
   * names. They are checked against the anchor's `:size` and `:sha256`
   * and the document is reloaded with them in hand — its TEXT does not
   * change, but every `(bin :at :len)` offset it carries now names
   * something.
   *
   * Bytes that match no anchor answer `{ ok: false, status: 1 }` with an
   * `anchor_mismatch` diagnostic, and the document is left as it was.
   *
   * @param {Uint8Array} bytes
   * @returns {LoadResult}
   */
  attachAnchor(bytes) {
    const e = this.#exports;
    if (bytes.length > e.tpr_fileCap()) {
      throw new Error(`tempura: the anchor exceeds tpr_fileCap (${e.tpr_fileCap()} bytes)`);
    }
    new Uint8Array(e.memory.buffer).set(bytes, e.tpr_filePtr());
    return this.#settle(e.tpr_attachAnchor(bytes.length));
  }

  /**
   * The document as it stands: the text that was loaded, the text a dump
   * assembled, or the text an edit produced with its layout preserved —
   * never a re-print of the value (plan 07's contract, and plan 04's
   * essence, both turn on the author's own bytes coming back).
   *
   * Null when nothing is loaded.
   * @returns {string | null}
   */
  get text() {
    if (this.#text !== null) return this.#text;
    const e = this.#exports;
    const len = e.tpr_text();
    if (len === 0) return null;
    this.#text = decoder.decode(new Uint8Array(e.memory.buffer, e.tpr_textPtr(), len));
    return this.#text;
  }

  /**
   * The derivation ('TPTL'), decoded lazily and cached until the next
   * load: tempo segments, meters, the bar table's shape, sections, cues
   * and the lane index. Null when nothing is loaded.
   * @returns {Timeline | null}
   */
  timeline() {
    if (this.#timeline) return this.#timeline;
    const e = this.#exports;
    const len = e.tpr_timeline();
    if (len === 0) return null;
    this.#timeline = decodeTimeline(
      new Uint8Array(e.memory.buffer, e.tpr_timelinePtr(), len).slice(),
    );
    return this.#timeline;
  }

  /**
   * Where `seconds` lands, after the end behaviour (`loop` wraps in
   * seconds, `hold` clamps — both BEFORE the conversion). A clock no map
   * can answer for comes back with `refused` set rather than as a
   * position nobody asked for. Null when nothing is loaded.
   *
   * @param {number} seconds
   * @returns {Playhead | null}
   */
  at(seconds) {
    return this.#playhead(this.#exports.tpr_at(seconds));
  }

  /**
   * The same answer, asked by TICK — the query an editor makes when the
   * playhead was dragged on the grid rather than on the clock. Never a
   * refusal: a tick is already on the grid.
   *
   * @param {bigint | number} tick
   * @returns {Playhead | null}
   */
  atTick(tick) {
    return this.#playhead(this.#exports.tpr_atTick(BigInt(tick)));
  }

  /**
   * The nearest grid line to `tick` under the meter in force, with an
   * optional swing (0 = none, 0.5 = a triplet feel on the off-beats).
   * With nothing loaded the tick comes back unchanged — a snap is a
   * nudge, and refusing to move is the one answer that cannot be wrong.
   *
   * @param {bigint | number} tick
   * @param {SnapGrid} grid
   * @param {number} [swing]
   * @returns {bigint}
   */
  snap(tick, grid, swing = 0) {
    const ordinal = SNAP_GRIDS.indexOf(grid);
    if (ordinal < 0) throw new Error(`tempura: ${grid} is not a snap grid`);
    return this.#exports.tpr_snap(BigInt(tick), ordinal, swing);
  }

  /**
   * Plan one operation (`./ops` builds them) without touching the
   * document: the actions come back as `Plan.text()` spells them, and a
   * plan that was not refused is HELD so `apply()` commits exactly what
   * was shown.
   *
   * A REFUSED plan is `actions: '[]\n'` — the empty action list, with the
   * reason in `diagnostics` — and nothing is held, so the `apply()` that
   * follows is a bad call rather than a silent no-op. `actions: ''` means
   * only that there was nothing to answer with: nothing loaded, the ask
   * was not an operation, or the actions did not fit the out zone.
   *
   * Never a throw: an operation is user input like any other.
   *
   * @param {object | string} op
   * @returns {PlanResult}
   */
  plan(op) {
    const len = this.#writeOp(op);
    const out = this.#exports.tpr_plan(len);
    this.diagnostics = this.#readDiags();
    return { actions: out === 0 ? '' : this.#outText(out), diagnostics: this.diagnostics };
  }

  /**
   * Commit an edit and reload the document; `text` reads it back.
   *
   * Three payloads, and the module tells them apart by their first token:
   *
   * - no argument — commit the plan `plan()` last produced. The only
   *   spelling that cannot have drifted: the actions are the ones the
   *   host is looking at.
   * - an ACTION LIST, as `plan()` handed it back (a JSON array, or the
   *   string `plan()` returned) — plan 10's own spelling, and what an
   *   editor needs when the author struck a line out of the plan. Read
   *   against the CURRENT document, so a host that edited the text
   *   underneath a plan gets whatever those addresses now name.
   * - an OPERATION (a JSON object, `./ops` builds them) — planned and
   *   applied in one call, the CLI's `edit --op`.
   *
   * A plan the engine refused never reaches the document: `status` is 1,
   * `diagnostics` says why, and `text` is unchanged.
   *
   * @param {object | ReadonlyArray<object> | string} [op]
   * @returns {LoadResult}
   */
  apply(op) {
    const len = op === undefined ? 0 : this.#writeOp(op);
    return this.#settle(this.#exports.tpr_apply(len));
  }

  /**
   * The document as a pacer score. Null when nothing is loaded or the
   * score was refused — `diagnostics` says which. The one refusal is the
   * CLI's: a conducted document whose file is not here would say the
   * placeholder's `:bpm 120` under a header naming the conductor, so
   * nothing comes back until `attachAnchor()` hands over the bytes.
   * @param {ScoreOptions} [opts]
   * @returns {string | null}
   */
  exportScore(opts = {}) {
    const flags =
      (opts.velocity ? 1 : 0) |
      (opts.easeLinear ? 2 : 0) |
      (opts.noHints ? 4 : 0) |
      (opts.sectionMarkers ? 8 : 0);
    const len = this.#exports.tpr_exportScore(flags);
    this.diagnostics = this.#readDiags();
    return len === 0 ? null : this.#outText(len);
  }

  /**
   * The document as a `.mid` or `.it`, residue attached. The bytes are
   * COPIED out of wasm memory, so they survive the next call. Null when
   * nothing is loaded or the build was refused — `diagnostics` says
   * which (a cross-kind ask is `build_cross_kind`).
   *
   * @param {Kind} kind
   * @returns {Uint8Array | null}
   */
  build(kind) {
    const e = this.#exports;
    const len = e.tpr_build(kindOrdinal(kind));
    this.diagnostics = this.#readDiags();
    return len === 0 ? null : new Uint8Array(e.memory.buffer, e.tpr_outPtr(), len).slice();
  }

  /**
   * Settle after a lifecycle call: the caches go, the report is read,
   * and a status this glue does not know is a throw (it would mean the
   * module and the glue disagree about the ABI).
   * @param {number} status
   * @returns {LoadResult}
   */
  #settle(status) {
    this.#timeline = null;
    this.#text = null;
    this.diagnostics = this.#readDiags();
    this.ok = status === 0;
    if (status > 3) throw new Error(`tempura: unknown status ${status} (glue/module mismatch)`);
    if (status === 3) throw new Error('tempura: out of memory');
    return {
      ok: this.ok,
      status: /** @type {0 | 1 | 2 | 3} */ (status),
      diagnostics: this.diagnostics,
    };
  }

  /**
   * @param {number} len
   * @returns {Playhead | null}
   */
  #playhead(len) {
    if (len === 0) return null;
    const e = this.#exports;
    return decodePlayhead(new Uint8Array(e.memory.buffer, e.tpr_playheadPtr(), len).slice());
  }

  /**
   * Write an operation or an action list into the op zone. A value is
   * serialized; a string is taken as already-serialized JSON, which is
   * what makes `apply(plan(op).actions)` a pass-through rather than a
   * re-render.
   * @param {object | ReadonlyArray<object> | string} op
   * @returns {number}
   */
  #writeOp(op) {
    const e = this.#exports;
    const bytes = encoder.encode(typeof op === 'string' ? op : JSON.stringify(op));
    // Over the cap is a BAD CALL and the module says so; writing the
    // bytes first would scribble past the zone, so the length alone goes
    // in and the module refuses it.
    if (bytes.length > e.tpr_opCap()) return bytes.length;
    new Uint8Array(e.memory.buffer).set(bytes, e.tpr_opPtr());
    return bytes.length;
  }

  /**
   * @param {number} len
   * @returns {string}
   */
  #outText(len) {
    const e = this.#exports;
    return decoder.decode(new Uint8Array(e.memory.buffer, e.tpr_outPtr(), len));
  }

  /** @returns {Diagnostic[]} */
  #readDiags() {
    const e = this.#exports;
    const len = e.tpr_diagLen();
    if (len === 0) return [];
    return decodeDiagnostics(new Uint8Array(e.memory.buffer, e.tpr_diagPtr(), len).slice());
  }
}

/**
 * The wire ordinal of a build kind.
 * @param {Kind} kind
 * @returns {number}
 */
function kindOrdinal(kind) {
  const ordinal = KINDS.indexOf(kind);
  if (ordinal < 0) throw new Error(`tempura: ${kind} is not a kind (mid | it)`);
  return ordinal;
}

/**
 * Which core reads these bytes, from their own magic — `MThd` for a
 * Standard MIDI File, `IMPM` for an Impulse Tracker module. A host that
 * knows the file's name passes `kind` instead.
 * @param {Uint8Array} bytes
 * @returns {Kind}
 */
function kindOfBytes(bytes) {
  const magic = decoder.decode(bytes.subarray(0, 4));
  if (magic === 'MThd' || magic === 'RIFF') return 'mid';
  if (magic === 'IMPM') return 'it';
  throw new Error(
    `tempura: these bytes start with "${magic}" — pass { kind } to say what they are`,
  );
}
