//! `Doc` → `Derived`: the three conductors, the content in ticks (plan
//! 03, "Three conductors" and "Phases" item 3).
//!
//! `TimeMap.derive` builds the two tables from POINTS; this file decides
//! which points they are — the document's own, an SMF anchor's tempo and
//! time-signature events, or an IT anchor's timing walk — and assembles
//! everything else a playhead reads: the sections and cues in ticks, one
//! onset list per lane with every clip expanded, the curve steps, the
//! length and the loop point.

const std = @import("std");
const testing = std.testing;

const Diag = @import("../Diag.zig");
const Grid = @import("Grid.zig");
const tm = @import("TimeMap.zig");
const value = @import("../doc/Value.zig");
const bridge_smf = @import("../doc/bridge_smf.zig");
const bridge_it = @import("../doc/bridge_it.zig");
const walk = @import("../itf/walk.zig");
const Module = @import("../itf/Module.zig");
const Sequence = @import("../smf/Sequence.zig");

const Doc = value.Doc;
const TimeMap = tm.TimeMap;

/// Assembling a derivation can only fail the way any allocation fails.
/// Every defect of a DOCUMENT is a diagnostic on the returned value.
pub const Error = error{OutOfMemory};

/// A named window, in ticks.
pub const Section = struct { name: []const u8, at: i64, dur: i64 };

/// A named point, in ticks.
pub const Cue = struct { name: []const u8, at: i64 };

/// One note, placed: the document's own notes and every note a clip put
/// on the timeline, in one list.
pub const Onset = struct { tick: i64, dur: i64, key: u7, vel: u7 };

/// One point on a curve lane — a keyframe of plan 02 with its tick
/// resolved, and what `curveAt` hands back.
pub const Step = struct {
    tick: i64,
    value: [4]f32,
    ncomp: u3,
    ease_src: []const u8,
};

/// One lane's content, placed.
pub const LaneIndex = struct {
    name: []const u8,
    kind: value.LaneKind,
    /// Whether the content came from an anchor rather than from the
    /// document.
    bound: bool,
    onsets: []Onset,
    steps: []Step,
};

