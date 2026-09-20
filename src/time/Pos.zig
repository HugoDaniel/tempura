//! Positions: the five unit spellings a document writes, the one place a
//! literal rounds, and the printer's rule that spells a tick back.
//!
//! Plan 03, "Positions". A `position` is a number with a REQUIRED unit —
//! `2.5q`, `16bar`, `1t`, `0.5b`, `12.5s` — because a bare number names no
//! grid (SJON's `(unit-shape :required true …)`, pacer's `time-pos`). Two
//! units resolve here, on the grid alone (`q` and `t`); the other three
//! need the tempo or meter map and come back as `needs_map` for the layer
//! that owns those tables.
//!
//! The two roundings of plan 03 live in exactly one function each, and
//! this file owns the first: `tickFromQuarters` rounds a literal to the
//! NEAREST tick with ties to even (`TimeMap` owns the other, where a
//! clock floors). `spell` builds its decimal in integers and formats no
//! float; the one float it touches is the round-trip check that plan 03
//! makes the printer responsible for.
//!
//! Failures are diagnostics, never errors — `unit_required`,
//! `position_not_integer`, `position_negative`, `tick_overflow` — on a
//! value the caller gets back; the single `Error` is the host-guard
//! `TickOverflow`, which the callers turn into that last code.

const std = @import("std");
const testing = std.testing;
const Diag = @import("../Diag.zig");
const Grid = @import("Grid.zig");

/// The host-guard error set. Everything a DOCUMENT can get wrong is a
/// `Diag.Code` on a returned value instead.
pub const Error = error{TickOverflow};

/// The five position units (plan 03, "Positions").
pub const Unit = enum {
    /// Quarter notes, decimal.
    q,
    /// Tempura ticks, integer.
    t,
    /// Bars, decimal, counted from 0 through the meter map.
    bar,
    /// Beats, decimal, counted from 0 across the meter map.
    b,
    /// Seconds, decimal, through the tempo map. Forbidden on
    /// `tempo-point` and `meter-point` (circular; pacer's rule).
    s,
};

/// A position as WRITTEN: the number and the unit it named, before any
/// map is consulted.
pub const Literal = struct {
    value: f64,
    unit: Unit,
};

/// What `parse` answers: the literal, or the one diagnostic the reader
/// has to fix first.
pub const ParseResult = union(enum) {
    ok: Literal,
    err: Diag.Code,
};

/// Read one position literal — `<number><unit>`, no spaces.
///
/// The unit is the trailing run of ASCII letters, so an exponent
/// (`1e3q`) still reaches the number. Total: every input answers, and an
/// unreadable one answers `unit_required`, which is the complaint a
/// document actually gets from the schema's unit shape.
///
/// The number grammar is `std.fmt.parseFloat`'s, a SUPERSET of SJON's
/// number token — `0x10t`, `1_000q` and `+1q` are read here and never
/// reach here, because SJON's reader is the gate and refuses them first.
/// This function is deliberately the permissive end: a position that got
/// past the schema is one this file should read, not re-litigate.
pub fn parse(text: []const u8) ParseResult {
    var split = text.len;
    while (split > 0 and std.ascii.isAlphabetic(text[split - 1])) split -= 1;

    const unit = std.meta.stringToEnum(Unit, text[split..]) orelse
        return .{ .err = .unit_required };
    const value = std.fmt.parseFloat(f64, text[0..split]) catch
        return .{ .err = .unit_required };

    // The sign is read before the integrality of `t`: `-1.5t` is wrong in
    // two ways and a reader fixes the sign first.
    if (value < 0) return .{ .err = .position_negative };
    if (unit == .t and value != @trunc(value)) return .{ .err = .position_not_integer };

    return .{ .ok = .{ .value = value, .unit = unit } };
}

/// What `tickFromLiteral` answers: a tick, the unit whose TABLE the
/// caller must consult, or the diagnostic the document earned.
pub const TickResult = union(enum) {
    tick: i64,
    needs_map: Unit,
    err: Diag.Code,
};

