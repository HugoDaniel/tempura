//! `src/edit/` — the edit engine (P105, plan 07).
//!
//! An operation is a PURE FUNCTION from a document and an ask to a list
//! of SJON edit actions, never a mutation of an in-memory model:
//!
//! ```zig
//! var loaded = try doc.fromSource(gpa, &schema, source, null);
//! defer loaded.deinit();
//! var tree = try sjon.parse(gpa, source);
//! defer tree.deinit();
//!
//! var p = try edit.plan(gpa, &loaded.doc, &tree, .{ .retime = .{
//!     .sel = .{ .lanes = &.{"flash"}, .kinds = .notes },
//!     .delta = time.Grid.TPQ,
//! } });
//! defer p.deinit();
//!
//! var applied = try edit.apply(gpa, source, &p);
//! defer applied.deinit();
//! ```
//!
//! The host applies the actions with SJON's structural editor
//! (`SJON/docs/LANGUAGE.md` §11), re-parses, and the document is what it
//! says. There is no undo stack here (the host keeps text history), no
//! dirty flag and no object identity: an address is a path plus a root,
//! and it is re-derived after every apply — SJON's own rule (§11.2, "A
//! path plus a root is an address, and an address is where a node is, not
//! which node it is").
//!
//! The files:
//!
//!   * `Op.zig` — what an editor can ask for, and `fromJson`.
//!   * `Select.zig` — which lanes, ticks, kinds and keys an ask is about.
//!   * `Plan.zig` — the actions, as text, with the diagnostics and the
//!     summary; a refusal is an empty action list and a diagnostic with
//!     the span of the form it refused on.
//!   * `apply.zig` — the actions sequenced so every address is valid when
//!     it is reached, spliced with layout `.preserve`.
//!   * `ops_native.zig` — every row of plan 07's table that acts on
//!     content the document holds itself.
//!   * `ops_bound.zig` — the front door, and the rows that act on
//!     content an anchor's inline dump holds: the `(note-on, note-off)`
//!     pairs and controller events of a `(midi/mtrk …)`, the `(ev …)`
//!     cells of an `(it/pattern …)`, and `materialize`.
//!   * `Snap.zig` / `ops_quantize.zig` — where the grid lines are, and
//!     the two operations that move a selection onto them.
//!   * `locate.zig` / `value.zig` — the two joins: a `Doc` node's span to
//!     a SJON address, and a value to the JSON an action carries.
//!
//! ## `Op.fromJson` — the CLI's `--op '<json>'` spelling
//!
//! One JSON object, `"op"` naming the operation and the rest its
//! payload. **Every position is a TICK** (plan 03's grid, `TPQ =
//! 46 126 080` per quarter note): the spelling a tick reaches the
//! document in is the printer's rule, not the caller's choice.
//!
//! A `"sel"` is `{"lanes": [name…], "range": [from, to), "kinds":
//! [note|keyframe|clip|section|cue…], "keys": [0..127…]}`, and every
//! field of it is optional — an omitted one is "every". A selection that
//! names lanes is about lane CONTENT, so it never reaches the sections
//! and cues, which are roots.
//!
//! ```json
//! {"op":"insert","lane":"flash","note":{"at":0,"dur":23063040,"key":36,"vel":110}}
//! {"op":"insert","section":{"name":"outro","at":737617280,"dur":737617280}}
//! {"op":"remove","sel":{"lanes":["flash"],"range":[0,184504320]}}
//! {"op":"retime","sel":{"kinds":["note"]},"delta":46126080}
//! {"op":"retime","sel":{"kinds":["cue"]},"to":184504320}
//! {"op":"revalue","sel":{"kinds":["keyframe"]},"value":[0.1,0.2,0.3]}
//! {"op":"ease","sel":{"kinds":["keyframe"]},"ease":"(spring :damping 0.5)"}
//! {"op":"resize","sel":{"kinds":["note"]},"dur":46126080}
//! {"op":"resize","sel":{"kinds":["clip"]},"repeat":3}
//! {"op":"velocity","sel":{"keys":[36]},"vel":64}
//! {"op":"split","sel":{"kinds":["clip"]},"at":276756480}
//! {"op":"merge","sel":{"kinds":["clip"]}}
//! {"op":"duplicate","sel":{"lanes":["flash"]},"delta":184504320}
//! {"op":"quantize","sel":{},"grid":"1/8","strength":0.5,"swing":0.25,"dur-too":false}
//! {"op":"nudge","sel":{},"grid":"1/16","count":1}
//! {"op":"nudge","sel":{},"ticks":-120}
//! {"op":"transpose","sel":{"kinds":["note"]},"semitones":12}
//! {"op":"stretch","from":0,"to":184504320,"p":3,"q":2}
//! {"op":"insert-tempo","at":184504320,"qpm":140,"mode":"wall-clock"}
//! {"op":"insert-tempo","at":0,"us":500000}
//! {"op":"insert-meter","at":184504320,"sig":[3,4]}
//! {"op":"rename","what":"phrase","from":"fill","to":"roll"}
//! {"op":"bind","lane":"pad","anchor":"song","track":1,"ch":2,"key":36}
//! {"op":"bind","lane":"bass","anchor":"song","channel":5,"column":"vol"}
//! {"op":"unbind","lane":"kick"}
//! {"op":"materialize","lane":"kick"}
//! {"op":"retime","sel":{"lanes":["lead"]},"delta":46126080,"allow-shared":true}
//! ```
//!
//! `"allow-shared"` rides on `retime`, `remove` and `velocity`, and says
//! the ask means EVERY occurrence of a bound Impulse Tracker cell whose
//! pattern more than one order plays. Without it such an edit is
//! `edit_pattern_shared` — a pattern is stored once and played many
//! times, so a volume, a removal and a move inside it all change every
//! place it sounds (plan 07, "Bound content, precisely").
//!
//! `"grid"` is `1/4`, `1/8`, `1/12`, `1/16`, `1/32`, `1bar` or `1b`.
//! `"what"` on a rename is `lane`, `section`, `phrase`, `target` or
//! `anchor`. An `insert` carries exactly one of `note`, `keyframe`,
//! `clip`, `section`, `cue`, `lane`, `phrase`; the first three go into
//! the `"lane"` named beside them and the rest are roots. Channels are
//! written as a musician counts them (`"ch":1` is the first), the way the
//! document spells them.
//!
//! Anything that is not an operation comes back as a diagnostic on the
//! returned value, never as an error: `--op` is user input like any
//! other.

