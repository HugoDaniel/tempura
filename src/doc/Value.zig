//! `Doc` — the timeline as a value.
//!
//! One `(timeline …)` document, lowered (plan 01, "Layering rule"):
//! everything above `doc/` — `time/`, `edit/`, `export/`, `residue/` —
//! consumes this and never a tree or a byte. Positions are RESOLVED
//! `i64` ticks on the grid of plan 03; the authored spellings that a
//! tick cannot recover are kept beside them (`length_lit`, a tempo
//! point's `:us` / `:qpm`, a keyframe's `:ease` source text) so a print
//! is faithful rather than merely equivalent.
//!
//! Memory: one arena owns every slice and every string, so a `Doc` is
//! self-contained and `deinit()` frees the lot (pacer's convention, plan
//! 01). Nothing here borrows the document source.
//!
//! The two file tiers (`midi`, `it`) are the inline dumps of plan 02's
//! anchor pairing. They are EMPTY in this task: an anchor with a dump
//! after it is marked `inline_dump`, and reading that dump into a
//! `Sequence` / `Module` is the anchored half's work.
//!
//! **Why this file is not `Doc.zig`.** The brief names it so, and the
//! part aggregator `doc/doc.zig` — the path `zig build
//! -Dtest-root=doc/doc.zig` names — differs from it only in case. On the
//! case-insensitive filesystem this repo lives on, the two are ONE path
//! and the aggregator's `@import("Doc.zig")` resolves to the aggregator
//! itself ("value of declaration depends on itself"). The invocation is
//! fixed, so the value file moved: `Value.zig`, holding `pub const Doc`
//! exactly as `smf/Sequence.zig` holds `pub const Sequence`.

const std = @import("std");

const Diag = @import("../Diag.zig");
const Pos = @import("../time/Pos.zig");
const TimeMap = @import("../time/TimeMap.zig");
const Sequence = @import("../smf/Sequence.zig");
const Module = @import("../itf/Module.zig");

const testing = std.testing;

/// Building a value can only fail the way any allocation fails. Every
/// defect a DOCUMENT can carry is a `Diag` on a returned result.
pub const Error = error{OutOfMemory};

/// An `(anchor :id …)`, and what a `:conductor` or a bound lane's
/// `:from` names. Arena-owned text, like every name here.
pub const AnchorId = []const u8;

/// Which file format an anchor points at.
pub const AnchorKind = enum { smf, it };

/// A file this document is arranged around (plan 02, "(anchor …)").
///
/// `size` and `sha256` are OPTIONAL in the manifest and so optional
/// here — and absent is not the same as unchecked: an anchor whose
/// bytes are ever honoured without both of them is `anchor_mismatch`,
/// never a silent re-read.
///
/// `sha256_src` is the authored spelling and `sha256` its 32 bytes when
/// the spelling really is 64 hex digits. Two fields for one key because
/// the digest is what `Resolver.verify` compares and the spelling is
/// what the printer writes back: a document may carry an elision
/// (`"9f2a…"`, the plan's own example) that has no bytes at all.
pub const Anchor = struct {
    id: AnchorId,
    kind: AnchorKind,
    file: []const u8,
    size: ?u64,
    sha256: ?[32]u8,
    sha256_src: ?[]const u8,
    /// A `(midi/smf …)` or `(it/module …)` root follows this anchor in
    /// document order — the positional pairing of plan 02.
    inline_dump: bool,
    /// Whether the anchor's bytes were read and verified. False for
    /// every by-reference anchor in this task: a resolver that cannot
    /// read one says `anchor_unavailable` and the anchor stays here,
    /// recorded and unresolved.
    resolved: bool,
    span: Diag.Span,
};

/// One tempo point, as authored.
///
/// The brief asks for a `spelling: enum { us, qpm }` beside the point.
/// `TimeMap.TempoPoint.tempo` is already a tagged union over exactly
/// those two, and its tag IS the authored spelling (`:us 400000` lands
/// on `.us`, `:qpm 125` on `.qpm`), so a second copy could only ever
/// disagree with the first. The alias records that the spelling is
/// carried; `spellingOf` is the question by name.
pub const TempoPoint = TimeMap.TempoPoint;

