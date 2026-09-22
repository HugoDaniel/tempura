//! The key budget (plan 08, "The key budget"): two deterministic
//! stages that take a bound curve lane from a point per tick down to
//! something pacer's `MAX_KEYS = 4096` can hold.
//!
//! 1. **Equal-run collapse**, always. Consecutive keys carrying the same
//!    value keep the FIRST on a `hold` lane and the first AND the LAST
//!    on a `linear` one. The last is not an ornament: dropping it turns
//!    `(0, 0) (1, 0) (2, 1)` into `(0, 0) (2, 1)`, which reads `0.5` at
//!    beat 1 — past `eps` before the second stage even runs.
//!
//! 2. **Thinning to `eps`** (default `1 / 127`, the CC quantum), by the
//!    rule that matches how pacer RECONSTRUCTS the lane:
//!    - `linear` reconstructs a polyline, so the stage is
//!      Ramer-Douglas-Peucker over `(beat, value)` — the point whose
//!      perpendicular distance from the chord is largest survives, and
//!      its two halves recurse. Plan 08's words: "the polyline
//!      reproduces the lane within `eps`".
//!    - `hold` reconstructs a staircase, so a perpendicular distance
//!      would measure nothing real: a step is kept when it differs from
//!      the last KEPT value by more than `eps`, which is plan 08's "the
//!      steps that exceed `eps` are kept".
//!
//! Determinism is the whole contract here, so: left-then-right recursion
//! in a fixed order, the lowest index wins a tie, comparisons are exact
//! (`>` against `eps`, never an epsilon on top of an epsilon), and no
//! libm — the perpendicular distance is compared SQUARED, so nothing
//! calls `@sqrt`. Same lane in, same keys out, on every host.
//!
//! A NATIVE lane never comes through here: the author wrote every
//! keyframe (plan 08, "Native lanes are never simplified").

const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Simplifying can only fail the way any allocation fails.
pub const Error = error{OutOfMemory};

/// One key on the way to a pacer `(key …)`: the position is already a
/// PACER tick, and `ease` is the easing printed for the segment ENDING
/// here, carried through untouched.
pub const Key = struct {
    tick: i64,
    value: [4]f32,
    ncomp: u3,
    ease: []const u8,
};

/// How pacer will reconstruct the lane between two keys — which is what
/// decides both stages' rules.
pub const Mode = enum { hold, linear };

/// Stage 1: equal-run collapse.
///
/// The kept keys are a new slice of `gpa`'s, which the caller frees;
/// `keys` is borrowed and untouched, and a key's `ease` stays borrowed.
pub fn collapse(gpa: Allocator, keys: []const Key, mode: Mode) Error![]Key {
    if (keys.len <= 2) return gpa.dupe(Key, keys);

    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, keys.len);

    var i: usize = 0;
    while (i < keys.len) {
        var j = i + 1;
        while (j < keys.len and sameValue(keys[i], keys[j])) j += 1;
        // `[i, j)` is one run. Its first key always stays.
        out.appendAssumeCapacity(keys[i]);
        // A `linear` run needs its LAST key too, or the ramp that
        // follows starts from the run's beginning and the plateau is
        // gone. `hold` holds the value until the next key by
        // definition, so the last one says nothing new.
        if (mode == .linear and j - i > 1) out.appendAssumeCapacity(keys[j - 1]);
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

/// Stage 2 for a `linear` lane: Ramer-Douglas-Peucker over
/// `(beat, value)`, keeping every point further than `eps` from the
/// chord its neighbours span.
///
/// `tpb` is pacer's ticks per beat, because the metric is a distance in
/// the `(beat, value)` PLANE: scaling the horizontal axis changes which
/// points survive, so the axis has to be the one plan 08 names.
///
/// The kept keys are a new slice of `gpa`'s, which the caller frees;
/// `keys` is borrowed and untouched, and a key's `ease` stays borrowed.
pub fn rdp(gpa: Allocator, keys: []const Key, eps: f32, tpb: i64) Error![]Key {
    if (keys.len <= 2) return gpa.dupe(Key, keys);

    const keep = try gpa.alloc(bool, keys.len);
    defer gpa.free(keep);
    @memset(keep, false);
    keep[0] = true;
    keep[keys.len - 1] = true;

    const xs = try gpa.alloc(f64, keys.len);
    defer gpa.free(xs);
    const per_beat: f64 = @floatFromInt(tpb);
    for (keys, xs) |key, *x| x.* = @as(f64, @floatFromInt(key.tick)) / per_beat;

    // The divide's pending frames are disjoint intervals of the keys, so
    // `keys.len` of them is a bound it never reaches (see `divide`).
    const stack = try gpa.alloc(Frame, keys.len);
    defer gpa.free(stack);

    const eps2 = @as(f64, eps) * @as(f64, eps);
    divide(keys, xs, keep, stack, eps2);

    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, keys.len);
    for (keys, keep) |key, wanted| {
        if (wanted) out.appendAssumeCapacity(key);
    }
    return out.toOwnedSlice(gpa);
}

