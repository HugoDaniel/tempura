//! The one integer grid every source converts onto.
//!
//! `TPQ = 46 126 080` ticks per quarter note `= 2^10 · 3^2 · 5 · 7 · 11 ·
//! 13 = 64 · PPC` (plan 03, "The grid"). It is chosen so that an SMF
//! division, an Impulse Tracker tick and a pacer meter all land on integer
//! ticks: `2^10` covers 1024 PPQ and every binary subdivision a DAW
//! offers, and the odd part is SJON's and pacer's, kept whole so the
//! family shares one set of tuplets.
//!
//! Everything here is integer arithmetic. Nothing in this file rounds a
//! literal (`Pos.tickFromQuarters` is that seam) and nothing floors a
//! clock (`TimeMap` is that one); the only rounding here is the SMF
//! division that does not divide, and it is nearest-with-ties-to-even on
//! exact integer ratios, never on floats.
//!
//! No `Error`, because none of this needs one: a division that does not
//! divide is a `null` (`ticksPerSmfTick`, `pacerDivisor`), which the
//! caller turns into a `division_inexact` diagnostic with the span it
//! owns, and a position past the ceiling is a SATURATED value flagged
//! `overflow` (`smfToTicks`), which the caller turns into
//! `tick_overflow`. The two exceptions are `beatTicks` and `barTicks`,
//! which carry a precondition on their denominator instead — see there.

const std = @import("std");
const testing = std.testing;

/// Ticks per quarter note. The grid, frozen at E1.
pub const TPQ: i64 = 46_126_080;

/// Pacer ticks per bar (SJON `Pattern.PPC`). `TPQ = 64 · PPC`.
pub const PPC: i64 = 720_720;

/// One Impulse Tracker tick: `1/24` quarter note (it 06 accumulates beats
/// as `ticks / 24`), so a row of speed `s` is `s · IT_TICK`.
pub const IT_TICK: i64 = 1_921_920;

/// The portable ceiling, SJON's own (`Pattern.zig:51`): 195 273 460
/// quarter notes, about 27 000 hours at 120 qpm. Past it is a
/// `tick_overflow` diagnostic, never a wrap.
pub const MAX_TICK: i64 = 1 << 53;

/// How many tempura ticks one SMF tick of division `ppq` is worth, or
/// `null` when `ppq` does not divide `TPQ` (500, 1000, 30720 …) — the
/// file-level question a dump answers with `division_inexact`.
///
/// `ppq` is SMF's `division` field, 1..32767; 0 is not a division and
/// answers `null` rather than dividing by zero.
pub fn ticksPerSmfTick(ppq: u15) ?i64 {
    if (ppq == 0) return null;
    const d: i64 = ppq;
    if (@rem(TPQ, d) != 0) return null;
    return @divExact(TPQ, d);
}

/// One SMF tick position on the grid: exact when the division divides
/// `TPQ` (or when this particular value happens to come out whole), and
/// otherwise the NEAREST tick with ties going to the even one.
///
/// `exact` is per VALUE, not per division: the caller counts the events it
/// actually rounded, and asks `ticksPerSmfTick` about the file's header.
///
/// `overflow` says the position is past `MAX_TICK`, in which case `tick`
/// is SATURATED at the ceiling (signed) and the caller raises
/// `tick_overflow` — plan 03's rule that the ceiling is a diagnostic and
/// never a wrap. The whole computation runs in `i128` and is narrowed only
/// after that check, because the input is a file's: SMF deltas are 28-bit
/// and a few hundred maximal ones at `division = 1` run past `i64` itself,
/// which a byte-eating entry point must answer rather than trap on.
pub fn smfToTicks(smf_tick: i64, ppq: u15) struct { tick: i64, exact: bool, overflow: bool = false } {
    if (ppq == 0) return .{ .tick = 0, .exact = false };
    const den: i128 = ppq;
    const num: i128 = @as(i128, smf_tick) * TPQ;

    // Floor-and-remainder, so the tie rule reads the same on both sides of
    // zero: 0 <= rem < den.
    const q = @divFloor(num, den);
    const rem = num - q * den;
    const exact = rem == 0;

    var nearest = q;
    if (!exact) {
        const twice = 2 * rem;
        const up = if (twice > den)
            true
        else if (twice < den)
            false
        else
            // The tie: half of a tick. Take whichever neighbour is even.
            @rem(q, 2) != 0;
        if (up) nearest = q + 1;
    }

    // The ceiling, tested while the value is still `i128`: a saturated
    // position is not an exact one, whatever the division did.
    if (nearest > MAX_TICK) return .{ .tick = MAX_TICK, .exact = false, .overflow = true };
    if (nearest < -MAX_TICK) return .{ .tick = -MAX_TICK, .exact = false, .overflow = true };

    return .{ .tick = @intCast(nearest), .exact = exact };
}

