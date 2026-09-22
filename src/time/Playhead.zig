//! Position queries: what an editor or a host asks of a derived document
//! (plan 03, "Position queries (`Playhead`)" and "Phases" item 4).
//!
//! Every one of them is a LOOKUP over `Derived` — the tempo map, the bar
//! table, the section and cue lists, the per-lane onsets — and none of
//! them is evaluation: `curveAt` hands back the two keyframes around a
//! tick and the easing named between them, never an interpolated value
//! (plan 00's non-goal).
//!
//! The wasm exports mirror these (plan 10), which is why the answers are
//! plain values and the only allocating queries are the two that answer
//! with a SET.

const std = @import("std");
const testing = std.testing;

const Diag = @import("../Diag.zig");
const Grid = @import("Grid.zig");
const Pos = @import("Pos.zig");
const tm = @import("TimeMap.zig");
const derive_file = @import("derive.zig");
const value = @import("../doc/Value.zig");
const walk = @import("../itf/walk.zig");
const test_support = @import("test_support.zig");

const Derived = derive_file.Derived;
const Onset = derive_file.Onset;
const Step = derive_file.Step;
const Doc = value.Doc;

/// A query fails the way an allocation fails, or the way a host clock
/// does: `at` takes SECONDS from outside, so the two guards `TimeMap`
/// raises ride out with it.
pub const Error = error{ OutOfMemory, TickOverflow, NonFiniteTime };

/// The subdivisions `snap` offers. `qN` is the note value: `q4` is a
/// quarter, `q8` an eighth, `q12` a triplet eighth, `q16` a sixteenth
/// and `q32` a thirty-second; `beat` and `bar` are the meter's own
/// lines.
pub const SnapGrid = enum { q4, q8, q12, q16, q32, bar, beat };

/// Where the playhead is.
pub const Position = struct {
    tick: i64,
    bar: i64,
    beat: i64,
    sub_ticks: i64,
    seconds_into_bar: f64,
    /// Indices into `Derived.sections`, in document order — sections may
    /// overlap, so this is a set and not one answer.
    section_ids: []u32,
    /// Indices into `Derived.cues`.
    prev_cue: ?u32,
    next_cue: ?u32,
    /// The tracker position, for a document an IT anchor conducts.
    order_row: ?walk.Position,

    /// Frees `section_ids` with the `gpa` the query was handed — the one
    /// allocation a position carries; everything else is plain values.
    pub fn deinit(self: *Position, gpa: std.mem.Allocator) void {
        gpa.free(self.section_ids);
        self.* = undefined;
    }
};

/// The two keyframes around a tick — `curveAt`'s answer.
pub const Around = struct { before: ?Step, after: ?Step };

/// Where `seconds` lands, after the end behaviour (plan 03: `loop` wraps
/// in SECONDS and `hold` clamps, both BEFORE the conversion — wrapping
/// ticks instead would replay the loop at the final segment's tempo).
///
/// `section_ids` is allocated with `gpa`; `Position.deinit` frees it.
pub fn at(gpa: std.mem.Allocator, d: *const Derived, seconds: f64) Error!Position {
    d.invariants();
    const wrapped = d.map.wrapSeconds(seconds);
    const tick = try d.map.tickFromSeconds(wrapped);

    var pos = try position(gpa, d, tick);
    // The one field the CLOCK answers better than the grid does. A tick
    // is the last one BEGUN at `wrapped`, so `seconds(tick)` may sit an
    // ulp below the second that was actually asked about; the caller
    // asked about that second, and where inside the bar it fell is what
    // it wants back. Everything else is a property of the tick and is
    // computed once, in `atTick`.
    pos.seconds_into_bar = wrapped - d.map.secondsFromTick(barAt(d, tick).start);
    return pos;
}

