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

    /// Whether wire channel `c` is in the set.
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

    /// Whether the set names no channel — never a valid address.
    pub fn isEmpty(self: Channels) bool {
        return self.mask == 0;
    }

    /// How many channels the set names, 0..16.
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

    /// Whether the two sets name the same channels.
    pub fn eql(self: Channels, other: Channels) bool {
        return self.mask == other.mask;
    }

    /// The channels in ascending order, one per `next()`.
    pub fn iterator(self: Channels) Iterator {
        return .{ .left = self.mask };
    }

    pub const Iterator = struct {
        left: u16,

        /// The lowest channel not yet answered, or null when none is left.
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

    /// How many times the clip plays its phrase: `repeat-count` is "at
    /// least once" (1..), and a `:repeat 0` the manifest refused still
    /// lowers as 0, so the floor is here, once.
    pub fn plays(self: Clip) i64 {
        return @max(1, self.repeat);
    }

    /// The playback window, in ticks from `offset`: `:length`, or the
    /// phrase's length times `plays` less `:offset` — THE formula, which
    /// the `:length` default (`fromSjon.contentEnd`), the placement
    /// (`time/derive.place`) and the selection (`edit/Select`) all read.
    ///
    /// Saturating: `:repeat` has no maximum and a phrase's `:length`
    /// reaches the grid's ceiling, so the product does not fit an `i64`
    /// in general. Not clamped: at or below 0 the clip places nothing,
    /// and each consumer says what that is to it.
    pub fn window(self: Clip, phrase: *const Phrase) i64 {
        return self.length orelse (phrase.length *| self.plays()) -| self.offset;
    }
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
    /// `:cc` on a NATIVE curve lane: the controller a `.mid` build
    /// renders its keyframes onto (plan 08 — the lane's own `:cc`, or
    /// `--cc` for a lane without one). Only `cc` and `cc14` are ever set
    /// here; a BOUND lane's controller is the one in its `binding`, and
    /// this stays null beside it.
    cc: ?SmfCurve = null,
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

    /// Frees the arena — every slice, name and table — and each inline
    /// tier's own `Sequence` / `Module`. Nothing read out of the
    /// document outlives this; a `TimeMap` or a `Derived` built from it
    /// owns its own and does.
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

    /// The properties every `Doc` this part hands out satisfies —
    /// asserted, never diagnosed, because each is something OUR code
    /// establishes and no input can break: a reader that meets a bad
    /// form diagnoses and drops it, and the value it returns satisfies
    /// these anyway (plan 12, "The invariants, value by value"). Called
    /// at the WRITE side — the end of `fromSjon.fromSource` — and at the
    /// READ side, the entry of each consumer that takes the whole value;
    /// never per query. The check costs nothing in `ReleaseSmall`, where
    /// a violated assertion is undefined behaviour rather than a trap —
    /// which is why every clause must be one no input can break, and why
    /// `tools/zt fuzz` drives arbitrary text through every reader of a
    /// `Doc`.
    ///
    /// Every duration is `≥ 0`: notes' and sections' alike resolve
    /// through `TimeMap.durationTicks`, which never answers a distance
    /// backwards. Two of plan 12's first clauses are NOT here, because
    /// the loader does not establish them: `:repeat 0` is the schema's
    /// complaint and the clip is kept with its zero, and two anchors of
    /// one `:id` are both kept. Both are diagnostics on the document, not
    /// defects of the value.
    pub fn invariants(self: *const Doc) void {
        for (self.anchors) |a| spanOk(a.span);
        for (self.tempo) |t| spanOk(t.span);
        for (self.meter) |m| spanOk(m.span);
        for (self.sections) |s| {
            spanOk(s.span);
            std.debug.assert(s.dur >= 0);
        }
        for (self.cues) |c| spanOk(c.span);
        for (self.passthrough) |p| spanOk(p.span);
        for (self.lanes) |*l| laneInvariants(l, false);
        for (self.phrases) |p| {
            spanOk(p.span);
            for (p.lanes) |*l| laneInvariants(l, true);
        }
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
    ///
    /// The tiers are compared by COUNT only. Two dumps are equal when
    /// they say the same thing, and saying so means walking two event
    /// streams or two pattern grids across two byte pools — which is
    /// `Sequence` / `Module` equality, a thing neither core exports yet
    /// (plan 05's rung 2 spells the shape in its own tests). The
    /// round-trip property this function serves is the DOCUMENT's, and a
    /// dump's own round trip is pinned where it belongs, in the two
    /// bridges' fixed-point tests. Deferred by the controller.
    pub fn eql(a: *const Doc, b: *const Doc) bool {
        if (!optStrEql(a.title, b.title)) return false;
        if (!optEql(i64, a.length, b.length)) return false;
        if (a.end != b.end) return false;
        if (!optStrEql(a.conductor, b.conductor)) return false;
        if (!allEql(Anchor, a.anchors, b.anchors, anchorEql)) return false;
        if (!allEql(TempoPoint, a.tempo, b.tempo, tempoPointEql)) return false;
        if (!allEql(MeterPoint, a.meter, b.meter, meterPointEql)) return false;
        if (!allEql(Section, a.sections, b.sections, sectionEql)) return false;
        if (!allEql(Cue, a.cues, b.cues, cueEql)) return false;
        if (!allEql(Lane, a.lanes, b.lanes, laneEql)) return false;
        if (!allEql(Phrase, a.phrases, b.phrases, phraseEql)) return false;
        if (!allEql(Passthrough, a.passthrough, b.passthrough, passthroughFormEql)) return false;
        return a.midi.len == b.midi.len and a.it.len == b.it.len;
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
    // Bounded by the shorter source's length: every `next` that answers
    // a token advances its scanner by at least one byte, and the loop
    // returns the moment either scanner runs out.
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

/// A span is a byte range: it never runs backwards.
fn spanOk(span: Diag.Span) void {
    std.debug.assert(span.start <= span.end);
}

/// One lane's clauses. `in_phrase` marks a phrase's lane, which carries
/// content only (plan 02): `fromSjon` never binds one, and the edit
/// engine cannot reach one.
fn laneInvariants(l: *const Lane, in_phrase: bool) void {
    spanOk(l.span);
    if (in_phrase) std.debug.assert(l.binding == null);
    // `:cc` on a NATIVE curve lane and the address inside a binding are
    // one key read two ways: a lane carries one or the other, never
    // both — and the native one is a controller, never a surface.
    if (l.cc != null) std.debug.assert(l.binding == null);
    if (l.cc) |c| std.debug.assert(c == .cc or c == .cc14);
    // A bound SMF address names at least one channel: `Channels.none`
    // is never an address, and `fromSjon` refuses `:ch []`.
    if (l.binding) |b| switch (b.address) {
        .smf => |s| std.debug.assert(!s.ch.isEmpty()),
        .it => {},
    };
    for (l.notes) |n| {
        spanOk(n.span);
        std.debug.assert(n.dur >= 0);
    }
    for (l.keyframes) |k| {
        spanOk(k.span);
        // `ncomp` counts the components in use: one to four.
        std.debug.assert(k.ncomp >= 1);
        std.debug.assert(k.ncomp <= 4);
    }
    for (l.clips) |c| spanOk(c.span);
}

/// Two slices of one length whose elements are pairwise `eqlFn`.
fn allEql(comptime T: type, a: []const T, b: []const T, comptime eqlFn: fn (T, T) bool) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!eqlFn(x, y)) return false;
    }
    return true;
}