/// Stage 2 for a `hold` lane: keep a step whose value leaves the last
/// kept one by more than `eps`. The first and the last key always stay
/// — the first is where the lane starts and the last is where it ends,
/// and pacer holds both past their edges.
///
/// The kept keys are a new slice of `gpa`'s, which the caller frees;
/// `keys` is borrowed and untouched, and a key's `ease` stays borrowed.
pub fn thinHold(gpa: Allocator, keys: []const Key, eps: f32) Error![]Key {
    if (keys.len <= 2) return gpa.dupe(Key, keys);

    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, keys.len);

    out.appendAssumeCapacity(keys[0]);
    var last = keys[0];
    for (keys[1 .. keys.len - 1]) |key| {
        if (spread(last, key) > eps) {
            out.appendAssumeCapacity(key);
            last = key;
        }
    }
    out.appendAssumeCapacity(keys[keys.len - 1]);
    return out.toOwnedSlice(gpa);
}

/// Both stages, in order — what a bound curve lane actually runs.
///
/// The kept keys are a new slice of `gpa`'s, which the caller frees;
/// `keys` is borrowed and untouched, and a key's `ease` stays borrowed.
pub fn budget(gpa: Allocator, keys: []const Key, mode: Mode, eps: f32, tpb: i64) Error![]Key {
    const collapsed = try collapse(gpa, keys, mode);
    defer gpa.free(collapsed);
    return switch (mode) {
        .linear => rdp(gpa, collapsed, eps, tpb),
        .hold => thinHold(gpa, collapsed, eps),
    };
}

// ---- the divide ----

/// One pending `[lo, hi]` of `divide`, both ends already kept.
const Frame = struct { lo: usize, hi: usize };

/// Ramer-Douglas-Peucker over `[0, keys.len - 1]` with both ends kept:
/// find the interior point furthest from the chord and, if it is past
/// `eps`, keep it and divide both halves — LEFT first, always, so the
/// order the splits are found in is fixed.
///
/// An explicit stack, not recursion: a curve lane may carry thousands
/// of keys and the textbook form recurses as deep as the key count in
/// the worst case (a monotone ramp that keeps every key), which is not
/// a stack a wasm host can be asked for. The pending frames are
/// intervals of the keys that overlap only at their ends, so there are
/// never more than `keys.len - 1` of them; and every split keeps one
/// interior key, so there are at most `keys.len - 2` splits and fewer
/// than `2 · keys.len` pops in all.
fn divide(keys: []const Key, xs: []const f64, keep: []bool, stack: []Frame, eps2: f64) void {
    std.debug.assert(keys.len >= 3);
    std.debug.assert(stack.len >= keys.len);
    std.debug.assert(keep[0] and keep[keys.len - 1]);

    stack[0] = .{ .lo = 0, .hi = keys.len - 1 };
    var pending: usize = 1;
    for (0..2 * keys.len) |_| {
        if (pending == 0) break;
        pending -= 1;
        const frame = stack[pending];
        const at = furthestFromChord(keys, xs, frame.lo, frame.hi, eps2) orelse continue;

        keep[at] = true;
        // RIGHT pushed first so that LEFT pops first.
        std.debug.assert(pending + 2 < stack.len);
        stack[pending] = .{ .lo = at, .hi = frame.hi };
        stack[pending + 1] = .{ .lo = frame.lo, .hi = at };
        pending += 2;
    } else unreachable;

    std.debug.assert(pending == 0);
    std.debug.assert(keep[0] and keep[keys.len - 1]);
}