/// The same answer, asked by TICK: the query an editor makes when the
/// playhead was dragged on the grid rather than on the clock, and the
/// one a golden corpus asks (plan 03's table, read from the grid side).
///
/// Not `at(secondsOf(tick))`: a clock value is the last tick BEGUN, so
/// that round trip lands one tick low at an interior tick (`TimeMap`'s
/// own header says so) and the question asked by tick would come back
/// about a different one. The two agree wherever the seam is exact,
/// which is every segment start.
///
/// `seconds_into_bar` is measured from the tick's own second here, which
/// is why `at` recomputes it from the second it was handed.
///
/// The error set is NARROWER than this module's by one fact: a tick is
/// already on the grid, so neither host guard `at` carries — a clock
/// past the ceiling, a clock that is not a number — can fire, and only
/// an allocation is left to fail. `Error` stays the module's set because
/// `at` needs all three.
///
/// `section_ids` is allocated with `gpa`; `Position.deinit` frees it.
pub fn atTick(gpa: std.mem.Allocator, d: *const Derived, tick: i64) error{OutOfMemory}!Position {
    d.invariants();
    return position(gpa, d, tick);
}

/// Where `tick` is — its bar, beat and second into the bar, the sections
/// over it, the nearest cue each way and the tracker position — over a
/// derivation the caller has already held to its invariants. Total over
/// `i64`; `section_ids` is allocated with `gpa`.
fn position(gpa: std.mem.Allocator, d: *const Derived, tick: i64) error{OutOfMemory}!Position {
    const where = d.map.barOf(tick);
    const bar_start = tick - (where.beat * Grid.beatTicks(where.meter.d) + where.sub_ticks);

    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(gpa);
    // A window is half-open `[at, at + dur)`, so a zero-length section
    // contains no tick at all; sections may overlap, and they come back
    // in document order.
    for (d.sections, 0..) |s, i| {
        if (s.at <= tick and tick < s.at + s.dur) try ids.append(gpa, @intCast(i));
    }

    // The cues are in DOCUMENT order, which is not tick order, so the
    // nearest one each way is searched rather than stepped to.
    var prev: ?u32 = null;
    var next: ?u32 = null;
    for (d.cues, 0..) |c, i| {
        if (c.at <= tick) {
            if (prev == null or c.at > d.cues[prev.?].at) prev = @intCast(i);
        } else {
            if (next == null or c.at < d.cues[next.?].at) next = @intCast(i);
        }
    }

    return .{
        .tick = tick,
        .bar = where.bar,
        .beat = where.beat,
        .sub_ticks = where.sub_ticks,
        .seconds_into_bar = d.map.secondsFromTick(tick) - d.map.secondsFromTick(bar_start),
        .section_ids = try ids.toOwnedSlice(gpa),
        .prev_cue = prev,
        .next_cue = next,
        .order_row = orderRowAt(d, tick),
    };
}

/// The inverse, for a scrub bar.
pub fn secondsOf(d: *const Derived, tick: i64) f64 {
    return d.map.secondsFromTick(tick);
}

/// The nearest grid line to `tick`, under the meter in force.
///
/// The lines of a subdivision are counted from the BAR LINE at or before
/// `tick`, not from tick 0: a `[7 8]` bar is three and a half quarters
/// long, so a quarter grid measured from the origin would drift off the
/// bar it belongs to. `swing` is a fraction of the step (0 is straight,
/// 0.5 puts the odd line halfway to the next) and offsets every SECOND
/// line, counting the bar's own line as 0. A tie resolves DOWN.
///
/// Total over `i64`, because `tpr_snap` hands a host's tick straight in:
/// a position is never negative and never past the grid's ceiling (plan
/// 03), so the tick is clamped into `[0, MAX_TICK]` first — which keeps
/// every sum below (the next bar's start, a line's offset in its bar)
/// inside `i64` — and the answer is a line on the grid.
pub fn snap(d: *const Derived, tick: i64, grid: SnapGrid, swing: f64) i64 {
    const t = std.math.clamp(tick, 0, Grid.MAX_TICK);
    var best: ?i64 = null;

    // This bar, the one before and the one after: a line near a bar line
    // may belong to either side, and a meter change or a bar length that
    // the step does not divide makes the neighbours' lines their own.
    const here = barAt(d, t);
    consider(&best, t, here, grid, swing);
    if (here.start > 0) consider(&best, t, barAt(d, here.start - 1), grid, swing);
    consider(&best, t, barAt(d, here.start + here.len), grid, swing);

    const snapped = best orelse t;
    // A line off the grid is never weighed, and `t` is clamped onto it.
    std.debug.assert(snapped >= 0);
    std.debug.assert(snapped <= Grid.MAX_TICK);
    return snapped;
}

