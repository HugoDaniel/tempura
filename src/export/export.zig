//! `src/export/` — the one door from tempura to pacer (P106, plan 08).
//!
//! The part aggregator (plan 01, "one aggregator per part"): it
//! re-exports the part's files and forces their inline tests, so
//! `zig build test -Dtest-root=export/export.zig` runs this subtree
//! alone with exactly the imports the root hands every part.

/// pacer's tick grid seen from tempura's: rounding onto the lattice and
/// the floor-interval decimal that prints a position pacer reads back.
pub const pos = @import("pos.zig");

/// The key budget: equal-run collapse and Ramer-Douglas-Peucker, the two
/// stages a bound curve lane passes through before it is printed.
pub const simplify = @import("simplify.zig");

/// One lane's content as pacer sees it: aggregated trigger onsets and
/// budgeted curve keys.
pub const lanes = @import("lanes.zig");

/// `exportScore` — the one door from tempura to pacer.
pub const score = @import("score.zig");

/// The tempo a renderer writes: the map's segments, each with the
/// document point that made it.
pub const tempo = @import("tempo.zig");

/// A curve value as a controller's integer — the one quantizer both
/// renderers write through.
pub const quantize = @import("quantize.zig");

/// `renderSmf` — a native timeline as a Standard MIDI File.
pub const render_smf = @import("render_smf.zig");

/// `renderIt` — a native timeline as an Impulse Tracker module.
pub const render_it = @import("render_it.zig");

/// The three conductors as fixtures, shared with `tools/gen_landing.zig`.
pub const test_support = @import("test_support.zig");

// ---- the public surface, re-exported ----

pub const Options = score.Options;
pub const Result = score.Result;
pub const EaseHint = score.EaseHint;
pub const MapEntry = score.MapEntry;
pub const exportScore = score.exportScore;
/// The map as JSON: `{"entries":[…]}`. See `score.mapJson`.
pub const mapJson = score.mapJson;
/// The map's entries array alone, for a wrapper with facts of its own.
pub const mapEntriesJson = score.mapEntriesJson;
pub const renderSmf = render_smf.renderSmf;
pub const renderIt = render_it.renderIt;

/// This part's error set: only resource exhaustion. Every defect of a
/// document is a diagnostic on the returned result.
pub const Error = error{OutOfMemory};

test {
    _ = pos;
    _ = simplify;
    _ = lanes;
    _ = score;
    _ = tempo;
    _ = quantize;
    _ = render_smf;
    _ = render_it;
    _ = test_support;
}
