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
//! 2. **Back into text.** pacer reads a position literal with one
//!    `mul + floor` (`pacer/src/TimeMap.zig`): a `b` literal against
//!    `tpb = PPC / n`, an `s` literal against `ticks_per_second`, each an
//!    exact value computed once. A shortest-ROUND-TRIP decimal of the
//!    value is not safe — `1.4 · 180180` is `252251.999…` in f64 and
//!    floors one tick short — so a position prints as the **shortest
//!    decimal `D` with `floor(f64(D) · rate) == T`**, searched over
//!    0..17 fractional digits and checked HERE in pacer's own op order.
//!    `std.fmt.parseFloat` is the decimal→f64 conversion because it is
//!    the one SJON's parser performs on a number literal
//!    (`SJON/src/Parser.zig`), so the check and the read agree by
//!    construction. One search serves both units: `spellBeats` passes
//!    `tpb`, `spellSeconds` passes `tps`.
//!
//! 3. **Beats versus quarters.** pacer's beat is `1 / n` of a bar, a
//!    `4 / d` note, and tempura's tempo is per quarter — so `:bpm =
//!    qpm · d / 4` and pacer's two bounds (`bpm-value` 1..1000,
//!    `meter-component` 1..16) are checked before anything is emitted.
//!
//! `Mapper` is where a caller meets all three: it holds the mode a score
//! is in (beats, or the 512-segment fallback's seconds), converts a
//! tempura tick to a pacer tick, converts a DURATION as the span of
//! `[at, at + dur)` rather than of `[0, dur)`, spells either, and keeps
//! the two rounding tallies the header comment prints.
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
const Map = time.TimeMap.TimeMap;

/// The longest fraction a position may carry. f64 holds about 17
/// significant decimal digits, so nothing past this can name a tick the
/// shorter spellings missed.
pub const MAX_FRAC_DIGITS: usize = 17;

/// Enough for `9223372036854775808.` + 17 digits.
pub const spell_buf_len: usize = 48;

/// pacer's ticks per beat under `[n d]`: `PPC / n`, exact for every
/// `n` in pacer's `meter-component` bound (720 720 is divisible by
/// 1..16). The denominator does not appear — pacer's beat is `1 / n` of
/// a bar whatever the note value is.
pub fn ticksPerBeat(n: u8) i64 {
    std.debug.assert(n >= 1 and n <= 16);
    return @divExact(Grid.PPC, @as(i64, n));
}

