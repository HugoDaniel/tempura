//! One lane's content as pacer sees it (plan 08, "What is emitted").
//!
//! Two conversions, both of which have to happen in a particular ORDER
//! to be correct:
//!
//! - **Onsets → a trigger's `:at` list.** A lane's onsets — the
//!   document's own notes with every clip expanded, or the bridge's note
//!   pairs for a bound lane, both already placed by `time/derive.zig` —
//!   are converted onto pacer's lattice FIRST and aggregated SECOND. A
//!   chord is three onsets on one tick, and two onsets a hundred ticks
//!   apart may round onto one pacer tick; either way pacer refuses an
//!   `:at` list that is not strictly ascending (`pacer/src/Compile.zig`,
//!   `trigger_invalid`), so equal pacer ticks become ONE event. The
//!   loudest velocity of a merged set is the one `--velocity` prints,
//!   and the merges are counted for the header comment.
//!
//! - **Steps → a track's `(key …)` children.** A NATIVE lane's
//!   keyframes are printed as authored: every one of them, its `:ease`
//!   verbatim (it is pacer's own vocabulary, carried not re-spelled),
//!   its value literal. A BOUND lane's steps are `hold` by default —
//!   the honest reading of a column of sampled values — or `linear`
//!   with `ease_linear`, are scaled into the lane's `:range`, and go
//!   through the two budget stages of `simplify.zig`.
//!
//! **Easing hints.** A midivia `ease-hint` event (or, from task 15, a
//! tempura lane record) says "these steps were a named curve between
//! these two ticks". A hint is honoured only after VERIFICATION: every
//! step inside the segment must lie within `eps` of the named curve
//! between the segment's endpoints, and then the segment collapses to
//! its two keys with the hinted `:ease`. Otherwise the hint is dropped
//! with `ease_hint_mismatch` and the steps win.
//!
//! Verification evaluates the curve, and plan 00 forbids libm in a value
//! path — so the twelve POLYNOMIAL primitives are reproduced here from
//! `pacer/src/Easing.zig` verbatim and everything else (the sine and
//! expo primitives, and every `(seq …)` / `(chain …)` / `(steps …)` /
//! `(cubic-bezier …)` / `(spring …)` form) is unevaluable and its hint
//! is dropped rather than trusted. A hint tempura cannot check is a hint
//! tempura does not apply.

const std = @import("std");
const testing = std.testing;

const Diag = @import("../Diag.zig");
const doc = @import("../doc/doc.zig");
const time = @import("../time/time.zig");

const pos = @import("pos.zig");
const simplify = @import("simplify.zig");

const Allocator = std.mem.Allocator;
const Grid = time.Grid;
const derive = time.derive;

/// Converting a lane can only fail the way any allocation fails. What a
/// DOCUMENT gets wrong is a diagnostic on the list the caller passes in.
pub const Error = error{OutOfMemory};

/// "These steps were `ease` between `from` and `to`" — a midivia
/// `ease-hint` event or a tempura lane record, in tempura ticks.
///
/// Task 15 wires the residue source; the SMF bridge's `ease_hint`
/// events are the source today. Nothing here parses the carrier: the
/// caller hands over hints and this module decides which survive.
pub const EaseHint = struct {
    lane: []const u8,
    from: i64,
    to: i64,
    ease: []const u8,
};

/// The switches a curve lane reads. A subset of `score.Options`, passed
/// down so this module never depends on the printer.
pub const CurveOptions = struct {
    /// The simplification tolerance, in the lane's OWN units after
    /// `:range` scaling. Default is the CC quantum.
    eps: f32 = 1.0 / 127.0,
    /// Print a bound lane's steps as `linear` ramps rather than `hold`
    /// stairs — the automation the DAW drew, when the author knows the
    /// file sampled a ramp.
    ease_linear: bool = false,
    /// Ignore every easing hint, verified or not.
    no_hints: bool = false,
};

/// A notes lane, converted: pacer ticks and the velocity that goes with
/// each. `ticks` is strictly ascending, which is exactly what pacer
/// demands of an `:at` list.
pub const Trigger = struct {
    ticks: []i64,
    vel: []u7,
    /// How many onsets landed on a tick another onset already held.
    aggregated: u32,

    pub fn deinit(self: *Trigger, gpa: Allocator) void {
        gpa.free(self.ticks);
        gpa.free(self.vel);
        self.* = undefined;
    }
};

