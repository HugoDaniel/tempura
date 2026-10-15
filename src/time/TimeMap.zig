//! The tempo and meter maps: the two tables that give the grid seconds
//! and bars (plan 03, "Tempo" and "Meter").
//!
//! `derive` turns the document's `tempo-point`s and `meter-point`s into
//! a segment table, a meter table and a bar table, best-effort: every
//! way a map can be wrong is a DIAGNOSTIC on the returned result and the
//! map is still built, because an editor has to show something.

const std = @import("std");
const testing = std.testing;
const Diag = @import("../Diag.zig");
const Grid = @import("Grid.zig");
const Pos = @import("Pos.zig");

/// The host-guard error set (pacer's own). A defective DOCUMENT is a
/// diagnostic; these two are the ceiling and a non-finite host clock.
pub const Error = error{ TickOverflow, NonFiniteTime };

/// The segment budget (plan 03: a per-tick IT slide over a whole song is
/// a few thousand). pacer's 512 is the EXPORT budget, not this one.
pub const MAX_TEMPO_SEGMENTS: usize = 4096;

/// The bar table's budget. The table is one `i64` per bar up to
/// `:length`, and the shortest bar tempura can spell is `[1 32]`
/// (5 765 760 ticks), so the grid's own ceiling alone would let a
/// document ask for 1.5 billion entries. 2^20 bars is over five hundred
/// hours of `[4 4]` at 120 quarter notes per minute; past it the table
/// stops and says `tick_overflow`, the same answer the ceiling gives.
pub const MAX_BARS: usize = 1 << 20;

/// One tempo point as authored.
pub const TempoPoint = struct {
    tick: i64,
    tempo: union(enum) { us: u32, qpm: f64 },
    span: Diag.Span = .{ .start = 0, .end = 0 },
};

/// One meter point as authored.
pub const MeterPoint = struct {
    tick: i64,
    n: u8,
    d: u8,
    span: Diag.Span = .{ .start = 0, .end = 0 },
};

/// What happens at `:length` (plan 03, "Tempo", loop and hold).
pub const End = enum { loop, hold };

/// A declared frame rate (plan 03's `f` unit): `num/den` frames per
/// second, from `:fps 25` (num 25, den 1) or `:fps [30000 1001]` (NTSC —
/// never a bare decimal, which would bake 2997/100 into every NTSC
/// document). Both components are bounded `1..16 777 215` by the
/// manifest, mirroring `us-per-quarter`, to catch typos.
pub const FrameRate = struct {
    num: u32,
    den: u32,
};

/// The frame state a map carries: the declared rate, and whether the
/// document wrote an `f` position — the printer's per-document rule,
/// which a rate alone never triggers.
pub const Frames = struct {
    rate: FrameRate,
    wrote: bool,
};

/// A resolved position: the tick, or the diagnostic the document earned.
/// An `f` literal whose frame lands on no tick start answers `inexact`
/// instead — the floored tick, which stands (never a wrap), with the
/// warning the caller raises. `durationTicks` answers in this shape.
pub const Resolved = union(enum) {
    tick: i64,
    inexact: i64,
    err: Diag.Code,
};

/// `tickFromLiteral`'s answer, the position twin of `Resolved`: the
/// tick, an off-grid frame's floored tick, or the diagnostic the
/// document earned.
pub const LiteralTick = union(enum) {
    tick: i64,
    inexact: i64,
    err: Diag.Code,
};

/// One derived tempo segment.
pub const Segment = struct {
    tick: i64,
    us: f64,
    tps: f64,
    start_sec: f64,
    /// The integer seconds origin, valid only when the map is `integral`.
    t_i: i128,
    /// The span of the authored point this segment came from, empty for a
    /// segment the map supplied (a document with no usable point at tick
    /// 0). This is the segment-to-point identity, captured by the table
    /// that makes the pairing (`tempoTable`) so a consumer never has to
    /// recover it by matching tick and rate.
    span: Diag.Span = .{ .start = 0, .end = 0 },
};

/// One derived meter segment.
pub const MeterSeg = struct {
    tick: i64,
    n: u8,
    d: u8,
    first_bar: i64,
    beats_before: i64,
};

