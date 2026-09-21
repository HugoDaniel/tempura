//! Tree → `Doc`: validate a `(timeline …)` source, then walk it once.
//!
//! Two vocabularies meet here and neither re-spells the other. What a
//! MANIFEST can say — a key's type, its range, its unit, which keys a
//! `:kind` admits, how many of a set may be present — is said in
//! `schema/tempura.sjon` and rides across under one tempura code,
//! `sjon_diagnostic`, keeping SJON's own message and span. What a schema
//! cannot see — document ORDER, which root follows which, the file an
//! anchor names, a relation between two forms — is checked here, each
//! with the offending form's span (plan 02, "The document"; the
//! manifest's header lists the same split from the other side).
//!
//! **The walk is total.** Every key is read with an `orelse`, never an
//! unwrap: a document that SJON already refused still lowers as far as
//! it goes, because an editor asking "what is wrong with this file"
//! wants every complaint at once and not the first one. Nothing here
//! asserts on user input.
//!
//! **Positions resolve through the document's OWN map.** With no
//! conductor that is what plan 03 says; an anchored document's map is
//! the anchored half's. The map is needed to resolve `:length` and
//! `:length` is needed to build the map, so the circle is cut in three
//! derives:
//!
//!   1. the METER ticks, resolved incrementally — a meter point's `:at`
//!      in `bar` or `b` counts through the meters BEFORE it, which is
//!      well-founded because `s` is forbidden on the form (plan 03);
//!   2. a PROVISIONAL map over both tables with length 0, which answers
//!      every `q` / `t` / `bar` / `b` / `s` literal in the document
//!      exactly as the final one will (a `bar` past the bar table
//!      extrapolates from the meter in force, and the tempo table does
//!      not depend on the length at all);
//!   3. the FINAL map, once `:length` is known — authored, or the end of
//!      the last event or clip rounded up to a bar, which is one more
//!      derive whose bar table stops on exactly that bar line.
//!
//! Only the final derive's diagnostics are forwarded, so a defect in the
//! tempo table is reported once and not three times.
//!
//! The rules that read the finished VALUE rather than the tree — an
//! anchor's bytes, two notes overlapping, a clip's phrase, a scene's
//! name — live in `checks.zig`, which this walk calls at the points
//! where each becomes answerable.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const Grid = @import("../time/Grid.zig");
const Pos = @import("../time/Pos.zig");
const Schema = @import("../Schema.zig");
const TimeMap = @import("../time/TimeMap.zig");
const Doc = @import("Value.zig");
const Resolver = @import("Resolver.zig");
const bridge_it = @import("bridge_it.zig");
const bridge_smf = @import("bridge_smf.zig");
const checks = @import("checks.zig");
const itf = @import("../itf/itf.zig");
const smf = @import("../smf/smf.zig");

const Ast = sjon.Ast;
const NodeIndex = Ast.NodeIndex;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Explicit error set. A defective DOCUMENT is never an error here — it
/// IS the diagnostics on the returned result (the SJON discipline).
pub const Error = error{OutOfMemory};

/// The slot-local defaults, restated.
///
/// SJON's materialized-defaults overlay is keyed by a GLOBAL form
/// lookup, so `note`, `keyframe` and `clip` — declared local to
/// `(lane …)` so that `note` may be tempura's timeline event while
/// midivia's `note` verb keeps its own meaning — never receive entries
/// (pacer hit the same wall with `(key :ease)` and seeded its program
/// table by hand). These four are read out of the manifest by the test
/// at the bottom of this file, so a `:default` that moves there breaks
/// the build rather than drifting.
const default_vel: u7 = 100;
const default_repeat: u32 = 1;
const default_transpose: i8 = 0;
const default_ease = "linear";

/// A note's `:ch` default is "the lane's `:ch`, or 1" — a default that
/// copies another key, so the manifest cannot declare it. A lane's `:ch`
/// is a BINDING key and a bound lane has no notes, so the fallback is
/// always the 1, which is 0 on the wire.
const default_note_ch: u4 = 0;

/// What `fromSource` returns: the document, the map its positions
/// resolved through, and the report.
///
/// `doc` and `map` own their arenas and `diags` owns its messages; the
/// result borrows nothing from the source or from the schema.
pub const Result = struct {
    doc: Doc.Doc,
    diags: Diag.List,
    map: TimeMap.TimeMap,

    pub fn deinit(self: *Result) void {
        self.doc.deinit();
        self.map.deinit();
        self.diags.deinit();
    }

    /// The first diagnostic carrying `code`, or null. The test and
    /// debug helper; production consumers walk `diags.items()`.
    pub fn findDiag(self: *const Result, code: Diag.Code) ?Diag.Diagnostic {
        for (self.diags.items()) |d| {
            if (d.code == code) return d;
        }
        return null;
    }
};

/// Validate one `(timeline …)` source against the preloaded bundle and
/// lower it to a `Doc`.
///
/// `schema` is borrowed FOR THE CALL ONLY: the result keeps no reference
/// to it, because every string it needed was copied into the document's
/// arena and the SJON tree it was validated against is released before
/// this function returns. `resolver` is how this host reads an anchor's
/// bytes; `null` means nothing was asked to read anything, and a
/// by-reference anchor is then recorded unresolved and silent.
pub fn fromSource(
    gpa: Allocator,
    schema: *const Schema,
    source: [:0]const u8,
    resolver: ?Resolver.Resolver,
) Error!Result {
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var validated = try Schema.validate(gpa, schema, source);
    defer validated.deinit();
    for (validated.diagnostics) |d| {
        try diags.add(
            .sjon_diagnostic,
            switch (d.severity) {
                .err => .err,
                .warning => .warning,
            },
            .{ .start = d.span.start, .end = d.span.end },
            "{s}",
            .{d.message},
        );
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    var ctx: Ctx = .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .tree = &validated.tree,
        .source = source,
        .view = .init(&validated.tree, &validated.materialized_defaults),
        .diags = &diags,
        .resolver = resolver,
    };

    var doc = try ctx.walk(validated.data_forest);
    // The arena's `errdefer` above frees the document's own slices; the
    // tiers each own an arena of their own, which it does not reach.
    errdefer releaseTiers(&doc);
    const map = try ctx.finalMap(&doc);
    doc.arena = arena;
    doc.invariants();
    return .{ .doc = doc, .diags = diags, .map = map };
}

/// Release the arenas the inline tiers own, on a load that failed after
/// `readTiers` handed them over. A finished document releases them in
/// `Doc.deinit`; this is the same loop for one that never finished, whose
/// own arena is `undefined` until `fromSource` sets it.
fn releaseTiers(doc: *Doc.Doc) void {
    for (doc.midi) |*t| t.sequence.deinit();
    for (doc.it) |*t| t.module.deinit();
}

/// Where a document's content ends — plan 02's `:length` default before
/// the round-up: "the end of the last event or clip".
///
/// This is the rule `Ctx.max_end` accumulates while the walk resolves
/// each form, stated over a FINISHED value so that a consumer holding a
/// `Doc` and no tree computes the same number: a native note's
/// `at + dur`, a keyframe's `at`, and a clip's whole WINDOW whether or
/// not anything sounds in it (`checks.clipPlacement`'s own arithmetic).
/// A phrase's own lanes count for nothing — they sound where a clip puts
/// them and the clip's window already says where that is — and a bound
/// lane's content counts for nothing either, because it is the ANCHOR's
/// material and the document did not place it.
///
/// `time/derive.zig` calls this rather than keeping a second copy of the
/// rule: the map that layer builds for a document has to be the map this
/// one built for it, and one function is how that stays true.
///
/// Saturating throughout: every term is user arithmetic.
pub fn contentEnd(doc: *const Doc.Doc) i64 {
    var end: i64 = 0;
    for (doc.lanes) |lane| {
        for (lane.notes) |n| end = @max(end, n.at +| n.dur);
        for (lane.keyframes) |k| end = @max(end, k.at);
        for (lane.clips) |c| {
            const phrase = doc.phraseByName(c.phrase) orelse continue;
            const window = c.length orelse
                (phrase.length *| @as(i64, c.repeat)) -| c.offset;
            end = @max(end, c.at +| @max(0, window));
        }
    }
    return end;
}

/// The map a `Doc` resolves its positions against — `Result.map`, from
/// the finished value alone.
///
/// The document layer owns the map. `fromSource` builds one while it
/// walks and stores it on the result; a consumer that holds a `Doc` and
/// wants the same answer calls this rather than re-deriving, because
/// "the same answer" is the whole point: the edit engine spells a
/// position with it, the exporters measure with it, and two copies of
/// plan 02's `:length` rule would be two documents.
///
/// It reproduces `finalMap` exactly:
///
///   * the CONDUCTOR's tables when the document names one and either
///     holds its inline dump or carries the anchor's verified bytes
///     (plan 03's rules 2 and 3, through `conductorOf`);
///   * plan 03's placeholder — 500 000 microseconds per quarter note in
///     `[4 4]` — when it names one and neither is in hand, so a
///     conducted document is never told it needs a point at tick 0. The
///     LOAD raised `anchor_unavailable` for that document already
///     (`conductedPlaceholder`); a map is not the place to hear it
///     twice;
///   * otherwise the document's own `(tempo-point …)` and
///     `(meter-point …)`;
///   * `:length`, or `contentEnd` — the anchor's own end included —
///     rounded UP to a bar by a probe derive.
///
/// The conductor's own diagnostics are dropped: a caller holding a `Doc`
/// has already been handed them by the load that produced it, and a map
/// is not the place to hear them twice.
///
/// Caller releases with `map.deinit()`.
pub fn mapOf(gpa: Allocator, doc: *const Doc.Doc) Error!TimeMap.TimeMap {
    doc.invariants();
    var cond: ?Conductor = null;
    defer if (cond) |*c| c.deinit();
    if (doc.conductor) |id| cond = try conductorOf(gpa, doc, id, doc.conductor_bytes);

    const seeded_tempo = [_]Doc.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    const seeded_meter = [_]Doc.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const tempo: []const Doc.TempoPoint = if (cond) |c|
        c.tempo
    else if (doc.conductor != null and doc.tempo.len == 0) &seeded_tempo else doc.tempo;
    const meter: []const Doc.MeterPoint = if (cond) |c|
        c.meter
    else if (doc.conductor != null and doc.meter.len == 0) &seeded_meter else doc.meter;

    const length = doc.length orelse len: {
        const content = @max(contentEnd(doc), if (cond) |c| c.end else 0);
        if (content <= 0) break :len 0;
        var probe = try TimeMap.derive(gpa, tempo, meter, content, doc.end);
        defer probe.deinit();
        const bars = probe.map.bars;
        break :len if (bars.len == 0) content else bars[bars.len - 1];
    };

    var final = try TimeMap.derive(gpa, tempo, meter, length, doc.end);
    final.diags.deinit();
    return final.map;
}

// ---------------------------------------------------------------------
// The walk
// ---------------------------------------------------------------------

/// A derived map and its report, so the caller says which half it wants:
/// the two provisional passes keep the map and drop the report, and the
/// final pass forwards both.
const Derived = struct {
    map: TimeMap.TimeMap,
    diags: Diag.List,

    fn deinit(self: *Derived) void {
        self.map.deinit();
        self.diags.deinit();
    }

    /// Keep the map, drop the report — a provisional derive says nothing
    /// the final one will not say again.
    fn intoMap(self: *Derived) TimeMap.TimeMap {
        self.diags.deinit();
        return self.map;
    }
};

/// What a top-level form is, for this walk.
const Root = enum {
    timeline,
    anchor,
    tempo_point,
    meter_point,
    section,
    cue,
    lane,
    phrase,
    smf_dump,
    /// A `(midi/mtrk …)` root: part of the dump the `(midi/smf …)`
    /// before it opened, never a dump of its own. An SMF dump is SEVERAL
    /// roots — the header and one per track — which is the one place the
    /// two tiers differ in shape (an `(it/module …)` holds everything).
    smf_track,
    it_dump,
    passthrough,
};

/// One inline dump, as the partition found it: the anchor it follows,
/// what it is, and the roots it spans inside the walk's flat root list.
const Dump = struct {
    anchor: u32,
    kind: Doc.AnchorKind,
    start: u32,
    len: u32,
};

/// The roots of one document sorted by what each is, in document order
/// — the walk's scratch. These lists come from the gpa and die with the
/// walk rather than with the document: the document's arena frees
/// nothing until the document itself does, and a walk's bookkeeping has
/// no business outliving the walk.
const Partition = struct {
    timelines: std.ArrayList(NodeIndex) = .empty,
    anchors: std.ArrayList(NodeIndex) = .empty,
    tempo: std.ArrayList(NodeIndex) = .empty,
    meter: std.ArrayList(NodeIndex) = .empty,
    sections: std.ArrayList(NodeIndex) = .empty,
    cues: std.ArrayList(NodeIndex) = .empty,
    lanes: std.ArrayList(NodeIndex) = .empty,
    phrases: std.ArrayList(NodeIndex) = .empty,
    passthrough: std.ArrayList(NodeIndex) = .empty,
    /// How many inline dumps paired with each anchor, by position.
    dumps_per_anchor: std.ArrayList(u32) = .empty,
    /// The inline dumps themselves: one entry per dump, each naming the
    /// anchor it follows and its own roots inside `dump_roots`.
    dumps: std.ArrayList(Dump) = .empty,
    dump_roots: std.ArrayList(NodeIndex) = .empty,

    fn deinit(self: *Partition, gpa: Allocator) void {
        self.timelines.deinit(gpa);
        self.anchors.deinit(gpa);
        self.tempo.deinit(gpa);
        self.meter.deinit(gpa);
        self.sections.deinit(gpa);
        self.cues.deinit(gpa);
        self.lanes.deinit(gpa);
        self.phrases.deinit(gpa);
        self.passthrough.deinit(gpa);
        self.dumps_per_anchor.deinit(gpa);
        self.dumps.deinit(gpa);
        self.dump_roots.deinit(gpa);
    }

    /// Open a dump after the last anchor — the positional pairing of
    /// plan 02, "(anchor …)": a dump belongs to the anchor it FOLLOWS,
    /// one per anchor. Answers how many dumps that anchor now has, so
    /// the caller can say `anchor_dump_duplicate` on a second, and null
    /// when no anchor precedes the dump at all.
    fn openDump(self: *Partition, gpa: Allocator, idx: NodeIndex, kind: Doc.AnchorKind) Error!?u32 {
        if (self.dumps_per_anchor.items.len == 0) return null;
        const last = &self.dumps_per_anchor.items[self.dumps_per_anchor.items.len - 1];
        last.* += 1;
        try self.dumps.append(gpa, .{
            .anchor = @intCast(self.dumps_per_anchor.items.len - 1),
            .kind = kind,
            .start = @intCast(self.dump_roots.items.len),
            .len = 1,
        });
        try self.dump_roots.append(gpa, idx);
        return last.*;
    }

    /// Add a `(midi/mtrk …)` to the SMF dump still open ahead of it —
    /// the header before it, with no other root in between — or answer
    /// false when no such dump is open.
    fn addTrack(self: *Partition, gpa: Allocator, idx: NodeIndex) Error!bool {
        if (self.dumps.items.len == 0) return false;
        const last = &self.dumps.items[self.dumps.items.len - 1];
        if (last.kind != .smf or last.start + last.len != self.dump_roots.items.len) return false;
        last.len += 1;
        try self.dump_roots.append(gpa, idx);
        return true;
    }
};

/// Head text to `Root`, for the eight heads plan 02 declares. Everything
/// else at the top level is pacer's and passes through.
const root_heads = [_]struct { []const u8, Root }{
    .{ "timeline", .timeline },
    .{ "anchor", .anchor },
    .{ "tempo-point", .tempo_point },
    .{ "meter-point", .meter_point },
    .{ "section", .section },
    .{ "cue", .cue },
    .{ "lane", .lane },
    .{ "phrase", .phrase },
};