fn anchorEql(x: Anchor, y: Anchor) bool {
    if (!std.mem.eql(u8, x.id, y.id)) return false;
    if (x.kind != y.kind) return false;
    if (!std.mem.eql(u8, x.file, y.file)) return false;
    if (!optEql(u64, x.size, y.size)) return false;
    if (!optStrEql(x.sha256_src, y.sha256_src)) return false;
    if ((x.sha256 == null) != (y.sha256 == null)) return false;
    if (x.sha256) |d| if (!std.mem.eql(u8, &d, &y.sha256.?)) return false;
    return x.inline_dump == y.inline_dump and x.resolved == y.resolved;
}

/// The same tick, the same authored spelling, the same number under it.
fn tempoPointEql(x: TempoPoint, y: TempoPoint) bool {
    if (x.tick != y.tick) return false;
    if (spellingOf(x) != spellingOf(y)) return false;
    return switch (x.tempo) {
        .us => |u| u == y.tempo.us,
        .qpm => |q| q == y.tempo.qpm,
    };
}

fn meterPointEql(x: MeterPoint, y: MeterPoint) bool {
    return x.tick == y.tick and x.n == y.n and x.d == y.d;
}

fn sectionEql(x: Section, y: Section) bool {
    return std.mem.eql(u8, x.name, y.name) and x.at == y.at and x.dur == y.dur;
}