/// The interior key of `[lo, hi]` furthest from the chord `lo → hi`, if
/// it is further than `eps` — null when the interval has no interior or
/// every key in it lies within `eps` of the chord.
fn furthestFromChord(keys: []const Key, xs: []const f64, lo: usize, hi: usize, eps2: f64) ?usize {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi < keys.len);
    if (hi <= lo + 1) return null;

    var best: f64 = 0;
    var at: usize = 0;
    var i = lo + 1;
    while (i < hi) : (i += 1) {
        const d2 = chordDistance2(keys, xs, lo, hi, i);
        // Strictly greater: scanning ascending, a tie keeps the LOWEST
        // index, which is what makes the split reproducible.
        if (d2 > best) {
            best = d2;
            at = i;
        }
    }
    if (at == 0 or best <= eps2) return null;
    std.debug.assert(lo < at and at < hi);
    return at;
}

/// The squared perpendicular distance from key `i` to the chord
/// `lo → hi`, on the worst component of a vector lane.
///
/// `cross² / (dx² + dy²)` is the square of `|cross| / len`, so the
/// comparison against `eps²` is the comparison against `eps` with no
/// `@sqrt` in it (plan 00's determinism rule: no libm in a value path).
fn chordDistance2(keys: []const Key, xs: []const f64, lo: usize, hi: usize, i: usize) f64 {
    const dx = xs[hi] - xs[lo];
    const px = xs[i] - xs[lo];
    var worst: f64 = 0;
    const n = @max(keys[i].ncomp, 1);
    var c: usize = 0;
    while (c < n) : (c += 1) {
        const dy = @as(f64, keys[hi].value[c]) - @as(f64, keys[lo].value[c]);
        const py = @as(f64, keys[i].value[c]) - @as(f64, keys[lo].value[c]);
        const cross = px * dy - py * dx;
        const len2 = dx * dx + dy * dy;
        // Two keys on one tick with one value cannot reach here (the
        // ticks strictly ascend), but a zero-length chord would divide
        // by zero, so it falls back to the plain vertical distance.
        const d2 = if (len2 == 0) py * py else (cross * cross) / len2;
        if (d2 > worst) worst = d2;
    }
    return worst;
}

/// Whether two keys carry the same value on every live component.
fn sameValue(a: Key, b: Key) bool {
    if (a.ncomp != b.ncomp) return false;
    var c: usize = 0;
    while (c < @max(a.ncomp, 1)) : (c += 1) {
        if (a.value[c] != b.value[c]) return false;
    }
    return true;
}

/// The largest per-component difference between two keys.
fn spread(a: Key, b: Key) f32 {
    var worst: f32 = 0;
    var c: usize = 0;
    while (c < @max(a.ncomp, 1)) : (c += 1) {
        const d = @abs(a.value[c] - b.value[c]);
        if (d > worst) worst = d;
    }
    return worst;
}

// ---- tests ----

fn k(tick: i64, v: f32) Key {
    return .{ .tick = tick, .value = .{ v, 0, 0, 0 }, .ncomp = 1, .ease = "linear" };
}

fn ticksOf(gpa: std.mem.Allocator, keys: []const Key) ![]i64 {
    const out = try gpa.alloc(i64, keys.len);
    for (keys, out) |src, *dst| dst.* = src.tick;
    return out;
}

test "simplify.collapse: a hold run keeps its first key and nothing else" {
    const gpa = testing.allocator;
    const keys = [_]Key{ k(0, 0.5), k(10, 0.5), k(20, 0.5), k(30, 0.9), k(40, 0.9) };

    const got = try collapse(gpa, &keys, .hold);
    defer gpa.free(got);
    const ticks = try ticksOf(gpa, got);
    defer gpa.free(ticks);
    try testing.expectEqualSlices(i64, &.{ 0, 30 }, ticks);
}