const Ctx = struct {
    gpa: Allocator,
    /// The document's arena. Every name, slice and source copy lands
    /// here; nothing outlives `Doc.deinit`.
    arena: Allocator,
    tree: *const Ast.Tree,
    source: [:0]const u8,
    /// Author value first, the manifest's `:default` second — for the
    /// GLOBAL forms (see `default_vel`'s note for the rest).
    view: sjon.EffectiveView.EffectiveView,
    diags: *Diag.List,
    resolver: ?Resolver.Resolver,

    /// The map every position resolves against, and whether it is live
    /// (the incremental meter pass replaces it once per point).
    map: TimeMap.TimeMap = undefined,
    map_live: bool = false,

    /// The document's own tempo and meter tables, in document order.
    tempo: []Doc.TempoPoint = &.{},
    meter: []Doc.MeterPoint = &.{},
    conductor: ?[]const u8 = null,
    end: TimeMap.End = .hold,
    /// The greatest tick any event or clip reaches — the input to the
    /// `:length` default rule.
    max_end: i64 = 0,

    /// The CONDUCTOR's tables, built out of the inline tier the
    /// `(timeline :conductor …)` names (plan 03, "Three conductors").
    /// `cond_live` is what says they were built at all: a conducted
    /// document whose anchor carries no dump has nothing to read and
    /// falls back to the placeholder in `derive`.
    cond_tempo: []Doc.TempoPoint = &.{},
    cond_meter: []Doc.MeterPoint = &.{},
    cond_live: bool = false,
    /// Where the conductor's own material ends — `max_end`'s other half
    /// for an anchored document (see `Conductor.end`).
    cond_end: i64 = 0,

    fn emit(
        self: *Ctx,
        code: Diag.Code,
        span: Ast.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        try self.diags.add(code, .err, .{ .start = span.start, .end = span.end }, fmt, args);
    }

    /// Replace the working map, freeing the one it stands in for.
    fn setMap(self: *Ctx, map: TimeMap.TimeMap) void {
        if (self.map_live) self.map.deinit();
        self.map = map;
        self.map_live = true;
    }

    fn dropMap(self: *Ctx) void {
        if (self.map_live) self.map.deinit();
        self.map_live = false;
    }

    fn classify(self: *const Ctx, idx: NodeIndex) ?Root {
        const tree = self.tree;
        if (tree.tagOf(idx) != .form) return null;
        const hdr = tree.formHeader(idx);
        const ns = hdr.namespace;

        // The hosted tiers first. A qualified head is unambiguous and a
        // bare one resolves to the single manifest that declares it —
        // the four share no head (plan 02, "Collisions, checked").
        if (std.mem.eql(u8, hdr.head, "smf") and nsIs(ns, "midi")) return .smf_dump;
        if (std.mem.eql(u8, hdr.head, "mtrk") and nsIs(ns, "midi")) return .smf_track;
        if (std.mem.eql(u8, hdr.head, "module") and nsIs(ns, "it")) return .it_dump;
        if (ns) |n| {
            if (!std.mem.eql(u8, n, "tempura")) return .passthrough;
        }
        for (root_heads) |entry| {
            if (std.mem.eql(u8, hdr.head, entry[0])) return entry[1];
        }
        return .passthrough;
    }

    /// Sort the forest's roots by what each is, and pair every inline
    /// dump with the anchor before it. The complaints a root can earn
    /// here — a dump or a track with nothing to belong to, a second dump
    /// on one anchor — are said as they are met, in document order.
    fn partition(self: *Ctx, forest: []const NodeIndex) Error!Partition {
        var p: Partition = .{};
        errdefer p.deinit(self.gpa);
        for (forest) |idx| {
            const what = self.classify(idx) orelse continue;
            switch (what) {
                .timeline => try p.timelines.append(self.gpa, idx),
                .anchor => {
                    try p.anchors.append(self.gpa, idx);
                    try p.dumps_per_anchor.append(self.gpa, 0);
                },
                .tempo_point => try p.tempo.append(self.gpa, idx),
                .meter_point => try p.meter.append(self.gpa, idx),
                .section => try p.sections.append(self.gpa, idx),
                .cue => try p.cues.append(self.gpa, idx),
                .lane => try p.lanes.append(self.gpa, idx),
                .phrase => try p.phrases.append(self.gpa, idx),
                .passthrough => try p.passthrough.append(self.gpa, idx),
                .smf_dump, .it_dump => {
                    const kind: Doc.AnchorKind = if (what == .smf_dump) .smf else .it;
                    const count = (try p.openDump(self.gpa, idx, kind)) orelse {
                        try self.emit(
                            .anchor_missing,
                            self.tree.spanOf(idx),
                            "an inline dump with no (anchor …) before it belongs to nothing",
                            .{},
                        );
                        continue;
                    };
                    if (count > 1) try self.emit(
                        .anchor_dump_duplicate,
                        self.tree.spanOf(idx),
                        "the anchor this dump follows already has one; " ++
                            "the pairing is positional and one dump per anchor",
                        .{},
                    );
                },
                // A track belongs to the header before it. One with no
                // header belongs to nothing, which is the same complaint
                // an orphan dump gets.
                .smf_track => if (!try p.addTrack(self.gpa, idx)) try self.emit(
                    .anchor_missing,
                    self.tree.spanOf(idx),
                    "a (midi/mtrk …) with no (midi/smf …) before it belongs to no dump",
                    .{},
                ),
            }
        }
        return p;
    }

    /// The header: one `(timeline …)`, and the document's first root.
    /// Every complaint is said and the first one is read regardless —
    /// the walk is total.
    fn readTimeline(
        self: *Ctx,
        doc: *Doc.Doc,
        forest: []const NodeIndex,
        timelines: []const NodeIndex,
    ) Error!void {
        if (timelines.len == 0) {
            try self.emit(
                .timeline_missing,
                .{ .start = 0, .end = 0 },
                "the document has no (timeline …) root",
                .{},
            );
            return;
        }
        for (timelines[1..]) |extra| {
            try self.emit(
                .timeline_duplicate,
                self.tree.spanOf(extra),
                "a second (timeline …) root; there is one per document",
                .{},
            );
        }
        if (!(forest.len > 0 and forest[0] == timelines[0])) {
            try self.emit(
                .timeline_missing,
                self.tree.spanOf(timelines[0]),
                "(timeline …) is not the document's first root",
                .{},
            );
        }
        try self.readHeader(doc, timelines[0]);
    }

    /// A conducted document has one owner of time: every tempo or meter
    /// point of its own is `conductor_conflict`.
    fn conductorConflicts(
        self: *Ctx,
        tempo: []const NodeIndex,
        meter: []const NodeIndex,
    ) Error!void {
        for ([_][]const NodeIndex{ tempo, meter }) |set| {
            for (set) |idx| try self.emit(
                .conductor_conflict,
                self.tree.spanOf(idx),
                "this document names a :conductor, and a conducted document has one owner of time",
                .{},
            );
        }
    }

    /// `:length`, resolved where the walk always resolved it — after the
    /// lanes, so its complaint (if any) follows theirs.
    fn readLength(self: *Ctx, doc: *Doc.Doc, timeline: NodeIndex) Error!void {
        const children = self.tree.formHeader(timeline).children;
        const node = kvNode(self.tree, children, "length") orelse return;
        doc.length_lit = literalOf(self.tree, node);
        doc.length = try self.resolve(node);
    }

    fn walk(self: *Ctx, forest: []const NodeIndex) Error!Doc.Doc {
        var doc: Doc.Doc = .{ .arena = undefined };
        var roots = try self.partition(forest);
        defer roots.deinit(self.gpa);

        // ---- the header: one (timeline …), and the document's first ----
        try self.readTimeline(&doc, forest, roots.timelines.items);
        self.conductor = doc.conductor;
        self.end = doc.end;

        // ---- the two maps ----
        try self.readMeterPoints(roots.meter.items);
        try self.readTempoPoints(roots.tempo.items);
        doc.tempo = self.tempo;
        doc.meter = self.meter;
        if (self.conductor != null) {
            try self.conductorConflicts(roots.tempo.items, roots.meter.items);
        }

        // ---- the anchors and the dumps they pair with ----
        //
        // Both come BEFORE the provisional map, and neither needs one:
        // an anchor has no position on it and a dump's `:at` is its
        // file's own tick, never the document's grid. The map, on the
        // other hand, may need THEM — a conducted document's tempo and
        // meter come out of the tier (plan 03, "Three conductors").
        doc.anchors = try self.readAnchors(roots.anchors.items, roots.dumps_per_anchor.items);
        try self.readTiers(&doc, roots.dumps.items, roots.dump_roots.items, roots.anchors.items);
        // From here the tiers are the document's, and a failure anywhere
        // below would drop them with it: each owns a gpa-backed arena
        // the document's arena does not free.
        errdefer releaseTiers(&doc);
        try self.conductorTables(&doc);

        // ---- the provisional map, and everything that resolves on it ----
        var provisional = try self.derive(0);
        self.setMap(provisional.intoMap());
        defer self.dropMap();

        doc.sections = try self.readSections(roots.sections.items);
        doc.cues = try self.readCues(roots.cues.items);
        doc.phrases = try self.readPhrases(roots.phrases.items);
        doc.lanes = try self.readLanes(roots.lanes.items, &doc);
        doc.passthrough = try self.readPassthrough(roots.passthrough.items);
        if (roots.timelines.items.len > 0) try self.readLength(&doc, roots.timelines.items[0]);

        // ---- the relations that need the whole document ----
        // A clip's window is the other half of the `:length` default
        // rule ("the end of the last event OR CLIP"), so the check hands
        // back the furthest tick it saw.
        self.max_end = @max(self.max_end, try checks.clipPlacement(self.diags, &doc));
        try checks.laneNames(self.diags, &doc);
        try checks.sceneNames(self.diags, &doc);
        return doc;
    }

    /// The final map: the authored `:length`, or plan 02's default — the
    /// end of the last event or clip rounded UP to a bar.
    ///
    /// The round-up falls out of `barTable`'s own stopping rule, which
    /// appends bar starts until one lands at or past the length it was
    /// given, so the LAST entry of a table derived over `max_end` is
    /// exactly that bar line. This pass is also the only one whose
    /// diagnostics are forwarded: a defect in the tempo table is
    /// reported once, not once per derive.
    fn finalMap(self: *Ctx, doc: *const Doc.Doc) Error!TimeMap.TimeMap {
        const length = doc.length orelse len: {
            // A conducted document's events are its ANCHOR's, so the
            // file's own end counts alongside what the document placed
            // (`Conductor.end`). `time/derive.zig` adds the same two
            // terms, and its agreement test pins that the two layers
            // give one document one map.
            const content = @max(self.max_end, self.cond_end);
            if (content <= 0) break :len 0;
            var probe = try self.derive(content);
            defer probe.deinit();
            const bars = probe.map.bars;
            break :len if (bars.len == 0) content else bars[bars.len - 1];
        };

        var final = try self.derive(length);
        defer final.diags.deinit();
        for (final.diags.items()) |d| {
            try self.diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
        }
        return final.map;
    }

    /// `TimeMap.derive` over the document's own points.
    ///
    /// With a `:conductor` and no points of its own, the tables are
    /// SEEDED with 120 quarter notes per minute in `[4 4]`: plan 03 says
    /// the anchor conducts such a document, so its own map is a
    /// placeholder until the anchored half reads one — and a placeholder
    /// must not report the "needs a point at tick 0" defect that having
    /// a conductor is precisely the answer to.
    fn derive(self: *Ctx, length: i64) Error!Derived {
        const seeded_tempo = [_]Doc.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
        const seeded_meter = [_]Doc.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
        // The CONDUCTOR's tables win when there are any: an anchored
        // document's positions resolve against the file's own time, not
        // against the placeholder a conductorless one is seeded with.
        const tempo: []const Doc.TempoPoint = if (self.cond_live)
            self.cond_tempo
        else if (self.conductor != null and self.tempo.len == 0) &seeded_tempo else self.tempo;
        const meter: []const Doc.MeterPoint = if (self.cond_live)
            self.cond_meter
        else if (self.conductor != null and self.meter.len == 0) &seeded_meter else self.meter;

        const res = try TimeMap.derive(self.gpa, tempo, meter, length, self.end);
        return .{ .map = res.map, .diags = res.diags };
    }

    /// A map over the meter table alone, at 120 quarter notes per
    /// minute. Enough to answer a `bar` or a `b` literal, which is all a
    /// tempo or meter point's `:at` can be (plan 03 forbids `s` there).
    fn deriveMeters(self: *Ctx, meters: []const Doc.MeterPoint) Error!Derived {
        const res = try TimeMap.derive(self.gpa, &.{}, meters, 0, .hold);
        return .{ .map = res.map, .diags = res.diags };
    }

    // ---- the header ---------------------------------------------------

    fn readHeader(self: *Ctx, doc: *Doc.Doc, form: NodeIndex) Error!void {
        const children = self.tree.formHeader(form).children;
        if (kvNode(self.tree, children, "title")) |node| {
            doc.title = try self.text(node);
        }
        if (self.effSymbol(form, "end")) |name| {
            doc.end = std.meta.stringToEnum(TimeMap.End, name) orelse .hold;
        }
        if (kvNode(self.tree, children, "conductor")) |node| {
            doc.conductor = try self.symbol(node);
        }
        // `:length` needs the map, and the map needs the points — it is
        // read at the end of `walk`.
    }

    // ---- the two maps -------------------------------------------------

    fn readMeterPoints(self: *Ctx, forms: []const NodeIndex) Error!void {
        // Every point installs a working map of its own, and a failure
        // part-way through must not leave the last one behind.
        defer self.dropMap();
        var out: std.ArrayList(Doc.MeterPoint) = .empty;
        for (forms) |form| {
            // Each point's `:at` counts through the meters BEFORE it:
            // `32bar` under `[3 4]` is not 32 bars of `[4 4]`.
            var partial = try self.deriveMeters(out.items);
            self.setMap(partial.intoMap());

            const span = self.tree.spanOf(form);
            const tick = try self.gridTick(form) orelse continue;

            var n: u8 = 0;
            var d: u8 = 0;
            const children = self.tree.formHeader(form).children;
            if (kvNode(self.tree, children, "sig")) |node| {
                if (self.tree.tagOf(node) == .vector) {
                    const elems = self.tree.vectorElements(node);
                    if (elems.len == 2) {
                        n = castU8(readNumber(self.tree, elems[0]));
                        d = castU8(readNumber(self.tree, elems[1]));
                    }
                }
            }
            // A `:sig` that is not a meter still goes in: `TimeMap` is
            // the one place that says `meter_map_invalid`, and it says it
            // with this span.
            try out.append(self.arena, .{
                .tick = tick,
                .n = n,
                .d = d,
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        self.meter = try out.toOwnedSlice(self.arena);
    }

    fn readTempoPoints(self: *Ctx, forms: []const NodeIndex) Error!void {
        // A tempo point's `:at` counts through the METER map, which is
        // complete by now, and never through the tempo map itself.
        var meters_only = try self.deriveMeters(self.meter);
        self.setMap(meters_only.intoMap());
        defer self.dropMap();

        var out: std.ArrayList(Doc.TempoPoint) = .empty;
        for (forms) |form| {
            const span = self.tree.spanOf(form);
            const tick = try self.gridTick(form) orelse continue;
            const children = self.tree.formHeader(form).children;

            const tempo: @FieldType(Doc.TempoPoint, "tempo") = blk: {
                if (kvNode(self.tree, children, "us")) |node| {
                    break :blk .{ .us = castU32(readNumber(self.tree, node)) };
                }
                if (kvNode(self.tree, children, "qpm")) |node| {
                    break :blk .{ .qpm = readNumber(self.tree, node) orelse 0 };
                }
                // Neither key: SJON's exclusive group already said so,
                // and `TimeMap` turns the zero into `tempo_map_invalid`.
                break :blk .{ .us = 0 };
            };
            try out.append(self.arena, .{
                .tick = tick,
                .tempo = tempo,
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        self.tempo = try out.toOwnedSlice(self.arena);
    }

    /// A `grid-position` `:at` — `q`, `t`, `bar` or `b`, never `s`.
    ///
    /// The manifest already refuses the seconds unit on these two forms
    /// (`grid-position`'s `:allowed` list); the check is repeated here
    /// because this is the rule's home: seconds are derived FROM this
    /// map, so a seconds position on the form that defines it is
    /// circular, and tempura says so in its own vocabulary too.
    fn gridTick(self: *Ctx, form: NodeIndex) Error!?i64 {
        const children = self.tree.formHeader(form).children;
        const node = kvNode(self.tree, children, "at") orelse return null;
        if (literalOf(self.tree, node)) |lit| {
            if (lit.unit == .s) {
                try self.emit(
                    .unit_required,
                    self.tree.spanOf(node),
                    "a tempo or meter point is never placed in seconds: seconds are what this " ++
                        "map defines",
                    .{},
                );
                return null;
            }
        }
        return self.resolve(node);
    }

    // ---- anchors ------------------------------------------------------

    fn readAnchors(self: *Ctx, forms: []const NodeIndex, dumps: []const u32) Error![]Doc.Anchor {
        var out: std.ArrayList(Doc.Anchor) = .empty;
        for (forms, dumps) |form, dump_count| {
            const children = self.tree.formHeader(form).children;
            const span = self.tree.spanOf(form);

            const id_node = kvNode(self.tree, children, "id") orelse continue;
            const id = try self.symbol(id_node);
            const kind_name = if (kvNode(self.tree, children, "kind")) |n|
                if (self.tree.tagOf(n) == .symbol) self.tree.symbolText(n) else ""
            else
                "";
            const file = if (kvNode(self.tree, children, "file")) |n| try self.text(n) else "";
            // `:size` is a USER number and the schema's bounds are not a
            // cast's: `1e30` has no `u64` to be truncated to, and an
            // `@intFromFloat` past the range is a panic on user input
            // (the root contract forbids one). Saturating instead, with
            // `bridge_it.castInt` — the doc layer's one such reader — so
            // an impossible `:size` cannot match the file's length and
            // comes back as `anchor_mismatch` with a span.
            const size: ?u64 = if (kvNode(self.tree, children, "size")) |n|
                if (readNumber(self.tree, n)) |v| bridge_it.castInt(u64, v, 0) else null
            else
                null;
            const sha_src: ?[]const u8 = if (kvNode(self.tree, children, "sha256")) |n|
                try self.text(n)
            else
                null;

            var anchor: Doc.Anchor = .{
                .id = id,
                .kind = std.meta.stringToEnum(Doc.AnchorKind, kind_name) orelse .smf,
                .file = file,
                .size = size,
                .sha256 = if (sha_src) |t| Resolver.parseDigest(t) else null,
                .sha256_src = sha_src,
                .inline_dump = dump_count > 0,
                .resolved = false,
                .span = .{ .start = span.start, .end = span.end },
            };
            try checks.anchorBytes(self.diags, &anchor, self.resolver);
            try out.append(self.arena, anchor);
        }
        return out.toOwnedSlice(self.arena);
    }

    // ---- the inline tiers ---------------------------------------------

    /// Read each inline dump into its tier, paired with the anchor it
    /// follows (plan 02, "(anchor …)": the pairing is positional).
    ///
    /// Both bridges take a TREE and hand back a value with its own
    /// report, which is forwarded here with the document's spans intact
    /// — the dump was validated as part of this document, so its spans
    /// already are document coordinates.
    fn readTiers(
        self: *Ctx,
        doc: *Doc.Doc,
        dumps: []const Dump,
        dump_roots: []const NodeIndex,
        anchor_forms: []const NodeIndex,
    ) Error!void {
        var midi: std.ArrayList(Doc.SmfTier) = .empty;
        var it: std.ArrayList(Doc.ItTier) = .empty;
        // A tier owns a GPA-backed arena of its own, which the document's
        // arena would not free: on the one failure a walk has, the tiers
        // read so far are released here.
        errdefer {
            for (midi.items) |*t| t.sequence.deinit();
            for (it.items) |*t| t.module.deinit();
        }

        for (dumps) |dump| {
            if (dump.anchor >= anchor_forms.len) continue;
            const anchor_form = anchor_forms[dump.anchor];
            const anchor_id = if (kvNode(
                self.tree,
                self.tree.formHeader(anchor_form).children,
                "id",
            )) |n|
                try self.symbol(n)
            else
                continue;
            const roots = dump_roots[dump.start..][0..dump.len];
            // Once per dump, before either bridge runs: the anchor's own
            // claim about its file is checked whether or not this tier
            // has offsets to honour against it.
            const anchor_bytes = try self.verifiedAnchorBytes(doc, anchor_id);

            switch (dump.kind) {
                .smf => {
                    var read = try bridge_smf.formsToSequence(self.gpa, self.tree, roots);
                    defer read.diags.deinit();
                    errdefer read.sequence.deinit();
                    for (read.diags.items()) |d| {
                        try self.diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
                    }
                    try midi.append(
                        self.arena,
                        .{ .anchor = anchor_id, .sequence = read.sequence },
                    );
                },
                .it => {
                    var read = try bridge_it.formsToModule(
                        self.gpa,
                        self.tree,
                        roots,
                        anchor_bytes,
                    );
                    defer read.diags.deinit();
                    errdefer read.module.deinit();
                    for (read.diags.items()) |d| {
                        try self.diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
                    }
                    try self.sourceAgrees(doc, anchor_id, read.source);
                    try it.append(self.arena, .{ .anchor = anchor_id, .module = read.module });
                },
            }
        }

        doc.midi = try midi.toOwnedSlice(self.arena);
        doc.it = try it.toOwnedSlice(self.arena);
    }

    /// The anchor's bytes, VERIFIED, or null — and a diagnostic at the
    /// anchor's span whenever they could not be.
    ///
    /// `checks.anchorBytes` deliberately leaves an anchor whose dump is
    /// INLINE alone, on the reading that such a dump "carries its own
    /// bytes and asks nothing of a filesystem". That is true of a
    /// `(midi/smf …)`, whose every byte is in the document, and false of
    /// an `(it/module …)`, which keeps each opaque body as a `(bin :at
    /// :len)` into the anchor's file (it 03, "The anchor": an offset "is
    /// only meaningful against this exact file"). Plan 02 admits no
    /// difference — `:size` and `:sha256` are "verified before any
    /// `(bin …)` or bound lane is honoured (`anchor_mismatch`, never a
    /// silent re-read)" — so an inline anchor is verified HERE, once, for
    /// either tier, and what could not be verified is said out loud
    /// rather than silently dropped.
    ///
    /// The one silence left is plan 02's own: with no resolver nothing
    /// was asked of anybody, so nothing is reported and no offset is
    /// honoured either.
    fn verifiedAnchorBytes(self: *Ctx, doc: *Doc.Doc, id: Doc.AnchorId) Error!?[]const u8 {
        var anchor: *Doc.Anchor = for (doc.anchors) |*a| {
            if (std.mem.eql(u8, a.id, id)) break a;
        } else return null;
        const r = self.resolver orelse return null;

        const bytes = r.read(anchor.file) orelse {
            try self.diags.add(
                .anchor_unavailable,
                .err,
                anchor.span,
                "no resolver could read \"{s}\", so this dump's offsets name nothing",
                .{anchor.file},
            );
            return null;
        };
        const size = anchor.size orelse {
            try self.diags.add(
                .anchor_mismatch,
                .err,
                anchor.span,
                "\"{s}\" was read, and this anchor declares no :size to check it against",
                .{anchor.file},
            );
            return null;
        };
        const digest = anchor.sha256 orelse {
            try self.diags.add(
                .anchor_mismatch,
                .err,
                anchor.span,
                "\"{s}\" was read, and this anchor declares no readable :sha256 to check it " ++
                    "against",
                .{anchor.file},
            );
            return null;
        };
        if (!Resolver.verify(bytes, size, digest)) {
            try self.diags.add(
                .anchor_mismatch,
                .err,
                anchor.span,
                "\"{s}\" is {d} bytes and does not match the declared :size {d} / :sha256; this " ++
                    "dump's offsets name a file that has changed",
                .{ anchor.file, bytes.len, size },
            );
            return null;
        }
        anchor.resolved = true;
        return bytes;
    }

    /// A hosted `(it/source …)` inside an inline module "is accepted when
    /// it agrees with the anchor and `anchor_conflict` when it does not"
    /// (plan 02, "(anchor …)"). Only the fields BOTH state are compared:
    /// a dump that omits one claims nothing about it.
    fn sourceAgrees(
        self: *Ctx,
        doc: *const Doc.Doc,
        id: Doc.AnchorId,
        source: ?bridge_it.Source,
    ) Error!void {
        const said = source orelse return;
        const anchor = doc.anchorById(id) orelse return;

        const disagreement: ?[]const u8 = blk: {
            if (said.file.len > 0 and anchor.file.len > 0 and
                !std.mem.eql(u8, said.file, anchor.file)) break :blk "file";
            if (said.size != null and anchor.size != null and
                said.size.? != anchor.size.?) break :blk "size";
            if (said.sha256) |a| if (anchor.sha256_src) |b| {
                if (!std.mem.eql(u8, a, b)) break :blk "sha256";
            };
            break :blk null;
        };
        if (disagreement) |what| try self.diags.add(
            .anchor_conflict,
            .err,
            said.span,
            "this module's own (source …) names a different :{s} than the (anchor :id {s} …) it " ++
                "is paired with",
            .{ what, id },
        );
    }

    // ---- the conductor ------------------------------------------------

    /// Build the conductor's tempo and meter tables out of the tier the
    /// `(timeline :conductor …)` names (plan 03, "Three conductors",
    /// rules 2 and 3).
    ///
    /// The tier is read when the anchor carries one, and the anchor's
    /// own VERIFIED BYTES are read when it conducts by reference — one
    /// owner, `conductorOf`, for both, because plan 03's rules draw no
    /// line there. Only a conductor nobody could produce at all keeps
    /// the placeholder, and that is an error rather than a silence.
    fn conductorTables(self: *Ctx, doc: *Doc.Doc) Error!void {
        const id = self.conductor orelse return;
        const anchor = doc.anchorById(id) orelse return;

        // A by-reference conductor's file, copied onto the DOCUMENT so
        // the layers above answer with this same one (`Doc`'s
        // `conductor_bytes`). `resolved` is the verdict `readAnchors`
        // already reached through `checks.anchorBytes`, so nothing is
        // verified twice and nothing is reported twice.
        var candidate: ?[]const u8 = null;
        if (!anchor.inline_dump and anchor.resolved) {
            if (self.resolver) |r| candidate = r.read(anchor.file);
        }

        var built: Conductor = (try conductorOf(self.gpa, doc, id, candidate)) orelse {
            // No conductor: the placeholder stays, and says so. Plan 03
            // makes no inline/by-reference distinction, so a conducted
            // document whose file is not here — or is here and is not a
            // file of that kind — is not merely an unresolved anchor:
            // every position it answers is 120 quarter notes per minute
            // in [4 4], and a score exported from it is wrong rather
            // than approximate.
            //
            // The two cases are told apart because the remedies differ:
            // a file that is absent is `tempura inline`'s business, and
            // a file that does not read is the wrong file.
            if (candidate == null) try self.diags.add(
                .anchor_unavailable,
                .err,
                anchor.span,
                "the anchor '{s}' conducts this document and its file ({s}) is not here, so " ++
                    "every position is the placeholder's 120 quarter notes per minute in [4 4]: " ++
                    "inline the tier (`tempura inline`) or hand the host the file",
                .{ id, anchor.file },
            ) else try self.diags.add(
                .anchor_unavailable,
                .err,
                anchor.span,
                "the anchor '{s}' conducts this document and its file ({s}) verifies but is not " ++
                    "a readable {t}, so every position is the placeholder's 120 quarter notes " ++
                    "per minute in [4 4]: `tempura inspect` says what those bytes are",
                .{ id, anchor.file, anchor.kind },
            );
            return;
        };
        defer built.deinit();
        // The bytes really do conduct, so they travel with the document:
        // `mapOf` and `time/derive.conduct` build these same tables off
        // them with no resolver of their own, and
        // `conductedPlaceholder` is then a field test rather than a
        // second read.
        if (candidate) |bytes| doc.conductor_bytes = try self.arena.dupe(u8, bytes);

        for (built.diags.items()) |d| {
            try self.diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
        }
        // Into the DOCUMENT's arena: the tables outlive the derivation
        // that made them, because every position in the document
        // resolves against them.
        self.cond_tempo = try self.arena.dupe(Doc.TempoPoint, built.tempo);
        self.cond_meter = try self.arena.dupe(Doc.MeterPoint, built.meter);
        self.cond_live = true;
        self.cond_end = built.end;
    }

    // ---- sections and cues --------------------------------------------

    fn readSections(self: *Ctx, forms: []const NodeIndex) Error![]Doc.Section {
        var out: std.ArrayList(Doc.Section) = .empty;
        for (forms) |form| {
            const children = self.tree.formHeader(form).children;
            const span = self.tree.spanOf(form);

            const name_node = kvNode(self.tree, children, "name") orelse continue;
            const at_node = kvNode(self.tree, children, "at") orelse continue;
            const dur_node = kvNode(self.tree, children, "dur") orelse continue;
            const at = (try self.resolve(at_node)) orelse continue;
            const dur = (try self.duration(dur_node, at)) orelse continue;

            try out.append(self.arena, .{
                .name = try self.symbol(name_node),
                .at = at,
                .dur = dur,
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        return out.toOwnedSlice(self.arena);
    }

    fn readCues(self: *Ctx, forms: []const NodeIndex) Error![]Doc.Cue {
        var out: std.ArrayList(Doc.Cue) = .empty;
        for (forms) |form| {
            const children = self.tree.formHeader(form).children;
            const span = self.tree.spanOf(form);

            const name_node = kvNode(self.tree, children, "name") orelse continue;
            const at_node = kvNode(self.tree, children, "at") orelse continue;
            const at = (try self.resolve(at_node)) orelse continue;

            try out.append(self.arena, .{
                .name = try self.text(name_node),
                .at = at,
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        return out.toOwnedSlice(self.arena);
    }

    // ---- lanes --------------------------------------------------------

    fn readLanes(self: *Ctx, forms: []const NodeIndex, doc: *const Doc.Doc) Error![]Doc.Lane {
        var out: std.ArrayList(Doc.Lane) = .empty;
        for (forms) |form| {
            try out.append(self.arena, try self.readLane(form, doc));
        }
        return out.toOwnedSlice(self.arena);
    }

    /// One `(lane …)`. `doc` is the document the lane's `:from` joins
    /// against, and `null` marks a lane INSIDE A PHRASE — the difference
    /// plan 02 draws: a phrase's lanes carry content only, so `:from`
    /// there is `phrase_lane_bound`, a `(clip …)` inside one is
    /// `clip_nested`, and `:target` is ignored because the placing
    /// lane's target applies.
    fn readLane(self: *Ctx, form: NodeIndex, doc: ?*const Doc.Doc) Error!Doc.Lane {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const span = tree.spanOf(form);
        const in_phrase = doc == null;

        const name = if (kvNode(tree, children, "name")) |n| try self.symbol(n) else "";
        const kind: Doc.LaneKind = if (self.effSymbol(form, "kind")) |k|
            std.meta.stringToEnum(Doc.LaneKind, k) orelse .notes
        else
            .notes;
        const target = if (in_phrase)
            name
        else if (kvNode(tree, children, "target")) |n|
            try self.symbol(n)
        else
            name;

        var lane: Doc.Lane = .{
            .name = name,
            .kind = kind,
            .target = target,
            .range = null,
            .binding = null,
            .notes = &.{},
            .keyframes = &.{},
            .clips = &.{},
            .query_src = null,
            .expr_src = null,
            .span = .{ .start = span.start, .end = span.end },
        };
        switch (kind) {
            .curve => lane.range = rangeOf(tree, children),
            .query => if (kvNode(tree, children, "query")) |node| {
                lane.query_src = try self.slice(node);
            },
            .formula => if (kvNode(tree, children, "expr")) |node| {
                lane.expr_src = try self.slice(node);
            },
            .notes => {},
        }

        // ---- the binding ----
        const from = kvNode(tree, children, "from");
        lane.binding = try self.laneBinding(form, from, kind, doc);

        // ---- a native curve lane's own controller ----
        // `:cc` without `:from` is the controller a `.mid` build renders
        // the keyframes onto (plan 08: "`--cc` or the lane's `:cc`");
        // bound, the same key is the address inside the binding above.
        if (kind == .curve and from == null) lane.cc = ccAddress(tree, children);

        // ---- the children ----
        const content = try self.laneContent(children, in_phrase);
        if (content.forms > 0 and from != null and !in_phrase) {
            try self.emit(
                .bound_lane_has_content,
                span,
                "this lane reads its content from an anchor, and content has one home",
                .{},
            );
        }
        lane.notes = content.notes;
        lane.keyframes = content.keyframes;
        lane.clips = content.clips;

        try checks.noteOverlap(self.diags, &lane);
        return lane;
    }

    /// A lane's `:from` as its binding, or null with the reason said: a
    /// phrase's lane cannot bind (`phrase_lane_bound`), a computed lane
    /// cannot (`bound_kind_invalid`), and an address the anchor's kind
    /// does not admit is `readBinding`'s `address_invalid`. With no
    /// `:from`, the one address key a NATIVE lane may carry is checked
    /// instead: its `:ch` is one channel, never a set. `doc` is null
    /// inside a phrase, as `readLane` has it.
    fn laneBinding(
        self: *Ctx,
        form: NodeIndex,
        from: ?NodeIndex,
        kind: Doc.LaneKind,
        doc: ?*const Doc.Doc,
    ) Error!?Doc.Binding {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const span = tree.spanOf(form);
        if (from) |node| {
            const d = doc orelse {
                try self.emit(
                    .phrase_lane_bound,
                    span,
                    "a phrase's lanes carry content only; " ++
                        ":from belongs on the lane that places the phrase",
                    .{},
                );
                return null;
            };
            if (kind == .query or kind == .formula) {
                try self.emit(
                    .bound_kind_invalid,
                    span,
                    "a {t} lane computes its content and cannot read it from an anchor",
                    .{kind},
                );
                return null;
            }
            return self.readBinding(form, node, kind, d);
        }
        // A NATIVE lane's `:ch` is the one channel its notes default to
        // (the manifest's own description of `note`'s `:ch`), and a set
        // is not a default: a note sounds on one channel. The vector
        // spelling belongs to a bound lane alone — it is what a dump
        // writes for a lane that was rendered on several channels — and
        // the manifest, which types the key once for both shapes of
        // lane, cannot say so.
        const ch = kvNode(tree, children, "ch") orelse return null;
        if (tree.tagOf(ch) == .vector) try self.emit(
            .address_invalid,
            span,
            "a native lane's :ch is one channel, the default its notes take; " ++
                ":ch {s} names a set, which only a lane bound with :from reads",
            .{try self.slice(ch)},
        );
        return null;
    }

    /// What a lane's child forms hold. `forms` counts every child FORM,
    /// read or not, because that count — not what survived reading — is
    /// what `bound_lane_has_content` is about.
    const LaneContent = struct {
        notes: []Doc.Note,
        keyframes: []Doc.Keyframe,
        clips: []Doc.Clip,
        forms: usize,
    };

    fn laneContent(self: *Ctx, children: []const NodeIndex, in_phrase: bool) Error!LaneContent {
        const tree = self.tree;
        var notes: std.ArrayList(Doc.Note) = .empty;
        var keyframes: std.ArrayList(Doc.Keyframe) = .empty;
        var clips: std.ArrayList(Doc.Clip) = .empty;
        var forms: usize = 0;
        for (children) |child| {
            if (tree.tagOf(child) != .form) continue;
            const head = tree.formHeader(child).head;
            forms += 1;
            if (std.mem.eql(u8, head, "note")) {
                if (try self.readNote(child)) |n| try notes.append(self.arena, n);
            } else if (std.mem.eql(u8, head, "keyframe")) {
                if (try self.readKeyframe(child)) |k| try keyframes.append(self.arena, k);
            } else if (std.mem.eql(u8, head, "clip")) {
                if (in_phrase) {
                    try self.emit(
                        .clip_nested,
                        tree.spanOf(child),
                        "a phrase's lane places nothing: " ++
                            "a clip inside one would nest a phrase in a phrase",
                        .{},
                    );
                } else if (try self.readClip(child)) |c| {
                    try clips.append(self.arena, c);
                }
            }
        }
        return .{
            .notes = try notes.toOwnedSlice(self.arena),
            .keyframes = try keyframes.toOwnedSlice(self.arena),
            .clips = try clips.toOwnedSlice(self.arena),
            .forms = forms,
        };
    }

    /// The address keys against the anchor's KIND (plan 02,
    /// `address_invalid`) — the one thing the schema cannot see, because
    /// it validates the lane and the anchor one at a time. An anchor no
    /// form declares is SJON's `not_cross_ref` and nothing is added.
    fn readBinding(
        self: *Ctx,
        form: NodeIndex,
        from: NodeIndex,
        lane_kind: Doc.LaneKind,
        doc: *const Doc.Doc,
    ) Error!?Doc.Binding {
        const id = try self.symbol(from);
        const anchor = doc.anchorById(id) orelse return null;
        return switch (anchor.kind) {
            .smf => self.smfBinding(form, anchor, lane_kind),
            .it => self.itBinding(form, anchor, lane_kind),
        };
    }

    /// A binding to a Standard MIDI File: `:track` and `:ch`, a `:key`
    /// for a drum lane, and for a curve lane exactly one of the four
    /// surfaces.
    fn smfBinding(
        self: *Ctx,
        form: NodeIndex,
        anchor: *const Doc.Anchor,
        lane_kind: Doc.LaneKind,
    ) Error!?Doc.Binding {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const span = tree.spanOf(form);
        const id = anchor.id;
        if (try self.foreignKeys(
            children,
            span,
            id,
            &.{ "channel", "column", "fx" },
            ":{s} addresses an Impulse Tracker module, and \"{s}\" is a Standard MIDI File",
        )) return null;
        const track_node = kvNode(tree, children, "track");
        const ch_node = kvNode(tree, children, "ch");
        if (track_node == null or ch_node == null) {
            try self.emit(
                .address_invalid,
                span,
                "a lane bound to the SMF anchor \"{s}\" names :track and :ch",
                .{id},
            );
            return null;
        }
        const curve = smfSurface(tree, children);
        // The manifest's exclusive group is AT-MOST-ONE by design,
        // because a native curve lane carries keyframes and addresses
        // nothing. The at-least-one half only holds once the lane is
        // bound and the anchor's kind is known, which is two forms and
        // therefore host-side: a bound SMF curve lane reads exactly one
        // of the four surfaces on its channel, and a lane that names
        // none has no content to read.
        if (lane_kind == .curve and curve == null) {
            try self.emit(
                .address_invalid,
                span,
                "a curve lane bound to the SMF anchor \"{s}\" reads one of " ++
                    ":cc, :bend, :pressure or :velocity",
                .{id},
            );
            return null;
        }
        const chs = (try self.channelSet(ch_node.?, span, id)) orelse return null;
        return .{ .anchor = anchor.id, .address = .{ .smf = .{
            .track = castU16(readNumber(tree, track_node.?)),
            .ch = chs,
            .key = if (kvNode(tree, children, "key")) |n| try self.noteKey(n) else null,
            .curve = curve,
        } } };
    }

    /// A binding to an Impulse Tracker module: `:channel`, and for a
    /// curve lane one `:column`, with its `:fx` letter when the column
    /// is `fx`.
    fn itBinding(
        self: *Ctx,
        form: NodeIndex,
        anchor: *const Doc.Anchor,
        lane_kind: Doc.LaneKind,
    ) Error!?Doc.Binding {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const span = tree.spanOf(form);
        const id = anchor.id;
        if (try self.foreignKeys(
            children,
            span,
            id,
            &.{ "track", "ch", "cc", "bend", "pressure", "velocity", "key" },
            ":{s} addresses a Standard MIDI File, and \"{s}\" is an Impulse Tracker module",
        )) return null;
        const channel_node = kvNode(tree, children, "channel") orelse {
            try self.emit(
                .address_invalid,
                span,
                "a lane bound to the IT anchor \"{s}\" names :channel",
                .{id},
            );
            return null;
        };
        const column = itColumn(tree, children);
        // The mirror of the SMF surface check: a bound IT curve lane
        // "reads one column" (plan 02, "(lane …)"), and the manifest
        // cannot say so because `:column` is legal on a NATIVE curve
        // lane's sibling keys and the anchor's kind is a second form
        // away.
        if (lane_kind == .curve and column == null) {
            try self.emit(
                .address_invalid,
                span,
                "a curve lane bound to the IT anchor \"{s}\" reads one :column — vol, pan or fx",
                .{id},
            );
            return null;
        }
        return .{ .anchor = anchor.id, .address = .{ .it = .{
            .channel = wireChannel(u6, readNumber(tree, channel_node)),
            .column = column,
            .fx = itFx(tree, children),
        } } };
    }

    /// The first of `keys` present on the lane, said as `address_invalid`
    /// with `fmt` over the key and the anchor's id. These are the OTHER
    /// format's keys, which the schema cannot refuse because it sees the
    /// lane and the anchor one at a time. True when one was found.
    fn foreignKeys(
        self: *Ctx,
        children: []const NodeIndex,
        span: Ast.Span,
        id: []const u8,
        keys: []const []const u8,
        comptime fmt: []const u8,
    ) Error!bool {
        for (keys) |wrong| {
            if (kvNode(self.tree, children, wrong) == null) continue;
            try self.emit(.address_invalid, span, fmt, .{ wrong, id });
            return true;
        }
        return false;
    }

    /// A bound SMF lane's `:ch`: one channel (`:ch 2`) or a vector of
    /// several (`:ch [1 2]`), each through `wireChannel` exactly as the
    /// single always was, so `:ch [3]` and `:ch 3` are one address.
    ///
    /// The manifest already bounds each element to 1..16 and the vector
    /// to 1..16 elements; what it cannot see is that a set is a SET —
    /// an empty vector names no channel at all and a repeated one names
    /// a channel twice, and both are `address_invalid` here, with the
    /// lane's own span.
    fn channelSet(self: *Ctx, node: NodeIndex, span: Ast.Span, id: []const u8) Error!?Doc.Channels {
        const tree = self.tree;
        if (tree.tagOf(node) != .vector) {
            return Doc.Channels.single(wireChannel(u4, readNumber(tree, node)));
        }
        const elems = tree.vectorElements(node);
        if (elems.len == 0) {
            try self.emit(
                .address_invalid,
                span,
                "a lane bound to the SMF anchor \"{s}\" reads at least one channel, and :ch [] " ++
                    "names none",
                .{id},
            );
            return null;
        }
        var set: Doc.Channels = .none;
        for (elems) |e| {
            const c = wireChannel(u4, readNumber(tree, e));
            if (set.has(c)) {
                try self.emit(
                    .address_invalid,
                    span,
                    "a lane bound to the SMF anchor \"{s}\" names channel {d} twice in its :ch set",
                    .{ id, @as(u8, c) + 1 },
                );
                return null;
            }
            set = set.with(c);
        }
        return set;
    }

    fn readNote(self: *Ctx, form: NodeIndex) Error!?Doc.Note {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const span = tree.spanOf(form);

        const at_node = kvNode(tree, children, "at") orelse return null;
        const dur_node = kvNode(tree, children, "dur") orelse return null;
        const key_node = kvNode(tree, children, "key") orelse return null;
        const at = (try self.resolve(at_node)) orelse return null;
        const dur = (try self.duration(dur_node, at)) orelse return null;
        const key = (try self.noteKey(key_node)) orelse return null;
        self.max_end = @max(self.max_end, at +| dur);

        return .{
            .at = at,
            .dur = dur,
            .key = key,
            .vel = if (kvNode(
                tree,
                children,
                "vel",
            )) |n| castU7(readNumber(tree, n)) else default_vel,
            .ch = if (kvNode(
                tree,
                children,
                "ch",
            )) |n| wireChannel(u4, readNumber(tree, n)) else default_note_ch,
            .off_vel = if (kvNode(
                tree,
                children,
                "off-vel",
            )) |n| castU7(readNumber(tree, n)) else null,
            .span = .{ .start = span.start, .end = span.end },
        };
    }

    fn readKeyframe(self: *Ctx, form: NodeIndex) Error!?Doc.Keyframe {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const span = tree.spanOf(form);

        const at_node = kvNode(tree, children, "at") orelse return null;
        const at = (try self.resolve(at_node)) orelse return null;
        self.max_end = @max(self.max_end, at);

        var value: [4]f32 = .{ 0, 0, 0, 0 };
        var ncomp: u3 = 1;
        if (kvNode(tree, children, "value")) |node| {
            if (tree.tagOf(node) == .vector) {
                const elems = tree.vectorElements(node);
                const n = @min(elems.len, 4);
                ncomp = @intCast(@max(n, 1));
                for (elems[0..n], 0..) |e, i| value[i] = @floatCast(readNumber(tree, e) orelse 0);
            } else {
                value[0] = @floatCast(readNumber(tree, node) orelse 0);
            }
        }
        return .{
            .at = at,
            .value = value,
            .ncomp = ncomp,
            .ease_src = if (kvNode(tree, children, "ease")) |n| try self.slice(n) else default_ease,
            .span = .{ .start = span.start, .end = span.end },
        };
    }

    fn readClip(self: *Ctx, form: NodeIndex) Error!?Doc.Clip {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const span = tree.spanOf(form);

        const at_node = kvNode(tree, children, "at") orelse return null;
        const phrase_node = kvNode(tree, children, "phrase") orelse return null;
        const at = (try self.resolve(at_node)) orelse return null;

        // `:offset` is a position INTO the phrase and `:length` the
        // window measured from it, so both are durations and both are
        // anchored at this clip's own `:at` — the tick the phrase-local
        // time starts at on this timeline. The printer spells them with
        // the same anchor, which is what makes them read back exactly.
        const offset: i64 = if (kvNode(tree, children, "offset")) |n|
            (try self.duration(n, at)) orelse 0
        else
            0;
        const length: ?i64 = if (kvNode(tree, children, "length")) |n|
            try self.duration(n, at)
        else
            null;

        return .{
            .at = at,
            .phrase = try self.symbol(phrase_node),
            .repeat = if (kvNode(
                tree,
                children,
                "repeat",
            )) |n| castU32(readNumber(tree, n)) else default_repeat,
            .offset = offset,
            .length = length,
            .transpose = if (kvNode(
                tree,
                children,
                "transpose",
            )) |n| castI8(readNumber(tree, n)) else default_transpose,
            .span = .{ .start = span.start, .end = span.end },
        };
    }

    // ---- phrases ------------------------------------------------------

    fn readPhrases(self: *Ctx, forms: []const NodeIndex) Error![]Doc.Phrase {
        const tree = self.tree;
        var out: std.ArrayList(Doc.Phrase) = .empty;
        for (forms) |form| {
            const children = tree.formHeader(form).children;
            const span = tree.spanOf(form);
            const name_node = kvNode(tree, children, "name") orelse continue;
            // A phrase's `:length` is the one duration with no `:at` to
            // be measured from — the fragment starts where it starts, at
            // phrase-local tick 0 — so it resolves from the origin, which
            // is what anchoring it at 0 would give anyway.
            const length: i64 = if (kvNode(tree, children, "length")) |n|
                (try self.resolve(n)) orelse 0
            else
                0;

            var lanes: std.ArrayList(Doc.Lane) = .empty;
            for (children) |child| {
                if (tree.tagOf(child) != .form) continue;
                if (!std.mem.eql(u8, tree.formHeader(child).head, "lane")) continue;
                // A phrase's lanes are placed by a clip and sound only
                // where that clip puts them, so nothing inside one moves
                // `max_end` on its own — the clip does, in `checkClips`.
                const before = self.max_end;
                try lanes.append(self.arena, try self.readLane(child, null));
                self.max_end = before;
            }
            try out.append(self.arena, .{
                .name = try self.symbol(name_node),
                .length = length,
                .lanes = try lanes.toOwnedSlice(self.arena),
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        return out.toOwnedSlice(self.arena);
    }

    // ---- pass-through -------------------------------------------------

    fn readPassthrough(self: *Ctx, forms: []const NodeIndex) Error![]Doc.Passthrough {
        const tree = self.tree;
        var out: std.ArrayList(Doc.Passthrough) = .empty;
        for (forms) |form| {
            const hdr = tree.formHeader(form);
            const span = tree.spanOf(form);

            // tempura emits the transport and the tempo map itself
            // (plan 08, "Pass-through"), so a document that also says
            // them has two owners of one thing.
            if (std.mem.eql(u8, hdr.head, "transport") or std.mem.eql(u8, hdr.head, "tempo")) {
                try self.emit(
                    .passthrough_conducts,
                    span,
                    "tempura emits ({s} …) itself at export; a timeline document says tempo " ++
                        "with (tempo-point …)",
                    .{hdr.head},
                );
            }

            var comments: std.ArrayList([]const u8) = .empty;
            for (tree.commentSpans(tree.leading_comments_index[form.raw()])) |c| {
                try comments.append(
                    self.arena,
                    try self.arena.dupe(u8, self.source[c.start..c.end]),
                );
            }

            try out.append(self.arena, .{
                .head = try self.arena.dupe(u8, hdr.head),
                .text = try self.arena.dupe(u8, self.source[span.start..span.end]),
                .comments = try comments.toOwnedSlice(self.arena),
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        return out.toOwnedSlice(self.arena);
    }

    // ---- readers ------------------------------------------------------

    /// A position literal, resolved through the working map.
    fn resolve(self: *Ctx, node: NodeIndex) Error!?i64 {
        const lit = literalOf(self.tree, node) orelse {
            try self.emit(
                .unit_required,
                self.tree.spanOf(node),
                "a position needs a unit: q, t, bar, b or s",
                .{},
            );
            return null;
        };
        const answer = self.map.tickFromLiteral(lit) catch {
            try self.emit(
                .tick_overflow,
                self.tree.spanOf(node),
                "this position is not a point on the grid",
                .{},
            );
            return null;
        };
        switch (answer) {
            .tick => |t| return t,
            .err => |code| {
                try self.emit(
                    code,
                    self.tree.spanOf(node),
                    "this position is not a point on the grid",
                    .{},
                );
                return null;
            },
        }
    }

    /// A DURATION — `:dur`, `:offset`, a clip's `:length` — measured
    /// from the form's own `:at` (plan 03, "Positions").
    ///
    /// All five units go through `TimeMap.durationTicks`, which owns the
    /// anchoring: a `bar` lands in the bar it reaches rather than in the
    /// bar the origin's meter would have made it, a `b` is its beat
    /// twin, an `s` is wall-clock from `at`, and `q` / `t` are grid
    /// units that no anchor can change. Under one meter every answer is
    /// bit for bit the one the unanchored reader gives.
    ///
    /// The printer inverts exactly this, through
    /// `TimeMap.spellDuration` with the same `at`, which is what keeps
    /// the round trip an identity across a meter change.
    fn duration(self: *Ctx, node: NodeIndex, at: i64) Error!?i64 {
        const lit = literalOf(self.tree, node) orelse {
            try self.emit(
                .unit_required,
                self.tree.spanOf(node),
                "a duration needs a unit: q, t, bar, b or s",
                .{},
            );
            return null;
        };
        const answer = self.map.durationTicks(lit, at) catch {
            try self.emit(
                .tick_overflow,
                self.tree.spanOf(node),
                "this duration is not a span of the grid",
                .{},
            );
            return null;
        };
        switch (answer) {
            .tick => |t| return t,
            .err => |code| {
                try self.emit(
                    code,
                    self.tree.spanOf(node),
                    "this duration is not a span of the grid",
                    .{},
                );
                return null;
            },
        }
    }

    /// `:key`: the MIDI number, or the note name that reads better
    /// (`"C4"` is 60, sharps `#`, flats `b` — the midi set's convention,
    /// midi 02).
    fn noteKey(self: *Ctx, node: NodeIndex) Error!?u7 {
        if (self.tree.tagOf(node) != .string) return castU7(readNumber(self.tree, node));
        const spelling = self.tree.stringText(node);
        return parseNoteName(spelling) orelse {
            // The manifest types the slot as a string and says the
            // spelling is checked host-side, so this is the rule's home
            // and the message names the spelling it could not read.
            try self.emit(
                .note_key_invalid,
                self.tree.spanOf(node),
                "\"{s}\" is not a note name: a letter A-G, any number of # or b, then the octave",
                .{spelling},
            );
            return null;
        };
    }

    /// The effective `:key` on `form` as a symbol name — the author's,
    /// else the manifest's `:default`. GLOBAL forms only; see
    /// `default_vel`'s note for why the slot-locals cannot use this.
    fn effSymbol(self: *const Ctx, form: NodeIndex, key: []const u8) ?[]const u8 {
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |node| if (self.tree.tagOf(
                node,
            ) == .symbol) self.tree.symbolText(node) else null,
            .default => |entry| switch (entry.value) {
                .keyword => |k| k,
                .string => |s| s,
                else => null,
            },
        };
    }

    /// A string value, copied into the document's arena.
    fn text(self: *Ctx, node: NodeIndex) Error![]const u8 {
        if (self.tree.tagOf(node) != .string) return "";
        return self.arena.dupe(u8, self.tree.stringText(node));
    }

    /// A symbol value, copied into the document's arena.
    fn symbol(self: *Ctx, node: NodeIndex) Error![]const u8 {
        if (self.tree.tagOf(node) != .symbol) return "";
        return self.arena.dupe(u8, self.tree.symbolText(node));
    }

    /// A node's own SOURCE TEXT, copied — what `:ease`, `:query` and
    /// `:expr` keep, because those vocabularies are pacer's and SJON's
    /// and tempura carries them rather than re-spelling them.
    fn slice(self: *Ctx, node: NodeIndex) Error![]const u8 {
        const span = self.tree.spanOf(node);
        return self.arena.dupe(u8, self.source[span.start..span.end]);
    }
};

// ---------------------------------------------------------------------
// Free helpers
// ---------------------------------------------------------------------

// ---------------------------------------------------------------------
// The two file conductors (plan 03, "Three conductors", rules 2 and 3)
// ---------------------------------------------------------------------

/// A conductor's tables as a file states them, and what was odd about
/// the file. Arena-backed: `deinit` frees both tables and the report.
///
/// Public because a conductor is not only a document's: `tempura dump`
/// reads bytes into a `Sequence` or a `Module` and needs the same tables
/// with no `(timeline …)` anywhere in sight — which is also the only way
/// a SMPTE division ever reaches rule 2, since a dump carries the
/// CONVERTED PPQ and never the SMPTE word (plan 05, "Chunks").
pub const Conductor = struct {
    tempo: []Doc.TempoPoint,
    meter: []Doc.MeterPoint,
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,
    /// Where the anchored material ENDS, in ticks: the last event of
    /// the file for rule 2, the walk's total for rule 3. A conducted
    /// document's events are the anchor's, so this is the other half of
    /// plan 02's `:length` default for one — without it a document whose
    /// content is all in its file has a length of zero and a playhead
    /// that cannot leave tick 0.
    end: i64 = 0,
    /// The timing walk rule 3 built these tables from, for the caller
    /// that needs more of it than the tempo: the tracker position at a
    /// tick (`time/Playhead.orderRowAt`) and a bound lane's content both
    /// read it, and walking the module a second time to get it would be
    /// a second answer to a question with one. Null for an SMF
    /// conductor. `deinit` frees it; a caller that wants to keep it
    /// takes it out and leaves null behind.
    rowmap: ?itf.walk.RowMap = null,

    pub fn deinit(self: *Conductor) void {
        if (self.rowmap) |*r| r.deinit();
        self.diags.deinit();
        self.arena.deinit();
    }
};

/// The conductor's tables for the anchor named `id` — the ONE owner of
/// plan 03's rules 2 and 3 over a finished `Doc`.
///
/// Three layers ask this question: the load, while it is lowering the
/// source (`Ctx.conductorTables`); `mapOf`, for a consumer that holds a
/// document; and `time/derive.conduct`, for the derivation. Each used to
/// choose an arm for itself, and the by-reference arm was missing from
/// all three — a conducted anchor whose file the resolver had ALREADY
/// read and verified was timed by the placeholder, with no diagnostic
/// anywhere (the final review's C1). There is one arm-chooser now:
///
///   * the anchor's INLINE tier when the document carries one — the
///     `Sequence` / `Module` is right there;
///   * otherwise the anchor's own bytes, read into a transient
///     `Sequence` / `Module` and handed to the same two functions. Plan
///     02 makes a by-reference anchor first class and plan 03 draws no
///     line at all, so neither does this;
///   * `null` when neither is in hand, which is the only case that keeps
///     the placeholder (`conductedPlaceholder`).
///
/// `bytes` is `Doc.conductor_bytes`: verified against `:size` and
/// `:sha256` and copied into the document's arena while it was read, so
/// no caller here needs a resolver and no two callers can disagree.
///
/// The transient read is released before returning, which is sound
/// because `Conductor` copies both tables into an arena of its own and
/// an IT `RowMap` is arena-backed with nothing borrowed from the module
/// it walked.
///
/// A read that came back with an ERROR is `null` — those bytes are not a
/// readable file of the anchor's kind, whatever their `:size` and
/// `:sha256` say, and timing a document off the empty value a total
/// reader hands back would be worse than the placeholder. `:sha256`
/// answers "is this the file the document was written against"; it
/// cannot answer "is this a `.mid`". The reader's individual complaints
/// are NOT forwarded (they index the anchor's bytes, and a map is not
/// where a file is diagnosed — `tempura dump` and `tempura inspect`
/// are); the caller says `anchor_unavailable` naming the kind instead.
/// What matters for TIME on a file that DID read — format 2, an inexact
/// division, a walk past the ceiling — is said by `smfConductor` /
/// `itConductor` themselves.
///
/// Caller releases with `deinit()`.
pub fn conductorOf(
    gpa: Allocator,
    doc: *const Doc.Doc,
    id: Doc.AnchorId,
    bytes: ?[]const u8,
) Error!?Conductor {
    const anchor = doc.anchorById(id) orelse return null;
    for (doc.midi) |*tier| {
        if (std.mem.eql(u8, tier.anchor, id)) {
            return try smfConductor(gpa, &tier.sequence, anchor.span);
        }
    }
    for (doc.it) |*tier| {
        if (std.mem.eql(u8, tier.anchor, id)) {
            return try itConductor(gpa, &tier.module, anchor.span);
        }
    }
    const raw = bytes orelse return null;
    switch (anchor.kind) {
        .smf => {
            var read = try smf.read(gpa, raw);
            defer read.deinit();
            if (read.diags.hasErrors()) return null;
            return try smfConductor(gpa, &read.sequence, anchor.span);
        },
        .it => {
            var read = try itf.read.read(gpa, raw);
            defer read.deinit();
            if (read.diags.hasErrors()) return null;
            return try itConductor(gpa, &read.module, anchor.span);
        },
    }
}

/// Whether `doc` is conducted by an anchor whose time nobody could
/// produce: it names a `:conductor`, the anchor exists, and neither an
/// inline tier nor the anchor's verified bytes are here — so every
/// position the document answers is plan 03's placeholder (500 000
/// microseconds per quarter note in `[4 4]`) and not the file's.
///
/// One predicate, three readings of it: the load and `time/derive` raise
/// `anchor_unavailable` as an ERROR on it, and `tempura export-score`
/// refuses — a transport of `:bpm 120` under a header that names a
/// conductor is a wrong score, not a score with a warning. The states it
/// is FALSE for are the honest ones: an inline tier, a file that was read
/// and verified, and a document that conducts itself.
pub fn conductedPlaceholder(doc: *const Doc.Doc) bool {
    const id = doc.conductor orelse return false;
    if (doc.anchorById(id) == null) return false;
    if (doc.conductor_bytes != null) return false;
    for (doc.midi) |*tier| {
        if (std.mem.eql(u8, tier.anchor, id)) return false;
    }
    for (doc.it) |*tier| {
        if (std.mem.eql(u8, tier.anchor, id)) return false;
    }
    return true;
}

/// Rule 2: every `set-tempo` in EVERY track merged by tick, each `us` as
/// written, and `time-signature` likewise with `nn` and `2^dd` as
/// `[n d]`. Equal ticks keep file order and the last wins. SMF tick `k`
/// becomes `k · TPQ / PPQ`, exact or nearest with `division_inexact`
/// counted once for the whole dump.
///
/// A SMPTE file is ONE segment at 120 quarter notes per minute over the
/// converted PPQ — its ticks are wall-clock by definition and that
/// segment reproduces every one of them exactly — and its own tempo
/// events are kept in the dump and ignored for timing.
///
/// `span` is what every diagnostic carries: the anchor's, for a
/// document, and the caller's choice otherwise.
pub fn smfConductor(gpa: Allocator, seq: *const smf.Sequence, span: Diag.Span) Error!Conductor {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();
    const arena = arena_state.allocator();

    if (seq.format == 2) try diags.add(
        .smf_format2,
        .err,
        span,
        "a format 2 file's tracks are independent sequences, not simultaneous ones, " ++
            "so it conducts nothing",
        .{},
    );

    const ppq = seq.division.pulsesPerQuarter();
    const smpte = seq.division == .smpte;
    if (Grid.ticksPerSmfTick(ppq) == null) try diags.add(
        .division_inexact,
        .warning,
        span,
        "division {d} does not divide the grid, " ++
            "so every tick of this file lands on its nearest one",
        .{ppq},
    );

    var points = try smfPoints(arena, seq, span);
    if (points.ignored > 0) try diags.add(
        .smpte_tempo_ignored,
        .warning,
        span,
        "{d} set-tempo event(s) of a SMPTE file are kept in the dump and not believed: " ++
            "SMPTE ticks are wall-clock",
        .{points.ignored},
    );
    // The tempo the converted grid was derived for — 120 quarter notes
    // per minute, an integer, so the one SMPTE segment keeps plan 03's
    // integer path — and the number the writer and the bridge put on
    // every `set-tempo` of that grid (`Division.tempoOnGrid`): one owner.
    if (smpte) try points.tempo.append(arena, .{
        .tick = 0,
        .tempo = .{ .us = smf.Division.smpte_tempo_us },
        .span = span,
    });

    const tempo = try mergeByTick(arena, Doc.TempoPoint, points.tempo.items);
    const meter = try mergeByTick(arena, Doc.MeterPoint, points.meter.items);
    return .{
        .tempo = try seedTempo(arena, tempo, span),
        .meter = try seedMeter(arena, meter, span),
        .diags = diags,
        .arena = arena_state,
        .end = points.end,
    };
}

/// What rule 2 reads out of a sequence's tracks: every tempo and meter
/// event as a point on the converted grid, in file order; how many tempo
/// events a SMPTE file had (kept in the dump, not believed); and the
/// tick its last event lands on.
const SmfPoints = struct {
    tempo: std.ArrayList(Doc.TempoPoint) = .empty,
    meter: std.ArrayList(Doc.MeterPoint) = .empty,
    ignored: usize = 0,
    end: i64 = 0,
};

fn smfPoints(arena: Allocator, seq: *const smf.Sequence, span: Diag.Span) Error!SmfPoints {
    const ppq = seq.division.pulsesPerQuarter();
    const smpte = seq.division == .smpte;
    var out: SmfPoints = .{};
    for (seq.tracks) |track| {
        for (track.events) |e| {
            out.end = @max(out.end, Grid.smfToTicks(e.at, ppq).tick);
        }
        for (track.events) |e| switch (e.kind) {
            .set_tempo => {
                if (smpte) {
                    out.ignored += 1;
                    continue;
                }
                // Zero microseconds a quarter has no meaning and the
                // reader already said so with its own span.
                if (e.payload.tempo == 0) continue;
                try out.tempo.append(arena, .{
                    .tick = Grid.smfToTicks(e.at, ppq).tick,
                    .tempo = .{ .us = e.payload.tempo },
                    .span = span,
                });
            },
            .time_signature => {
                const t = e.payload.time_sig;
                try out.meter.append(arena, .{
                    .tick = Grid.smfToTicks(e.at, ppq).tick,
                    .n = t.nn,
                    // RP-001 writes the denominator as its power of two.
                    // Past `2^7` there is no byte to hold it, and past
                    // `32` no meter tempura admits — which `TimeMap`
                    // says with `meter_map_invalid` rather than this
                    // clamping the file into a lie.
                    .d = if (t.dd < 8) @as(u8, 1) << @intCast(t.dd) else 0,
                    .span = span,
                });
            },
            else => {},
        };
    }
    return out;
}

/// Rule 3: the timing walk. One segment per tempo change, in IT ticks
/// scaled by `Grid.IT_TICK`, and `qpm` IS the IT tempo (the
/// 24-ticks-per-quarter convention, plan 06). Bars come from the
/// module's highlight `[minor major]` as one `[major / minor, 4]` meter
/// point at tick 0, and `[4 4]` when the module states none.
pub fn itConductor(gpa: Allocator, module: *const itf.Module, span: Diag.Span) Error!Conductor {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();
    const arena = arena_state.allocator();

    var rowmap = try itf.walk.derive(gpa, module, .{});
    errdefer rowmap.deinit();
    for (rowmap.diags.items()) |d| {
        try diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
    }

    var tempo: std.ArrayList(Doc.TempoPoint) = .empty;
    var over = false;
    for (rowmap.segments) |seg| {
        // IT ticks times 1 921 920 in `i128`, so the grid's ceiling is a
        // CHECK and never a wrap: a module whose walk runs past it is
        // `tick_overflow` and the segments past it are dropped.
        const tick = @as(i128, seg.start_tick) * Grid.IT_TICK;
        if (tick > Grid.MAX_TICK) {
            over = true;
            break;
        }
        try tempo.append(arena, .{
            .tick = @intCast(tick),
            .tempo = .{ .qpm = @floatFromInt(seg.tempo) },
            .span = span,
        });
    }
    if (over) try diags.add(
        .tick_overflow,
        .err,
        span,
        "this module's walk reaches past the grid ceiling {d}; the tempo segments past it are " ++
            "dropped",
        .{Grid.MAX_TICK},
    );

    const h = module.header;
    const stated = (h.special & itf.model.special.highlight) != 0 and h.highlight_minor > 0;
    const beats: u16 = if (stated) h.highlight_major / h.highlight_minor else 0;
    // A highlight that does not divide into a meter tempura admits says
    // nothing about bars, and `[4 4]` is what every tracker shows.
    const n: u8 = if (beats >= 1 and beats <= 64) @intCast(beats) else 4;

    return .{
        .tempo = try seedTempo(arena, try mergeByTick(arena, Doc.TempoPoint, tempo.items), span),
        .meter = try arena.dupe(
            Doc.MeterPoint,
            &[_]Doc.MeterPoint{.{ .tick = 0, .n = n, .d = 4, .span = span }},
        ),
        .diags = diags,
        .arena = arena_state,
        .end = end: {
            const total = @as(i128, rowmap.total_ticks) * Grid.IT_TICK;
            break :end if (total > Grid.MAX_TICK) Grid.MAX_TICK else @intCast(total);
        },
        .rowmap = rowmap,
    };
}

/// Merge conductor points by tick — STABLE, so equal ticks keep the
/// order the tracks were read in, and the LAST of them wins (plan 03,
/// "Three conductors", rule 2).
fn mergeByTick(arena: Allocator, comptime T: type, points: []T) Error![]T {
    const Order = struct {
        fn before(_: void, x: T, y: T) bool {
            return x.tick < y.tick;
        }
    };
    std.mem.sort(T, points, {}, Order.before);

    var out: std.ArrayList(T) = .empty;
    for (points, 0..) |p, i| {
        if (i + 1 < points.len and points[i + 1].tick == p.tick) continue;
        try out.append(arena, p);
    }
    return out.toOwnedSlice(arena);
}

/// A conductor's table starts at tick 0 or it is not a map. A file with
/// no tempo event before its first note is playing at SMF's own default,
/// 120 quarter notes per minute, and saying so is not a guess.
fn seedTempo(arena: Allocator, points: []Doc.TempoPoint, span: Diag.Span) Error![]Doc.TempoPoint {
    if (points.len > 0 and points[0].tick == 0) return points;
    const out = try arena.alloc(Doc.TempoPoint, points.len + 1);
    out[0] = .{ .tick = 0, .tempo = .{ .us = 500_000 }, .span = span };
    @memcpy(out[1..], points);
    return out;
}

/// The same for the meter: a file with no time signature is in `[4 4]`,
/// which is what every sequencer shows it as.
fn seedMeter(arena: Allocator, points: []Doc.MeterPoint, span: Diag.Span) Error![]Doc.MeterPoint {
    if (points.len > 0 and points[0].tick == 0) return points;
    const out = try arena.alloc(Doc.MeterPoint, points.len + 1);
    out[0] = .{ .tick = 0, .n = 4, .d = 4, .span = span };
    @memcpy(out[1..], points);
    return out;
}

/// A head is this tier's when it is unqualified or carries the tier's
/// own namespace.
fn nsIs(ns: ?[]const u8, want: []const u8) bool {
    return ns == null or std.mem.eql(u8, ns.?, want);
}

/// Find a kvpair child by key name. O(children), like pacer's.
fn kvNode(tree: *const Ast.Tree, children: []const NodeIndex, key: []const u8) ?NodeIndex {
    for (children) |c| {
        if (tree.tagOf(c) != .kvpair) continue;
        const kv = tree.kvpairHeader(c);
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

/// Any numeric literal as f64, or null for a non-numeric tag.
fn readNumber(tree: *const Ast.Tree, idx: NodeIndex) ?f64 {
    return switch (tree.tagOf(idx)) {
        .number => tree.numberOf(idx),
        .number_i64 => @floatFromInt(tree.numberI64Of(idx)),
        .number_u64 => @floatFromInt(tree.numberU64Of(idx)),
        .number_with_unit => tree.numberWithUnitOf(idx).value,
        else => null,
    };
}

/// A `:key true` flag. SJON carries a boolean in the TAG, not the data.
fn boolAt(tree: *const Ast.Tree, children: []const NodeIndex, key: []const u8) bool {
    const node = kvNode(tree, children, key) orelse return false;
    return tree.tagOf(node) == .boolean_true;
}

/// A position literal from a `number_with_unit` node, or null when the
/// slot holds something else (a bare number, a symbol, a form).
fn literalOf(tree: *const Ast.Tree, node: NodeIndex) ?Pos.Literal {
    if (tree.tagOf(node) != .number_with_unit) return null;
    const nu = tree.numberWithUnitOf(node);
    const unit = std.meta.stringToEnum(Pos.Unit, nu.unit) orelse return null;
    return .{ .value = nu.value, .unit = unit };
}

/// Narrowing readers. Each is TOTAL: the manifest's bounds have already
/// been checked by the time a clean document gets here, and a document
/// SJON refused still has to lower without trapping.
fn castU8(v: ?f64) u8 {
    const x = v orelse return 0;
    return if (x >= 0 and x <= 255) @intFromFloat(x) else 0;
}

/// `:cc` as a curve lane spells it — one number, or `[msb lsb]` for a
/// 14-bit pair — or null when the key is absent or not one of those two
/// shapes. Read the same way for a bound lane's address and for a native
/// lane's own controller, so the two cannot disagree on a spelling.
fn ccAddress(tree: *const Ast.Tree, children: []const NodeIndex) ?Doc.SmfCurve {
    const node = kvNode(tree, children, "cc") orelse return null;
    if (tree.tagOf(node) == .vector) {
        const elems = tree.vectorElements(node);
        if (elems.len != 2) return null;
        return .{ .cc14 = .{
            castU7(readNumber(tree, elems[0])),
            castU7(readNumber(tree, elems[1])),
        } };
    }
    return .{ .cc = castU7(readNumber(tree, node)) };
}

/// `:range` as a curve lane spells it — `[lo hi]` — or null when the key
/// is absent or not a pair.
fn rangeOf(tree: *const Ast.Tree, children: []const NodeIndex) ?[2]f32 {
    const node = kvNode(tree, children, "range") orelse return null;
    if (tree.tagOf(node) != .vector) return null;
    const elems = tree.vectorElements(node);
    if (elems.len != 2) return null;
    return .{
        @floatCast(readNumber(tree, elems[0]) orelse 0),
        @floatCast(readNumber(tree, elems[1]) orelse 0),
    };
}

/// Which of the four SMF surfaces a bound curve lane names — `:cc` (one
/// number or a 14-bit pair), else the first of `:bend`, `:pressure` and
/// `:velocity` set true — or null when it names none.
fn smfSurface(tree: *const Ast.Tree, children: []const NodeIndex) ?Doc.SmfCurve {
    if (ccAddress(tree, children)) |c| return c;
    if (boolAt(tree, children, "bend")) return .bend;
    if (boolAt(tree, children, "pressure")) return .pressure;
    if (boolAt(tree, children, "velocity")) return .velocity;
    return null;
}

/// `:column` as one of the three IT columns, or null when absent or not
/// one of them.
fn itColumn(tree: *const Ast.Tree, children: []const NodeIndex) ?Doc.ItColumn {
    const n = kvNode(tree, children, "column") orelse return null;
    if (tree.tagOf(n) != .symbol) return null;
    return std.meta.stringToEnum(Doc.ItColumn, tree.symbolText(n));
}

/// `:fx` as its one ASCII letter, or null when absent or not exactly one
/// character.
fn itFx(tree: *const Ast.Tree, children: []const NodeIndex) ?u8 {
    const n = kvNode(tree, children, "fx") orelse return null;
    if (tree.tagOf(n) != .string) return null;
    const t = tree.stringText(n);
    return if (t.len == 1) t[0] else null;
}

fn castU7(v: ?f64) u7 {
    const x = v orelse return 0;
    return if (x >= 0 and x <= 127) @intFromFloat(x) else 0;
}

/// A `:track` that will not read answers 0 like every other narrowing
/// reader here, not 1: the manifest bounds `:track` to 1 and up, so 0 is
/// outside its domain and cannot be mistaken for the first track of the
/// file. (`wireChannel` is the one that answers 0 meaningfully — 0 is
/// channel 1 on the wire, the manifest's own floor.)
fn castU16(v: ?f64) u16 {
    const x = v orelse return 0;
    return if (x >= 0 and x <= 65535) @intFromFloat(x) else 0;
}

fn castU32(v: ?f64) u32 {
    const x = v orelse return 0;
    return if (x >= 0 and x <= 4_294_967_295) @intFromFloat(x) else 0;
}

fn castI8(v: ?f64) i8 {
    const x = v orelse return 0;
    return if (x >= -128 and x <= 127) @intFromFloat(x) else 0;
}

/// A 1-based display channel to its wire value. `:ch 1` is 0 and
/// `:channel 1` is 0 — the domains `u4` and `u6` name exactly.
fn wireChannel(comptime T: type, v: ?f64) T {
    const max: f64 = @floatFromInt(std.math.maxInt(T));
    const x = (v orelse 1) - 1;
    return if (x >= 0 and x <= max) @intFromFloat(x) else 0;
}

/// `"C4"` is 60: a letter A-G, any number of `#` or `b`, then the
/// octave, which may be negative (`"C-1"` is 0). Total — an unreadable
/// spelling answers null and the caller says so with a span.
fn parseNoteName(text: []const u8) ?u7 {
    if (text.len < 2) return null;
    const step: i32 = switch (std.ascii.toUpper(text[0])) {
        'C' => 0,
        'D' => 2,
        'E' => 4,
        'F' => 5,
        'G' => 7,
        'A' => 9,
        'B' => 11,
        else => return null,
    };
    var i: usize = 1;
    var accidental: i32 = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '#' => accidental += 1,
            'b' => accidental -= 1,
            else => break,
        }
    }
    if (i == text.len) return null;
    const octave = std.fmt.parseInt(i32, text[i..], 10) catch return null;
    const key = (octave + 1) * 12 + step + accidental;
    return if (key >= 0 and key <= 127) @intCast(key) else null;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// The smallest document every malformed fixture is built on: a header,
/// and the tempo and meter points a document with no conductor owes.
const preamble =
    \\(timeline)
    \\(tempo-point :at 0q :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\
;

/// Load `source` and require that `want` is among tempura's own
/// diagnostics. Prints the whole report when it is not, so a RED run
/// says what it got instead.
fn expectCode(source: [:0]const u8, want: Diag.Code) !void {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, source, null);
    defer res.deinit();

    for (res.diags.items()) |d| if (d.code == want) return;

    std.debug.print("\nexpected {t}, got {d} diagnostic(s):\n", .{ want, res.diags.items().len });
    for (res.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
    std.debug.print("source:\n{s}\n", .{source});
    return error.ExpectedDiagnosticMissing;
}

/// Load `source` and require SILENCE — no SJON diagnostic, no tempura
/// one. A valid document must not make the bridge talk.
fn expectClean(source: [:0]const u8) !void {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, source, null);
    defer res.deinit();
    if (res.diags.items().len == 0) return;

    std.debug.print(
        "\nexpected a clean document, got {d} diagnostic(s):\n",
        .{res.diags.items().len},
    );
    for (res.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
    std.debug.print("source:\n{s}\n", .{source});
    return error.UnexpectedDiagnostics;
}

test "fromSjon: the smallest document a timeline can be loads clean" {
    try expectClean(preamble);
}

test "fromSjon: a second (timeline …) is timeline_duplicate" {
    try expectCode(preamble ++ "(timeline :title \"again\")", .timeline_duplicate);
}

test "fromSjon: no (timeline …), or one that is not first, is timeline_missing" {
    try expectCode(
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
    , .timeline_missing);
    try expectCode(
        \\(cue :name "early" :at 0q)
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
    , .timeline_missing);
}

test "fromSjon: no conductor and no tempo point at tick 0 is tempo_map_invalid" {
    try expectCode(
        \\(timeline)
        \\(meter-point :at 0bar :sig [4 4])
    , .tempo_map_invalid);
}

test "fromSjon: no conductor and no meter point at tick 0 is meter_map_invalid" {
    try expectCode(
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
    , .meter_map_invalid);
}

test "fromSjon: a conductor plus the document's own points is conductor_conflict" {
    try expectCode(
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "x.it")
        \\(tempo-point :at 0q :qpm 120)
    , .conductor_conflict);
    try expectCode(
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "x.it")
        \\(meter-point :at 0bar :sig [4 4])
    , .conductor_conflict);
}

test "fromSjon: a conducted document owes no tempo or meter point of its own" {
    // The other side of `conductor_conflict`: the tick-0 requirement is
    // what the conductor answers, so a conducted document with no points
    // is not doubly wrong.
    //
    // The claim is exactly that and no wider: this anchor's file is not
    // in anybody's hands, which is its own error since the by-reference
    // conductor was fixed — and it is the one the document gets.
    const gpa = testing.allocator;
    var res = try load(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "x.it")
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.count(.tempo_map_invalid));
    try testing.expectEqual(@as(usize, 0), res.diags.count(.meter_map_invalid));
    try testing.expectEqual(@as(usize, 1), res.diags.items().len);
    try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_unavailable));
}

test "fromSjon: an inline dump with no anchor before it is anchor_missing" {
    try expectCode(preamble ++ "(it/module :title \"orphan\")", .anchor_missing);
}

test "fromSjon: two dumps for one anchor is anchor_dump_duplicate" {
    try expectCode(preamble ++
        \\(anchor :id song :kind it :file "x.it")
        \\(it/module :title "one")
        \\(it/module :title "two")
    , .anchor_dump_duplicate);
}

test "fromSjon: the positional pairing marks an anchor as carrying a dump" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble ++
        \\(anchor :id one :kind it :file "one.it")
        \\(it/module :title "one")
        \\(anchor :id two :kind it :file "two.it")
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.count(.anchor_missing));
    try testing.expectEqual(@as(usize, 0), res.diags.count(.anchor_dump_duplicate));
    try testing.expect(res.doc.anchorById("one").?.inline_dump);
    try testing.expect(!res.doc.anchorById("two").?.inline_dump);
    // …and the dump is READ into the tier the anchor names — one tier,
    // paired with the anchor it follows and not with the one after it.
    try testing.expectEqual(@as(usize, 1), res.doc.it.len);
    try testing.expectEqualStrings("one", res.doc.it[0].anchor);
    try testing.expectEqual(@as(usize, 0), res.doc.midi.len);
}

test "fromSjon: address keys that do not fit the anchor's kind are address_invalid" {
    // An IT anchor addressed the SMF way.
    try expectCode(preamble ++
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name kick :kind notes :from song :track 1 :ch 3)
    , .address_invalid);
    // An SMF anchor addressed the IT way.
    try expectCode(preamble ++
        \\(anchor :id song :kind smf :file "x.mid")
        \\(lane :name kick :kind notes :from song :channel 3)
    , .address_invalid);
    // An SMF anchor with no address at all.
    try expectCode(preamble ++
        \\(anchor :id song :kind smf :file "x.mid")
        \\(lane :name kick :kind notes :from song)
    , .address_invalid);
    // An IT anchor with no :channel.
    try expectCode(preamble ++
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name kick :kind notes :from song)
    , .address_invalid);
}

test "fromSjon: a bound SMF lane's :ch is one channel or a set of them" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble ++
        \\(anchor :id file :kind smf :file "x.mid")
        \\(lane :name kit :kind notes :from file :track 2 :ch [1 2])
        \\(lane :name one :kind notes :from file :track 2 :ch [3])
        \\(lane :name high :kind notes :from file :track 2 :ch [16 10])
    , null);
    defer res.deinit();
    try testing.expectEqual(@as(usize, 0), res.diags.items().len);

    // `[1 2]` is bits 0 and 1; `[3]` is exactly `:ch 3`; order in the
    // vector is nothing, the set is what is kept.
    try testing.expect(
        res.doc.lanes[0].binding.?.address.smf.ch.eql(Doc.Channels.single(0).with(1)),
    );
    try testing.expect(res.doc.lanes[1].binding.?.address.smf.ch.eql(.single(2)));
    try testing.expect(
        res.doc.lanes[2].binding.?.address.smf.ch.eql(Doc.Channels.single(9).with(15)),
    );

    // A set with nothing in it, or with a channel twice, is not an
    // address.
    try expectCode(preamble ++
        \\(anchor :id file :kind smf :file "x.mid")
        \\(lane :name kit :kind notes :from file :track 2 :ch [])
    , .address_invalid);
    try expectCode(preamble ++
        \\(anchor :id file :kind smf :file "x.mid")
        \\(lane :name kit :kind notes :from file :track 2 :ch [2 2])
    , .address_invalid);
    // …and a NATIVE lane's `:ch` is its notes' default, which a set
    // cannot be.
    try expectCode(preamble ++
        \\(lane :name kit :kind notes :ch [1 2]
        \\  (note :at 0bar :dur 1q :key 36))
    , .address_invalid);
    try expectClean(preamble ++
        \\(lane :name kit :kind notes :ch 2
        \\  (note :at 0bar :dur 1q :key 36))
    );
}

test "fromSjon: the two addresses that do fit read back as the wire values" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble ++
        \\(anchor :id file :kind smf :file "x.mid")
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name drum :kind notes :from file :track 2 :ch 10 :key "C4")
        \\(lane :name mod :kind curve :from file :track 2 :ch 1 :cc [1 33])
        \\(lane :name vol :kind curve :from song :channel 5 :column fx :fx "M")
    , null);
    defer res.deinit();
    try testing.expectEqual(@as(usize, 0), res.diags.items().len);

    const drum = res.doc.lanes[0].binding.?.address.smf;
    try testing.expectEqual(@as(u16, 2), drum.track);
    try testing.expect(drum.ch.eql(.single(9))); // :ch 10 is 9 on the wire
    try testing.expectEqual(@as(u7, 60), drum.key.?); // "C4"

    const mod = res.doc.lanes[1].binding.?.address.smf;
    try testing.expectEqual([2]u7{ 1, 33 }, mod.curve.?.cc14);

    const vol = res.doc.lanes[2].binding.?.address.it;
    try testing.expectEqual(@as(u6, 4), vol.channel); // :channel 5 is 4
    try testing.expectEqual(Doc.ItColumn.fx, vol.column.?);
    try testing.expectEqual(@as(u8, 'M'), vol.fx.?);
}

test "fromSjon: a bound lane with children is bound_lane_has_content" {
    try expectCode(preamble ++
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name kick :kind notes :from song :channel 3
        \\  (note :at 0q :dur 1q :key 36))
    , .bound_lane_has_content);
}

test "fromSjon: a query or formula lane that binds is bound_kind_invalid" {
    try expectCode(preamble ++
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name hats :kind query :from song :query (euclid 3 8 1))
    , .bound_kind_invalid);
    try expectCode(preamble ++
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name pulse :kind formula :from song :expr (sin beat))
    , .bound_kind_invalid);
}

test "fromSjon: two notes on one key overlapping in one lane are note_overlap" {
    try expectCode(preamble ++
        \\(lane :name flash :kind notes
        \\  (note :at 0q :dur 2q :key 36)
        \\  (note :at 1q :dur 2q :key 36))
    , .note_overlap);
}

test "fromSjon: notes that touch, or sit on different keys, do not overlap" {
    try expectClean(preamble ++
        \\(lane :name flash :kind notes
        \\  (note :at 0q :dur 1q :key 36)
        \\  (note :at 1q :dur 1q :key 36)
        \\  (note :at 0q :dur 2q :key 38))
    );
}

test "fromSjon: a clip on a phrase with no lane of that name is clip_lane_missing" {
    try expectCode(preamble ++
        \\(lane :name flash :kind notes
        \\  (clip :at 0q :phrase fill))
        \\(phrase :name fill :length 1bar
        \\  (lane :name glow
        \\    (note :at 0q :dur 1q :key 36)))
    , .clip_lane_missing);
}

test "fromSjon: a clip inside a phrase's lane is clip_nested" {
    try expectCode(preamble ++
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash
        \\    (clip :at 0q :phrase fill)))
    , .clip_nested);
}