const op_file = @import("Op.zig");
const plan_file = @import("Plan.zig");
const apply_file = @import("apply.zig");
const select_file = @import("Select.zig");
const snap_file = @import("Snap.zig");
const locate = @import("locate.zig");
const value = @import("value.zig");

// ---- the ask ----

/// Every operation of plan 07's table that acts on native content.
pub const Op = op_file.Op;
/// Read one operation from the CLI's `--op '<json>'` spelling. See the
/// header.
pub const fromJson = op_file.fromJson;
/// What `fromJson` answers: the operation, or the reasons it is not one.
pub const Parsed = op_file.Parsed;
/// By ticks, or by counted steps of a grid.
pub const Delta = op_file.Delta;

/// Which lanes, which ticks, which kinds, which keys.
pub const Select = select_file.Select;
pub const Kind = select_file.Kind;
pub const Kinds = select_file.Kinds;
pub const Target = select_file.Target;
/// Resolve a selection against a document.
pub const resolve = select_file.resolve;

// ---- the answer ----

/// The plan: SJON edit actions as text, the diagnostics, and the counts.
pub const Plan = plan_file.Plan;
/// One SJON edit action (§11.1).
pub const Action = plan_file.Action;
/// Which of SJON's eight structural operations an action is.
pub const ActionKind = plan_file.Kind;
/// What a plan does, in counts.
pub const Summary = plan_file.Summary;

/// Every native operation's planner.
pub const ops_native = @import("ops_native.zig");
/// Every bound operation's planner.
pub const ops_bound = @import("ops_bound.zig");
/// Plan an operation over a document. Pure, total, deterministic.
pub const plan = ops_bound.plan;
/// `plan` for a caller that already holds the document's map — the one
/// `doc.fromSource` returned. The map is the DOCUMENT LAYER's
/// (`doc.fromSjon.mapOf`), and handing it in saves deriving it twice.
pub const planWith = ops_bound.planWith;
/// Read an action list back into a `Plan` — `Plan.text()`'s inverse, and
/// what a host hands `tpr_apply` when it has looked at a plan and struck
/// a line out (plan 10's row: "actions as JSON → the document
/// re-loaded"). Total: an array that is not one is a refusal with a
/// diagnostic, never an error.
pub const fromActionsJson = plan_file.fromActionsJson;
/// Apply a plan to a document's bytes, layout preserved.
pub const apply = apply_file.apply;
/// What `apply` returns.
pub const Applied = apply_file.Applied;
/// Inline an anchor: its file's tier as `insert_root` actions straight
/// after its `(anchor …)` — what `tempura inline` plans, callable by any
/// host holding the bytes (`inline_anchor.zig`, the one file here that
/// reads a file's bytes, and says why).
pub const inline_anchor = @import("inline_anchor.zig");
/// `inline_anchor.inlineAnchor`: the anchor's bytes in, an `Inlined` out.
pub const inlineAnchor = inline_anchor.inlineAnchor;

// ---- the grid ----

/// Where the grid lines are, under the meter map.
pub const Snap = snap_file;
/// A subdivision, a bar or a beat.
pub const Grid = snap_file.Grid;
/// Quantize's and nudge's own arithmetic.
pub const ops_quantize = @import("ops_quantize.zig");

/// A node's address: the root its path starts at, and the steps down.
pub const Site = locate.Site;

/// This part's error set: only resource exhaustion. Every defect of a
/// document or of an operation is a diagnostic on a returned value.
pub const Error = error{OutOfMemory};

test {
    _ = op_file;
    _ = plan_file;
    _ = apply_file;
    _ = select_file;
    _ = snap_file;
    _ = locate;
    _ = value;
    _ = ops_native;
    _ = ops_bound;
    _ = ops_quantize;
    _ = inline_anchor;
}
