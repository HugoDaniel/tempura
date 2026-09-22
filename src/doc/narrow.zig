//! Narrowing a tree's number to the integer a field holds — the one
//! place `doc/` turns an `f64` off a SJON tree into a `u8`, a `u16`, a
//! channel.
//!
//! **The rule, stated once.** The manifest bounds every field these
//! readers fill (`schema/tempura.sjon`, `midi.sjon`, `it.sjon`), and a
//! document that breaks a bound is refused at validation and rides
//! across as `sjon_diagnostic`. The readers lower it ANYWAY — collection
//! over abort, so an editor hears every complaint at once — and what
//! they must never do is trap: `@intFromFloat` past its type's range,
//! of a NaN or of an infinity is undefined behaviour in `ReleaseSmall`.
//! So every narrowing is TOTAL, takes the number's integer part (the
//! manifest's `:integer true` has already refused a fraction), and says
//! by its NAME what an out-of-range number becomes:
//!
//!   * `int` — null. The reader decides; `orZero` is the document
//!     reader's decision.
//!   * `orZero` — 0, `fromSjon`'s rule, where 0 is outside the field's
//!     domain or is the layers' own "none": `:track 0` names no track,
//!     `:us 0` no tempo (which the map then says in its own words), and
//!     neither can be mistaken for a value the author wrote.
//!   * `saturate` — the nearest end of the type, the format bridges'
//!     rule (`bridge_smf`, `bridge_it`): a byte field reads as the byte
//!     the format can carry nearest to what was written, and a `:size`
//!     no `u64` holds cannot then match any file.
//!   * `wireChannel` — a channel counted from 1 to the wire's count from
//!     0, and channel 1 when the number is absent or no channel.
//!   * `f32OrZero` — the one FLOAT narrowing: a keyframe's value and a
//!     curve's `:range`, which the manifest types `:repr f32`. What f32
//!     cannot hold (`1e39`, and `1e999`, which SJON reads as an infinity)
//!     is 0, `orZero`'s rule, because `@floatCast` does not trap there —
//!     it answers an infinity, which then flows into every exporter.
//!
//! Until this file the three readers each carried their own copies, and
//! the difference between the first two rules was an accident of which
//! file a field was read in rather than a statement.

const std = @import("std");
const testing = std.testing;

/// `v`'s integer part as a `T`, or null when there is no number, it is
/// not one (NaN, an infinity), or `T` cannot hold it.
///
/// The range test is made on exact powers of two — `[-2^(b-1), 2^(b-1))`
/// for a signed `T` of `b` bits, `[0, 2^b)` for an unsigned one — so it
/// is exact for every width up to 64, where `@floatFromInt(maxInt(T))`
/// would round up and admit a value `@intFromFloat` traps on.
pub fn int(comptime T: type, v: ?f64) ?T {
    const x = @trunc(v orelse return null);
    const r = range(T);
    // A NaN fails both comparisons and answers null with the rest.
    if (!(x >= r.lo and x < r.hi)) return null;
    return @intFromFloat(x);
}

/// `int`, or 0 — the document reader's rule (see the header).
pub fn orZero(comptime T: type, v: ?f64) T {
    return int(T, v) orelse 0;
}

/// `int`, or the nearer end of `T` past either — the format bridges'
/// rule (see the header). An absent number, or a NaN, is `fallback`.
pub fn saturate(comptime T: type, v: ?f64, fallback: T) T {
    const x = v orelse return fallback;
    if (std.math.isNan(x)) return fallback;
    if (int(T, x)) |n| return n;
    return if (x < 0) std.math.minInt(T) else std.math.maxInt(T);
}

/// A channel counted from 1 — `:ch 1`, `:channel 1`, as every display
/// counts them — to the wire's count from 0, `T`'s whole domain (`u4` for
/// MIDI, `u6` for Impulse Tracker). Absent, or no channel of `T`, is
/// channel 1, which is 0.
pub fn wireChannel(comptime T: type, v: ?f64) T {
    const counted = v orelse return 0;
    return int(T, counted - 1) orelse 0;
}

/// `v` as the `f32` the document layer keeps, or 0 when there is no
/// number, it is not one (NaN, an infinity), or its f32 is not finite —
/// past `floatMax(f32)`, where the manifest's `:repr f32` has already
/// refused it with `sjon_diagnostic` (see the header). A finite value
/// in range keeps f32's own rounding of it, `@floatCast`'s.
pub fn f32OrZero(v: ?f64) f32 {
    const narrowed: f32 = @floatCast(v orelse return 0);
    if (!std.math.isFinite(narrowed)) return 0;
    return narrowed;
}