fn cueEql(x: Cue, y: Cue) bool {
    return std.mem.eql(u8, x.name, y.name) and x.at == y.at;
}

fn phraseEql(x: Phrase, y: Phrase) bool {
    if (!std.mem.eql(u8, x.name, y.name)) return false;
    if (x.length != y.length) return false;
    return allEql(Lane, x.lanes, y.lanes, laneEql);
}

/// A pass-through form: its head, its text STRUCTURALLY, and the
/// comments above it exactly (`passthroughEql` says why the two differ).
fn passthroughFormEql(x: Passthrough, y: Passthrough) bool {
    if (!std.mem.eql(u8, x.head, y.head)) return false;
    if (!passthroughEql(x.text, y.text)) return false;
    return allEql([]const u8, x.comments, y.comments, strEql);
}

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn laneEql(x: Lane, y: Lane) bool {
    if (!std.mem.eql(u8, x.name, y.name)) return false;
    if (x.kind != y.kind) return false;
    if (!std.mem.eql(u8, x.target, y.target)) return false;
    if ((x.range == null) != (y.range == null)) return false;
    if (x.range) |r| if (r[0] != y.range.?[0] or r[1] != y.range.?[1]) return false;
    if (!bindingEql(x.binding, y.binding)) return false;
    if ((x.cc == null) != (y.cc == null)) return false;
    if (x.cc) |c| if (!std.meta.eql(c, y.cc.?)) return false;
    if (!allEql(Note, x.notes, y.notes, noteEql)) return false;
    if (!allEql(Keyframe, x.keyframes, y.keyframes, keyframeEql)) return false;
    if (!allEql(Clip, x.clips, y.clips, clipEql)) return false;
    if (!optStrEql(x.query_src, y.query_src)) return false;
    return optStrEql(x.expr_src, y.expr_src);
}

fn bindingEql(a: ?Binding, b: ?Binding) bool {
    if (a == null or b == null) return a == null and b == null;
    const x = a.?;
    const y = b.?;
    if (!std.mem.eql(u8, x.anchor, y.anchor)) return false;
    if (std.meta.activeTag(x.address) != std.meta.activeTag(y.address)) return false;
    switch (x.address) {
        .smf => |s| {
            const o = y.address.smf;
            if (s.track != o.track or !s.ch.eql(o.ch)) return false;
            if (!optEql(u7, s.key, o.key)) return false;
            if ((s.curve == null) != (o.curve == null)) return false;
            if (s.curve) |c| if (!std.meta.eql(c, o.curve.?)) return false;
        },
        .it => |s| {
            const o = y.address.it;
            if (s.channel != o.channel) return false;
            if (!optEql(ItColumn, s.column, o.column)) return false;
            if (!optEql(u8, s.fx, o.fx)) return false;
        },
    }
    return true;
}

fn noteEql(x: Note, y: Note) bool {
    if (x.at != y.at or x.dur != y.dur) return false;
    if (x.key != y.key or x.vel != y.vel or x.ch != y.ch) return false;
    return optEql(u7, x.off_vel, y.off_vel);
}

fn keyframeEql(x: Keyframe, y: Keyframe) bool {
    if (x.at != y.at or x.ncomp != y.ncomp) return false;
    if (!std.mem.eql(f32, &x.value, &y.value)) return false;
    return std.mem.eql(u8, x.ease_src, y.ease_src);
}