/// Which of `:us` / `:qpm` a tempo point was written with.
pub const Spelling = enum { us, qpm };

/// The authored spelling of a tempo point.
pub fn spellingOf(p: TempoPoint) Spelling {
    return switch (p.tempo) {
        .us => .us,
        .qpm => .qpm,
    };
}

/// One meter point, as authored.
pub const MeterPoint = TimeMap.MeterPoint;

/// A named window, exported as a pacer `(scene …)` of the same name.
pub const Section = struct {
    name: []const u8,
    at: i64,
    dur: i64,
    span: Diag.Span,
};

/// A named point in time — never a window.
pub const Cue = struct {
    name: []const u8,
    at: i64,
    span: Diag.Span,
};

/// What a lane carries, and the discriminant that gates its keys.
pub const LaneKind = enum { notes, curve, query, formula };

/// Which surface of a bound SMF channel a curve lane reads.
pub const SmfCurve = union(enum) {
    cc: u7,
    cc14: [2]u7,
    bend,
    pressure,
    velocity,
};

/// Which column of a bound Impulse Tracker channel a curve lane reads.
pub const ItColumn = enum { vol, pan, fx };

/// A bound lane's address. The key set depends on the anchor's KIND,
/// which is why the mismatch is a host check (`address_invalid`) and not
/// a shape the manifest could carry: the schema sees the lane and the
/// anchor one at a time.
///
/// Channels are stored on the WIRE: `:ch 1` is `ch == 0` and
/// `:channel 1` is `channel == 0`, so `u4` and `u6` are exactly the
/// domains. The printer adds the one back.
pub const Address = union(enum) {
    smf: struct {
        /// 1-based file order, as written.
        track: u16,
        ch: u4,
        /// One key — a drum lane. Null takes every key on the address.
        key: ?u7,
        curve: ?SmfCurve,
    },
    it: struct {
        channel: u6,
        column: ?ItColumn,
        /// The effect letter, as its ASCII byte. Only with `:column fx`.
        fx: ?u8,
    },
};

/// A lane whose content lives in an anchor's file rather than here.
pub const Binding = struct {
    anchor: AnchorId,
    address: Address,
};

/// A note event.
pub const Note = struct {
    at: i64,
    dur: i64,
    key: u7,
    vel: u7,
    /// MIDI channel for rendering, on the wire (`:ch 1` is 0).
    ch: u4,
    off_vel: ?u7,
    span: Diag.Span,
};

/// A value reached exactly at `at`, with the easing that shaped the
/// segment ENDING here (pacer's semantics, plan 02).
pub const Keyframe = struct {
    at: i64,
    value: [4]f32,
    ncomp: u3,
    /// The `:ease` value's source text, VERBATIM — `in-cubic`, or a
    /// whole `(spring :damping 0.5)` form. Typed by pacer's own
    /// `pacer/ease-spec`, so tempura never re-spells that vocabulary;
    /// it carries it.
    ease_src: []const u8,
    span: Diag.Span,
};

/// A phrase placed on a lane.
pub const Clip = struct {
    at: i64,
    phrase: []const u8,
    repeat: u32,
    offset: i64,
    /// The playback window from `offset`. Null is the default: the
    /// phrase's length times `repeat` minus `offset`.
    length: ?i64,
    transpose: i8,
    span: Diag.Span,
};

/// One stream of content driving one pacer target.
pub const Lane = struct {
    name: []const u8,
    kind: LaneKind,
    /// The pacer name this lane drives at export. Defaults to `name`,
    /// which the bridge resolves — this is never empty.
    target: []const u8,
    /// `:range`, a `curve` lane's key only (the controller's ruling).
    range: ?[2]f32,
    binding: ?Binding,
    notes: []Note,
    keyframes: []Keyframe,
    clips: []Clip,
    /// The `:query` value's source text, verbatim — a SJON
    /// `PatternQuery`, kept whole for the layer that compiles it.
    query_src: ?[]const u8,
    /// The `:expr` value's source text, verbatim — a pacer expression.
    expr_src: ?[]const u8,
    span: Diag.Span,
};

/// A reusable fragment: lanes with content, placed by a `(clip …)`.
pub const Phrase = struct {
    name: []const u8,
    length: i64,
    lanes: []Lane,
    span: Diag.Span,
};