test "simplify.collapse: a linear plateau keeps its FIRST and its LAST key" {
    // Plan 08's worked reason: dropping the last of `(0, 0) (1, 0) (2, 1)`
    // leaves `(0, 0) (2, 1)`, which reads 0.5 at beat 1 — past `eps`
    // before simplification even runs.
    const gpa = testing.allocator;
    const keys = [_]Key{ k(0, 0), k(1, 0), k(2, 1) };

    const got = try collapse(gpa, &keys, .linear);
    defer gpa.free(got);
    const ticks = try ticksOf(gpa, got);
    defer gpa.free(ticks);
    try testing.expectEqualSlices(i64, &.{ 0, 1, 2 }, ticks);

    // A longer plateau loses only its interior.
    const flat = [_]Key{ k(0, 0.25), k(1, 0.25), k(2, 0.25), k(3, 0.25), k(4, 1) };
    const thinned = try collapse(gpa, &flat, .linear);
    defer gpa.free(thinned);
    const flat_ticks = try ticksOf(gpa, thinned);
    defer gpa.free(flat_ticks);
    try testing.expectEqualSlices(i64, &.{ 0, 3, 4 }, flat_ticks);
}

test "simplify.rdp: a straight ramp collapses to its endpoints, a kink survives" {
    const gpa = testing.allocator;
    const tpb: i64 = 180_180;

    // Exactly on the line: every interior point goes.
    var ramp: [9]Key = undefined;
    for (&ramp, 0..) |*key, i| {
        const f: f32 = @floatFromInt(i);
        key.* = k(@as(i64, @intCast(i)) * tpb, f / 8.0);
    }
    const straight = try rdp(gpa, &ramp, 1.0 / 127.0, tpb);
    defer gpa.free(straight);
    const straight_ticks = try ticksOf(gpa, straight);
    defer gpa.free(straight_ticks);
    try testing.expectEqualSlices(i64, &.{ 0, 8 * tpb }, straight_ticks);

    // One point pushed a quarter off the line stays, and with an `eps`
    // wide enough to swallow the shoulders it is the ONLY survivor: the
    // perpendicular distance from the full chord is 0.248 beats-value,
    // and every point of the two halves it splits is under 0.19.
    var kinked = ramp;
    kinked[4].value[0] += 0.25;
    const kept = try rdp(gpa, &kinked, 0.2, tpb);
    defer gpa.free(kept);
    const kept_ticks = try ticksOf(gpa, kept);
    defer gpa.free(kept_ticks);
    try testing.expectEqualSlices(i64, &.{ 0, 4 * tpb, 8 * tpb }, kept_ticks);
}

test "simplify.rdp: the same input gives the same output, ascending, endpoints kept" {
    const gpa = testing.allocator;
    const tpb: i64 = 180_180;
    var lane: [64]Key = undefined;
    for (&lane, 0..) |*key, i| {
        // A deterministic sawtooth: no clock, no hash iteration.
        const f: f32 = @floatFromInt((i * 37) % 23);
        key.* = k(@as(i64, @intCast(i)) * @divExact(tpb, 4), f / 23.0);
    }

    const a = try rdp(gpa, &lane, 1.0 / 127.0, tpb);
    defer gpa.free(a);
    const b = try rdp(gpa, &lane, 1.0 / 127.0, tpb);
    defer gpa.free(b);
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expectEqual(x.tick, y.tick);

    try testing.expectEqual(lane[0].tick, a[0].tick);
    try testing.expectEqual(lane[lane.len - 1].tick, a[a.len - 1].tick);
    for (a[1..], a[0 .. a.len - 1]) |next, prev| try testing.expect(next.tick > prev.tick);
}

