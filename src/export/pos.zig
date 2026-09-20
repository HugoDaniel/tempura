//! pacer's tick grid seen from tempura's (plan 08, "The pacer grid, from
//! tempura's").
//!
//! Two conversions and one printing rule:
//!
//! 1. **Onto the lattice.** pacer's grid is `PPC = 720 720` ticks per
//!    BAR; tempura's is `TPQ = 64 · PPC` per quarter. Under a meter
//!    `[n d]` a tempura tick `k` is a pacer tick iff `256 n / d` divides
//!    it, and then the pacer tick is `k / (256 n / d)`. Everything else
//!    takes the nearest, ties down, and is COUNTED (`Counter`).
//!
//! 2. **Back into text.** pacer reads a `b` literal with one
//!    `mul + floor` (`pacer/src/TimeMap.zig`): `tpb = PPC / n`, an exact
//!    integer computed once, then `ticks = floor(beats · f64(tpb))`. A
//!    shortest-ROUND-TRIP decimal of the beat value is not safe — `1.4 ·
//!    180180` is `252251.999…` in f64 and floors one tick short — so a
//!    position prints as the **shortest decimal `D` with
//!    `floor(f64(D) · f64(tpb)) == T`**, that is the shortest decimal in
//!    `[T / tpb, (T + 1) / tpb)`, searched over 0..17 fractional digits
//!    and checked HERE in pacer's own op order. `std.fmt.parseFloat` is
//!    the decimal→f64 conversion because it is the one SJON's parser
//!    performs on a number literal (`SJON/src/Parser.zig`), so the check
//!    and the read agree by construction.
//!
//! 3. **Beats versus quarters.** pacer's beat is `1 / n` of a bar, a
//!    `4 / d` note, and tempura's tempo is per quarter — so `:bpm =
//!    qpm · d / 4` and pacer's two bounds (`bpm-value` 1..1000,
//!    `meter-component` 1..16) are checked before anything is emitted.
//!
//! Determinism: integer arithmetic in `i128` for every candidate, one
//! `f64` multiply and one `@floor` for every check, no libm anywhere.
//! The node landing test runs the printed positions through the real
//! `pacer.wasm` on every `verify`, so a change to pacer's conversion
//! fails before a wrong skeleton ships.

const std = @import("std");
const testing = std.testing;

const time = @import("../time/time.zig");

const Grid = time.Grid;

/// The longest fraction a position may carry. f64 holds about 17
/// significant decimal digits, so nothing past this can name a tick the
/// shorter spellings missed.
pub const MAX_FRAC_DIGITS: usize = 17;

/// How many decimals with a given digit count are tried before the
/// search widens. The floor interval `[T / tpb, (T + 1) / tpb)` is
/// narrower than one unit in the last place for every digit count that
/// matters, so the first candidate at or just below its floor is
/// normally the answer; the extra tries cover the case where f64
/// rounding carries a shorter decimal UP onto the tick.
const max_candidates: usize = 4;

/// Enough for `-9223372036854775808.` + 17 digits.
pub const spell_buf_len: usize = 48;

/// pacer's ticks per beat under `[n d]`: `PPC / n`, exact for every
/// `n` in pacer's `meter-component` bound (720 720 is divisible by
/// 1..16). The denominator does not appear — pacer's beat is `1 / n` of
/// a bar whatever the note value is.
pub fn ticksPerBeat(n: u8) i64 {
    std.debug.assert(n >= 1 and n <= 16);
    return @divExact(Grid.PPC, @as(i64, n));
}

/// Whether `[n d]` is a meter pacer can carry: both components in
/// 1..16 (`meter-component`) and a denominator whose bar divides the
/// grid exactly (`Grid.pacerDivisor`). A meter that fails this is
/// `export_meter_unsupported` and the score gets `[4 4]`.
pub fn supportedMeter(n: u8, d: u8) bool {
    if (n < 1 or n > 16 or d < 1 or d > 16) return false;
    return Grid.pacerDivisor(n, d) != null;
}