/// THE literal rounding seam: quarter notes to ticks, one multiply and
/// one round to NEAREST with ties to EVEN (plan 03, "Positions"). It is
/// the only place a LITERAL rounds; the only other float rounding in the
/// repo is `TimeMap`'s clock floor. (`Grid.smfToTicks` rounds an inexact
/// division too, but on exact integer ratios, never through an f64.)
///
/// Ties to even, not away from zero: a literal names the nearest tick, so
/// a value sitting exactly between two of them must not drift in one
/// direction when a document is transposed, scaled or round-tripped.
/// `@round` is half-away-from-zero, so the tie is corrected explicitly.
///
/// `error.TickOverflow` past `MAX_TICK` (and for a non-finite value),
/// never a wrap; callers report it as `tick_overflow`.
pub fn tickFromQuarters(q: f64) Error!i64 {
    const scaled = q * @as(f64, @floatFromInt(Grid.TPQ));
    if (!std.math.isFinite(scaled)) return error.TickOverflow;

    var nearest = @round(scaled);
    // A tie is reachable only below 2^52, where the halves are still
    // representable; above it `scaled` is already an integer and the
    // difference is 0.
    if (@abs(scaled - nearest) == 0.5 and @rem(nearest, 2) != 0) {
        nearest -= std.math.sign(nearest);
    }

    const ceiling: f64 = @floatFromInt(Grid.MAX_TICK);
    if (nearest > ceiling or nearest < -ceiling) return error.TickOverflow;
    return @intFromFloat(nearest);
}

/// Resolve a literal as far as the grid alone allows.
///
/// `q` rounds through the seam above and `t` is taken as written; `bar`,
/// `b` and `s` need the meter or tempo map and come back as `needs_map`
/// for the layer that owns those tables. The document rules are restated
/// here rather than trusted from `parse`, because a literal also arrives
/// from a validated SJON number plus a unit token.
pub fn tickFromLiteral(lit: Literal) TickResult {
    if (lit.value < 0) return .{ .err = .position_negative };
    return switch (lit.unit) {
        .q => if (tickFromQuarters(lit.value)) |tick|
            .{ .tick = tick }
        else |_|
            .{ .err = .tick_overflow },
        .t => blk: {
            // A NaN is caught by the integrality test above (it equals
            // nothing, not even its own truncation), so this comparison
            // only has to hold back the ceiling.
            if (lit.value != @trunc(lit.value)) break :blk .{ .err = .position_not_integer };
            if (lit.value > @as(f64, @floatFromInt(Grid.MAX_TICK))) break :blk .{ .err = .tick_overflow };
            break :blk .{ .tick = @intFromFloat(lit.value) };
        },
        .bar, .b, .s => .{ .needs_map = lit.unit },
    };
}

/// The `q`-spelling lattice: `TPQ = 9009 · 5120` with `5120 = 2^10 · 5`,
/// so `k / TPQ` is a terminating decimal exactly when `9009` divides `k`,
/// and the reduced denominator then divides 5120 — at most 10 fractional
/// digits.
const Q_STEP: i64 = 9009;
const Q_DEN: u64 = 5120;
/// `10^10 / 5120`: turns a remainder out of 5120 into the 10 decimal
/// digits that follow the point, exactly, in integers.
const Q_DIGIT_SCALE: u64 = 1_953_125;

comptime {
    std.debug.assert(Grid.TPQ == Q_STEP * @as(i64, Q_DEN));
    std.debug.assert(Q_DEN * Q_DIGIT_SCALE == 10_000_000_000);
}