/// A curve lane, converted and budgeted.
pub const Curve = struct {
    keys: []simplify.Key,
    /// How many steps the lane started with, for the header comment's
    /// `A → B` count.
    source_steps: u32,

    pub fn deinit(self: *Curve, gpa: Allocator) void {
        gpa.free(self.keys);
        self.* = undefined;
    }
};

/// Onsets → a trigger's `:at` list: convert, then aggregate.
pub fn triggers(
    gpa: Allocator,
    onsets: []const derive.Onset,
    n: u8,
    d: u8,
    counter: *pos.Counter,
) Error!Trigger {
    var ticks: std.ArrayList(i64) = .empty;
    errdefer ticks.deinit(gpa);
    var vels: std.ArrayList(u7) = .empty;
    errdefer vels.deinit(gpa);
    try ticks.ensureTotalCapacity(gpa, onsets.len);
    try vels.ensureTotalCapacity(gpa, onsets.len);

    var aggregated: u32 = 0;
    for (onsets) |o| {
        const tick = counter.convert(@max(o.tick, 0), n, d);
        // `derive` sorted the onsets by tick, and the conversion is
        // monotone, so an equal tick can only be the one just appended.
        if (ticks.items.len != 0 and ticks.items[ticks.items.len - 1] == tick) {
            aggregated +|= 1;
            const last = &vels.items[vels.items.len - 1];
            if (o.vel > last.*) last.* = o.vel;
            continue;
        }
        ticks.appendAssumeCapacity(tick);
        vels.appendAssumeCapacity(o.vel);
    }

    return .{
        .ticks = try ticks.toOwnedSlice(gpa),
        .vel = try vels.toOwnedSlice(gpa),
        .aggregated = aggregated,
    };
}

/// Steps → a track's `(key …)` children.
pub fn curve(
    gpa: Allocator,
    lane: *const doc.Lane,
    index: *const derive.LaneIndex,
    hints: []const EaseHint,
    n: u8,
    d: u8,
    opts: CurveOptions,
    counter: *pos.Counter,
    diags: *Diag.List,
) Error!Curve {
    const source_steps: u32 = @intCast(index.steps.len);

    // A NATIVE lane is printed as authored — every keyframe, its easing
    // verbatim, its value literal. Nothing below this line runs for one.
    if (!index.bound) {
        const keys = try gpa.alloc(simplify.Key, index.steps.len);
        for (index.steps, keys) |src, *dst| dst.* = .{
            .tick = counter.convert(@max(src.tick, 0), n, d),
            .value = src.value,
            .ncomp = src.ncomp,
            .ease = src.ease_src,
        };
        return .{ .keys = keys, .source_steps = source_steps };
    }

    const mode: simplify.Mode = if (opts.ease_linear) .linear else .hold;
    const ease_name = @tagName(mode);

    const raw = try gpa.alloc(simplify.Key, index.steps.len);
    defer gpa.free(raw);
    for (index.steps, raw) |src, *dst| dst.* = .{
        .tick = counter.convert(@max(src.tick, 0), n, d),
        .value = scaled(src.value, src.ncomp, lane.range),
        .ncomp = src.ncomp,
        .ease = ease_name,
    };

    var out: std.ArrayList(simplify.Key) = .empty;
    errdefer out.deinit(gpa);

    // Every hint is decided ONCE, up front — verified into a span or
    // dropped with its diagnostic — so a hint that loses cannot be
    // re-judged (and re-reported) by a later pass of the walk below.
    const spans = if (opts.no_hints)
        &[_]Span{}
    else
        try verifiedSpans(gpa, lane, index, raw, hints, opts.eps, diags);
    defer gpa.free(spans);

    // Then one walk, alternating between the spans a verified hint owns
    // (two keys, the hinted easing) and the runs between them (the two
    // budget stages).
    var at: usize = 0;
    var next: usize = 0;
    while (at < raw.len) {
        while (next < spans.len and spans[next].start < at) next += 1;
        const span: ?Span = if (next < spans.len) spans[next] else null;
        const gap_end = if (span) |sp| sp.start else raw.len;
        if (gap_end > at) try appendBudgeted(gpa, &out, raw[at..gap_end], mode, opts.eps, n);
        if (span) |sp| {
            try out.append(gpa, raw[sp.start]);
            var last = raw[sp.end];
            last.ease = sp.ease;
            try out.append(gpa, last);
            at = sp.end + 1;
            next += 1;
        } else {
            at = gap_end;
        }
    }

    return .{ .keys = try out.toOwnedSlice(gpa), .source_steps = source_steps };
}