/// How many tempura ticks one PACER tick is worth under meter `[n d]`
/// (`256 n / d`), or `null` when the meter has no place on pacer's
/// lattice.
///
/// pacer bounds both components to integers 1..16
/// (`pacer/schema/pacer.sjon:41-45`) and also accepts a `d` that is not a
/// power of two; tempura never emits one (plan 08,
/// `export_meter_unsupported`), so those answer `null` here. Every
/// accepted `d` divides 256, so the quotient is an integer — the check is
/// kept anyway, because the domain is the contract and not an accident of
/// the numbers.
pub fn pacerDivisor(n: u8, d: u8) ?i64 {
    switch (d) {
        1, 2, 4, 8, 16, 32 => {},
        else => return null,
    }
    if (n == 0) return null;

    const num: i64 = 256 * @as(i64, n);
    const den: i64 = d;
    if (@rem(num, den) != 0) return null;
    return @divExact(num, den);
}

/// One beat of a `[n d]` meter in ticks: `4 · TPQ / d` quarters' worth.
///
/// PRECONDITION: `d` divides `4 · TPQ = 2^12 · 3^2 · 5 · 7 · 11 · 13`.
/// Every denominator tempura emits does — `{1, 2, 4, 8, 16, 32}`,
/// `pacerDivisor`'s domain — as does every other value in pacer's own
/// 1..16 bound and every power of two an SMF's `dd` can spell in a `u8`.
/// A `d` outside that (0, 17, …) is a caller bug rather than user input:
/// the meter map validates before it converts, and `@divExact` makes a
/// violation loud instead of silently truncating a bar length.
pub fn beatTicks(d: u8) i64 {
    return @divExact(4 * TPQ, @as(i64, d));
}

/// One bar of a `[n d]` meter in ticks: `n` beats of `4 / d` quarters.
/// Equals `pacerDivisor(n, d) · PPC` whenever the meter has a divisor.
pub fn barTicks(n: u8, d: u8) i64 {
    return @as(i64, n) * beatTicks(d);
}

/// Whether `tick` sits on pacer's lattice under meter `[n d]` — that is,
/// whether it is a multiple of `256 n / d`. A meter with no divisor puts
/// nothing on the lattice.
///
/// Plan 03's worked correction: at 480 PPQ a 32nd note is SMF tick 60,
/// `TPQ / 8` here, and NOT a pacer tick.
pub fn isPacerTick(tick: i64, n: u8, d: u8) bool {
    const divisor = pacerDivisor(n, d) orelse return false;
    return @rem(tick, divisor) == 0;
}

test "Grid: the constants are the plan's numbers" {
    try testing.expectEqual(@as(i64, 46_126_080), TPQ);
    try testing.expectEqual(@as(i64, 720_720), PPC);
    try testing.expectEqual(@as(i64, 1_921_920), IT_TICK);
    try testing.expectEqual(@as(i64, 9_007_199_254_740_992), MAX_TICK);

    // TPQ = 2^10 · 3^2 · 5 · 7 · 11 · 13 = 64 · PPC — the factorisation is
    // what makes every row of the exactness table land.
    try testing.expectEqual(TPQ, 64 * PPC);
    try testing.expectEqual(TPQ, 1024 * 9 * 5 * 7 * 11 * 13);
    try testing.expectEqual(MAX_TICK, @as(i64, 1) << 53);
}