/// The printer's rule, frozen at E1 (plan 03, "The printer's rule"):
/// `Nbar` on a bar line, else `Nq` when the tick has an exact short
/// decimal in quarters, else `Nt`. Dumps of quantised material read as
/// music; triplets and freely played material read as ticks.
///
/// `bar_line` is the bar NUMBER the caller's meter table found for this
/// tick, or `null` when the tick is not on a bar line — this file owns no
/// map and asks for the answer rather than guessing it.
///
/// The decimal is produced by integer arithmetic (`m = tick / 9009`, the
/// value `m / 5120`, trailing zeros trimmed); no float is ever formatted.
/// The `q` branch is then CHECKED — plan 03 makes the printer responsible
/// for a spelling that reads back — because above roughly 2^52 ticks the
/// f64 literal seam can no longer carry a ten-digit decimal home. A
/// spelling that would not round-trip falls through to `Nt`.
pub fn spell(writer: anytype, tick: i64, bar_line: ?i64) !void {
    if (bar_line) |bar| return writer.print("{d}bar", .{bar});

    if (@rem(tick, Q_STEP) == 0) q: {
        const m = @divExact(tick, Q_STEP);

        // `@floatFromInt` is exact here (|m| < 2^53) and IEEE division is
        // correctly rounded, so this is bit-for-bit the f64 that
        // `parse` would hand back from the decimal printed below.
        const value = @as(f64, @floatFromInt(m)) / @as(f64, @floatFromInt(Q_DEN));
        const back = tickFromQuarters(value) catch break :q;
        if (back != tick) break :q;

        const mag: u64 = @abs(m);
        if (m < 0) try writer.writeAll("-");
        try writer.print("{d}", .{mag / Q_DEN});

        const rem = mag % Q_DEN;
        if (rem != 0) {
            var scaled = rem * Q_DIGIT_SCALE;
            var digits: [10]u8 = undefined;
            var i: usize = digits.len;
            while (i > 0) : (i -= 1) {
                digits[i - 1] = '0' + @as(u8, @intCast(scaled % 10));
                scaled /= 10;
            }
            var end: usize = digits.len;
            while (end > 1 and digits[end - 1] == '0') end -= 1;
            try writer.writeAll(".");
            try writer.writeAll(digits[0..end]);
        }
        return writer.writeAll("q");
    }

    return writer.print("{d}t", .{tick});
}

/// `spell` into a fresh slice owned by the caller — free it with `gpa`.
/// The convenience for callers that have no writer at hand; the canonical
/// printer writes straight into the document's.
pub fn spellAlloc(gpa: std.mem.Allocator, tick: i64, bar_line: ?i64) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // An `Allocating` writer fails for exactly one reason, and `spell`
    // itself cannot fail: the `WriteFailed` it can raise IS the failed
    // allocation, so it is named as one here.
    spell(&aw.writer, tick, bar_line) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

test "Pos.parse: each of the five units, in its plan-03 spelling" {
    try testing.expectEqual(Literal{ .value = 2.5, .unit = .q }, parse("2.5q").ok);
    try testing.expectEqual(Literal{ .value = 16, .unit = .bar }, parse("16bar").ok);
    try testing.expectEqual(Literal{ .value = 1, .unit = .t }, parse("1t").ok);
    try testing.expectEqual(Literal{ .value = 0.5, .unit = .b }, parse("0.5b").ok);
    try testing.expectEqual(Literal{ .value = 12.5, .unit = .s }, parse("12.5s").ok);

    // Zero is a position, and `bar` and `b` count from 0 like pacer's.
    try testing.expectEqual(Literal{ .value = 0, .unit = .q }, parse("0q").ok);
    try testing.expectEqual(Literal{ .value = 0, .unit = .bar }, parse("0bar").ok);

    // An exponent reaches the number: the unit is only the trailing run
    // of letters.
    try testing.expectEqual(Literal{ .value = 1000, .unit = .q }, parse("1e3q").ok);

    // A big integer tick, and a long decimal, both read whole.
    try testing.expectEqual(Literal{ .value = 15_375_360, .unit = .t }, parse("15375360t").ok);
    try testing.expectEqual(Literal{ .value = 0.0001953125, .unit = .q }, parse("0.0001953125q").ok);
}