fn clipEql(x: Clip, y: Clip) bool {
    if (x.at != y.at or x.offset != y.offset) return false;
    if (!std.mem.eql(u8, x.phrase, y.phrase)) return false;
    if (x.repeat != y.repeat or x.transpose != y.transpose) return false;
    return optEql(i64, x.length, y.length);
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

test "Doc.invariants: an empty document and a hand-built one hold" {
    var d: Doc = .empty(testing.allocator);
    defer d.deinit();
    d.invariants();

    // A native curve lane with its own controller, a keyframe of every
    // legal width and a phrase whose lane is unbound: the positive space
    // of each clause.
    var keys = [_]Keyframe{
        .{ .at = 0, .value = .{ 0, 0, 0, 0 }, .ncomp = 1, .ease_src = "linear", .span = .{
            .start = 1,
            .end = 2,
        } },
        .{ .at = 1, .value = .{ 1, 1, 1, 1 }, .ncomp = 4, .ease_src = "hold", .span = .{
            .start = 3,
            .end = 3,
        } },
    };
    var lanes = [_]Lane{bareCurve("glow")};
    lanes[0].cc = .{ .cc14 = .{ 74, 106 } };
    lanes[0].keyframes = &keys;
    var inner = [_]Lane{bareCurve("glow")};
    var phrases = [_]Phrase{.{
        .name = "fill",
        .length = 4,
        .lanes = &inner,
        .span = .{ .start = 0, .end = 9 },
    }};
    d.lanes = &lanes;
    d.phrases = &phrases;
    d.invariants();
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

    var one = [_]Section{.{
        .name = "intro",
        .at = 0,
        .dur = 8,
        .span = .{ .start = 0, .end = 4 },
    }};
    var two = [_]Section{.{
        .name = "intro",
        .at = 0,
        .dur = 8,
        .span = .{ .start = 99, .end = 120 },
    }};
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
    b.length = 4096;

    // A native curve lane's `:cc` is a field like any other: the
    // controller a build renders onto (plan 08).
    var la = [_]Lane{bareCurve("glow")};
    var lb = [_]Lane{bareCurve("glow")};
    a.lanes = &la;
    b.lanes = &lb;
    try testing.expect(a.eql(&b));
    lb[0].cc = .{ .cc = 74 };
    try testing.expect(!a.eql(&b));
    la[0].cc = .{ .cc = 74 };
    try testing.expect(a.eql(&b));
    lb[0].cc = .{ .cc14 = .{ 74, 106 } };
    try testing.expect(!a.eql(&b));
}

/// A native curve lane with nothing in it, for the test above.
fn bareCurve(name: []const u8) Lane {
    return .{
        .name = name,
        .kind = .curve,
        .target = name,
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = .{ .start = 0, .end = 0 },
    };
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

test "Doc.Clip.window: :length, or the phrase times its plays less :offset — at least once" {
    const nowhere: Diag.Span = .{ .start = 0, .end = 0 };
    const phrase: Phrase = .{ .name = "fill", .length = 100, .lanes = &.{}, .span = nowhere };
    var clip: Clip = .{
        .at = 1000,
        .phrase = "fill",
        .repeat = 3,
        .offset = 20,
        .length = null,
        .transpose = 0,
        .span = .{ .start = 0, .end = 0 },
    };
    // 100 ticks of phrase, three times, less the 20-tick offset.
    try std.testing.expectEqual(@as(i64, 280), clip.window(&phrase));
    // `repeat-count` is at least once: a `:repeat 0` plays the phrase.
    clip.repeat = 0;
    try std.testing.expectEqual(@as(i64, 1), clip.plays());
    try std.testing.expectEqual(@as(i64, 80), clip.window(&phrase));
    // An explicit `:length` is the window instead.
    clip.length = 50;
    try std.testing.expectEqual(@as(i64, 50), clip.window(&phrase));
    // Saturating: the product of two user numbers does not wrap.
    clip.length = null;
    clip.repeat = std.math.maxInt(u32);
    const huge: Phrase = .{ .name = "fill", .length = 1 << 53, .lanes = &.{}, .span = nowhere };
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64) - 20), clip.window(&huge));
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
    var phrases = [_]Phrase{.{
        .name = "fill",
        .length = 4,
        .lanes = &.{},
        .span = .{ .start = 0, .end = 1 },
    }};
    d.anchors = &anchors;
    d.phrases = &phrases;

    try testing.expectEqual(AnchorKind.it, d.anchorById("song").?.kind);
    try testing.expect(d.anchorById("other") == null);
    try testing.expectEqual(@as(i64, 4), d.phraseByName("fill").?.length);
    try testing.expect(d.phraseByName("other") == null);
}