/// A pacer root kept whole. tempura never derives from one and never
/// edits one: `text` is the form's own source slice and the printer
/// writes it back byte for byte, after tempura's own emissions.
pub const Passthrough = struct {
    /// The form's head, so a consumer can ask what it is without
    /// re-parsing (`transport`, `scene`, `control`, …).
    head: []const u8,
    /// The form's source text, verbatim — interior comments included.
    text: []const u8,
    /// The comment lines SJON attached ahead of this root, in order,
    /// each with its `;` and its text exactly as written. Printed back
    /// above the form, one per line, which is where a re-read finds
    /// them again — so the printer is idempotent from its first pass.
    comments: []const []const u8,
    span: Diag.Span,
};

/// An inline `(midi/smf …)` dump and the anchor it pairs with. EMPTY in
/// this task — the type exists so the anchored half fills it.
pub const SmfTier = struct {
    anchor: AnchorId,
    sequence: Sequence.Sequence,
};

/// An inline `(it/module …)` dump and the anchor it pairs with. EMPTY in
/// this task, as `SmfTier` is.
pub const ItTier = struct {
    anchor: AnchorId,
    module: Module.Module,
};

/// The document.
pub const Doc = struct {
    title: ?[]const u8 = null,
    /// The resolved `:length` tick, or null for the default rule (the
    /// end of the last event or clip, rounded up to a bar). The map the
    /// bridge returns always carries a concrete length; this field says
    /// whether the DOCUMENT did.
    length: ?i64 = null,
    /// `:length` as written, so a print is faithful.
    length_lit: ?Pos.Literal = null,
    end: TimeMap.End = .hold,
    conductor: ?AnchorId = null,
    anchors: []Anchor = &.{},
    tempo: []TempoPoint = &.{},
    meter: []MeterPoint = &.{},
    sections: []Section = &.{},
    cues: []Cue = &.{},
    lanes: []Lane = &.{},
    phrases: []Phrase = &.{},
    passthrough: []Passthrough = &.{},
    midi: []SmfTier = &.{},
    it: []ItTier = &.{},

    arena: std.heap.ArenaAllocator,

    /// An empty document over a fresh arena — what the bridge returns
    /// when a source holds no timeline at all.
    pub fn empty(gpa: std.mem.Allocator) Doc {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Doc) void {
        for (self.midi) |*t| t.sequence.deinit();
        for (self.it) |*t| t.module.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// The anchor named `id`, or null.
    pub fn anchorById(self: *const Doc, id: AnchorId) ?*const Anchor {
        for (self.anchors) |*a| {
            if (std.mem.eql(u8, a.id, id)) return a;
        }
        return null;
    }

    /// The phrase named `name`, or null.
    pub fn phraseByName(self: *const Doc, name: []const u8) ?*const Phrase {
        for (self.phrases) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Field-for-field equality, SPANS AND `length_lit` EXCLUDED.
    ///
    /// The round-trip property of plan 02 phase 3 compares a document
    /// against the one its own printing reads back, and those are two
    /// different texts: a span names a byte range in the source it was
    /// read from, so comparing spans would compare the two texts'
    /// layouts rather than the two documents.
    ///
    /// `length_lit` is excluded for the same reason from the other end.
    /// It is the spelling the AUTHOR used, and the canonical printer is
    /// supposed to normalise a spelling — `:length 512q` prints `128bar`
    /// under `[4 4]`, which is the printer's rule doing its job (plan 03:
    /// "A hand-written document may use any unit anywhere; only the
    /// printer is constrained"). The tick it resolved to is what the two
    /// documents have to agree on, and `length` carries that.
    /// `length_lit` rides along for the edit engine and for a host that
    /// wants to show what was typed; nothing downstream compares it.
    pub fn eql(a: *const Doc, b: *const Doc) bool {
        if (!optStrEql(a.title, b.title)) return false;
        if (!optEql(i64, a.length, b.length)) return false;
        if (a.end != b.end) return false;
        if (!optStrEql(a.conductor, b.conductor)) return false;

        if (a.anchors.len != b.anchors.len) return false;
        for (a.anchors, b.anchors) |x, y| {
            if (!std.mem.eql(u8, x.id, y.id)) return false;
            if (x.kind != y.kind) return false;
            if (!std.mem.eql(u8, x.file, y.file)) return false;
            if (!optEql(u64, x.size, y.size)) return false;
            if (!optStrEql(x.sha256_src, y.sha256_src)) return false;
            if ((x.sha256 == null) != (y.sha256 == null)) return false;
            if (x.sha256) |d| if (!std.mem.eql(u8, &d, &y.sha256.?)) return false;
            if (x.inline_dump != y.inline_dump) return false;
            if (x.resolved != y.resolved) return false;
        }

        if (a.tempo.len != b.tempo.len) return false;
        for (a.tempo, b.tempo) |x, y| {
            if (x.tick != y.tick) return false;
            if (spellingOf(x) != spellingOf(y)) return false;
            switch (x.tempo) {
                .us => |u| if (u != y.tempo.us) return false,
                .qpm => |q| if (q != y.tempo.qpm) return false,
            }
        }

        if (a.meter.len != b.meter.len) return false;
        for (a.meter, b.meter) |x, y| {
            if (x.tick != y.tick or x.n != y.n or x.d != y.d) return false;
        }

        if (a.sections.len != b.sections.len) return false;
        for (a.sections, b.sections) |x, y| {
            if (!std.mem.eql(u8, x.name, y.name)) return false;
            if (x.at != y.at or x.dur != y.dur) return false;
        }

        if (a.cues.len != b.cues.len) return false;
        for (a.cues, b.cues) |x, y| {
            if (!std.mem.eql(u8, x.name, y.name) or x.at != y.at) return false;
        }

        if (!lanesEql(a.lanes, b.lanes)) return false;

        if (a.phrases.len != b.phrases.len) return false;
        for (a.phrases, b.phrases) |x, y| {
            if (!std.mem.eql(u8, x.name, y.name)) return false;
            if (x.length != y.length) return false;
            if (!lanesEql(x.lanes, y.lanes)) return false;
        }

        if (a.passthrough.len != b.passthrough.len) return false;
        for (a.passthrough, b.passthrough) |x, y| {
            if (!std.mem.eql(u8, x.head, y.head)) return false;
            if (!std.mem.eql(u8, x.text, y.text)) return false;
            if (x.comments.len != y.comments.len) return false;
            for (x.comments, y.comments) |cx, cy| {
                if (!std.mem.eql(u8, cx, cy)) return false;
            }
        }

        // The two tiers are empty in this task; length equality is the
        // whole of their contract until the anchored half fills them.
        if (a.midi.len != b.midi.len or a.it.len != b.it.len) return false;
        return true;
    }
};

fn lanesEql(a: []const Lane, b: []const Lane) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (x.kind != y.kind) return false;
        if (!std.mem.eql(u8, x.target, y.target)) return false;
        if ((x.range == null) != (y.range == null)) return false;
        if (x.range) |r| if (r[0] != y.range.?[0] or r[1] != y.range.?[1]) return false;
        if ((x.binding == null) != (y.binding == null)) return false;
        if (x.binding) |bx| {
            const by = y.binding.?;
            if (!std.mem.eql(u8, bx.anchor, by.anchor)) return false;
            if (std.meta.activeTag(bx.address) != std.meta.activeTag(by.address)) return false;
            switch (bx.address) {
                .smf => |s| {
                    const o = by.address.smf;
                    if (s.track != o.track or s.ch != o.ch) return false;
                    if (!optEql(u7, s.key, o.key)) return false;
                    if ((s.curve == null) != (o.curve == null)) return false;
                    if (s.curve) |c| if (!std.meta.eql(c, o.curve.?)) return false;
                },
                .it => |s| {
                    const o = by.address.it;
                    if (s.channel != o.channel) return false;
                    if (!optEql(ItColumn, s.column, o.column)) return false;
                    if (!optEql(u8, s.fx, o.fx)) return false;
                },
            }
        }
        if (x.notes.len != y.notes.len) return false;
        for (x.notes, y.notes) |nx, ny| {
            if (nx.at != ny.at or nx.dur != ny.dur) return false;
            if (nx.key != ny.key or nx.vel != ny.vel or nx.ch != ny.ch) return false;
            if (!optEql(u7, nx.off_vel, ny.off_vel)) return false;
        }
        if (x.keyframes.len != y.keyframes.len) return false;
        for (x.keyframes, y.keyframes) |kx, ky| {
            if (kx.at != ky.at or kx.ncomp != ky.ncomp) return false;
            if (!std.mem.eql(f32, &kx.value, &ky.value)) return false;
            if (!std.mem.eql(u8, kx.ease_src, ky.ease_src)) return false;
        }
        if (x.clips.len != y.clips.len) return false;
        for (x.clips, y.clips) |cx, cy| {
            if (cx.at != cy.at or cx.offset != cy.offset) return false;
            if (!std.mem.eql(u8, cx.phrase, cy.phrase)) return false;
            if (cx.repeat != cy.repeat or cx.transpose != cy.transpose) return false;
            if (!optEql(i64, cx.length, cy.length)) return false;
        }
        if (!optStrEql(x.query_src, y.query_src)) return false;
        if (!optStrEql(x.expr_src, y.expr_src)) return false;
    }
    return true;
}