/// The notes of `lane` whose `[at, at + dur)` contains `tick`, in onset
/// order. Allocated with `gpa`, the caller's to free; a zero-length note
/// sounds nowhere.
///
/// The error set is `atTick`'s, narrower than this module's: a tick is
/// already on the grid and the lane's list is already built, so only the
/// answer's allocation can fail.
pub fn sounding(
    gpa: std.mem.Allocator,
    d: *const Derived,
    lane: []const u8,
    tick: i64,
) error{OutOfMemory}![]Onset {
    var out: std.ArrayList(Onset) = .empty;
    errdefer out.deinit(gpa);
    if (d.laneByName(lane)) |l| {
        // The list is sorted by tick, so the answer is in onset order.
        for (l.onsets) |o| {
            if (o.tick <= tick and tick < o.tick + o.dur) try out.append(gpa, o);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The onsets of `lane` in `[from, to)` — a SUBSLICE of the lane's own
/// list, borrowed until the derivation is freed, because the census this
/// answers is read and never kept.
pub fn onsets(d: *const Derived, lane: []const u8, from: i64, to: i64) []const Onset {
    const l = d.laneByName(lane) orelse return &.{};
    if (to <= from) return l.onsets[0..0];
    const lo = lowerBound(l.onsets, from);
    const hi = lowerBound(l.onsets, to);
    return l.onsets[lo..hi];
}

/// The two keyframes around `tick` on a curve lane, and with them the
/// easing named between: `after.ease_src` shapes the segment ENDING at
/// `after` (pacer's semantics, plan 02). Before the first keyframe the
/// lane holds its first value and after the last its last, which is what
/// a null on either side says. NEVER the interpolated value (plan 00's
/// non-goal).
pub fn curveAt(d: *const Derived, lane: []const u8, tick: i64) Around {
    const l = d.laneByName(lane) orelse return .{ .before = null, .after = null };
    var out: Around = .{ .before = null, .after = null };
    for (l.steps) |s| {
        if (s.tick <= tick) out.before = s else {
            out.after = s;
            break;
        }
    }
    return out;
}

/// The tracker position at `tick` — `(order, row, tick_in_row)` — for a
/// document an IT anchor conducts, so a studio shows where the module is
/// with no renderer readback (plan 03; it 09's rule). Null for every
/// other document, and past the walk's end.
pub fn orderRowAt(d: *const Derived, tick: i64) ?walk.Position {
    if (d.rowmap == null) return null;
    // The walk counts IT ticks; a tempura tick inside one belongs to it.
    return walk.orderRowAt(&d.rowmap.?, @divFloor(tick, Grid.IT_TICK));
}

// ---- snap's parts ----

/// One bar: where it starts, how long it is, its number and its meter.
const Bar = struct { start: i64, len: i64, number: i64, seg: tm.MeterSeg };

/// The bar `tick` falls in. `tick >= 0`.
fn barAt(d: *const Derived, tick: i64) Bar {
    const where = d.map.barOf(tick);
    const start = tick - (where.beat * Grid.beatTicks(where.meter.d) + where.sub_ticks);
    return .{
        .start = start,
        .len = Grid.barTicks(where.meter.n, where.meter.d),
        .number = where.bar,
        .seg = where.meter,
    };
}

/// The lines one bar contributes near `t`, weighed against the best so
/// far. Only the indices around `t` are formed: the grid may be
/// thousands of lines long and the answer is always one of four.
fn consider(best: *?i64, t: i64, bar: Bar, grid: SnapGrid, swing: f64) void {
    if (grid == .bar) {
        // The bar lines themselves; the parity that swings is the bar
        // number.
        const off = if (@mod(bar.number, 2) == 0) 0 else swingTicks(bar.len, swing);
        weigh(best, t, bar.start + off);
        return;
    }

    const step = stepOf(grid, bar.seg);
    if (step <= 0) return;
    const off = swingTicks(step, swing);

    const k0 = @divFloor(t - bar.start, step);
    var k = k0 - 1;
    while (k <= k0 + 2) : (k += 1) {
        if (k < 0) continue;
        const from_start = k * step;
        // A line at or past the bar's end is the NEXT bar's line 0, and
        // that bar answers for it.
        if (from_start >= bar.len) break;
        weigh(best, t, bar.start + from_start + (if (@mod(k, 2) == 0) 0 else off));
    }
}

/// One line, weighed: nearer wins, and a tie resolves DOWN. A line off
/// the grid — before tick 0, or past the ceiling (the bar after the one
/// holding `MAX_TICK` starts there) — is no answer.
fn weigh(best: *?i64, t: i64, line: i64) void {
    if (line < 0 or line > Grid.MAX_TICK) return;
    const current = best.* orelse {
        best.* = line;
        return;
    };
    const d_new = @abs(line - t);
    const d_old = @abs(current - t);
    if (d_new < d_old or (d_new == d_old and line < current)) best.* = line;
}

/// A subdivision's step in ticks. `qN` is the note value — `q12` is a
/// triplet eighth, `TPQ / 3`, an integer on this grid — and `beat` is
/// the meter's own `4 / d` quarters.
fn stepOf(grid: SnapGrid, seg: tm.MeterSeg) i64 {
    return switch (grid) {
        .q4 => Grid.TPQ,
        .q8 => @divExact(Grid.TPQ, 2),
        .q12 => @divExact(Grid.TPQ, 3),
        .q16 => @divExact(Grid.TPQ, 4),
        .q32 => @divExact(Grid.TPQ, 8),
        .beat => Grid.beatTicks(seg.d),
        // `bar` never reaches here: it has no uniform step to name.
        .bar => 0,
    };
}

/// The swing offset of an odd line, as a fraction of the step.
///
/// The fraction is taken in QUARTERS and rounded by the one literal seam
/// (`Pos.tickFromQuarters`, plan 03's "literals round" half of the
/// rounding rule) rather than by a second `@round` of this file's own.
/// It is clamped inside the step, because an offset that reached the
/// next line would reorder the grid.
fn swingTicks(step: i64, swing: f64) i64 {
    if (swing == 0 or !std.math.isFinite(swing) or step <= 0) return 0;
    const quarters = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(Grid.TPQ)) * swing;
    const off = Pos.tickFromQuarters(quarters) catch return 0;
    return std.math.clamp(off, -(step - 1), step - 1);
}

/// The first onset at or after `tick`, by binary search over a list that
/// is sorted by tick.
fn lowerBound(list: []const Onset, tick: i64) usize {
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (list[mid].tick < tick) lo = mid + 1 else hi = mid;
    }
    // The boundary of a sorted list: everything before it is earlier than
    // `tick`, and the onset at it is not.
    if (lo > 0) std.debug.assert(list[lo - 1].tick < tick);
    if (lo < list.len) std.debug.assert(list[lo].tick >= tick);
    return lo;
}

// ---- tests ----

const TPQ = Grid.TPQ;
const bar44 = 4 * TPQ;
const bar34 = 3 * TPQ;

/// The fixture of plan 03, phase 4: overlapping sections, two cues, a
/// meter change and a tempo change.
///
/// Hand computation. Tempo: 500 000 microseconds a quarter (two quarters
/// a second) to tick 184 504 320, then 250 000 (four a second). Meter:
/// [4 4] to tick 369 008 640, then [3 4]. So the bar table is
///
///   bar 0 → 0            bar 1 → 184 504 320   bar 2 → 369 008 640
///   bar 3 → 507 386 880  bar 4 → 645 765 120
///
/// and the seconds at those ticks are 0, 2, 3, 3.75 and 4.5.
fn fixture(gpa: std.mem.Allocator, end: tm.End) !Doc {
    var doc: Doc = .empty(gpa);
    errdefer doc.deinit();
    const arena = doc.arena.allocator();

    doc.tempo = try arena.dupe(tm.TempoPoint, &.{
        .{ .tick = 0, .tempo = .{ .us = 500_000 } },
        .{ .tick = 184_504_320, .tempo = .{ .us = 250_000 } },
    });
    doc.meter = try arena.dupe(tm.MeterPoint, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
        .{ .tick = 369_008_640, .n = 3, .d = 4 },
    });
    doc.sections = try arena.dupe(value.Section, &.{
        .{ .name = "intro", .at = 0, .dur = 2 * bar44, .span = fixture_span },
        .{ .name = "drop", .at = bar44, .dur = 2 * bar44, .span = fixture_span },
    });
    doc.cues = try arena.dupe(value.Cue, &.{
        .{ .name = "a", .at = 184_504_320, .span = fixture_span },
        .{ .name = "b", .at = 507_386_880, .span = fixture_span },
    });
    doc.lanes = try fixtureLanes(arena);
    doc.length = 645_765_120;
    doc.end = end;
    return doc;
}

