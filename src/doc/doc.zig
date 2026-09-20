//! `src/doc/` — the document value (P102, plan 02 "The document").
//!
//! The part aggregator (plan 01, "one aggregator per part"): it
//! re-exports the part's files and forces their inline tests, so
//! `zig build test -Dtest-root=doc/doc.zig` runs this subtree alone with
//! exactly the imports the root hands every part.
//!
//! The value itself lives in `Value.zig`, not `Doc.zig`: on a
//! case-insensitive filesystem that name and this one are ONE path, and
//! `-Dtest-root=doc/doc.zig` fixes which of the two the aggregator is
//! (see `Value.zig`'s header).
//!
//! `doc/` is the one place a SJON tree and a `Doc` meet. Below it the
//! format cores never see SJON; above it `time/`, `edit/`, `export/` and
//! `residue/` consume `Doc` and never a tree (plan 01, "Layering rule").
//!
//! ```zig
//! var schema = try tempura.Schema.load(gpa);
//! defer schema.deinit();
//!
//! var loaded = try doc.fromSource(gpa, &schema, source, null);
//! defer loaded.deinit();
//! if (!loaded.diags.hasErrors()) {
//!     const text = try doc.print(gpa, &loaded.doc, &loaded.map, .{});
//!     defer gpa.free(text);
//! }
//! ```

const value = @import("Value.zig");
const resolver_file = @import("Resolver.zig");

/// Tree → value: validate a `(timeline …)` source and walk it once.
pub const fromSjon = @import("fromSjon.zig");
/// Value → the canonical `(timeline …)` text.
pub const toSjon = @import("toSjon.zig");
/// The rules plan 02 states over the finished value.
pub const checks = @import("checks.zig");

/// The `midi/` bridge: a `Sequence` ⇄ the hosted SMF vocabulary, note
/// pairing and controller steps for a bound lane.
pub const bridge_smf = @import("bridge_smf.zig");

/// The `it/` bridge: a `Module` ⇄ the hosted Impulse Tracker
/// vocabulary, and the bound-lane derivations over a `RowMap`.
pub const bridge_it = @import("bridge_it.zig");

/// The skeleton: the timeline tier a file with no residue derives.
pub const skeleton = @import("skeleton.zig");

// ---- the value ----

/// The timeline as a value.
pub const Doc = value.Doc;
pub const AnchorId = value.AnchorId;
pub const AnchorKind = value.AnchorKind;
pub const Anchor = value.Anchor;
pub const TempoPoint = value.TempoPoint;
pub const MeterPoint = value.MeterPoint;
pub const Spelling = value.Spelling;
pub const spellingOf = value.spellingOf;
pub const Section = value.Section;
pub const Cue = value.Cue;
pub const LaneKind = value.LaneKind;
pub const Lane = value.Lane;
pub const Binding = value.Binding;
pub const Address = value.Address;
pub const SmfCurve = value.SmfCurve;
pub const ItColumn = value.ItColumn;
pub const Note = value.Note;
pub const Keyframe = value.Keyframe;
pub const Clip = value.Clip;
pub const Phrase = value.Phrase;
pub const Passthrough = value.Passthrough;
pub const SmfTier = value.SmfTier;
pub const ItTier = value.ItTier;

// ---- where an anchor's bytes come from ----

/// One function, `read(path) ?[]const u8`, and the two stores that
/// implement it.
pub const Resolver = resolver_file.Resolver;
pub const Memory = resolver_file.Memory;
pub const Fs = resolver_file.Fs;
pub const memory = resolver_file.memory;
pub const fs = resolver_file.fs;
pub const verify = resolver_file.verify;

// ---- tree → value ----

/// What `fromSource` returns: the document, its own `TimeMap`, and the
/// report.
pub const Result = fromSjon.Result;
/// Validate one `(timeline …)` source and lower it to a `Doc`.
pub const fromSource = fromSjon.fromSource;

// ---- value → text ----

/// The canonical printer's switches.
pub const PrintOptions = toSjon.Options;
/// Print a `Doc` as the canonical `(timeline …)` text.
pub const print = toSjon.print;

/// This part's error set: only resource exhaustion. Every defect of a
/// document is a diagnostic on a returned value.
pub const Error = error{OutOfMemory};

test {
    _ = value;
    _ = resolver_file;
    _ = checks;
    _ = fromSjon;
    _ = toSjon;
    _ = bridge_smf;
    _ = bridge_it;
    _ = skeleton;
}