/// pacer's `bpm-value` bound.
pub fn inBpmRange(bpm: f64) bool {
    return std.math.isFinite(bpm) and bpm >= 1 and bpm <= 1000;
}

/// `:bpm` for a document tempo: pacer's beat is a `4 / d` note, so the
/// beat rate is `qpm · d / 4`. Plan 08 pins the direction; midi 05 had
/// it inverted.
pub fn pacerBpm(qpm: f64, d: u8) f64 {
    return qpm * @as(f64, @floatFromInt(d)) / 4.0;
}

/// THE conversion, in pacer's op order: one multiply, one floor
/// (`pacer/src/TimeMap.zig`'s `mulFloor`). Saturates at the grid
/// ceiling instead of trapping, because a candidate decimal is allowed
/// to be absurd — it simply will not match.
pub fn pacerFloor(value: f64, rate: i64) i64 {
    if (!std.math.isFinite(value)) return Grid.MAX_TICK;
    const product = value * @as(f64, @floatFromInt(rate));
    if (!std.math.isFinite(product)) return Grid.MAX_TICK;
    const floored = @floor(product);
    const ceiling: f64 = @floatFromInt(Grid.MAX_TICK);
    if (floored >= ceiling) return Grid.MAX_TICK;
    if (floored <= -ceiling) return -Grid.MAX_TICK;
    return @intFromFloat(floored);
}

/// A tempura tick on pacer's lattice under `[n d]`: the nearest pacer
/// tick, ties DOWN, and whether it was already one.
///
/// PRECONDITION: `supportedMeter(n, d)` — the caller substitutes
/// `[4 4]` for a meter pacer cannot carry, and says so with
/// `export_meter_unsupported`, before it converts anything.
pub fn pacerTick(tick: i64, n: u8, d: u8) struct { tick: i64, exact: bool } {
    const divisor = Grid.pacerDivisor(n, d).?;
    const q = @divFloor(tick, divisor);
    const rem = tick - q * divisor;
    if (rem == 0) return .{ .tick = q, .exact = true };
    // Ties down: `2 · rem == divisor` keeps `q`.
    return .{ .tick = if (2 * rem > divisor) q + 1 else q, .exact = false };
}

/// The tally plan 08's header comment prints: how many positions left
/// the lattice and by how much, in pacer beats.
pub const Counter = struct {
    rounded: u32 = 0,
    max_err_beats: f64 = 0,

    /// Convert one tempura tick and record what it cost.
    pub fn convert(self: *Counter, tick: i64, n: u8, d: u8) i64 {
        const res = pacerTick(tick, n, d);
        if (!res.exact) {
            self.rounded +|= 1;
            const divisor = Grid.pacerDivisor(n, d).?;
            const off = @abs(tick - res.tick * divisor);
            // One pacer beat is `Grid.beatTicks(d)` tempura ticks —
            // `256 · PPC / d`, the same number `divisor · tpb` gives.
            const err = @as(f64, @floatFromInt(off)) /
                @as(f64, @floatFromInt(Grid.beatTicks(d)));
            if (err > self.max_err_beats) self.max_err_beats = err;
        }
        return res.tick;
    }
};

/// Print `pacer_tick` as a pacer position: `Nbar` on a bar line, else
/// the shortest decimal that floors back onto it, with the `b` unit.
///
/// A bar is `PPC` ticks whatever the meter is (pacer's `tickFromBars`),
/// so the bar spelling needs no meter and is exact for every integer.
pub fn spellBeats(writer: anytype, pacer_tick: i64, n: u8) !void {
    std.debug.assert(pacer_tick >= 0);
    if (@rem(pacer_tick, Grid.PPC) == 0)
        return writer.print("{d}bar", .{@divExact(pacer_tick, Grid.PPC)});

    const tpb = ticksPerBeat(n);
    var buf: [spell_buf_len]u8 = undefined;
    if (shortestFloor(&buf, pacer_tick, tpb)) |text|
        return writer.print("{s}b", .{text});

    // Unreachable for every tick a document can hold: the search only
    // runs out of digits where f64's significand runs out, past 10^17
    // beats. Printing the shortest round-trip of the exact ratio keeps
    // the text readable and one tick is the worst it can be off.
    return writer.print("{d}b", .{
        @as(f64, @floatFromInt(pacer_tick)) / @as(f64, @floatFromInt(tpb)),
    });
}

