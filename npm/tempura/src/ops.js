// Typed builders for the operation JSON `tpr_plan` / `tpr_apply` take.
//
// One object per operation, `"op"` naming it and the rest its payload —
// the grammar is `src/edit/edit.zig`'s header, and these functions are
// its JS spelling. They BUILD, they never validate: an ask that is not an
// operation comes back from the module as a diagnostic with a span, the
// same way the CLI's `--op` does, and a second opinion here would be a
// second grammar to keep in step.
//
// **Every position is a TICK** (TPQ = 46 126 080 per quarter note). The
// spelling a tick reaches the document in — `1bar`, `3q`, a raw number —
// is the printer's rule, not the caller's choice. Ticks may be numbers
// or BigInts; `JSON.stringify` has no spelling for a BigInt, so they are
// narrowed here and a tick past `Number.MAX_SAFE_INTEGER` throws rather
// than rounding silently.
//
// Channels are written as a musician counts them (`ch: 1` is the first),
// the way the document spells them.

/** @typedef {import('./types.js').Selection} Selection */

/**
 * A tick as JSON carries it. BigInt in, number out — the grid's ceiling
 * is 2^53, so every tick a document can hold is exact as a double, and
 * one past it is a mistake worth hearing about.
 * @param {bigint | number} tick
 * @returns {number}
 */
function tickOf(tick) {
  if (typeof tick === 'number') {
    if (!Number.isSafeInteger(tick)) throw new Error(`tempura: ${tick} is not a whole tick`);
    return tick;
  }
  if (tick > BigInt(Number.MAX_SAFE_INTEGER) || tick < -BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`tempura: the tick ${tick} is past the grid's 2^53 ceiling`);
  }
  return Number(tick);
}

/**
 * A selection, with every field optional — an omitted one is "every".
 * A selection that names lanes is about lane CONTENT, so it never
 * reaches the sections and cues, which are roots.
 *
 * @param {Selection} [sel]
 * @returns {object}
 */
export function sel({ lanes, range, kinds, keys } = {}) {
  // Built by spreading rather than by assigning into a
  // `Record<string, unknown>`: an omitted field must be ABSENT (the
  // grammar reads "every" from a missing key, not from an undefined
  // one), and a spread says that without a mutable bag in between.
  return {
    ...(lanes ? { lanes } : {}),
    ...(range ? { range: [tickOf(range[0]), tickOf(range[1])] } : {}),
    ...(kinds ? { kinds } : {}),
    ...(keys ? { keys } : {}),
  };
}

/**
 * Insert a note into `lane`.
 * @param {string} lane
 * @param {{ at: bigint | number, dur: bigint | number, key: number, vel: number }} note
 */
export const insertNote = (lane, note) => ({
  op: 'insert',
  lane,
  note: { ...note, at: tickOf(note.at), dur: tickOf(note.dur) },
});

/**
 * Insert a keyframe into `lane`. `value` is one to four components.
 * @param {string} lane
 * @param {{ at: bigint | number, value: number | number[], ease?: string }} keyframe
 */
export const insertKeyframe = (lane, keyframe) => ({
  op: 'insert',
  lane,
  keyframe: { ...keyframe, at: tickOf(keyframe.at) },
});

/**
 * Insert a clip into `lane` — a phrase placed on the timeline.
 * @param {string} lane
 * @param {{ at: bigint | number, phrase: string, repeat?: number }} clip
 */
export const insertClip = (lane, clip) => ({
  op: 'insert',
  lane,
  clip: { ...clip, at: tickOf(clip.at) },
});

/**
 * Insert a section — a named window, a root and not lane content.
 * @param {{ name: string, at: bigint | number, dur: bigint | number }} section
 */
export const insertSection = (section) => ({
  op: 'insert',
  section: { ...section, at: tickOf(section.at), dur: tickOf(section.dur) },
});

/**
 * Insert a cue — a named point.
 * @param {{ name: string, at: bigint | number }} cue
 */
export const insertCue = (cue) => ({ op: 'insert', cue: { ...cue, at: tickOf(cue.at) } });

/**
 * Insert an empty lane.
 * @param {{ name: string, kind: 'notes' | 'curve' | 'query' | 'formula', target?: string }} lane
 */
export const insertLane = (lane) => ({ op: 'insert', lane });

/**
 * Insert an empty phrase — a named bundle a clip plays.
 * @param {{ name: string }} phrase
 */
export const insertPhrase = (phrase) => ({ op: 'insert', phrase });

/**
 * Remove everything a selection resolves to.
 * @param {{ sel: object, allowShared?: boolean }} ask
 */
export const remove = ({ sel: selection, allowShared }) =>
  shared({ op: 'remove', sel: selection }, allowShared);

/**
 * Move a selection: `delta` ticks, or to the absolute tick `to`.
 * @param {{ sel: object, delta?: bigint | number, to?: bigint | number, allowShared?: boolean }} ask
 */
export const retime = ({ sel: selection, delta, to, allowShared }) =>
  shared(
    {
      op: 'retime',
      sel: selection,
      ...(delta === undefined ? {} : { delta: tickOf(delta) }),
      ...(to === undefined ? {} : { to: tickOf(to) }),
    },
    allowShared,
  );

/**
 * Give every selected keyframe a new value.
 * @param {{ sel: object, value: number | number[] }} ask
 */
export const revalue = ({ sel: selection, value }) => ({ op: 'revalue', sel: selection, value });

/**
 * Give every selected keyframe a new easing, as the document spells it
 * (`"linear"`, `"(spring :damping 0.5)"`).
 * @param {{ sel: object, ease: string }} ask
 */