/// The one span every fixture node carries: none of these tests reads it.
const fixture_span: Diag.Span = .{ .start = 0, .end = 1 };

/// The fixture's two lanes: `kick`, three notes in the first half-bar,
/// and `glow`, a curve with a keyframe on each of the first three bar
/// lines. Every slice in `arena`.
fn fixtureLanes(arena: std.mem.Allocator) ![]value.Lane {
    const notes = try arena.dupe(value.Note, &.{
        fixtureNote(0, TPQ, 36, 100),
        fixtureNote(TPQ, 2 * TPQ, 38, 90),
        fixtureNote(2 * TPQ, TPQ / 2, 42, 80),
    });
    const keys = try arena.dupe(value.Keyframe, &.{
        fixtureKey(0, 0.2, "hold"),
        fixtureKey(184_504_320, 0.9, "in-cubic"),
        fixtureKey(369_008_640, 0.1, "linear"),
    });
    return arena.dupe(value.Lane, &.{
        fixtureLane("kick", .notes, notes, &.{}),
        fixtureLane("glow", .curve, &.{}, keys),
    });
}

fn fixtureNote(tick: i64, dur: i64, key: u7, vel: u7) value.Note {
    return .{
        .at = tick,
        .dur = dur,
        .key = key,
        .vel = vel,
        .ch = 0,
        .off_vel = null,
        .span = fixture_span,
    };
}