/// The document as a playhead reads it.
///
/// Self-contained: `arena` owns every name, onset and step here, and
/// `map` and `rowmap` own theirs, so a `Derived` outlives the `Doc` it
/// was built from and `deinit()` frees the lot (pacer's convention).
pub const Derived = struct {
    map: TimeMap,
    sections: []Section,
    cues: []Cue,
    /// One per `(lane …)`, in document order.
    lanes: []LaneIndex,
    /// The conductor's timing walk, for a document an IT anchor conducts
    /// — what `Playhead.orderRowAt` reads, and where the module's own
    /// loop point is (`loop_row`). Null for every other document.
    rowmap: ?walk.RowMap,
    /// What the derivation found wrong, in the order it found it.
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Derived) void {
        self.map.deinit();
        if (self.rowmap) |*r| r.deinit();
        self.diags.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// The lane named `name`, or null.
    pub fn laneByName(self: *const Derived, name: []const u8) ?*const LaneIndex {
        for (self.lanes) |*l| {
            if (std.mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }

    /// The canonical text: the map's echo, then the sections, the cues
    /// and one line per lane, in document order.
    pub fn echo(self: *const Derived, writer: anytype) !void {
        try self.map.echo(writer);
        for (self.sections) |s| {
            try writer.print("(section :name {s} :at {d} :dur {d})\n", .{ s.name, s.at, s.dur });
        }
        for (self.cues) |c| {
            try writer.print("(cue :name \"{s}\" :at {d})\n", .{ c.name, c.at });
        }
        for (self.lanes) |l| {
            const first: i64 = if (l.onsets.len == 0) 0 else l.onsets[0].tick;
            const last: i64 = if (l.onsets.len == 0) 0 else l.onsets[l.onsets.len - 1].tick;
            try writer.print(
                "(lane :name {s} :kind {s} :onsets {d} :first {d} :last {d})\n",
                .{ l.name, @tagName(l.kind), l.onsets.len, first, last },
            );
        }
    }
};

/// The document, derived.
///
/// Best-effort, like every producer here: what a document gets wrong is
/// a diagnostic on the returned value and the derivation is still built,
/// because an editor has to show something.
pub fn derive(gpa: std.mem.Allocator, doc: *const Doc) Error!Derived {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    var diags: Diag.List = .init(gpa);
    var rowmap: ?walk.RowMap = null;
    errdefer {
        if (rowmap) |*r| r.deinit();
        arena.deinit();
        diags.deinit();
    }
    const a = arena.allocator();

    const conducted = try conduct(gpa, a, doc, &diags, &rowmap);

    const sections = try a.alloc(Section, doc.sections.len);
    for (doc.sections, sections) |src, *dst| {
        dst.* = .{ .name = try a.dupe(u8, src.name), .at = src.at, .dur = src.dur };
    }
    const cues = try a.alloc(Cue, doc.cues.len);
    for (doc.cues, cues) |src, *dst| {
        dst.* = .{ .name = try a.dupe(u8, src.name), .at = src.at };
    }
    const lanes = try laneTable(gpa, a, doc, &diags, &rowmap);

    // Plan 02's `:length` default — "the end of the last event or clip,
    // rounded up to a bar" — over everything this derivation placed, the
    // anchored material included.
    var content_end: i64 = conducted.end;
    for (lanes) |l| {
        for (l.onsets) |o| content_end = @max(content_end, o.tick + @max(o.dur, 0));
        for (l.steps) |s| content_end = @max(content_end, s.tick);
    }
    // A clip's WINDOW counts whether or not anything sounds in it — the
    // same arithmetic `doc/checks.zig` hands the bridge, so a document
    // derived here and one loaded through `fromSource` agree on the
    // default length. Saturating, because the window is user arithmetic.
    for (doc.lanes) |l| {
        for (l.clips) |c| {
            const phrase = doc.phraseByName(c.phrase) orelse continue;
            const window = c.length orelse
                (phrase.length *| @as(i64, c.repeat)) -| c.offset;
            content_end = @max(content_end, c.at +| @max(0, window));
        }
    }
    const length = doc.length orelse
        try roundUpToBar(gpa, conducted, content_end, doc.end);

    var res = try tm.derive(gpa, conducted.tempo, conducted.meter, length, doc.end);
    errdefer res.map.deinit();
    {
        defer res.diags.deinit();
        for (res.diags.items()) |d| {
            try diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
        }
    }

    return .{
        .map = res.map,
        .sections = sections,
        .cues = cues,
        .lanes = lanes,
        .rowmap = rowmap,
        .diags = diags,
        .arena = arena,
    };
}

// ---- the conductor ----

/// The points the two tables are built from, and where the anchored
/// material ends.
const Conducted = struct {
    tempo: []const tm.TempoPoint,
    meter: []const tm.MeterPoint,
    /// The end of the CONDUCTOR's own material in ticks, which the
    /// `:length` default counts alongside the document's content. Zero
    /// for a document that conducts itself.
    end: i64 = 0,
};

/// What a conducted document falls back to when its anchor carries no
/// dump to read: 120 quarter notes per minute in [4 4], SMF's own
/// default. `500 000` is an INTEGER, so the fallback never forces the
/// f64 path on a map that would otherwise be exact.
const seed_tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
const seed_meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};

/// Plan 03's three conductors: the document's own points, an SMF
/// anchor's tempo and time-signature events, or an IT anchor's timing
/// walk.
fn conduct(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    doc: *const Doc,
    diags: *Diag.List,
    rowmap: *?walk.RowMap,
) Error!Conducted {
    const id = doc.conductor orelse return .{ .tempo = doc.tempo, .meter = doc.meter };

    // One owner of time per document (plan 03, "Three conductors"): with
    // a `:conductor`, the document's own points are an error. The bridge
    // says this too, over the SOURCE; a `Doc` reaching here from the edit
    // engine never passed through it.
    for (doc.tempo) |p| try diags.add(
        .conductor_conflict,
        .err,
        p.span,
        "this document names a :conductor, and a conducted document has one owner of time",
        .{},
    );
    for (doc.meter) |p| try diags.add(
        .conductor_conflict,
        .err,
        p.span,
        "this document names a :conductor, and a conducted document has one owner of time",
        .{},
    );

    const anchor = doc.anchorById(id) orelse return seeded();
    switch (anchor.kind) {
        .smf => if (smfTier(doc, id)) |t| return try fromSmf(a, &t.sequence, diags),
        .it => if (itTier(doc, id)) |t| return try fromIt(gpa, a, &t.module, diags, rowmap),
    }
    // A by-reference anchor nothing has read yet: the document says the
    // file conducts, and until the file is here the tables are the
    // fallback. `anchor_unavailable` belongs to the resolver, not here.
    return seeded();
}

fn seeded() Conducted {
    return .{ .tempo = &seed_tempo, .meter = &seed_meter };
}

/// Rule 2: every `set-tempo` in EVERY track merged by tick (stable;
/// equal ticks keep file order and the last wins), `time-signature`
/// likewise, and SMF tick `k` at `k · TPQ / PPQ`.
///
/// A file with SMPTE division is one segment at 120 quarter notes per
/// minute over the converted grid and its `set-tempo` events are ignored
/// for timing: SMPTE ticks are wall-clock by definition and that segment
/// reproduces them exactly.
fn fromSmf(
    a: std.mem.Allocator,
    seq: *const Sequence.Sequence,
    diags: *Diag.List,
) Error!Conducted {
    const ppq = seq.division.pulsesPerQuarter();
    const wall_clock = switch (seq.division) {
        .smpte => true,
        .ppq => false,
    };

    var tempo: std.ArrayList(tm.TempoPoint) = .empty;
    var meter: std.ArrayList(tm.MeterPoint) = .empty;
    var inexact = false;
    var overflow = false;
    var ignored: usize = 0;
    var end: i64 = 0;

    for (seq.tracks) |t| {
        for (t.events) |e| {
            const conv = Grid.smfToTicks(e.at, ppq);
            if (!conv.exact) inexact = true;
            if (conv.overflow) overflow = true;
            end = @max(end, conv.tick);
            switch (e.kind) {
                .set_tempo => {
                    if (wall_clock) {
                        ignored += 1;
                        continue;
                    }
                    try tempo.append(a, .{ .tick = conv.tick, .tempo = .{ .us = e.payload.tempo } });
                },
                .time_signature => {
                    const sig = e.payload.time_sig;
                    try meter.append(a, .{ .tick = conv.tick, .n = sig.nn, .d = powerOfTwo(sig.dd) });
                },
                else => {},
            }
        }
    }

    if (inexact) try diags.add(
        .division_inexact,
        .warning,
        .{ .start = 0, .end = 0 },
        "division {d} does not divide {d}; this file's ticks land on the nearest tempura tick",
        .{ ppq, Grid.TPQ },
    );
    if (overflow) try diags.add(
        .tick_overflow,
        .err,
        .{ .start = 0, .end = 0 },
        "this file reaches past the grid ceiling {d}; its ticks are clamped",
        .{Grid.MAX_TICK},
    );
    if (ignored > 0) try diags.add(
        .smpte_tempo_ignored,
        .warning,
        .{ .start = 0, .end = 0 },
        "SMPTE division: {d} set-tempo event(s) are ignored for timing and the file plays at 120 quarter notes per minute",
        .{ignored},
    );

    std.mem.sort(tm.TempoPoint, tempo.items, {}, byTick(tm.TempoPoint));
    std.mem.sort(tm.MeterPoint, meter.items, {}, byTick(tm.MeterPoint));
    return .{
        .tempo = try openAtZero(tm.TempoPoint, a, try lastPerTick(tm.TempoPoint, a, tempo.items), seed_tempo[0]),
        .meter = try openAtZero(tm.MeterPoint, a, try lastPerTick(tm.MeterPoint, a, meter.items), seed_meter[0]),
        .end = end,
    };
}

/// Rule 3: the timing walk. tempura ticks are IT ticks · 1 921 920,
/// segments are one per tempo change (a slide yields one per tick), and
/// `qpm` IS the IT tempo — the 24-ticks-per-quarter convention.
///
/// Bars come from the module's highlight `[minor major]` when set, as one
/// meter point at 0 with `[major / minor, 4]`, else `[4 4]`: a speed
/// change moves the row grid, never the bar grid.
fn fromIt(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    module: *const Module.Module,
    diags: *Diag.List,
    rowmap: *?walk.RowMap,
) Error!Conducted {
    // The map goes to the caller's slot FIRST: it owns an arena from the
    // moment it exists, and `derive`'s errdefer is what frees it.
    rowmap.* = try walk.derive(gpa, module, .{});
    const map = &rowmap.*.?;
    for (map.diags.items()) |d| {
        try diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
    }

    var tempo: std.ArrayList(tm.TempoPoint) = .empty;
    var overflow = false;
    for (map.segments) |s| {
        const tick = itToTicks(s.start_tick) orelse {
            overflow = true;
            break;
        };
        try tempo.append(a, .{ .tick = tick, .tempo = .{ .qpm = @floatFromInt(s.tempo) } });
    }
    const end = itToTicks(map.total_ticks) orelse end: {
        overflow = true;
        break :end Grid.MAX_TICK;
    };
    if (overflow) try diags.add(
        .tick_overflow,
        .err,
        .{ .start = 0, .end = 0 },
        "this module reaches past the grid ceiling {d}; the segments past it are dropped",
        .{Grid.MAX_TICK},
    );

    const meter = try a.alloc(tm.MeterPoint, 1);
    meter[0] = itMeter(module.header);
    return .{
        .tempo = try openAtZero(tm.TempoPoint, a, tempo.items, seed_tempo[0]),
        .meter = meter,
        .end = end,
    };
}

/// The module's highlight as a meter: `[major / minor, 4]` when the
/// header carries a valid one, else `[4 4]`.
fn itMeter(header: Module.Header) tm.MeterPoint {
    const minor = header.highlight_minor;
    const major = header.highlight_major;
    if (header.special & Module.special.highlight != 0 and
        minor > 0 and major >= minor and major % minor == 0)
    {
        const n = major / minor;
        if (n >= 1 and n <= 64) return .{ .tick = 0, .n = n, .d = 4 };
    }
    return .{ .tick = 0, .n = 4, .d = 4 };
}

/// IT ticks to tempura ticks, or null past the grid ceiling. The product
/// is formed in `i128`, so the ceiling is a CHECK and never a wrap.
fn itToTicks(it_ticks: i64) ?i64 {
    const t = @as(i128, it_ticks) * Grid.IT_TICK;
    if (t < 0 or t > Grid.MAX_TICK) return null;
    return @intCast(t);
}

/// SMF's `dd`, which is a power of two by definition. Past 32 there is
/// no meter tempura can spell, and 0 is what `TimeMap` refuses by name
/// (`meter_map_invalid`).
fn powerOfTwo(dd: u8) u8 {
    if (dd > 5) return 0;
    return @as(u8, 1) << @intCast(dd);
}

/// A comparator on `.tick` alone. `std.mem.sort` is stable, so points
/// that share a tick keep the order they were collected in — which is
/// file order, across tracks (plan 03, rule 2).
fn byTick(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn less(_: void, x: T, y: T) bool {
            return x.tick < y.tick;
        }
    }.less;
}