/// The derived maps.
pub const TimeMap = struct {
    segments: []Segment,
    meters: []MeterSeg,
    bars: []i64,
    length: i64,
    end: End,
    /// The document's declared frame state, or null when it declared no
    /// `:fps` — the one state an `f` literal refuses. Set once, by
    /// `derive`; nothing below writes it.
    frames: ?Frames,
    integral: bool,
    loop_secs: f64,
    arena: std.heap.ArenaAllocator,

    /// Frees the three tables. The map borrows nothing from the points
    /// it was derived from, so they may go first.
    pub fn deinit(self: *TimeMap) void {
        self.arena.deinit();
    }

    /// The map's own contract, asserted where a map is made (the end of
    /// `derive`) and where a whole one is read (`derive.Derived`'s, so the
    /// `Playhead` entry points). Every clause is one `derive` ESTABLISHES
    /// whatever the points said — a point that would break one is a
    /// diagnostic and never an entry — so a failure is a bug in this file,
    /// never a defect of a document. O(segments + meters + bars): a
    /// construction's cost, never a query's.
    pub fn invariants(self: *const TimeMap) void {
        self.segmentInvariants();
        self.meterInvariants();
        self.barInvariants();
        // The loop point is a number, and a length at or after tick 0
        // lies at or after second 0. A NEGATIVE length is `derive`'s to
        // take (see there), and its loop point is then behind second 0.
        std.debug.assert(!std.math.isNan(self.loop_secs));
        if (self.length >= 0) std.debug.assert(self.loop_secs >= 0);
    }

    /// The tempo table: from tick 0, strictly ascending inside the grid
    /// and the budget, every rate positive, the seconds origins never
    /// stepping back, and each path's own representation throughout.
    fn segmentInvariants(self: *const TimeMap) void {
        const segs = self.segments;
        std.debug.assert(segs.len >= 1);
        std.debug.assert(segs.len <= MAX_TEMPO_SEGMENTS);
        std.debug.assert(segs[0].tick == 0);
        std.debug.assert(segs[0].start_sec == 0);
        std.debug.assert(segs[0].t_i == 0);
        for (segs, 0..) |s, i| {
            std.debug.assert(s.tick <= Grid.MAX_TICK);
            std.debug.assert(std.math.isFinite(s.us));
            std.debug.assert(s.us > 0);
            // Positive, so never a NaN — but NOT always finite: a `:qpm`
            // near f64's own ceiling makes a `us` whose rate overflows to
            // +inf, which every read of the table answers without a trap.
            std.debug.assert(s.tps > 0);
            if (self.integral) {
                std.debug.assert(s.us == @trunc(s.us));
                std.debug.assert(s.us < MAX_INTEGRAL_US);
            } else {
                std.debug.assert(s.t_i == 0);
            }
            if (i == 0) continue;
            const prev = segs[i - 1];
            std.debug.assert(s.tick > prev.tick);
            std.debug.assert(s.start_sec >= prev.start_sec);
            std.debug.assert(s.t_i >= prev.t_i);
        }
    }

    /// The meter table: from tick 0 and bar 0, strictly ascending inside
    /// the grid, every signature one `meterOk` admits, and every change a
    /// whole number of bars of the meter before it — which is what the
    /// bar numbers and beat counts it carries say.
    fn meterInvariants(self: *const TimeMap) void {
        const mets = self.meters;
        std.debug.assert(mets.len >= 1);
        std.debug.assert(mets[0].tick == 0);
        std.debug.assert(mets[0].first_bar == 0);
        std.debug.assert(mets[0].beats_before == 0);
        for (mets, 0..) |m, i| {
            std.debug.assert(m.tick <= Grid.MAX_TICK);
            std.debug.assert(m.n >= 1);
            std.debug.assert(m.n <= 64);
            std.debug.assert(m.d >= 1);
            std.debug.assert(m.d <= 32);
            std.debug.assert(std.math.isPowerOfTwo(m.d));
            // A segment the bar table reaches starts on its own first bar.
            if (m.first_bar < self.bars.len) {
                std.debug.assert(self.bars[@intCast(m.first_bar)] == m.tick);
            }
            if (i == 0) continue;
            const prev = mets[i - 1];
            const nbars = m.first_bar - prev.first_bar;
            std.debug.assert(nbars >= 1);
            std.debug.assert(m.tick - prev.tick == nbars * Grid.barTicks(prev.n, prev.d));
            std.debug.assert(m.beats_before - prev.beats_before == nbars * prev.n);
        }
    }

    /// The bar table: bar 0 at tick 0, strictly ascending inside the grid
    /// and the budget, and stopping at the FIRST bar line at or after the
    /// length — so no entry before the last one reaches it.
    fn barInvariants(self: *const TimeMap) void {
        const bars = self.bars;
        std.debug.assert(bars.len >= 1);
        std.debug.assert(bars.len <= MAX_BARS);
        std.debug.assert(bars[0] == 0);
        std.debug.assert(bars[bars.len - 1] <= Grid.MAX_TICK);
        for (bars[1..], bars[0 .. bars.len - 1]) |b, prev| std.debug.assert(b > prev);
        if (bars.len >= 2) std.debug.assert(bars[bars.len - 2] < @max(self.length, 0));
    }

    /// `seconds(tick)`, plan 03's formula in whichever path this map
    /// took. A SEGMENT START is exact by construction — `seconds(tick_i)`
    /// IS `start_sec_i`, the table entry — which is what makes
    /// `tickFromSeconds(secondsFromTick(tick_i))` return `tick_i`.
    /// Interior ticks make no such claim: a clock value is the last tick
    /// BEGUN, and `seconds(k)` may sit one ulp below `k`'s true start.
    ///
    /// Total over `i64`: `Playhead.atTick` hands it whatever tick a host
    /// asked about, so it asserts nothing of `tick` — only that the
    /// answer is a number on the same side of zero as the tick. Not
    /// always a FINITE one: a near-zero rate reaches +inf.
    pub fn secondsFromTick(self: *const TimeMap, tick: i64) f64 {
        const seg = self.segments[self.segmentOfTick(tick)];
        const seconds = if (self.integral) integral: {
            // (T_i + (tick − tick_i) · us_i) / (TPQ · 1e6): the numerator
            // is exact in i128, and there is ONE division.
            const num = seg.t_i + @as(i128, tick - seg.tick) * @as(i128, @intFromFloat(seg.us));
            break :integral @as(f64, @floatFromInt(num)) / TICK_US;
        } else floating: {
            // start_sec_i + (tick − tick_i) / tps_i.
            break :floating seg.start_sec + @as(f64, @floatFromInt(tick - seg.tick)) / seg.tps;
        };
        std.debug.assert(!std.math.isNan(seconds));
        if (tick >= 0) std.debug.assert(seconds >= 0);
        if (tick <= 0) std.debug.assert(seconds <= 0);
        return seconds;
    }

    /// THE clock floor, and the only one in the repo (plan 03's risk
    /// note: literals round — `Pos.tickFromQuarters` — clocks floor, and
    /// each rounding has exactly one function). Both paths are the same
    /// shape against the active segment's origin, and the `max(0, …)`
    /// clamp covers a seconds value that selected segment `i` and lands
    /// an ulp before its origin.
    ///
    /// Does NOT wrap: `wrapSeconds` is the end-behaviour seam and runs
    /// FIRST, in seconds, at the `at`-style caller.
    pub fn tickFromSeconds(self: *const TimeMap, seconds: f64) Error!i64 {
        if (!std.math.isFinite(seconds)) return error.NonFiniteTime;
        const seg = self.segments[self.segmentOfSeconds(seconds)];

        const offset = if (self.integral) off: {
            // (seconds · (TPQ · 1e6) − T_i) / us_i.
            const scaled = seconds * TICK_US;
            if (!std.math.isFinite(scaled)) return error.TickOverflow;
            break :off (scaled - @as(f64, @floatFromInt(seg.t_i))) / seg.us;
        } else off: {
            // (seconds − start_sec_i) · tps_i.
            break :off (seconds - seg.start_sec) * seg.tps;
        };
        if (!std.math.isFinite(offset)) return error.TickOverflow;

        const floored = @max(0, @floor(offset));
        const ceiling: f64 = @floatFromInt(Grid.MAX_TICK);
        if (floored > ceiling) return error.TickOverflow;
        const tick = seg.tick + @as(i64, @intFromFloat(floored));
        if (tick > Grid.MAX_TICK) return error.TickOverflow;
        // On the grid, and never before the segment it was read in.
        std.debug.assert(tick >= seg.tick);
        std.debug.assert(tick >= 0);
        return tick;
    }

    /// Frame `n` at `rate`, as seconds — `n · den / num`, ONE multiply
    /// and ONE divide, in that order. This is the whole of a frame
    /// literal's own arithmetic (plan 03's op-order discipline); the
    /// only rounding a frame ever takes is the clock seam every clock
    /// value already takes.
    fn frameSeconds(rate: FrameRate, n: f64) f64 {
        return n * @as(f64, @floatFromInt(rate.den)) / @as(f64, @floatFromInt(rate.num));
    }

    /// `TICK_US` as the exact integer the frame path's
    /// cross-multiplication runs on — `TPQ · 1e6` folded at comptime,
    /// the same number the f64 constant holds.
    const TICK_US_I: i128 = @as(i128, Grid.TPQ) * 1_000_000;

    /// The widest whole `us` the exact frame path admits. Schema-legal
    /// `us` stops at 16 777 215 and a `:qpm` at one names 60 000 000,
    /// both far under it; the bound is the proof below that no `i128`
    /// product the path forms can overflow, so a map a HOST built by
    /// hand past it takes the f64 seam rather than a wrapped product.
    /// With every `us` ≤ 2^36: each origin `t_i ≤ MAX_TICK · us ≤ 2^89`
    /// (the anchor's own numerator likewise), a frame literal inside
    /// the grid satisfies `p · den · TICK_US ≤ 2^53 · 2^24 · 2^46 <
    /// 2^123`, and the segment walk only ever compares origins against
    /// the anchor's — a difference the same `2^123` term bounds on
    /// either side (checked, so even a hand-built map past the bound
    /// answers rather than wraps).
    const EXACT_US_MAX: f64 = 0x1p36;

    /// An f64 frame literal as the exact rational it names: `value ==
    /// p · 2^-shift` with `p` the literal's whole IEEE significand, so
    /// the exact path never re-associates a float. `huge` marks a
    /// literal of 2^127 frames or more, which no grid this map can
    /// hold lands (any schema-legal rate puts it past `MAX_TICK`
    /// ticks). Nothing here classifies a SMALL literal: whether its
    /// instant leaves its anchor's own tick is a question about the
    /// rate and the anchor's segment (`exactFloor`'s two-arm test),
    /// never about the literal's exponent alone.
    const FrameParts = struct {
        p: i128,
        shift: u32,
        huge: bool = false,
    };

    fn frameParts(n: f64) FrameParts {
        const raw: u64 = @bitCast(n);
        const mant = raw & 0x000F_FFFF_FFFF_FFFF;
        const biased: u32 = @intCast((raw >> 52) & 0x7FF);
        if (biased == 0) {
            // Zero, or a denormal: `mant · 2^-1074`. Both reach
            // `exactFloor`, where zero is the anchor exactly and the
            // denormal's shift 1074 falls to the wide-shift arm.
            return .{ .p = @intCast(mant), .shift = 1074 };
        }
        const p: i128 = (@as(i128, 1) << 52) | @as(i128, mant);
        const e: i32 = @as(i32, @intCast(biased)) - 1075;
        if (e >= 0) {
            // A whole literal of 2^52 frames or more. A shift past 74
            // would leave `p` alone near `i128`'s ceiling while every
            // product it feeds is bounded by `2^123` — such a literal
            // is `huge`, and the caller answers `tick_overflow`.
            if (e > 74) return .{ .p = 0, .shift = 0, .huge = true };
            return .{ .p = p << @intCast(e), .shift = 0 };
        }
        return .{ .p = p, .shift = @intCast(-e) };
    }

    /// Where an instant measured from `anchor` lands, exactly: the
    /// tick and whether the instant IS that tick's start — the frame
    /// seam's own two questions, answered in integers so neither the
    /// floor nor the verdict depends on any float association.
    const ExactLanding = struct { tick: i64, exact: bool };

    /// The exact landing of frame literal `n` at `rate`, measured from
    /// tick `anchor` (tick 0 for a position): the instant
    /// `n · den / num` seconds is `p · 2^-shift · den / num`, located
    /// on the segment table by integer cross-multiplication — the same
    /// floor `tickFromSeconds` would take, computed without the f64
    /// detour that can round an exact frame one tick short, and the
    /// same read-back, judged as the exact rational instead of a float
    /// sum against a float division. Null when this map is not
    /// integral or one of its `us` is past `EXACT_US_MAX`: the caller
    /// takes the f64 seam, which stays deterministic (the declared
    /// limit of the f64 tempo path).
    fn exactLanding(
        self: *const TimeMap,
        rate: FrameRate,
        n: f64,
        anchor: i64,
    ) ?(Error!ExactLanding) {
        if (!self.exactMap()) return null;

        const parts = frameParts(n);
        if (parts.huge) return Error.TickOverflow;
        // Zero frames is the anchor itself. A literal small enough to
        // stay inside its anchor's own tick is NOT decided here: that
        // judgment needs the rate and the anchor's segment, and it is
        // `exactFloor`'s first question — an exponent alone cannot
        // answer it, which is the whole of the finding-1 defect.
        if (parts.p == 0) return ExactLanding{ .tick = anchor, .exact = true };

        // The ceiling pre-check, in f64 where it only ever classifies:
        // an instant past the grid's own last second by a relative band
        // 2^-40 wide — four orders wider than any rounding in either
        // chain — is `tick_overflow` exactly as the seam answers it,
        // and an instant inside the band is one whose every integer
        // product below is inside the envelope `EXACT_US_MAX` proves.
        const secs = frameSeconds(rate, n);
        const ceil_secs = self.secondsFromTick(Grid.MAX_TICK);
        if (secs > ceil_secs * (1.0 + 0x1p-40)) return Error.TickOverflow;

        return self.exactFloor(rate, parts, anchor) catch |e| return e;
    }

    /// Whether a frame literal's instant stays strictly inside its
    /// anchor's own tick — the judgment the shift-only cutoff once
    /// guessed at and got wrong at schema-legal rates (finding 1, plan
    /// 03's dated 2026-10-15 ruling): a literal under `2^-48` frames
    /// can still be millions of ticks wide when `den` is large and
    /// `us` small, so the answer is this EXACT compare, never a
    /// threshold. Tiny is `r_num / r_den < us_a`, with
    /// `r_den = num · 2^shift` and `us_a` the anchor segment's whole
    /// `us` — two arms, each keeping every product inside `i128`:
    ///
    ///   * Arm A — the shift cannot hold the denominator. `shift ≥
    ///     127`, or `shift + bits(num) > 127`, means `num << shift`
    ///     needs more than 127 bits, so `r_den > 2^127 > r_num`: a
    ///     fractional literal's `p` is under `2^53` by construction
    ///     and the manifest bounds `den < 2^24` and `num ≥ 1`, so
    ///     `r_num < 2^123` while `r_den` is past `2^127` — the
    ///     instant is under `2^-4` of a unit and cannot reach the
    ///     `us_a ≥ 1` mark. (Arm A never fires at `shift = 0`: a u32
    ///     `num` cannot carry 128 bits.) The old cutoff's overflow
    ///     guard, restated as a proof.
    ///   * Arm B — the exact compare, without the product:
    ///     `r_num < us_a · num · 2^shift ⟺ (r_num >> shift) <
    ///     us_a · num`, the floor-shift identity for positive
    ///     integers, with `shift ≤ 126` here (so the shift itself is
    ///     legal) and `us_a · num ≤ 2^36 · 2^24 = 2^60`.
    ///
    /// In the non-tiny case `r_den ≤ r_num / us_a ≤ r_num < 2^123`,
    /// so the caller's `num << shift` is PROVEN to fit — no widening,
    /// no f64 fallback, and no classification a tolerance could move.
    fn frameTiny(rate: FrameRate, parts: FrameParts, r_num: i128, us_a: i128) bool {
        const num_bits: u32 = 32 - @as(u32, @clz(rate.num));
        if (parts.shift >= 127 or parts.shift + num_bits > 127) return true;
        const held = us_a * @as(i128, rate.num);
        return r_num >> @intCast(parts.shift) < held;
    }

    /// `exactLanding`'s arithmetic, apart so the parent stays the
    /// guard: the tiny judgment, the anchor's own numerator, the
    /// literal's length in microseconds as an exact
    /// integer-plus-remainder, the segment walk, and the one division
    /// that floors.
    fn exactFloor(
        self: *const TimeMap,
        rate: FrameRate,
        parts: FrameParts,
        anchor: i64,
    ) Error!ExactLanding {
        const a_seg = self.segments[self.segmentOfTick(anchor)];
        const anchor_us: i128 = @intFromFloat(a_seg.us);
        const anchor_num = a_seg.t_i +
            @as(i128, anchor - a_seg.tick) * anchor_us;

        // The literal's length in MICROSECONDS: `r = p · den · TICK_US
        // / (num · 2^shift)`, split into its integer part and the
        // remainder over its own denominator, so the floor below is
        // two exact divisions and never a common-denominator product.
        const r_num = parts.p * @as(i128, rate.den) * TICK_US_I;
        // Tiny, judged exactly: an instant strictly inside the
        // anchor's own tick floors to the anchor from ANY segment —
        // it stays before the next segment's origin too (`us_a` more
        // units away at least) — so the walk below is skipped whole.
        if (frameTiny(rate, parts, r_num, anchor_us)) {
            return .{ .tick = anchor, .exact = false };
        }
        const r_den = @as(i128, rate.num) << @intCast(parts.shift);
        const r_int = @divFloor(r_num, r_den);
        const r_rem = r_num - r_int * r_den;

        // The segment the instant lands in: the last one whose start
        // is at or before it — `segmentOfSeconds`' walk, judged
        // exactly. `start ≤ instant` cross-multiplies to
        // `(anchor_num − t_i) · r_den + r_num ≥ 0`, and the product is
        // checked: an overflowed positive difference is certainly ≥ 0
        // and an overflowed negative one certainly is not, so even a
        // map past the envelope answers rather than wraps.
        var i: usize = self.segments.len - 1;
        while (i > 0) : (i -= 1) {
            const d = anchor_num - self.segments[i].t_i;
            const dt, const ov = @mulWithOverflow(d, r_den);
            // `dt + r_num ≥ 0` without the sum, which could itself
            // wrap when `dt` sits just under `2^127`: `r_num > 0`, so
            // a non-negative `dt` needs no sum at all, and a negative
            // one crosses zero exactly at `-r_num` — sign-identical
            // to the intent, with every operand a legal `i128`.
            const reached = if (ov != 0) d > 0 else if (dt >= 0) true else dt >= -r_num;
            if (reached) break;
        }
        const seg = self.segments[i];
        const us: i128 = @intFromFloat(seg.us);

        // The floor: `anchor_num − t_i + r_int` microseconds into the
        // segment, over `us` per tick. The fraction `r_rem / r_den` is
        // under one whole microsecond-count division away (it is under
        // one `us`, which is a whole number ≥ 1), so this quotient IS
        // the floor of the whole instant — and the two remainders
        // together ARE the exactness verdict: the instant is the tick
        // it landed on exactly when both are zero.
        const whole = (anchor_num - seg.t_i) + r_int;
        std.debug.assert(whole >= 0); // the segment chosen starts at or before the instant
        const k = @divFloor(whole, us);
        const rem = whole - k * us;
        const into = std.math.cast(i64, k) orelse return Error.TickOverflow;
        const tick = seg.tick + into;
        if (tick > Grid.MAX_TICK) return Error.TickOverflow;
        return .{ .tick = tick, .exact = rem == 0 and r_rem == 0 };
    }

    /// The frame seam: frame `n`'s instant, floored at the one clock,
    /// with the floor read back — `exact` iff `secondsFromTick(tick)`
    /// returns the instant bit for bit, which is the whole of
    /// "off-grid": a frame's instant either is a tick start or is not.
    fn frameTick(self: *const TimeMap, rate: FrameRate, n: f64) Error!struct {
        tick: i64,
        exact: bool,
    } {
        const secs = frameSeconds(rate, n);
        const tick = try self.tickFromSeconds(secs);
        return .{ .tick = tick, .exact = self.secondsFromTick(tick) == secs };
    }

    /// The frame-line test — `Pos.spell`'s read-back discipline made
    /// policy: `tick` is on a frame line of the map's declared rate
    /// exactly when the frame its own seconds nominate
    /// (`n = @round(secondsFromTick(tick) · num / den)`) resolves back
    /// to `tick` itself, exact. Anything else — no declared rate, a
    /// nomination that misses, a floor that was not exact — answers
    /// null, so a spelling that would not round-trip falls through to
    /// the bar / quarter / tick spellings rather than lie. The
    /// `isBarLine` twin, and the INTEGER statement of the discipline:
    /// `writableFrame` below is its decimal twin, the one the printer
    /// reads, extended to a frame's fractions.
    ///
    /// On an integral map the statement is integer arithmetic outright
    /// (`exactFrameValue`): a tick is on a frame line exactly when the
    /// tick's own numerator times the rate's numerator divides
    /// `TICK_US` times the denominator, and the frame is the quotient —
    /// no nomination to miss. The f64 path keeps the float nomination.
    pub fn frameLine(self: *const TimeMap, tick: i64) ?i64 {
        const frames = self.frames orelse return null;
        if (self.exactMap()) {
            // The integer statement: a tick is on a frame line exactly
            // when the reduced frame value is a whole number. Its null
            // is an answer — no frame line — never a case for the float
            // nomination below, which an exact map must not consult.
            const value = self.exactFrameValue(frames.rate, tick) orelse return null;
            const whole = @trunc(value);
            if (whole != value or whole > 9_007_199_254_740_992.0) return null;
            return @intFromFloat(whole);
        }
        const num: f64 = @floatFromInt(frames.rate.num);
        const den: f64 = @floatFromInt(frames.rate.den);
        // The nomination is capped where its double could not name a
        // tick of this grid again, and a non-finite seconds (a
        // near-zero rate) nominates nothing.
        const nominated = @round(self.secondsFromTick(tick) * num / den);
        if (!(nominated >= 0 and nominated <= 9_007_199_254_740_992.0)) return null;
        const landed = self.frameTick(frames.rate, nominated) catch return null;
        if (!landed.exact or landed.tick != tick) return null;
        return @intFromFloat(nominated);
    }

    /// Whether this map's frame questions are answered by the exact
    /// integer path: every segment whole (the map is `integral`) and
    /// inside `EXACT_US_MAX`'s envelope. The f64 tempo path is the one
    /// map shape that answers no.
    fn exactMap(self: *const TimeMap) bool {
        if (!self.integral) return false;
        for (self.segments) |s| if (s.us > EXACT_US_MAX) return false;
        return true;
    }

    /// The frame a tick sits at, as this map's INTEGRAL arithmetic
    /// spells it: `A · num / (TICK_US · den)` over the tick's own
    /// segment, reduced — or null when the value is not a whole number
    /// of frames, is past 2^53 (where f64 stops being integer-exact, so
    /// no decimal could name the tick back), or has no decimal an f64
    /// holds bit for bit. Called only on an `exactMap` map.
    fn exactFrameValue(self: *const TimeMap, rate: FrameRate, tick: i64) ?f64 {
        // A position is never negative (plan 03), and this map's first
        // segment starts at tick 0, so a tick at or after 0 has a
        // numerator at or after 0 — anything else is no frame's.
        if (tick < 0) return null;
        const seg = self.segments[self.segmentOfTick(tick)];
        const top: u128 = @intCast((seg.t_i +
            @as(i128, tick - seg.tick) * @as(i128, @intFromFloat(seg.us))) * rate.num);
        const bottom: u128 = @intCast(TICK_US_I * rate.den);
        const g: u128 = std.math.gcd(top, bottom);
        const n = @divExact(top, g);
        const d = @divExact(bottom, g);
        // A spelling the printer could emit and read back BIT FOR BIT:
        // the reduced denominator a power of two and the numerator's
        // own significant bits within f64's 53 — else no decimal names
        // this frame exactly. (Tick 0 is frame 0: the empty numerator
        // divides everything.)
        if (d != 1 and (d & (d - 1)) != 0) return null;
        if (n == 0) return 0;
        const odd = n >> @intCast(@ctz(n));
        if (odd > (@as(u128, 1) << 53)) return null;
        const value = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d));
        // IEEE division is exact whenever the quotient is
        // representable, and both operands above are, so this is the
        // frame itself or nothing the caller may spell.
        if (!(value >= 0 and value <= 9_007_199_254_740_992.0)) return null;
        return value;
    }

    /// The frame a tick's seconds name, as the printer may spell it —
    /// `frameLine`'s DECIMAL twin, for a document that WROTE an `f`
    /// position (the printer's per-document rule: a rate alone changes
    /// no spelling). `secondsFromTick(tick) · num / den` names the
    /// frame — an integer, or a fraction, because `f` is a decimal unit
    /// like `q` — and the naming is an answer only when it resolves
    /// EXACTLY back to `tick` through the frame seam, `Pos.spell`'s
    /// read-back discipline: a spelling that would not round-trip falls
    /// through rather than lie. Null when the document wrote no frames,
    /// the map holds no rate, the nomination misses, or a floor was not
    /// exact.
    ///
    /// On an integral map the read-back is the integer statement above
    /// (`exactFrameValue`): the printed decimal must resolve to the
    /// tick EXACTLY, not to within a float collision — a tick between
    /// frames has no `f` spelling at all under this rule, where the
    /// float nomination once printed the long decimal that happened to
    /// land back inside one ulp. The f64 path keeps that nomination.
    fn writableFrame(self: *const TimeMap, tick: i64) ?f64 {
        const frames = self.frames orelse return null;
        if (!frames.wrote) return null;
        if (self.exactMap()) {
            // The integer read-back: the exact frame value, or no
            // spelling. Its null is an answer — this tick has no `f`
            // spelling that reads back exactly — never a case for the
            // float nomination below, whose long decimals are "exact"
            // only where two float chains collide.
            return self.exactFrameValue(frames.rate, tick);
        }
        const num: f64 = @floatFromInt(frames.rate.num);
        const den: f64 = @floatFromInt(frames.rate.den);
        // The nomination is capped where its decimal could not name a
        // tick of this grid again, and a non-finite seconds (a near-zero
        // rate) nominates nothing.
        const named = self.secondsFromTick(tick) * num / den;
        if (!(named >= 0 and named <= 9_007_199_254_740_992.0)) return null;
        const landed = self.frameTick(frames.rate, named) catch return null;
        if (!landed.exact or landed.tick != tick) return null;
        return named;
    }

    /// One frame value as the printer spells it — `toSjon`'s own number
    /// rule, so `20f` and `2.5f` are the spellings: an integral frame
    /// prints as the integer it is, everything else takes the shortest
    /// decimal that reads back as the same float.
    fn writeFrame(writer: anytype, frame: f64) !void {
        const exact_int_max: f64 = @floatFromInt(@as(i64, 1) << 53);
        if (@floor(frame) == frame and frame < exact_int_max) {
            return writer.print("{d}f", .{@as(i64, @intFromFloat(frame))});
        }
        return writer.print("{d}f", .{frame});
    }

    /// The last segment starting at or before `tick`; segment 0 extends
    /// backward. A linear scan, deterministic, over at most
    /// `MAX_TEMPO_SEGMENTS` entries (plan 03).
    fn segmentOfTick(self: *const TimeMap, tick: i64) usize {
        // `derive` always leaves a segment at tick 0 (the map's own
        // invariant, not the document's).
        std.debug.assert(self.segments.len > 0);
        var i: usize = self.segments.len - 1;
        while (i > 0) : (i -= 1) {
            if (self.segments[i].tick <= tick) return i;
        }
        return 0;
    }

    /// The seconds-domain twin.
    fn segmentOfSeconds(self: *const TimeMap, seconds: f64) usize {
        std.debug.assert(self.segments.len > 0);
        var i: usize = self.segments.len - 1;
        while (i > 0) : (i -= 1) {
            if (self.segments[i].start_sec <= seconds) return i;
        }
        return 0;
    }

    /// The end behaviour, in SECONDS and before any conversion (plan 03,
    /// pacer's mapped-score rule): `loop` wraps into `[0, loop_secs)`,
    /// `hold` clamps at `seconds(length)`. `Playhead.at` is the only
    /// caller; `evalTicks`-style callers pass ticks and wrap ticks.
    ///
    /// Wrapping TICKS instead would replay iteration 2 at the final
    /// segment's tempo — the bug the ordering exists to prevent.
    ///
    /// A `loop` needs a positive length to wrap into — `@mod` by zero is
    /// a NaN, and a NaN is no answer for a playhead — so a map without
    /// one passes the seconds through. A `hold` clamps at whatever the
    /// length is, including zero; only a non-finite loop point (which
    /// nothing finite can be compared against) passes through.
    pub fn wrapSeconds(self: *const TimeMap, seconds: f64) f64 {
        if (!std.math.isFinite(self.loop_secs)) return seconds;
        return switch (self.end) {
            .loop => if (self.loop_secs > 0) @mod(seconds, self.loop_secs) else seconds,
            .hold => @min(seconds, self.loop_secs),
        };
    }

    /// Where a tick sits: the bar, the beat in it, the ticks into that
    /// beat, and the meter in force. A negative tick is read as tick 0 (a
    /// position is never negative, plan 03). Past the bar table the last
    /// meter CARRIES ON — a bar is a bar whether or not `:length` reached
    /// it, and a document's positions are resolved while its default
    /// length is still being computed.
    pub fn barOf(self: *const TimeMap, tick: i64) struct {
        bar: i64,
        beat: i64,
        sub_ticks: i64,
        meter: MeterSeg,
    } {
        const t = @max(tick, 0);
        const bar = self.barAt(t);
        const seg = self.meters[self.meterOfBar(bar)];
        const beat_len = Grid.beatTicks(seg.d);
        // The start is at or before `t` by construction, so it fits.
        const rem = t - @as(i64, @intCast(self.barStartRaw(bar)));
        return .{
            .bar = bar,
            .beat = @divFloor(rem, beat_len),
            .sub_ticks = @rem(rem, beat_len),
            .meter = seg,
        };
    }

    /// Where bar `bar` starts according to the TABLE, or `null` when the
    /// table does not hold it. The table runs to `:length`, and one bar
    /// start past it when `:length` falls mid-bar — so the last entry is
    /// the first bar line at or after the end. `tickFromLiteral` and
    /// `barOf` read further than this, through the meter map.
    pub fn barStart(self: *const TimeMap, bar: i64) ?i64 {
        if (bar < 0 or bar >= self.bars.len) return null;
        return self.bars[@intCast(bar)];
    }

    /// The bar NUMBER when `tick` is a bar line, else `null` — the
    /// question `Pos.spell` asks before it prints `Nbar`.
    ///
    /// A bar line past the bar table is still a bar line: this reads the
    /// meter map exactly as `tickFromLiteral(.bar)` writes it, so
    /// `7bar` on a six-bar timeline spells back as `7bar`.
    pub fn isBarLine(self: *const TimeMap, tick: i64) ?i64 {
        if (tick < 0) return null;
        const bar = self.barAt(tick);
        return if (self.barStartRaw(bar) == tick) bar else null;
    }

    /// The bar `tick` falls in, from the table while the table reaches
    /// and past it from the meter in force. `tick >= 0`.
    fn barAt(self: *const TimeMap, tick: i64) i64 {
        std.debug.assert(self.bars.len > 0);
        if (tick <= self.bars[self.bars.len - 1]) return self.barIndex(tick);
        const seg = self.meters[self.meterOfTick(tick)];
        return seg.first_bar + @divFloor(tick - seg.tick, Grid.barTicks(seg.n, seg.d));
    }

    /// Resolve a position literal against the maps — all six units of
    /// plan 03, "Positions".
    ///
    /// `q` and `t` are the grid's own and go through `Pos`; `bar` and `b`
    /// are counted from 0 through the meter map, their fraction scaled by
    /// the bar's or the beat's length IN QUARTERS and rounded by the one
    /// shared half-to-even seam, `Pos.tickFromQuarters`; `s` and `f` go
    /// through the tempo map's clock floor — `f` at the document's
    /// declared `:fps` rate, and `frame_rate_missing` on a map that holds
    /// none. A negative position is `position_negative`, and the grid
    /// ceiling is `tick_overflow` — a document's mistakes are diagnostics.
    /// The one ERROR is a literal that is not a number at all (a NaN or
    /// an infinity), which no document can spell and no map can answer.
    ///
    /// A `bar` or `b` past `:length` still answers: the last meter
    /// carries on past the bar table, because a position may name a bar
    /// the timeline does not reach.
    pub fn tickFromLiteral(self: *const TimeMap, lit: Pos.Literal) Error!LiteralTick {
        if (!std.math.isFinite(lit.value)) return error.NonFiniteTime;
        if (lit.value < 0) return .{ .err = .position_negative };
        const ceiling: f64 = @floatFromInt(Grid.MAX_TICK);

        switch (lit.unit) {
            .q, .t => return switch (Pos.tickFromLiteral(lit)) {
                .tick => |t| .{ .tick = t },
                .err => |c| .{ .err = c },
                // `q` and `t` are exactly the units the grid answers on
                // its own; `Pos` never asks a map about them.
                .needs_map => unreachable,
            },
            .s, .f => return self.clockTick(lit),
            .bar => {
                const whole = @trunc(lit.value);
                if (whole > ceiling) return .{ .err = .tick_overflow };
                const bar: i64 = @intFromFloat(whole);
                const seg = self.meters[self.meterOfBar(bar)];
                const start = self.barStartOf(bar) catch return .{ .err = .tick_overflow };
                // A bar of `[n d]` is 4n/d quarters — exact in f64 for
                // every meter the map holds (`d` is a power of two).
                const bar_quarters = 4.0 * @as(
                    f64,
                    @floatFromInt(seg.n),
                ) / @as(f64, @floatFromInt(seg.d));
                const into = Pos.tickFromQuarters((lit.value - whole) * bar_quarters) catch
                    return .{ .err = .tick_overflow };
                return .{
                    .tick = capped(@as(i128, start) + into) catch return .{ .err = .tick_overflow },
                };
            },
            .b => {
                const whole = @trunc(lit.value);
                if (whole > ceiling) return .{ .err = .tick_overflow };
                const beat: i64 = @intFromFloat(whole);
                const seg = self.meters[self.meterOfBeat(beat)];
                // The meter table carries the cumulative beat count at
                // each segment's first bar, so the integer part names bar
                // `m` and beat `k` inside it directly.
                const delta = beat - seg.beats_before;
                const n: i64 = seg.n;
                const start = self.barStartOf(seg.first_bar + @divFloor(delta, n)) catch
                    return .{ .err = .tick_overflow };
                const beat_start = @as(
                    i128,
                    start,
                ) + @as(i128, @mod(delta, n)) * Grid.beatTicks(seg.d);
                // A beat of `[n d]` is 4/d quarters.
                const beat_quarters = 4.0 / @as(f64, @floatFromInt(seg.d));
                const into = Pos.tickFromQuarters((lit.value - whole) * beat_quarters) catch
                    return .{ .err = .tick_overflow };
                return .{
                    .tick = capped(beat_start + into) catch return .{ .err = .tick_overflow },
                };
            },
        }
    }

    /// The two CLOCK units' arm of `tickFromLiteral`, apart so the parent
    /// stays the parent: `s` straight through the one clock floor, and
    /// `f` at the document's declared rate through the same floor —
    /// `frame_rate_missing` when the map holds none (no default rate
    /// exists to guess with), and the seam read back for exactness when
    /// it does. The only rounding either takes is the clock floor every
    /// clock value already takes: a frame never round-to-nearests and
    /// never wraps, and an instant that is not a tick start is `inexact`
    /// — the floored tick, said.
    ///
    /// On an integral map the `f` arm takes `exactLanding`: the same
    /// floor and read-back in exact integers, because the f64 chain can
    /// round an exact frame's instant one tick short (fl(1.4) seconds is
    /// BELOW 1.4, and the floor of the product can land there) and can
    /// read a between-frames instant back as "exact" when the two floats
    /// collide. The f64 tempo path keeps the float seam below, which is
    /// deterministic and nothing more — its declared limit.
    fn clockTick(self: *const TimeMap, lit: Pos.Literal) Error!LiteralTick {
        const rate = switch (lit.unit) {
            .s => null,
            .f => if (self.frames) |frames| frames.rate else return .{
                .err = .frame_rate_missing,
            },
            else => unreachable, // the parent sends only the clock units
        };
        if (lit.unit == .f) {
            if (self.exactLanding(rate.?, lit.value, 0)) |answer| {
                const landed = answer catch |e| switch (e) {
                    error.TickOverflow => return .{ .err = .tick_overflow },
                    error.NonFiniteTime => return e,
                };
                return if (landed.exact) .{ .tick = landed.tick } else .{ .inexact = landed.tick };
            }
        }
        const secs = switch (lit.unit) {
            .s => lit.value,
            .f => frameSeconds(rate.?, lit.value),
            else => unreachable,
        };
        const tick = self.tickFromSeconds(secs) catch |e| switch (e) {
            error.TickOverflow => return .{ .err = .tick_overflow },
            error.NonFiniteTime => return e,
        };
        if (lit.unit == .s) return .{ .tick = tick };
        // The frame seam read back, bit for bit: the frame's instant is
        // this tick's seconds exactly, or the floor stands and is said.
        if (self.secondsFromTick(tick) == secs) return .{ .tick = tick };
        return .{ .inexact = tick };
    }

    /// A DURATION literal — `:dur`, `:offset`, a clip's `:length` —
    /// measured from the form's own `:at` (plan 03, "Positions":
    /// "Durations are positions measured from the form's own `:at`").
    ///
    /// The difference from `tickFromLiteral` is only ever visible across
    /// a meter change: under one meter `1bar` is one bar's worth of
    /// ticks wherever it starts, and this returns exactly that, bit for
    /// bit. At a `[3 4]` → `[4 4]` change on bar 2, `:at 2bar :dur 1bar`
    /// is the fourth bar's FOUR quarters and not the first three's three.
    ///
    ///   * `q` and `t` are grid units and carry no anchor at all;
    ///   * `bar` lands on `barAt(at) + k` and answers the distance to it,
    ///     the fraction scaled by the LANDING bar's length;
    ///   * `b` is the beat twin, over the cumulative beat count;
    ///   * `s` is wall-clock from `at`, through the one clock seam;
    ///   * `f` is the frame twin of `s`: wall-clock from `at`, at the
    ///     document's declared rate, with the landing read back for
    ///     exactness (`inexact` when the frame's instant is no tick
    ///     start, `frame_rate_missing` on a map that holds no rate).
    ///
    /// Both roundings stay where plan 03 put them: a fraction goes
    /// through `Pos.tickFromQuarters` (half to even) and seconds through
    /// `tickFromSeconds` (floor).
    ///
    /// A duration is never negative. Two spellings could ask for one — a
    /// whole-bar or whole-beat count from an anchor that sits INSIDE a
    /// bar, whose landing line is therefore behind it, and a seconds
    /// count so small that the clock floor of `seconds(at)` lands a tick
    /// short of `at` itself (the header's ulp) — and both are answered
    /// as 0 rather than as a distance backwards.
    pub fn durationTicks(self: *const TimeMap, lit: Pos.Literal, at: i64) Error!Resolved {
        const answer = try self.resolveDuration(lit, at);
        switch (answer) {
            // Never a distance backwards, and never past the ceiling —
            // an inexact landing no less than an exact one.
            .tick, .inexact => |t| {
                std.debug.assert(t >= 0);
                std.debug.assert(t <= Grid.MAX_TICK);
            },
            // Only the codes a position can earn — `frame_rate_missing`
            // too, an `f` duration on a map with no declared rate.
            .err => |code| std.debug.assert(code == .position_negative or
                code == .position_not_integer or code == .tick_overflow or
                code == .frame_rate_missing),
        }
        return answer;
    }

    /// `durationTicks`'s answer, unit by unit; the public door asserts
    /// the contract of what it hands back.
    fn resolveDuration(self: *const TimeMap, lit: Pos.Literal, at: i64) Error!Resolved {
        if (!std.math.isFinite(lit.value)) return error.NonFiniteTime;
        if (lit.value < 0) return .{ .err = .position_negative };
        const anchor = @max(at, 0);
        const ceiling: f64 = @floatFromInt(Grid.MAX_TICK);

        switch (lit.unit) {
            // Grid units: a quarter is a quarter wherever it starts, so
            // there is nothing for an anchor to change.
            .q, .t => return switch (try self.tickFromLiteral(lit)) {
                .tick => |t| .{ .tick = t },
                // Only the clock units answer inexact; on the grid this
                // is the tick it already was.
                .inexact => |t| .{ .tick = t },
                .err => |c| .{ .err = c },
            },
            .s => {
                const abs = self.tickFromSeconds(
                    self.secondsFromTick(anchor) + lit.value,
                ) catch |e| switch (e) {
                    error.TickOverflow => return .{ .err = .tick_overflow },
                    error.NonFiniteTime => return e,
                };
                return .{ .tick = @max(0, abs - anchor) };
            },
            .f => return self.frameDuration(lit, anchor),
            .bar => {
                const whole = @trunc(lit.value);
                if (whole > ceiling) return .{ .err = .tick_overflow };
                const landing = self.barAt(anchor) + @as(i64, @intFromFloat(whole));
                const start = self.barStartRaw(landing);
                const seg = self.meters[self.meterOfBar(landing)];
                // A bar of `[n d]` is 4n/d quarters — exact in f64 for
                // every meter the map holds (`d` is a power of two).
                const bar_quarters = 4.0 * @as(
                    f64,
                    @floatFromInt(seg.n),
                ) / @as(f64, @floatFromInt(seg.d));
                const into = Pos.tickFromQuarters((lit.value - whole) * bar_quarters) catch
                    return .{ .err = .tick_overflow };
                return .{
                    .tick = capped(
                        @max(0, start + into - anchor),
                    ) catch return .{ .err = .tick_overflow },
                };
            },
            .b => {
                const whole = @trunc(lit.value);
                if (whole > ceiling) return .{ .err = .tick_overflow };
                const landing = self.beatAt(anchor) + @as(i64, @intFromFloat(whole));
                const start = self.beatStartRaw(landing);
                const seg = self.meters[self.meterOfBeat(landing)];
                // A beat of `[n d]` is 4/d quarters.
                const beat_quarters = 4.0 / @as(f64, @floatFromInt(seg.d));
                const into = Pos.tickFromQuarters((lit.value - whole) * beat_quarters) catch
                    return .{ .err = .tick_overflow };
                return .{
                    .tick = capped(
                        @max(0, start + into - anchor),
                    ) catch return .{ .err = .tick_overflow },
                };
            },
        }
    }

    /// The `f` arm of `resolveDuration`, apart so the parent stays the
    /// parent: the `s` arm's shape with a frame instant in place of the
    /// seconds count — wall-clock from the anchor, at the document's
    /// declared rate, through the one clock seam, with the landing read
    /// back for exactness exactly as `clockTick` reads a position.
    ///
    /// On an integral map that read-back is `exactLanding`'s integer
    /// judgment: the asked instant is the anchor's own exact numerator
    /// plus `n · den / num`, and comparing float associations of it (a
    /// three-rounded sum against a one-rounded division) calls truly
    /// exact frames inexact — `:at 20f :dur 1f` at `:fps 25`/`:qpm 300`
    /// is 21/25 s, tick 19 37 29 536 exactly, and the float chain
    /// said `frame_inexact`. The f64 tempo path keeps the float chain.
    fn frameDuration(self: *const TimeMap, lit: Pos.Literal, anchor: i64) Error!Resolved {
        const rate = (self.frames orelse return .{
            .err = .frame_rate_missing,
        }).rate;
        if (self.exactLanding(rate, lit.value, anchor)) |answer| {
            const landed = answer catch |e| switch (e) {
                error.TickOverflow => return .{ .err = .tick_overflow },
                error.NonFiniteTime => return e,
            };
            // Never a distance backwards: the instant is at or after
            // the anchor's own, so its floor is at or after the anchor.
            const d = landed.tick - anchor;
            std.debug.assert(d >= 0);
            return if (landed.exact) .{ .tick = d } else .{ .inexact = d };
        }
        const want = self.secondsFromTick(anchor) + frameSeconds(rate, lit.value);
        const abs = self.tickFromSeconds(want) catch |e| switch (e) {
            error.TickOverflow => return .{ .err = .tick_overflow },
            error.NonFiniteTime => return e,
        };
        const d = @max(0, abs - anchor);
        // Exact iff the asked instant is the tick it landed on; the
        // floored distance stands otherwise, never a wrap.
        if (self.secondsFromTick(anchor + d) == want) return .{ .tick = d };
        return .{ .inexact = d };
    }

    /// The canonical spelling of a DURATION measured from `at`.
    ///
    /// `Nbar` when BOTH ends sit on bar lines — the honest count of bars
    /// between them, whatever meters they cross — and otherwise the
    /// delta's own `Nq` / `Nt` by `Pos.spell`'s rule. That is exactly the
    /// set of spellings `durationTicks` inverts: a `bar` duration read
    /// back from a bar-line anchor lands on the same tick, and a `q` or a
    /// `t` one carries no anchor at all. The property
    /// `durationTicks(parse(spellDuration(d, at)), at) == d` is pinned by
    /// the test below, across a meter change.
    ///
    /// In a document that WROTE an `f` position there is one earlier
    /// branch, the `Nbar` rule's shape at the document's own rate: `Nf`
    /// when both ends sit on FRAME lines — the honest count of frames
    /// between them, whatever tempos they cross, read back exactly or
    /// not at all.
    pub fn spellDuration(self: *const TimeMap, writer: anytype, dur: i64, at: i64) !void {
        if (dur >= 0 and at >= 0) {
            if (self.frameSpan(dur, at)) |frames| return writeFrame(writer, frames);
            if (self.isBarLine(at)) |from| {
                const end = at +| dur;
                if (self.isBarLine(end)) |to| {
                    // The later line is never earlier in the count: bar
                    // numbers rise with the tick, past the table too.
                    std.debug.assert(to >= from);
                    return writer.print("{d}bar", .{to - from});
                }
            }
        }
        return Pos.spell(writer, dur, null);
    }

    /// The frame count of a duration whose BOTH ends are frame lines —
    /// `spellDuration`'s `f` branch, the `Nbar` rule's shape at the
    /// document's declared rate — or null when it is no answer: either
    /// end is not a frame line, or the count itself does not resolve
    /// back exactly, so the spelling falls through to the bar / quarter
    /// / tick spellings rather than lie.
    ///
    /// On an integral map the count's own read-back is the integer
    /// judgment (`exactLanding` from the anchor): the float sum below
    /// compares three roundings against one and drops exact spans —
    /// one frame from `20f` at `:fps 25`/`:qpm 300` printed as `q`
    /// rather than the `1f` both ends are. The f64 path keeps the sum.
    fn frameSpan(self: *const TimeMap, dur: i64, at: i64) ?f64 {
        const from = self.writableFrame(at) orelse return null;
        const end = at +| dur;
        const to = self.writableFrame(end) orelse return null;
        // `writableFrame` answered, so the map holds the rate.
        const rate = self.frames.?.rate;
        if (self.exactLanding(rate, to - from, at)) |answer| {
            // The count's instant from `at` is `end`'s own, or this is
            // no answer: the spelling falls through rather than lie.
            const landed = answer catch return null;
            if (!landed.exact or landed.tick != end) return null;
            return to - from;
        }
        const want = self.secondsFromTick(at) + frameSeconds(rate, to - from);
        if (self.secondsFromTick(end) != want) return null;
        return to - from;
    }

    /// The canonical text of the map: one line per tempo segment, one
    /// per meter segment, then the bar table's shape and the length.
    ///
    /// Every float is its 16-hex-digit BIT PATTERN (pacer's corpus
    /// idiom), because this text is what the golden corpus pins and a
    /// decimal spelling would hide the last bit — the one place the two
    /// paths and the two hosts could ever disagree. `:us` is the
    /// authored-looking number beside it, and `:tps` re-derives from it.
    pub fn echo(self: *const TimeMap, writer: anytype) !void {
        for (self.segments) |s| {
            try writer.print(
                "(segment :tick {d} :us {d} :tps \"{X:0>16}\" :start-sec \"{X:0>16}\")\n",
                .{ s.tick, s.us, bits(s.tps), bits(s.start_sec) },
            );
        }
        for (self.meters) |m| {
            try writer.print(
                "(meter :tick {d} :sig [{d} {d}] :first-bar {d})\n",
                .{ m.tick, m.n, m.d, m.first_bar },
            );
        }
        try writer.print(
            "(bars :count {d} :last-start {d})\n",
            .{ self.bars.len, if (self.bars.len == 0) 0 else self.bars[self.bars.len - 1] },
        );
        try writer.print(
            "(length :tick {d} :end {s} :loop-secs \"{X:0>16}\")\n",
            .{ self.length, @tagName(self.end), bits(self.loop_secs) },
        );
    }

    /// The canonical spelling of a tick (plan 03, "The printer's rule"),
    /// which is `Pos.spell`'s — this map only answers the one question
    /// `Pos` owns no table for: is that tick a bar line, and which bar?
    /// In a document that WROTE an `f` position there is one earlier
    /// question still: is that tick a frame line, and which frame — `Nf`
    /// ahead of `Nbar`, ahead of `Nq`, ahead of `Nt`, so a document that
    /// wrote frames reads in frames. A document that declared a rate and
    /// wrote none takes no branch here at all.
    pub fn spell(self: *const TimeMap, writer: anytype, tick: i64) !void {
        if (self.writableFrame(tick)) |frame| return writeFrame(writer, frame);
        return self.spellGrid(writer, tick);
    }

    /// `spell` with the `f` branch withheld: the spelling for the forms
    /// whose `:at` is a `grid-position` (plan 03's `tempo-point` and
    /// `meter-point`), which refuse the frame unit as they refuse `s` —
    /// a frame is counted through the tempo map, and these forms are
    /// the map. A dump that spelled one of their positions in frames
    /// would not reload, so the map's own points print `Nbar` / `Nq` /
    /// `Nt` whatever the document wrote.
    pub fn spellGrid(self: *const TimeMap, writer: anytype, tick: i64) !void {
        const bar_line = self.isBarLine(tick);
        if (bar_line) |bar| {
            // A bar line is only ever found at or after tick 0, and bars
            // count from 0.
            std.debug.assert(tick >= 0);
            std.debug.assert(bar >= 0);
        }
        return Pos.spell(writer, tick, bar_line);
    }

    /// Where bar `bar` starts, whether or not the table reaches it: past
    /// `:length` the meter in force carries on. Checked against the grid
    /// ceiling, for the callers that derived `bar` from a LITERAL.
    fn barStartOf(self: *const TimeMap, bar: i64) Error!i64 {
        return capped(self.barStartRaw(bar));
    }

    /// The same answer in `i128`, for the callers that derived `bar` from
    /// a tick they already hold — the start is then at or before that
    /// tick and needs no ceiling of its own.
    fn barStartRaw(self: *const TimeMap, bar: i64) i128 {
        if (bar >= 0 and bar < @as(i64, @intCast(self.bars.len))) return self.bars[@intCast(bar)];
        const seg = self.meters[self.meterOfBar(bar)];
        return @as(i128, seg.tick) +
            @as(i128, bar - seg.first_bar) * Grid.barTicks(seg.n, seg.d);
    }

    /// The beat `tick` falls in, counted from 0 across the meter map —
    /// the `b` twin of `barAt`, and exact past the bar table because the
    /// meter in force carries on.
    fn beatAt(self: *const TimeMap, tick: i64) i64 {
        const t = @max(tick, 0);
        const seg = self.meters[self.meterOfTick(t)];
        return seg.beats_before + @divFloor(t - seg.tick, Grid.beatTicks(seg.d));
    }

    /// Where beat `beat` starts, in `i128` — the `b` twin of
    /// `barStartRaw`: the meter table carries the cumulative beat count
    /// at each segment's first bar, so the count names bar `m` and beat
    /// `k` inside it directly.
    fn beatStartRaw(self: *const TimeMap, beat: i64) i128 {
        const seg = self.meters[self.meterOfBeat(beat)];
        const delta = beat - seg.beats_before;
        const n: i64 = seg.n;
        return self.barStartRaw(seg.first_bar + @divFloor(delta, n)) +
            @as(i128, @mod(delta, n)) * Grid.beatTicks(seg.d);
    }

    /// The last meter segment starting at or before `tick` — the
    /// tick-domain twin of `meterOfBar`, for reading past the table.
    fn meterOfTick(self: *const TimeMap, tick: i64) usize {
        std.debug.assert(self.meters.len > 0);
        var i: usize = self.meters.len - 1;
        while (i > 0) : (i -= 1) {
            if (self.meters[i].tick <= tick) return i;
        }
        return 0;
    }

    /// The grid ceiling, checked while the value is still `i128`.
    fn capped(tick: i128) Error!i64 {
        if (tick > Grid.MAX_TICK) return error.TickOverflow;
        return @intCast(tick);
    }

    /// The last meter segment whose cumulative beat count is at or before
    /// `beat` — the `b` unit's twin of `meterOfBar`.
    fn meterOfBeat(self: *const TimeMap, beat: i64) usize {
        std.debug.assert(self.meters.len > 0);
        var i: usize = self.meters.len - 1;
        while (i > 0) : (i -= 1) {
            if (self.meters[i].beats_before <= beat) return i;
        }
        return 0;
    }

    /// The last bar starting at or before `tick` (`tick >= 0`), by binary
    /// search. `bars[0]` is 0 and the table is never empty, so the search
    /// always has an answer.
    fn barIndex(self: *const TimeMap, tick: i64) i64 {
        std.debug.assert(self.bars.len > 0 and self.bars[0] == 0);
        var lo: usize = 0;
        var hi: usize = self.bars.len;
        // Invariant: bars[lo] <= tick, and hi is past the answer.
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.bars[mid] <= tick) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// The last meter segment whose first bar is at or before `bar`.
    fn meterOfBar(self: *const TimeMap, bar: i64) usize {
        std.debug.assert(self.meters.len > 0);
        var i: usize = self.meters.len - 1;
        while (i > 0) : (i -= 1) {
            if (self.meters[i].first_bar <= bar) return i;
        }
        return 0;
    }
};

