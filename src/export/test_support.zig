//! Fixtures for `src/export/`'s own tests — a native document, an
//! SMF-conducted one and an IT-conducted one, each with its `Derived`
//! beside it.
//!
//! The three conductors of plan 03 are the three shapes `exportScore`
//! has to get right (plan 08 phase 2's reds), and two of them need a
//! file. The format cores' own `Builder`s are what make those files
//! without a committed blob, exactly as `smf/test_support.zig` and
//! `itf/test_support.zig` do for the cores — which is also why this
//! file, and only this file in `src/export/`, imports them. The
//! exporter itself consumes a `Doc` and a `Derived` and nothing else
//! (plan 01, "Layering rule").
//!
//! `tools/gen_landing.zig` builds the same three so the node suite can
//! load every golden score through the real `pacer.wasm`; the fixtures
//! are therefore `pub` rather than test-private.

const std = @import("std");

const Schema = @import("../Schema.zig");
const doc = @import("../doc/doc.zig");
const time = @import("../time/time.zig");
const Sequence = @import("../smf/Sequence.zig");
const Module = @import("../itf/Module.zig");

const Allocator = std.mem.Allocator;
const Grid = time.Grid;
const derive = time.derive;

/// One quarter note and one `[4 4]` bar, in tempura ticks.
pub const q: i64 = Grid.TPQ;
pub const bar: i64 = 4 * Grid.TPQ;

/// A document and what a playhead reads of it. `deinit` frees both.
pub const Fixture = struct {
    doc: doc.Doc,
    derived: derive.Derived,

    pub fn deinit(self: *Fixture) void {
        self.derived.deinit();
        self.doc.deinit();
    }
};

/// The native fixture's source — plan 02's example, trimmed to four
/// bars and made COMPOSE-CLEAN: every target the score drives is
/// declared by a pass-through `(target …)`, so the emitted skeleton
/// loads through `pacer.wasm` with no host registries at all.
///
/// The chord at `0q` and the `(clip …)` are here on purpose: the first
/// is the aggregation plan 08 counts in the header, the second is the
/// expansion `time/derive.zig` performs before the exporter sees a
/// single onset.
pub const native_source: [:0]const u8 =
    \\(timeline :title "impulsos" :length 4bar :end loop)
    \\
    \\(tempo-point :at 0q   :qpm 125)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(section :name intro :at 0bar :dur 2bar)
    \\(section :name drop  :at 2bar :dur 2bar)
    \\(cue :name "the drop" :at 2bar)
    \\
    \\(lane :name kick :kind notes :target kick
    \\  (note :at 0q   :dur 0.5q :key 36 :vel 110)
    \\  (note :at 0q   :dur 0.5q :key 43 :vel 96)
    \\  (note :at 1q   :dur 0.5q :key 36 :vel 64)
    \\  (clip :at 2bar :phrase fill :repeat 2))
    \\(lane :name glow :kind curve :target glow
    \\  (keyframe :at 0q :value 0.2 :ease hold)
    \\  (keyframe :at 4q :value 0.9 :ease in-cubic)
    \\  (keyframe :at 8q :value 0.1 :ease (spring :damping 0.5)))
    \\(lane :name hats  :kind query   :target hats  :query (euclid 3 8 1))
    \\(lane :name pulse :kind formula :target pulse :expr (* beat 2))
    \\
    \\(phrase :name fill :length 1bar
    \\  (lane :name kick
    \\    (note :at 0q   :dur 0.25q :key 38 :vel 100)
    \\    (note :at 0.5q :dur 0.25q :key 38 :vel 80)))
    \\
    \\(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)
    \\(target :name kick :arity 4)
    \\(target :name kick-vel :arity 1)
    \\(target :name glow :arity 1)
    \\(target :name hats :arity 1)
    \\(target :name pulse :arity 1)
    \\(target :name glow-amt :arity 1)
;

/// The native fixture, loaded through the real bridge.
pub fn native(gpa: Allocator) !Fixture {
    return fromText(gpa, native_source);
}

/// Any document, loaded through the real bridge and derived.
pub fn fromText(gpa: Allocator, source: [:0]const u8) !Fixture {
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var loaded = try doc.fromSource(gpa, &schema, source, null);
    errdefer loaded.deinit();
    if (loaded.diags.hasErrors()) {
        for (loaded.diags.items()) |d| std.debug.print("fixture: {t}: {s}\n", .{ d.code, d.message });
        return error.FixtureDoesNotLoad;
    }
    // The map `fromSource` returns is the bridge's; `derive` builds its
    // own from the same points, and that is the one the exporter reads.
    loaded.map.deinit();
    loaded.diags.deinit();

    var d = loaded.doc;
    errdefer d.deinit();
    const derived = try derive.derive(gpa, &d);
    return .{ .doc = d, .derived = derived };
}