/// One point per tick, the LAST of each run — "equal ticks keep file
/// order and the last wins".
fn lastPerTick(comptime T: type, a: std.mem.Allocator, items: []const T) Error![]T {
    var out: std.ArrayList(T) = .empty;
    var i: usize = 0;
    while (i < items.len) {
        var j = i;
        while (j + 1 < items.len and items[j + 1].tick == items[i].tick) j += 1;
        try out.append(a, items[j]);
        i = j + 1;
    }
    return out.toOwnedSlice(a);
}

/// The table with a point at tick 0, whatever the file said: a `.mid`
/// whose first tempo comes late plays at 120 until it, and a module or a
/// file with no meter is in [4 4]. Without this the map's first segment
/// would start at the second point's tick and every lookup before it
/// would read the wrong one.
fn openAtZero(comptime T: type, a: std.mem.Allocator, items: []T, first: T) Error![]T {
    if (items.len > 0 and items[0].tick == 0) return items;
    const out = try a.alloc(T, items.len + 1);
    out[0] = first;
    @memcpy(out[1..], items);
    return out;
}

/// The first bar line at or after `end`, which is the `:length` default.
///
/// The round-up falls out of `TimeMap`'s own bar table, which appends bar
/// starts until one lands at or past the length it was given — so the
/// LAST entry of a table derived over `end` is exactly that bar line.
fn roundUpToBar(
    gpa: std.mem.Allocator,
    conducted: Conducted,
    end: i64,
    end_behaviour: tm.End,
) Error!i64 {
    if (end <= 0) return 0;
    var probe = try tm.derive(gpa, conducted.tempo, conducted.meter, end, end_behaviour);
    defer probe.deinit();
    const bars = probe.map.bars;
    return if (bars.len == 0) end else bars[bars.len - 1];
}

// ---- the lanes ----

/// One `LaneIndex` per lane, in document order.
fn laneTable(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    doc: *const Doc,
    diags: *Diag.List,
    rowmap: *?walk.RowMap,
) Error![]LaneIndex {
    const out = try a.alloc(LaneIndex, doc.lanes.len);
    for (doc.lanes, out) |*src, *dst| {
        var onsets: std.ArrayList(Onset) = .empty;
        var steps: std.ArrayList(Step) = .empty;

        if (src.binding) |binding| {
            try bound(gpa, a, doc, src, binding, &onsets, &steps, diags, rowmap);
        } else {
            for (src.notes) |n| try onsets.append(a, .{
                .tick = n.at,
                .dur = n.dur,
                .key = n.key,
                .vel = n.vel,
            });
            for (src.keyframes) |k| try steps.append(a, .{
                .tick = k.at,
                .value = k.value,
                .ncomp = k.ncomp,
                .ease_src = try a.dupe(u8, k.ease_src),
            });
            for (src.clips) |c| try place(a, doc, src, c, &onsets, &steps, diags);
        }

        std.mem.sort(Onset, onsets.items, {}, onsetBefore);
        std.mem.sort(Step, steps.items, {}, stepBefore);
        dst.* = .{
            .name = try a.dupe(u8, src.name),
            .kind = src.kind,
            .bound = src.binding != null,
            .onsets = try onsets.toOwnedSlice(a),
            .steps = try steps.toOwnedSlice(a),
        };
    }
    return out;
}