test "Pos.parse: a plain number is unit_required" {
    // SJON's `(unit-shape :required true …)`, pacer's `time-pos`
    // spelling: a bare number in a position slot names no grid.
    try testing.expectEqual(Diag.Code.unit_required, parse("16").err);
    try testing.expectEqual(Diag.Code.unit_required, parse("2.5").err);
    try testing.expectEqual(Diag.Code.unit_required, parse("0").err);
    try testing.expectEqual(Diag.Code.unit_required, parse("").err);
}

test "Pos.parse: an unknown unit is unit_required too" {
    try testing.expectEqual(Diag.Code.unit_required, parse("4beats").err);
    try testing.expectEqual(Diag.Code.unit_required, parse("120bpm").err);
    try testing.expectEqual(Diag.Code.unit_required, parse("2Q").err);
    try testing.expectEqual(Diag.Code.unit_required, parse("2ms").err);
    // A unit with no number names nothing either.
    try testing.expectEqual(Diag.Code.unit_required, parse("bar").err);
    // Nor does a malformed number: the schema's unit shape is what a
    // document actually trips, and this is the same complaint.
    try testing.expectEqual(Diag.Code.unit_required, parse("1.2.3q").err);
}

test "Pos.parse: a negative position is position_negative" {
    try testing.expectEqual(Diag.Code.position_negative, parse("-1q").err);
    try testing.expectEqual(Diag.Code.position_negative, parse("-0.5bar").err);
    try testing.expectEqual(Diag.Code.position_negative, parse("-1t").err);
    try testing.expectEqual(Diag.Code.position_negative, parse("-12.5s").err);
    // The sign is read before the integrality of `t`: one complaint, the
    // one a reader fixes first.
    try testing.expectEqual(Diag.Code.position_negative, parse("-1.5t").err);

    // Negative ZERO is not a negative position: it is the origin, and it
    // resolves to tick 0 like any other spelling of it.
    try testing.expectEqual(Literal{ .value = -0.0, .unit = .q }, parse("-0q").ok);
    try testing.expectEqual(@as(i64, 0), tickFromLiteral(parse("-0q").ok).tick);
    try testing.expectEqual(@as(i64, 0), tickFromLiteral(parse("-0.0t").ok).tick);
}

test "Pos.parse: a fractional tick is position_not_integer" {
    try testing.expectEqual(Diag.Code.position_not_integer, parse("1.5t").err);
    try testing.expectEqual(Diag.Code.position_not_integer, parse("0.0001t").err);
    // `1.0t` is an integer spelled with a point, and is fine.
    try testing.expectEqual(Literal{ .value = 1, .unit = .t }, parse("1.0t").ok);
    // Every other unit is decimal by definition.
    try testing.expectEqual(Literal{ .value = 1.5, .unit = .q }, parse("1.5q").ok);
    try testing.expectEqual(Literal{ .value = 1.5, .unit = .bar }, parse("1.5bar").ok);
}

test "Pos.tickFromQuarters: one multiply, and the plain values are exact" {
    try testing.expectEqual(@as(i64, 0), try tickFromQuarters(0));
    try testing.expectEqual(Grid.TPQ, try tickFromQuarters(1));
    try testing.expectEqual(@as(i64, 115_315_200), try tickFromQuarters(2.5));
    try testing.expectEqual(4 * Grid.TPQ, try tickFromQuarters(4));
    try testing.expectEqual(@divExact(Grid.TPQ, 4), try tickFromQuarters(0.25));
    // A tuplet the grid was chosen for: a third of a quarter is exact.
    try testing.expectEqual(@divExact(Grid.TPQ, 3), try tickFromQuarters(1.0 / 3.0));
}

