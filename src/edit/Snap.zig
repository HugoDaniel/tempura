//! Snapping (plan 07, "Snapping").
//!
//! The grid an editor draws and the grid an operation rounds to are the
//! same one: the lines a subdivision puts under the METER MAP, counted
//! from each bar's own start, so a meter change re-phases the grid the
//! way every tracker and every DAW does. All integer arithmetic on plan
//! 03's tick grid.
//!
//! A subdivision that does not divide a bar exactly — a `1/12` in a
//! `[7 8]` bar — simply stops at the bar line and starts again on the
//! next one, and says nothing about it: the grid is finer than audible
//! and the bar line is the honest nearest tick.

const std = @import("std");

const Grid_ = @import("../time/Grid.zig");
const TimeMap = @import("../time/TimeMap.zig");

const testing = std.testing;

pub const Error = error{OutOfMemory};

/// What an editor calls "the grid": a subdivision, a bar or a beat.
///
/// This is the edit engine's own type and not `time/Grid.zig`, which is
/// the tick grid's CONSTANTS (`TPQ`, `MAX_TICK`, the conversions). The
/// two never meet: one says how long a tick is, this one says where the
/// lines are.
pub const Grid = union(enum) {
    /// `1/n` of a whole note — 4 a quarter, 8 an eighth, 12 a triplet
    /// eighth, 16 a sixteenth, 32 a thirty-second.
    div: u16,
    /// One line per bar, under the meter in force.
    bar,
    /// One line per beat, under the meter in force.
    beat,

    /// How the CLI's `--op` JSON spells one: `1/8`, `1bar`, `1b`.
    pub fn parse(text: []const u8) ?Grid {
        if (std.mem.eql(u8, text, "1bar")) return .bar;
        if (std.mem.eql(u8, text, "1b")) return .beat;
        if (std.mem.startsWith(u8, text, "1/")) {
            const n = std.fmt.parseInt(u16, text[2..], 10) catch return null;
            if (n == 0) return null;
            return .{ .div = n };
        }
        return null;
    }
};

/// One bar of the map: where it starts, how long it is, and the step the
/// grid takes inside it.
const Window = struct {
    start: i64,
    len: i64,
    step: i64,

    /// The greatest `k` whose line still sits inside this bar.
    fn lastIndex(self: Window) i64 {
        if (self.len <= 0 or self.step <= 0) return 0;
        const n = @divFloor(self.len - 1, self.step);
        return n;
    }
};

/// How far one line of `grid` is from the next, in the bar `tick` falls
/// in — a bar's own length, a beat's, or a subdivision of a whole note.
///
/// Public because a nudge counts in these steps and a quantize snaps to
/// the lines they put down: one function, so the two cannot disagree
/// about how long a step is.
pub fn stepOf(map: *const TimeMap.TimeMap, tick: i64, grid: Grid) i64 {
    return windowOf(map, tick, grid).step;
}

fn windowOf(map: *const TimeMap.TimeMap, tick: i64, grid: Grid) Window {
    const b = map.barOf(tick);
    const beat_len = Grid_.beatTicks(b.meter.d);
    const bar_len = Grid_.barTicks(b.meter.n, b.meter.d);
    const start = @max(tick, 0) - (b.beat * beat_len + b.sub_ticks);
    return .{
        .start = start,
        .len = bar_len,
        .step = switch (grid) {
            .bar => bar_len,
            .beat => beat_len,
            // A subdivision is `1/n` of a WHOLE note, and a whole note is
            // four quarters. A division that is not exact floors, which
            // is under one tick of 2.2 microseconds at any tempo a
            // document can spell.
            .div => |n| @max(1, @divFloor(4 * Grid_.TPQ, @as(i64, n))),
        },
    };
}

/// Line `k` of `w`, with `swing` moving every second one.
///
/// `swing` in −1..1 offsets the odd lines by that fraction of the step —
/// the DAW convention, where +0.5 on eighths is the shuffle that lands
/// the off-beat two thirds of the way through the beat. A bar grid takes
/// no swing: there is no "every second bar" in the idea.
fn lineOf(w: Window, k: i64, grid: Grid, swing: f64) i64 {
    const base = w.start + k * w.step;
    if (grid == .bar or swing == 0 or @rem(k, 2) == 0) return base;
    const off = swing * @as(f64, @floatFromInt(w.step));
    // One multiply and a truncation toward zero: the offset is a
    // FRACTION of a step the caller chose, not a position a document
    // spelled, so it does not go through the literal seam.
    return base + @as(i64, @intFromFloat(@trunc(off)));
}

