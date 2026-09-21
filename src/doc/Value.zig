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
//! anchor pairing: an anchor with a dump after it is marked
//! `inline_dump`, and the dump itself is read into a `Sequence` or a
//! `Module` beside it. They are the one thing here a `Doc` does not own
//! through its own arena — each tier's value carries an arena of its
//! own, which `deinit` releases with the rest.
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

/// A SET of MIDI channels on one track, on the WIRE: bit `c` set means
/// wire channel `c`, so `:ch 1` is bit 0 and `:ch [1 2]` is bits 0 and 1.
///
/// A bound SMF lane names one or several channels of one track. One is
/// the usual case and the only one an author writes by hand; several is
/// what a dump writes when a native lane whose notes named more than one
/// channel comes back BOUND (plan 04, rule 2): its rendering is one track
/// and one lane record PER CHANNEL, and a lane whose records are stale
/// binds at every channel those records name, or the untouched channel's
/// notes would be in the tier and in no lane (`residue/reconcile.zig`,
/// `bindLane`). A lane RECORD names exactly one channel, because a hash
/// is over a `(track, ch)` pair and the wire is frozen — so a set only
/// ever reaches the wire as its `first()`, and only in the one place
/// that is documented (`residue/records.zig`, `encodeAddress`).
///
/// Two bytes, pinned as a build break: sixteen channels is MIDI's whole
/// domain, so a mask that had to grow would mean the type had stopped
/// meaning what this header says.
pub const Channels = struct {
    mask: u16,

    comptime {
        std.debug.assert(@sizeOf(Channels) == 2);
    }

    /// No channel at all. Never a valid address — `fromSjon` refuses an
    /// empty vector — but the zero a set is built up from.
    pub const none: Channels = .{ .mask = 0 };

    /// The set holding `c` alone: what every hand-written `:ch N`, every
    /// skeleton lane and every decoded record is.
    pub fn single(c: u4) Channels {
        return .{ .mask = @as(u16, 1) << c };
    }

    pub fn has(self: Channels, c: u4) bool {
        return self.mask & (@as(u16, 1) << c) != 0;
    }

    /// `self` with `c` in it.
    pub fn with(self: Channels, c: u4) Channels {
        return .{ .mask = self.mask | (@as(u16, 1) << c) };
    }

    /// The union of the two sets.
    pub fn merge(self: Channels, other: Channels) Channels {
        return .{ .mask = self.mask | other.mask };
    }

    pub fn isEmpty(self: Channels) bool {
        return self.mask == 0;
    }

    pub fn count(self: Channels) u8 {
        return @popCount(self.mask);
    }

    /// The lowest channel in the set — THE channel of a single, and what
    /// the frozen record wire carries of a set. Channel 0 for an empty
    /// set, which no caller hands over.
    pub fn first(self: Channels) u4 {
        if (self.mask == 0) return 0;
        return @intCast(@ctz(self.mask));
    }

    pub fn eql(self: Channels, other: Channels) bool {
        return self.mask == other.mask;
    }

    /// The channels in ascending order, one per `next()`.
    pub fn iterator(self: Channels) Iterator {
        return .{ .left = self.mask };
    }

    pub const Iterator = struct {
        left: u16,

        pub fn next(self: *Iterator) ?u4 {
            if (self.left == 0) return null;
            const c: u4 = @intCast(@ctz(self.left));
            self.left &= self.left - 1;
            return c;
        }
    };
};