test "Grid.ticksPerSmfTick: every PPQ the plan lists divides TPQ" {
    // Plan 03, "The grid", the SMF row — enumerated one by one.
    const exact = [_]u15{ 24, 48, 96, 120, 192, 240, 384, 480, 960, 1024, 1920, 3840, 7680, 15360 };
    for (exact) |ppq| {
        const per = ticksPerSmfTick(ppq) orelse {
            std.debug.print("ppq {d} should divide TPQ\n", .{ppq});
            return error.TestExpectedExactDivision;
        };
        try testing.expectEqual(TPQ, per * @as(i64, ppq));
    }

    // The worked values, spelled out rather than derived.
    try testing.expectEqual(@as(?i64, 1_921_920), ticksPerSmfTick(24));
    try testing.expectEqual(@as(?i64, 96_096), ticksPerSmfTick(480));
    try testing.expectEqual(@as(?i64, 45_045), ticksPerSmfTick(1024));

    // And the three that do not: a dump counts these as
    // `division_inexact`.
    try testing.expectEqual(@as(?i64, null), ticksPerSmfTick(500));
    try testing.expectEqual(@as(?i64, null), ticksPerSmfTick(1000));
    try testing.expectEqual(@as(?i64, null), ticksPerSmfTick(30720));

    // 1 is a division nobody writes and every grid divides; 0 is not a
    // division at all and must not divide by zero.
    try testing.expectEqual(@as(?i64, TPQ), ticksPerSmfTick(1));
    try testing.expectEqual(@as(?i64, null), ticksPerSmfTick(0));
}

test "Grid.smfToTicks: a division of 0 is not a division" {
    // The header reader refuses `division = 0` before anything gets here;
    // the guard is so that a hole upstream is a zero, not a divide fault.
    const nil = smfToTicks(480, 0);
    try testing.expectEqual(@as(i64, 0), nil.tick);
    try testing.expect(!nil.exact);
}

test "Grid.smfToTicks: past the ceiling saturates and says so, never panics" {
    // The i128 product is narrowed to i64 only AFTER the grid ceiling is
    // checked. A crafted `.mid` reaches this: SMF deltas are 28-bit, so
    // about 750 maximal ones at `division = 1` put the running tick past
    // i64 itself, and `src/fuzz.zig` will try. The answer is a saturated
    // tick the caller can report as `tick_overflow`, never a trap.
    //
    // 480 PPQ, the last SMF tick under the ceiling and the first past it.
    // (Nothing can land EXACTLY on MAX_TICK: that needs `TPQ / ppq` to be
    // a power of two, and TPQ's odd part 45045 is larger than the biggest
    // division SMF can spell, so no `ppq <= 32767` gives one.)
    const last = smfToTicks(93_731_260_975, 480);
    try testing.expectEqual(@as(i64, 9_007_199_254_653_600), last.tick);
    try testing.expect(last.exact);
    try testing.expect(!last.overflow);

    const past = smfToTicks(93_731_260_976, 480);
    try testing.expectEqual(MAX_TICK, past.tick);
    try testing.expect(!past.exact);
    try testing.expect(past.overflow);

    // One maximal 28-bit delta at 1 PPQ is already past the ceiling.
    const delta = smfToTicks((1 << 28) - 1, 1);
    try testing.expectEqual(MAX_TICK, delta.tick);
    try testing.expect(delta.overflow);

    // And past i64 itself, both ways: the multiply is done in i128, so
    // these saturate instead of trapping.
    try testing.expectEqual(MAX_TICK, smfToTicks(std.math.maxInt(i64), 24).tick);
    try testing.expect(smfToTicks(std.math.maxInt(i64), 24).overflow);
    try testing.expectEqual(-MAX_TICK, smfToTicks(std.math.minInt(i64), 24).tick);
    try testing.expect(smfToTicks(std.math.minInt(i64), 24).overflow);

    // Everything an ordinary file holds leaves the flag alone.
    try testing.expect(!smfToTicks(60, 480).overflow);
    try testing.expect(!smfToTicks(1, 500).overflow);
    try testing.expect(!smfToTicks(0, 0).overflow);
}