/// The grid lines in `[from, to)`, in order. Caller frees.
///
/// Every bar in the range contributes the lines its own meter puts in
/// it, counted from its own start — so the line after a `[4 4]` bar in a
/// `[3 4]` document is the next bar's downbeat and never a leftover of
/// the bar before.
pub fn lines(
    gpa: std.mem.Allocator,
    map: *const TimeMap.TimeMap,
    grid: Grid,
    from: i64,
    to: i64,
) Error![]i64 {
    var out: std.ArrayList(i64) = .empty;
    errdefer out.deinit(gpa);
    if (to <= from) return out.toOwnedSlice(gpa);

    var at: i64 = @max(from, 0);
    while (at < to) {
        const w = windowOf(map, at, grid);
        var k: i64 = 0;
        while (k <= w.lastIndex()) : (k += 1) {
            const line = w.start + k * w.step;
            if (line >= to) break;
            if (line >= from) try out.append(gpa, line);
        }
        const next = w.start + w.len;
        // A bar with no length would be a map defect, not a grid one;
        // stop rather than spin.
        if (next <= at) break;
        at = next;
    }
    return out.toOwnedSlice(gpa);
}

/// The grid line nearest `tick`, ties resolved DOWN.
///
/// Down and not to-even, because a snap is a musician's expectation: a
/// note exactly between two lines belongs to the one it has already
/// passed.
pub fn nearest(map: *const TimeMap.TimeMap, tick: i64, grid: Grid, swing: f64) i64 {
    if (tick <= 0) return 0;
    const lo = floorLine(map, tick, grid, swing);
    const hi = ceilLine(map, tick, grid, swing);
    return if (tick - lo <= hi - tick) lo else hi;
}

/// The index of the greatest line of `w` at or below `tick`.
///
/// Swing moves the odd lines, so the arithmetic guess can be one off in
/// either direction; walking it back is two comparisons, and it leaves
/// the post-condition the ceiling relies on — the NEXT line is strictly
/// above `tick`.
fn floorIndex(w: Window, tick: i64, grid: Grid, swing: f64) i64 {
    var k = @min(@divFloor(tick - w.start, w.step), w.lastIndex());
    if (k < 0) k = 0;
    while (k > 0 and lineOf(w, k, grid, swing) > tick) k -= 1;
    while (k < w.lastIndex() and lineOf(w, k + 1, grid, swing) <= tick) k += 1;
    return k;
}

/// The greatest line at or below `tick`.
fn floorLine(map: *const TimeMap.TimeMap, tick: i64, grid: Grid, swing: f64) i64 {
    const w = windowOf(map, tick, grid);
    return lineOf(w, floorIndex(w, tick, grid, swing), grid, swing);
}

/// The least line at or above `tick` — the next bar's downbeat when this
/// bar has no line left, which is what a subdivision that does not
/// divide the bar runs into.
fn ceilLine(map: *const TimeMap.TimeMap, tick: i64, grid: Grid, swing: f64) i64 {
    const w = windowOf(map, tick, grid);
    const k = floorIndex(w, tick, grid, swing);
    const line = lineOf(w, k, grid, swing);
    if (line >= tick) return line;
    if (k < w.lastIndex()) return lineOf(w, k + 1, grid, swing);
    return w.start + w.len;
}

// ---------------------------------------------------------------------------

const TPQ = Grid_.TPQ;

/// `[4 4]` for two bars, then `[3 4]`: the meter change every test here
/// needs, and the tempo map's default beside it.
fn changingMeter(gpa: std.mem.Allocator) !TimeMap.Result {
    return TimeMap.derive(
        gpa,
        &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }},
        &.{
            .{ .tick = 0, .n = 4, .d = 4 },
            .{ .tick = 8 * TPQ, .n = 3, .d = 4 },
        },
        16 * TPQ,
        .hold,
    );
}