test "fromSjon: :from inside a phrase's lane is phrase_lane_bound" {
    try expectCode(preamble ++
        \\(anchor :id song :kind it :file "x.it")
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash :from song :channel 3))
    , .phrase_lane_bound);
}

test "fromSjon: a pass-through (transport …) or (tempo …) is passthrough_conducts" {
    try expectCode(
        preamble ++ "(transport :bpm 120 :meter [4 4] :dur 16bar)",
        .passthrough_conducts,
    );
    try expectCode(preamble ++ "(tempo :at 0b :bpm 140)", .passthrough_conducts);
}

test "fromSjon: a (scene …) under a section's name is scene_duplicate" {
    try expectCode(preamble ++
        \\(section :name intro :at 0bar :dur 16bar)
        \\(scene :name intro :at 0b :dur 4b)
    , .scene_duplicate);
}

test "fromSjon: two sections of one name are scene_duplicate too" {
    try expectCode(preamble ++
        \\(section :name intro :at 0bar :dur 16bar)
        \\(section :name intro :at 16bar :dur 16bar)
    , .scene_duplicate);
}

test "fromSjon: a quoted pacer scene name is the same name as a section's" {
    // pacer types a scene's `:name` as a string, so the two spellings of
    // one name collide and the export would emit two scenes called the
    // same thing.
    try expectCode(preamble ++
        \\(section :name intro :at 0bar :dur 16bar)
        \\(scene :name "intro" :at 0b :dur 4b)
    , .scene_duplicate);
}