// ---- the pieces ----

/// A verified hint's span over `raw`, inclusive at both ends.
const Span = struct { start: usize, end: usize, ease: []const u8 };

/// Every hint that names this lane, decided: the ones whose steps
/// really do follow the named curve become spans, ascending and
/// non-overlapping, and the ones that do not are dropped here — once —
/// with `ease_hint_mismatch`.
fn verifiedSpans(
    gpa: Allocator,
    lane: *const doc.Lane,
    index: *const derive.LaneIndex,
    raw: []const simplify.Key,
    hints: []const EaseHint,
    eps: f32,
    diags: *Diag.List,
) Error![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);

    for (hints) |h| {
        if (!std.mem.eql(u8, h.lane, index.name)) continue;
        if (h.to <= h.from) continue;
        const bounds = spanOf(index.steps, h) orelse continue;
        // Two keys are already the collapse a hint asks for, so there is
        // nothing to verify and nothing to gain.
        if (bounds.end <= bounds.start + 1) continue;
        if (!verify(raw, bounds.start, bounds.end, h.ease, eps)) {
            try diags.add(
                .ease_hint_mismatch,
                .warning,
                lane.span,
                "lane {s}: the steps between ticks {d} and {d} are not {s} within {d} — the hint is dropped and the steps win",
                .{ index.name, h.from, h.to, h.ease, eps },
            );
            continue;
        }
        try out.append(gpa, .{ .start = bounds.start, .end = bounds.end, .ease = h.ease });
    }

    // Ascending by start, and a hint that reaches into one already taken
    // loses: two curves cannot own one step.
    std.mem.sort(Span, out.items, {}, spanBefore);
    var kept: usize = 0;
    var reach: usize = 0;
    for (out.items) |span| {
        if (kept != 0 and span.start <= reach) continue;
        out.items[kept] = span;
        kept += 1;
        reach = span.end;
    }
    out.shrinkRetainingCapacity(kept);
    return out.toOwnedSlice(gpa);
}

/// Ascending by start; the longer span first on a tie, so the one that
/// explains more steps is the one kept.
fn spanBefore(_: void, a: Span, b: Span) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

/// The step indices a hint's `[from, to]` covers.
fn spanOf(steps: []const derive.Step, h: EaseHint) ?struct { start: usize, end: usize } {
    var start: ?usize = null;
    var end: usize = 0;
    for (steps, 0..) |s, i| {
        if (s.tick < h.from) continue;
        if (s.tick > h.to) break;
        if (start == null) start = i;
        end = i;
    }
    const s = start orelse return null;
    if (end <= s) return null;
    return .{ .start = s, .end = end };
}

/// Whether every step strictly inside `[start, end]` lies within `eps`
/// of `ease` drawn between the two endpoints' values.
fn verify(raw: []const simplify.Key, start: usize, end: usize, ease: []const u8, eps: f32) bool {
    // An unevaluable easing never verifies: see the module header.
    if (easeAt(ease, 0.5) == null) return false;

    const span: f64 = @floatFromInt(raw[end].tick - raw[start].tick);
    if (span <= 0) return false;
    var i = start + 1;
    while (i < end) : (i += 1) {
        const u = @as(f64, @floatFromInt(raw[i].tick - raw[start].tick)) / span;
        const shaped = easeAt(ease, u) orelse return false;
        var c: usize = 0;
        while (c < @max(raw[i].ncomp, 1)) : (c += 1) {
            const lo: f64 = raw[start].value[c];
            const hi: f64 = raw[end].value[c];
            const want = lo + (hi - lo) * shaped;
            if (@abs(want - @as(f64, raw[i].value[c])) > @as(f64, eps)) return false;
        }
    }
    return true;
}