/// A bound lane's content: the anchor's, read through `doc/`'s bridges
/// and converted onto the grid (plan 02, "Binding"; plan 05 and plan 06,
/// "Bound lanes").
///
/// The two bridges answer in their FILE's unit — SMF pulses, IT ticks —
/// and this is where both become tempura ticks. A bound curve's value
/// stays normalised: `:range` scales it at export, not here.
fn bound(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    doc: *const Doc,
    lane: *const value.Lane,
    binding: value.Binding,
    onsets: *std.ArrayList(Onset),
    steps: *std.ArrayList(Step),
    diags: *Diag.List,
    rowmap: *?walk.RowMap,
) Error!void {
    switch (binding.address) {
        .smf => |addr| {
            const tier = smfTier(doc, binding.anchor) orelse return;
            const ppq = tier.sequence.division.pulsesPerQuarter();
            switch (lane.kind) {
                .notes => {
                    var paired = try bridge_smf.pairNotes(gpa, &tier.sequence, addr.track, addr.ch, addr.key);
                    defer paired.deinit();
                    for (paired.diags.items()) |d| {
                        try diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
                    }
                    for (paired.notes) |n| {
                        const at = Grid.smfToTicks(n.at, ppq).tick;
                        const end = Grid.smfToTicks(n.at + @max(n.dur, 0), ppq).tick;
                        try onsets.append(a, .{
                            .tick = at,
                            .dur = end - at,
                            .key = n.key,
                            .vel = n.vel,
                        });
                    }
                },
                .curve => {
                    const address = addr.curve orelse return;
                    const read = try bridge_smf.curveSteps(gpa, &tier.sequence, addr.track, addr.ch, address);
                    defer gpa.free(read);
                    for (read) |s| try steps.append(a, normalised(Grid.smfToTicks(s.at, ppq).tick, s.value));
                },
                // A `query` or a `formula` lane cannot bind
                // (`bound_kind_invalid`, the document's own check).
                .query, .formula => {},
            }
        },
        .it => |addr| {
            const tier = itTier(doc, binding.anchor) orelse return;
            // The conductor's walk when this lane is bound to the anchor
            // that conducts — the usual shape, and the whole of plan 04's
            // skeleton — and a walk of its own otherwise.
            var local: ?walk.RowMap = null;
            defer if (local) |*l| l.deinit();
            const map: *const walk.RowMap = map: {
                if (doc.conductor) |id| {
                    if (std.mem.eql(u8, id, binding.anchor)) {
                        if (rowmap.*) |*r| break :map r;
                    }
                }
                local = try walk.derive(gpa, &tier.module, .{});
                break :map &local.?;
            };
            switch (lane.kind) {
                .notes => {
                    const notes = try bridge_it.boundNotes(gpa, &tier.module, map, addr.channel);
                    defer gpa.free(notes);
                    for (notes) |n| {
                        const at = itToTicks(n.at) orelse continue;
                        const end = itToTicks(n.at + @max(n.dur, 0)) orelse Grid.MAX_TICK;
                        try onsets.append(a, .{
                            .tick = at,
                            .dur = end - at,
                            .key = n.key,
                            .vel = n.vel,
                        });
                    }
                },
                .curve => {
                    const column = addr.column orelse return;
                    const read = try bridge_it.curveSteps(gpa, &tier.module, map, addr.channel, column, addr.fx);
                    defer gpa.free(read);
                    for (read) |s| {
                        const at = itToTicks(s.at) orelse continue;
                        try steps.append(a, normalised(at, s.value));
                    }
                },
                .query, .formula => {},
            }
        },
    }
}

/// One step of a bound curve. A bound lane has no authored easing, so
/// the segment between two of its values is `linear` — the name pacer
/// gives a straight line.
fn normalised(tick: i64, v: f32) Step {
    return .{ .tick = tick, .value = .{ v, 0, 0, 0 }, .ncomp = 1, .ease_src = "linear" };
}

/// The inline dump paired with `id`, or null when the anchor is
/// by-reference and nothing has read it.
fn smfTier(doc: *const Doc, id: value.AnchorId) ?*const value.SmfTier {
    for (doc.midi) |*t| {
        if (std.mem.eql(u8, t.anchor, id)) return t;
    }
    return null;
}

fn itTier(doc: *const Doc, id: value.AnchorId) ?*const value.ItTier {
    for (doc.it) |*t| {
        if (std.mem.eql(u8, t.anchor, id)) return t;
    }
    return null;
}

/// A clip's content, placed (plan 02, "(clip …)").
///
/// The phrase's own timeline runs `:repeat` times end to end; the window
/// is `[:offset, :offset + :length)` into it, `:length` defaulting to
/// what is left of the repeats; and a source tick `s` inside the window
/// lands at `:at + (s − :offset)`. Content past the window is NOT placed
/// — what a split clip's left half needs — and the measure is the
/// event's own onset, so a note that starts inside keeps its whole
/// duration.
fn place(
    a: std.mem.Allocator,
    doc: *const Doc,
    lane: *const value.Lane,
    clip: value.Clip,
    onsets: *std.ArrayList(Onset),
    steps: *std.ArrayList(Step),
    diags: *Diag.List,
) Error!void {
    // A clip naming no phrase, or a phrase with no lane of this name, is
    // `clip_lane_missing` — the document's own check (plan 02), raised
    // where the span lives. Here it simply places nothing.
    const phrase = doc.phraseByName(clip.phrase) orelse return;
    const from = laneOf(phrase, lane.name) orelse return;
    if (phrase.length <= 0) return;

    const repeat: i64 = @max(1, clip.repeat);
    const total = phrase.length * repeat;
    const window = clip.length orelse (total - clip.offset);
    if (window <= 0) return;

    var r: i64 = 0;
    while (r < repeat) : (r += 1) {
        const base = r * phrase.length;
        for (from.notes) |n| {
            const at = try placedTick(base + n.at, clip, window, diags) orelse continue;
            try onsets.append(a, .{
                .tick = at,
                .dur = n.dur,
                .key = transposed(n.key, clip.transpose),
                .vel = n.vel,
            });
        }
        for (from.keyframes) |k| {
            const at = try placedTick(base + k.at, clip, window, diags) orelse continue;
            try steps.append(a, .{
                .tick = at,
                .value = k.value,
                .ncomp = k.ncomp,
                .ease_src = try a.dupe(u8, k.ease_src),
            });
        }
    }
}

/// Where a source tick lands, or null when the window or the grid
/// ceiling refuses it.
fn placedTick(source: i64, clip: value.Clip, window: i64, diags: *Diag.List) Error!?i64 {
    if (source < clip.offset or source >= clip.offset + window) return null;
    const at = @as(i128, clip.at) + (source - clip.offset);
    if (at > Grid.MAX_TICK) {
        try diags.add(
            .tick_overflow,
            .err,
            clip.span,
            "this clip places content past the grid ceiling {d}; it is not placed",
            .{Grid.MAX_TICK},
        );
        return null;
    }
    return @intCast(at);
}