test "fromSjon: a scene under a name no section uses passes through in peace" {
    try expectClean(preamble ++
        \\(section :name intro :at 0bar :dur 16bar)
        \\(scene :name outro :at 0b :dur 4b)
    );
}

test "fromSjon: a negative position is position_negative" {
    try expectCode(preamble ++ "(cue :name \"before\" :at -1q)", .position_negative);
}

test "fromSjon: seconds on a tempo or meter point is unit_required" {
    try expectCode(
        \\(timeline)
        \\(tempo-point :at 0s :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
    , .unit_required);
    try expectCode(
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0s :sig [4 4])
    , .unit_required);
}

test "fromSjon: a note name that will not read is note_key_invalid" {
    // The manifest types `:key`'s string arm and says the spelling is
    // checked host-side, so the code is tempura's own and the message
    // names the octave it could not read.
    try expectCode(preamble ++
        \\(lane :name flash :kind notes
        \\  (note :at 0q :dur 1q :key "H9"))
    , .note_key_invalid);
}

test "fromSjon: two lanes of one name are lane_duplicate" {
    try expectCode(preamble ++
        \\(lane :name flash :kind notes)
        \\(lane :name flash :kind curve)
    , .lane_duplicate);
    // A phrase's lane shares the placing lane's name by design, and is a
    // different namespace.
    try expectClean(preamble ++
        \\(lane :name flash :kind notes
        \\  (clip :at 0q :phrase fill))
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash
        \\    (note :at 0q :dur 1q :key 38)))
    );
}