/// A bound lane's address. The key set depends on the anchor's KIND,
/// which is why the mismatch is a host check (`address_invalid`) and not
/// a shape the manifest could carry: the schema sees the lane and the
/// anchor one at a time.
///
/// Channels are stored on the WIRE: `:ch 1` is channel 0 and
/// `:channel 1` is `channel == 0`, so `Channels`' bits and `u6` are
/// exactly the domains. The printer adds the one back.
pub const Address = union(enum) {
    smf: struct {
        /// 1-based file order, as written.
        track: u16,
        /// One channel (`:ch 2`) or several of this track (`:ch [1 2]`).
        ch: Channels,
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

/// An inline `(midi/smf …)` dump and the anchor it pairs with — the
/// whole `.mid` as a value, filled by `doc/bridge_smf.zig` when the
/// document's roots carry one.
///
/// `sequence` owns an arena of its own (the format cores are arena-backed
/// values, plan 05), so `Doc.deinit` releases it explicitly rather than
/// letting the document's arena stand for it.
pub const SmfTier = struct {
    anchor: AnchorId,
    sequence: Sequence.Sequence,
};

/// An inline `(it/module …)` dump and the anchor it pairs with, filled
/// by `doc/bridge_it.zig`. `module` owns its own arena, as `SmfTier`'s
/// `sequence` does; its opaque regions point at the ANCHOR's bytes,
/// which it neither owns nor copies.
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
    /// The CONDUCTOR anchor's own bytes, when it conducts BY REFERENCE
    /// and the host could read and verify them — arena-owned, like every
    /// other slice here.
    ///
    /// Plan 03's rules 2 and 3 make no inline/by-reference distinction,
    /// and the two layers that build a conductor's tables over a finished
    /// value (`fromSjon.mapOf`, `time/derive.conduct`) hold a `Doc` and
    /// no resolver — so the file travels WITH the document and
    /// `fromSjon.conductorOf` is the one owner all three read it through.
    /// Null for a document that conducts itself, for an inline tier
    /// (the tier IS the bytes) and for a file nobody could produce, which
    /// is the one case that keeps the placeholder
    /// (`fromSjon.conductedPlaceholder`).
    conductor_bytes: ?[]const u8 = null,
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
    ///
    /// A PASS-THROUGH form is compared structurally for the same reason
    /// (`passthroughEql`): its `text` is a source slice, and two
    /// documents that say the same thing in two layouts are one
    /// document. The comments an author wrote above a root are still
    /// compared exactly — the printer is required to put those back.
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
            if (!passthroughEql(x.text, y.text)) return false;
            if (x.comments.len != y.comments.len) return false;
            for (x.comments, y.comments) |cx, cy| {
                if (!std.mem.eql(u8, cx, cy)) return false;
            }
        }

        // The tiers are compared by COUNT only. Two dumps are equal when
        // they say the same thing, and saying so means walking two event
        // streams or two pattern grids across two byte pools — which is
        // `Sequence` / `Module` equality, a thing neither core exports
        // yet (plan 05's rung 2 spells the shape in its own tests). The
        // round-trip property this function serves is the DOCUMENT's, and
        // a dump's own round trip is pinned where it belongs, in the two
        // bridges' fixed-point tests. Deferred by the controller.
        if (a.midi.len != b.midi.len or a.it.len != b.it.len) return false;
        return true;
    }
};

/// Two pass-through forms compared STRUCTURALLY: the same tokens in the
/// same order, whatever the layout between them.
///
/// `Passthrough.text` is a pacer root's SOURCE SLICE, and comparing two
/// of those byte for byte compares two texts' typography rather than two
/// documents. That is exactly what the final review's D1 caught: plan
/// 04's essence restores a document through SJON's Binary IR and prints
/// it back with SJON's own printer, so a `(control :id glow-amt …)` an
/// author had aligned under a trailing comment came back canonically
/// laid out — semantically the same form, and `rung3 :ok false` on
/// `corpus/examples-native` for it, which made the branch's
/// essence-exactness gate report a loss that had not happened.
///
/// The comparison is the token stream, and allocation-free because
/// `eql` takes no allocator (and a round-trip check that could fail on
/// memory pressure would be a worse gate than this one):
///
///   * whitespace between tokens is layout and is skipped;
///   * a `;` comment to end of line is layout HERE — an interior comment
///     the printer moved or re-indented is not a changed document. The
///     comments an author wrote ABOVE a root are still compared byte for
///     byte, above: those are `Passthrough.comments`, which the printer
///     is required to put back where a re-read finds them;
///   * `(`, `)`, `[`, `]`, `{` and `}` are each one token, so nesting is
///     compared and not merely the leaves;
///   * a string literal is one token, quotes, escapes and all — its
///     interior spaces are content, not layout;
///   * everything else is a run up to the next delimiter: a keyword, a
///     symbol, a number, a boolean.
///
/// What is NOT normalised is a number's spelling: `0.50` and `0.5` are
/// two tokens here. SJON's printer does not re-spell what Binary IR
/// carried, so the two sides agree in practice, and a re-spelling IS
/// something a reviewer should be shown rather than have hidden.
fn passthroughEql(a: []const u8, b: []const u8) bool {
    var x: Tokens = .{ .src = a };
    var y: Tokens = .{ .src = b };
    while (true) {
        const ta = x.next();
        const tb = y.next();
        if (ta == null or tb == null) return ta == null and tb == null;
        if (!std.mem.eql(u8, ta.?, tb.?)) return false;
    }
}