/// The phrase's lane of the same name — "a clip places the phrase's lane
/// of the same `:name` as this lane" (plan 02).
fn laneOf(phrase: *const value.Phrase, name: []const u8) ?*const value.Lane {
    for (phrase.lanes) |*l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

/// `:transpose` semitones, clamped to the key domain: a transposition
/// that would leave 0..127 has no key to name and holds at the edge.
fn transposed(key: u7, semitones: i8) u7 {
    return @intCast(std.math.clamp(@as(i16, key) + semitones, 0, 127));
}

/// Onsets sort by tick, then by key, velocity and duration — a total
/// order, so the list is the same on every host.
fn onsetBefore(_: void, x: Onset, y: Onset) bool {
    if (x.tick != y.tick) return x.tick < y.tick;
    if (x.key != y.key) return x.key < y.key;
    if (x.vel != y.vel) return x.vel < y.vel;
    return x.dur < y.dur;
}

/// Steps sort by tick alone, and the sort is stable, so two keyframes at
/// one tick keep document order.
fn stepBefore(_: void, x: Step, y: Step) bool {
    return x.tick < y.tick;
}

// ---- tests ----

const TPQ = Grid.TPQ;
const bar44 = 4 * TPQ;

/// A document owning its own arena, with the header every fixture needs.
fn fixtureDoc(gpa: std.mem.Allocator) Doc {
    return .empty(gpa);
}

test "derive: sections and cues come over in ticks, in document order" {
    const gpa = testing.allocator;
    var doc: Doc = fixtureDoc(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    var sections = [_]value.Section{
        .{ .name = "intro", .at = 0, .dur = bar44, .span = .{ .start = 0, .end = 1 } },
        .{ .name = "drop", .at = bar44 / 2, .dur = bar44, .span = .{ .start = 0, .end = 1 } },
    };
    var cues = [_]value.Cue{
        .{ .name = "one", .at = 0, .span = .{ .start = 0, .end = 1 } },
        .{ .name = "two", .at = 3 * TPQ, .span = .{ .start = 0, .end = 1 } },
    };
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.sections = &sections;
    doc.cues = &cues;
    doc.length = 2 * bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    // The names are COPIED into the derivation's own arena, so they are
    // compared as text and not as pointers.
    try testing.expectEqual(@as(usize, 2), d.sections.len);
    try testing.expectEqualStrings("intro", d.sections[0].name);
    try testing.expectEqual(@as(i64, 0), d.sections[0].at);
    try testing.expectEqual(@as(i64, 184_504_320), d.sections[0].dur);
    try testing.expectEqualStrings("drop", d.sections[1].name);
    try testing.expectEqual(@as(i64, 92_252_160), d.sections[1].at);
    try testing.expectEqual(@as(i64, 184_504_320), d.sections[1].dur);

    try testing.expectEqual(@as(usize, 2), d.cues.len);
    try testing.expectEqualStrings("one", d.cues[0].name);
    try testing.expectEqual(@as(i64, 0), d.cues[0].at);
    try testing.expectEqualStrings("two", d.cues[1].name);
    try testing.expectEqual(@as(i64, 138_378_240), d.cues[1].at);
    try testing.expectEqual(@as(i64, 369_008_640), d.map.length);
    try testing.expectEqual(@as(usize, 0), d.diags.items().len);
}

test "derive: a native notes lane, its clip expanded by :repeat and :transpose" {
    // Hand computation. TPQ = 46 126 080, so a quarter is 46 126 080
    // ticks, a bar of [4 4] is 184 504 320 and a 16th is 11 531 520.
    //
    // The phrase `fill` is one quarter long and holds two notes, at 0
    // and at 0.5q = 23 063 040. The clip sits at 1bar = 184 504 320 with
    // `:repeat 2` and `:transpose 12`, so the phrase's own timeline is
    // two quarters long and every note lands twelve semitones up:
    //
    //   r0 note 0    → 184 504 320 + 0          = 184 504 320  key 50
    //   r0 note 0.5q → 184 504 320 + 23 063 040 = 207 567 360  key 50
    //   r1 note 0    → 184 504 320 + 46 126 080 = 230 630 400  key 50
    //   r1 note 0.5q → 184 504 320 + 69 189 120 = 253 693 440  key 50
    //
    // The lane's own two notes come first: 0 and 1q.
    const gpa = testing.allocator;
    var doc: Doc = fixtureDoc(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };

    var phrase_notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 4, .key = 38, .vel = 100, .ch = 0, .off_vel = null, .span = span },
        .{ .at = TPQ / 2, .dur = TPQ / 4, .key = 38, .vel = 80, .ch = 0, .off_vel = null, .span = span },
    };
    var phrase_lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    var phrases = [_]value.Phrase{.{
        .name = "fill",
        .length = TPQ,
        .lanes = &phrase_lanes,
        .span = span,
    }};

    var notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 2, .key = 36, .vel = 110, .ch = 0, .off_vel = null, .span = span },
        .{ .at = TPQ, .dur = TPQ / 2, .key = 38, .vel = 90, .ch = 0, .off_vel = null, .span = span },
    };
    var clips = [_]value.Clip{.{
        .at = bar44,
        .phrase = "fill",
        .repeat = 2,
        .offset = 0,
        .length = null,
        .transpose = 12,
        .span = span,
    }};
    var lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &notes,
        .keyframes = &.{},
        .clips = &clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};

    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.phrases = &phrases;
    doc.lanes = &lanes;
    doc.length = 2 * bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lane = d.laneByName("flash").?;
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = 23_063_040, .key = 36, .vel = 110 },
        .{ .tick = 46_126_080, .dur = 23_063_040, .key = 38, .vel = 90 },
        .{ .tick = 184_504_320, .dur = 11_531_520, .key = 50, .vel = 100 },
        .{ .tick = 207_567_360, .dur = 11_531_520, .key = 50, .vel = 80 },
        .{ .tick = 230_630_400, .dur = 11_531_520, .key = 50, .vel = 100 },
        .{ .tick = 253_693_440, .dur = 11_531_520, .key = 50, .vel = 80 },
    }, lane.onsets);
}

test "derive: a clip's :offset and :length window, content past it not placed" {
    // Hand computation. The same one-quarter phrase, `:repeat 2` so its
    // own timeline is [0, 2q) holding notes at 0, 0.5q, 1q and 1.5q. The
    // clip takes `:offset 0.5q :length 1q`, so the window is
    // [0.5q, 1.5q) and the note at 0 is BEFORE it while the note at
    // 1.5q is past it — both dropped. The two inside land at
    //
    //   0.5q → 0 + (23 063 040 − 23 063 040) = 0
    //   1q   → 0 + (46 126 080 − 23 063 040) = 23 063 040
    const gpa = testing.allocator;
    var doc: Doc = fixtureDoc(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };

    var phrase_notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 4, .key = 38, .vel = 100, .ch = 0, .off_vel = null, .span = span },
        .{ .at = TPQ / 2, .dur = TPQ / 4, .key = 38, .vel = 80, .ch = 0, .off_vel = null, .span = span },
    };
    var phrase_lanes = [_]value.Lane{.{
        .name = "spark",
        .kind = .notes,
        .target = "spark",
        .range = null,
        .binding = null,
        .notes = &phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    var phrases = [_]value.Phrase{.{ .name = "fill", .length = TPQ, .lanes = &phrase_lanes, .span = span }};

    var clips = [_]value.Clip{.{
        .at = 0,
        .phrase = "fill",
        .repeat = 2,
        .offset = TPQ / 2,
        .length = TPQ,
        .transpose = 0,
        .span = span,
    }};
    var lanes = [_]value.Lane{.{
        .name = "spark",
        .kind = .notes,
        .target = "spark",
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &.{},
        .clips = &clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};

    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.phrases = &phrases;
    doc.lanes = &lanes;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lane = d.laneByName("spark").?;
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = 11_531_520, .key = 38, .vel = 80 },
        .{ .tick = 23_063_040, .dur = 11_531_520, .key = 38, .vel = 100 },
    }, lane.onsets);
}

