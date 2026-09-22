//! pacer's twelve POLYNOMIAL easing primitives, and the one question
//! tempura asks of them: does this run of steps follow that curve?
//!
//! Two consumers verify an easing hint against the steps a file holds —
//! the exporter (`export/lanes.zig`, a midivia `ease-hint` or a lane
//! record over a bound curve) and reconciliation (`residue/reconcile.zig`,
//! a stale lane's record) — and they cannot import each other:
//! `export/lanes.zig` reaches `doc/doc.zig`, which exports
//! `doc/pipeline.zig`, which imports `residue/reconcile.zig`. So the
//! curve lives here, below both, beside `Diag.zig`, and imports `std`
//! alone.
//!
//! The formulas are `pacer/src/Easing.zig`'s `evalOp`, expression for
//! expression. Everything else pacer can spell — the sine and expo
//! primitives, which need a transcendental plan 00 forbids in a value
//! path, and every `(seq …)` / `(chain …)` / `(steps …)` /
//! `(cubic-bezier …)` / `(spring …)` form, which needs pacer's own
//! compiler — is unevaluable here, and a hint tempura cannot check is a
//! hint tempura does not apply.
//!
//! Pure: no allocation, no state, the same answer on every host.

const std = @import("std");

const testing = std.testing;

/// The eased fraction of the way along a segment at `u` in `0..1`, or
/// null for every easing this cannot evaluate exactly.
pub fn easeAt(ease: []const u8, u: f64) ?f64 {
    const p1 = 1.0 - u;
    if (std.mem.eql(u8, ease, "linear")) return u;
    if (std.mem.eql(u8, ease, "hold")) return if (u >= 1) 1.0 else 0.0;
    if (std.mem.eql(u8, ease, "smoothstep")) return u * u * (3.0 - 2.0 * u);
    if (std.mem.eql(u8, ease, "in-quad")) return u * u;
    if (std.mem.eql(u8, ease, "out-quad")) return 1.0 - p1 * p1;
    if (std.mem.eql(u8, ease, "in-out-quad"))
        return if (u < 0.5) 2.0 * u * u else 1.0 - (2.0 * p1) * (2.0 * p1) / 2.0;
    if (std.mem.eql(u8, ease, "in-cubic")) return u * u * u;
    if (std.mem.eql(u8, ease, "out-cubic")) return 1.0 - p1 * p1 * p1;
    if (std.mem.eql(u8, ease, "in-out-cubic"))
        return if (u < 0.5) 4.0 * u * u * u else 1.0 - (2.0 * p1) * (2.0 * p1) * (2.0 * p1) / 2.0;
    if (std.mem.eql(u8, ease, "in-quart")) return u * u * u * u;
    if (std.mem.eql(u8, ease, "out-quart")) return 1.0 - p1 * p1 * p1 * p1;
    if (std.mem.eql(u8, ease, "in-out-quart"))
        return if (u < 0.5)
            8.0 * u * u * u * u
        else
            1.0 - (2.0 * p1) * (2.0 * p1) * (2.0 * p1) * (2.0 * p1) / 2.0;
    return null;
}

/// Whether `ease` is one `easeAt` evaluates — the first question both
/// verifications ask, so an unevaluable hint is dropped before a step is
/// read.
pub fn evaluable(ease: []const u8) bool {
    return easeAt(ease, 0.5) != null;
}

/// One end of a segment: a tick and the value the curve holds there.
pub const Point = struct { tick: i64, value: f64 };

/// How far `value` at tick `at` lies from `ease` drawn between `from`
/// and `to`, or null when the easing is not evaluable or the segment
/// spans no ticks. The op order is the verifications' own: the fraction
/// `(at − from) / (to − from)` in f64, once, then `lo + (hi − lo) · e`.
pub fn deviation(ease: []const u8, from: Point, to: Point, at: i64, value: f64) ?f64 {
    const span: f64 = @floatFromInt(to.tick - from.tick);
    if (!(span > 0)) return null;
    const u = @as(f64, @floatFromInt(at - from.tick)) / span;
    const shaped = easeAt(ease, u) orelse return null;
    const want = from.value + (to.value - from.value) * shaped;
    return @abs(want - value);
}

test "Easing.easeAt: the twelve polynomial primitives match pacer's own formulas" {
    try testing.expectEqual(@as(?f64, 0.5), easeAt("linear", 0.5));
    try testing.expectEqual(@as(?f64, 0), easeAt("hold", 0.5));
    try testing.expectEqual(@as(?f64, 1), easeAt("hold", 1));
    try testing.expectEqual(@as(?f64, 0.5), easeAt("smoothstep", 0.5));
    try testing.expectEqual(@as(?f64, 0.25), easeAt("in-quad", 0.5));
    try testing.expectEqual(@as(?f64, 0.75), easeAt("out-quad", 0.5));
    try testing.expectEqual(@as(?f64, 0.125), easeAt("in-cubic", 0.5));
    try testing.expectEqual(@as(?f64, 0.875), easeAt("out-cubic", 0.5));
    try testing.expectEqual(@as(?f64, 0.0625), easeAt("in-quart", 0.5));
    try testing.expectEqual(@as(?f64, 0.9375), easeAt("out-quart", 0.5));
    try testing.expectEqual(@as(?f64, 0.5), easeAt("in-out-quad", 0.5));
    try testing.expectEqual(@as(?f64, 0.5), easeAt("in-out-cubic", 0.5));
    try testing.expectEqual(@as(?f64, 0.5), easeAt("in-out-quart", 0.5));
    // Everything a transcendental or pacer's compiler would be needed for.
    try testing.expect(easeAt("in-sine", 0.5) == null);
    try testing.expect(easeAt("(spring :damping 0.5)", 0.5) == null);
    try testing.expect(!evaluable("in-expo"));
    try testing.expect(evaluable("linear"));
}

test "Easing.deviation: the distance from the curve, and null for no curve or no span" {
    const from: Point = .{ .tick = 0, .value = 0 };
    const to: Point = .{ .tick = 100, .value = 1 };
    try testing.expectEqual(@as(?f64, 0), deviation("linear", from, to, 50, 0.5));
    try testing.expectEqual(@as(?f64, 0.125), deviation("in-quad", from, to, 50, 0.375));
    try testing.expectEqual(@as(?f64, null), deviation("in-sine", from, to, 50, 0.5));
    try testing.expectEqual(@as(?f64, null), deviation("linear", from, from, 0, 0));
}