/// Run one unhinted run of keys through both budget stages and append
/// what survives, without repeating a key the previous run already
/// contributed.
fn appendBudgeted(
    gpa: Allocator,
    out: *std.ArrayList(simplify.Key),
    run: []const simplify.Key,
    mode: simplify.Mode,
    eps: f32,
    n: u8,
) Error!void {
    const kept = try simplify.budget(gpa, run, mode, eps, pos.ticksPerBeat(n));
    defer gpa.free(kept);
    for (kept) |key| {
        if (out.items.len != 0 and out.items[out.items.len - 1].tick == key.tick) continue;
        try out.append(gpa, key);
    }
}

/// A bound lane's normalised value in the lane's `:range`. Without a
/// `:range` the value stays as the bridge produced it (0..1, or −1..1
/// for a bend).
fn scaled(value: [4]f32, ncomp: u3, range: ?[2]f32) [4]f32 {
    const r = range orelse return value;
    var out = value;
    var c: usize = 0;
    while (c < @max(ncomp, 1)) : (c += 1) {
        out[c] = r[0] + value[c] * (r[1] - r[0]);
    }
    return out;
}

/// pacer's twelve POLYNOMIAL easing primitives, reproduced from
/// `pacer/src/Easing.zig`'s `evalOp` expression for expression — null
/// for every easing this cannot evaluate exactly (the sine and expo
/// primitives, which need a transcendental, and every combinator form,
/// which needs pacer's own compiler).
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

// ---- tests ----

const q = Grid.TPQ;

fn onset(tick: i64, key: u7, vel: u7) derive.Onset {
    return .{ .tick = tick, .dur = q, .key = key, .vel = vel };
}

fn step(tick: i64, v: f32) derive.Step {
    return .{ .tick = tick, .value = .{ v, 0, 0, 0 }, .ncomp = 1, .ease_src = "linear" };
}

fn boundLane(name: []const u8, range: ?[2]f32) doc.Lane {
    return .{
        .name = name,
        .kind = .curve,
        .target = name,
        .range = range,
        .binding = .{ .anchor = "song", .address = .{ .smf = .{ .track = 1, .ch = 0, .key = null, .curve = .{ .cc = 74 } } } },
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = .{ .start = 0, .end = 1 },
    };
}

test "lanes.triggers: a chord aggregates to one onset carrying the loudest velocity" {
    const gpa = testing.allocator;
    // Three notes on one tick, and a fourth a beat later.
    const onsets = [_]derive.Onset{
        onset(0, 48, 70),
        onset(0, 55, 110),
        onset(0, 60, 96),
        onset(q, 48, 64),
    };
    var counter: pos.Counter = .{};

    var got = try triggers(gpa, &onsets, 4, 4, &counter);
    defer got.deinit(gpa);

    try testing.expectEqualSlices(i64, &.{ 0, 180_180 }, got.ticks);
    try testing.expectEqualSlices(u7, &.{ 110, 64 }, got.vel);
    try testing.expectEqual(@as(u32, 2), got.aggregated);
    try testing.expectEqual(@as(u32, 0), counter.rounded);
}

test "lanes.triggers: two near onsets that round onto one pacer tick become one event" {
    const gpa = testing.allocator;
    // pacer refuses an `:at` list that is not strictly ascending
    // (`Compile.zig`, `trigger_invalid`), so the merge happens AFTER the
    // conversion — two ticks 100 apart share a pacer tick at divisor 256.
    const onsets = [_]derive.Onset{ onset(512, 60, 80), onset(570, 62, 99) };
    var counter: pos.Counter = .{};

    var got = try triggers(gpa, &onsets, 4, 4, &counter);
    defer got.deinit(gpa);

    try testing.expectEqualSlices(i64, &.{2}, got.ticks);
    try testing.expectEqualSlices(u7, &.{99}, got.vel);
    try testing.expectEqual(@as(u32, 1), got.aggregated);
    try testing.expectEqual(@as(u32, 1), counter.rounded);
}