/// What `derive` returns: the map and the report.
pub const Result = struct {
    map: TimeMap,
    diags: Diag.List,

    /// Frees both; a caller that keeps the map takes it out and frees
    /// the report alone.
    pub fn deinit(self: *Result) void {
        self.map.deinit();
        self.diags.deinit();
    }
};

/// `TPQ · 1e6`: ticks times microseconds per second, the numerator of
/// both paths. The product is exact in f64 (46 126 080 000 000 is well
/// under 2^53), so folding it at comptime is bit-for-bit the `TPQ · 1e6`
/// of plan 03's `tps_i = (TPQ · 1e6) / us_i`.
const TICK_US: f64 = @as(f64, @floatFromInt(Grid.TPQ)) * 1e6;

/// Microseconds per quarter note per minute: `us = 60e6 / qpm`, and
/// `qpm = 60e6 / us` read back (`export/tempo.zig`).
pub const US_PER_MINUTE: f64 = 60_000_000;

/// What a map with no usable point at tick 0 is given. 120 quarter notes
/// per minute is SMF's own default (`us = 500 000`, an INTEGER, so the
/// fallback never forces the f64 path on a document that says `:us`).
const DEFAULT_US: f64 = 500_000;

/// The widest `us` the integer path admits, exclusive. Its origins are
/// `Σ Δtick_j · us_j` in i128 and a query forms `(tick − tick_i) · us_i`
/// the same way over any `i64` tick a host hands it; with every `us`
/// below 2^63 and every tick inside `i64`, both products stay under
/// 2^126. A whole number of microseconds at or above it — a `:qpm` under
/// 6.6e-12, which the schema refuses and the reader keeps — is still a
/// tempo, and takes the f64 path, where nothing accumulates.
const MAX_INTEGRAL_US: f64 = 0x1p63;