fn fixtureKey(tick: i64, v: f32, ease: []const u8) value.Keyframe {
    return .{
        .at = tick,
        .value = .{ v, 0, 0, 0 },
        .ncomp = 1,
        .ease_src = ease,
        .span = fixture_span,
    };
}

fn fixtureLane(
    name: []const u8,
    kind: value.LaneKind,
    notes: []value.Note,
    keys: []value.Keyframe,
) value.Lane {
    return .{
        .name = name,
        .kind = kind,
        .target = name,
        .range = null,
        .binding = null,
        .notes = notes,
        .keyframes = keys,
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = fixture_span,
    };
}

test "Playhead.at: tick 0 — the first section, no cue behind, the first ahead" {
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    var p = try at(gpa, &d, 0);
    defer p.deinit(gpa);

    try testing.expectEqual(@as(i64, 0), p.tick);
    try testing.expectEqual(@as(i64, 0), p.bar);
    try testing.expectEqual(@as(i64, 0), p.beat);
    try testing.expectEqual(@as(i64, 0), p.sub_ticks);
    try testing.expectEqual(@as(f64, 0), p.seconds_into_bar);
    try testing.expectEqualSlices(u32, &.{0}, p.section_ids);
    try testing.expect(p.prev_cue == null);
    try testing.expectEqual(@as(?u32, 0), p.next_cue);
    try testing.expect(p.order_row == null);
}

test "Playhead.at: two seconds in — bar 1, both sections, the cue behind" {
    // Two quarters a second, so 2 s is 4 quarters: tick 184 504 320,
    // which is bar 1's line, cue `a`'s tick and the start of `drop`.
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    var p = try at(gpa, &d, 2.0);
    defer p.deinit(gpa);

    try testing.expectEqual(@as(i64, 184_504_320), p.tick);
    try testing.expectEqual(@as(i64, 1), p.bar);
    try testing.expectEqual(@as(i64, 0), p.beat);
    try testing.expectEqual(@as(f64, 0), p.seconds_into_bar);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, p.section_ids);
    try testing.expectEqual(@as(?u32, 0), p.prev_cue);
    try testing.expectEqual(@as(?u32, 1), p.next_cue);
}