test "derive: a curve lane's keyframes become steps in tick order" {
    const gpa = testing.allocator;
    var doc: Doc = fixtureDoc(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };

    var keyframes = [_]value.Keyframe{
        .{ .at = 0, .value = .{ 0.2, 0, 0, 0 }, .ncomp = 1, .ease_src = "hold", .span = span },
        .{ .at = 4 * TPQ, .value = .{ 0.9, 0, 0, 0 }, .ncomp = 1, .ease_src = "in-cubic", .span = span },
    };
    var lanes = [_]value.Lane{.{
        .name = "glow",
        .kind = .curve,
        .target = "glow",
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &keyframes,
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.lanes = &lanes;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lane = d.laneByName("glow").?;
    try testing.expectEqual(@as(usize, 2), lane.steps.len);
    try testing.expectEqual(@as(i64, 0), lane.steps[0].tick);
    try testing.expectEqual(@as(f32, 0.2), lane.steps[0].value[0]);
    try testing.expectEqualStrings("hold", lane.steps[0].ease_src);
    try testing.expectEqual(@as(i64, 184_504_320), lane.steps[1].tick);
    try testing.expectEqualStrings("in-cubic", lane.steps[1].ease_src);
    try testing.expectEqual(@as(usize, 0), lane.onsets.len);
}

test "derive: the default :length is the last content rounded up to a bar" {
    // Hand computation: the last note ends at 1q + 0.5q = 1.5q =
    // 69 189 120, and the first bar line at or after that is bar 1,
    // 184 504 320.
    const gpa = testing.allocator;
    var doc: Doc = fixtureDoc(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    var notes = [_]value.Note{
        .{ .at = TPQ, .dur = TPQ / 2, .key = 36, .vel = 100, .ch = 0, .off_vel = null, .span = span },
    };
    var lanes = [_]value.Lane{.{
        .name = "kick",
        .kind = .notes,
        .target = "kick",
        .range = null,
        .binding = null,
        .notes = &notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.lanes = &lanes;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(i64, 184_504_320), d.map.length);
}

test "derive: the default :length counts a clip's whole window" {
    // Hand computation. The phrase is FOUR bars long and its only note
    // sits at its start; the clip places it at 1bar, so the window runs
    // to 1bar + 4bar = 5bar = 922 521 600 while the last note it places
    // ends a quarter of a quarter into bar 1. Plan 02 counts "the end of
    // the last event OR CLIP", so the length is the window's end.
    const gpa = testing.allocator;
    var doc: Doc = fixtureDoc(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    var phrase_notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 4, .key = 38, .vel = 100, .ch = 0, .off_vel = null, .span = span },
    };
    var phrase_lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    var phrases = [_]value.Phrase{.{ .name = "fill", .length = 4 * bar44, .lanes = &phrase_lanes, .span = span }};
    var clips = [_]value.Clip{.{
        .at = bar44,
        .phrase = "fill",
        .repeat = 1,
        .offset = 0,
        .length = null,
        .transpose = 0,
        .span = span,
    }};
    var lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &.{},
        .clips = &clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.phrases = &phrases;
    doc.lanes = &lanes;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(i64, 922_521_600), d.map.length);
}

test "derive.echo: the map, then the sections, the cues and the lanes" {
    const gpa = testing.allocator;
    var doc: Doc = fixtureDoc(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    var sections = [_]value.Section{
        .{ .name = "intro", .at = 0, .dur = bar44, .span = span },
    };
    var cues = [_]value.Cue{
        .{ .name = "bar 2", .at = bar44, .span = span },
    };
    var notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 2, .key = 36, .vel = 110, .ch = 0, .off_vel = null, .span = span },
        .{ .at = TPQ, .dur = TPQ / 2, .key = 38, .vel = 90, .ch = 0, .off_vel = null, .span = span },
    };
    var lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.sections = &sections;
    doc.cues = &cues;
    doc.lanes = &lanes;
    doc.length = 2 * bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    // The map's own four lines are `TimeMap.echo`'s, pinned by its own
    // test: 500 000 microseconds per quarter is 92 252 160 ticks per
    // second (0x4195FEA000000000) and two bars of [4 4] at that tempo
    // are four seconds (0x4010000000000000).
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try d.echo(&w);
    try testing.expectEqualStrings(
        \\(segment :tick 0 :us 500000 :tps "4195FEA000000000" :start-sec "0000000000000000")
        \\(meter :tick 0 :sig [4 4] :first-bar 0)
        \\(bars :count 3 :last-start 369008640)
        \\(length :tick 369008640 :end hold :loop-secs "4010000000000000")
        \\(section :name intro :at 0 :dur 184504320)
        \\(cue :name "bar 2" :at 184504320)
        \\(lane :name flash :kind notes :onsets 2 :first 0 :last 46126080)
        \\
    , w.buffered());
}

// ---- tests: the three conductors ----

/// The three-segment map of plan 03, phase 3, authored natively: 125,
/// 150 and 200 quarter notes per minute at ticks 0, 1q and 2q, one bar
/// of [4 4] long.
///
/// 60 000 000 / 125 = 480 000 microseconds per quarter note, / 150 =
/// 400 000 and / 200 = 300 000 — all three integers, so the map takes
/// the integer path whichever conductor built it.
fn nativeThreeSegments(gpa: std.mem.Allocator) Doc {
    var doc: Doc = .empty(gpa);
    const a = doc.arena.allocator();
    const tempo = a.alloc(tm.TempoPoint, 3) catch unreachable;
    tempo[0] = .{ .tick = 0, .tempo = .{ .us = 480_000 } };
    tempo[1] = .{ .tick = TPQ, .tempo = .{ .us = 400_000 } };
    tempo[2] = .{ .tick = 2 * TPQ, .tempo = .{ .us = 300_000 } };
    const meter = a.alloc(tm.MeterPoint, 1) catch unreachable;
    meter[0] = .{ .tick = 0, .n = 4, .d = 4 };
    doc.tempo = tempo;
    doc.meter = meter;
    doc.length = bar44;
    return doc;
}

/// One anchor, by id, of the kind the tier that follows it carries.
fn anchorsOf(doc: *Doc, kind: value.AnchorKind) []value.Anchor {
    const a = doc.arena.allocator();
    const out = a.alloc(value.Anchor, 1) catch unreachable;
    out[0] = .{
        .id = "song",
        .kind = kind,
        .file = "song",
        .size = null,
        .sha256 = null,
        .sha256_src = null,
        .inline_dump = true,
        .resolved = true,
        .span = .{ .start = 0, .end = 1 },
    };
    return out;
}

test "derive: an SMF conductor — set-tempo on track 2, merged by tick" {
    // Hand computation. Division 960 pulses per quarter divides TPQ
    // exactly (46 126 080 / 960 = 48 048), so SMF tick 960 is 1q =
    // 46 126 080 and 1920 is 2q = 92 252 160. The tempo events sit on
    // track 2 (index 1) and the midi set's rule that tempo on ANY track
    // is honoured is what makes them the conductor's.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    _ = try b.addTrack();
    try b.addEvent(1, 0, .set_tempo, .{ .tempo = 480_000 });
    try b.addEvent(1, 960, .set_tempo, .{ .tempo = 400_000 });
    try b.addEvent(1, 1920, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(0, 1920, .end_of_track, .empty);
    try b.addEvent(1, 1920, .end_of_track, .empty);
    const seq = try b.finish();

    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    var native = nativeThreeSegments(gpa);
    defer native.deinit();
    var n = try derive(gpa, &native);
    defer n.deinit();

    var smf_buf: [1024]u8 = undefined;
    var native_buf: [1024]u8 = undefined;
    var wa = std.Io.Writer.fixed(&smf_buf);
    var wb = std.Io.Writer.fixed(&native_buf);
    try d.echo(&wa);
    try n.echo(&wb);
    try testing.expectEqualStrings(wb.buffered(), wa.buffered());

    try testing.expectEqual(@as(usize, 3), d.map.segments.len);
    try testing.expectEqual(@as(i64, 46_126_080), d.map.segments[1].tick);
    try testing.expectEqual(@as(f64, 400_000), d.map.segments[1].us);
    try testing.expect(d.map.integral);
    try testing.expectEqual(@as(usize, 0), d.diags.items().len);
}

/// The same three segments as an Impulse Tracker module.
///
/// Speed 6 and 24 ticks to the quarter make a row a 16th note, so row 4
/// is 1q and row 8 is 2q. Pattern 1 is the one-row `B01` that jumps to
/// itself: the walk ends at the second visit of that row, with the state
/// it left pattern 0 in — so the module plays its tempo changes ONCE and
/// the segment table is the three the document authored.
pub fn threeSegmentModule(gpa: std.mem.Allocator) !Module.Module {
    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    try b.addOrder(0);
    try b.addOrder(1);
    const song = try b.addPattern(16);
    // `Txx` with xx >= 0x20 sets the tempo: 0x96 = 150, 0xC8 = 200.
    song.at(4, 0).* = .{ .fx = 'T' - '@', .param = 150 };
    song.at(8, 0).* = .{ .fx = 'T' - '@', .param = 200 };
    const tail = try b.addPattern(1);
    tail.at(0, 0).* = .{ .fx = 'B' - '@', .param = 1 };
    return b.finish();
}

test "derive: an IT conductor — Txx rows through the timing walk" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    const module = try threeSegmentModule(gpa);
    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    doc.anchors = anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.it = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    var native = nativeThreeSegments(gpa);
    defer native.deinit();
    var n = try derive(gpa, &native);
    defer n.deinit();

    var it_buf: [1024]u8 = undefined;
    var native_buf: [1024]u8 = undefined;
    var wa = std.Io.Writer.fixed(&it_buf);
    var wb = std.Io.Writer.fixed(&native_buf);
    try d.echo(&wa);
    try n.echo(&wb);
    try testing.expectEqualStrings(wb.buffered(), wa.buffered());

    // The walk's own map comes back with the derivation, so a studio
    // reads the tracker position from it (`Playhead.orderRowAt`).
    try testing.expect(d.rowmap != null);
    try testing.expectEqual(@as(i64, 102), d.rowmap.?.total_ticks);
    try testing.expectEqual(@as(usize, 0), d.diags.items().len);
}

test "derive: an IT T0x slide yields one tempo segment per tick" {
    // Hand computation. Speed 6, tempo 125; `T01` on row 0 slides the
    // tempo DOWN by one on every non-row tick, so IT ticks 1..5 carry
    // 124, 123, 122, 121 and 120 — five changes plus the initial
    // segment. One IT tick is 1 921 920 tempura ticks.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    try b.addOrder(0);
    try b.addOrder(1);
    const song = try b.addPattern(1);
    song.at(0, 0).* = .{ .fx = 'T' - '@', .param = 0x01 };
    const tail = try b.addPattern(1);
    tail.at(0, 0).* = .{ .fx = 'B' - '@', .param = 1 };
    const module = b.finish();

    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    doc.anchors = anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.it = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 6), d.map.segments.len);
    for (d.map.segments, 0..) |s, i| {
        try testing.expectEqual(@as(i64, @intCast(i)) * Grid.IT_TICK, s.tick);
    }
    // 60 000 000 / 124 is not an integer, so the whole table takes the
    // f64 path (plan 03, "The segment table").
    try testing.expect(!d.map.integral);
}