fn optEql(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

test "Doc: an empty document owns an arena and frees it" {
    var d: Doc = .empty(testing.allocator);
    defer d.deinit();

    try testing.expect(d.title == null);
    try testing.expect(d.length == null);
    try testing.expectEqual(TimeMap.End.hold, d.end);
    try testing.expectEqual(@as(usize, 0), d.lanes.len);
    try testing.expect(d.eql(&d));
}

test "Doc.spellingOf: the union's tag IS the authored spelling" {
    try testing.expectEqual(Spelling.us, spellingOf(.{ .tick = 0, .tempo = .{ .us = 400_000 } }));
    try testing.expectEqual(Spelling.qpm, spellingOf(.{ .tick = 0, .tempo = .{ .qpm = 125 } }));
}

test "Doc.eql: ignores spans and notices every other field" {
    const gpa = testing.allocator;
    var a: Doc = .empty(gpa);
    defer a.deinit();
    var b: Doc = .empty(gpa);
    defer b.deinit();

    var one = [_]Section{.{ .name = "intro", .at = 0, .dur = 8, .span = .{ .start = 0, .end = 4 } }};
    var two = [_]Section{.{ .name = "intro", .at = 0, .dur = 8, .span = .{ .start = 99, .end = 120 } }};
    a.sections = &one;
    b.sections = &two;
    try testing.expect(a.eql(&b));

    two[0].dur = 9;
    try testing.expect(!a.eql(&b));
    two[0].dur = 8;
    two[0].name = "drop";
    try testing.expect(!a.eql(&b));

    a.sections = &.{};
    b.sections = &.{};
    a.title = "impulsos";
    try testing.expect(!a.eql(&b));
    b.title = "impulsos";
    try testing.expect(a.eql(&b));

    // `length_lit` is informational: the printer normalises a spelling,
    // so two documents that resolved to the same tick are the same
    // document however their `:length` was typed.
    a.length = 4096;
    b.length = 4096;
    a.length_lit = .{ .value = 128, .unit = .bar };
    b.length_lit = .{ .value = 512, .unit = .q };
    try testing.expect(a.eql(&b));
    // The TICK is what they have to agree on.
    b.length = 4097;
    try testing.expect(!a.eql(&b));
}

test "Doc.anchorById / phraseByName: the two joins the bridge and the printer need" {
    const gpa = testing.allocator;
    var d: Doc = .empty(gpa);
    defer d.deinit();

    var anchors = [_]Anchor{.{
        .id = "song",
        .kind = .it,
        .file = "impulse-04.it",
        .size = null,
        .sha256 = null,
        .sha256_src = null,
        .inline_dump = false,
        .resolved = false,
        .span = .{ .start = 0, .end = 1 },
    }};
    var phrases = [_]Phrase{.{ .name = "fill", .length = 4, .lanes = &.{}, .span = .{ .start = 0, .end = 1 } }};
    d.anchors = &anchors;
    d.phrases = &phrases;

    try testing.expectEqual(AnchorKind.it, d.anchorById("song").?.kind);
    try testing.expect(d.anchorById("other") == null);
    try testing.expectEqual(@as(i64, 4), d.phraseByName("fill").?.length);
    try testing.expect(d.phraseByName("other") == null);
}