/// Print `secs` as a pacer `s` position — the 512-segment fallback's
/// unit (plan 08, "Transport and tempo"), where the score carries no
/// tempo table and every position is wall-clock.
pub fn spellSeconds(writer: anytype, secs: f64) !void {
    return writer.print("{d}s", .{secs});
}

/// Print `qpm · d / 4` as the shortest decimal that reads back as that
/// exact f64 — checked with `std.fmt.parseFloat`, the conversion SJON's
/// parser performs.
pub fn spellBpm(writer: anytype, qpm: f64, d: u8) !void {
    const v = pacerBpm(qpm, d);
    var buf: [spell_buf_len]u8 = undefined;
    var k: usize = 0;
    while (k <= MAX_FRAC_DIGITS) : (k += 1) {
        const scale = pow10(k);
        const scaled = @round(v * @as(f64, @floatFromInt(scale)));
        if (!std.math.isFinite(scaled)) break;
        const text = fixed(&buf, @intFromFloat(scaled), k);
        const back = std.fmt.parseFloat(f64, text) catch continue;
        if (back == v) return writer.print("{s}", .{text});
    }
    return writer.print("{d}", .{v});
}

// ---- the floor-interval search ----

/// The shortest decimal `D` with `pacerFloor(D, rate) == target`, or
/// null when 0..`MAX_FRAC_DIGITS` fractional digits hold none.
///
/// Candidates are generated by EXACT integer arithmetic — `m / 10^k`
/// for `m` from `floor(target · 10^k / rate)` (one step below the
/// interval, so a decimal f64 rounds up onto the tick is not missed) up
/// to one past `(target + 1) · 10^k / rate` — and each is decided by
/// the f64 check alone. Digit counts ascend, so the first hit IS the
/// shortest.
fn shortestFloor(buf: []u8, target: i64, rate: i64) ?[]const u8 {
    std.debug.assert(target >= 0 and rate > 0);
    const t: i128 = target;
    const r: i128 = rate;
    var k: usize = 0;
    while (k <= MAX_FRAC_DIGITS) : (k += 1) {
        const scale: i128 = pow10(k);
        var m: i128 = @max(@divFloor(t * scale, r), 0);
        // One past the interval: the smallest `m` with
        // `m / 10^k >= (target + 1) / rate`.
        const stop: i128 = @divFloor((t + 1) * scale + r - 1, r);
        var tries: usize = 0;
        while (m <= stop and tries < max_candidates) : ({
            m += 1;
            tries += 1;
        }) {
            const text = fixed(buf, m, k);
            const v = std.fmt.parseFloat(f64, text) catch continue;
            if (pacerFloor(v, rate) == target) return text;
        }
    }
    return null;
}

/// `10^k`, for `k <= MAX_FRAC_DIGITS`.
fn pow10(k: usize) i128 {
    var p: i128 = 1;
    var i: usize = 0;
    while (i < k) : (i += 1) p *= 10;
    return p;
}

/// `m / 10^k` as a plain fixed-point decimal, digit by digit — never
/// through a float, so the text is exactly the rational it names.
fn fixed(buf: []u8, m: i128, k: usize) []const u8 {
    std.debug.assert(m >= 0);
    const scale = pow10(k);
    const int_part = @divFloor(m, scale);
    var frac = m - int_part * scale;
    const head = std.fmt.bufPrint(buf, "{d}", .{int_part}) catch unreachable;
    if (k == 0) return head;
    var len = head.len;
    buf[len] = '.';
    len += 1;
    var place = @divExact(scale, 10);
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const digit = @divFloor(frac, place);
        buf[len] = '0' + @as(u8, @intCast(digit));
        len += 1;
        frac -= digit * place;
        place = @divTrunc(place, 10);
    }
    return buf[0..len];
}

