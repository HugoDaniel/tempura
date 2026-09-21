// Shared structural types for tempura's public API.
//
// JSDoc-only: this module emits no runtime values (`export {}` makes it a
// module so the typedefs are importable). `tsc` emits them into
// `types/types.d.ts` for published consumers.
//
// Convention (pacer's): decoded, consumer-facing values are read once per
// call and meant to be read, not mutated. Ticks are `bigint` — the grid
// is `i64` on TPQ = 46 126 080 per quarter note, and a bar of a long
// piece leaves the double's exact range.

export {};

/**
 * One derived tempo segment: where it starts, and the three numbers the
 * seconds↔ticks projection is computed from.
 * @typedef {object} TimelineSegment
 * @property {bigint} tick Where the segment begins.
 * @property {number} us Microseconds per quarter note.
 * @property {number} ticksPerSecond The projection's slope.
 * @property {number} startSeconds `seconds(tick)` at the segment's start — exact by construction.
 */

/**
 * One derived meter segment. `firstBar` and `beatsBefore` are the
 * cumulative counts at its start, so a host names a bar or a beat
 * without walking the table.
 * @typedef {object} TimelineMeter
 * @property {bigint} tick
 * @property {bigint} firstBar
 * @property {bigint} beatsBefore
 * @property {number} n Beats per bar.
 * @property {number} d The beat's note value (4 = a quarter).
 */

/**
 * The bar table's shape. The table itself is not on the wire — it is one
 * `i64` per bar up to `:length` — and is recomputed from `meters`.
 * @typedef {object} TimelineBars
 * @property {number} count
 * @property {bigint} lastStart
 */

/**
 * A named window, in ticks. Windows may overlap.
 * @typedef {object} TimelineSection
 * @property {string} name
 * @property {bigint} at
 * @property {bigint} dur
 */

/**
 * A named point, in ticks. Cues come back in DOCUMENT order, which is
 * not tick order.
 * @typedef {object} TimelineCue
 * @property {string} name
 * @property {bigint} at
 */

/**
 * One lane, indexed rather than expanded: what it is, how much it holds,
 * and where it reaches. The content itself never crosses the boundary —
 * a host that needs the notes reads the document.
 * @typedef {object} TimelineLane
 * @property {string} name
 * @property {'notes' | 'curve' | 'query' | 'formula'} kind
 * @property {boolean} bound Whether the content came from an anchor rather than the document.
 * @property {number} onsets
 * @property {number} steps
 * @property {bigint} firstTick First onset, or 0 when the lane has none.
 * @property {bigint} lastTick Last onset, or 0 when the lane has none.
 */

/**
 * The derivation, decoded from the `'TPTL'` blob.
 * @typedef {object} Timeline
 * @property {bigint} length
 * @property {number} loopSeconds
 * @property {'loop' | 'hold'} end What happens at `:length`.
 * @property {boolean} integral Whether the map took the exact integer path.
 * @property {TimelineSegment[]} segments
 * @property {TimelineMeter[]} meters
 * @property {TimelineBars} bars
 * @property {TimelineSection[]} sections
 * @property {TimelineCue[]} cues
 * @property {TimelineLane[]} lanes
 */

/**
 * The tracker position under an Impulse Tracker conductor.
 * @typedef {object} OrderRow
 * @property {number} order
 * @property {number} row
 * @property {bigint} tickInRow
 */

/**
 * Where the playhead is, decoded from the `'TPPH'` blob.
 * @typedef {object} Playhead
 * @property {'tick-overflow' | 'non-finite-time' | null} refused Non-null when
 *   the clock was one no map can answer for; every other field is then zero or null.
 * @property {bigint} tick
 * @property {bigint} bar
 * @property {bigint} beat
 * @property {bigint} subTicks Ticks past the beat.
 * @property {number} secondsIntoBar
 * @property {number[]} sectionIds Indexes into {@link Timeline.sections}, in document order.
 * @property {number | null} prevCue Index into {@link Timeline.cues}.
 * @property {number | null} nextCue
 * @property {OrderRow | null} orderRow Null unless an IT anchor conducts.
 */