comptime {
    std.debug.assert(MAX_INTEGRAL_US == @as(f64, @floatFromInt(@as(u64, 1) << 63)));
}

/// The derived maps, best-effort: every defect is a diagnostic and the
/// map is still built (plan 03; an editor has to show something).
///
/// Whatever the points say, the result holds at least one tempo segment
/// and one meter segment, both starting at tick 0, and a bar table whose
/// first entry is bar 0 — the invariant every lookup here relies on. A
/// `length` below 0 gives the one-entry bar table and a loop point with
/// nothing in it, which `wrapSeconds` passes through.
///
/// `frames` is the document's declared frame state — its `:fps`, and
/// whether the document wrote an `f` position — delivered as one
/// parameter so a caller cannot forget it the way a post-construction
/// field can be forgotten. Null for a document with no `:fps`, and for
/// every map derived without one (a conductor's probe, a file's own
/// seconds: no file format carries a rate).
pub fn derive(
    gpa: std.mem.Allocator,
    tempo: []const TempoPoint,
    meter: []const MeterPoint,
    length: i64,
    end: End,
    frames: ?Frames,
) error{OutOfMemory}!Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var diags: Diag.List = .init(gpa);
    errdefer {
        arena_state.deinit();
        diags.deinit();
    }
    const arena = arena_state.allocator();

    const segments = try tempoTable(arena, &diags, tempo);
    const integral = isIntegral(segments);
    fillOrigins(segments, integral);

    const meters = try meterTable(arena, &diags, meter);
    const bars = try barTable(arena, &diags, meters, length);

    var map: TimeMap = .{
        .segments = segments,
        .meters = meters,
        .bars = bars,
        .length = length,
        .end = end,
        .frames = frames,
        .integral = integral,
        .loop_secs = 0,
        .arena = arena_state,
    };
    // The loop point is the map's own answer for `:length`, computed once
    // (pacer's compile-time constant): `wrapSeconds` runs on it per call.
    map.loop_secs = map.secondsFromTick(length);

    map.invariants();
    return .{ .map = map, .diags = diags };
}

/// The tempo points, validated into `{tick, us}` pairs. `tps`,
/// `start_sec` and `t_i` are filled afterwards, once the path is known.
fn tempoTable(
    arena: std.mem.Allocator,
    diags: *Diag.List,
    tempo: []const TempoPoint,
) error{OutOfMemory}![]Segment {
    var segs: std.ArrayList(Segment) = .empty;

    // The point at tick 0 is required, and a point that names no tempo is
    // no point: the fallback segment goes in unless the document put a
    // USABLE one there (the same test `meterTable` makes), or the map
    // would start at the second point's tick — or at nothing at all —
    // and every lookup below would read the wrong segment.
    const at_zero = tempo.len > 0 and tempo[0].tick == 0;
    if (!(at_zero and usOf(tempo[0]) != null)) {
        // A point IS at tick 0 and is the thing that is wrong: the loop
        // below reports it in its own words, once.
        if (!at_zero) {
            try diags.add(
                .tempo_map_invalid,
                .err,
                if (tempo.len > 0) tempo[0].span else .{ .start = 0, .end = 0 },
                "a tempo map needs a point at tick 0; assuming {d} microseconds per quarter note",
                .{DEFAULT_US},
            );
        }
        try segs.append(arena, blank(0, DEFAULT_US, .{ .start = 0, .end = 0 }));
    }

    for (tempo) |p| {
        switch (tempoStep(segs.getLastOrNull(), segs.items.len, p)) {
            .keep => |seg| try segs.append(arena, seg),
            .refuse => |why| {
                try refuseTempo(diags, p, why);
                // The budget is spent: every later point goes with this
                // one, and the diagnostic said so once.
                if (why == .over_budget) break;
            },
        }
    }

    return segs.toOwnedSlice(arena);
}

/// Why `tempoTable` drops a point, with what its diagnostic prints.
const TempoRefusal = union(enum) {
    no_tempo,
    /// The tick of the segment it fails to follow.
    not_after: i64,
    past_ceiling,
    over_budget,
};

/// What one authored tempo point comes to, after `prev` (the last kept
/// segment, or null before the first) and `count` kept segments: the
/// segment to keep, or the reason to drop it. Pure; the checks run in
/// the order the diagnostics have always been raised.
fn tempoStep(
    prev: ?Segment,
    count: usize,
    p: TempoPoint,
) union(enum) { keep: Segment, refuse: TempoRefusal } {
    const us = usOf(p) orelse return .{ .refuse = .no_tempo };
    if (prev) |before| {
        if (p.tick <= before.tick) return .{ .refuse = .{ .not_after = before.tick } };
    }
    // Every segment sits inside the grid, so a query's `tick_i +
    // offset` stays inside i64. No reader places a point past the
    // ceiling — a literal, an SMF pulse and an IT tick are each
    // capped on the way in — but the map's contract is the value's.
    if (p.tick > Grid.MAX_TICK) return .{ .refuse = .past_ceiling };
    if (count == MAX_TEMPO_SEGMENTS) return .{ .refuse = .over_budget };
    return .{ .keep = blank(p.tick, us, p.span) };
}

/// The diagnostic a dropped tempo point earns, with its own span.
fn refuseTempo(diags: *Diag.List, p: TempoPoint, why: TempoRefusal) error{OutOfMemory}!void {
    switch (why) {
        .no_tempo => try diags.add(
            .tempo_map_invalid,
            .err,
            p.span,
            "tempo point at tick {d} names no tempo",
            .{p.tick},
        ),
        .not_after => |prev| try diags.add(
            .tempo_map_invalid,
            .err,
            p.span,
            "tempo point at tick {d} is not after the previous point at tick {d}",
            .{ p.tick, prev },
        ),
        .past_ceiling => try diags.add(
            .tick_overflow,
            .err,
            p.span,
            "tempo point at tick {d} is past the grid ceiling {d}",
            .{ p.tick, Grid.MAX_TICK },
        ),
        .over_budget => try diags.add(
            .tempo_map_invalid,
            .err,
            p.span,
            "more than {d} tempo segments; the points from tick {d} on are dropped",
            .{ MAX_TEMPO_SEGMENTS, p.tick },
        ),
    }
}

/// The meter points, validated into segments that carry the bar number
/// and the cumulative beat count each one starts at.
fn meterTable(
    arena: std.mem.Allocator,
    diags: *Diag.List,
    meter: []const MeterPoint,
) error{OutOfMemory}![]MeterSeg {
    var mets: std.ArrayList(MeterSeg) = .empty;

    if (!(meter.len > 0 and meter[0].tick == 0 and meterOk(meter[0]))) {
        try diags.add(
            .meter_map_invalid,
            .err,
            if (meter.len > 0) meter[0].span else .{ .start = 0, .end = 0 },
            "a meter map needs a point at tick 0; assuming [4 4]",
            .{},
        );
        try mets.append(arena, .{ .tick = 0, .n = 4, .d = 4, .first_bar = 0, .beats_before = 0 });
    }

    for (meter) |p| {
        switch (meterStep(mets.getLastOrNull(), p)) {
            .keep => |seg| try mets.append(arena, seg),
            .refuse => |why| try refuseMeter(diags, p, why),
        }
    }

    return mets.toOwnedSlice(arena);
}

/// Why `meterTable` drops a point, with what its diagnostic prints.
const MeterRefusal = union(enum) {
    not_a_meter,
    /// The tick of the segment it fails to follow.
    not_after: i64,
    past_ceiling,
    /// How far into a bar of the meter before it the point sits.
    off_bar: struct { into: i64, n: u8, d: u8 },
};

/// What one authored meter point comes to after `prev`, the last kept
/// segment (null before the first): the segment to keep, with its first
/// bar and the beats before it, or the reason to drop it. Pure; the
/// checks run in the order the diagnostics have always been raised.
fn meterStep(prev: ?MeterSeg, p: MeterPoint) union(enum) { keep: MeterSeg, refuse: MeterRefusal } {
    if (!meterOk(p)) return .{ .refuse = .not_a_meter };
    // No segment yet: reachable only for a valid point at tick 0 —
    // otherwise `meterTable`'s default already filled the slot.
    const before = prev orelse return .{
        .keep = .{ .tick = p.tick, .n = p.n, .d = p.d, .first_bar = 0, .beats_before = 0 },
    };
    if (p.tick <= before.tick) return .{ .refuse = .{ .not_after = before.tick } };
    // Inside the grid, for the reason `tempoStep` gives.
    if (p.tick > Grid.MAX_TICK) return .{ .refuse = .past_ceiling };
    // A meter change mid-bar is not a thing in any source format
    // (plan 03, "Meter"), so the point has to sit on a bar line of
    // the meter before it.
    const bar_len = Grid.barTicks(before.n, before.d);
    const delta = p.tick - before.tick;
    const into = @rem(delta, bar_len);
    if (into != 0) return .{
        .refuse = .{ .off_bar = .{ .into = into, .n = before.n, .d = before.d } },
    };
    const nbars = @divExact(delta, bar_len);
    // Strictly after, on a bar line: at least one whole bar on.
    std.debug.assert(nbars >= 1);
    return .{ .keep = .{
        .tick = p.tick,
        .n = p.n,
        .d = p.d,
        .first_bar = before.first_bar + nbars,
        .beats_before = before.beats_before + nbars * before.n,
    } };
}

/// The diagnostic a dropped meter point earns, with its own span.
fn refuseMeter(diags: *Diag.List, p: MeterPoint, why: MeterRefusal) error{OutOfMemory}!void {
    switch (why) {
        .not_a_meter => try diags.add(
            .meter_map_invalid,
            .err,
            p.span,
            "meter [{d} {d}] at tick {d} is not a meter: " ++
                "n is 1..64 and d is one of 1, 2, 4, 8, 16, 32",
            .{ p.n, p.d, p.tick },
        ),
        .not_after => |prev| try diags.add(
            .meter_map_invalid,
            .err,
            p.span,
            "meter point at tick {d} is not after the previous point at tick {d}",
            .{ p.tick, prev },
        ),
        .past_ceiling => try diags.add(
            .tick_overflow,
            .err,
            p.span,
            "meter point at tick {d} is past the grid ceiling {d}",
            .{ p.tick, Grid.MAX_TICK },
        ),
        .off_bar => |off| try diags.add(
            .meter_off_bar,
            .err,
            p.span,
            "meter point at tick {d} is {d} ticks into a bar of [{d} {d}]",
            .{ p.tick, off.into, off.n, off.d },
        ),
    }
}

/// `n` is 1..64 and `d` is a power of two up to 32 (plan 03, "Meter":
/// SMF's `dd` is a power of two, and a `d` that is not one has no source
/// and no exact bar length here). `Grid.beatTicks` carries this as a
/// PRECONDITION, so every point is checked before it is converted.
/// Whether a meter point is one the map honours: `n` in 1..64 and `d` in
/// the power-of-two set pacer's lattice and the grid both divide. The one
/// definition — a consumer reading a document's RAW meter points (the
/// renderers do, for a header) asks this rather than re-deriving a weaker
/// check, because a `:sig` that is not a meter still goes into the
/// document and only this map says `meter_map_invalid` about it.
pub fn meterOk(p: MeterPoint) bool {
    if (p.n < 1 or p.n > 64) return false;
    return switch (p.d) {
        1, 2, 4, 8, 16, 32 => true,
        else => false,
    };
}

/// `bar_start(m)` for every bar up to `:length`, built once per derive
/// (plan 03, "Meter"): the index IS the bar number.
fn barTable(
    arena: std.mem.Allocator,
    diags: *Diag.List,
    meters: []const MeterSeg,
    length: i64,
) error{OutOfMemory}![]i64 {
    var bars: std.ArrayList(i64) = .empty;
    const end_tick = @max(length, 0);
    var tick: i64 = 0;
    var mi: usize = 0;
    // One entry per pass, so never more than `MAX_BARS` passes: on the
    // last one the budget check below breaks if nothing else has, and
    // the loop's `else` is never reached.
    for (0..MAX_BARS) |_| {
        // The meter in force at `tick`. `mi` only moves forward, so
        // this is bounded by the meter count over the whole table.
        while (mi + 1 < meters.len and meters[mi + 1].tick <= tick) mi += 1;
        try bars.append(arena, tick);
        if (tick >= end_tick) break;

        const next = tick + Grid.barTicks(meters[mi].n, meters[mi].d);
        if (next > Grid.MAX_TICK) {
            try diags.add(
                .tick_overflow,
                .err,
                .{ .start = 0, .end = 0 },
                "bar {d} starts past the grid ceiling {d}; the bar table stops at tick {d}",
                .{ bars.items.len, Grid.MAX_TICK, tick },
            );
            break;
        }
        if (bars.items.len >= MAX_BARS) {
            try diags.add(
                .tick_overflow,
                .err,
                .{ .start = 0, .end = 0 },
                "a length of {d} ticks is more than {d} bars; the bar table stops at tick {d}",
                .{ length, MAX_BARS, tick },
            );
            break;
        }
        tick = next;
    } else unreachable;
    return bars.toOwnedSlice(arena);
}

/// A float as the 16 hex digits of its IEEE-754 bits — the corpus's
/// only float spelling.
fn bits(x: f64) u64 {
    return @bitCast(x);
}

/// Whether a tempo point names a tempo the map honours: microseconds per
/// quarter note, from `:us` or from `60e6 / :qpm`, finite and positive —
/// `usOf`, the test `tempoTable` makes. The one definition, as `meterOk`
/// is for a meter: a consumer that writes a point (the edit engine's
/// `insert-tempo`) asks this rather than re-deriving a weaker check,
/// because only this map says `tempo_map_invalid` about a point.
pub fn tempoOk(p: TempoPoint) bool {
    return usOf(p) != null;
}

/// The microseconds per quarter note a point names, or `null` when it
/// names no tempo at all — `:us 0`, or a `:qpm` that is zero, negative or
/// not a number. `60e6 / qpm` is ONE f64 division (plan 03, "Tempo").
///
/// The map's own conversion, and the only one: a segment's `us` is this
/// value bit for bit, so a consumer that pairs a segment with the point
/// behind it (`export/tempo.zig`) compares against this and not against
/// a division of its own. Pure; borrows nothing.
pub fn usOf(p: TempoPoint) ?f64 {
    const us = switch (p.tempo) {
        .us => |u| @as(f64, @floatFromInt(u)),
        .qpm => |q| US_PER_MINUTE / q,
    };
    if (!(std.math.isFinite(us) and us > 0)) return null;
    return us;
}

fn blank(tick: i64, us: f64, span: Diag.Span) Segment {
    return .{ .tick = tick, .us = us, .tps = 0, .start_sec = 0, .t_i = 0, .span = span };
}

/// Which of plan 03's two paths this map takes, decided ONCE: the
/// integer origins when every `us` is a whole number of microseconds (an
/// SMF conductor, or a document that says `:us`, or a `:qpm` whose
/// `60e6 / qpm` divides out) that the accumulator can hold
/// (`MAX_INTEGRAL_US`), the f64 origins otherwise. A single fractional
/// or oversized `us` takes the whole table with it; a document never
/// mixes them at run time.
fn isIntegral(segments: []const Segment) bool {
    for (segments) |s| {
        if (s.us != @trunc(s.us)) return false;
        if (s.us >= MAX_INTEGRAL_US) return false;
    }
    return true;
}

/// Plan 03's op order, verbatim, in whichever path `integral` chose.
/// Never reassociated.
fn fillOrigins(segments: []Segment, integral: bool) void {
    var t_acc: i128 = 0;
    for (segments, 0..) |*s, i| {
        // tps_i = (TPQ · 1e6) / us_i — one mul (comptime-folded, exact),
        // one div. It is the f64 path's rate and the echo's for both.
        s.tps = TICK_US / s.us;

        if (i == 0) {
            s.t_i = 0;
            s.start_sec = 0;
            continue;
        }
        const prev = segments[i - 1];
        if (integral) {
            // T_i = Σ Δtick_j · us_j, accumulated UNDIVIDED in i128, and
            // seconds(tick_i) = T_i / (TPQ · 1e6) — the one division.
            t_acc += @as(i128, s.tick - prev.tick) * @as(i128, @intFromFloat(prev.us));
            s.t_i = t_acc;
            s.start_sec = @as(f64, @floatFromInt(s.t_i)) / TICK_US;
        } else {
            // start_sec_{i+1} = start_sec_i + Δtick / tps_i — Δtick exact
            // i64→f64, ONE division, ONE add.
            s.t_i = 0;
            s.start_sec = prev.start_sec + @as(f64, @floatFromInt(s.tick - prev.tick)) / prev.tps;
        }
    }
}

// ---- tests ----

test "TimeMap.derive: the segment table builds in plan 03's op order" {
    // Three segments, every expectation dyadic-exact by hand:
    //   seg 0 @ tick 0,          120 qpm → us = 60e6/120 = 500 000
    //                            tps = (TPQ·1e6)/500 000 = 92 252 160
    //                            (the identity tps = TPQ·qpm/60 = 768 768·qpm)
    //   seg 1 @ tick 184 504 320 (4q), 240 qpm → us = 250 000, tps = 184 504 320
    //   seg 2 @ tick 553 512 960 (12q), 97.3 qpm → us = 60e6/97.3 is NOT an
    //                            integer, so the whole table takes the f64 path.
    // start_sec_1 = 0 + 184 504 320 / 92 252 160  = 2
    // start_sec_2 = 2 + 369 008 640 / 184 504 320 = 4
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
        .{ .tick = 184_504_320, .tempo = .{ .qpm = 240 } },
        .{ .tick = 553_512_960, .tempo = .{ .qpm = 97.3 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
    }, 553_512_960, .loop, null);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 3), r.map.segments.len);
    try testing.expectEqual(false, r.map.integral);

    try testing.expectEqual(@as(f64, 500_000), r.map.segments[0].us);
    try testing.expectEqual(@as(f64, 92_252_160), r.map.segments[0].tps);
    try testing.expectEqual(@as(f64, 0), r.map.segments[0].start_sec);

    try testing.expectEqual(@as(f64, 250_000), r.map.segments[1].us);
    try testing.expectEqual(@as(f64, 184_504_320), r.map.segments[1].tps);
    try testing.expectEqual(@as(f64, 2), r.map.segments[1].start_sec);

    // 768 768 · 97.3 = 74 801 126.4, the one segment whose rate is not
    // exact in f64 — it is the same one multiply and one divide.
    try testing.expectApproxEqRel(@as(f64, 74_801_126.4), r.map.segments[2].tps, 1e-12);
    try testing.expectEqual(@as(f64, 4), r.map.segments[2].start_sec);

    // Every value above is exact under ANY equivalent accumulation, so
    // they pin the numbers and not the op ORDER. This map does: 97.3 qpm
    // from 0 and 150 at 4q, where
    //   start_sec_1 = 0 + 184 504 320 / tps_0 = 2.466598150051387
    // and the last bit is the whole point — a microseconds origin
    // (Δtick · us_0 / TPQ, then / 1e6) lands one ulp above, on
    // 0x4003BB97CF96C22C.
    var pin = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 97.3 } },
        .{ .tick = 184_504_320, .tempo = .{ .qpm = 150 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 184_504_320, .hold, null);
    defer pin.deinit();
    try testing.expectEqual(false, pin.map.integral);
    try testing.expectEqual(
        @as(u64, 0x4003BB97CF96C22B),
        @as(u64, @bitCast(pin.map.segments[1].start_sec)),
    );
}

