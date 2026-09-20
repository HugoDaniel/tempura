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
const checks = @import("checks.zig");

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
        .a = arena.allocator(),
        .tree = &validated.tree,
        .source = source,
        .view = .init(&validated.tree, &validated.materialized_defaults),
        .diags = &diags,
        .resolver = resolver,
    };

    var doc = try ctx.walk(validated.data_forest);
    const map = try ctx.finalMap(&doc);
    doc.arena = arena;
    return .{ .doc = doc, .diags = diags, .map = map };
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
    it_dump,
    passthrough,
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
    a: Allocator,
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
        if (std.mem.eql(u8, hdr.head, "module") and nsIs(ns, "it")) return .it_dump;
        if (ns) |n| {
            if (!std.mem.eql(u8, n, "tempura")) return .passthrough;
        }
        for (root_heads) |entry| {
            if (std.mem.eql(u8, hdr.head, entry[0])) return entry[1];
        }
        return .passthrough;
    }

    fn walk(self: *Ctx, forest: []const NodeIndex) Error!Doc.Doc {
        var doc: Doc.Doc = .{ .arena = undefined };

        // ---- the roots, partitioned in document order ----
        var timelines: std.ArrayList(NodeIndex) = .empty;
        var anchor_forms: std.ArrayList(NodeIndex) = .empty;
        var tempo_forms: std.ArrayList(NodeIndex) = .empty;
        var meter_forms: std.ArrayList(NodeIndex) = .empty;
        var section_forms: std.ArrayList(NodeIndex) = .empty;
        var cue_forms: std.ArrayList(NodeIndex) = .empty;
        var lane_forms: std.ArrayList(NodeIndex) = .empty;
        var phrase_forms: std.ArrayList(NodeIndex) = .empty;
        var passthrough_forms: std.ArrayList(NodeIndex) = .empty;
        // How many inline dumps paired with each anchor, by position.
        var dumps_per_anchor: std.ArrayList(u32) = .empty;

        for (forest) |idx| {
            const what = self.classify(idx) orelse continue;
            switch (what) {
                .timeline => try timelines.append(self.a, idx),
                .anchor => {
                    try anchor_forms.append(self.a, idx);
                    try dumps_per_anchor.append(self.a, 0);
                },
                .tempo_point => try tempo_forms.append(self.a, idx),
                .meter_point => try meter_forms.append(self.a, idx),
                .section => try section_forms.append(self.a, idx),
                .cue => try cue_forms.append(self.a, idx),
                .lane => try lane_forms.append(self.a, idx),
                .phrase => try phrase_forms.append(self.a, idx),
                .passthrough => try passthrough_forms.append(self.a, idx),
                .smf_dump, .it_dump => {
                    // Positional pairing (plan 02, "(anchor …)"): a dump
                    // belongs to the anchor it FOLLOWS, one per anchor.
                    if (dumps_per_anchor.items.len == 0) {
                        try self.emit(
                            .anchor_missing,
                            self.tree.spanOf(idx),
                            "an inline dump with no (anchor …) before it belongs to nothing",
                            .{},
                        );
                    } else {
                        const last = &dumps_per_anchor.items[dumps_per_anchor.items.len - 1];
                        last.* += 1;
                        if (last.* > 1) try self.emit(
                            .anchor_dump_duplicate,
                            self.tree.spanOf(idx),
                            "the anchor this dump follows already has one; the pairing is positional and one dump per anchor",
                            .{},
                        );
                    }
                },
            }
        }

        // ---- the header: one (timeline …), and the document's first ----
        if (timelines.items.len == 0) {
            try self.emit(
                .timeline_missing,
                .{ .start = 0, .end = 0 },
                "the document has no (timeline …) root",
                .{},
            );
        } else {
            for (timelines.items[1..]) |extra| {
                try self.emit(
                    .timeline_duplicate,
                    self.tree.spanOf(extra),
                    "a second (timeline …) root; there is one per document",
                    .{},
                );
            }
            if (!(forest.len > 0 and forest[0] == timelines.items[0])) {
                try self.emit(
                    .timeline_missing,
                    self.tree.spanOf(timelines.items[0]),
                    "(timeline …) is not the document's first root",
                    .{},
                );
            }
            try self.readHeader(&doc, timelines.items[0]);
        }
        self.conductor = doc.conductor;
        self.end = doc.end;

        // ---- the two maps ----
        try self.readMeterPoints(meter_forms.items);
        try self.readTempoPoints(tempo_forms.items);
        doc.tempo = self.tempo;
        doc.meter = self.meter;
        if (self.conductor != null) {
            for ([_][]const NodeIndex{ tempo_forms.items, meter_forms.items }) |set| {
                for (set) |idx| try self.emit(
                    .conductor_conflict,
                    self.tree.spanOf(idx),
                    "this document names a :conductor, and a conducted document has one owner of time",
                    .{},
                );
            }
        }

        // ---- the provisional map, and everything that resolves on it ----
        var provisional = try self.derive(0);
        self.setMap(provisional.intoMap());
        defer self.dropMap();

        doc.anchors = try self.readAnchors(anchor_forms.items, dumps_per_anchor.items);
        doc.sections = try self.readSections(section_forms.items);
        doc.cues = try self.readCues(cue_forms.items);
        doc.phrases = try self.readPhrases(phrase_forms.items);
        doc.lanes = try self.readLanes(lane_forms.items, &doc);
        doc.passthrough = try self.readPassthrough(passthrough_forms.items);

        if (timelines.items.len > 0) {
            const children = self.tree.formHeader(timelines.items[0]).children;
            if (kvNode(self.tree, children, "length")) |node| {
                doc.length_lit = literalOf(self.tree, node);
                doc.length = try self.resolve(node);
            }
        }

        // ---- the relations that need the whole document ----
        // A clip's window is the other half of the `:length` default
        // rule ("the end of the last event OR CLIP"), so the check hands
        // back the furthest tick it saw.
        self.max_end = @max(self.max_end, try checks.clipPlacement(self.diags, &doc));
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
            if (self.max_end <= 0) break :len 0;
            var probe = try self.derive(self.max_end);
            defer probe.deinit();
            const bars = probe.map.bars;
            break :len if (bars.len == 0) self.max_end else bars[bars.len - 1];
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
        const tempo: []const Doc.TempoPoint =
            if (self.conductor != null and self.tempo.len == 0) &seeded_tempo else self.tempo;
        const meter: []const Doc.MeterPoint =
            if (self.conductor != null and self.meter.len == 0) &seeded_meter else self.meter;

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
            try out.append(self.a, .{
                .tick = tick,
                .n = n,
                .d = d,
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        self.meter = try out.toOwnedSlice(self.a);
        self.dropMap();
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
            try out.append(self.a, .{
                .tick = tick,
                .tempo = tempo,
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        self.tempo = try out.toOwnedSlice(self.a);
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
                    "a tempo or meter point is never placed in seconds: seconds are what this map defines",
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
            const size: ?u64 = if (kvNode(self.tree, children, "size")) |n|
                if (readNumber(self.tree, n)) |v| @intFromFloat(@max(0, v)) else null
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
            try out.append(self.a, anchor);
        }
        return out.toOwnedSlice(self.a);
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

            try out.append(self.a, .{
                .name = try self.symbol(name_node),
                .at = at,
                .dur = dur,
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        return out.toOwnedSlice(self.a);
    }

    fn readCues(self: *Ctx, forms: []const NodeIndex) Error![]Doc.Cue {
        var out: std.ArrayList(Doc.Cue) = .empty;
        for (forms) |form| {
            const children = self.tree.formHeader(form).children;
            const span = self.tree.spanOf(form);

            const name_node = kvNode(self.tree, children, "name") orelse continue;
            const at_node = kvNode(self.tree, children, "at") orelse continue;
            const at = (try self.resolve(at_node)) orelse continue;

            try out.append(self.a, .{
                .name = try self.text(name_node),
                .at = at,
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        return out.toOwnedSlice(self.a);
    }

    // ---- lanes --------------------------------------------------------

    fn readLanes(self: *Ctx, forms: []const NodeIndex, doc: *const Doc.Doc) Error![]Doc.Lane {
        var out: std.ArrayList(Doc.Lane) = .empty;
        for (forms) |form| {
            try out.append(self.a, try self.readLane(form, doc));
        }
        return out.toOwnedSlice(self.a);
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
            .curve => if (kvNode(tree, children, "range")) |node| {
                if (tree.tagOf(node) == .vector) {
                    const elems = tree.vectorElements(node);
                    if (elems.len == 2) lane.range = .{
                        @floatCast(readNumber(tree, elems[0]) orelse 0),
                        @floatCast(readNumber(tree, elems[1]) orelse 0),
                    };
                }
            },
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
        if (from) |node| {
            if (doc) |d| {
                if (kind == .query or kind == .formula) {
                    try self.emit(
                        .bound_kind_invalid,
                        span,
                        "a {t} lane computes its content and cannot read it from an anchor",
                        .{kind},
                    );
                } else {
                    lane.binding = try self.readBinding(form, node, d);
                }
            } else {
                try self.emit(
                    .phrase_lane_bound,
                    span,
                    "a phrase's lanes carry content only; :from belongs on the lane that places the phrase",
                    .{},
                );
            }
        }

        // ---- the children ----
        var notes: std.ArrayList(Doc.Note) = .empty;
        var keyframes: std.ArrayList(Doc.Keyframe) = .empty;
        var clips: std.ArrayList(Doc.Clip) = .empty;
        var content: usize = 0;
        for (children) |child| {
            if (tree.tagOf(child) != .form) continue;
            const head = tree.formHeader(child).head;
            content += 1;
            if (std.mem.eql(u8, head, "note")) {
                if (try self.readNote(child)) |n| try notes.append(self.a, n);
            } else if (std.mem.eql(u8, head, "keyframe")) {
                if (try self.readKeyframe(child)) |k| try keyframes.append(self.a, k);
            } else if (std.mem.eql(u8, head, "clip")) {
                if (in_phrase) {
                    try self.emit(
                        .clip_nested,
                        tree.spanOf(child),
                        "a phrase's lane places nothing: a clip inside one would nest a phrase in a phrase",
                        .{},
                    );
                } else if (try self.readClip(child)) |c| {
                    try clips.append(self.a, c);
                }
            }
        }
        if (content > 0 and from != null and !in_phrase) {
            try self.emit(
                .bound_lane_has_content,
                span,
                "this lane reads its content from an anchor, and content has one home",
                .{},
            );
        }
        lane.notes = try notes.toOwnedSlice(self.a);
        lane.keyframes = try keyframes.toOwnedSlice(self.a);
        lane.clips = try clips.toOwnedSlice(self.a);

        try checks.noteOverlap(self.diags, &lane);
        return lane;
    }

    /// The address keys against the anchor's KIND (plan 02,
    /// `address_invalid`) — the one thing the schema cannot see, because
    /// it validates the lane and the anchor one at a time. An anchor no
    /// form declares is SJON's `not_cross_ref` and nothing is added.
    fn readBinding(self: *Ctx, form: NodeIndex, from: NodeIndex, doc: *const Doc.Doc) Error!?Doc.Binding {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const span = tree.spanOf(form);
        const id = try self.symbol(from);
        const anchor = doc.anchorById(id) orelse return null;

        switch (anchor.kind) {
            .smf => {
                for ([_][]const u8{ "channel", "column", "fx" }) |wrong| {
                    if (kvNode(tree, children, wrong) != null) {
                        try self.emit(
                            .address_invalid,
                            span,
                            ":{s} addresses an Impulse Tracker module, and \"{s}\" is a Standard MIDI File",
                            .{ wrong, id },
                        );
                        return null;
                    }
                }
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
                var curve: ?Doc.SmfCurve = null;
                if (kvNode(tree, children, "cc")) |node| {
                    if (tree.tagOf(node) == .vector) {
                        const elems = tree.vectorElements(node);
                        if (elems.len == 2) curve = .{ .cc14 = .{
                            castU7(readNumber(tree, elems[0])),
                            castU7(readNumber(tree, elems[1])),
                        } };
                    } else curve = .{ .cc = castU7(readNumber(tree, node)) };
                } else if (boolAt(tree, children, "bend")) {
                    curve = .bend;
                } else if (boolAt(tree, children, "pressure")) {
                    curve = .pressure;
                } else if (boolAt(tree, children, "velocity")) {
                    curve = .velocity;
                }
                return .{ .anchor = anchor.id, .address = .{ .smf = .{
                    .track = castU16(readNumber(tree, track_node.?)),
                    .ch = wireChannel(u4, readNumber(tree, ch_node.?)),
                    .key = if (kvNode(tree, children, "key")) |n| try self.noteKey(n) else null,
                    .curve = curve,
                } } };
            },
            .it => {
                for ([_][]const u8{ "track", "ch", "cc", "bend", "pressure", "velocity", "key" }) |wrong| {
                    if (kvNode(tree, children, wrong) != null) {
                        try self.emit(
                            .address_invalid,
                            span,
                            ":{s} addresses a Standard MIDI File, and \"{s}\" is an Impulse Tracker module",
                            .{ wrong, id },
                        );
                        return null;
                    }
                }
                const channel_node = kvNode(tree, children, "channel") orelse {
                    try self.emit(
                        .address_invalid,
                        span,
                        "a lane bound to the IT anchor \"{s}\" names :channel",
                        .{id},
                    );
                    return null;
                };
                const column: ?Doc.ItColumn = if (kvNode(tree, children, "column")) |n|
                    if (tree.tagOf(n) == .symbol) std.meta.stringToEnum(Doc.ItColumn, tree.symbolText(n)) else null
                else
                    null;
                const fx: ?u8 = if (kvNode(tree, children, "fx")) |n| blk: {
                    if (tree.tagOf(n) != .string) break :blk null;
                    const t = tree.stringText(n);
                    break :blk if (t.len == 1) t[0] else null;
                } else null;

                return .{ .anchor = anchor.id, .address = .{ .it = .{
                    .channel = wireChannel(u6, readNumber(tree, channel_node)),
                    .column = column,
                    .fx = fx,
                } } };
            },
        }
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
            .vel = if (kvNode(tree, children, "vel")) |n| castU7(readNumber(tree, n)) else default_vel,
            .ch = if (kvNode(tree, children, "ch")) |n| wireChannel(u4, readNumber(tree, n)) else default_note_ch,
            .off_vel = if (kvNode(tree, children, "off-vel")) |n| castU7(readNumber(tree, n)) else null,
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

        const offset: i64 = if (kvNode(tree, children, "offset")) |n|
            (try self.resolve(n)) orelse 0
        else
            0;
        const length: ?i64 = if (kvNode(tree, children, "length")) |n|
            try self.resolve(n)
        else
            null;

        return .{
            .at = at,
            .phrase = try self.symbol(phrase_node),
            .repeat = if (kvNode(tree, children, "repeat")) |n| castU32(readNumber(tree, n)) else default_repeat,
            .offset = offset,
            .length = length,
            .transpose = if (kvNode(tree, children, "transpose")) |n| castI8(readNumber(tree, n)) else default_transpose,
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
                try lanes.append(self.a, try self.readLane(child, null));
                self.max_end = before;
            }
            try out.append(self.a, .{
                .name = try self.symbol(name_node),
                .length = length,
                .lanes = try lanes.toOwnedSlice(self.a),
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        return out.toOwnedSlice(self.a);
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
                    "tempura emits ({s} …) itself at export; a timeline document says tempo with (tempo-point …)",
                    .{hdr.head},
                );
            }

            var comments: std.ArrayList([]const u8) = .empty;
            for (tree.commentSpans(tree.leading_comments_index[form.raw()])) |c| {
                try comments.append(self.a, try self.a.dupe(u8, self.source[c.start..c.end]));
            }

            try out.append(self.a, .{
                .head = try self.a.dupe(u8, hdr.head),
                .text = try self.a.dupe(u8, self.source[span.start..span.end]),
                .comments = try comments.toOwnedSlice(self.a),
                .span = .{ .start = span.start, .end = span.end },
            });
        }
        return out.toOwnedSlice(self.a);
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
            try self.emit(.tick_overflow, self.tree.spanOf(node), "this position is not a point on the grid", .{});
            return null;
        };
        switch (answer) {
            .tick => |t| return t,
            .err => |code| {
                try self.emit(code, self.tree.spanOf(node), "this position is not a point on the grid", .{});
                return null;
            },
        }
    }

    /// A DURATION — `:dur`, `:offset`, a clip's `:length` — which plan 03
    /// measures from the form's own `:at`.
    ///
    /// `q`, `t`, `bar` and `b` are counted from the ORIGIN: under one
    /// meter that is the same answer as counting from `at`, and it is
    /// the answer the printer inverts (a duration tick spells back as
    /// `Nbar` exactly when `Nbar` resolves to it, which is what makes
    /// the round trip an identity). An `s` duration is genuinely
    /// anchored — wall-clock from `at` through the tempo map, pacer's own
    /// rule for a scene-relative position.
    fn duration(self: *Ctx, node: NodeIndex, at: i64) Error!?i64 {
        const lit = literalOf(self.tree, node) orelse return self.resolve(node);
        if (lit.unit != .s) return self.resolve(node);

        const from = self.map.secondsFromTick(at);
        const abs = self.map.tickFromSeconds(from + lit.value) catch {
            try self.emit(.tick_overflow, self.tree.spanOf(node), "this duration runs past the grid", .{});
            return null;
        };
        return abs - at;
    }

    /// `:key`: the MIDI number, or the note name that reads better
    /// (`"C4"` is 60, sharps `#`, flats `b` — the midi set's convention,
    /// midi 02).
    fn noteKey(self: *Ctx, node: NodeIndex) Error!?u7 {
        if (self.tree.tagOf(node) != .string) return castU7(readNumber(self.tree, node));
        const spelling = self.tree.stringText(node);
        return parseNoteName(spelling) orelse {
            // The frozen `Diag.Code` has no note-name variant, and this
            // task appends two codes, neither of them that. The
            // complaint therefore rides on the code this vocabulary
            // already gives an unreadable literal in a typed slot —
            // `Pos.parse` answers `unit_required` for `"1.2.3q"` for the
            // same reason — and the message names the spelling it could
            // not read. `note_key_invalid` is what the next append owes.
            try self.emit(
                .unit_required,
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
            .author => |node| if (self.tree.tagOf(node) == .symbol) self.tree.symbolText(node) else null,
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
        return self.a.dupe(u8, self.tree.stringText(node));
    }

    /// A symbol value, copied into the document's arena.
    fn symbol(self: *Ctx, node: NodeIndex) Error![]const u8 {
        if (self.tree.tagOf(node) != .symbol) return "";
        return self.a.dupe(u8, self.tree.symbolText(node));
    }

    /// A node's own SOURCE TEXT, copied — what `:ease`, `:query` and
    /// `:expr` keep, because those vocabularies are pacer's and SJON's
    /// and tempura carries them rather than re-spelling them.
    fn slice(self: *Ctx, node: NodeIndex) Error![]const u8 {
        const span = self.tree.spanOf(node);
        return self.a.dupe(u8, self.source[span.start..span.end]);
    }
};

// ---------------------------------------------------------------------
// Free helpers
// ---------------------------------------------------------------------

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

fn castU7(v: ?f64) u7 {
    const x = v orelse return 0;
    return if (x >= 0 and x <= 127) @intFromFloat(x) else 0;
}

fn castU16(v: ?f64) u16 {
    const x = v orelse return 1;
    return if (x >= 0 and x <= 65535) @intFromFloat(x) else 1;
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

    std.debug.print("\nexpected a clean document, got {d} diagnostic(s):\n", .{res.diags.items().len});
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
    // is silent rather than doubly wrong.
    try expectClean(
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "x.it")
    );
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
    // The tiers stay EMPTY here: reading a dump is the anchored half's.
    try testing.expectEqual(@as(usize, 0), res.doc.it.len);
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
    try testing.expectEqual(@as(u4, 9), drum.ch); // :ch 10 is 9 on the wire
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
    try expectCode(preamble ++ "(transport :bpm 120 :meter [4 4] :dur 16bar)", .passthrough_conducts);
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

test "fromSjon: a note name that will not read is reported with its spelling" {
    try expectCode(preamble ++
        \\(lane :name flash :kind notes
        \\  (note :at 0q :dur 1q :key "H9"))
    , .unit_required);
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
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;

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
        if (d.code == .sjon_diagnostic and std.mem.indexOf(u8, d.message, "nowhere") != null) found = true;
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
    try testing.expectEqualStrings("; pacer's form, pass-through", res.doc.passthrough[0].comments[0]);
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
            } else if (std.mem.eql(u8, form.name, "keyframe") and std.mem.eql(u8, key.name, "ease")) {
                try testing.expectEqualStrings(default_ease, d.symbol);
                seen += 1;
            } else if (std.mem.eql(u8, form.name, "clip") and std.mem.eql(u8, key.name, "repeat")) {
                try testing.expectEqual(@as(f64, default_repeat), d.number);
                seen += 1;
            } else if (std.mem.eql(u8, form.name, "clip") and std.mem.eql(u8, key.name, "transpose")) {
                try testing.expectEqual(@as(f64, default_transpose), d.number);
                seen += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 4), seen);
}