export const ease = ({ sel: selection, ease: spec }) => ({
  op: 'ease',
  sel: selection,
  ease: spec,
});

/**
 * Resize a selection: notes take a `dur`, clips a `repeat`.
 * @param {{ sel: object, dur?: bigint | number, repeat?: number }} ask
 */
export const resize = ({ sel: selection, dur, repeat }) => ({
  op: 'resize',
  sel: selection,
  ...(dur === undefined ? {} : { dur: tickOf(dur) }),
  ...(repeat === undefined ? {} : { repeat }),
});

/**
 * Set every selected note's velocity.
 * @param {{ sel: object, vel: number, allowShared?: boolean }} ask
 */
export const velocity = ({ sel: selection, vel, allowShared }) =>
  shared({ op: 'velocity', sel: selection, vel }, allowShared);

/**
 * Split every selected clip at `at`.
 * @param {{ sel: object, at: bigint | number }} ask
 */
export const split = ({ sel: selection, at }) => ({ op: 'split', sel: selection, at: tickOf(at) });

/**
 * Merge the selected clips back into one.
 * @param {{ sel: object }} ask
 */
export const merge = ({ sel: selection }) => ({ op: 'merge', sel: selection });

/**
 * Copy a selection `delta` ticks later.
 * @param {{ sel: object, delta: bigint | number }} ask
 */
export const duplicate = ({ sel: selection, delta }) => ({
  op: 'duplicate',
  sel: selection,
  delta: tickOf(delta),
});

/**
 * Move a selection onto a grid. `grid` is `1/4`, `1/8`, `1/12`, `1/16`,
 * `1/32`, `1bar` or `1b`; `strength` is how far towards the line (1 is
 * all the way), `swing` the off-beat push, `durToo` whether durations
 * quantize with the onsets.
 * @param {{ sel: object, grid: string, strength?: number, swing?: number, durToo?: boolean }} ask
 */
export const quantize = ({ sel: selection, grid, strength, swing, durToo }) => ({
  op: 'quantize',
  sel: selection,
  grid,
  ...(strength === undefined ? {} : { strength }),
  ...(swing === undefined ? {} : { swing }),
  ...(durToo === undefined ? {} : { 'dur-too': durToo }),
});

/**
 * Nudge a selection: `count` steps of `grid`, or a raw number of ticks.
 * @param {{ sel: object, grid?: string, count?: number, ticks?: bigint | number }} ask
 */
export const nudge = ({ sel: selection, grid, count, ticks }) => ({
  op: 'nudge',
  sel: selection,
  ...(grid === undefined ? {} : { grid }),
  ...(count === undefined ? {} : { count }),
  ...(ticks === undefined ? {} : { ticks: tickOf(ticks) }),
});

/**
 * Transpose every selected note.
 * @param {{ sel: object, semitones: number }} ask
 */
export const transpose = ({ sel: selection, semitones }) => ({
  op: 'transpose',
  sel: selection,
  semitones,
});

/**
 * Stretch the window `[from, to)` by the exact ratio `p / q`.
 * @param {{ from: bigint | number, to: bigint | number, p: number, q: number }} ask
 */
export const stretch = ({ from, to, p, q }) => ({
  op: 'stretch',
  from: tickOf(from),
  to: tickOf(to),
  p,
  q,
});

/**
 * Insert a tempo point: microseconds per quarter, or quarters per
 * minute. `mode` is `"wall-clock"` to keep the seconds of what follows.
 * @param {{ at: bigint | number, us?: number, qpm?: number, mode?: 'wall-clock' }} ask
 */
export const insertTempo = ({ at, us, qpm, mode }) => ({
  op: 'insert-tempo',
  at: tickOf(at),
  ...(us === undefined ? {} : { us }),
  ...(qpm === undefined ? {} : { qpm }),
  ...(mode === undefined ? {} : { mode }),
});

/**
 * Insert a meter point.
 * @param {{ at: bigint | number, sig: [number, number] }} ask
 */
export const insertMeter = ({ at, sig }) => ({ op: 'insert-meter', at: tickOf(at), sig });

/**
 * Rename something, and every reference to it.
 * @param {{ what: 'lane' | 'section' | 'phrase' | 'target' | 'anchor', from: string, to: string }} ask
 */
export const rename = ({ what, from, to }) => ({ op: 'rename', what, from, to });

/**
 * Bind a lane to an anchor's content: an SMF track/channel (with an
 * optional `key`, `cc`, or `bend`), or an IT channel and column.
 * @param {{ lane: string, anchor: string, track?: number, ch?: number, key?: number,
 *   cc?: number, bend?: boolean, channel?: number, column?: 'vol' | 'pan' | 'fx' }} ask
 */
export const bind = (ask) => ({ op: 'bind', ...ask });

/**
 * Cut a lane loose from its anchor, leaving it empty.
 * @param {string} lane
 */
export const unbind = (lane) => ({ op: 'unbind', lane });

/**
 * Copy a bound lane's content into the document, so the lane owns it.
 * @param {string} lane
 */
export const materialize = (lane) => ({ op: 'materialize', lane });

/**
 * `"allow-shared"` says the ask means EVERY occurrence of a bound
 * Impulse Tracker cell whose pattern more than one order plays. Without
 * it such an edit is `edit_pattern_shared`: a pattern is stored once and
 * played many times, so a volume, a removal and a move inside it all
 * change every place it sounds.
 * @param {object} op
 * @param {boolean | undefined} allowShared
 * @returns {object}
 */
function shared(op, allowShared) {
  return allowShared ? { ...op, 'allow-shared': true } : op;
}
