//! Quantize and nudge (plan 07, "The operations", the two rows that move
//! a selection by a RULE rather than by a number).
//!
//! Both are a `retime` whose only difference is where to, so this file
//! holds the where-to and `ops_native` does the moving: the same
//! `set_keyword :at` when the order holds, the same remove-and-insert
//! when it does not.

const std = @import("std");

const Grid = @import("../time/Grid.zig");
const TimeMap = @import("../time/TimeMap.zig");

const Op = @import("Op.zig");
const Snap = @import("Snap.zig");

const testing = std.testing;

/// Where a quantize puts `tick`.
///
/// `strength` is how far onto the line the tick travels: 1 lands on it,
/// 0.5 halves the distance, 0 leaves it alone. The fraction is taken of
/// the DISTANCE and rounded to a tick (half away from zero, so a tick
/// that is one away from the line at full strength still arrives), which
/// is what keeps a half-strength pass a musical smoothing rather than a
/// grid of its own.
pub fn quantized(
    map: *const TimeMap.TimeMap,
    tick: i64,
    grid: Snap.Grid,
    strength: f64,
    swing: f64,
) i64 {
    const line = Snap.nearest(map, tick, grid, swing);
    if (strength >= 1) return line;
    if (strength <= 0) return tick;
    const delta = line - tick;
    const moved = @as(f64, @floatFromInt(delta)) * strength;
    return tick + @as(i64, @intFromFloat(@round(moved)));
}

/// Where a nudge puts `tick`: by ticks, or by counted steps of a grid.
///
/// A step is counted from the tick's OWN bar, so nudging by one `1/8` in
/// a `[7 8]` bar moves by an eighth of that bar's own grid and a nudge
/// across a meter change lands where the next bar's grid says. Counting
/// is line by line, so a step that would leave the bar lands on the next
/// bar's line rather than on a tick no grid has.
pub fn nudged(map: *const TimeMap.TimeMap, tick: i64, delta: Op.Delta) i64 {
    switch (delta) {
        .ticks => |d| return tick +| d,
        .steps => |s| {
            var at = tick;
            var left = s.count;
            while (left > 0) : (left -= 1) at = nextLine(map, at, s.grid);
            while (left < 0) : (left += 1) at = previousLine(map, at, s.grid);
            return at;
        },
    }
}

/// The first line strictly after `tick`.
fn nextLine(map: *const TimeMap.TimeMap, tick: i64, grid: Snap.Grid) i64 {
    const step = stepOf(map, tick, grid);
    const at = Snap.nearest(map, tick +| step, grid, 0);
    return if (at > tick) at else tick +| step;
}

/// The last line strictly before `tick`.
fn previousLine(map: *const TimeMap.TimeMap, tick: i64, grid: Snap.Grid) i64 {
    const step = stepOf(map, @max(0, tick - 1), grid);
    const at = Snap.nearest(map, @max(0, tick -| step), grid, 0);
    return if (at < tick) at else @max(0, tick -| step);
}

/// The grid's step in the bar `tick` falls in.
fn stepOf(map: *const TimeMap.TimeMap, tick: i64, grid: Snap.Grid) i64 {
    const b = map.barOf(tick);
    return switch (grid) {
        .bar => Grid.barTicks(b.meter.n, b.meter.d),
        .beat => Grid.beatTicks(b.meter.d),
        .div => |n| @max(1, @divFloor(4 * Grid.TPQ, @as(i64, n))),
    };
}

// ---------------------------------------------------------------------------

const TPQ = Grid.TPQ;

fn fourFour(gpa: std.mem.Allocator) !TimeMap.Result {
    return TimeMap.derive(
        gpa,
        &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }},
        &.{.{ .tick = 0, .n = 4, .d = 4 }},
        16 * TPQ,
        .hold,
    );
}

test "ops_quantize: full strength lands on the line, half strength halves the distance" {
    const gpa = testing.allocator;
    var res = try fourFour(gpa);
    defer res.deinit();

    const eighth: Snap.Grid = .{ .div = 8 };
    const step = @divExact(TPQ, 2);
    const late = step + @divExact(TPQ, 8); // an eighth note plus a bit

    try testing.expectEqual(step, quantized(&res.map, late, eighth, 1, 0));
    // Half of the distance, rounded to a tick — and back the way it came.
    try testing.expectEqual(
        late - @divExact(TPQ, 16),
        quantized(&res.map, late, eighth, 0.5, 0),
    );
    // Zero strength is not an edit at all.
    try testing.expectEqual(late, quantized(&res.map, late, eighth, 0, 0));
}

test "ops_quantize: swing carries into the quantize" {
    const gpa = testing.allocator;
    var res = try fourFour(gpa);
    defer res.deinit();

    const eighth: Snap.Grid = .{ .div = 8 };
    const swung = @divExact(TPQ, 2) + @divExact(TPQ, 6);
    try testing.expectEqual(swung, quantized(&res.map, @divExact(TPQ, 2), eighth, 1, 1.0 / 3.0));
}

test "ops_quantize: nudge by ticks and by counted steps" {
    const gpa = testing.allocator;
    var res = try fourFour(gpa);
    defer res.deinit();

    try testing.expectEqual(@as(i64, 5), nudged(&res.map, 0, .{ .ticks = 5 }));
    try testing.expectEqual(@as(i64, 0), nudged(&res.map, 5, .{ .ticks = -5 }));

    // One sixteenth forward from a line, and two back from a quarter.
    const sixteenth: Snap.Grid = .{ .div = 16 };
    try testing.expectEqual(@divExact(TPQ, 4), nudged(&res.map, 0, .{ .steps = .{ .grid = sixteenth, .count = 1 } }));
    try testing.expectEqual(
        @divExact(TPQ, 2),
        nudged(&res.map, TPQ, .{ .steps = .{ .grid = sixteenth, .count = -2 } }),
    );
    // A nudge from between two lines lands on a line, not on the offset.
    try testing.expectEqual(
        @divExact(TPQ, 4),
        nudged(&res.map, 1000, .{ .steps = .{ .grid = sixteenth, .count = 1 } }),
    );
    // Never before the start of the timeline.
    try testing.expectEqual(@as(i64, 0), nudged(&res.map, 0, .{ .steps = .{ .grid = sixteenth, .count = -4 } }));
}

test "ops_quantize: a bar step crosses a meter change by the bars themselves" {
    const gpa = testing.allocator;
    var res = try TimeMap.derive(
        gpa,
        &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }},
        &.{
            .{ .tick = 0, .n = 4, .d = 4 },
            .{ .tick = 8 * TPQ, .n = 3, .d = 4 },
        },
        16 * TPQ,
        .hold,
    );
    defer res.deinit();

    // Bar 2 starts at 8q and bar 3 at 11q under [3 4].
    try testing.expectEqual(@as(i64, 8 * TPQ), nudged(&res.map, 4 * TPQ, .{ .steps = .{ .grid = .bar, .count = 1 } }));
    try testing.expectEqual(@as(i64, 11 * TPQ), nudged(&res.map, 8 * TPQ, .{ .steps = .{ .grid = .bar, .count = 1 } }));
}