// ---- tests ----

test "pos.pacerTick: the lattice, the nearest tick, and a tie going down" {
    // `[4 4]`: the divisor is 256 n / d = 256, so a quarter (TPQ) is
    // 180 180 pacer ticks and lands exactly.
    const q = pacerTick(Grid.TPQ, 4, 4);
    try testing.expectEqual(@as(i64, 180_180), q.tick);
    try testing.expect(q.exact);

    // A 32nd is TPQ / 8 and is NOT a pacer tick (plan 03's worked
    // correction). Its remainder is exactly half the divisor, so the tie
    // goes DOWN.
    const t32 = pacerTick(@divExact(Grid.TPQ, 8), 4, 4);
    try testing.expectEqual(@as(i64, 22_522), t32.tick);
    try testing.expect(!t32.exact);

    // Just past half rounds up; just under stays down.
    try testing.expectEqual(@as(i64, 1), pacerTick(129, 4, 4).tick);
    try testing.expectEqual(@as(i64, 0), pacerTick(127, 4, 4).tick);
    try testing.expectEqual(@as(i64, 0), pacerTick(128, 4, 4).tick);
}

test "pos.spellBeats: the floor-interval rule on a triplet, a quintuplet, a 16th and a 32nd" {
    var buf: [64]u8 = undefined;

    // A 16th is on the lattice and its decimal is exact.
    try testing.expectEqualStrings("0.25b", try spellSlice(&buf, 45_045, 4));

    // The quintuplet plan 08 names: `1.4b` floors one tick SHORT through
    // pacer's mul+floor, so the exporter prints the next decimal up.
    try testing.expectEqualStrings("1.400001b", try spellSlice(&buf, 252_252, 4));

    // …and the naive spelling really is one tick short, which is why the
    // rule exists at all.
    try testing.expectEqual(@as(i64, 252_251), pacerFloor(1.4, 180_180));

    // A triplet: `0.3333333333333333` STANDS (plan 08's words) — it does
    // land on the tick — but it is not the SHORTEST decimal that does.
    try testing.expectEqual(@as(i64, 60_060), pacerFloor(0.3333333333333333, 180_180));
    try testing.expectEqualStrings("0.333334b", try spellSlice(&buf, 60_060, 4));

    // A 32nd rounded onto the lattice (22 522) spells back as `0.125b`:
    // the decimal that floors onto the ROUNDED tick, not onto the 32nd.
    try testing.expectEqualStrings("0.125b", try spellSlice(&buf, 22_522, 4));
}

test "pos.spellBeats: bar lines print as Nbar, whatever the meter" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("0bar", try spellSlice(&buf, 0, 4));
    try testing.expectEqualStrings("1bar", try spellSlice(&buf, Grid.PPC, 4));
    try testing.expectEqualStrings("16bar", try spellSlice(&buf, 16 * Grid.PPC, 7));
    // One tick off a bar line is a beat position again.
    try testing.expectEqualStrings("3.999995b", try spellSlice(&buf, Grid.PPC - 1, 4));
}

test "pos.spellBeats: every pacer tick in two bars of [4 4] and [7 8] lands on itself" {
    // The exhaustive floor-interval proof, in tempura's reproduction of
    // pacer's op order. The node landing test runs the same rule through
    // the real `pacer.wasm` on a sample of these.
    for ([_]u8{ 4, 7 }) |n| {
        const tpb: f64 = @floatFromInt(ticksPerBeat(n));
        var buf: [64]u8 = undefined;
        var t: i64 = 0;
        while (t < 2 * Grid.PPC) : (t += 1) {
            const text = try spellSlice(&buf, t, n);
            if (std.mem.endsWith(u8, text, "bar")) {
                const bars = try std.fmt.parseFloat(f64, text[0 .. text.len - 3]);
                try testing.expectEqual(t, pacerFloor(bars, Grid.PPC));
            } else {
                const beats = try std.fmt.parseFloat(f64, text[0 .. text.len - 1]);
                try testing.expectEqual(t, pacerFloor(beats, @intFromFloat(tpb)));
            }
        }
    }
}