test "TimeMap.derive: a segment keeps the span of the point that made it" {
    // The map's own provenance, so a consumer that has to name the
    // document node behind a segment (the export position map) reads it
    // here instead of pairing tick and rate a second time. A point the
    // map refused is behind no segment, and the origin the map supplies
    // at tick 0 has no point: both carry the empty span.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 125 }, .span = .{ .start = 10, .end = 11 } },
        .{ .tick = 184_504_320, .tempo = .{ .qpm = 150 }, .span = .{ .start = 20, .end = 21 } },
        .{ .tick = 369_008_640, .tempo = .{ .qpm = -5 }, .span = .{ .start = 30, .end = 31 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 738_017_280, .hold, null);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 2), r.map.segments.len);
    try testing.expectEqual(@as(u32, 10), r.map.segments[0].span.start);
    try testing.expectEqual(@as(u32, 11), r.map.segments[0].span.end);
    try testing.expectEqual(@as(u32, 20), r.map.segments[1].span.start);
    try testing.expectEqual(@as(u32, 21), r.map.segments[1].span.end);

    // A document whose only point is not at tick 0: the map supplies
    // segment 0, which names no document node, and keeps the point as
    // segment 1 with its own span.
    var supplied = try derive(testing.allocator, &.{
        .{ .tick = 46_126_080, .tempo = .{ .qpm = 125 }, .span = .{ .start = 10, .end = 11 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 92_252_160, .hold, null);
    defer supplied.deinit();
    try testing.expectEqual(@as(usize, 2), supplied.map.segments.len);
    try testing.expectEqual(@as(u32, 0), supplied.map.segments[0].span.end);
    try testing.expectEqual(@as(u32, 10), supplied.map.segments[1].span.start);
}

test "TimeMap.derive: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails with
    // error.OutOfMemory and testing.allocator sees no leak; past the last
    // index it succeeds. Bounded by the number of allocations the call
    // makes, which the loop discovers.
    //
    // The fixture makes all three tables AND the report allocate: no
    // tempo point at tick 0 (the fallback, said), a meter point 2q into
    // a [3 4] bar (dropped, said), a meter change on bar 2 and a bar table
    // six bars long.
    const tempo = [_]TempoPoint{
        .{ .tick = 46_126_080, .tempo = .{ .qpm = 120 } },
        .{ .tick = 184_504_320, .tempo = .{ .qpm = 97.3 } },
    };
    const meter = [_]MeterPoint{
        .{ .tick = 0, .n = 3, .d = 4 },
        .{ .tick = 92_252_160, .n = 5, .d = 4 },
        .{ .tick = 276_756_480, .n = 4, .d = 4 },
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = derive(failing.allocator(), &tempo, &meter, 1_014_773_760, .loop, null);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expectEqual(@as(usize, 2), r.diags.items().len);
            try testing.expectEqual(@as(usize, 7), r.map.bars.len);
            break;
        }
    }
    // The sweep swept: the map's arena and the report's are each asked
    // for memory (an arena asks its backing allocator for whole nodes,
    // not once per table, so this is a floor and not a count).
    try testing.expect(fail_index >= 2);
}

/// The fixture of plan 03's op-order table: 120 qpm, 240 qpm at 4q,
/// 97.3 qpm at 12q. `:length` is 16q, two bars of `[4 4]`.
fn threeSegmentMap() error{OutOfMemory}!Result {
    return derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
        .{ .tick = 184_504_320, .tempo = .{ .qpm = 240 } },
        .{ .tick = 553_512_960, .tempo = .{ .qpm = 97.3 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
    }, 738_017_280, .loop, null);
}

test "TimeMap: seconds and ticks are exact at a segment boundary, both ways" {
    var r = try threeSegmentMap();
    defer r.deinit();
    const m = &r.map;

    // seconds(tick) = start_sec_i + (tick − tick_i) / tps_i.
    //   tick 92 252 160 (2q)  → 92 252 160 / 92 252 160  = 1
    //   tick 184 504 320 (4q) → the segment-1 origin, 2 exactly
    //   tick 276 756 480 (6q) → 2 + 92 252 160 / 184 504 320 = 2.5
    //   tick 553 512 960 (12q)→ the segment-2 origin, 4 exactly
    try testing.expectEqual(@as(f64, 0), m.secondsFromTick(0));
    try testing.expectEqual(@as(f64, 1), m.secondsFromTick(92_252_160));
    try testing.expectEqual(@as(f64, 2), m.secondsFromTick(184_504_320));
    try testing.expectEqual(@as(f64, 2.5), m.secondsFromTick(276_756_480));
    try testing.expectEqual(@as(f64, 4), m.secondsFromTick(553_512_960));
    // A segment start IS its table entry — that is what makes the round
    // trip below exact.
    try testing.expectEqual(m.segments[1].start_sec, m.secondsFromTick(184_504_320));
    try testing.expectEqual(m.segments[2].start_sec, m.secondsFromTick(553_512_960));

    // tick(seconds) = tick_i + max(0, floor((seconds − start_sec_i) · tps_i)).
    //   1.5 s · 92 252 160 = 138 378 240 (3q), inside segment 0
    //   2.0 s → segment 1 selected, the difference is 0: the origin back
    //   2.5 s → 184 504 320 + 0.5 · 184 504 320 = 276 756 480
    //   4.0 s → segment 2's origin back
    try testing.expectEqual(@as(i64, 0), try m.tickFromSeconds(0));
    try testing.expectEqual(@as(i64, 138_378_240), try m.tickFromSeconds(1.5));
    try testing.expectEqual(@as(i64, 184_504_320), try m.tickFromSeconds(2.0));
    try testing.expectEqual(@as(i64, 276_756_480), try m.tickFromSeconds(2.5));
    try testing.expectEqual(@as(i64, 553_512_960), try m.tickFromSeconds(4.0));

    // A clock value FLOORS — it is the last tick begun, never the
    // nearest one: 2e-8 s · 92 252 160 = 1.8450432, which is tick 1.
    try testing.expectEqual(@as(i64, 1), try m.tickFromSeconds(2e-8));

    // The `max(0, …)` clamp: seconds before the map start no more make a
    // negative tick than they make a negative position.
    try testing.expectEqual(@as(i64, 0), try m.tickFromSeconds(-1.0));
}

test "TimeMap: :qpm 97.3 then 150 at 13q returns the boundary tick from its own seconds" {
    // Plan 03's fixture for the SHAPE of the table. 13q = 13 · TPQ =
    // 599 639 040 ticks; us_0 = 60e6 / 97.3 = 616 649.537…, not a whole
    // number of microseconds, so the map takes the f64 path.
    //
    // start_sec_1 = 0 + 599 639 040 / tps_0 is the table entry, and
    // seconds(599 639 040) IS that entry, so the difference is exactly 0
    // and tick(seconds) = tick_1 + max(0, floor(0 · tps_1)) = tick_1.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 97.3 } },
        .{ .tick = 599_639_040, .tempo = .{ .qpm = 150 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
    }, 599_639_040, .hold, null);
    defer r.deinit();
    const m = &r.map;

    try testing.expectEqual(false, m.integral);
    const seconds = m.secondsFromTick(599_639_040);
    try testing.expectEqual(m.segments[1].start_sec, seconds);
    try testing.expectEqual(@as(i64, 599_639_040), try m.tickFromSeconds(seconds));

    // Why the shape and not a microseconds origin (plan 03, "The segment
    // table"): the same fixture with origins kept in MICROSECONDS and
    // scaled by 1e6 on the way in and out loses a ulp in the round trip,
    // so the offset it hands its clock floor is NEGATIVE — and larger
    // than −1, about −1.07e−7 of a tick. A floor of a value in (−1, 0) is
    // −1, so that table answers 599 639 039, the boundary tick MINUS ONE.
    // Stated as the two inequalities and not as a floor builtin, because
    // the repo's one clock floor is `tickFromSeconds` and 03's lint
    // greps the source for that builtin ("Round versus floor").
    const tpq: f64 = @floatFromInt(Grid.TPQ);
    const us_0: f64 = 60_000_000.0 / 97.3;
    const us_1: f64 = 60_000_000.0 / 150.0;
    const origin_us: f64 = 599_639_040.0 * us_0 / tpq;
    const bad_seconds = origin_us / 1e6;
    const bad_offset = (bad_seconds * 1e6 - origin_us) * tpq / us_1;
    try testing.expect(bad_offset < 0);
    try testing.expect(bad_offset > -1);
}

test "TimeMap: the same fixture in :us takes the integer path to the same tick" {
    // `:us 616650` is the nearest whole microsecond to 60e6 / 97.3 and
    // `:us 400000` is 60e6 / 150 exactly, so EVERY us_i is an integer and
    // the origins are the undivided i128 ones:
    //   T_1 = 599 639 040 · 616 650 = 369 767 414 016 000
    //   start_sec_1 = T_1 / (TPQ · 1e6), the one division
    // and seconds(599 639 040) is that same quotient, so
    // (seconds · (TPQ · 1e6) − T_1) / us_1 floors to 0.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 616_650 } },
        .{ .tick = 599_639_040, .tempo = .{ .us = 400_000 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
    }, 599_639_040, .hold, null);
    defer r.deinit();
    const m = &r.map;

    try testing.expectEqual(true, m.integral);
    try testing.expectEqual(@as(i128, 0), m.segments[0].t_i);
    try testing.expectEqual(@as(i128, 369_767_414_016_000), m.segments[1].t_i);

    const seconds = m.secondsFromTick(599_639_040);
    try testing.expectEqual(m.segments[1].start_sec, seconds);
    try testing.expectEqual(@as(i64, 599_639_040), try m.tickFromSeconds(seconds));
}

test "TimeMap: :us 480000 and :qpm 125 derive one identical segment" {
    // 60e6 / 125 = 480 000 exactly, so the two spellings name the same
    // tempo, take the same (integer) path and build the same segment:
    //   tps = (TPQ · 1e6) / 480 000 = 96 096 000 = 768 768 · 125.
    var by_us = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 480_000 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, null);
    defer by_us.deinit();
    var by_qpm = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 125 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, null);
    defer by_qpm.deinit();

    try testing.expectEqual(@as(usize, 1), by_us.map.segments.len);
    try testing.expectEqual(by_us.map.segments[0], by_qpm.map.segments[0]);
    try testing.expectEqual(@as(f64, 480_000), by_us.map.segments[0].us);
    try testing.expectEqual(@as(f64, 96_096_000), by_us.map.segments[0].tps);
    try testing.expectEqual(true, by_us.map.integral);
    try testing.expectEqual(true, by_qpm.map.integral);
}

/// A bar of `[n d]` is n beats of 4/d quarters:
///   [3 4] → 3 · TPQ = 138 378 240 ticks
///   [4 4] → 4 · TPQ = 184 504 320 ticks
/// The change sits on bar 2 of the first meter, tick 2 · 138 378 240 =
/// 276 756 480, and `:length` is four [4 4] bars later:
/// 276 756 480 + 4 · 184 504 320 = 1 014 773 760, which is bar 6.
fn meterChangeMap() error{OutOfMemory}!Result {
    return derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
    }, &.{
        .{ .tick = 0, .n = 3, .d = 4 },
        .{ .tick = 276_756_480, .n = 4, .d = 4 },
    }, 1_014_773_760, .hold, null);
}

test "TimeMap.derive: the bar table under a [3 4] → [4 4] change" {
    var r = try meterChangeMap();
    defer r.deinit();
    const m = &r.map;

    try testing.expectEqual(@as(usize, 0), r.diags.items().len);
    try testing.expectEqualSlices(i64, &.{
        0,
        138_378_240,
        276_756_480,
        461_260_800,
        645_765_120,
        830_269_440,
        1_014_773_760,
    }, m.bars);

    // Bars 0 and 1 carry three beats each, so the [4 4] segment's first
    // bar is 2 and the beats before it are 6.
    try testing.expectEqual(@as(usize, 2), m.meters.len);
    try testing.expectEqual(MeterSeg{
        .tick = 276_756_480,
        .n = 4,
        .d = 4,
        .first_bar = 2,
        .beats_before = 6,
    }, m.meters[1]);

    // barOf: bar 3 starts at 461 260 800, so one quarter later is beat 1
    // on the nose.
    const at = m.barOf(461_260_800 + 46_126_080);
    try testing.expectEqual(@as(i64, 3), at.bar);
    try testing.expectEqual(@as(i64, 1), at.beat);
    try testing.expectEqual(@as(i64, 0), at.sub_ticks);
    try testing.expectEqual(@as(u8, 4), at.meter.n);

    // Inside bar 1, which is still [3 4]: 138 378 240 + 2 · 46 126 080 + 1
    // = beat 2 plus one tick.
    const off = m.barOf(230_630_401);
    try testing.expectEqual(@as(i64, 1), off.bar);
    try testing.expectEqual(@as(i64, 2), off.beat);
    try testing.expectEqual(@as(i64, 1), off.sub_ticks);
    try testing.expectEqual(@as(u8, 3), off.meter.n);

    // Past the table the [4 4] carries on: bar 7 starts at
    // 1 014 773 760 + 184 504 320 = 1 199 278 080, and one quarter into
    // it is beat 1 of bar 7.
    const past = m.barOf(1_199_278_080 + 46_126_080);
    try testing.expectEqual(@as(i64, 7), past.bar);
    try testing.expectEqual(@as(i64, 1), past.beat);
    try testing.expectEqual(@as(i64, 0), past.sub_ticks);

    try testing.expectEqual(@as(?i64, 0), m.isBarLine(0));
    try testing.expectEqual(@as(?i64, 2), m.isBarLine(276_756_480));
    try testing.expectEqual(@as(?i64, null), m.isBarLine(276_756_481));
    // `:length` is bar 6, the table's last entry…
    try testing.expectEqual(@as(?i64, 6), m.isBarLine(1_014_773_760));
    // …and a bar line past the table is still a bar line.
    try testing.expectEqual(@as(?i64, 7), m.isBarLine(1_199_278_080));
    try testing.expectEqual(@as(?i64, null), m.isBarLine(1_199_278_079));

    // `barStart` is the TABLE's own answer and stops where it stops.
    try testing.expectEqual(@as(?i64, 645_765_120), m.barStart(4));
    try testing.expectEqual(@as(?i64, null), m.barStart(7));
}

test "TimeMap.derive: a meter point off a bar line of the meter before it is meter_off_bar" {
    // [4 4] from tick 0 puts a bar line every 4 · TPQ = 184 504 320
    // ticks. Tick 92 252 160 is 2q — the middle of bar 0 — so the point
    // is dropped, with its own span, and the map stays [4 4]:
    // bars 0, 184 504 320, 369 008 640 for a length of two bars.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
        .{ .tick = 92_252_160, .n = 3, .d = 4, .span = .{ .start = 7, .end = 11 } },
    }, 369_008_640, .hold, null);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.diags.count(.meter_off_bar));
    try testing.expectEqual(Diag.Code.meter_off_bar, r.diags.items()[0].code);
    try testing.expectEqual(@as(u32, 7), r.diags.items()[0].span.start);
    try testing.expectEqual(@as(usize, 1), r.map.meters.len);
    try testing.expectEqualSlices(i64, &.{ 0, 184_504_320, 369_008_640 }, r.map.bars);
}

test "TimeMap.derive: a meter map with no point at 0, a bad signature or a step back is meter_map_invalid" {
    // No point at tick 0: the map is given [4 4] and says so. The point
    // at 184 504 320 is a bar line of that default (4 · TPQ), so it is
    // kept, as bar 1.
    var none = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
    }, &.{
        .{ .tick = 184_504_320, .n = 3, .d = 4 },
    }, 184_504_320, .hold, null);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 1), none.diags.count(.meter_map_invalid));
    try testing.expectEqual(@as(usize, 2), none.map.meters.len);
    try testing.expectEqual(@as(u8, 4), none.map.meters[0].n);
    try testing.expectEqual(@as(i64, 1), none.map.meters[1].first_bar);
    try testing.expectEqual(@as(i64, 4), none.map.meters[1].beats_before);

    // `d` must be one of 1, 2, 4, 8, 16, 32 and `n` must be 1..64.
    var bad = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
        .{ .tick = 184_504_320, .n = 5, .d = 3 },
        .{ .tick = 369_008_640, .n = 0, .d = 4 },
        .{ .tick = 553_512_960, .n = 65, .d = 4 },
    }, 184_504_320, .hold, null);
    defer bad.deinit();
    try testing.expectEqual(@as(usize, 3), bad.diags.count(.meter_map_invalid));
    try testing.expectEqual(@as(usize, 1), bad.map.meters.len);

    // Ascending, and never twice at one tick.
    var back = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
        .{ .tick = 184_504_320, .n = 3, .d = 4 },
        .{ .tick = 184_504_320, .n = 2, .d = 4 },
    }, 184_504_320, .hold, null);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.diags.count(.meter_map_invalid));
    try testing.expectEqual(@as(usize, 2), back.map.meters.len);
    try testing.expectEqual(@as(u8, 3), back.map.meters[1].n);
}

test "TimeMap.derive: a tempo map with no point at 0, a step back or too many segments is tempo_map_invalid" {
    // No point at tick 0: the map is given SMF's own default, 500 000
    // microseconds per quarter note (120 qpm), and says so. The default
    // is an INTEGER, so it never drags a `:us` document onto the f64 path.
    var none = try derive(testing.allocator, &.{
        .{ .tick = 46_126_080, .tempo = .{ .us = 400_000 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, null);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 1), none.diags.count(.tempo_map_invalid));
    try testing.expectEqual(@as(usize, 2), none.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), none.map.segments[0].us);
    try testing.expectEqual(true, none.map.integral);

    // Two points at one tick are the same diagnostic as a step back
    // (plan 03, pacer's rule): the later one is dropped.
    var twice = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 500_000 } },
        .{ .tick = 46_126_080, .tempo = .{ .us = 400_000 } },
        .{ .tick = 46_126_080, .tempo = .{ .us = 300_000 } },
        .{ .tick = 1, .tempo = .{ .us = 200_000 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, null);
    defer twice.deinit();
    try testing.expectEqual(@as(usize, 2), twice.diags.count(.tempo_map_invalid));
    try testing.expectEqual(@as(usize, 2), twice.map.segments.len);
    try testing.expectEqual(@as(f64, 400_000), twice.map.segments[1].us);

    // The segment budget: the points past it are dropped, once.
    const many = try testing.allocator.alloc(TempoPoint, MAX_TEMPO_SEGMENTS + 8);
    defer testing.allocator.free(many);
    for (many, 0..) |*p, i| {
        p.* = .{ .tick = @as(i64, @intCast(i)) * 46_126_080, .tempo = .{ .us = 500_000 } };
    }
    var capped = try derive(
        testing.allocator,
        many,
        &.{.{ .tick = 0, .n = 4, .d = 4 }},
        0,
        .hold,
        null,
    );
    defer capped.deinit();
    try testing.expectEqual(@as(usize, 1), capped.diags.count(.tempo_map_invalid));
    try testing.expectEqual(MAX_TEMPO_SEGMENTS, capped.map.segments.len);
}

