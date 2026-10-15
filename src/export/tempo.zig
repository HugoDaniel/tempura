//! The tempo a renderer writes: the map's segments, each with the
//! document point that made it.
//!
//! The map (`derived.map.segments`) is the one owner of which tempo
//! points count — it refuses a `:qpm -5`, a point that is not after the
//! one before it and every point past `MAX_TEMPO_SEGMENTS`, and it puts
//! a 120 QPM segment at tick 0 when the document has no usable point
//! there. A renderer that read `doc.tempo` instead wrote what the map had
//! refused (a `:qpm -5` became 500 000 µs in the `.mid`) and, in the
//! `.it`, took its initial tempo from the first point whatever its tick.
//! So both renderers walk the segments.
//!
//! What a segment has lost is the document's SPELLING: its `us` is
//! `60e6 / qpm` in f64, and `60e6 / us` does not give every whole
//! `:qpm` back to the last bit (`:qpm 102` comes back as
//! 101.99999999999999) — while an IT tempo is exact exactly when the
//! AUTHORED number is whole. So each segment comes paired with the point
//! behind it, found by the map's own division (`TimeMap.usOf`, the one
//! owner: a segment's `us` is that value bit for bit), with the point's
//! span for the diagnostics.
//!
//! Pure: no allocation, O(points + segments) for a whole walk, because
//! the map keeps points in document order and the walk's cursor only
//! moves forward.

const std = @import("std");

const Diag = @import("../Diag.zig");
const Grid = @import("../time/Grid.zig");
const TimeMap = @import("../time/TimeMap.zig");

const testing = std.testing;

/// One tempo segment of the map, and the document point that made it.
pub const Kept = struct {
    tick: i64,
    /// Microseconds per quarter note, the map's own (finite, positive).
    us: f64,
    /// Quarter notes per minute as the document SPELLED them: the point's
    /// own `:qpm`, or `60e6 / us` for a `:us` point and for the segment
    /// the map supplied at tick 0 when the document had none.
    qpm: f64,
    /// The point's span, or an empty one for a supplied segment.
    span: Diag.Span,
};

/// Walks `segments` in order, pairing each with its point of `points`.
///
/// Borrows both slices; the `Kept` values it answers borrow nothing.
pub const Walk = struct {
    segments: []const TimeMap.Segment,
    points: []const TimeMap.TempoPoint,
    seg: usize = 0,
    /// Every point before this one is behind a segment already walked or
    /// was refused.
    point: usize = 0,

    /// The walk over `map`'s segments and the `points` it was derived
    /// from — the document's own `tempo`, which is what `map` was built
    /// from whenever a renderer writes a conductor.
    pub fn init(map: *const TimeMap.TimeMap, points: []const TimeMap.TempoPoint) Walk {
        return .{ .segments = map.segments, .points = points };
    }

    /// The next segment, or null past the last.
    pub fn next(self: *Walk) ?Kept {
        if (self.seg >= self.segments.len) return null;
        const s = self.segments[self.seg];
        const first = self.seg == 0;
        self.seg += 1;
        const found = if (first) self.origin(s) else self.after(s);
        const p = found orelse return .{
            .tick = s.tick,
            .us = s.us,
            .qpm = TimeMap.US_PER_MINUTE / s.us,
            .span = .{ .start = 0, .end = 0 },
        };
        return .{ .tick = s.tick, .us = s.us, .qpm = qpmOf(p), .span = p.span };
    }

    /// Segment 0 is the document's first point exactly when that point
    /// sits at tick 0 with a tempo the map accepted — the map's own test
    /// — and the one the map supplied otherwise.
    fn origin(self: *Walk, s: TimeMap.Segment) ?TimeMap.TempoPoint {
        if (self.points.len == 0) return null;
        const p = self.points[0];
        if (p.tick != 0 or !behind(p, s)) return null;
        self.point = 1;
        return p;
    }

    /// Every later segment is a point, the first one at or after the
    /// cursor at its tick with its tempo: the points between were
    /// refused.
    fn after(self: *Walk, s: TimeMap.Segment) ?TimeMap.TempoPoint {
        var i = self.point;
        // Bounded by the points: the cursor only moves forward.
        while (i < self.points.len) : (i += 1) {
            const p = self.points[i];
            if (p.tick != s.tick or !behind(p, s)) continue;
            self.point = i + 1;
            return p;
        }
        return null;
    }
};

/// Whether `p`'s tempo is `s`'s: the map's own division, compared bit for
/// bit. A point that names no tempo (`TimeMap.usOf` is null) was refused
/// and is behind no segment.
fn behind(p: TimeMap.TempoPoint, s: TimeMap.Segment) bool {
    const us = TimeMap.usOf(p) orelse return false;
    return us == s.us;
}

/// A point's quarter notes per minute, as it was spelled.
fn qpmOf(p: TimeMap.TempoPoint) f64 {
    return switch (p.tempo) {
        .qpm => |q| q,
        .us => |u| TimeMap.US_PER_MINUTE / @as(f64, @floatFromInt(u)),
    };
}

fn deriveMap(points: []const TimeMap.TempoPoint) !TimeMap.Result {
    const meter = [_]TimeMap.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    return TimeMap.derive(testing.allocator, points, &meter, 4 * Grid.TPQ, .hold, null);
}

test "tempo.Walk: every segment with the point behind it, spelled as written" {
    const q: i64 = Grid.TPQ;
    const points = [_]TimeMap.TempoPoint{
        .{ .tick = 0, .tempo = .{ .qpm = 102 }, .span = .{ .start = 1, .end = 2 } },
        .{ .tick = q, .tempo = .{ .us = 400_000 }, .span = .{ .start = 3, .end = 4 } },
    };
    var r = try deriveMap(&points);
    defer r.deinit();

    var walk: Walk = .init(&r.map, &points);
    const a = walk.next().?;
    // 60e6 / (60e6 / 102) is not 102 in f64: the authored number is.
    try testing.expectEqual(@as(f64, 102), a.qpm);
    try testing.expectEqual(@as(u32, 1), a.span.start);
    const b = walk.next().?;
    try testing.expectEqual(q, b.tick);
    try testing.expectEqual(@as(f64, 150), b.qpm);
    try testing.expectEqual(@as(?Kept, null), walk.next());
}

test "tempo.Walk: a refused point is skipped, and a supplied origin has no point" {
    const q: i64 = Grid.TPQ;
    const points = [_]TimeMap.TempoPoint{
        // Refused (`:qpm -5` names no tempo): the map supplies 120 QPM.
        .{ .tick = 0, .tempo = .{ .qpm = -5 }, .span = .{ .start = 1, .end = 2 } },
        .{ .tick = q, .tempo = .{ .qpm = 150 }, .span = .{ .start = 3, .end = 4 } },
        // Refused: not after the point before it.
        .{ .tick = q, .tempo = .{ .qpm = 90 }, .span = .{ .start = 5, .end = 6 } },
    };
    var r = try deriveMap(&points);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.map.segments.len);

    var walk: Walk = .init(&r.map, &points);
    const a = walk.next().?;
    try testing.expectEqual(@as(f64, 500_000), a.us);
    try testing.expectEqual(@as(f64, 120), a.qpm);
    try testing.expectEqual(@as(u32, 0), a.span.end);
    const b = walk.next().?;
    try testing.expectEqual(@as(f64, 150), b.qpm);
    try testing.expectEqual(@as(u32, 3), b.span.start);
    try testing.expectEqual(@as(?Kept, null), walk.next());
}