/**
 * One diagnostic, decoded from the `'TPDG'` blob.
 * @typedef {object} Diagnostic
 * @property {'document' | 'derivation' | 'operation'} stage Which producer raised it.
 * @property {'error' | 'warning' | 'info'} severity
 * @property {number} code `Diag.Code`'s ordinal — append-only from E3.
 * @property {number} start Byte offset into what the producer read.
 * @property {number} end
 * @property {string} message
 */

/**
 * What a lifecycle call answers: the raw status, whether it is clean,
 * and the report.
 * @typedef {object} LoadResult
 * @property {boolean} ok Status 0 — loaded, and nothing is wrong with it.
 * @property {0 | 1 | 2 | 3} status 0 ok, 1 diagnostics, 2 bad call, 3 out of memory.
 * @property {ReadonlyArray<Diagnostic>} diagnostics
 */

/**
 * What `plan` answers: the actions as `Plan.text()` spells them (a JSON
 * array, one action per line), and why it refused when it did.
 * @typedef {object} PlanResult
 * @property {string} actions `''` when nothing was planned.
 * @property {ReadonlyArray<Diagnostic>} diagnostics
 */

/**
 * Which native format a build writes.
 * @typedef {'mid' | 'it'} Kind
 */

/**
 * The subdivisions `snap` offers: `q4` is a quarter … `q32` a
 * thirty-second, and `beat` and `bar` are the meter's own lines.
 * @typedef {'q4' | 'q8' | 'q12' | 'q16' | 'q32' | 'bar' | 'beat'} SnapGrid
 */

/**
 * `exportScore`'s switches — plan 10's four, as booleans.
 * @typedef {object} ScoreOptions
 * @property {boolean} [velocity] A sibling `<lane>-vel` track per notes lane.
 * @property {boolean} [easeLinear] Print a bound curve lane's steps as ramps, not stairs.
 * @property {boolean} [noHints] Ignore every easing hint.
 * @property {boolean} [sectionMarkers] Carried for the CLI's one options struct.
 */

/**
 * The tempura.wasm export surface (the `tpr_*` ABI). Modeled explicitly
 * so the glue type-checks against the boundary instead of reaching
 * through `any`; the `Tempura` constructor casts `instance.exports` once.
 * @typedef {object} TempuraExports
 * @property {WebAssembly.Memory} memory
 * @property {() => number} tpr_abiVersion
 * @property {() => number} tpr_docPtr
 * @property {() => number} tpr_docCap
 * @property {() => number} tpr_filePtr
 * @property {() => number} tpr_fileCap
 * @property {() => number} tpr_opPtr
 * @property {() => number} tpr_opCap
 * @property {() => number} tpr_textPtr
 * @property {() => number} tpr_outPtr
 * @property {() => number} tpr_outCap
 * @property {() => number} tpr_timelinePtr
 * @property {() => number} tpr_playheadPtr
 * @property {() => number} tpr_diagPtr
 * @property {() => number} tpr_diagLen
 * @property {(len: number) => number} tpr_load
 * @property {(kind: number, len: number) => number} tpr_loadFile
 * @property {(len: number) => number} tpr_attachAnchor
 * @property {() => number} tpr_text
 * @property {() => number} tpr_timeline
 * @property {(seconds: number) => number} tpr_at
 * @property {(tick: bigint) => number} tpr_atTick
 * @property {(tick: bigint, grid: number, swing: number) => bigint} tpr_snap
 * @property {(len: number) => number} tpr_plan
 * @property {(len: number) => number} tpr_apply
 * @property {(flags: number) => number} tpr_exportScore
 * @property {(kind: number) => number} tpr_build
 */

/**
 * A selection: which lanes, which ticks, which kinds, which keys. Every
 * field is optional and an omitted one means "every". A selection that
 * names lanes is about lane CONTENT, so it never reaches the sections
 * and cues, which are roots.
 * @typedef {object} Selection
 * @property {string[]} [lanes]
 * @property {[bigint | number, bigint | number]} [range] Half-open `[from, to)`,
 *   in ticks — a BigInt like every other tick here, or a number when the
 *   caller knows it is small. `ops.sel` narrows it for JSON.
 * @property {Array<'note' | 'keyframe' | 'clip' | 'section' | 'cue'>} [kinds]
 * @property {number[]} [keys] MIDI keys, 0..127.
 */