test "derive: conductor_conflict — one owner of time per document" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    const a = doc.arena.allocator();
    const tempo = try a.alloc(tm.TempoPoint, 1);
    tempo[0] = .{ .tick = 0, .tempo = .{ .us = 500_000 }, .span = .{ .start = 12, .end = 40 } };
    const meter = try a.alloc(tm.MeterPoint, 1);
    meter[0] = .{ .tick = 0, .n = 3, .d = 4, .span = .{ .start = 41, .end = 70 } };
    doc.tempo = tempo;
    doc.meter = meter;
    doc.anchors = anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 2), d.diags.count(.conductor_conflict));
    try testing.expectEqual(@as(u32, 12), d.diags.items()[0].span.start);
    // The anchor has no dump to conduct with, so the tables fall back to
    // 120 quarter notes per minute in [4 4] — the document's own points
    // are refused, never silently honoured.
    try testing.expectEqual(@as(usize, 1), d.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), d.map.segments[0].us);
    try testing.expectEqual(@as(u8, 4), d.map.meters[0].n);
}

test "derive: an SMF conductor with SMPTE division is one 120 qpm segment" {
    // Plan 03, rule 2: SMPTE ticks are wall-clock by definition, so the
    // file's `set-tempo` events are ignored for timing and said so.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .smpte = .{ .fps = 25, .tpf = 40 } };
    _ = try b.addTrack();
    try b.addEvent(0, 0, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(0, 500, .end_of_track, .empty);
    const seq = try b.finish();

    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), d.map.segments[0].us);
    try testing.expectEqual(@as(usize, 1), d.diags.count(.smpte_tempo_ignored));
}