/// `T`'s range as two exact `f64` bounds, the upper one exclusive.
fn range(comptime T: type) struct { lo: f64, hi: f64 } {
    const info = @typeInfo(T).int;
    comptime std.debug.assert(info.bits >= 1 and info.bits <= 64);
    const one: f64 = 1;
    return switch (info.signedness) {
        .signed => .{
            .lo = -std.math.ldexp(one, info.bits - 1),
            .hi = std.math.ldexp(one, info.bits - 1),
        },
        .unsigned => .{ .lo = 0, .hi = std.math.ldexp(one, info.bits) },
    };
}

test "narrow.int: the integer part when the type holds it, else null" {
    try testing.expectEqual(@as(?u8, 255), int(u8, 255));
    try testing.expectEqual(@as(?u8, 3), int(u8, 3.9));
    try testing.expectEqual(@as(?u8, null), int(u8, 256));
    try testing.expectEqual(@as(?u8, null), int(u8, -1));
    try testing.expectEqual(@as(?i8, -128), int(i8, -128));
    try testing.expectEqual(@as(?i8, null), int(i8, 128));
    try testing.expectEqual(@as(?u8, null), int(u8, null));
    try testing.expectEqual(@as(?u8, null), int(u8, std.math.nan(f64)));
    try testing.expectEqual(@as(?u8, null), int(u8, std.math.inf(f64)));
    // The 64-bit ends, where `@floatFromInt(maxInt)` rounds up to 2^63
    // and a `<=` against it would admit a trap.
    const two63: f64 = 9_223_372_036_854_775_808.0;
    try testing.expectEqual(@as(?i64, null), int(i64, two63));
    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), int(i64, -two63));
    try testing.expectEqual(@as(?u64, null), int(u64, 2 * two63));
    try testing.expectEqual(@as(?u64, 1 << 63), int(u64, two63));
}

test "narrow: orZero, saturate and wireChannel say what out of range becomes" {
    try testing.expectEqual(@as(u16, 0), orZero(u16, 70_000));
    try testing.expectEqual(@as(u32, 0), orZero(u32, -1));
    try testing.expectEqual(@as(u16, 1), orZero(u16, 1));

    try testing.expectEqual(@as(u8, 255), saturate(u8, 1e30, 7));
    try testing.expectEqual(@as(u8, 0), saturate(u8, -1e30, 7));
    try testing.expectEqual(@as(u8, 7), saturate(u8, null, 7));
    try testing.expectEqual(@as(u8, 7), saturate(u8, std.math.nan(f64), 7));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), saturate(i64, 1e30, 0));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), saturate(i64, -1e30, 0));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), saturate(u64, std.math.inf(f64), 0));

    try testing.expectEqual(@as(u4, 0), wireChannel(u4, 1));
    try testing.expectEqual(@as(u4, 15), wireChannel(u4, 16));
    try testing.expectEqual(@as(u4, 0), wireChannel(u4, 17));
    try testing.expectEqual(@as(u4, 0), wireChannel(u4, null));
    try testing.expectEqual(@as(u6, 63), wireChannel(u6, 64));
    try testing.expectEqual(@as(u6, 0), wireChannel(u6, -9e18));
}

test "narrow.f32OrZero: what f32 cannot hold is 0, never an infinity" {
    try testing.expectEqual(@as(f32, 0.5), f32OrZero(0.5));
    try testing.expectEqual(@as(f32, -2), f32OrZero(-2));
    try testing.expectEqual(@as(f32, 0), f32OrZero(null));
    try testing.expectEqual(@as(f32, 0), f32OrZero(1e39));
    try testing.expectEqual(@as(f32, 0), f32OrZero(-1e39));
    try testing.expectEqual(@as(f32, 0), f32OrZero(std.math.inf(f64)));
    try testing.expectEqual(@as(f32, 0), f32OrZero(-std.math.inf(f64)));
    try testing.expectEqual(@as(f32, 0), f32OrZero(std.math.nan(f64)));
    // f32's own largest finite value still reads, as does a number that
    // only rounds to it.
    const max: f64 = std.math.floatMax(f32);
    try testing.expectEqual(std.math.floatMax(f32), f32OrZero(max));
    try testing.expectEqual(@as(f32, 3.4e38), f32OrZero(3.4e38));
}