/// 120 qpm, doubling to 240 at 4q (tick 184 504 320), `[4 4]`, two bars
/// long (369 008 640 ticks): tps 92 252 160 then 184 504 320, and the
/// boundary lands on exactly 2 s.
fn twoSegmentMap(end: End) error{OutOfMemory}!Result {
    return derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
        .{ .tick = 184_504_320, .tempo = .{ .qpm = 240 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
    }, 369_008_640, end, null);
}

/// 120 qpm, `[4 4]`, and no length at all — the map a document has
/// before its `:length` is worked out.
fn zeroLengthMap(end: End) error{OutOfMemory}!Result {
    return derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
    }, 0, end, null);
}

test "TimeMap: :end loop wraps SECONDS first, into the early segment" {
    var r = try twoSegmentMap(.loop);
    defer r.deinit();
    const m = &r.map;

    // loop_secs = seconds(369 008 640) = 2 + 184 504 320 / 184 504 320 = 3.
    try testing.expectEqual(@as(f64, 3), m.loop_secs);

    // 3.5 s is half a second into iteration 2, which replays the FIRST
    // segment: 0.5 · 92 252 160 = 46 126 080 (1q).
    const wrapped = m.wrapSeconds(3.5);
    try testing.expectEqual(@as(f64, 0.5), wrapped);
    try testing.expectEqual(@as(i64, 46_126_080), try m.tickFromSeconds(wrapped));

    // The bug this ordering prevents: converting first reads 1.5 s of
    // segment-1 tempo (184 504 320 + 1.5 · 184 504 320 = 461 260 800) and
    // wrapping THAT gives 92 252 160 — double the correct position.
    try testing.expectEqual(@as(i64, 92_252_160), @mod(try m.tickFromSeconds(3.5), 369_008_640));

    // Negative time wraps into [0, loop_secs) like the tick-domain @mod.
    try testing.expectEqual(@as(f64, 2.5), m.wrapSeconds(-0.5));

    // A loop with no length has nothing to wrap into: `@mod` by zero is
    // a NaN, so the seconds pass through instead.
    var zero = try zeroLengthMap(.loop);
    defer zero.deinit();
    try testing.expectEqual(@as(f64, 0), zero.map.loop_secs);
    try testing.expectEqual(@as(f64, 5), zero.map.wrapSeconds(5.0));
}

test "TimeMap: :end hold clamps at seconds(length)" {
    var r = try twoSegmentMap(.hold);
    defer r.deinit();
    const m = &r.map;

    try testing.expectEqual(@as(f64, 3), m.loop_secs);
    try testing.expectEqual(@as(f64, 3), m.wrapSeconds(5.0));
    try testing.expectEqual(@as(i64, 369_008_640), try m.tickFromSeconds(m.wrapSeconds(5.0)));
    // Below the edge nothing moves; a negative clock passes through the
    // clamp and meets `max(0, …)` in the conversion.
    try testing.expectEqual(@as(f64, 2.5), m.wrapSeconds(2.5));
    try testing.expectEqual(@as(f64, -1.5), m.wrapSeconds(-1.5));
    try testing.expectEqual(@as(i64, 0), try m.tickFromSeconds(m.wrapSeconds(-1.5)));

    // A hold clamps at whatever the length is, INCLUDING zero: a
    // timeline of no length holds every clock at its one tick.
    var zero = try zeroLengthMap(.hold);
    defer zero.deinit();
    try testing.expectEqual(@as(f64, 0), zero.map.loop_secs);
    try testing.expectEqual(@as(f64, 0), zero.map.wrapSeconds(5.0));
    try testing.expectEqual(@as(i64, 0), try zero.map.tickFromSeconds(zero.map.wrapSeconds(5.0)));
}

test "TimeMap.derive: a bar table past MAX_TICK is tick_overflow" {
    // `[64 1]` is the longest bar tempura can spell: 64 beats of 4/1
    // quarters = 256 quarters = 256 · TPQ = 11 808 276 480 ticks. With
    // MAX_TICK = 2^53 = 9 007 199 254 740 992,
    //   762 786 · 11 808 276 480 = 9 007 187 983 073 280 ≤ MAX_TICK
    //   762 787 · 11 808 276 480 = 9 007 199 791 349 760 >  MAX_TICK
    // so the table holds bars 0…762 786 — 762 787 entries — and stops
    // there however much more `:length` asks for. Past the ceiling is a
    // diagnostic, never a wrap (plan 03, "The grid").
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
    }, &.{
        .{ .tick = 0, .n = 64, .d = 1 },
    }, Grid.MAX_TICK + 1, .hold, null);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.diags.count(.tick_overflow));
    try testing.expectEqual(@as(usize, 762_787), r.map.bars.len);
    try testing.expectEqual(@as(i64, 9_007_187_983_073_280), r.map.bars[r.map.bars.len - 1]);
    try testing.expect(r.map.bars[r.map.bars.len - 1] + 11_808_276_480 > Grid.MAX_TICK);
}

test "TimeMap.derive: a tempo or meter point past the grid ceiling is tick_overflow and dropped" {
    // The ceiling itself is a position (`MAX_TICK` is the last tick the
    // grid names) and one past it is not. 48 818 366 bars of [4 4] is
    // the first bar line past the ceiling — the meter point sits on a
    // bar line, so the ceiling is the only thing wrong with it.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
        .{ .tick = Grid.MAX_TICK, .tempo = .{ .qpm = 240 } },
        .{ .tick = Grid.MAX_TICK + 1, .tempo = .{ .qpm = 60 }, .span = .{ .start = 3, .end = 9 } },
    }, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
        .{
            .tick = 48_818_366 * (4 * Grid.TPQ),
            .n = 3,
            .d = 4,
            .span = .{ .start = 12, .end = 20 },
        },
    }, 4 * Grid.TPQ, .hold, null);
    defer r.deinit();

    try testing.expect(48_818_366 * (4 * Grid.TPQ) > Grid.MAX_TICK);
    try testing.expectEqual(@as(usize, 2), r.diags.count(.tick_overflow));
    try testing.expectEqual(@as(u32, 3), r.diags.items()[0].span.start);
    try testing.expectEqual(@as(u32, 12), r.diags.items()[1].span.start);
    try testing.expectEqual(@as(usize, 2), r.map.segments.len);
    try testing.expectEqual(Grid.MAX_TICK, r.map.segments[1].tick);
    try testing.expectEqual(@as(usize, 1), r.map.meters.len);
}

test "TimeMap.tickFromSeconds: a non-finite clock is NonFiniteTime, a runaway one TickOverflow" {
    // A host clock is the one input that is neither the document's nor
    // the grid's, so these two are ERRORS and not diagnostics.
    var integral = try twoSegmentMap(.hold);
    defer integral.deinit();
    var floating = try threeSegmentMap();
    defer floating.deinit();
    try testing.expectEqual(true, integral.map.integral);
    try testing.expectEqual(false, floating.map.integral);

    for ([_]*const TimeMap{ &integral.map, &floating.map }) |m| {
        try testing.expectError(error.NonFiniteTime, m.tickFromSeconds(std.math.nan(f64)));
        try testing.expectError(error.NonFiniteTime, m.tickFromSeconds(std.math.inf(f64)));
        try testing.expectError(error.NonFiniteTime, m.tickFromSeconds(-std.math.inf(f64)));
        // 1e30 s is finite and so is the product, but the tick is 22
        // orders of magnitude past the ceiling.
        try testing.expectError(error.TickOverflow, m.tickFromSeconds(1e30));
        // 1e300 s overflows the product itself.
        try testing.expectError(error.TickOverflow, m.tickFromSeconds(1e300));
    }
}

test "TimeMap.tickFromLiteral: a bar, a beat and a seconds literal each resolve" {
    // The [3 4] → [4 4] map of the bar-table test, at 120 qpm (tps
    // 92 252 160). Bars 0 and 1 are 3 · TPQ = 138 378 240 ticks and carry
    // beats 0…5; bar 2 starts at 276 756 480 and is 4 · TPQ long.
    var r = try meterChangeMap();
    defer r.deinit();
    const m = &r.map;

    // `bar`: the integer part through the bar table, the fraction scaled
    // by THAT bar's length and rounded half to even by the one shared
    // seam. Bar 1 starts at 138 378 240 and is 3 quarters long, so
    // 1.5bar = 138 378 240 + round(1.5q) = 138 378 240 + 69 189 120.
    try testing.expectEqual(
        @as(i64, 207_567_360),
        (try m.tickFromLiteral(.{ .value = 1.5, .unit = .bar })).tick,
    );
    try testing.expectEqual(
        @as(i64, 276_756_480),
        (try m.tickFromLiteral(.{ .value = 2, .unit = .bar })).tick,
    );
    // Past the table's last bar (6, at :length) the last meter carries
    // on: bar 7 = 1 014 773 760 + 184 504 320.
    try testing.expectEqual(
        @as(i64, 1_199_278_080),
        (try m.tickFromLiteral(.{ .value = 7, .unit = .bar })).tick,
    );

    // `b`: beats counted from 0 ACROSS the map. Beat 3 is bar 1's first
    // beat (138 378 240); beat 6 is bar 2's (276 756 480); beat 7.5 is
    // 276 756 480 + 1 · 46 126 080 + round(0.5q) = 345 945 600.
    try testing.expectEqual(
        @as(i64, 138_378_240),
        (try m.tickFromLiteral(.{ .value = 3, .unit = .b })).tick,
    );
    try testing.expectEqual(
        @as(i64, 276_756_480),
        (try m.tickFromLiteral(.{ .value = 6, .unit = .b })).tick,
    );
    try testing.expectEqual(
        @as(i64, 345_945_600),
        (try m.tickFromLiteral(.{ .value = 7.5, .unit = .b })).tick,
    );

    // `s`: through the tempo map, 2.5 · 92 252 160.
    try testing.expectEqual(
        @as(i64, 230_630_400),
        (try m.tickFromLiteral(.{ .value = 2.5, .unit = .s })).tick,
    );

    // `q` and `t` still answer from the grid alone (`Pos`'s own seam).
    try testing.expectEqual(
        @as(i64, 138_378_240),
        (try m.tickFromLiteral(.{ .value = 3, .unit = .q })).tick,
    );
    try testing.expectEqual(
        @as(i64, 12_345),
        (try m.tickFromLiteral(.{ .value = 12_345, .unit = .t })).tick,
    );

    // A negative position is a diagnostic in every unit.
    try testing.expectEqual(
        Diag.Code.position_negative,
        (try m.tickFromLiteral(.{ .value = -1, .unit = .bar })).err,
    );
    try testing.expectEqual(
        Diag.Code.position_negative,
        (try m.tickFromLiteral(.{ .value = -0.5, .unit = .b })).err,
    );
    try testing.expectEqual(
        Diag.Code.position_negative,
        (try m.tickFromLiteral(.{ .value = -2, .unit = .s })).err,
    );
}

test "TimeMap.tickFromLiteral: a frame literal with no rate is frame_rate_missing" {
    // No map can resolve a frame without the document's declared `:fps`
    // — there is no default rate to guess with — so the refusal is the
    // answer whatever the literal says.
    var r = try meterChangeMap();
    defer r.deinit();
    const m = &r.map;

    try testing.expectEqual(
        Diag.Code.frame_rate_missing,
        (try m.tickFromLiteral(.{ .value = 25, .unit = .f })).err,
    );
    try testing.expectEqual(
        Diag.Code.frame_rate_missing,
        (try m.tickFromLiteral(.{ .value = 0, .unit = .f })).err,
    );
    try testing.expectEqual(
        Diag.Code.frame_rate_missing,
        (try m.durationTicks(.{ .value = 25, .unit = .f }, 0)).err,
    );
}

test "TimeMap.tickFromLiteral: frames at the declared rate" {
    // :qpm 300 is us 200 000 — an integer, so the integral path — and
    // tps 230 630 400 (768 768 · 300). A frame at 25 fps is 1/25 s =
    // 9 225 216 ticks exactly; a second is 25 of them.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 300 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 25, .den = 1 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    try testing.expectEqual(
        @as(i64, 0),
        (try m.tickFromLiteral(.{ .value = 0, .unit = .f })).tick,
    );
    try testing.expectEqual(
        @as(i64, 9_225_216),
        (try m.tickFromLiteral(.{ .value = 1, .unit = .f })).tick,
    );
    try testing.expectEqual(
        @as(i64, 23_063_040),
        (try m.tickFromLiteral(.{ .value = 2.5, .unit = .f })).tick,
    );
    try testing.expectEqual(
        @as(i64, 184_504_320),
        (try m.tickFromLiteral(.{ .value = 20, .unit = .f })).tick,
    );
    try testing.expectEqual(
        @as(i64, 230_630_400),
        (try m.tickFromLiteral(.{ .value = 25, .unit = .f })).tick,
    );
    // Every one of them lands on a tick start at this tempo, so each is
    // exact and the frame-line test names the frame itself.
    try testing.expectEqual(@as(?i64, 20), m.frameLine(184_504_320));
    try testing.expectEqual(@as(?i64, null), m.frameLine(184_504_321));
}

test "TimeMap.tickFromLiteral: an off-grid frame is floored and said" {
    // NTSC `[30000 1001]` at the same tempo: frame 1's instant is
    // 1001/30000 s, which at tps 230 630 400 is 7 695 367.68 ticks —
    // between two. The clock floor answers the tick beneath, the seam
    // read back says the frame landed on no tick start, and the `inexact`
    // payload is the floored tick that stands — never a wrap, never a
    // round to nearest.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 300 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 30000, .den = 1001 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    // Frame 0 is tick 0, exact.
    try testing.expectEqual(
        @as(i64, 0),
        (try m.tickFromLiteral(.{ .value = 0, .unit = .f })).tick,
    );
    const one = try m.tickFromLiteral(.{ .value = 1, .unit = .f });
    try testing.expectEqual(@as(i64, 7_695_367), one.inexact);
    // The floored tick is refused by the frame-line test: it is not any
    // frame's start at this rate.
    try testing.expectEqual(@as(?i64, null), m.frameLine(7_695_367));
}

test "TimeMap.tickFromLiteral: NTSC frames land where the rational puts them" {
    // Plan 03's historic T2 bullet said "29.97 and 23.976 never land",
    // and the truth is finer: at :qpm 300 (tps 230 630 400) a
    // `[30000 1001]` frame is 192 384 192/25 ticks, so every 25th frame
    // IS a tick start — frame 25 is tick 192 384 192 exactly — and a
    // `[24000 1001]` frame is 48 096 048/5, so every 5th one is (frame
    // 5 is tick 48 096 048). Frame 1 of the NTSC pair stays between
    // ticks, floored and said, as the test above pins.
    var ntsc = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 300 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 30000, .den = 1001 },
        .wrote = true,
    });
    defer ntsc.deinit();

    switch (try ntsc.map.tickFromLiteral(.{ .value = 25, .unit = .f })) {
        .tick => |t| try testing.expectEqual(@as(i64, 192_384_192), t),
        .inexact => return error.TestExactFrameSaidInexact,
        .err => return error.TestFrameRefused,
    }
    try testing.expectEqual(@as(?i64, 25), ntsc.map.frameLine(192_384_192));

    var film = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 300 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 24000, .den = 1001 },
        .wrote = true,
    });
    defer film.deinit();
    switch (try film.map.tickFromLiteral(.{ .value = 5, .unit = .f })) {
        .tick => |t| try testing.expectEqual(@as(i64, 48_096_048), t),
        .inexact => return error.TestExactFrameSaidInexact,
        .err => return error.TestFrameRefused,
    }
}

test "TimeMap.tickFromLiteral: an exact frame is its tick, not one the f64 chain shorted" {
    // The plainest case of the defect this map no longer has: at 120
    // qpm (us 500 000, the fallback tempo) with :fps 25, frame 35 is
    // 1.4 s = 129 153 024 ticks exactly (1.4 · 92 252 160). The f64
    // chain floors it one short — fl(1.4) is BELOW 1.4, the product's
    // own rounding does not buy it back, and the floor answers
    // 129 153 023 — and then reads its landing back as "between ticks".
    // The exact path answers the tick the rational names, the frame
    // line names frame 35 for it, and the printer spells it.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 25, .den = 1 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    switch (try m.tickFromLiteral(.{ .value = 35, .unit = .f })) {
        .tick => |t| try testing.expectEqual(@as(i64, 129_153_024), t),
        .inexact => return error.TestExactFrameSaidInexact,
        .err => return error.TestFrameRefused,
    }
    try testing.expectEqual(@as(?i64, 35), m.frameLine(129_153_024));

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try m.spell(&w, 129_153_024);
    try testing.expectEqualStrings("35f", w.buffered());

    // A tick between frames has NO f spelling under the exact rule —
    // not the long decimal that once collided back inside one ulp —
    // so the printer falls through to the grid's own spellings.
    w = std.Io.Writer.fixed(&buf);
    try m.spell(&w, 129_153_025);
    try testing.expect(!std.mem.endsWith(u8, w.buffered(), "f"));
}

test "TimeMap.durationTicks: an f duration's exactness is not the float sum's" {
    // The observed defect, with its own arithmetic: :fps 25 at :qpm 300,
    // `:at 20f :dur 1f`. Twenty frames is 0.8 s — tick 184 504 320,
    // whose seconds are not dyadic — and one frame more is 21/25 s =
    // 193 729 536 exactly ((21/25) · 5 · TPQ), so the duration is one
    // frame, 9 225 216 ticks. The float `want` (fl(0.8) + fl(0.04))
    // and the read-back (fl(0.84)) differ by an ulp and the verdict
    // said `frame_inexact`; the exact judgment says what is true.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 300 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 25, .den = 1 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    switch (try m.durationTicks(.{ .value = 1, .unit = .f }, 184_504_320)) {
        .tick => |d| try testing.expectEqual(@as(i64, 9_225_216), d),
        .inexact => return error.TestExactFrameSaidInexact,
        .err => return error.TestDurationRefused,
    }
    // A HALF frame is exact the same way: 2.5 frames is 0.1 s =
    // 23 063 040 ticks from anywhere.
    switch (try m.durationTicks(.{ .value = 2.5, .unit = .f }, 184_504_320)) {
        .tick => |d| try testing.expectEqual(@as(i64, 23_063_040), d),
        .inexact => return error.TestExactFrameSaidInexact,
        .err => return error.TestDurationRefused,
    }
    // And `spellDuration` prints the frame count both ends are — the
    // float sum once dropped this to the delta's own `q` spelling.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try m.spellDuration(&w, 9_225_216, 184_504_320);
    try testing.expectEqualStrings("1f", w.buffered());
}