/// pacer's `ticks_per_second` for a score with NO tempo table:
/// `(bpm · f64(tpb)) / 60.0`, `pacer/src/TimeMap.zig`'s `init` op order,
/// computed once. That is the rate the 512-segment fallback's `s`
/// positions are read back through, because a score carrying no
/// `(tempo …)` form takes pacer's degenerate path
/// (`tickFromSeconds`: `if (segments.len <= 1) return mulFloor(seconds,
/// ticks_per_second)`), and its seconds DURATIONS take the same one
/// (`pacer/src/Compile.zig`: `if (map.segments.len <= 1 or anchor == 0)
/// break :blk map.tickFromSeconds(value)`).
pub fn ticksPerSecond(bpm: f64, n: u8) f64 {
    return (bpm * @as(f64, @floatFromInt(ticksPerBeat(n)))) / 60.0;
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
pub fn pacerFloor(value: f64, rate: f64) i64 {
    if (!std.math.isFinite(value) or !std.math.isFinite(rate)) return Grid.MAX_TICK;
    const product = value * rate;
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

/// The tally plan 08's header comment prints. Positions and DURATIONS
/// are counted apart: a position that left the lattice moves an event,
/// a duration that left it changes how long a window lasts, and a
/// person reading the header wants to know which happened.
pub const Counter = struct {
    rounded: u32 = 0,
    max_err_beats: f64 = 0,
    durations_rounded: u32 = 0,
    max_dur_err_beats: f64 = 0,

    /// Convert one tempura tick onto the lattice and record what it
    /// cost. The beats-mode position path; `Mapper` owns the other.
    pub fn convert(self: *Counter, tick: i64, n: u8, d: u8) i64 {
        const res = pacerTick(tick, n, d);
        if (!res.exact) self.notePosition(errorInBeats(tick - res.tick * Grid.pacerDivisor(n, d).?, d));
        return res.tick;
    }

    /// Record a position that missed its tick by `err` pacer beats.
    pub fn notePosition(self: *Counter, err: f64) void {
        self.rounded +|= 1;
        if (err > self.max_err_beats) self.max_err_beats = err;
    }

    /// Record a duration that missed its span by `err` pacer beats.
    pub fn noteDuration(self: *Counter, err: f64) void {
        self.durations_rounded +|= 1;
        if (err > self.max_dur_err_beats) self.max_dur_err_beats = err;
    }
};

/// `off` tempura ticks as a fraction of one pacer beat. One pacer beat
/// is `Grid.beatTicks(d)` tempura ticks — `256 · PPC / d`, the same
/// number `divisor · tpb` gives.
fn errorInBeats(off: i64, d: u8) f64 {
    return @as(f64, @floatFromInt(@abs(off))) / @as(f64, @floatFromInt(Grid.beatTicks(d)));
}

// ---- the mapper: one door for every position a score prints ----

/// Which grid a score's positions ride, and how they print.
pub const Mode = union(enum) {
    /// pacer's lattice under `[n d]`, printed in beats and bars.
    beats: struct { n: u8, d: u8 },
    /// The wall clock, printed in seconds — the 512-segment fallback.
    /// The score then carries NO `(tempo …)` form, so pacer's
    /// seconds→ticks takes its degenerate one-`mul`-one-`floor` path
    /// against `tps` and an `s` position lands on a tick exactly the way
    /// a `b` position does. `n` is still the emitted meter's, because
    /// `tps` is derived from `tpb = PPC / n`.
    seconds: struct { n: u8, tps: f64, map: *const Map },
};

/// The one place a tempura tick becomes a pacer tick and a pacer tick
/// becomes text.
///
/// Every caller goes through it, so a score in the seconds fallback
/// converts, aggregates and prints by exactly the same rules as a score
/// in beats — and both modes' roundings land in one `Counter`.
pub const Mapper = struct {
    mode: Mode,
    counter: Counter = .{},

    /// The meter's numerator, whichever mode this is.
    pub fn beatsPerBar(self: *const Mapper) u8 {
        return switch (self.mode) {
            .beats => |b| b.n,
            .seconds => |s| s.n,
        };
    }

    /// A POSITION: the pacer tick this tempura tick lands on, counted.
    pub fn position(self: *Mapper, tick: i64) i64 {
        switch (self.mode) {
            .beats => |b| return self.counter.convert(@max(tick, 0), b.n, b.d),
            .seconds => |s| {
                const want = self.wallTicks(tick);
                const landed = nearest(want);
                if (want != @as(f64, @floatFromInt(landed)))
                    self.counter.notePosition(@abs(want - @as(f64, @floatFromInt(landed))) /
                        @as(f64, @floatFromInt(ticksPerBeat(s.n))));
                return landed;
            },
        }
    }

    /// A DURATION: how many pacer ticks the window `[at, at + dur)`
    /// spans, counted apart from positions.
    ///
    /// The span, not the length measured from zero. Under a tempo map
    /// those differ — seconds mode exists precisely because the tempo is
    /// not constant, so "the seconds elapsed over the first `dur` ticks"
    /// is not the length of a window that starts at `at`. The op order
    /// is fixed: convert both ends, subtract once.
    pub fn durationTicks(self: *Mapper, at: i64, dur: i64) i64 {
        const from = @max(at, 0);
        const to = from +| @max(dur, 0);
        const a = self.rawPosition(from);
        const b = self.rawPosition(to);
        const span = b - a;
        switch (self.mode) {
            .beats => |m| {
                const divisor = Grid.pacerDivisor(m.n, m.d).?;
                const off = (to - from) - span * divisor;
                if (off != 0) self.counter.noteDuration(errorInBeats(off, m.d));
            },
            .seconds => |m| {
                const want = self.wallTicks(to) - self.wallTicks(from);
                const got: f64 = @floatFromInt(span);
                if (want != got) self.counter.noteDuration(@abs(want - got) /
                    @as(f64, @floatFromInt(ticksPerBeat(m.n))));
            },
        }
        return span;
    }

    /// Print a pacer tick in this score's unit.
    pub fn spell(self: *const Mapper, writer: anytype, pacer_tick: i64) !void {
        return switch (self.mode) {
            .beats => |b| spellBeats(writer, pacer_tick, b.n),
            .seconds => |s| spellSeconds(writer, pacer_tick, s.tps),
        };
    }

    /// The same conversion as `position`, without touching the counter —
    /// what `durationTicks` reads its two ends through, so a window's
    /// ends are not counted twice.
    fn rawPosition(self: *const Mapper, tick: i64) i64 {
        return switch (self.mode) {
            .beats => |b| pacerTick(@max(tick, 0), b.n, b.d).tick,
            .seconds => nearest(self.wallTicks(tick)),
        };
    }

    /// Where a tempura tick sits on pacer's grid in the seconds mode:
    /// the document's own clock, times pacer's constant tick rate.
    fn wallTicks(self: *const Mapper, tick: i64) f64 {
        const s = self.mode.seconds;
        return s.map.secondsFromTick(@max(tick, 0)) * s.tps;
    }
};

/// Nearest integer, ties DOWN — the tie rule `pacerTick` uses, so the
/// two modes round the same way.
fn nearest(x: f64) i64 {
    if (!std.math.isFinite(x)) return 0;
    const lo = @floor(x);
    return pacerFloor(if (x - lo > 0.5) lo + 1 else lo, 1.0);
}

// ---- spelling ----

/// Print `pacer_tick` as a pacer position in beats: `Nbar` on a bar
/// line, else the shortest decimal that floors back onto it, with `b`.
///
/// A bar is `PPC` ticks whatever the meter is (pacer's `tickFromBars`),
/// so the bar spelling needs no meter and is exact for every integer.
pub fn spellBeats(writer: anytype, pacer_tick: i64, n: u8) !void {
    std.debug.assert(pacer_tick >= 0);
    if (@rem(pacer_tick, Grid.PPC) == 0)
        return writer.print("{d}bar", .{@divExact(pacer_tick, Grid.PPC)});

    const tpb: f64 = @floatFromInt(ticksPerBeat(n));
    var buf: [spell_buf_len]u8 = undefined;
    if (shortestFloor(&buf, pacer_tick, tpb)) |text|
        return writer.print("{s}b", .{text});
    return writer.print("{d}b", .{@as(f64, @floatFromInt(pacer_tick)) / tpb});
}

/// Print `pacer_tick` as a pacer position in seconds — the 512-segment
/// fallback's unit (plan 08, "Transport and tempo"), under the SAME
/// floor-interval rule beats take, against `tps` instead of `tpb`.
///
/// Without it two adjacent pacer ticks (about 2.8 µs apart at 120 bpm
/// in `[4 4]`) could print decimals that floor onto one tick, and pacer
/// refuses an `:at` list that is not strictly ascending.
pub fn spellSeconds(writer: anytype, pacer_tick: i64, tps: f64) !void {
    std.debug.assert(pacer_tick >= 0);
    var buf: [spell_buf_len]u8 = undefined;
    if (shortestFloor(&buf, pacer_tick, tps)) |text|
        return writer.print("{s}s", .{text});
    return writer.print("{d}s", .{@as(f64, @floatFromInt(pacer_tick)) / tps});
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
/// `pacerFloor(·, rate)` is monotone non-decreasing: a correctly-rounded
/// decimal→f64 conversion, one multiply and one floor each are. So for
/// every digit count `k` there is exactly ONE candidate worth checking —
/// `g(k)`, the smallest `m` with `pacerFloor(m / 10^k, rate) >= target`.
/// Anything smaller floors below the target; anything larger floors at
/// least as high as `g(k)` does, so if `g(k)` overshoots, no `k`-digit
/// decimal lands.
///
/// And `g` walks cheaply: `(g(k) − 1) / 10^k` is below the target and
/// `g(k) / 10^k` is at or above it, so `g(k+1)` lies in
/// `(10 · (g(k) − 1), 10 · g(k)]` — ten candidates, scanned in order.
/// Driving the search by `pacerFloor` itself is what makes it exact:
/// f64's own rounding is part of the answer rather than something a
/// candidate generator has to predict. It also makes one search serve
/// both units, since only `rate` differs.
fn shortestFloor(buf: []u8, target: i64, rate: f64) ?[]const u8 {
    std.debug.assert(target >= 0);
    if (!std.math.isFinite(rate) or rate <= 0) return null;

    var m = firstAtOrAbove(target, rate);
    var k: usize = 0;
    while (true) : (k += 1) {
        const text = fixed(buf, m, k);
        if (pacerFloor(parse(text), rate) == target) return text;
        if (k == MAX_FRAC_DIGITS) return null;
        // Widen by one digit: the answer is in `(10·(m − 1), 10·m]`.
        const top = 10 * m;
        var next = @max(10 * (m - 1) + 1, 0);
        while (next < top and pacerFloor(parse(fixed(buf, next, k + 1)), rate) < target) next += 1;
        m = next;
    }
}

/// The smallest whole number whose `mul + floor` reaches `target` — the
/// search's `g(0)`. The quotient names it to within a step or two, and
/// the walk closes the gap against `pacerFloor` itself.
fn firstAtOrAbove(target: i64, rate: f64) i128 {
    if (target <= 0) return 0;
    const quotient = @as(f64, @floatFromInt(target)) / rate;
    var m: i128 = if (std.math.isFinite(quotient) and quotient > 0)
        @intFromFloat(@min(@ceil(quotient), @as(f64, @floatFromInt(Grid.MAX_TICK))))
    else
        0;
    var steps: usize = 0;
    while (m > 0 and pacerFloor(@floatFromInt(m - 1), rate) >= target and steps < 64) : (steps += 1) m -= 1;
    steps = 0;
    while (pacerFloor(@floatFromInt(m), rate) < target and steps < 64) : (steps += 1) m += 1;
    return m;
}

/// A decimal this module formatted always parses; an infinity for the
/// unreachable case simply fails every comparison.
fn parse(text: []const u8) f64 {
    return std.fmt.parseFloat(f64, text) catch std.math.inf(f64);
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
    try testing.expectEqual(@as(i64, 252_251), pacerFloor(1.4, 180_180.0));

    // A triplet: `0.3333333333333333` STANDS (plan 08's words) — it does
    // land on the tick — but it is not the SHORTEST decimal that does.
    try testing.expectEqual(@as(i64, 60_060), pacerFloor(0.3333333333333333, 180_180.0));
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
                try testing.expectEqual(t, pacerFloor(bars, @floatFromInt(Grid.PPC)));
            } else {
                const beats = try std.fmt.parseFloat(f64, text[0 .. text.len - 1]);
                try testing.expectEqual(t, pacerFloor(beats, tpb));
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

test "pos.spellSeconds: the floor-interval rule against pacer's seconds -> ticks" {
    // 120 bpm in [4 4]: `tps = (120 · 180180) / 60 = 360360` ticks a
    // second, pacer's own `init` op order.
    const tps = ticksPerSecond(120, 4);
    try testing.expectEqual(@as(f64, 360_360), tps);

    var buf: [64]u8 = undefined;
    // A whole second, and a tick that a naive shortest-round-trip would
    // print short: every printed decimal floors back onto its own tick.
    for ([_]i64{ 0, 1, 2, 3, 360_360, 360_361, 252_252, 720_719, 1_441_440 }) |t| {
        var w = std.Io.Writer.fixed(&buf);
        try spellSeconds(&w, t, tps);
        const text = w.buffered();
        try testing.expect(std.mem.endsWith(u8, text, "s"));
        const secs = try std.fmt.parseFloat(f64, text[0 .. text.len - 1]);
        try testing.expectEqual(t, pacerFloor(secs, tps));
    }

    // Adjacent ticks get DISTINCT, ascending spellings — without that,
    // two events 2.8 µs apart would floor onto one tick and pacer would
    // refuse the `:at` list (`trigger_invalid`).
    var a_buf: [64]u8 = undefined;
    var b_buf: [64]u8 = undefined;
    var wa = std.Io.Writer.fixed(&a_buf);
    var wb = std.Io.Writer.fixed(&b_buf);
    try spellSeconds(&wa, 1000, tps);
    try spellSeconds(&wb, 1001, tps);
    try testing.expect(!std.mem.eql(u8, wa.buffered(), wb.buffered()));
}

test "pos.Mapper: a duration is the span of [at, at+dur), not the seconds over [0, dur)" {
    const gpa = testing.allocator;
    // Two bars of [4 4]: the first at 60 quarter notes a minute, the
    // second at 240. A window over the SECOND bar lasts a quarter of
    // what a window of the same tick length over the first one does, and
    // a duration measured from tick 0 would report the first.
    var res = try time.TimeMap.derive(gpa, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 60 } },
        .{ .tick = 4 * Grid.TPQ, .tempo = .{ .qpm = 240 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 8 * Grid.TPQ, .hold);
    defer res.diags.deinit();
    defer res.map.deinit();

    const tps = ticksPerSecond(120, 4);
    var m: Mapper = .{ .mode = .{ .seconds = .{ .n = 4, .tps = tps, .map = &res.map } } };

    // Bar 0 is four quarters at 60 qpm = 4 s; bar 1 is four at 240 = 1 s.
    const bar = 4 * Grid.TPQ;
    const first = m.durationTicks(0, bar);
    const second = m.durationTicks(bar, bar);
    try testing.expectEqual(@as(i64, @intFromFloat(4.0 * tps)), first);
    try testing.expectEqual(@as(i64, @intFromFloat(1.0 * tps)), second);
    // …and the bug this pins: measured from zero, the second window
    // would report the first window's four seconds.
    try testing.expect(second != first);
    try testing.expectEqual(first, m.durationTicks(0, bar));
}

test "pos.Mapper: beats mode converts, spells and counts durations apart from positions" {
    var m: Mapper = .{ .mode = .{ .beats = .{ .n = 4, .d = 4 } } };

    // On the lattice: nothing counted, either way.
    try testing.expectEqual(@as(i64, 180_180), m.position(Grid.TPQ));
    try testing.expectEqual(@as(i64, 180_180), m.durationTicks(Grid.TPQ, Grid.TPQ));
    try testing.expectEqual(@as(u32, 0), m.counter.rounded);
    try testing.expectEqual(@as(u32, 0), m.counter.durations_rounded);

    // A 32nd off the lattice counts as a POSITION rounding…
    _ = m.position(@divExact(Grid.TPQ, 8));
    try testing.expectEqual(@as(u32, 1), m.counter.rounded);
    try testing.expectEqual(@as(u32, 0), m.counter.durations_rounded);

    // …and a window whose span leaves the lattice counts as a DURATION
    // one, on its own tally.
    _ = m.durationTicks(0, @divExact(Grid.TPQ, 8));
    try testing.expectEqual(@as(u32, 1), m.counter.rounded);
    try testing.expectEqual(@as(u32, 1), m.counter.durations_rounded);
    try testing.expect(m.counter.max_dur_err_beats > 0);

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try m.spell(&w, 180_180);
    try testing.expectEqualStrings("1b", w.buffered());
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