test "Grid: the IT row — one tick is TPQ/24, a row is speed ticks" {
    try testing.expectEqual(TPQ, IT_TICK * 24);
    try testing.expectEqual(@as(?i64, IT_TICK), ticksPerSmfTick(24));
    // A row of speed 6 is a sixteenth note.
    try testing.expectEqual(@divExact(TPQ, 4), 6 * IT_TICK);
}

test "Grid.smfToTicks: exact divisions scale, the rest round half to even" {
    // Exact: 480 PPQ, a 32nd note is SMF tick 60 and tempura tick TPQ/8.
    const a = smfToTicks(60, 480);
    try testing.expect(a.exact);
    try testing.expectEqual(@divExact(TPQ, 8), a.tick);
    try testing.expectEqual(@as(i64, 5_765_760), a.tick);

    // Exact: a whole note at 96 PPQ.
    const b = smfToTicks(384, 96);
    try testing.expect(b.exact);
    try testing.expectEqual(4 * TPQ, b.tick);

    // Inexact: 500 PPQ. One SMF tick is TPQ/500 = 92252.16 — the nearest
    // tick is 92252, and the division is reported as inexact.
    const c = smfToTicks(1, 500);
    try testing.expect(!c.exact);
    try testing.expectEqual(@as(i64, 92_252), c.tick);

    // A tie at 1000 PPQ: TPQ/1000 = 46126.08, no tie; but 30720 PPQ gives
    // TPQ/30720 = 1501.5 exactly — half, so it goes to the EVEN neighbour.
    const tie = smfToTicks(1, 30720);
    try testing.expect(!tie.exact);
    try testing.expectEqual(@as(i64, 1502), tie.tick);
    // `exact` is per VALUE, not per division: two SMF ticks at 30720 are
    // 3003 tempura ticks with nothing left over, so that event did not
    // round even though its division is not a divisor of TPQ. (The
    // file-level `division_inexact` question is `ticksPerSmfTick`'s.)
    const two = smfToTicks(2, 30720);
    try testing.expectEqual(@as(i64, 3003), two.tick);
    try testing.expect(two.exact);
    // Three: 4504.5 → the even neighbour is 4504.
    const three = smfToTicks(3, 30720);
    try testing.expectEqual(@as(i64, 4504), three.tick);

    // Zero is zero on every division, exact or not.
    try testing.expectEqual(@as(i64, 0), smfToTicks(0, 500).tick);
    try testing.expect(smfToTicks(0, 480).exact);
}

test "Grid.pacerDivisor: the worked meters from plan 03" {
    // One pacer tick is `256 n / d` tempura ticks. Plan 03, "The grid",
    // the pacer row and the "Worked divisors" line, meter by meter.
    const rows = [_]struct { n: u8, d: u8, divisor: i64 }{
        .{ .n = 4, .d = 4, .divisor = 256 },
        .{ .n = 3, .d = 4, .divisor = 192 },
        .{ .n = 5, .d = 4, .divisor = 320 },
        .{ .n = 7, .d = 8, .divisor = 224 },
        .{ .n = 9, .d = 8, .divisor = 288 },
        .{ .n = 12, .d = 8, .divisor = 384 },
        .{ .n = 11, .d = 8, .divisor = 352 },
        .{ .n = 13, .d = 16, .divisor = 208 },
        .{ .n = 6, .d = 8, .divisor = 192 },
        .{ .n = 2, .d = 2, .divisor = 256 },
        .{ .n = 16, .d = 16, .divisor = 256 },
    };
    for (rows) |row| {
        const got = pacerDivisor(row.n, row.d) orelse {
            std.debug.print("meter [{d} {d}] should have a divisor\n", .{ row.n, row.d });
            return error.TestExpectedDivisor;
        };
        try testing.expectEqual(row.divisor, got);
        // And the bar is that divisor times pacer's ticks-per-bar.
        try testing.expectEqual(got * PPC, barTicks(row.n, row.d));
    }

    // A denominator that is not a power of two is a meter pacer accepts
    // and tempura never emits (`export_meter_unsupported`, plan 08).
    try testing.expectEqual(@as(?i64, null), pacerDivisor(4, 3));
    try testing.expectEqual(@as(?i64, null), pacerDivisor(3, 12));
    try testing.expectEqual(@as(?i64, null), pacerDivisor(4, 64));
    // Zero beats is not a meter — and would be a zero modulus below.
    try testing.expectEqual(@as(?i64, null), pacerDivisor(0, 4));
    try testing.expectEqual(@as(?i64, null), pacerDivisor(4, 0));
}