test "derive: an SMF division that does not divide TPQ says division_inexact once" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    // 500 does not divide 46 126 080 (plan 03, "The grid").
    b.division = .{ .ppq = 500 };
    _ = try b.addTrack();
    try b.addEvent(0, 1, .set_tempo, .{ .tempo = 400_000 });
    try b.addEvent(0, 3, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(0, 3, .end_of_track, .empty);
    const seq = try b.finish();

    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.diags.count(.division_inexact));
    // A file whose first tempo comes late plays at 120 until it: the
    // table opens with the SMF default at tick 0.
    try testing.expectEqual(@as(usize, 3), d.map.segments.len);
    try testing.expectEqual(@as(i64, 0), d.map.segments[0].tick);
    try testing.expectEqual(@as(f64, 500_000), d.map.segments[0].us);
}

test "derive: equal SMF ticks keep file order and the last set-tempo wins" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    _ = try b.addTrack();
    // Track 1 and track 2 both name tick 0; the LAST in file order wins.
    try b.addEvent(0, 0, .set_tempo, .{ .tempo = 480_000 });
    try b.addEvent(1, 0, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(0, 0, .end_of_track, .empty);
    try b.addEvent(1, 0, .end_of_track, .empty);
    const seq = try b.finish();

    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.map.segments.len);
    try testing.expectEqual(@as(f64, 300_000), d.map.segments[0].us);
}

test "derive: an SMF time-signature is the meter map" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    // `nn` 3 over `dd` 2, which is 2^2 = 4: three quarter notes to a bar.
    try b.addEvent(0, 0, .time_signature, .{ .time_sig = .{ .nn = 3, .dd = 2, .cc = 24, .bb = 8 } });
    try b.addEvent(0, 2880, .end_of_track, .empty);
    const seq = try b.finish();

    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.map.meters.len);
    try testing.expectEqual(@as(u8, 3), d.map.meters[0].n);
    try testing.expectEqual(@as(u8, 4), d.map.meters[0].d);
    // Three tracks' worth of nothing: the SMF's own end is 2880 pulses =
    // 3q = 138 378 240 ticks, which is exactly one [3 4] bar, so the
    // default `:length` is that bar line.
    try testing.expectEqual(@as(i64, 138_378_240), d.map.length);
}

test "derive: an IT highlight becomes the meter, [major/minor 4]" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    // 12 rows to the measure, 4 to the beat — three beats a bar.
    b.module.header.highlight_minor = 4;
    b.module.header.highlight_major = 12;
    try b.addOrder(0);
    _ = try b.addPattern(4);
    const module = b.finish();

    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    doc.anchors = anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.it = tiers;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(u8, 3), d.map.meters[0].n);
    try testing.expectEqual(@as(u8, 4), d.map.meters[0].d);
}

// ---- tests: bound lanes ----

test "derive: a bound SMF notes lane, paired and converted to the grid" {
    // Hand computation. Division 960 divides TPQ (46 126 080 / 960 =
    // 48 048), so SMF tick 480 is 480 · 48 048 = 23 063 040 = half a
    // quarter. The note-on at 0 is closed by the note-off at 480.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    try b.addEvent(0, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(0, 480, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
    try b.addEvent(0, 0, .control_change, .{ .control = .{ .ch = 0, .num = 74, .val = 0 } });
    try b.addEvent(0, 480, .control_change, .{ .control = .{ .ch = 0, .num = 74, .val = 127 } });
    try b.addEvent(0, 960, .end_of_track, .empty);
    const seq = try b.finish();

    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    const lanes = try a.alloc(value.Lane, 2);
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    lanes[0] = .{
        .name = "lead",
        .kind = .notes,
        .target = "lead",
        .range = null,
        .binding = .{
            .anchor = "song",
            .address = .{ .smf = .{ .track = 1, .ch = 0, .key = null, .curve = null } },
        },
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    lanes[1] = .{
        .name = "cutoff",
        .kind = .curve,
        .target = "cutoff",
        .range = null,
        .binding = .{
            .anchor = "song",
            .address = .{ .smf = .{ .track = 1, .ch = 0, .key = null, .curve = .{ .cc = 74 } } },
        },
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    doc.anchors = anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.lanes = lanes;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lead = d.laneByName("lead").?;
    try testing.expect(lead.bound);
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = 23_063_040, .key = 60, .vel = 100 },
    }, lead.onsets);

    // A bound curve's value stays NORMALISED; `:range` scales it at
    // export (plan 02), so nothing here knows what it drives.
    const cutoff = d.laneByName("cutoff").?;
    try testing.expectEqual(@as(usize, 2), cutoff.steps.len);
    try testing.expectEqual(@as(i64, 0), cutoff.steps[0].tick);
    try testing.expectEqual(@as(f32, 0), cutoff.steps[0].value[0]);
    try testing.expectEqual(@as(i64, 23_063_040), cutoff.steps[1].tick);
    try testing.expectEqual(@as(f32, 1), cutoff.steps[1].value[0]);
}

test "derive: a bound IT notes lane reads the module through the walk" {
    // Hand computation. Speed 6, so a row is six IT ticks: the note on
    // row 0 of channel 1 sounds at IT tick 0 and the `===` on row 2 ends
    // it at IT tick 12. One IT tick is 1 921 920 tempura ticks, so the
    // note is 23 063 040 long — half a quarter.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(4);
    pat.at(0, 1).* = .{ .note = 60, .ins = 1 };
    pat.at(2, 1).* = .{ .note = Module.note_off, .ins = 0 };
    const module = b.finish();

    const a = doc.arena.allocator();
    const tiers = try a.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    const lanes = try a.alloc(value.Lane, 1);
    lanes[0] = .{
        .name = "bass",
        .kind = .notes,
        .target = "bass",
        .range = null,
        .binding = .{
            .anchor = "song",
            .address = .{ .it = .{ .channel = 1, .column = null, .fx = null } },
        },
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = .{ .start = 0, .end = 1 },
    };
    doc.anchors = anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.it = tiers;
    doc.lanes = lanes;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const bass = d.laneByName("bass").?;
    try testing.expect(bass.bound);
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = 23_063_040, .key = 60, .vel = 127 },
    }, bass.onsets);
}