test "TimeMap.tickFromLiteral: a wide-shift frame leaves its anchor's tick exactly as the rate says" {
    // The finding-1 map: :fps [1 100] under :us 1, where a frame is
    // 100 s and one tick is us/(TPQ · 1e6) s = 1/(46 126 080 · 1e6) s
    // ≈ 2.17e-14 s. A 2e-15f literal is 2e-13 s = 9.225216 ticks —
    // NINE ticks past tick 0 — yet its shift (101) sat past the old
    // 100-shift cutoff, and the anchor was answered instead: a silent
    // nine-tick misplacement inside the schema's legal extremes, while
    // the same instant by the clock (`--seconds 2e-13`) said 9. The
    // two-arm test asks the rate and the segment instead of the
    // exponent: 9.225216 ≥ one tick, so not tiny.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 1 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 1, .den = 100 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    switch (try m.tickFromLiteral(.{ .value = 2e-15, .unit = .f })) {
        .tick => return error.TestInexactFrameSaidExact,
        .inexact => |t| try testing.expectEqual(@as(i64, 9), t),
        .err => return error.TestFrameRefused,
    }
    // The seam neighbour, green before and after: 5e-15f is shift 100,
    // the widest the old cutoff walked, and 23.0632 ticks — the exact
    // path's old working band must keep answering it.
    switch (try m.tickFromLiteral(.{ .value = 5e-15, .unit = .f })) {
        .tick => return error.TestInexactFrameSaidExact,
        .inexact => |t| try testing.expectEqual(@as(i64, 23), t),
        .err => return error.TestFrameRefused,
    }
    // The arm-B boundary, both sides of one tick: a tick is 2^-52.04
    // frames here, so 2e-16f (0.9225 ticks) stays inside the anchor's
    // own tick, and 2.5e-16f (1.1531 ticks) is the FIRST tick past it
    // — a shift-104 literal the cutoff collapsed to 0.
    switch (try m.tickFromLiteral(.{ .value = 2e-16, .unit = .f })) {
        .tick => return error.TestInexactFrameSaidExact,
        .inexact => |t| try testing.expectEqual(@as(i64, 0), t),
        .err => return error.TestFrameRefused,
    }
    switch (try m.tickFromLiteral(.{ .value = 2.5e-16, .unit = .f })) {
        .tick => return error.TestInexactFrameSaidExact,
        .inexact => |t| try testing.expectEqual(@as(i64, 1), t),
        .err => return error.TestFrameRefused,
    }
    // Genuinely tiny stays tiny: 1e-30f is 4.6e-15 ticks (arm A, its
    // shift 152 cannot hold any denominator), and the smallest
    // denormal 5e-324f (shift 1074) falls to the same arm.
    switch (try m.tickFromLiteral(.{ .value = 1e-30, .unit = .f })) {
        .tick => return error.TestInexactFrameSaidExact,
        .inexact => |t| try testing.expectEqual(@as(i64, 0), t),
        .err => return error.TestFrameRefused,
    }
    switch (try m.tickFromLiteral(.{ .value = 5e-324, .unit = .f })) {
        .tick => return error.TestInexactFrameSaidExact,
        .inexact => |t| try testing.expectEqual(@as(i64, 0), t),
        .err => return error.TestFrameRefused,
    }
}

test "TimeMap.durationTicks: a frame duration the shift cutoff collapsed spans its true ticks" {
    // The same map's sounding collapse: a note at 1q (tick 46 126 080)
    // with :dur 2e-15f spans 9.225216 ticks — the cutoff answered
    // span 0 and the note's sounding line vanished, while a nonzero
    // duration IS listed at its onset tick (the frames-25 control).
    // The floor is 9 ticks past the anchor, inexact, standing.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 1 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 1, .den = 100 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    switch (try m.durationTicks(.{ .value = 2e-15, .unit = .f }, 46_126_080)) {
        .tick => return error.TestInexactDurationSaidExact,
        .inexact => |d| try testing.expectEqual(@as(i64, 9), d),
        .err => return error.TestDurationRefused,
    }
    // From tick 0 the same span: nine ticks, not the anchor.
    switch (try m.durationTicks(.{ .value = 2e-15, .unit = .f }, 0)) {
        .tick => return error.TestInexactDurationSaidExact,
        .inexact => |d| try testing.expectEqual(@as(i64, 9), d),
        .err => return error.TestDurationRefused,
    }
}

test "TimeMap.durationTicks: a frame from a segment's last tick floors at the segment it reaches" {
    // Crossing: :us 1 changes to :us 16 777 215 at tick 1000, and the
    // anchor is 999 — the last tick of the fast segment. The 2e-15f
    // instant is 9.225216 fast-segment ticks past it, past the change
    // (origin 1000), and 8.225 units into the slow segment's FIRST
    // tick (a whole 16 777 215 units wide) — so the floor is tick
    // 1000, a span of 1, inexact. The cutoff answered 0 without
    // looking; a next segment anywhere cannot move a floor that is
    // computed from the instant itself.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 1 } },
        .{ .tick = 1000, .tempo = .{ .us = 16_777_215 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 1, .den = 100 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    switch (try m.durationTicks(.{ .value = 2e-15, .unit = .f }, 999)) {
        .tick => return error.TestInexactDurationSaidExact,
        .inexact => |d| try testing.expectEqual(@as(i64, 1), d),
        .err => return error.TestDurationRefused,
    }
    // Crossing-adjacent, green before and after: 1e-16f from the same
    // anchor is 0.4613 fast-segment ticks — strictly inside the
    // anchor's own tick — so the answer IS the anchor, span 0,
    // whatever the next segment's width.
    switch (try m.durationTicks(.{ .value = 1e-16, .unit = .f }, 999)) {
        .tick => return error.TestInexactDurationSaidExact,
        .inexact => |d| try testing.expectEqual(@as(i64, 0), d),
        .err => return error.TestDurationRefused,
    }
}

test "TimeMap.tickFromLiteral: schema extremes — the r_num ceiling and the 127-bit denominator" {
    // The widest products the exact path can form, pinned at both
    // schema ceilings. :fps [1 16 777 215] under :us 16 777 215: a
    // 1e-11f literal's r_num is 122 bits (the envelope's 2^123
    // ceiling, a hair under it), and its instant is 461.2608 ticks —
    // one tick is us/TPQ µs and the 16 777 215s cancel — floored to
    // 461, inexact.
    var wide = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 16_777_215 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 1, .den = 16_777_215 },
        .wrote = true,
    });
    defer wide.deinit();

    switch (try wide.map.tickFromLiteral(.{ .value = 1e-11, .unit = .f })) {
        .tick => return error.TestInexactFrameSaidExact,
        .inexact => |t| try testing.expectEqual(@as(i64, 461), t),
        .err => return error.TestFrameRefused,
    }

    // :fps [16 777 215 1]: num is odd and 24 bits wide. A shift-103
    // literal's r_den = 16 777 215 · 2^103 is 127 bits — the widest
    // that fits i128 — and arm B compares against it without ever
    // forming it; a shift-104 one (r_den 128 bits) is arm A, answered
    // without the shift a naive `num << shift` would wrap. Both
    // instants are truly tiny — under 2^-29 of the anchor's own tick
    // — so the anchor, inexact, is the true answer from both arms.
    var odd = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 1 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 16_777_215, .den = 1 },
        .wrote = true,
    });
    defer odd.deinit();

    switch (try odd.map.tickFromLiteral(.{ .value = 5e-16, .unit = .f })) {
        .tick => return error.TestInexactFrameSaidExact,
        .inexact => |t| try testing.expectEqual(@as(i64, 0), t),
        .err => return error.TestFrameRefused,
    }
    switch (try odd.map.tickFromLiteral(.{ .value = 2.5e-16, .unit = .f })) {
        .tick => return error.TestInexactFrameSaidExact,
        .inexact => |t| try testing.expectEqual(@as(i64, 0), t),
        .err => return error.TestFrameRefused,
    }
    // The huge arm is untouched: 2^127 frames is past every grid.
    switch (try odd.map.tickFromLiteral(.{ .value = 0x1p127, .unit = .f })) {
        .tick, .inexact => return error.TestHugeFrameLanded,
        .err => |c| switch (c) {
            .tick_overflow => {},
            else => return error.TestWrongCode,
        },
    }
}

test "TimeMap.durationTicks: the walk's compare never wraps at the envelope's edge" {
    // The hardened compare's own case, built at the envelope's edge:
    // the anchor is 4 400 000 000 000 000 ticks into the map's SECOND
    // :us 1 segment (origin 10 000 000 000 000 000), a third segment
    // follows at 4 600 000 000 000 000, rate [1 16 777 215], literal
    // 0x1.8p-23 (shift 75, p = 3 · 2^51). Walking down, the anchor's
    // own iteration has dt = d · r_den at 127 bits — it fits — but
    // dt + r_num is one bit past 2^127: the wrapped sum reads
    // negative, "not reached", and the walk would run past the
    // segment table's floor. The sign-split compare never sums:
    // dt ≥ 0 reaches.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 1 } },
        .{ .tick = 10_000_000_000_000, .tempo = .{ .us = 1 } },
        .{ .tick = 4_600_000_000_000_000, .tempo = .{ .us = 1 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 1, .den = 16_777_215 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    // The instant is the literal's 138 378 231 752 014.7 tick-widths
    // into a segment whose ticks are 1 unit wide: floored to 138 378
    // 231 752 014 ticks past the anchor, inexact (the .7 tail).
    switch (try m.durationTicks(.{ .value = 0x1.8p-23, .unit = .f }, 4_410_000_000_000_000)) {
        .tick => return error.TestInexactDurationSaidExact,
        .inexact => |d| try testing.expectEqual(@as(i64, 138_378_231_752_014), d),
        .err => return error.TestDurationRefused,
    }
}

test "TimeMap.durationTicks: an f duration anchors at its form's :at" {
    // 120 qpm doubling to 240 at 4q (tick 184 504 320, exactly 2 s): a
    // second of wall clock is 92 252 160 ticks before the change and
    // 184 504 320 after it. A 25-frame duration (one second at 25 fps)
    // measured from an `:at` before the change is two quarters; from the
    // change itself, four — the anchor's tempo, not the origin's.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
        .{ .tick = 184_504_320, .tempo = .{ .qpm = 240 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 25, .den = 1 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    try testing.expectEqual(
        @as(i64, 92_252_160),
        (try m.durationTicks(.{ .value = 25, .unit = .f }, 0)).tick,
    );
    try testing.expectEqual(
        @as(i64, 184_504_320),
        (try m.durationTicks(.{ .value = 25, .unit = .f }, 184_504_320)).tick,
    );
    // A quarter of a second (6.25 frames) from the change is a quarter
    // of its four quarters — one quarter, exact.
    try testing.expectEqual(
        @as(i64, Grid.TPQ),
        (try m.durationTicks(.{ .value = 6.25, .unit = .f }, 184_504_320)).tick,
    );
}

test "TimeMap: the f64 path's frame seam is deterministic" {
    // :qpm 143 makes us = 60e6/143 — not a whole number — so the map
    // takes the f64 path, where a frame's answer is only as good as the
    // op order. Determinism is the claim (plan 03: same document + same
    // f64 ⇒ same tick): two independent derives agree, tag for tag and
    // payload for payload, and the frame-line test answers exactly what
    // the literal's own read-back said.
    const tempo = [_]TempoPoint{.{ .tick = 0, .tempo = .{ .qpm = 143 } }};
    const meter = [_]MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const frames: Frames = .{ .rate = .{ .num = 25, .den = 1 }, .wrote = true };

    var a = try derive(testing.allocator, &tempo, &meter, 0, .hold, frames);
    defer a.deinit();
    var b = try derive(testing.allocator, &tempo, &meter, 0, .hold, frames);
    defer b.deinit();
    try testing.expectEqual(false, a.map.integral);

    for (0..1_000) |i| {
        const n: f64 = @floatFromInt(i);
        const x = try a.map.tickFromLiteral(.{ .value = n, .unit = .f });
        const y = try b.map.tickFromLiteral(.{ .value = n, .unit = .f });
        const exact = switch (x) {
            .tick => true,
            .inexact => false,
            .err => return error.TestFrameSeamRefused,
        };
        const tick = switch (x) {
            .tick => |t| t,
            .inexact => |t| t,
            .err => return error.TestFrameSeamRefused,
        };
        try testing.expectEqual(std.meta.activeTag(x), std.meta.activeTag(y));
        try testing.expectEqual(tick, switch (y) {
            .tick => |t| t,
            .inexact => |t| t,
            .err => return error.TestFrameSeamRefused,
        });
        // The frame-line test agrees with the literal's own exactness:
        // an exact frame reads back as the very frame that named it, an
        // off-grid one is refused — the printer's fall-through rule.
        const line: ?i64 = if (exact) @intCast(i) else null;
        try testing.expectEqual(line, a.map.frameLine(tick));
    }
}

test "TimeMap.spell: the printer's rule, with this map's bar table" {
    var r = try meterChangeMap();
    defer r.deinit();
    const m = &r.map;

    // A bar line prints as `Nbar` — bar 2 starts at 276 756 480.
    // One quarter is 46 126 080 = 9009 · 5120, no bar line here but an
    // exact short decimal in quarters, so `1q`. Tick 1 is neither.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try m.spell(&w, 276_756_480);
    try testing.expectEqualStrings("2bar", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try m.spell(&w, 46_126_080);
    try testing.expectEqualStrings("1q", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try m.spell(&w, 69_189_120);
    try testing.expectEqualStrings("1.5q", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try m.spell(&w, 1);
    try testing.expectEqualStrings("1t", w.buffered());

    // A bar line past the bar table spells as a bar, not as the 26
    // quarters it also is: this fixture ends at bar 6 and bar 7 starts at
    // 1 014 773 760 + 184 504 320 = 1 199 278 080.
    w = std.Io.Writer.fixed(&buf);
    try m.spell(&w, 1_199_278_080);
    try testing.expectEqualStrings("7bar", w.buffered());
    // And the literal that named it reads back to the same tick.
    try testing.expectEqual(
        @as(i64, 1_199_278_080),
        (try m.tickFromLiteral(.{ .value = 7, .unit = .bar })).tick,
    );
}

test "TimeMap.spell: spell ∘ parse is the identity in a document that wrote frames" {
    // The `Pos.zig` fixed-point property at MAP level, in a document
    // that wrote frames: whatever `spell` prints for a tick — `Nf` on a
    // frame line, else `Nbar` / `Nq` / `Nt` — parses back and resolves
    // through this map as the SAME tick, and spelling it again gives the
    // same text. The `f` branch is emission-checked (a frame prints only
    // when it resolves exactly back), so the property cannot fail from a
    // fired branch; the count proves the branch really fires.
    //
    // Both regimes: the integral path (`:qpm 300`, us 200 000, a frame
    // at 25 fps exactly 9 225 216 ticks) and the f64 path (`:qpm 143`,
    // where almost no frame lands and the honest spellings fall through).
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const rand = prng.random();

    var integral = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 300 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 25, .den = 1 },
        .wrote = true,
    });
    defer integral.deinit();
    try testing.expect(integral.map.integral);

    var floating = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 143 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 25, .den = 1 },
        .wrote = true,
    });
    defer floating.deinit();
    try testing.expect(!floating.map.integral);

    var buf: [64]u8 = undefined;
    var again: [64]u8 = undefined;
    var f_spellings: usize = 0;
    for ([_]*const TimeMap{ &integral.map, &floating.map }) |m| {
        for (0..2_000) |i| {
            // Four regimes: anywhere on the grid; a frame literal this
            // map resolves (exact or floored — the tick is the thing the
            // property spells either way); the `9009` lattice; a bar.
            const k = switch (i % 4) {
                0 => rand.intRangeAtMost(i64, 0, Grid.MAX_TICK),
                1 => lit: {
                    const lit: Pos.Literal = .{
                        .value = @floatFromInt(rand.intRangeAtMost(u32, 0, 100_000)),
                        .unit = .f,
                    };
                    break :lit switch (try m.tickFromLiteral(lit)) {
                        .tick => |t| t,
                        .inexact => |t| t,
                        .err => continue,
                    };
                },
                2 => 9009 * rand.intRangeAtMost(i64, 0, @divFloor(Grid.MAX_TICK, 9009)),
                else => lit: {
                    const lit: Pos.Literal = .{
                        .value = @floatFromInt(rand.intRangeAtMost(i64, 0, 1 << 20)),
                        .unit = .bar,
                    };
                    break :lit switch (try m.tickFromLiteral(lit)) {
                        .tick => |t| t,
                        .inexact => |t| t,
                        .err => continue,
                    };
                },
            };
            var w = std.Io.Writer.fixed(&buf);
            try m.spell(&w, k);
            const text = w.buffered();
            if (m == &integral.map and std.mem.endsWith(u8, text, "f")) f_spellings += 1;

            const back_lit = switch (Pos.parse(text)) {
                .ok => |l| l,
                .err => |code| {
                    std.debug.print("tick {d} spelled {s}: {t}\n", .{ k, text, code });
                    return error.TestSpellingDoesNotParse;
                },
            };
            const back = switch (try m.tickFromLiteral(back_lit)) {
                .tick => |t| t,
                .inexact => |t| t,
                .err => |code| {
                    std.debug.print("tick {d} spelled {s}: {t}\n", .{ k, text, code });
                    return error.TestSpellingDoesNotResolve;
                },
            };
            if (back != k) {
                std.debug.print("tick {d} spelled {s} reads {d}\n", .{ k, text, back });
                return error.TestRoundTripDrifted;
            }
            // And the print of the print is the same text — a fixed point.
            var w2 = std.Io.Writer.fixed(&again);
            try m.spell(&w2, back);
            try testing.expectEqualStrings(text, w2.buffered());
        }
    }
    // The `f` branch really fired — a printer that never spells frames
    // passes every clause above vacuously.
    try testing.expect(f_spellings > 50);
}

test "TimeMap: durationTicks(spellDuration(d, at), at) is d, across a tempo change, in frames" {
    // The duration twin of the property above, on the printer's own
    // fixture: 120 qpm doubling to 240 at 4q, with `:fps 5` declared and
    // written — a rate whose frames land on tick starts in BOTH segments
    // (92 252 160 / 5 = 18 450 432 and 184 504 320 / 5 = 36 900 864), so
    // a duration measured across the change in frames is exactly the
    // frame count between its ends, and reads back as itself.
    var r = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
        .{ .tick = 184_504_320, .tempo = .{ .qpm = 240 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, .{
        .rate = .{ .num = 5, .den = 1 },
        .wrote = true,
    });
    defer r.deinit();
    const m = &r.map;

    var buf: [64]u8 = undefined;
    // The pinned pair: frame 1 (0.2 s = 18 450 432) to frame 11
    // (2.2 s = 184 504 320 + 36 900 864), ten frames across the change.
    var w = std.Io.Writer.fixed(&buf);
    try m.spellDuration(&w, 221_405_184 - 18_450_432, 18_450_432);
    try testing.expectEqualStrings("10f", w.buffered());
    try testing.expectEqual(
        @as(i64, 221_405_184 - 18_450_432),
        (try m.durationTicks(.{ .value = 10, .unit = .f }, 18_450_432)).tick,
    );

    // The property, over drawn frame pairs: whatever spelling
    // `spellDuration` chooses — `Nf` when both ends are frame lines,
    // else `Nbar` / `Nq` / `Nt` — resolves from the same anchor as the
    // same duration. The draws stay inside 180 s, where this fixture's
    // integer origins are still exact in f64 and the frame seam can
    // fire; past it the honest spellings fall through and the property
    // covers those too.
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const rand = prng.random();
    var f_spellings: usize = 0;
    for (0..2_000) |_| {
        const f0 = rand.intRangeAtMost(u32, 0, 850);
        const f1 = f0 + rand.intRangeAtMost(u32, 1, 900 -| f0);
        const at = switch (try m.tickFromLiteral(.{ .value = @floatFromInt(f0), .unit = .f })) {
            .tick => |t| t,
            .inexact => |t| t,
            .err => continue,
        };
        // Every frame is 18 450 432 or 36 900 864 ticks at this rate
        // (both integers), so EVERY drawn pair is a pair of tick starts
        // and the exactness claim has teeth: an `inexact` payload here
        // is the claim failing, not another tick to read through.
        const d = switch (try m.durationTicks(
            .{ .value = @floatFromInt(f1 - f0), .unit = .f },
            at,
        )) {
            .tick => |t| t,
            .inexact => return error.TestExactDurationSaidInexact,
            .err => continue,
        };
        var w2 = std.Io.Writer.fixed(&buf);
        try m.spellDuration(&w2, d, at);
        const text = w2.buffered();
        if (std.mem.endsWith(u8, text, "f")) f_spellings += 1;

        const lit = switch (Pos.parse(text)) {
            .ok => |l| l,
            .err => |code| {
                std.debug.print("dur {d} at {d} spelled {s}: {t}\n", .{ d, at, text, code });
                return error.TestSpellingDoesNotParse;
            },
        };
        const back = switch (try m.durationTicks(lit, at)) {
            .tick => |t| t,
            .inexact => |t| t,
            .err => |code| {
                std.debug.print("dur {d} at {d} spelled {s}: {t}\n", .{ d, at, text, code });
                return error.TestSpellingDoesNotResolve;
            },
        };
        if (back != d) {
            std.debug.print("dur {d} at {d} spelled {s} spans {d}\n", .{ d, at, text, back });
            return error.TestDurationRoundTripDrifted;
        }
    }
    try testing.expect(f_spellings > 50);
}

test "TimeMap.echo: the canonical text of a map, floats as bit patterns" {
    var r = try twoSegmentMap(.loop);
    defer r.deinit();

    // Every float below is hand-assembled from its IEEE-754 fields.
    //   92 252 160 = 2^26 · 1.374694824218750: exponent 1023 + 26 = 1049
    //     = 0x419, mantissa 0.37469482421875 · 2^52 = 0x5FEA000000000
    //     → 0x4195FEA000000000
    //   184 504 320 is twice that, so only the exponent moves, to 0x41A
    //     → 0x41A5FEA000000000
    //   0 → 0x0000000000000000, 2 → 0x4000000000000000,
    //   3 → 0x4008000000000000 (1.5 · 2^1)
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.map.echo(&w);
    try testing.expectEqualStrings(
        \\(segment :tick 0 :us 500000 :tps "4195FEA000000000" :start-sec "0000000000000000")
        \\(segment :tick 184504320 :us 250000 :tps "41A5FEA000000000" :start-sec "4000000000000000")
        \\(meter :tick 0 :sig [4 4] :first-bar 0)
        \\(bars :count 3 :last-start 369008640)
        \\(length :tick 369008640 :end loop :loop-secs "4008000000000000")
        \\
    , w.buffered());
}

test "TimeMap.derive: a tempo point at tick 0 that names no tempo still leaves a segment there" {
    // `:us 0` is not a tempo, so the point is dropped with its own
    // diagnostic — and the fallback segment has to take tick 0 anyway.
    // Without it the table would be EMPTY and `derive` itself would read
    // past its end computing `loop_secs`.
    var lone = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .us = 0 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, null);
    defer lone.deinit();
    try testing.expectEqual(@as(usize, 1), lone.diags.count(.tempo_map_invalid));
    try testing.expectEqual(@as(usize, 1), lone.map.segments.len);
    try testing.expectEqual(@as(i64, 0), lone.map.segments[0].tick);
    try testing.expectEqual(@as(f64, 500_000), lone.map.segments[0].us);
    try testing.expectEqual(@as(f64, 0), lone.map.secondsFromTick(0));

    // The same with a usable point after it: the fallback holds tick 0,
    // so the map still starts where the timeline does — 184 504 320 ticks
    // at 500 000 µs per quarter note is 2 s, the second segment's origin.
    var then_good = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 0 } },
        .{ .tick = 184_504_320, .tempo = .{ .us = 400_000 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 184_504_320, .hold, null);
    defer then_good.deinit();
    try testing.expectEqual(@as(usize, 1), then_good.diags.count(.tempo_map_invalid));
    try testing.expectEqual(@as(usize, 2), then_good.map.segments.len);
    try testing.expectEqual(@as(i64, 0), then_good.map.segments[0].tick);
    try testing.expectEqual(@as(f64, 0), then_good.map.secondsFromTick(0));
    try testing.expectEqual(@as(i64, 0), try then_good.map.tickFromSeconds(0));
    try testing.expectEqual(@as(f64, 2), then_good.map.segments[1].start_sec);
    try testing.expectEqual(@as(f64, 2), then_good.map.loop_secs);

    // A NaN and a negative `:qpm` are the same non-tempo, and the map is
    // still built around them.
    var not_numbers = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = std.math.nan(f64) } },
        .{ .tick = 46_126_080, .tempo = .{ .qpm = -120 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 0, .hold, null);
    defer not_numbers.deinit();
    try testing.expectEqual(@as(usize, 2), not_numbers.diags.count(.tempo_map_invalid));
    try testing.expectEqual(@as(usize, 1), not_numbers.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), not_numbers.map.segments[0].us);
}