test "Pos.tickFromQuarters: ties go to the EVEN tick, not away from zero" {
    // `q = j / 2048` with j odd puts the product exactly on a half tick
    // (`TPQ / 2048 = 22522.5`), which is the only way to reach a tie from
    // a value f64 holds exactly. `@round` would answer away-from-zero on
    // every one of these; ties-to-even splits them.
    try testing.expectEqual(@as(i64, 22_522), try tickFromQuarters(1.0 / 2048.0));
    try testing.expectEqual(@as(i64, 67_568), try tickFromQuarters(3.0 / 2048.0));
    try testing.expectEqual(@as(i64, 112_612), try tickFromQuarters(5.0 / 2048.0));
    try testing.expectEqual(@as(i64, 157_658), try tickFromQuarters(7.0 / 2048.0));
    // And away from zero, at a tie that is not near it.
    try testing.expectEqual(@as(i64, 46_148_602), try tickFromQuarters(1.0 + 1.0 / 2048.0));

    // A hair off the tie on either side: nearest wins, and the tie rule
    // does not reach values that are not exactly half.
    try testing.expectEqual(@as(i64, 22_523), try tickFromQuarters((1.0 + 1e-9) / 2048.0));
    try testing.expectEqual(@as(i64, 22_522), try tickFromQuarters((1.0 - 1e-9) / 2048.0));
}

test "Pos.tickFromQuarters: past MAX_TICK is TickOverflow, never a wrap" {
    // 195 273 460 quarter notes is the last whole quarter under the
    // ceiling; the next one is past it.
    try testing.expectEqual(@as(i64, 9_007_199_237_836_800), try tickFromQuarters(195_273_460));
    try testing.expectError(error.TickOverflow, tickFromQuarters(195_273_461));
    try testing.expectError(error.TickOverflow, tickFromQuarters(1e30));
    try testing.expectError(error.TickOverflow, tickFromQuarters(-1e30));
    try testing.expectError(error.TickOverflow, tickFromQuarters(std.math.inf(f64)));
    try testing.expectError(error.TickOverflow, tickFromQuarters(std.math.nan(f64)));
    // The ceiling itself is reachable and is not an overflow.
    try testing.expectEqual(Grid.MAX_TICK, try tickFromQuarters(@as(f64, @floatFromInt(Grid.MAX_TICK)) / @as(f64, @floatFromInt(Grid.TPQ))));
}

test "Pos.tickFromLiteral: q and t resolve here, the map units do not" {
    try testing.expectEqual(@as(i64, 115_315_200), tickFromLiteral(.{ .value = 2.5, .unit = .q }).tick);
    try testing.expectEqual(@as(i64, 0), tickFromLiteral(.{ .value = 0, .unit = .q }).tick);
    try testing.expectEqual(@as(i64, 1), tickFromLiteral(.{ .value = 1, .unit = .t }).tick);
    try testing.expectEqual(@as(i64, 15_375_360), tickFromLiteral(.{ .value = 15_375_360, .unit = .t }).tick);
    try testing.expectEqual(Grid.MAX_TICK, tickFromLiteral(.{ .value = @floatFromInt(Grid.MAX_TICK), .unit = .t }).tick);

    // `bar`, `b` and `s` need a table this file does not own.
    try testing.expectEqual(Unit.bar, tickFromLiteral(.{ .value = 16, .unit = .bar }).needs_map);
    try testing.expectEqual(Unit.b, tickFromLiteral(.{ .value = 0.5, .unit = .b }).needs_map);
    try testing.expectEqual(Unit.s, tickFromLiteral(.{ .value = 12.5, .unit = .s }).needs_map);
}

test "Pos.tickFromLiteral: the diagnostics, on literals no parse built" {
    // A literal can arrive from a validated SJON number and a unit token
    // without passing through `parse`, so the rules are re-stated here.
    try testing.expectEqual(Diag.Code.position_negative, tickFromLiteral(.{ .value = -1, .unit = .q }).err);
    try testing.expectEqual(Diag.Code.position_negative, tickFromLiteral(.{ .value = -0.5, .unit = .bar }).err);
    try testing.expectEqual(Diag.Code.position_not_integer, tickFromLiteral(.{ .value = 1.5, .unit = .t }).err);
    try testing.expectEqual(Diag.Code.tick_overflow, tickFromLiteral(.{ .value = 195_273_461, .unit = .q }).err);
    try testing.expectEqual(Diag.Code.tick_overflow, tickFromLiteral(.{ .value = 1e30, .unit = .t }).err);
}