test "pos.Counter: off-lattice positions are counted with the worst error in beats" {
    var c: Counter = .{};
    try testing.expectEqual(@as(u32, 0), c.rounded);

    // On the lattice: nothing counted.
    try testing.expectEqual(@as(i64, 180_180), c.convert(Grid.TPQ, 4, 4));
    try testing.expectEqual(@as(u32, 0), c.rounded);
    try testing.expectEqual(@as(f64, 0), c.max_err_beats);

    // A 32nd is half a divisor off: 128 of 11 531 520 ticks to the beat.
    try testing.expectEqual(@as(i64, 22_522), c.convert(@divExact(Grid.TPQ, 8), 4, 4));
    try testing.expectEqual(@as(u32, 1), c.rounded);
    try testing.expectEqual(128.0 / @as(f64, @floatFromInt(Grid.beatTicks(4))), c.max_err_beats);

    // A smaller error does not replace the worst one.
    _ = c.convert(1, 4, 4);
    try testing.expectEqual(@as(u32, 2), c.rounded);
    try testing.expectEqual(128.0 / @as(f64, @floatFromInt(Grid.beatTicks(4))), c.max_err_beats);
}

test "pos.spellBpm: pacer's beat is 4/d of a quarter, so :bpm is qpm · d / 4" {
    var buf: [64]u8 = undefined;

    // `[4 4]`: a beat IS a quarter.
    try testing.expectEqualStrings("125", try bpmSlice(&buf, 125, 4));
    // `[6 8]`: a beat is an eighth, twice the quarter rate — plan 08's
    // direction, the one midi 05 wrote inverted.
    try testing.expectEqualStrings("250", try bpmSlice(&buf, 125, 8));
    try testing.expectEqualStrings("62.5", try bpmSlice(&buf, 125, 2));
    // A fractional tempo keeps every digit it needs to read back.
    try testing.expectEqualStrings("128.5", try bpmSlice(&buf, 128.5, 4));
    try testing.expectEqual(@as(f64, 250), pacerBpm(125, 8));
}

test "pos.supportedMeter: pacer's meter-component bound, 1..16 and a power of two below" {
    try testing.expect(supportedMeter(4, 4));
    try testing.expect(supportedMeter(7, 8));
    try testing.expect(supportedMeter(16, 16));
    // `d = 32` is tempura's grid but past pacer's `meter-component` 16.
    try testing.expect(!supportedMeter(4, 32));
    // `n = 17` likewise.
    try testing.expect(!supportedMeter(17, 4));
    // A denominator that is not a power of two has no pacer divisor.
    try testing.expect(!supportedMeter(4, 6));
}

test "pos.inBpmRange: pacer's bpm-value bound is 1..1000" {
    try testing.expect(inBpmRange(125));
    try testing.expect(inBpmRange(1));
    try testing.expect(inBpmRange(1000));
    try testing.expect(!inBpmRange(0.5));
    // Plan 08's example: `:qpm 600` in `[12 8]` is 1 200 pacer bpm.
    try testing.expect(!inBpmRange(pacerBpm(600, 8)));
}

// ---- test helpers ----

/// `spellBeats` into `buf`, as a slice.
fn spellSlice(buf: []u8, pacer_tick: i64, n: u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try spellBeats(&w, pacer_tick, n);
    return w.buffered();
}

fn bpmSlice(buf: []u8, qpm: f64, d: u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try spellBpm(&w, qpm, d);
    return w.buffered();
}