test "TimeMap.derive: a whole-microsecond us too wide for the i128 origins takes the f64 path" {
    // `:qpm 1e-30` is 6e37 microseconds per quarter note — a whole
    // number, as every float that large is, and one the schema refuses
    // (`qpm-value` is 1..1000) while the reader keeps it. The integer
    // path's `Σ Δtick · us` overflowed i128 on the second point and
    // trapped `fromSource` itself; a `us` at or past `MAX_INTEGRAL_US`
    // now sends the table down the f64 path, where a slow tempo is only
    // a small rate.
    var wide = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 1e-30 } },
        .{ .tick = Grid.TPQ, .tempo = .{ .qpm = 120 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 8 * Grid.TPQ, .hold, null);
    defer wide.deinit();
    try testing.expectEqual(false, wide.map.integral);
    try testing.expectEqual(@as(usize, 2), wide.map.segments.len);
    try testing.expect(wide.map.segments[0].us >= MAX_INTEGRAL_US);
    try testing.expect(std.math.isFinite(wide.map.loop_secs));
    try testing.expectEqual(@as(i64, 0), try wide.map.tickFromSeconds(0));
    // A segment start is still exact by construction — the one claim the
    // f64 path makes about a table whose first segment is 6e31 s long.
    try testing.expectEqual(
        @as(i64, Grid.TPQ),
        try wide.map.tickFromSeconds(wide.map.segments[1].start_sec),
    );

    // Inside the bound the path is still the integer one: `:qpm 1e-10`
    // is 6e17 microseconds, under 2^63, and `TPQ · 6e17` is 2.8e25 —
    // well inside i128, and the undivided origin of the second segment.
    var narrow = try derive(testing.allocator, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 1e-10 } },
        .{ .tick = Grid.TPQ, .tempo = .{ .qpm = 120 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 8 * Grid.TPQ, .hold, null);
    defer narrow.deinit();
    try testing.expectEqual(true, narrow.map.integral);
    const us_0: i128 = @intFromFloat(narrow.map.segments[0].us);
    try testing.expect(us_0 < 1 << 63);
    try testing.expectEqual(us_0 * Grid.TPQ, narrow.map.segments[1].t_i);
}

// ---------------------------------------------------------------------
// Durations: measured from the form's own `:at` (plan 03, "Positions")
// ---------------------------------------------------------------------

/// A `[3 4]` map that turns `[4 4]` on bar 2 — the smallest fixture in
/// which a duration's anchor is visible at all.
fn threeThenFour(gpa: std.mem.Allocator) error{OutOfMemory}!Result {
    return derive(gpa, &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }}, &.{
        .{ .tick = 0, .n = 3, .d = 4 },
        .{ .tick = 6 * Grid.TPQ, .n = 4, .d = 4 },
    }, 24 * Grid.TPQ, .hold, null);
}

test "TimeMap.durationTicks: a bar is the bar it lands in, not the bar at the origin" {
    var r = try threeThenFour(testing.allocator);
    defer r.deinit();
    const map = &r.map;

    // Bars 0 and 1 are `[3 4]` (three quarters); bar 2 on is `[4 4]`.
    // `:at 0bar :dur 1bar` is three quarters…
    try testing.expectEqual(
        @as(i64, 3 * Grid.TPQ),
        (try map.durationTicks(.{ .value = 1, .unit = .bar }, 0)).tick,
    );
    // …and `:at 2bar :dur 1bar` is FOUR, which counting from the origin
    // would have got wrong (it would have answered the first bar's three).
    try testing.expectEqual(
        @as(i64, 4 * Grid.TPQ),
        (try map.durationTicks(.{ .value = 1, .unit = .bar }, 6 * Grid.TPQ)).tick,
    );
    // Two bars across the change, from bar 1: three plus four.
    try testing.expectEqual(
        @as(i64, 7 * Grid.TPQ),
        (try map.durationTicks(.{ .value = 2, .unit = .bar }, 3 * Grid.TPQ)).tick,
    );
    // A fraction scales by the LANDING bar's length: half of bar 3's four
    // quarters, measured from bar 2.
    try testing.expectEqual(
        @as(i64, 6 * Grid.TPQ),
        (try map.durationTicks(.{ .value = 1.5, .unit = .bar }, 6 * Grid.TPQ)).tick,
    );
}

test "TimeMap.durationTicks: the beat twin, over the cumulative beat count" {
    var r = try threeThenFour(testing.allocator);
    defer r.deinit();
    const map = &r.map;

    // Every beat here is a quarter, so a beat count is a quarter count —
    // what changes across the meter is which BAR a beat belongs to, and
    // `b` never asks.
    try testing.expectEqual(
        @as(i64, Grid.TPQ),
        (try map.durationTicks(.{ .value = 1, .unit = .b }, 0)).tick,
    );
    try testing.expectEqual(
        @as(i64, 4 * Grid.TPQ),
        (try map.durationTicks(.{ .value = 4, .unit = .b }, 6 * Grid.TPQ)).tick,
    );
    // Half a beat.
    try testing.expectEqual(
        @as(i64, @divExact(Grid.TPQ, 2)),
        (try map.durationTicks(.{ .value = 0.5, .unit = .b }, 3 * Grid.TPQ)).tick,
    );
}

test "TimeMap.durationTicks: q and t carry no anchor, and s is wall-clock from it" {
    var r = try threeThenFour(testing.allocator);
    defer r.deinit();
    const map = &r.map;

    // A quarter is a quarter wherever it starts: the two answers are the
    // same value the unanchored reader gives.
    for ([_]i64{ 0, 3 * Grid.TPQ, 6 * Grid.TPQ }) |at| {
        try testing.expectEqual(
            @as(i64, @divExact(5 * Grid.TPQ, 2)),
            (try map.durationTicks(.{ .value = 2.5, .unit = .q }, at)).tick,
        );
        try testing.expectEqual(
            @as(i64, 9009),
            (try map.durationTicks(.{ .value = 9009, .unit = .t }, at)).tick,
        );
    }
    // 120 quarter notes per minute: one second is two quarters, from
    // anywhere on this one-segment tempo map.
    try testing.expectEqual(
        @as(i64, 2 * Grid.TPQ),
        (try map.durationTicks(.{ .value = 1, .unit = .s }, 6 * Grid.TPQ)).tick,
    );
}

test "TimeMap.durationTicks: a duration is never negative, and the document's rules still hold" {
    var r = try threeThenFour(testing.allocator);
    defer r.deinit();
    const map = &r.map;

    // `0bar` from inside a bar names the line BEHIND the anchor; a
    // duration does not run backwards, so the answer is no time at all.
    try testing.expectEqual(
        @as(i64, 0),
        (try map.durationTicks(.{ .value = 0, .unit = .bar }, Grid.TPQ)).tick,
    );
    try testing.expectEqual(
        @as(i64, 0),
        (try map.durationTicks(.{ .value = 0, .unit = .b }, 9009)).tick,
    );

    try testing.expectEqual(
        Diag.Code.position_negative,
        (try map.durationTicks(.{ .value = -1, .unit = .bar }, 0)).err,
    );
    try testing.expectEqual(
        Diag.Code.position_not_integer,
        (try map.durationTicks(.{ .value = 1.5, .unit = .t }, 0)).err,
    );
    try testing.expectEqual(
        Diag.Code.tick_overflow,
        (try map.durationTicks(.{ .value = 1e30, .unit = .bar }, 0)).err,
    );
}

test "TimeMap.durationTicks: a seconds duration from an interior anchor is never negative" {
    // `seconds(anchor)` at an interior tick may sit an ulp below the
    // anchor's true start (the header's clock rule), so the clock floor
    // of that same second lands on `anchor − 1`, and `0s` read back as
    // one tick BACKWARDS — which no duration is. Both paths, every
    // seventh tick of the first quarter: enough anchors for the ulp to
    // bite on each.
    var floating = try threeSegmentMap();
    defer floating.deinit();
    var integral = try twoSegmentMap(.hold);
    defer integral.deinit();
    try testing.expectEqual(false, floating.map.integral);
    try testing.expectEqual(true, integral.map.integral);

    for ([_]*const TimeMap{ &floating.map, &integral.map }) |m| {
        for (0..1_000_000) |i| {
            const at: i64 = @as(i64, @intCast(i)) * 7;
            const zero = (try m.durationTicks(.{ .value = 0, .unit = .s }, at)).tick;
            if (zero != 0) {
                std.debug.print("0s from tick {d} read back as {d}\n", .{ at, zero });
                return error.TestDurationRanBackwards;
            }
        }
    }
}

test "TimeMap.durationTicks: under ONE meter the anchor changes nothing, bit for bit" {
    // The compatibility claim: every existing document reads the same.
    var r = try derive(testing.allocator, &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }}, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
    }, 64 * Grid.TPQ, .hold, null);
    defer r.deinit();
    const map = &r.map;

    for ([_]f64{ 0, 1, 2, 16, 0.5, 2.25 }) |v| {
        const unanchored = (try map.tickFromLiteral(.{ .value = v, .unit = .bar })).tick;
        for ([_]i64{ 0, 4 * Grid.TPQ, 16 * Grid.TPQ }) |at| {
            try testing.expectEqual(
                unanchored,
                (try map.durationTicks(.{ .value = v, .unit = .bar }, at)).tick,
            );
        }
    }
}

test "TimeMap.tempoOk: the tempo table's own test, by name" {
    try testing.expect(tempoOk(.{ .tick = 0, .tempo = .{ .us = 500_000 } }));
    try testing.expect(tempoOk(.{ .tick = 0, .tempo = .{ .qpm = 97.3 } }));
    try testing.expect(!tempoOk(.{ .tick = 0, .tempo = .{ .us = 0 } }));
    try testing.expect(!tempoOk(.{ .tick = 0, .tempo = .{ .qpm = 0 } }));
    try testing.expect(!tempoOk(.{ .tick = 0, .tempo = .{ .qpm = -5 } }));
    try testing.expect(!tempoOk(.{ .tick = 0, .tempo = .{ .qpm = std.math.nan(f64) } }));
    // …and exactly what `derive` keeps: a point it refuses says
    // `tempo_map_invalid`, one it keeps does not.
    var res = try derive(testing.allocator, &.{.{ .tick = 0, .tempo = .{ .qpm = -5 } }}, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
    }, 0, .hold, null);
    defer res.deinit();
    try testing.expectEqual(@as(usize, 1), res.diags.count(.tempo_map_invalid));
}

test "TimeMap.spellDuration: Nbar between two bar lines, else the delta's own spelling" {
    var r = try threeThenFour(testing.allocator);
    defer r.deinit();
    const map = &r.map;

    var buf: [64]u8 = undefined;
    const spelled = struct {
        fn f(m: *const TimeMap, b: []u8, dur: i64, at: i64) ![]const u8 {
            var w = std.Io.Writer.fixed(b);
            try m.spellDuration(&w, dur, at);
            return w.buffered();
        }
    }.f;

    // One bar from bar 2 is four quarters and spells `1bar` — the tick
    // count alone would have spelled it `4q`, which re-reads as four
    // quarters wherever it lands and is only right by accident.
    try testing.expectEqualStrings("1bar", try spelled(map, &buf, 4 * Grid.TPQ, 6 * Grid.TPQ));
    try testing.expectEqualStrings("1bar", try spelled(map, &buf, 3 * Grid.TPQ, 0));
    try testing.expectEqualStrings("2bar", try spelled(map, &buf, 7 * Grid.TPQ, 3 * Grid.TPQ));
    // Neither end on a bar line, or only one: the delta, by `Pos.spell`.
    try testing.expectEqualStrings("0.5q", try spelled(map, &buf, @divExact(Grid.TPQ, 2), 0));
    try testing.expectEqualStrings("3q", try spelled(map, &buf, 3 * Grid.TPQ, Grid.TPQ));
    try testing.expectEqualStrings("15375360t", try spelled(map, &buf, @divExact(Grid.TPQ, 3), 0));
    // Zero is zero, at a bar line and off one.
    try testing.expectEqualStrings("0bar", try spelled(map, &buf, 0, 0));
    try testing.expectEqualStrings("0q", try spelled(map, &buf, 0, Grid.TPQ));
}

test "TimeMap: durationTicks(spellDuration(d, at), at) is d, across a meter change" {
    // The property the two halves exist for: what the printer writes for
    // a duration reads back as the same number of ticks FROM THE SAME
    // `:at`. Every anchor on the fixture's grid, every duration to every
    // later point on it, plus a sweep of off-grid pairs.
    var r = try threeThenFour(testing.allocator);
    defer r.deinit();
    const map = &r.map;

    var buf: [64]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x64_75_72_61_74);
    const rand = prng.random();

    var checked: usize = 0;
    var bar_spellings: usize = 0;
    var i: usize = 0;
    while (i < 4_000) : (i += 1) {
        // Half the draws land on bar lines at BOTH ends, so the `Nbar`
        // branch is exercised as hard as the delta one; the pair is
        // ordered rather than resampled, so every draw is a case.
        const lo: i64 = if (i % 2 == 0)
            map.barStart(rand.intRangeAtMost(i64, 0, 7)).?
        else
            rand.intRangeAtMost(i64, 0, 20 * Grid.TPQ);
        const hi: i64 = if (i % 2 == 0)
            map.barStart(rand.intRangeAtMost(i64, 0, 7)).?
        else
            rand.intRangeAtMost(i64, 0, 20 * Grid.TPQ);
        const at = @min(lo, hi);
        const dur = @max(lo, hi) - at;

        var w = std.Io.Writer.fixed(&buf);
        try map.spellDuration(&w, dur, at);
        const text = w.buffered();
        if (std.mem.endsWith(u8, text, "bar")) bar_spellings += 1;

        const lit = switch (Pos.parse(text)) {
            .ok => |l| l,
            .err => |code| {
                std.debug.print(
                    "duration {d} at {d} spelled {s}, which does not parse: {t}\n",
                    .{ dur, at, text, code },
                );
                return error.TestSpellingDoesNotParse;
            },
        };
        switch (try map.durationTicks(lit, at)) {
            // `spellDuration` never writes `f` (the printer's frame
            // branch is phase 3), so an inexact landing cannot reach
            // here; treated as the tick it is, the same assertion holds.
            .tick, .inexact => |got| if (got != dur) {
                std.debug.print(
                    "duration {d} at {d} spelled {s}, which reads back as {d}\n",
                    .{ dur, at, text, got },
                );
                return error.TestDurationRoundTripDrifted;
            },
            .err => |code| {
                std.debug.print(
                    "duration {d} at {d} spelled {s}, which will not resolve: {t}\n",
                    .{ dur, at, text, code },
                );
                return error.TestDurationWillNotResolve;
            },
        }
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 4_000), checked);
    try testing.expect(bar_spellings > 1_500);
}