/// Spell `tick` into `buf` for the tests below, and give back the slice.
fn spelled(buf: []u8, tick: i64, bar_line: ?i64) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try spell(&w, tick, bar_line);
    return w.buffered();
}

test "Pos.spell: a bar line prints as Nbar, whatever its tick is" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("16bar", try spelled(&buf, 16 * 4 * Grid.TPQ, 16));
    try testing.expectEqualStrings("0bar", try spelled(&buf, 0, 0));
    try testing.expectEqualStrings("1bar", try spelled(&buf, 3 * Grid.TPQ, 1));
    // Bar lines win even where a `q` spelling exists — a dump of
    // quantised material reads as music.
    try testing.expectEqualStrings("64bar", try spelled(&buf, 64 * 4 * Grid.TPQ, 64));
}

test "Pos.spell: 9009 | tick prints as the exact shortest decimal quarter" {
    // `TPQ / 9009 = 5120 = 2^10 · 5`, so `k / TPQ` terminates in at most
    // 10 fractional digits exactly when 9009 divides k.
    var buf: [64]u8 = undefined;
    const cases = [_]struct { tick: i64, text: []const u8 }{
        .{ .tick = 0, .text = "0q" },
        .{ .tick = Grid.TPQ, .text = "1q" },
        .{ .tick = 115_315_200, .text = "2.5q" },
        .{ .tick = @divExact(Grid.TPQ, 2), .text = "0.5q" },
        .{ .tick = @divExact(Grid.TPQ, 4), .text = "0.25q" },
        .{ .tick = @divExact(Grid.TPQ, 8), .text = "0.125q" },
        .{ .tick = 3 * @divExact(Grid.TPQ, 4), .text = "0.75q" },
        .{ .tick = 64 * Grid.TPQ, .text = "64q" },
        // The smallest q the rule can spell: one 5120th of a quarter.
        .{ .tick = 9009, .text = "0.0001953125q" },
        .{ .tick = 4 * 9009, .text = "0.00078125q" },
        .{ .tick = Grid.TPQ + 9009, .text = "1.0001953125q" },
    };
    for (cases) |c| {
        try testing.expectEqualStrings(c.text, try spelled(&buf, c.tick, null));
    }
}

test "Pos.spell: everything else prints as ticks" {
    var buf: [64]u8 = undefined;
    // A triplet: 1/3 of a quarter is not a terminating decimal, and
    // `TPQ / 3` is not a multiple of 9009. `0.3333333333q` is never
    // emitted.
    try testing.expectEqualStrings("15375360t", try spelled(&buf, @divExact(Grid.TPQ, 3), null));
    try testing.expectEqualStrings("7687680t", try spelled(&buf, @divExact(Grid.TPQ, 6), null));
    // One IT tick is 1/24 of a quarter — also a repeating decimal.
    try testing.expectEqualStrings("1921920t", try spelled(&buf, Grid.IT_TICK, null));
    // Freely played material.
    try testing.expectEqualStrings("1t", try spelled(&buf, 1, null));
    try testing.expectEqualStrings("46126081t", try spelled(&buf, Grid.TPQ + 1, null));
    try testing.expectEqualStrings("9007199254740992t", try spelled(&buf, Grid.MAX_TICK, null));
}

test "Pos.spell: a q spelling is emitted only when it reads back exactly" {
    // Plan 03: \"a printed `q` value round-trips because the printer checks
    // it\". Above ~2^52 the f64 seam stops being able to carry a
    // 10-fractional-digit decimal back to the same tick, so the printer
    // falls through to ticks even though 9009 divides this one.
    var buf: [64]u8 = undefined;
    const big: i64 = 3_867_658_884_166_077;
    try testing.expectEqual(@as(i64, 0), @rem(big, 9009));
    try testing.expectEqualStrings("3867658884166077t", try spelled(&buf, big, null));
}