test "Snap.lines: a subdivision re-phases at every bar of a meter change" {
    const gpa = testing.allocator;
    var res = try changingMeter(gpa);
    defer res.deinit();

    // Quarters across the change: bars 0 and 1 have four each, bar 2 has
    // three, and the line after 11q is bar 3's downbeat at 11q.
    const got = try lines(gpa, &res.map, .{ .div = 4 }, 0, 12 * TPQ);
    defer gpa.free(got);
    var want: [12]i64 = undefined;
    for (0..12) |i| want[i] = @as(i64, @intCast(i)) * TPQ;
    try testing.expectEqualSlices(i64, &want, got);

    // Bars: two of four quarters, then threes.
    const bars = try lines(gpa, &res.map, .bar, 0, 15 * TPQ);
    defer gpa.free(bars);
    try testing.expectEqualSlices(i64, &.{
        0,        4 * TPQ,
        8 * TPQ,  11 * TPQ,
        14 * TPQ,
    }, bars);

    // Half-open, and a range inside one bar keeps only its own lines.
    const inner = try lines(gpa, &res.map, .{ .div = 8 }, 9 * TPQ, 10 * TPQ);
    defer gpa.free(inner);
    try testing.expectEqualSlices(i64, &.{ 9 * TPQ, 9 * TPQ + @divExact(TPQ, 2) }, inner);
}

test "Snap.lines: a subdivision that does not divide the bar stops at the bar line" {
    const gpa = testing.allocator;
    var res = try TimeMap.derive(
        gpa,
        &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }},
        &.{.{ .tick = 0, .n = 7, .d = 8 }},
        16 * TPQ,
        .hold,
    );
    defer res.deinit();

    // A [7 8] bar is 3.5 quarters; a 1/12 line is a third of a quarter.
    // Eleven of them fit (the last at 3⅓ quarters), the twelfth would be
    // past the bar, and the line after it is the next bar's own start.
    const got = try lines(gpa, &res.map, .{ .div = 12 }, 0, 4 * TPQ);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 13), got.len);
    try testing.expectEqual(@as(i64, 10 * @divExact(TPQ, 3)), got[10]);
    try testing.expectEqual(@as(i64, 7 * @divExact(TPQ, 2)), got[11]);
    try testing.expectEqual(@as(i64, 7 * @divExact(TPQ, 2) + @divExact(TPQ, 3)), got[12]);
}

test "Snap.nearest: ties resolve down" {
    const gpa = testing.allocator;
    var res = try changingMeter(gpa);
    defer res.deinit();

    const half = @divExact(TPQ, 2);
    // Exactly between two quarter lines: the one already passed.
    try testing.expectEqual(@as(i64, 0), nearest(&res.map, half, .{ .div = 4 }, 0));
    try testing.expectEqual(@as(i64, TPQ), nearest(&res.map, half + 1, .{ .div = 4 }, 0));
    try testing.expectEqual(@as(i64, 0), nearest(&res.map, half - 1, .{ .div = 4 }, 0));

    // Across the meter change: 10.6q snaps to bar 2's second beat.
    try testing.expectEqual(@as(i64, 10 * TPQ), nearest(&res.map, 10 * TPQ + 1, .beat, 0));
    try testing.expectEqual(@as(i64, 11 * TPQ), nearest(&res.map, 11 * TPQ - 1, .bar, 0));
}

test "Snap.nearest: swing moves every second line by a fraction of the step" {
    const gpa = testing.allocator;
    var res = try changingMeter(gpa);
    defer res.deinit();

    const half = @divExact(TPQ, 2);
    const shuffled = half + @divExact(TPQ, 6); // a third of an eighth later
    const grid: Grid = .{ .div = 8 };

    // The off-beat eighth has MOVED: a note written there is exact, and
    // a note still on the straight line is pulled out to it.
    try testing.expectEqual(@as(i64, shuffled), nearest(&res.map, shuffled, grid, 1.0 / 3.0));
    try testing.expectEqual(@as(i64, shuffled), nearest(&res.map, half, grid, 1.0 / 3.0));
    // The even lines never move, and what sits near one still lands there.
    try testing.expectEqual(@as(i64, TPQ), nearest(&res.map, TPQ, grid, 1.0 / 3.0));
    try testing.expectEqual(@as(i64, 0), nearest(&res.map, 1000, grid, 1.0 / 3.0));
    // Straight, the same note is exactly on the line it was written on.
    try testing.expectEqual(@as(i64, half), nearest(&res.map, half, grid, 0));
}

test "Snap.Grid.parse: the three spellings the CLI takes" {
    try testing.expectEqual(Grid{ .div = 8 }, Grid.parse("1/8").?);
    try testing.expectEqual(Grid{ .div = 12 }, Grid.parse("1/12").?);
    try testing.expectEqual(Grid.bar, Grid.parse("1bar").?);
    try testing.expectEqual(Grid.beat, Grid.parse("1b").?);
    try testing.expect(Grid.parse("1/0") == null);
    try testing.expect(Grid.parse("quarter") == null);
}