test "Playhead.at: inside a bar under the second tempo — beat and seconds into it" {
    // 2.5 s is half a second past bar 1's line, and the second segment
    // runs at four quarters a second: two quarters in, beat 2.
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    var p = try at(gpa, &d, 2.5);
    defer p.deinit(gpa);

    try testing.expectEqual(@as(i64, 276_756_480), p.tick);
    try testing.expectEqual(@as(i64, 1), p.bar);
    try testing.expectEqual(@as(i64, 2), p.beat);
    try testing.expectEqual(@as(i64, 0), p.sub_ticks);
    try testing.expectEqual(@as(f64, 0.5), p.seconds_into_bar);
}

test "Playhead.at: hold clamps at the length, loop wraps in seconds first" {
    const gpa = testing.allocator;
    {
        var doc = try fixture(gpa, .hold);
        defer doc.deinit();
        var d = try derive_file.derive(gpa, &doc);
        defer d.deinit();

        // The length is 4.5 s in; ten seconds hold there.
        var p = try at(gpa, &d, 10.0);
        defer p.deinit(gpa);
        try testing.expectEqual(@as(i64, 645_765_120), p.tick);
        try testing.expectEqual(@as(i64, 4), p.bar);
    }
    {
        var doc = try fixture(gpa, .loop);
        defer doc.deinit();
        var d = try derive_file.derive(gpa, &doc);
        defer d.deinit();

        // 5 s wraps to 0.5 s — half a second at two quarters a second is
        // one quarter, tick 46 126 080. Wrapping TICKS instead would
        // replay at the final segment's tempo, which is the bug the
        // ordering prevents.
        var p = try at(gpa, &d, 5.0);
        defer p.deinit(gpa);
        try testing.expectEqual(@as(i64, 46_126_080), p.tick);
        try testing.expectEqual(@as(i64, 0), p.bar);
        try testing.expectEqual(@as(i64, 1), p.beat);
    }
}

test "Playhead.secondsOf: the inverse of at, exact at a segment start" {
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(f64, 0), secondsOf(&d, 0));
    try testing.expectEqual(@as(f64, 2), secondsOf(&d, 184_504_320));
    try testing.expectEqual(@as(f64, 3), secondsOf(&d, 369_008_640));
    try testing.expectEqual(@as(f64, 4.5), secondsOf(&d, 645_765_120));
}

test "Playhead.snap: the nearest line, ties down" {
    // A sixteenth is 11 531 520 ticks. 5 000 000 is nearer 0; 5 765 760
    // is exactly halfway and the tie resolves DOWN; 6 000 000 is nearer
    // the line above.
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(i64, 0), snap(&d, 5_000_000, .q16, 0));
    try testing.expectEqual(@as(i64, 0), snap(&d, 5_765_760, .q16, 0));
    try testing.expectEqual(@as(i64, 11_531_520), snap(&d, 6_000_000, .q16, 0));
    try testing.expectEqual(@as(i64, 46_126_080), snap(&d, 50_000_000, .q4, 0));
    try testing.expectEqual(@as(i64, 23_063_040), snap(&d, 30_000_000, .q8, 0));
    // A triplet eighth is TPQ / 3 = 15 375 360, an integer on this grid.
    try testing.expectEqual(@as(i64, 15_375_360), snap(&d, 20_000_000, .q12, 0));
    try testing.expectEqual(@as(i64, 5_765_760), snap(&d, 3_000_000, .q32, 0));
}

test "Playhead.snap: bar and beat lines come from the meter in force" {
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(i64, 184_504_320), snap(&d, 100_000_000, .bar, 0));
    try testing.expectEqual(@as(i64, 0), snap(&d, 80_000_000, .bar, 0));
    // Bar 2 starts at 369 008 640 and is [3 4]: its beats are one
    // quarter apart, so 60 000 000 into it snaps to beat 1.
    try testing.expectEqual(@as(i64, 415_134_720), snap(&d, 429_008_640, .beat, 0));
    // Bar 3 starts one [3 4] bar later, at 507 386 880 — the line the
    // bar grid finds from inside bar 2.
    try testing.expectEqual(@as(i64, 507_386_880), snap(&d, 480_000_000, .bar, 0));
}