test "Pos.spellAlloc: the same text, owned by the caller" {
    const gpa = testing.allocator;

    const q = try spellAlloc(gpa, 115_315_200, null);
    defer gpa.free(q);
    try testing.expectEqualStrings("2.5q", q);

    const t = try spellAlloc(gpa, @divExact(Grid.TPQ, 3), null);
    defer gpa.free(t);
    try testing.expectEqualStrings("15375360t", t);

    const bar = try spellAlloc(gpa, 0, 12);
    defer gpa.free(bar);
    try testing.expectEqualStrings("12bar", bar);
}

test "Pos: spell → parse → tick is the identity on 10 000 random ticks" {
    // The printer's rule is only worth anything if it is reversible: what
    // a dump prints, a document may say back, and the tick has to be the
    // same one. Half the draws are snapped onto the `9009` lattice so the
    // `q` branch is exercised as hard as the `t` one.
    var prng = std.Random.DefaultPrng.init(0x7e_11_70_72_61);
    const rand = prng.random();

    var buf: [64]u8 = undefined;
    var q_spellings: usize = 0;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        var k = rand.intRangeAtMost(i64, 0, Grid.MAX_TICK);
        if (i % 2 == 0) k -= @rem(k, 9009);

        const text = try spelled(&buf, k, null);
        if (std.mem.endsWith(u8, text, "q")) q_spellings += 1;

        const lit = switch (parse(text)) {
            .ok => |l| l,
            .err => |code| {
                std.debug.print("tick {d} spelled {s}, which does not parse: {t}\n", .{ k, text, code });
                return error.TestSpellingDoesNotParse;
            },
        };
        switch (tickFromLiteral(lit)) {
            .tick => |got| if (got != k) {
                std.debug.print("tick {d} spelled {s}, which reads back as {d}\n", .{ k, text, got });
                return error.TestRoundTripDrifted;
            },
            else => {
                std.debug.print("tick {d} spelled {s}, which does not resolve on the grid\n", .{ k, text });
                return error.TestSpellingNeedsAMap;
            },
        }
    }
    // And the `q` branch really was exercised: without the printer's
    // round-trip check this count would be ~5000 and the loop would fail.
    try testing.expect(q_spellings > 3_000);
}

test "Pos.spell: a negative tick keeps its sign — the printer never lies" {
    // No document holds one (`position_negative` refuses it at the door),
    // but `spell` is total over `i64` and a printer that drops a sign is
    // worse than one that prints something unusual.
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("-9010t", try spelled(&buf, -9009 - 1, null));
    try testing.expectEqualStrings("-0.0001953125q", try spelled(&buf, -9009, null));
    try testing.expectEqualStrings("-2.5q", try spelled(&buf, -115_315_200, null));
}

test "Pos.spell: below 2^51 every 9009-multiple really does spell as a quarter" {
    // The round-trip check in `spell` is a safety net, not a policy: in
    // the range music lives in (2^51 ticks is 48 million quarter notes,
    // about 6 700 hours at 120 qpm) the f64 seam carries a ten-digit
    // decimal home every time, so the `q` branch must never fall back
    // there. The error term is `tick · 2^-52`, so below 2^51 it cannot
    // reach the half tick that would change the rounding.
    var prng = std.Random.DefaultPrng.init(0x5120_9009);
    const rand = prng.random();

    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 5_000) : (i += 1) {
        var k = rand.intRangeAtMost(i64, 0, 1 << 51);
        k -= @rem(k, 9009);
        const text = try spelled(&buf, k, null);
        if (!std.mem.endsWith(u8, text, "q")) {
            std.debug.print("tick {d} fell back to {s}\n", .{ k, text });
            return error.TestQSpellingFellBack;
        }
    }
}