test "simplify.budget: collapse then RDP reproduces a synthetic lane within eps" {
    const gpa = testing.allocator;
    const tpb: i64 = 180_180;
    const eps: f32 = 1.0 / 127.0;

    // A freehand-looking automation lane: a plateau, a ramp with tiny
    // jitter under the CC quantum, and a step.
    var lane: [256]Key = undefined;
    for (&lane, 0..) |*key, i| {
        const t = @as(i64, @intCast(i)) * @divExact(tpb, 12);
        const v: f32 = if (i < 64) 0.25 else if (i < 192) blk: {
            const u: f32 = @floatFromInt(i - 64);
            const jitter: f32 = if (i % 3 == 0) 0.002 else 0;
            break :blk 0.25 + u / 128.0 * 0.5 + jitter;
        } else 0.9;
        key.* = k(t, v);
    }

    const got = try budget(gpa, &lane, .linear, eps, tpb);
    defer gpa.free(got);
    try testing.expect(got.len < lane.len / 4);

    // Every original point is within `eps` of the kept polyline.
    for (lane) |src| {
        const approx = sampleLinear(got, src.tick);
        try testing.expect(@abs(approx - src.value[0]) <= eps);
    }
}

test "simplify.budget: a hold lane keeps the steps that exceed eps and drops the rest" {
    const gpa = testing.allocator;
    const eps: f32 = 1.0 / 127.0;
    const keys = [_]Key{
        k(0, 0.5),
        k(10, 0.503), // under the quantum: dropped
        k(20, 0.504), // still under it, measured from the last KEPT key
        k(30, 0.6), // past it: kept
        k(40, 0.9), // the last key always stays
    };
    const got = try budget(gpa, &keys, .hold, eps, 180_180);
    defer gpa.free(got);
    const ticks = try ticksOf(gpa, got);
    defer gpa.free(ticks);
    try testing.expectEqualSlices(i64, &.{ 0, 30, 40 }, ticks);

    // …and stage 1 has already dropped a repeat of the last value, so a
    // `hold` run never reaches the thinning at all.
    const run = [_]Key{ k(0, 0.5), k(10, 0.6), k(20, 0.6), k(30, 0.6) };
    const collapsed = try budget(gpa, &run, .hold, eps, 180_180);
    defer gpa.free(collapsed);
    const run_ticks = try ticksOf(gpa, collapsed);
    defer gpa.free(run_ticks);
    try testing.expectEqualSlices(i64, &.{ 0, 10 }, run_ticks);
}

test "simplify: a vector lane is measured on its worst component" {
    const gpa = testing.allocator;
    const tpb: i64 = 180_180;
    var lane = [_]Key{
        .{ .tick = 0, .value = .{ 0, 0, 0, 0 }, .ncomp = 3, .ease = "linear" },
        .{ .tick = tpb, .value = .{ 0.5, 0.5, 0.5, 0 }, .ncomp = 3, .ease = "linear" },
        .{ .tick = 2 * tpb, .value = .{ 1, 1, 1, 0 }, .ncomp = 3, .ease = "linear" },
    };
    // Straight in every component: the middle goes.
    const flat = try rdp(gpa, &lane, 1.0 / 127.0, tpb);
    defer gpa.free(flat);
    try testing.expectEqual(@as(usize, 2), flat.len);

    // One component off the line is enough to keep it.
    lane[1].value[2] = 0.9;
    const kept = try rdp(gpa, &lane, 1.0 / 127.0, tpb);
    defer gpa.free(kept);
    try testing.expectEqual(@as(usize, 3), kept.len);
}

/// The linear reconstruction a pacer `linear` track performs, for the
/// "within eps" assertion above.
fn sampleLinear(keys: []const Key, tick: i64) f32 {
    if (keys.len == 0) return 0;
    if (tick <= keys[0].tick) return keys[0].value[0];
    for (keys[1..], keys[0 .. keys.len - 1]) |b, a| {
        if (tick > b.tick) continue;
        const span: f64 = @floatFromInt(b.tick - a.tick);
        const u: f64 = @as(f64, @floatFromInt(tick - a.tick)) / span;
        const lo: f64 = a.value[0];
        const hi: f64 = b.value[0];
        return @floatCast(lo + (hi - lo) * u);
    }
    return keys[keys.len - 1].value[0];
}