test "fromSjon: a bound SMF curve lane names one of the four surfaces" {
    // The manifest's group is at-most-one (a NATIVE curve lane addresses
    // nothing); the at-least-one half needs the anchor's kind and is
    // therefore host-side.
    try expectCode(preamble ++
        \\(anchor :id file :kind smf :file "x.mid")
        \\(lane :name mod :kind curve :from file :track 1 :ch 1)
    , .address_invalid);
    // With a surface it is fine, and a bound NOTES lane never needed one.
    try expectClean(preamble ++
        \\(anchor :id file :kind smf :file "x.mid")
        \\(lane :name mod :kind curve :from file :track 1 :ch 1 :bend true)
        \\(lane :name drum :kind notes :from file :track 1 :ch 10)
    );
}

test "fromSjon: a duration is measured from its own :at, across a meter change" {
    // Plan 03, "Positions": a duration is a position measured from the
    // form's own `:at`. Bars 0 and 1 are [3 4]; bar 2 on is [4 4].
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema,
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [3 4])
        \\(meter-point :at 2bar :sig [4 4])
        \\(section :name intro :at 0bar :dur 1bar)
        \\(section :name drop :at 2bar :dur 1bar)
        \\(lane :name flash :kind notes
        \\  (note :at 2bar :dur 1bar :key 36))
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    // Three quarters in the first bar…
    try testing.expectEqual(@as(i64, 3 * Grid.TPQ), res.doc.sections[0].dur);
    // …and FOUR in the third, which counting from the origin got wrong.
    try testing.expectEqual(@as(i64, 4 * Grid.TPQ), res.doc.sections[1].dur);
    try testing.expectEqual(@as(i64, 4 * Grid.TPQ), res.doc.lanes[0].notes[0].dur);
}