test "lanes.curve: a bound lane's steps are hold keys, or linear with ease_linear" {
    const gpa = testing.allocator;
    const lane = boundLane("glow", null);
    const steps = [_]derive.Step{ step(0, 0), step(q, 0.5), step(2 * q, 1) };
    const index: derive.LaneIndex = .{
        .name = "glow",
        .kind = .curve,
        .bound = true,
        .onsets = &.{},
        .steps = @constCast(&steps),
    };
    var counter: pos.Counter = .{};
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var held = try curve(gpa, &lane, &index, &.{}, 4, 4, .{}, &counter, &diags);
    defer held.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), held.keys.len);
    for (held.keys) |key| try testing.expectEqualStrings("hold", key.ease);

    var ramped = try curve(gpa, &lane, &index, &.{}, 4, 4, .{ .ease_linear = true }, &counter, &diags);
    defer ramped.deinit(gpa);
    // A straight ramp under `linear` is exactly the RDP's easy case.
    try testing.expectEqual(@as(usize, 2), ramped.keys.len);
    for (ramped.keys) |key| try testing.expectEqualStrings("linear", key.ease);
    try testing.expectEqual(@as(u32, 0), diags.items().len);
}

test "lanes.curve: :range scales a bound lane's normalised value" {
    const gpa = testing.allocator;
    const lane = boundLane("cutoff", .{ 200, 8000 });
    const steps = [_]derive.Step{ step(0, 0), step(q, 0.5), step(2 * q, 1) };
    const index: derive.LaneIndex = .{
        .name = "cutoff",
        .kind = .curve,
        .bound = true,
        .onsets = &.{},
        .steps = @constCast(&steps),
    };
    var counter: pos.Counter = .{};
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var got = try curve(gpa, &lane, &index, &.{}, 4, 4, .{}, &counter, &diags);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), got.keys.len);
    try testing.expectEqual(@as(f32, 200), got.keys[0].value[0]);
    try testing.expectEqual(@as(f32, 4100), got.keys[1].value[0]);
    try testing.expectEqual(@as(f32, 8000), got.keys[2].value[0]);
}

test "lanes.curve: native keyframes are untouched, each with its :ease verbatim" {
    const gpa = testing.allocator;
    var lane = boundLane("glow", null);
    lane.binding = null;
    // A plateau AND a value inside `eps` of its neighbours: a bound lane
    // would lose both; a native one keeps every keyframe the author
    // wrote (plan 08, "Native lanes are never simplified").
    const steps = [_]derive.Step{
        .{ .tick = 0, .value = .{ 0.2, 0, 0, 0 }, .ncomp = 1, .ease_src = "hold" },
        .{ .tick = q, .value = .{ 0.2, 0, 0, 0 }, .ncomp = 1, .ease_src = "in-cubic" },
        .{ .tick = 2 * q, .value = .{ 0.2001, 0, 0, 0 }, .ncomp = 1, .ease_src = "(spring :damping 0.5)" },
        .{ .tick = 3 * q, .value = .{ 0.9, 0, 0, 0 }, .ncomp = 1, .ease_src = "linear" },
    };
    const index: derive.LaneIndex = .{
        .name = "glow",
        .kind = .curve,
        .bound = false,
        .onsets = &.{},
        .steps = @constCast(&steps),
    };
    var counter: pos.Counter = .{};
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var got = try curve(gpa, &lane, &index, &.{}, 4, 4, .{}, &counter, &diags);
    defer got.deinit(gpa);

    try testing.expectEqual(@as(usize, 4), got.keys.len);
    try testing.expectEqualStrings("hold", got.keys[0].ease);
    try testing.expectEqualStrings("in-cubic", got.keys[1].ease);
    try testing.expectEqualStrings("(spring :damping 0.5)", got.keys[2].ease);
    try testing.expectEqual(@as(f32, 0.2001), got.keys[2].value[0]);
    // Native values are literal: `:range` never scales them.
    try testing.expectEqual(@as(f32, 0.9), got.keys[3].value[0]);
}