/// SJON's significant bytes, token by token — enough of a lexer for
/// `passthroughEql` and deliberately no more (the real one is SJON's,
/// and it wants an allocator and a diagnostic list).
const Tokens = struct {
    src: []const u8,
    i: usize = 0,

    fn next(self: *Tokens) ?[]const u8 {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            switch (c) {
                ' ', '\t', '\r', '\n' => self.i += 1,
                ';' => while (self.i < self.src.len and self.src[self.i] != '\n') {
                    self.i += 1;
                },
                else => break,
            }
        }
        if (self.i >= self.src.len) return null;

        const start = self.i;
        switch (self.src[self.i]) {
            '(', ')', '[', ']', '{', '}' => {
                self.i += 1;
                return self.src[start..self.i];
            },
            '"' => {
                self.i += 1;
                while (self.i < self.src.len) : (self.i += 1) {
                    if (self.src[self.i] == '\\') {
                        // A trailing backslash is a truncated literal;
                        // stop at the end rather than stepping past it.
                        self.i += 1;
                        continue;
                    }
                    if (self.src[self.i] == '"') {
                        self.i += 1;
                        break;
                    }
                }
                return self.src[start..@min(self.i, self.src.len)];
            },
            else => {
                while (self.i < self.src.len) : (self.i += 1) {
                    switch (self.src[self.i]) {
                        ' ', '\t', '\r', '\n', ';', '(', ')', '[', ']', '{', '}', '"' => break,
                        else => {},
                    }
                }
                return self.src[start..self.i];
            },
        }
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
                    if (s.track != o.track or !s.ch.eql(o.ch)) return false;
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

test "Doc.Channels: a single, a set, its first, its count and its walk" {
    const one: Channels = .single(1);
    try testing.expect(one.has(1));
    try testing.expect(!one.has(0));
    try testing.expectEqual(@as(u4, 1), one.first());
    try testing.expectEqual(@as(u8, 1), one.count());
    try testing.expect(!one.isEmpty());
    try testing.expect(Channels.none.isEmpty());
    try testing.expectEqual(@as(u4, 0), Channels.none.first());

    // The union is order-free, and `first` is the LOWEST channel in it
    // whatever order it was built in — which is what makes the record
    // wire deterministic.
    const set = Channels.single(9).with(2).merge(.single(15));
    try testing.expectEqual(@as(u4, 2), set.first());
    try testing.expectEqual(@as(u8, 3), set.count());
    try testing.expect(set.eql(Channels.single(2).with(15).with(9)));
    try testing.expect(!set.eql(one));

    var it = set.iterator();
    try testing.expectEqual(@as(?u4, 2), it.next());
    try testing.expectEqual(@as(?u4, 9), it.next());
    try testing.expectEqual(@as(?u4, 15), it.next());
    try testing.expectEqual(@as(?u4, null), it.next());
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

test "Doc.eql: a pass-through form re-laid-out is the same form" {
    // The final review's D1. Plan 04's essence restores a document
    // through SJON's Binary IR and prints it back canonically, so a
    // pacer root an author had aligned by hand comes back with different
    // whitespace and the same meaning — and comparing `text` byte for
    // byte reported `rung3 :ok false` for it, which is a loss the gate
    // was claiming had happened when it had not.
    const gpa = testing.allocator;
    var a: Doc = .empty(gpa);
    defer a.deinit();
    var b: Doc = .empty(gpa);
    defer b.deinit();

    var one = [_]Passthrough{.{
        .head = "control",
        .text = "(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)",
        .comments = &.{},
        .span = .{ .start = 0, .end = 4 },
    }};
    var two = [_]Passthrough{.{
        .head = "control",
        .text =
        \\(control
        \\  :id glow-amt     ; the author's own alignment
        \\  :type slider
        \\  :min 0 :max 1
        \\  :value 0.5
        \\  :target glow-amt)
        ,
        .comments = &.{},
        .span = .{ .start = 99, .end = 140 },
    }};
    a.passthrough = &one;
    b.passthrough = &two;
    try testing.expect(a.eql(&b));

    // …and a form that says something DIFFERENT is still different, at
    // every level: a changed value, a changed key, a changed nesting, a
    // dropped token.
    for ([_][]const u8{
        "(control :id glow-amt :type slider :min 0 :max 1 :value 0.6 :target glow-amt)",
        "(control :id glow-amt :type knob :min 0 :max 1 :value 0.5 :target glow-amt)",
        "(control :id glow-amt :type slider :min 0 :max 1 :value 0.5)",
        "(control :id glow-amt :type slider :range [0 1] :value 0.5 :target glow-amt)",
        "(control :id glow-amt :type slider :min 0 :max 1 :value (0.5) :target glow-amt)",
    }) |text| {
        two[0].text = text;
        if (a.eql(&b)) {
            std.debug.print("not distinguished: {s}\n", .{text});
            return error.StructuralComparisonTooLoose;
        }
    }

    // A string's own interior spaces are content and not layout.
    one[0].text = "(control :id x :label \"two  spaces\")";
    two[0].text = "(control :id x :label \"two spaces\")";
    try testing.expect(!a.eql(&b));
    two[0].text = "(control  :id  x\n  :label \"two  spaces\")";
    try testing.expect(a.eql(&b));

    // The comments ABOVE a root are the printer's contract and are
    // compared exactly.
    one[0].comments = &.{"; pacer's form, pass-through"};
    two[0].comments = &.{"; pacer's form,  pass-through"};
    try testing.expect(!a.eql(&b));
    two[0].comments = &.{"; pacer's form, pass-through"};
    try testing.expect(a.eql(&b));
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