test "fromSjon: an s duration is wall-clock from its own :at" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // 120 quarter notes per minute to bar 1, then 240: a second is two
    // quarters in the first segment and four in the second.
    var res = try fromSource(gpa, &schema,
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(tempo-point :at 4q :qpm 240)
        \\(meter-point :at 0bar :sig [4 4])
        \\(section :name a :at 0bar :dur 1s)
        \\(section :name b :at 1bar :dur 1s)
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expectEqual(@as(i64, 2 * Grid.TPQ), res.doc.sections[0].dur);
    try testing.expectEqual(@as(i64, 4 * Grid.TPQ), res.doc.sections[1].dur);
}

test "fromSjon: a position past the grid ceiling is tick_overflow" {
    try expectCode(preamble ++ "(cue :name \"far\" :at 1e30q)", .tick_overflow);
}

test "fromSjon: a meter change off a bar line is meter_off_bar" {
    try expectCode(
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(meter-point :at 1q :sig [3 4])
    , .meter_off_bar);
}

test "fromSjon: a resolver that cannot read an anchor says anchor_unavailable" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const table: Resolver.Memory = .{ .entries = &.{} };
    var res = try fromSource(
        gpa,
        &schema,
        preamble ++ "(anchor :id song :kind it :file \"absent.it\")",
        Resolver.memory(&table),
    );
    defer res.deinit();

    try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_unavailable));
    try testing.expect(!res.doc.anchors[0].resolved);
}

test "fromSjon: with no resolver a by-reference anchor is recorded, unresolved and silent" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble ++
        \\(anchor :id song :kind it :file "absent.it")
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expect(!res.doc.anchors[0].resolved);
    try testing.expect(!res.doc.anchors[0].inline_dump);
}

test "fromSjon: bytes that disagree with :size / :sha256 are anchor_mismatch" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const table: Resolver.Memory = .{ .entries = &.{
        .{ .path = "x.it", .bytes = "IMPMbytes" },
    } };
    var res = try fromSource(
        gpa,
        &schema,
        preamble ++
            \\(anchor :id song :kind it :file "x.it" :size 3 :sha256 "9f2a00000000000000000000000000000000000000000000000000000000abcd")
        ,
        Resolver.memory(&table),
    );
    defer res.deinit();

    try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_mismatch));
    try testing.expect(!res.doc.anchors[0].resolved);
}

test "fromSjon: an anchor with no :size / :sha256 is anchor_mismatch once its bytes are read" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const table: Resolver.Memory = .{ .entries = &.{
        .{ .path = "x.it", .bytes = "IMPMbytes" },
    } };
    var res = try fromSource(
        gpa,
        &schema,
        preamble ++ "(anchor :id song :kind it :file \"x.it\")",
        Resolver.memory(&table),
    );
    defer res.deinit();

    try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_mismatch));
}

test "fromSjon: bytes that match are honoured and the anchor is resolved" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const bytes = "IMPMbytes";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});

    const source = try std.fmt.allocPrintSentinel(gpa, preamble ++
        \\(anchor :id song :kind it :file "x.it" :size {d} :sha256 "{s}")
    , .{ bytes.len, hex[0..] }, 0);
    defer gpa.free(source);

    const table: Resolver.Memory = .{ .entries = &.{.{ .path = "x.it", .bytes = bytes }} };
    var res = try fromSource(gpa, &schema, source, Resolver.memory(&table));
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expect(res.doc.anchors[0].resolved);
}

test "fromSjon: SJON's own complaints ride across as sjon_diagnostic" {
    // A cross-ref to an anchor no form declares is SJON's `not_cross_ref`
    // and stays SJON's — tempura never re-spells a rule the manifest
    // already says.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble ++
        \\(lane :name kick :kind notes :from nowhere :channel 3)
    , null);
    defer res.deinit();

    try testing.expect(res.diags.count(.sjon_diagnostic) > 0);
    var found = false;
    for (res.diags.items()) |d| {
        if (d.code == .sjon_diagnostic and std.mem.indexOf(
            u8,
            d.message,
            "nowhere",
        ) != null) found = true;
    }
    try testing.expect(found);
}

test "fromSjon: :length is the authored spelling AND the resolved tick" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema,
        \\(timeline :title "impulsos" :length 128bar :end loop)
        \\(tempo-point :at 0q :qpm 125)
        \\(meter-point :at 0bar :sig [4 4])
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expectEqualStrings("impulsos", res.doc.title.?);
    try testing.expectEqual(TimeMap.End.loop, res.doc.end);
    try testing.expectEqual(@as(i64, 128 * 4 * Grid.TPQ), res.doc.length.?);
    try testing.expectEqual(Pos.Unit.bar, res.doc.length_lit.?.unit);
    try testing.expectEqual(@as(f64, 128), res.doc.length_lit.?.value);
    try testing.expectEqual(@as(i64, 128 * 4 * Grid.TPQ), res.map.length);
}

test "fromSjon: an omitted :length is the last event rounded UP to a bar" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // The last note ends at 5 quarters, which is one quarter into bar 1
    // of [4 4] — so the length is bar 2, not bar 1 and not 5q.
    var res = try fromSource(gpa, &schema, preamble ++
        \\(lane :name flash :kind notes
        \\  (note :at 4q :dur 1q :key 36))
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expect(res.doc.length == null);
    try testing.expectEqual(@as(i64, 2 * 4 * Grid.TPQ), res.map.length);
}

test "fromSjon: an event that lands exactly on a bar line rounds to itself" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble ++
        \\(lane :name flash :kind notes
        \\  (note :at 0q :dur 8q :key 36))
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(i64, 2 * 4 * Grid.TPQ), res.map.length);
}

test "fromSjon: a clip's window reaches the length default through its phrase" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // One bar of phrase, placed at bar 2 and repeated twice: the last
    // thing the timeline holds ends at bar 4.
    var res = try fromSource(gpa, &schema, preamble ++
        \\(lane :name flash :kind notes
        \\  (clip :at 2bar :phrase fill :repeat 2))
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash
        \\    (note :at 0q :dur 1q :key 38)))
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expectEqual(@as(i64, 4 * 4 * Grid.TPQ), res.map.length);
}

test "fromSjon: the document with nothing in it has length 0" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble, null);
    defer res.deinit();
    try testing.expectEqual(@as(i64, 0), res.map.length);
}

test "fromSjon: positions resolve through the document's own map" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // [3 4] to bar 2, then [4 4]: bar 2 is at 6 quarters and `8b` is
    // beat 8, which is bar 2 plus 2 beats (beats 0..5 are in the two
    // [3 4] bars), at 8 quarters.
    var res = try fromSource(gpa, &schema,
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [3 4])
        \\(meter-point :at 2bar :sig [4 4])
        \\(cue :name "bar 2" :at 2bar)
        \\(cue :name "beat 8" :at 8b)
        \\(cue :name "second 1" :at 1s)
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expectEqual(@as(i64, 6 * Grid.TPQ), res.doc.cues[0].at);
    try testing.expectEqual(@as(i64, 8 * Grid.TPQ), res.doc.cues[1].at);
    // 120 quarter notes per minute: one second is two quarters.
    try testing.expectEqual(@as(i64, 2 * Grid.TPQ), res.doc.cues[2].at);
}

test "fromSjon: a meter point's :at counts through the meters before it" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema,
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [3 4])
        \\(meter-point :at 4bar :sig [4 4])
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    // Four bars of [3 4] is twelve quarters — not sixteen.
    try testing.expectEqual(@as(i64, 12 * Grid.TPQ), res.doc.meter[1].tick);
}

test "fromSjon: the tempo point's authored spelling survives" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema,
        \\(timeline)
        \\(tempo-point :at 0q :qpm 125)
        \\(tempo-point :at 64bar :us 400000)
        \\(meter-point :at 0bar :sig [4 4])
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expectEqual(Doc.Spelling.qpm, Doc.spellingOf(res.doc.tempo[0]));
    try testing.expectEqual(@as(f64, 125), res.doc.tempo[0].tempo.qpm);
    try testing.expectEqual(Doc.Spelling.us, Doc.spellingOf(res.doc.tempo[1]));
    try testing.expectEqual(@as(u32, 400_000), res.doc.tempo[1].tempo.us);
}

test "fromSjon: a lane's :target defaults to its own :name" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble ++
        \\(lane :name glow :kind curve
        \\  (keyframe :at 0q :value 0.2))
        \\(lane :name flash :kind notes :target strobe)
    , null);
    defer res.deinit();

    try testing.expectEqualStrings("glow", res.doc.lanes[0].target);
    try testing.expectEqualStrings("strobe", res.doc.lanes[1].target);
    // And an omitted `:ease` is the manifest's `linear`.
    try testing.expectEqualStrings("linear", res.doc.lanes[0].keyframes[0].ease_src);
}