test "lanes.curve: a verified ease hint collapses its segment to two keys" {
    const gpa = testing.allocator;
    const lane = boundLane("glow", null);

    // Nine steps sampling `in-cubic` from 0 to 1 over two quarters —
    // what a DAW's automation lane looks like when midivia knew the
    // curve and wrote an `ease-hint` beside it.
    var raw: [9]derive.Step = undefined;
    for (&raw, 0..) |*s, i| {
        const u: f64 = @as(f64, @floatFromInt(i)) / 8.0;
        s.* = step(@as(i64, @intCast(i)) * @divExact(q, 4), @floatCast(u * u * u));
    }
    const index: derive.LaneIndex = .{
        .name = "glow",
        .kind = .curve,
        .bound = true,
        .onsets = &.{},
        .steps = &raw,
    };
    const hints = [_]EaseHint{.{ .lane = "glow", .from = 0, .to = 2 * q, .ease = "in-cubic" }};
    var counter: pos.Counter = .{};
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var got = try curve(gpa, &lane, &index, &hints, 4, 4, .{}, &counter, &diags);
    defer got.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), got.keys.len);
    try testing.expectEqual(@as(f32, 0), got.keys[0].value[0]);
    try testing.expectEqual(@as(f32, 1), got.keys[1].value[0]);
    // The easing shapes the segment ENDING at a key (pacer's semantics),
    // so it rides the LAST of the two.
    try testing.expectEqualStrings("in-cubic", got.keys[1].ease);
    try testing.expectEqual(@as(usize, 0), diags.items().len);
}

test "lanes.curve: a hint the steps do not follow is dropped with ease_hint_mismatch" {
    const gpa = testing.allocator;
    const lane = boundLane("glow", null);

    // The same nine steps, but sampling a straight line: `in-cubic` is
    // nowhere near them, so the hint loses and the steps win.
    var raw: [9]derive.Step = undefined;
    for (&raw, 0..) |*s, i| {
        const u: f32 = @as(f32, @floatFromInt(i)) / 8.0;
        s.* = step(@as(i64, @intCast(i)) * @divExact(q, 4), u);
    }
    const index: derive.LaneIndex = .{
        .name = "glow",
        .kind = .curve,
        .bound = true,
        .onsets = &.{},
        .steps = &raw,
    };
    const hints = [_]EaseHint{.{ .lane = "glow", .from = 0, .to = 2 * q, .ease = "in-cubic" }};
    var counter: pos.Counter = .{};
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var got = try curve(gpa, &lane, &index, &hints, 4, 4, .{}, &counter, &diags);
    defer got.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), diags.count(.ease_hint_mismatch));
    try testing.expectEqual(Diag.Severity.warning, diags.items()[0].severity);
    // The steps won, and the straight line still thins to its endpoints
    // under the `hold` staircase rule.
    for (got.keys) |key| try testing.expectEqualStrings("hold", key.ease);
}

test "lanes.curve: an easing tempura cannot evaluate exactly is never silently trusted" {
    const gpa = testing.allocator;
    const lane = boundLane("glow", null);
    var raw: [5]derive.Step = undefined;
    for (&raw, 0..) |*s, i| {
        const u: f32 = @as(f32, @floatFromInt(i)) / 4.0;
        s.* = step(@as(i64, @intCast(i)) * @divExact(q, 2), u);
    }
    const index: derive.LaneIndex = .{
        .name = "glow",
        .kind = .curve,
        .bound = true,
        .onsets = &.{},
        .steps = &raw,
    };
    // `in-sine` needs a transcendental; a `(spring …)` form needs pacer's
    // own compiler. Neither can be checked here without libm, and plan
    // 00 forbids libm in a value path — so the hint is dropped rather
    // than trusted.
    const hints = [_]EaseHint{.{ .lane = "glow", .from = 0, .to = 2 * q, .ease = "in-sine" }};
    var counter: pos.Counter = .{};
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var got = try curve(gpa, &lane, &index, &hints, 4, 4, .{}, &counter, &diags);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), diags.count(.ease_hint_mismatch));
    for (got.keys) |key| try testing.expect(!std.mem.eql(u8, "in-sine", key.ease));
}