/// An SMF-conducted document: two `set-tempo`s and a `time-signature`
/// on track 1, a bound notes lane and a bound `cc 74` curve lane on
/// track 2.
///
/// Division 960 divides `TPQ` exactly (46 126 080 / 960 = 48 048), so
/// every pulse below lands on the grid and then on pacer's lattice —
/// the fixture is about the CONDUCTOR, not about rounding.
pub fn smfConducted(gpa: Allocator) !Fixture {
    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    _ = try b.addTrack();

    try b.addEvent(0, 0, .time_signature, .{ .time_sig = .{ .nn = 4, .dd = 2, .cc = 24, .bb = 8 } });
    try b.addEvent(0, 0, .set_tempo, .{ .tempo = 480_000 });
    try b.addEvent(0, 960, .set_tempo, .{ .tempo = 400_000 });
    try b.addEvent(0, 3840, .end_of_track, .empty);

    try b.addEvent(1, 0, .note_on, .{ .note = .{ .ch = 1, .key = 36, .vel = 100 } });
    try b.addEvent(1, 240, .note_off, .{ .note = .{ .ch = 1, .key = 36, .vel = 0 } });
    try b.addEvent(1, 480, .note_on, .{ .note = .{ .ch = 1, .key = 38, .vel = 80 } });
    try b.addEvent(1, 720, .note_off, .{ .note = .{ .ch = 1, .key = 38, .vel = 0 } });
    for ([_][2]i64{ .{ 0, 0 }, .{ 240, 32 }, .{ 480, 64 }, .{ 720, 96 }, .{ 960, 127 } }) |p| {
        try b.addEvent(1, p[0], .control_change, .{
            .control = .{ .ch = 1, .num = 74, .val = @intCast(p[1]) },
        });
    }
    try b.addEvent(1, 3840, .end_of_track, .empty);
    const seq = try b.finish();

    var d: doc.Doc = .empty(gpa);
    errdefer d.deinit();
    const arena = d.arena.allocator();

    const tiers = try arena.alloc(doc.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    d.anchors = try anchor(arena, .smf, "impulse.mid");
    d.conductor = "song";
    d.midi = tiers;
    d.length = 2 * bar;

    const lanes = try arena.alloc(doc.Lane, 2);
    lanes[0] = bound("kick", .notes, .{ .smf = .{ .track = 2, .ch = .single(1), .key = null, .curve = null } }, null);
    lanes[1] = bound(
        "filter",
        .curve,
        .{ .smf = .{ .track = 2, .ch = .single(1), .key = null, .curve = .{ .cc = 74 } } },
        .{ 0, 1 },
    );
    d.lanes = lanes;
    d.passthrough = try targets(arena, &.{ "kick 4", "kick-vel 1", "filter 1" });

    const derived = try derive.derive(gpa, &d);
    return .{ .doc = d, .derived = derived };
}

/// An IT-conducted document: a module whose `Txx` rows are the tempo
/// map and whose channel 1 carries the notes a bound lane reads back
/// through the timing walk.
///
/// Speed 6 and 24 ticks to the quarter make a row a 16th, so the `Txx`
/// at rows 4 and 8 sit on 1q and 2q — the same three segments
/// `time/derive.zig` pins by hand for its own IT conductor test (125,
/// 150 and 200 quarter notes per minute). Pattern 1 is the one-row `B01`
/// that jumps to itself, which is what ends the walk after ONE pass.
pub fn itConducted(gpa: Allocator) !Fixture {
    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    try b.addOrder(0);
    try b.addOrder(1);

    const song = try b.addPattern(16);
    const fx_t: u8 = 'T' - '@';
    // C-5 is note 60 in IT's own numbering, the middle of the table.
    song.at(0, 0).* = .{ .note = 60, .ins = 1, .vol = 64 };
    song.at(4, 0).* = .{ .note = 62, .ins = 1, .vol = 48, .fx = fx_t, .param = 150 };
    song.at(8, 0).* = .{ .note = 64, .ins = 1, .vol = 32, .fx = fx_t, .param = 200 };
    song.at(12, 0).* = .{ .note = 65, .ins = 1, .vol = 64 };
    const tail = try b.addPattern(1);
    tail.at(0, 0).* = .{ .fx = 'B' - '@', .param = 1 };
    const module = b.finish();

    var d: doc.Doc = .empty(gpa);
    errdefer d.deinit();
    const arena = d.arena.allocator();

    const tiers = try arena.alloc(doc.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    d.anchors = try anchor(arena, .it, "impulse-04.it");
    d.conductor = "song";
    d.it = tiers;
    d.length = 2 * bar;

    const lanes = try arena.alloc(doc.Lane, 1);
    lanes[0] = bound("bass", .notes, .{ .it = .{ .channel = 0, .column = null, .fx = null } }, null);
    d.lanes = lanes;
    d.passthrough = try targets(arena, &.{ "bass 4", "bass-vel 1" });

    const derived = try derive.derive(gpa, &d);
    return .{ .doc = d, .derived = derived };
}

/// A document the 512-segment fallback fires on: 600 tempo points a
/// whole beat-per-minute apart over two bars, so nothing coalesces
/// within `--tempo-eps` and the score has to print its positions in
/// SECONDS (plan 08, "Transport and tempo"; the it set's 09 fallback).
///
/// The tempo really moves — 60 quarter notes a minute up to 659 — so
/// the two bars are not the same length in seconds and a `:dur`
/// measured from tick 0 would be visibly wrong. Two sections and a
/// notes lane on the quarters give the emitted score something to get
/// right, and the `(target …)` roots let it load standalone.
pub fn slideConducted(gpa: Allocator) !Fixture {
    var d: doc.Doc = .empty(gpa);
    errdefer d.deinit();
    const arena = d.arena.allocator();

    const points = try arena.alloc(doc.TempoPoint, 600);
    for (points, 0..) |*t, i| t.* = .{
        .tick = @as(i64, @intCast(i)) * @divExact(q, 64),
        .tempo = .{ .qpm = 60 + @as(f64, @floatFromInt(i)) },
    };
    d.tempo = points;
    const meter = try arena.alloc(doc.MeterPoint, 1);
    meter[0] = .{ .tick = 0, .n = 4, .d = 4 };
    d.meter = meter;
    d.length = 2 * bar;

    const sections = try arena.alloc(doc.Section, 2);
    sections[0] = .{ .name = "one", .at = 0, .dur = bar, .span = .{ .start = 0, .end = 1 } };
    sections[1] = .{ .name = "two", .at = bar, .dur = bar, .span = .{ .start = 0, .end = 1 } };
    d.sections = sections;

    const notes = try arena.alloc(doc.Note, 8);
    for (notes, 0..) |*n, i| n.* = .{
        .at = @as(i64, @intCast(i)) * q,
        .dur = @divExact(q, 2),
        .key = 36,
        .vel = 100,
        .ch = 0,
        .off_vel = null,
        .span = .{ .start = 0, .end = 1 },
    };
    const lanes = try arena.alloc(doc.Lane, 1);
    lanes[0] = .{
        .name = "hit",
        .kind = .notes,
        .target = "hit",
        .range = null,
        .binding = null,
        .notes = notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = .{ .start = 0, .end = 1 },
    };
    d.lanes = lanes;
    d.passthrough = try targets(arena, &.{ "hit 4", "hit-vel 1" });

    const derived = try derive.derive(gpa, &d);
    return .{ .doc = d, .derived = derived };
}

// ---- the small builders ----

fn anchor(arena: Allocator, kind: doc.AnchorKind, file: []const u8) ![]doc.Anchor {
    const out = try arena.alloc(doc.Anchor, 1);
    out[0] = .{
        .id = "song",
        .kind = kind,
        .file = file,
        .size = null,
        .sha256 = null,
        .sha256_src = null,
        .inline_dump = true,
        .resolved = true,
        .span = .{ .start = 0, .end = 1 },
    };
    return out;
}

/// `(target :name X :arity N)` pass-through roots, one per `"<name> <arity>"`
/// — pacer's compose mode, which is what lets the emitted skeleton load
/// through `pacer.wasm` with no host registries at all.
fn targets(arena: Allocator, specs: []const []const u8) ![]doc.Passthrough {
    const out = try arena.alloc(doc.Passthrough, specs.len);
    for (specs, out) |spec, *p| {
        const sp = std.mem.indexOfScalar(u8, spec, ' ').?;
        p.* = .{
            .head = "target",
            .text = try std.fmt.allocPrint(
                arena,
                "(target :name {s} :arity {s})",
                .{ spec[0..sp], spec[sp + 1 ..] },
            ),
            .comments = &.{},
            .span = .{ .start = 0, .end = 1 },
        };
    }
    return out;
}

fn bound(
    name: []const u8,
    kind: doc.LaneKind,
    address: doc.Address,
    range: ?[2]f32,
) doc.Lane {
    return .{
        .name = name,
        .kind = kind,
        .target = name,
        .range = range,
        .binding = .{ .anchor = "song", .address = address },
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = .{ .start = 0, .end = 1 },
    };
}