test "Grid.beatTicks / barTicks: a beat is 4/d quarters, a bar is n of them" {
    try testing.expectEqual(TPQ, beatTicks(4));
    try testing.expectEqual(2 * TPQ, beatTicks(2));
    try testing.expectEqual(4 * TPQ, beatTicks(1));
    try testing.expectEqual(@divExact(TPQ, 2), beatTicks(8));
    try testing.expectEqual(@divExact(TPQ, 4), beatTicks(16));
    // The grid is richer than pacer's lattice: a [n 3] beat is exact here
    // even though it has no pacer divisor.
    try testing.expectEqual(@as(i64, 61_501_440), beatTicks(3));
    try testing.expectEqual(4 * TPQ, 3 * beatTicks(3));

    try testing.expectEqual(4 * TPQ, barTicks(4, 4));
    try testing.expectEqual(3 * TPQ, barTicks(3, 4));
    try testing.expectEqual(@divExact(7 * TPQ, 2), barTicks(7, 8));
    try testing.expectEqual(barTicks(4, 4), barTicks(2, 2));
    try testing.expectEqual(barTicks(3, 4), barTicks(6, 8));
}

test "Grid.isPacerTick: a 32nd at 480 PPQ is on the grid, not on pacer's" {
    // Plan 03 corrects the midi set here: SMF tick 60 at 480 PPQ is a
    // 32nd note; 60 is not a multiple of 8, so it is NOT a pacer tick.
    const thirty_second = smfToTicks(60, 480);
    try testing.expect(thirty_second.exact);
    try testing.expectEqual(@divExact(TPQ, 8), thirty_second.tick);
    try testing.expect(!isPacerTick(thirty_second.tick, 4, 4));

    // A sixteenth is, and so are the bar line, the beat and the eighth.
    try testing.expect(isPacerTick(@divExact(TPQ, 4), 4, 4));
    try testing.expect(isPacerTick(0, 4, 4));
    try testing.expect(isPacerTick(TPQ, 4, 4));
    try testing.expect(isPacerTick(barTicks(4, 4), 4, 4));
    try testing.expect(isPacerTick(@divExact(TPQ, 2), 4, 4));

    // Triplets and quintuplets ARE on pacer's lattice — that is what the
    // odd part of PPC (`3^2 · 5 · 7 · 11 · 13`) is for. What falls off is
    // the deep BINARY subdivision: pacer gives 180 180 = 2^2 · 3^2 · 5 · 7
    // · 11 · 13 steps per quarter in [4 4], so 16ths land and 32nds do
    // not.
    try testing.expect(isPacerTick(@divExact(TPQ, 3), 4, 4));
    try testing.expect(isPacerTick(@divExact(TPQ, 6), 4, 4));
    try testing.expect(isPacerTick(@divExact(TPQ, 5), 4, 4));
    try testing.expect(!isPacerTick(@divExact(TPQ, 16), 4, 4));

    // A meter with no divisor puts nothing on pacer's grid.
    try testing.expect(!isPacerTick(0, 4, 3));
}