test "Playhead.snap: swing offsets every second line" {
    // An eighth is 23 063 040 and a swing of 0.5 pushes the ODD lines
    // half a step late: line 1 moves from 23 063 040 to 34 594 560.
    // 30 000 000 is 6 936 960 past the straight line 1 and 4 594 560
    // before the swung one.
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(i64, 34_594_560), snap(&d, 30_000_000, .q8, 0.5));
    // The even lines do not move.
    try testing.expectEqual(@as(i64, 0), snap(&d, 2_000_000, .q8, 0.5));
    try testing.expectEqual(@as(i64, 46_126_080), snap(&d, 45_000_000, .q8, 0.5));
}

test "Playhead.sounding: the notes whose window contains the tick, in onset order" {
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    {
        // [0, 1q) holds the first note and nothing else.
        const s = try sounding(gpa, &d, "kick", 0);
        defer gpa.free(s);
        try testing.expectEqual(@as(usize, 1), s.len);
        try testing.expectEqual(@as(u7, 36), s[0].key);
    }
    {
        // One tick past 1q the first note is over and the second is on.
        const s = try sounding(gpa, &d, "kick", 46_126_081);
        defer gpa.free(s);
        try testing.expectEqual(@as(usize, 1), s.len);
        try testing.expectEqual(@as(u7, 38), s[0].key);
    }
    {
        // At 2q the second note is still sounding and the third starts.
        const s = try sounding(gpa, &d, "kick", 92_252_160);
        defer gpa.free(s);
        try testing.expectEqual(@as(usize, 2), s.len);
        try testing.expectEqual(@as(u7, 38), s[0].key);
        try testing.expectEqual(@as(u7, 42), s[1].key);
    }
    {
        const s = try sounding(gpa, &d, "no-such-lane", 0);
        defer gpa.free(s);
        try testing.expectEqual(@as(usize, 0), s.len);
    }
}

test "Playhead.onsets: the census of a window, half-open" {
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 3), onsets(&d, "kick", 0, 300_000_000).len);
    try testing.expectEqual(@as(usize, 1), onsets(&d, "kick", 46_126_080, 92_252_160).len);
    try testing.expectEqual(
        @as(i64, 46_126_080),
        onsets(&d, "kick", 46_126_080, 92_252_160)[0].tick,
    );
    try testing.expectEqual(@as(usize, 0), onsets(&d, "kick", 1, 46_126_080).len);
    try testing.expectEqual(@as(usize, 0), onsets(&d, "glow", 0, 300_000_000).len);
}

test "Playhead.curveAt: the two keyframes around a tick and the easing between" {
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    {
        const c = curveAt(&d, "glow", 100_000_000);
        try testing.expectEqual(@as(i64, 0), c.before.?.tick);
        try testing.expectEqual(@as(i64, 184_504_320), c.after.?.tick);
        // The easing applies over the segment ENDING at the later
        // keyframe (pacer's semantics, plan 02).
        try testing.expectEqualStrings("in-cubic", c.after.?.ease_src);
    }
    {
        // On a keyframe: that one is `before`, the next is `after`.
        const c = curveAt(&d, "glow", 184_504_320);
        try testing.expectEqual(@as(i64, 184_504_320), c.before.?.tick);
        try testing.expectEqual(@as(i64, 369_008_640), c.after.?.tick);
    }
    {
        // Past the last, the lane holds its last value.
        const c = curveAt(&d, "glow", 600_000_000);
        try testing.expectEqual(@as(i64, 369_008_640), c.before.?.tick);
        try testing.expect(c.after == null);
    }
    {
        const c = curveAt(&d, "kick", 0);
        try testing.expect(c.before == null);
        try testing.expect(c.after == null);
    }
}