test "fromSjon: :ease, :query and :expr keep their source text whole" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble ++
        \\(lane :name glow :kind curve
        \\  (keyframe :at 0q :value [0.1 0.2 0.3] :ease (spring :damping 0.5)))
        \\(lane :name hats :kind query :query (euclid 3 8 1))
        \\(lane :name pulse :kind formula :expr (sin (* beat 6.2832)))
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expectEqualStrings("(spring :damping 0.5)", res.doc.lanes[0].keyframes[0].ease_src);
    try testing.expectEqual(@as(u3, 3), res.doc.lanes[0].keyframes[0].ncomp);
    try testing.expectEqualStrings("(euclid 3 8 1)", res.doc.lanes[1].query_src.?);
    try testing.expectEqualStrings("(sin (* beat 6.2832))", res.doc.lanes[2].expr_src.?);
}

test "fromSjon: a pass-through root is kept verbatim, with the comments above it" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try fromSource(gpa, &schema, preamble ++
        \\; pacer's form, pass-through
        \\(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)
        \\(target :name glow :arity 1)
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expectEqual(@as(usize, 2), res.doc.passthrough.len);
    try testing.expectEqualStrings("control", res.doc.passthrough[0].head);
    try testing.expectEqualStrings(
        "(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)",
        res.doc.passthrough[0].text,
    );
    try testing.expectEqual(@as(usize, 1), res.doc.passthrough[0].comments.len);
    try testing.expectEqualStrings(
        "; pacer's form, pass-through",
        res.doc.passthrough[0].comments[0],
    );
}

test "fromSjon.parseNoteName: the midi set's convention, middle C is C4" {
    try testing.expectEqual(@as(u7, 60), parseNoteName("C4").?);
    try testing.expectEqual(@as(u7, 61), parseNoteName("C#4").?);
    try testing.expectEqual(@as(u7, 61), parseNoteName("Db4").?);
    try testing.expectEqual(@as(u7, 0), parseNoteName("C-1").?);
    try testing.expectEqual(@as(u7, 127), parseNoteName("G9").?);
    try testing.expectEqual(@as(u7, 69), parseNoteName("A4").?);
    try testing.expectEqual(@as(u7, 62), parseNoteName("C##4").?);

    try testing.expect(parseNoteName("H9") == null);
    try testing.expect(parseNoteName("C") == null);
    try testing.expect(parseNoteName("") == null);
    try testing.expect(parseNoteName("C#") == null);
    try testing.expect(parseNoteName("G10") == null); // past 127
    try testing.expect(parseNoteName("C-2") == null); // below 0
}

test "fromSjon: the slot-local defaults restated here are the manifest's" {
    // `note`, `keyframe` and `clip` are declared LOCAL to `(lane …)`, and
    // SJON's materialized-defaults overlay is keyed by a global form
    // lookup, so the four constants at the top of this file are the only
    // copy of those defaults in the repo. This is what keeps them from
    // drifting: the manifest is read back and compared.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const tempura = schema.preloaded.plugins[0];
    var lane: ?sjon.Plugin.FormSpec = null;
    for (tempura.forms) |f| {
        if (std.mem.eql(u8, f.name, "lane")) lane = f;
    }
    const locals = lane.?.local_forms;

    var seen: usize = 0;
    for (locals) |form| {
        for (form.keys) |key| {
            const d = key.default orelse continue;
            if (std.mem.eql(u8, form.name, "note") and std.mem.eql(u8, key.name, "vel")) {
                try testing.expectEqual(@as(f64, default_vel), d.number);
                seen += 1;
            } else if (std.mem.eql(u8, form.name, "keyframe") and
                std.mem.eql(u8, key.name, "ease"))
            {
                try testing.expectEqualStrings(default_ease, d.symbol);
                seen += 1;
            } else if (std.mem.eql(u8, form.name, "clip") and std.mem.eql(u8, key.name, "repeat")) {
                try testing.expectEqual(@as(f64, default_repeat), d.number);
                seen += 1;
            } else if (std.mem.eql(u8, form.name, "clip") and
                std.mem.eql(u8, key.name, "transpose"))
            {
                try testing.expectEqual(@as(f64, default_transpose), d.number);
                seen += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 4), seen);
}

// ---------------------------------------------------------------------
// The anchored half: the tiers, the conductors, the anchor's bytes
// ---------------------------------------------------------------------

/// Load `source` with a resolver and hand the whole result back. The
/// anchored tests read the map and the tiers, not just the report.
fn load(gpa: Allocator, source: [:0]const u8, resolver: ?Resolver.Resolver) !Result {
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    return fromSource(gpa, &schema, source, resolver);
}

/// A document conducted by an inline SMF dump whose tempo sits on the
/// SECOND track and whose meter is `[3 4]` — so a `bar` position is
/// three quarters and not four.
const conducted_smf =
    \\(timeline :conductor song)
    \\(anchor :id song :kind smf :file "x.mid")
    \\(midi/smf :format 1 :division 480)
    \\(midi/mtrk
    \\  (time-signature :at 0 :num 3 :denom 4 :clocks 24 :thirty-seconds 8)
    \\  (end-of-track :at 1920))
    \\(midi/mtrk
    \\  (set-tempo :at 0 :us 500000)
    \\  (set-tempo :at 960 :us 400000)
    \\  (end-of-track :at 1920))
    \\(cue :name "two" :at 1bar)
;

test "fromSjon: an inline (midi/smf …) reads into the tier its anchor names" {
    const gpa = testing.allocator;
    var res = try load(gpa, conducted_smf, null);
    defer res.deinit();

    for (res.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
    try testing.expectEqual(@as(usize, 0), res.diags.items().len);

    try testing.expectEqual(@as(usize, 1), res.doc.midi.len);
    try testing.expectEqualStrings("song", res.doc.midi[0].anchor);
    // The header root and BOTH `(midi/mtrk …)` roots are one dump.
    try testing.expectEqual(@as(usize, 2), res.doc.midi[0].sequence.tracks.len);
    try testing.expect(res.doc.anchorById("song").?.inline_dump);
}

test "fromSjon: an SMF conductor's tempo is honoured on any track, and its meter rules bars" {
    const gpa = testing.allocator;
    var res = try load(gpa, conducted_smf, null);
    defer res.deinit();

    // Two segments, the second from the track that carries no meter:
    // "tempo on any track is honoured" (plan 03, rule 2).
    try testing.expectEqual(@as(usize, 2), res.map.segments.len);
    try testing.expectEqual(@as(i64, 0), res.map.segments[0].tick);
    try testing.expectEqual(@as(f64, 500_000), res.map.segments[0].us);
    // 960 SMF ticks at 480 PPQ is two quarter notes.
    try testing.expectEqual(@as(i64, 2 * Grid.TPQ), res.map.segments[1].tick);
    try testing.expectEqual(@as(f64, 400_000), res.map.segments[1].us);
    // …and the file's `[3 4]` is what `1bar` means in the document.
    try testing.expectEqual(@as(i64, 3 * Grid.TPQ), res.doc.cues[0].at);
}

/// `conducted_smf`'s inline tier as a FILE, plus a document that only
/// names it: the same conductor said by reference. The bytes come out of
/// the canonical writer rather than a literal so the two spellings
/// cannot drift apart, and the anchor's `:size` / `:sha256` are that
/// file's own — a by-reference anchor that declares neither is
/// `anchor_mismatch` the moment a resolver reads it.
const ByReference = struct {
    inline_res: Result,
    written: smf.Written,
    source: [:0]u8,
    entries: [1]Resolver.Memory.Entry,

    fn init(gpa: Allocator) !ByReference {
        var inline_res = try load(gpa, conducted_smf, null);
        errdefer inline_res.deinit();
        var written = try smf.write(gpa, &inline_res.doc.midi[0].sequence, .{});
        errdefer written.deinit();

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(written.bytes, &digest, .{});
        var hex: [64]u8 = undefined;
        for (digest, 0..) |b, i| {
            _ = try std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b});
        }

        const source = try std.fmt.allocPrintSentinel(gpa,
            \\(timeline :conductor song)
            \\(anchor :id song :kind smf :file "x.mid" :size {d} :sha256 "{s}")
            \\(cue :name "two" :at 1bar)
            \\
        , .{ written.bytes.len, hex }, 0);
        errdefer gpa.free(source);

        return .{
            .inline_res = inline_res,
            .written = written,
            .source = source,
            .entries = .{.{ .path = "x.mid", .bytes = written.bytes }},
        };
    }

    /// A resolver over the one file. Borrows `self`, so the caller keeps
    /// it alive for the load.
    fn table(self: *const ByReference) Resolver.Memory {
        return .{ .entries = &self.entries };
    }

    fn deinit(self: *ByReference, gpa: Allocator) void {
        gpa.free(self.source);
        self.written.deinit();
        self.inline_res.deinit();
    }
};

test "fromSjon: a by-reference conductor is timed by the file the resolver read" {
    // The final review's C1: the resolver had already read and VERIFIED
    // these bytes, and the document was timed by the placeholder anyway
    // — `validate` said nothing, `timeline` said 500 000 microseconds
    // and `export-score` said `:bpm 120`. Plan 03's rules 2 and 3 make
    // no inline/by-reference distinction, so the two spellings of one
    // conductor give one map, segment for segment and bar for bar.
    const gpa = testing.allocator;
    var fx = try ByReference.init(gpa);
    defer fx.deinit(gpa);

    const t = fx.table();
    var res = try load(gpa, fx.source, Resolver.memory(&t));
    defer res.deinit();

    for (res.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expect(res.doc.anchors[0].resolved);
    try testing.expect(!res.doc.anchors[0].inline_dump);
    // The bytes travel with the document, which is what lets the layers
    // above build the same tables with no resolver of their own.
    try testing.expect(res.doc.conductor_bytes != null);
    try testing.expect(!conductedPlaceholder(&res.doc));

    // The FILE's two segments, not the placeholder's one.
    try testing.expectEqual(@as(usize, 2), res.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), res.map.segments[0].us);
    try testing.expectEqual(@as(i64, 2 * Grid.TPQ), res.map.segments[1].tick);
    try testing.expectEqual(@as(f64, 400_000), res.map.segments[1].us);
    // …and the file's `[3 4]`, which is what makes `1bar` three quarters.
    try testing.expectEqual(@as(i64, 3 * Grid.TPQ), res.doc.cues[0].at);

    // The inline twin, echoed against it: one text or a bug.
    var from_inline: std.Io.Writer.Allocating = .init(gpa);
    defer from_inline.deinit();
    var from_ref: std.Io.Writer.Allocating = .init(gpa);
    defer from_ref.deinit();
    try fx.inline_res.map.echo(&from_inline.writer);
    try res.map.echo(&from_ref.writer);
    try testing.expectEqualStrings(from_inline.written(), from_ref.written());

    // `mapOf` over the finished value takes the same arm — the one
    // owner is `conductorOf` and nothing else chooses.
    var again = try mapOf(gpa, &res.doc);
    defer again.deinit();
    var from_mapof: std.Io.Writer.Allocating = .init(gpa);
    defer from_mapof.deinit();
    try again.echo(&from_mapof.writer);
    try testing.expectEqualStrings(from_ref.written(), from_mapof.written());
}

test "fromSjon: a by-reference conductor nobody can read is anchor_unavailable, not a silence" {
    // The other half of C1's fix: with no resolver (wasm without
    // `tpr_attachAnchor`, a host with no filesystem) the placeholder
    // STAYS — plan 03 needs a document to be answerable — but a
    // conducted document is told, as an ERROR, that the answers are the
    // placeholder's. Plan 02's "recorded unresolved and silent" holds for
    // an anchor that merely carries content; it cannot hold for the one
    // that keeps time.
    const gpa = testing.allocator;
    var fx = try ByReference.init(gpa);
    defer fx.deinit(gpa);

    var res = try load(gpa, fx.source, null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_unavailable));
    try testing.expect(res.diags.hasErrors());
    try testing.expect(res.doc.conductor_bytes == null);
    try testing.expect(conductedPlaceholder(&res.doc));
    // One segment at the placeholder's 500 000 microseconds, and `1bar`
    // is four quarters again because the file's `[3 4]` is not here.
    try testing.expectEqual(@as(usize, 1), res.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), res.map.segments[0].us);
    try testing.expectEqual(@as(i64, 4 * Grid.TPQ), res.doc.cues[0].at);
}

test "fromSjon: a conductor's file that verifies but is not that kind is anchor_unavailable" {
    // The re-review's Minor 1. `:size` and `:sha256` answer "is this the
    // file the document was written against"; they cannot answer "is
    // this a `.mid`". Both readers are TOTAL, so a verified blob of
    // nothing came back as an empty `Sequence` and conducted the
    // document at the placeholder in silence — `validate` clean,
    // `export-score` at `:bpm 120`.
    const gpa = testing.allocator;

    const junk = "not a midi file at all";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(junk, &digest, .{});
    var hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        _ = try std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b});
    }
    const source = try std.fmt.allocPrintSentinel(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind smf :file "x.mid" :size {d} :sha256 "{s}")
        \\(cue :name "two" :at 1bar)
        \\
    , .{ junk.len, hex }, 0);
    defer gpa.free(source);

    const entries = [_]Resolver.Memory.Entry{.{ .path = "x.mid", .bytes = junk }};
    const table: Resolver.Memory = .{ .entries = &entries };
    var res = try load(gpa, source, Resolver.memory(&table));
    defer res.deinit();

    // The anchor VERIFIED — that is the whole point of the case — and
    // the conductor still refused it, naming the kind.
    try testing.expect(res.doc.anchors[0].resolved);
    try testing.expectEqual(@as(usize, 0), res.diags.count(.anchor_mismatch));
    try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_unavailable));
    const d = res.findDiag(.anchor_unavailable).?;
    try testing.expect(std.mem.indexOf(u8, d.message, "not a readable smf") != null);

    // …and the bytes are NOT kept on the document, so the two layers
    // above and `export-score` all see the placeholder for what it is.
    try testing.expect(res.doc.conductor_bytes == null);
    try testing.expect(conductedPlaceholder(&res.doc));
    try testing.expectEqual(@as(usize, 1), res.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), res.map.segments[0].us);
}

test "fromSjon: an anchor :size no u64 can hold saturates and says anchor_mismatch" {
    // `:size 1e30` used to panic in `readAnchors` on an
    // `@intFromFloat` — a defect of the CAST, over user input the root
    // contract says is never asserted on. Saturated, it disagrees with
    // the file the resolver read and is a diagnostic with a span.
    const gpa = testing.allocator;
    const table: Resolver.Memory = .{ .entries = &.{
        .{ .path = "x.it", .bytes = "IMPMbytes" },
    } };
    var res = try load(
        gpa,
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(anchor :id song :kind it :file "x.it" :size 1e30 :sha256 "9f2a00000000000000000000000000000000000000000000000000000000abcd")
    ,
        Resolver.memory(&table),
    );
    defer res.deinit();

    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), res.doc.anchors[0].size.?);
    try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_mismatch));
    try testing.expect(!res.doc.anchors[0].resolved);
}

test "fromSjon.mapOf: the map a Doc answers with is the map its load stored" {
    // One document, two ways to the same map: the walk builds one while
    // it resolves, and a consumer holding only the value asks for it
    // again. They agree segment for segment, bar for bar — including the
    // CONDUCTOR branch, where the tables are the file's and not the
    // document's, and including `:length`'s default, where the anchor's
    // own end is half the rule.
    const gpa = testing.allocator;
    for ([_][:0]const u8{
        conducted_smf,
        \\(timeline :title "native")
        \\(tempo-point :at 0q :qpm 125)
        \\(meter-point :at 0bar :sig [3 4])
        \\(lane :name flash (note :at 0q :dur 1q :key 36))
        ,
        \\(timeline :conductor song)
        \\(anchor :id song :kind smf :file "x.mid")
        \\(cue :name "one" :at 1bar)
        ,
    }) |source| {
        var res = try load(gpa, source, null);
        defer res.deinit();

        var again = try mapOf(gpa, &res.doc);
        defer again.deinit();

        try testing.expectEqual(res.map.length, again.length);
        try testing.expectEqual(res.map.end, again.end);
        try testing.expectEqual(res.map.integral, again.integral);
        try testing.expectEqual(res.map.segments.len, again.segments.len);
        for (res.map.segments, again.segments) |a, b| {
            try testing.expectEqual(a.tick, b.tick);
            try testing.expectEqual(a.us, b.us);
        }
        try testing.expectEqual(res.map.meters.len, again.meters.len);
        for (res.map.meters, again.meters) |a, b| {
            try testing.expectEqual(a.tick, b.tick);
            try testing.expectEqual(a.n, b.n);
            try testing.expectEqual(a.d, b.d);
        }
        try testing.expectEqualSlices(i64, res.map.bars, again.bars);
    }
}

test "fromSjon: a conducted document with no :length ends where its anchor's material does" {
    // Plan 02's `:length` default is "the end of the last event or clip,
    // rounded up to a bar", and for a CONDUCTED document the events are
    // the anchor's: `Conductor.end` is the other half of the rule, which
    // `contentEnd` alone cannot see because it walks the DOCUMENT's own
    // lanes. Both of this layer's answers — the map `fromSource` stores
    // and the one `mapOf` rebuilds from the value — carry it, and a
    // regression would show up here as a length of zero and a playhead
    // that cannot leave tick 0.
    const gpa = testing.allocator;

    // SMF: the last event is at 1920 pulses of 480, which is four
    // quarters — two bars of the file's own [3 4].
    var smf_res = try load(gpa, conducted_smf, null);
    defer smf_res.deinit();
    try testing.expect(smf_res.doc.length == null);
    try testing.expectEqual(@as(i64, 6 * Grid.TPQ), smf_res.map.length);
    var smf_again = try mapOf(gpa, &smf_res.doc);
    defer smf_again.deinit();
    try testing.expectEqual(smf_res.map.length, smf_again.length);

    // IT: 16 rows of speed 6 at 24 ticks to the quarter is four quarters,
    // one bar of the highlight's [4 4].
    var it_res = try load(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "x.it")
        \\(it/module
        \\  (it/timing :speed 6 :tempo 125 :highlight [4 16])
        \\  (it/orders 0)
        \\  (it/pattern 0 :rows 16
        \\    (row 0 (ev 1 :note "C-5" :ins 1))))
    , null);
    defer it_res.deinit();
    try testing.expect(it_res.doc.length == null);
    try testing.expectEqual(@as(i64, 4 * Grid.TPQ), it_res.map.length);
    var it_again = try mapOf(gpa, &it_res.doc);
    defer it_again.deinit();
    try testing.expectEqual(it_res.map.length, it_again.length);
}

test "fromSjon: a file with no tempo or meter event conducts at 120 in [4 4]" {
    const gpa = testing.allocator;
    var res = try load(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind smf :file "x.mid")
        \\(midi/smf :format 1 :division 480)
        \\(midi/mtrk (end-of-track :at 1920))
        \\(cue :name "one" :at 1bar)
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expectEqual(@as(usize, 1), res.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), res.map.segments[0].us);
    try testing.expectEqual(@as(i64, 4 * Grid.TPQ), res.doc.cues[0].at);
}

