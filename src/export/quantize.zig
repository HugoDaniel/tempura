//! A curve value as a controller's integer: the one quantizer both
//! renderers write through.
//!
//! A `.mid` controller is 7 bits and an IT column is 0..64 (volume) or
//! 0..255 (an effect's parameter), and a curve lane's value lives on its
//! `:range`. The mapping is one formula — `round((v − lo) / (hi − lo) ·
//! top)`, clamped to `0..top` — and `render_smf` and `render_it` each had
//! it, spelled twice. It lives here, below both, so a change to the
//! rounding moves both files' output together.
//!
//! Pure and total: a degenerate `:range` (`hi == lo`, which has no
//! scale), a non-finite end of one or a non-finite value answers 0 rather
//! than a NaN cast, and the answer is never past `top`.

const std = @import("std");

const testing = std.testing;

/// `round((v − lo) / (hi − lo) · top)` over `range = [lo hi]`, clamped
/// to `0..top`.
pub fn quantize(v: f64, range: [2]f32, top: u8) u8 {
    const lo: f64 = range[0];
    const hi: f64 = range[1];
    if (hi == lo) return 0;
    if (!std.math.isFinite(lo) or !std.math.isFinite(hi) or !std.math.isFinite(v)) return 0;
    const ceiling: f64 = @floatFromInt(top);
    const scaled = @round((v - lo) / (hi - lo) * ceiling);
    if (!(scaled > 0)) return 0;
    if (scaled >= ceiling) return top;
    const out: u8 = @intFromFloat(scaled);
    std.debug.assert(out <= top);
    return out;
}

test "quantize: the range's ends are 0 and top, the middle rounds, the rest clamps" {
    const unit = [2]f32{ 0, 1 };
    try testing.expectEqual(@as(u8, 0), quantize(0, unit, 127));
    try testing.expectEqual(@as(u8, 127), quantize(1, unit, 127));
    // 0.5 · 127 = 63.5, which rounds away from zero.
    try testing.expectEqual(@as(u8, 64), quantize(0.5, unit, 127));
    try testing.expectEqual(@as(u8, 32), quantize(0.5, unit, 64));
    try testing.expectEqual(@as(u8, 255), quantize(2, unit, 255));
    try testing.expectEqual(@as(u8, 0), quantize(-1, unit, 255));
    // A reversed range runs the other way.
    try testing.expectEqual(@as(u8, 127), quantize(0, .{ 1, 0 }, 127));
}

test "quantize: a degenerate range or a value that is no number answers 0" {
    try testing.expectEqual(@as(u8, 0), quantize(0.5, .{ 1, 1 }, 127));
    try testing.expectEqual(@as(u8, 0), quantize(std.math.nan(f64), .{ 0, 1 }, 127));
    try testing.expectEqual(@as(u8, 0), quantize(std.math.inf(f64), .{ 0, 1 }, 127));
    try testing.expectEqual(@as(u8, 0), quantize(0.5, .{ 0, std.math.inf(f32) }, 127));
}