test "Playhead.orderRowAt: the tracker position, against the walk's row map" {
    // The three-segment module of `derive`: speed 6, so a row is six IT
    // ticks and row 4 starts at IT tick 24 — one quarter, 46 126 080
    // tempura ticks. One IT tick is 1 921 920 of them.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    const module = try test_support.threeSegmentModule(gpa);
    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    const anchors = try arena.alloc(value.Anchor, 1);
    anchors[0] = .{
        .id = "song",
        .kind = .it,
        .file = "song",
        .size = null,
        .sha256 = null,
        .sha256_src = null,
        .inline_dump = true,
        .resolved = true,
        .span = .{ .start = 0, .end = 1 },
    };
    doc.anchors = anchors;
    doc.conductor = "song";
    doc.it = tiers;

    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    const p = orderRowAt(&d, 46_126_080).?;
    try testing.expectEqual(@as(u16, 0), p.order);
    try testing.expectEqual(@as(u16, 4), p.row);
    try testing.expectEqual(@as(u16, 0), p.tick_in_row);

    const q = orderRowAt(&d, 46_126_080 + Grid.IT_TICK).?;
    try testing.expectEqual(@as(u16, 4), q.row);
    try testing.expectEqual(@as(u16, 1), q.tick_in_row);

    // Past the walk's 102 ticks there is no tracker position.
    try testing.expect(orderRowAt(&d, 102 * Grid.IT_TICK) == null);

    // And `at` carries it, so a studio reads one value.
    var pos = try at(gpa, &d, secondsOf(&d, 46_126_080));
    defer pos.deinit(gpa);
    try testing.expectEqual(@as(u16, 4), pos.order_row.?.row);
}

test "Playhead.orderRowAt: a document no IT anchor conducts has none" {
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    try testing.expect(orderRowAt(&d, 0) == null);
}

test "Playhead.snap: swing under a meter change, and a swung tie resolves down" {
    // Hand computation. Bar 2 starts at 369 008 640 and is [3 4], so its
    // beats are a quarter (46 126 080) apart and a swing of 0.5 pushes
    // the odd ones half a beat late:
    //
    //   beat 0 → 369 008 640   beat 1 → 415 134 720 + 23 063 040
    //                                 = 438 197 760   beat 2 → 461 260 800
    //
    // 430 000 000 is 8 197 760 below the swung beat 1 and 60 991 360
    // above beat 0, so the swung line wins — and bar 1's own beats, a
    // [4 4] bar away, are further still.
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(i64, 438_197_760), snap(&d, 430_000_000, .beat, 0.5));
    // Straight, the same tick snaps to beat 1 where it really sits.
    try testing.expectEqual(@as(i64, 415_134_720), snap(&d, 430_000_000, .beat, 0));
    // A bar line is line 0 of its own bar and never moves, so a tick just
    // below bar 2 snaps onto it and not onto bar 1's swung last beat.
    try testing.expectEqual(@as(i64, 369_008_640), snap(&d, 369_007_640, .beat, 0.5));

    // A swung line makes a tie of its own: an eighth is 23 063 040 and
    // the swung line 1 sits at 34 594 560, so 17 297 280 is exactly
    // halfway between it and line 0 — and a tie resolves DOWN.
    try testing.expectEqual(@as(i64, 0), snap(&d, 17_297_280, .q8, 0.5));
    // One tick past the middle it is the swung line's.
    try testing.expectEqual(@as(i64, 34_594_560), snap(&d, 17_297_281, .q8, 0.5));
}

test "Playhead.snap: a tick past the grid ceiling snaps onto the grid, never past it" {
    // `tpr_snap` hands a host's i64 straight in. `maxInt(i64)` used to be
    // clamped at 0 only, and the bar after it — `start + len` — and a
    // line's `start + from_start + off` overflowed. Past the ceiling the
    // answer is the ceiling's own: the tick is clamped into the grid
    // first, and a line past the ceiling is never weighed, as a line
    // before tick 0 is not.
    const gpa = testing.allocator;
    var doc = try fixture(gpa, .hold);
    defer doc.deinit();
    var d = try derive_file.derive(gpa, &doc);
    defer d.deinit();

    const grids = [_]SnapGrid{ .q4, .q8, .q12, .q16, .q32, .bar, .beat };
    for (grids) |g| {
        for ([_]f64{ 0, 0.5, -1 }) |swing| {
            const top = snap(&d, std.math.maxInt(i64), g, swing);
            try testing.expect(top >= 0);
            try testing.expect(top <= Grid.MAX_TICK);
            try testing.expectEqual(snap(&d, Grid.MAX_TICK, g, swing), top);
            try testing.expectEqual(@as(i64, 0), snap(&d, std.math.minInt(i64), g, swing));
        }
    }
}