test "fromSjon.smfConductor: SMPTE is one 120-qpm segment and its tempo events are ignored" {
    const gpa = testing.allocator;

    // A SMPTE division never survives a DUMP — the printer writes the
    // converted PPQ (plan 05, "Chunks") — so the rule is reached with a
    // sequence read from bytes, which is what `tempura dump` has.
    var seq = seq: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.format = 0;
        b.division = .{ .smpte = .{ .fps = 25, .tpf = 40 } };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .set_tempo, .{ .tempo = 400_000 });
        try b.addEvent(t, 500, .set_tempo, .{ .tempo = 300_000 });
        try b.addEvent(t, 1000, .end_of_track, .empty);
        break :seq try b.finish();
    };
    defer seq.deinit();

    var c = try smfConductor(gpa, &seq, .{ .start = 0, .end = 1 });
    defer c.deinit();

    try testing.expectEqual(@as(usize, 1), c.tempo.len);
    try testing.expectEqual(@as(i64, 0), c.tempo[0].tick);
    try testing.expectEqual(@as(u32, 500_000), c.tempo[0].tempo.us);
    // Both of them, named once — and 25 × 40 / 2 is 500, which does not
    // divide the grid, so the same dump says that too.
    try testing.expectEqual(@as(usize, 1), c.diags.count(.smpte_tempo_ignored));
    try testing.expectEqual(@as(usize, 1), c.diags.count(.division_inexact));
    for (c.diags.items()) |d| {
        if (d.code != .smpte_tempo_ignored) continue;
        try testing.expect(std.mem.indexOf(u8, d.message, "2 set-tempo") != null);
    }
}

test "fromSjon.smfConductor: an inexact division is named once, and format 2 conducts nothing" {
    const gpa = testing.allocator;

    var seq = seq: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.format = 2;
        // 500 does not divide TPQ (plan 03, "The grid").
        b.division = .{ .ppq = 500 };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .set_tempo, .{ .tempo = 500_000 });
        try b.addEvent(t, 1, .set_tempo, .{ .tempo = 400_000 });
        try b.addEvent(t, 2, .set_tempo, .{ .tempo = 300_000 });
        try b.addEvent(t, 500, .end_of_track, .empty);
        break :seq try b.finish();
    };
    defer seq.deinit();

    var c = try smfConductor(gpa, &seq, .{ .start = 0, .end = 1 });
    defer c.deinit();

    // Once for the FILE, not once per event it rounded.
    try testing.expectEqual(@as(usize, 1), c.diags.count(.division_inexact));
    try testing.expectEqual(@as(usize, 1), c.diags.count(.smf_format2));
    try testing.expectEqual(@as(usize, 3), c.tempo.len);
}

test "fromSjon.smfConductor: equal ticks keep file order and the last one wins" {
    const gpa = testing.allocator;

    var seq = seq: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.division = .{ .ppq = 96 };
        const one = try b.addTrack();
        try b.addEvent(one, 0, .set_tempo, .{ .tempo = 500_000 });
        try b.addEvent(one, 96, .end_of_track, .empty);
        const two = try b.addTrack();
        try b.addEvent(two, 0, .set_tempo, .{ .tempo = 400_000 });
        try b.addEvent(two, 96, .end_of_track, .empty);
        break :seq try b.finish();
    };
    defer seq.deinit();

    var c = try smfConductor(gpa, &seq, .{ .start = 0, .end = 1 });
    defer c.deinit();

    try testing.expectEqual(@as(usize, 1), c.tempo.len);
    try testing.expectEqual(@as(u32, 400_000), c.tempo[0].tempo.us);
}

test "fromSjon: an inline (it/module …) conducts through the timing walk" {
    const gpa = testing.allocator;
    var res = try load(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "x.it")
        \\(it/module
        \\  (it/timing :speed 6 :tempo 125 :highlight [4 16])
        \\  (it/orders 0 end)
        \\  (it/pattern 0 :rows 4 (row 2 (ev 1 :fx "T96"))))
        \\(cue :name "row two" :at 12t)
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    try testing.expectEqual(@as(usize, 1), res.doc.it.len);

    // Two segments: the module's initial tempo, and the `T96` the walk
    // reads at row 2 — twelve IT ticks in, `Grid.IT_TICK` apiece.
    try testing.expectEqual(@as(usize, 2), res.map.segments.len);
    try testing.expectEqual(@as(i64, 0), res.map.segments[0].tick);
    try testing.expectEqual(@as(i64, 12 * Grid.IT_TICK), res.map.segments[1].tick);
    // `qpm` IS the IT tempo: 125 then 0x96 = 150.
    try testing.expectEqual(@as(f64, 60_000_000.0 / 125.0), res.map.segments[0].us);
    try testing.expectEqual(@as(f64, 60_000_000.0 / 150.0), res.map.segments[1].us);
    // …and the highlight [4 16] is four beats to a measure.
    try testing.expectEqual(@as(u8, 4), res.map.meters[0].n);
    try testing.expectEqual(@as(u8, 4), res.map.meters[0].d);
}

test "fromSjon.itConductor: the highlight is [major / minor 4], and [4 4] when there is none" {
    const gpa = testing.allocator;

    for ([_]struct { u8, u8, bool, u8 }{
        // minor, major, stated, expected numerator
        .{ 4, 16, true, 4 },
        .{ 3, 12, true, 4 },
        .{ 4, 12, true, 3 },
        .{ 6, 42, true, 7 },
        // Stated but meaningless, and not stated at all: `[4 4]`.
        .{ 0, 16, true, 4 },
        .{ 4, 16, false, 4 },
    }) |row| {
        var module = module: {
            var b: itf.Builder = .init(gpa);
            errdefer b.deinit();
            b.module.header.highlight_minor = row[0];
            b.module.header.highlight_major = row[1];
            if (row[2]) {
                b.module.header.special |= itf.model.special.highlight;
            } else b.module.header.special &= ~itf.model.special.highlight;
            _ = try b.addPattern(4);
            try b.addOrder(0);
            break :module b.finish();
        };
        defer module.deinit();

        var c = try itConductor(gpa, &module, .{ .start = 0, .end = 1 });
        defer c.deinit();
        try testing.expectEqual(@as(usize, 1), c.meter.len);
        try testing.expectEqual(row[3], c.meter[0].n);
        try testing.expectEqual(@as(u8, 4), c.meter[0].d);
    }
}

test "fromSjon: an anchor whose bytes do not match its :sha256 is anchor_mismatch" {
    const gpa = testing.allocator;

    const bytes = "MThd not really";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var right: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&right, "{x}", .{&digest});

    const store: Resolver.Memory = .{ .entries = &.{.{ .path = "x.mid", .bytes = bytes }} };

    // The truth first: the same bytes, the right size and the right
    // digest, and the anchor resolves in silence.
    {
        const source = try std.fmt.allocPrintSentinel(gpa,
            \\(timeline)
            \\(tempo-point :at 0q :qpm 120)
            \\(meter-point :at 0bar :sig [4 4])
            \\(anchor :id song :kind smf :file "x.mid" :size {d} :sha256 "{s}")
        , .{ bytes.len, right }, 0);
        defer gpa.free(source);

        var res = try load(gpa, source, Resolver.memory(&store));
        defer res.deinit();
        try testing.expectEqual(@as(usize, 0), res.diags.items().len);
        try testing.expect(res.doc.anchorById("song").?.resolved);
    }

    // …and one wrong digit is a refusal, never a silent re-read.
    {
        var wrong = right;
        wrong[0] = if (wrong[0] == '0') '1' else '0';
        const source = try std.fmt.allocPrintSentinel(gpa,
            \\(timeline)
            \\(tempo-point :at 0q :qpm 120)
            \\(meter-point :at 0bar :sig [4 4])
            \\(anchor :id song :kind smf :file "x.mid" :size {d} :sha256 "{s}")
        , .{ bytes.len, wrong }, 0);
        defer gpa.free(source);

        var res = try load(gpa, source, Resolver.memory(&store));
        defer res.deinit();
        try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_mismatch));
        try testing.expect(!res.doc.anchorById("song").?.resolved);
    }
}

test "fromSjon: a module's own (it/source …) that disagrees with the anchor is anchor_conflict" {
    try expectCode(
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "acid.it" :size 1284403)
        \\(it/module (it/source :file "other.it" :size 1284403))
    , .anchor_conflict);
    // …and one that agrees is simply accepted.
    try expectClean(
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "acid.it" :size 1284403)
        \\(it/module (it/source :file "acid.it" :size 1284403))
    );
}

test "fromSjon: a bound lane over an inline tier resolves its notes" {
    const gpa = testing.allocator;
    var res = try load(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "x.it")
        \\(it/module
        \\  (it/orders 0 end)
        \\  (it/pattern 0 :rows 4
        \\    (row 0 (ev 3 "C-5" :ins 1 :vol 32))
        \\    (row 2 (ev 3 off))))
        \\(lane :name kick :kind notes :from song :channel 3 :target kick)
    , null);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 0), res.diags.items().len);

    // The lane is BOUND: no content of its own, an address into the tier.
    const lane = res.doc.lanes[0];
    try testing.expectEqual(@as(usize, 0), lane.notes.len);
    try testing.expectEqual(@as(u6, 2), lane.binding.?.address.it.channel);

    // …and the tier answers it, through the walk that conducts it.
    var rowmap = try itf.walk.derive(gpa, &res.doc.it[0].module, .{});
    defer rowmap.deinit();
    const notes = try bridge_it.boundNotes(
        gpa,
        &res.doc.it[0].module,
        &rowmap,
        lane.binding.?.address.it.channel,
    );
    defer gpa.free(notes);

    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqual(@as(u7, 60), notes[0].key);
    // `round(32 · 127 / 64)` is 64, and the `off` two rows on ends it.
    try testing.expectEqual(@as(u7, 64), notes[0].vel);
    try testing.expectEqual(@as(i64, 0), notes[0].at);
    try testing.expectEqual(@as(i64, 12), notes[0].dur);
}

test "fromSjon: an inline module's (bin …) is checked against the anchor's verified bytes" {
    const gpa = testing.allocator;

    const bytes = "IMPM" ++ [_]u8{0} ** 60;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
    const store: Resolver.Memory = .{ .entries = &.{.{ .path = "x.it", .bytes = bytes }} };

    // 64 bytes of anchor: a region ending at 64 fits, one ending at 65
    // does not — and an offset is meaningful only against this exact
    // file (it 03, "The anchor").
    for ([_]struct { u32, usize }{ .{ 0x20, 0 }, .{ 0x21, 1 } }) |row| {
        const source = try std.fmt.allocPrintSentinel(gpa,
            \\(timeline :conductor song)
            \\(anchor :id song :kind it :file "x.it" :size {d} :sha256 "{s}")
            \\(it/module (it/instrument 1 :name "bass" :raw (bin :at 0x20 :len 0x{X})))
        , .{ bytes.len, hex, row[0] }, 0);
        defer gpa.free(source);

        var res = try load(gpa, source, Resolver.memory(&store));
        defer res.deinit();
        try testing.expectEqual(row[1], res.diags.count(.it_parapointer_out_of_range));
    }
}

test "fromSjon: an inline dump's anchor is verified too, and says so when it cannot be" {
    const gpa = testing.allocator;

    const bytes = "IMPM" ++ [_]u8{0} ** 60;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
    const store: Resolver.Memory = .{ .entries = &.{.{ .path = "x.it", .bytes = bytes }} };

    const dump = "(it/module (it/instrument 1 :name \"bass\" :raw (bin :at 0x0 :len 0x10)))";

    // The truth first: an inline anchor that checks out resolves in
    // silence and its offsets are honoured.
    {
        const source = try std.fmt.allocPrintSentinel(gpa,
            \\(timeline :conductor song)
            \\(anchor :id song :kind it :file "x.it" :size {d} :sha256 "{s}")
            \\{s}
        , .{ bytes.len, hex, dump }, 0);
        defer gpa.free(source);

        var res = try load(gpa, source, Resolver.memory(&store));
        defer res.deinit();
        try testing.expectEqual(@as(usize, 0), res.diags.items().len);
        try testing.expect(res.doc.anchorById("song").?.resolved);
        try testing.expectEqual(@as(u32, 0x10), res.doc.it[0].module.instruments[0].raw.len);
    }

    // A STALE digest: the file the offsets name has changed under the
    // document, and that is never a silent re-read (plan 02).
    {
        var wrong = hex;
        wrong[0] = if (wrong[0] == '0') '1' else '0';
        const source = try std.fmt.allocPrintSentinel(gpa,
            \\(timeline :conductor song)
            \\(anchor :id song :kind it :file "x.it" :size {d} :sha256 "{s}")
            \\{s}
        , .{ bytes.len, wrong, dump }, 0);
        defer gpa.free(source);

        var res = try load(gpa, source, Resolver.memory(&store));
        defer res.deinit();
        // Once, at the ANCHOR's span, and the offsets are dropped.
        try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_mismatch));
        try testing.expect(!res.doc.anchorById("song").?.resolved);
        const anchor_span = res.doc.anchorById("song").?.span;
        try testing.expectEqual(anchor_span.start, res.diags.items()[0].span.start);
    }

    // No digest at all is the same refusal: bytes honoured without one
    // cannot be verified (the controller's ruling on the two optional
    // keys), and an inline dump's `(bin …)` refs are bytes honoured.
    {
        const source = try std.fmt.allocPrintSentinel(gpa,
            \\(timeline :conductor song)
            \\(anchor :id song :kind it :file "x.it" :size {d})
            \\{s}
        , .{ bytes.len, dump }, 0);
        defer gpa.free(source);

        var res = try load(gpa, source, Resolver.memory(&store));
        defer res.deinit();
        try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_mismatch));
    }

    // …and a file the resolver cannot produce at all.
    {
        const source = try std.fmt.allocPrintSentinel(gpa,
            \\(timeline :conductor song)
            \\(anchor :id song :kind it :file "gone.it" :size {d} :sha256 "{s}")
            \\{s}
        , .{ bytes.len, hex, dump }, 0);
        defer gpa.free(source);

        var res = try load(gpa, source, Resolver.memory(&store));
        defer res.deinit();
        try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_unavailable));
    }

    // With NO resolver nothing was asked of anybody, so nothing is said —
    // plan 02's own silence, unchanged.
    {
        const source = try std.fmt.allocPrintSentinel(gpa,
            \\(timeline :conductor song)
            \\(anchor :id song :kind it :file "x.it" :size 1 :sha256 "beef")
            \\{s}
        , .{dump}, 0);
        defer gpa.free(source);

        var res = try load(gpa, source, null);
        defer res.deinit();
        try testing.expectEqual(@as(usize, 0), res.diags.items().len);
    }
}

test "fromSjon: an inline (midi/smf …) anchor is verified on the same rule" {
    // An SMF dump honours no offset against its file, but plan 02 draws
    // no such line: `:size` and `:sha256` are verified "before any
    // (bin …) OR BOUND LANE is honoured", and a bound lane over a stale
    // dump is a lane over music the file no longer holds.
    const gpa = testing.allocator;
    const store: Resolver.Memory = .{ .entries = &.{.{ .path = "x.mid", .bytes = "MThd" }} };

    var res = try load(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind smf :file "x.mid" :size 4 :sha256 "beefbeef")
        \\(midi/smf :format 0 :division 96)
        \\(midi/mtrk (end-of-track :at 0))
    , Resolver.memory(&store));
    defer res.deinit();

    try testing.expectEqual(@as(usize, 1), res.diags.count(.anchor_mismatch));
}

test "fromSjon: a bound IT curve lane names one :column" {
    // The mirror of the SMF surface check (plan 02, "(lane …)").
    try expectCode(preamble ++
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name bass-vol :kind curve :from song :channel 5)
    , .address_invalid);
    // With a column it is fine, and a bound NOTES lane never needed one.
    try expectClean(preamble ++
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name bass-vol :kind curve :from song :channel 5 :column vol)
        \\(lane :name kick :kind notes :from song :channel 3)
    );
}

/// Every root kind at once, so a sweep over the loader walks every
/// reader: an inline tier of EACH kind — the `(midi/…)` one conducting —
/// with a lane bound to each, native notes, a curve with its own `:cc`,
/// a query, a clip over a phrase, a section, a cue and a pass-through
/// root. The two tiers are what pin `releaseTiers`: each owns an arena
/// of its own, which a load that fails after `readTiers` must free.
const sweep_doc: [:0]const u8 =
    \\; every root kind, so the sweep walks every reader
    \\(timeline :title "sweep" :length 2bar :conductor song)
    \\(anchor :id song :kind smf :file "x.mid")
    \\(midi/smf :format 1 :division 480)
    \\(midi/mtrk
    \\  (set-tempo :at 0 :us 500000)
    \\  (time-signature :at 0 :num 4 :denom 4 :clocks 24 :thirty-seconds 8)
    \\  (marker :at 0 :text "top")
    \\  (end-of-track :at 1920))
    \\(midi/mtrk
    \\  (note-on :at 0 :ch 1 :key 60 :vel 100)
    \\  (note-off :at 480 :ch 1 :key 60 :vel 64)
    \\  (end-of-track :at 1920))
    \\(anchor :id mod :kind it :file "y.it")
    \\(it/module
    \\  (it/timing :speed 6 :tempo 125 :highlight [4 16])
    \\  (it/orders 0 end)
    \\  (it/pattern 0 :rows 4 (row 2 (ev 1 :fx "T96"))))
    \\(section :name intro :at 0bar :dur 1bar)
    \\(cue :name "drop" :at 1bar)
    \\(lane :name kick :kind notes
    \\  (note :at 0bar :dur 1q :key 36 :vel 100)
    \\  (clip :at 1bar :phrase fill :repeat 2))
    \\(lane :name glow :kind curve :range [0 1] :cc 74
    \\  (keyframe :at 0bar :value 0)
    \\  (keyframe :at 1bar :value 1 :ease in-cubic))
    \\(lane :name piano :kind notes :from song :track 2 :ch 1)
    \\(lane :name lead :kind notes :from mod :channel 1)
    \\(lane :name hats :kind query :query (euclid 3 8 1))
    \\(phrase :name fill :length 1q
    \\  (lane :name kick :kind notes
    \\    (note :at 0q :dur 1t :key 38)))
    \\; a pacer root, passed through
    \\(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)
;

test "fromSjon.fromSource: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails
    // with error.OutOfMemory and testing.allocator sees no leak; past
    // the last index it succeeds. Bounded by the number of allocations
    // the call makes, which the loop discovers.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const result = fromSource(failing.allocator(), &schema, sweep_doc, null);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var res = try result;
            defer res.deinit();
            // The fixture is worth the sweep only if it really walked
            // every reader: it loads clean.
            for (res.diags.items()) |d| {
                std.debug.print("sweep fixture: {t}: {s}\n", .{ d.code, d.message });
            }
            try testing.expectEqual(@as(usize, 0), res.diags.items().len);
            // …and it carried a tier of each kind, which is what makes
            // every index past `readTiers` a test of `releaseTiers`.
            try testing.expectEqual(@as(usize, 1), res.doc.midi.len);
            try testing.expectEqual(@as(usize, 1), res.doc.it.len);
            break;
        }
    }
}