test "lanes.curve: two hints, decided once each — the good one collapses, the bad one is reported" {
    const gpa = testing.allocator;
    const lane = boundLane("glow", null);

    // Two segments: `in-cubic` over the first quarter, a straight line
    // over the second. Both are hinted `in-cubic`; only the first is.
    var raw: [9]derive.Step = undefined;
    for (raw[0..5], 0..) |*s, i| {
        const u: f64 = @as(f64, @floatFromInt(i)) / 4.0;
        s.* = step(@as(i64, @intCast(i)) * @divExact(q, 4), @floatCast(u * u * u));
    }
    for (raw[5..], 5..) |*s, i| {
        const u: f32 = @as(f32, @floatFromInt(i - 4)) / 4.0;
        s.* = step(@as(i64, @intCast(i)) * @divExact(q, 4), 1 + u);
    }
    const index: derive.LaneIndex = .{
        .name = "glow",
        .kind = .curve,
        .bound = true,
        .onsets = &.{},
        .steps = &raw,
    };
    const hints = [_]EaseHint{
        .{ .lane = "glow", .from = 0, .to = q, .ease = "in-cubic" },
        .{ .lane = "glow", .from = q + @divExact(q, 4), .to = 2 * q, .ease = "in-cubic" },
        // A hint for a lane this is not: never looked at.
        .{ .lane = "other", .from = 0, .to = 2 * q, .ease = "in-quad" },
    };
    var counter: pos.Counter = .{};
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var got = try curve(gpa, &lane, &index, &hints, 4, 4, .{}, &counter, &diags);
    defer got.deinit(gpa);

    // Exactly ONE complaint, however many times the walk passes the
    // hints: a hint is decided once.
    try testing.expectEqual(@as(usize, 1), diags.count(.ease_hint_mismatch));
    // The verified segment is its two endpoints, the second key carrying
    // the easing that shaped it.
    try testing.expectEqual(@as(i64, 0), got.keys[0].tick);
    try testing.expectEqualStrings("in-cubic", got.keys[1].ease);
    try testing.expectEqual(@as(f32, 1), got.keys[1].value[0]);
}

test "lanes.curve: no_hints ignores every hint, verified or not" {
    const gpa = testing.allocator;
    const lane = boundLane("glow", null);
    var raw: [9]derive.Step = undefined;
    for (&raw, 0..) |*s, i| {
        const u: f64 = @as(f64, @floatFromInt(i)) / 8.0;
        s.* = step(@as(i64, @intCast(i)) * @divExact(q, 4), @floatCast(u * u * u));
    }
    const index: derive.LaneIndex = .{
        .name = "glow",
        .kind = .curve,
        .bound = true,
        .onsets = &.{},
        .steps = &raw,
    };
    const hints = [_]EaseHint{.{ .lane = "glow", .from = 0, .to = 2 * q, .ease = "in-cubic" }};
    var counter: pos.Counter = .{};
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var got = try curve(gpa, &lane, &index, &hints, 4, 4, .{ .no_hints = true }, &counter, &diags);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), diags.items().len);
    for (got.keys) |key| try testing.expectEqualStrings("hold", key.ease);
}

test "lanes.easeAt: the twelve polynomial primitives match pacer's own formulas" {
    try testing.expectEqual(@as(?f64, 0.5), easeAt("linear", 0.5));
    try testing.expectEqual(@as(?f64, 0), easeAt("hold", 0.5));
    try testing.expectEqual(@as(?f64, 1), easeAt("hold", 1));
    try testing.expectEqual(@as(?f64, 0.5), easeAt("smoothstep", 0.5));
    try testing.expectEqual(@as(?f64, 0.25), easeAt("in-quad", 0.5));
    try testing.expectEqual(@as(?f64, 0.75), easeAt("out-quad", 0.5));
    try testing.expectEqual(@as(?f64, 0.125), easeAt("in-cubic", 0.5));
    try testing.expectEqual(@as(?f64, 0.0625), easeAt("in-quart", 0.5));
    try testing.expectEqual(@as(?f64, 0.5), easeAt("in-out-quad", 0.5));
    try testing.expectEqual(@as(?f64, 0.5), easeAt("in-out-cubic", 0.5));
    try testing.expectEqual(@as(?f64, 0.5), easeAt("in-out-quart", 0.5));
    // Everything else is unevaluable HERE, on purpose.
    try testing.expect(easeAt("in-sine", 0.5) == null);
    try testing.expect(easeAt("(spring :damping 0.5)", 0.5) == null);
}
