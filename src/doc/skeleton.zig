//! The skeleton: a timeline tier derived from a file that carries no
//! residue (plan 04, "Reconciliation", rule 1).
//!
//! A `.mid` or a `.it` tempura never wrote has no essence in it, and the
//! document it dumps to must still be usable. So the bridge reads the
//! addresses the file actually uses and states them: one bound `notes`
//! lane per used address, one bound `curve` lane per controller that
//! moved, the file's own markers as cues, and `:conductor` set to the
//! anchor — the file conducts, because nothing else can.
//!
//! Nothing here is a guess. Every lane names an address the file
//! carries, and a lane whose address is silent is not derived: rule 1's
//! "more than one value" is the line between a controller that was
//! AUTOMATED and one that was merely set once.
//!
//! No diagnostics: rule 1 says so in as many words. The conversions this
//! walks (an SMF tick on an inexact division, a SMPTE file's ignored
//! tempo) are the CONDUCTOR map's to report, and it reports them once
//! per dump rather than once per lane.

const std = @import("std");

const Diag = @import("../Diag.zig");
const Doc = @import("Value.zig");
const Grid = @import("../time/Grid.zig");
const bridge_it = @import("bridge_it.zig");
const itf = @import("../itf/itf.zig");
const model = itf.model;
const smf = @import("../smf/smf.zig");
const walk = itf.walk;

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Explicit error set: only resource exhaustion.
pub const Error = error{OutOfMemory};

/// The line a derived document opens with, so a reader knows at a glance
/// that the timeline was inferred and not restored (plan 04, rule 1).
pub const header_comment = "; skeleton: derived, no residue found";

pub const Options = struct {
    /// `--cues`: emit one cue per played IT order (plan 04, rule 1; plan
    /// 06, "Bound lanes over a module"). Off by default because an
    /// order list is long and a cue per order is a lot of noise in a
    /// document nobody asked for it in. SMF markers and cue points are
    /// not gated: a marker IS a cue the author wrote.
    cues: bool = false,
};

/// What `derive` returns: the tier, owned by one arena.
pub const Result = struct {
    lanes: []Doc.Lane,
    cues: []Doc.Cue,
    /// The anchor the derived tier is conducted by — the first tier's,
    /// and null when the document holds no inline dump at all.
    conductor: ?Doc.AnchorId,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }

    /// The lane named `name`, or null. The tests' join.
    pub fn laneByName(self: *const Result, name: []const u8) ?*const Doc.Lane {
        for (self.lanes) |*l| {
            if (std.mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }
};

/// Derive the skeleton of `doc`'s inline tiers.
pub fn derive(gpa: Allocator, doc: *const Doc.Doc, opts: Options) Error!Result {
    doc.invariants();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: Deriver = .{ .gpa = gpa, .arena = arena, .opts = opts };
    // The tiers in document order, so the FIRST inline dump is the
    // conductor: rule 1 is written for one file per document, and a
    // second would need an author to say which of them keeps time.
    for (doc.midi) |*tier| {
        if (d.conductor == null) d.conductor = try arena.dupe(u8, tier.anchor);
        try d.smfTier(tier);
    }
    for (doc.it) |*tier| {
        if (d.conductor == null) d.conductor = try arena.dupe(u8, tier.anchor);
        try d.itTier(tier);
    }

    // Cues read in tick order; ties keep the order they were found in,
    // so the same file always derives the same document.
    std.mem.sort(Doc.Cue, d.cues.items, {}, cueBefore);
    return .{
        .lanes = d.lanes.items,
        .cues = d.cues.items,
        .conductor = d.conductor,
        .arena = arena_state,
    };
}

fn cueBefore(_: void, x: Doc.Cue, y: Doc.Cue) bool {
    return x.at < y.at;
}

/// How many DISTINCT values one controller surface took. Rule 1's "more
/// than one value" is the line between automation and a setting, so two
/// is as high as this has to count.
const Seen = struct {
    count: u2 = 0,
    first: u16 = 0,

    fn saw(self: *Seen, value: u16) void {
        if (self.count == 0) {
            self.first = value;
            self.count = 1;
        } else if (self.count == 1 and value != self.first) self.count = 2;
    }

    fn moved(self: Seen) bool {
        return self.count == 2;
    }
};

/// What one SMF track's events say, channel by channel: whether it
/// sounded, and how many values each controller surface took.
const Census = struct {
    /// Sixteen channels of 128 controllers, the caller's buffer.
    cc: []Seen,
    sounds: [16]bool = @splat(false),
    bend: [16]Seen = @splat(.{}),
    pressure: [16]Seen = @splat(.{}),

    fn saw(self: *Census, e: smf.Event) void {
        switch (e.kind) {
            // A note-off alone does not make an address a lane: an
            // orphan off is what a DAW leaves behind, not music.
            .note_on => if (e.payload.note.vel > 0 and e.payload.note.ch < 16) {
                self.sounds[e.payload.note.ch] = true;
            },
            .control_change => {
                const c = e.payload.control;
                if (c.ch < 16 and c.num < 128) self.cc[@as(usize, c.ch) * 128 + c.num].saw(c.val);
            },
            .pitch_bend => if (e.payload.bend.ch < 16) {
                self.bend[e.payload.bend.ch].saw(e.payload.bend.value);
            },
            .channel_pressure => if (e.payload.pressure.ch < 16) {
                self.pressure[e.payload.pressure.ch].saw(e.payload.pressure.val);
            },
            else => {},
        }
    }
};

const Deriver = struct {
    gpa: Allocator,
    /// The result's arena — every name and every slice lands here.
    arena: Allocator,
    opts: Options,
    lanes: std.ArrayList(Doc.Lane) = .empty,
    cues: std.ArrayList(Doc.Cue) = .empty,
    conductor: ?Doc.AnchorId = null,

    // ---- the SMF half ----

    fn smfTier(self: *Deriver, tier: *const Doc.SmfTier) Error!void {
        const seq = &tier.sequence;
        const ppq = seq.division.pulsesPerQuarter();
        // The census's controller table, on the heap and reset per
        // track: sixteen channels of 128 controllers is more than a
        // stack frame should carry.
        const cc = try self.gpa.alloc(Seen, 16 * 128);
        defer self.gpa.free(cc);

        for (seq.tracks, 0..) |track, index| {
            // A `(lane :track …)` is a u16, so a track past 65,535 has no
            // lane to derive — and no count to warn in: `smf/read` has
            // said `smf_ntrks_mismatch`, a header's u16 being unable to
            // number them either, and rule 1 raises nothing of its own.
            const number = std.math.cast(u16, index + 1) orelse break;
            @memset(cc, .{});
            var census: Census = .{ .cc = cc };
            for (track.events) |e| switch (e.kind) {
                .marker, .cue_point => try self.smfCue(seq, e, ppq),
                else => census.saw(e),
            };
            for (0..16) |ch| try self.smfChannel(tier.anchor, number, @intCast(ch), &census);
        }
    }

    /// The lanes one channel of one track earns: a notes lane when it
    /// sounded, a curve per surface that moved.
    fn smfChannel(
        self: *Deriver,
        anchor: Doc.AnchorId,
        number: u16,
        ch: u4,
        census: *const Census,
    ) Error!void {
        const at: usize = ch;
        const base = try std.fmt.allocPrint(self.arena, "t{d}-ch{d}", .{ number, at + 1 });
        if (census.sounds[at]) try self.smfLane(anchor, base, .notes, number, ch, null);
        for (0..128) |num| {
            if (!census.cc[at * 128 + num].moved()) continue;
            const name = try std.fmt.allocPrint(self.arena, "{s}-cc{d}", .{ base, num });
            try self.smfLane(anchor, name, .curve, number, ch, .{ .cc = @intCast(num) });
        }
        if (census.bend[at].moved()) {
            const name = try std.fmt.allocPrint(self.arena, "{s}-bend", .{base});
            try self.smfLane(anchor, name, .curve, number, ch, .bend);
        }
        if (census.pressure[at].moved()) {
            const name = try std.fmt.allocPrint(self.arena, "{s}-pressure", .{base});
            try self.smfLane(anchor, name, .curve, number, ch, .pressure);
        }
    }

    fn smfLane(
        self: *Deriver,
        anchor: Doc.AnchorId,
        name: []const u8,
        kind: Doc.LaneKind,
        track: u16,
        ch: u4,
        curve: ?Doc.SmfCurve,
    ) Error!void {
        try self.lanes.append(self.arena, lane(try self.arena.dupe(u8, anchor), name, kind, .{
            .smf = .{
                .track = track,
                .ch = .single(ch),
                // One lane per ADDRESS: splitting a drum track by key is an
                // edit an author makes, not one a derivation guesses.
                .key = null,
                .curve = curve,
            },
        }));
    }

    fn smfCue(self: *Deriver, seq: *const smf.Sequence, e: smf.Event, ppq: u15) Error!void {
        const text = seq.bytesOf(e.payload.bytes);
        // A marker whose bytes are not UTF-8 has no name a document can
        // spell; it stays in the `midi/` tier, where it is exact.
        if (!std.unicode.utf8ValidateSlice(text)) return;
        try self.cues.append(self.arena, .{
            .name = try self.arena.dupe(u8, text),
            .at = Grid.smfToTicks(e.at, ppq).tick,
            .span = .{ .start = 0, .end = 0 },
        });
    }

    // ---- the IT half ----

    fn itTier(self: *Deriver, tier: *const Doc.ItTier) Error!void {
        const m = &tier.module;

        for (0..model.channels) |ch| {
            var sounds = false;
            var vol: Seen = .{};
            var pan: Seen = .{};
            for (m.patterns) |pat| {
                for (0..pat.rows) |r| {
                    const c = pat.at(r, ch).*;
                    if (c.note <= model.note_max) sounds = true;
                    if (c.vol <= 64) vol.saw(c.vol);
                    // The pan column is the volume column's `pXX` codes
                    // AND the `Xxx` effect (plan 06). The two scales are
                    // kept apart in the key so a `p16` and an `X 3F` are
                    // the two different values they are.
                    if (c.vol >= 128 and c.vol <= 192) pan.saw(@as(u16, c.vol) - 128 + 256);
                    if (c.fx == 'X' - '@') pan.saw(c.param);
                }
            }

            const wire: u6 = @intCast(ch);
            const base = try std.fmt.allocPrint(self.arena, "ch{d}", .{ch + 1});
            if (sounds) try self.itLane(tier.anchor, base, .notes, wire, null);
            if (vol.moved()) try self.itLane(
                tier.anchor,
                try std.fmt.allocPrint(self.arena, "{s}-vol", .{base}),
                .curve,
                wire,
                .vol,
            );
            if (pan.moved()) try self.itLane(
                tier.anchor,
                try std.fmt.allocPrint(self.arena, "{s}-pan", .{base}),
                .curve,
                wire,
                .pan,
            );
        }

        if (!self.opts.cues) return;
        var rowmap = try walk.derive(self.gpa, m, .{});
        defer rowmap.deinit();
        var order_cues = try bridge_it.orderCues(self.gpa, &rowmap);
        defer order_cues.deinit();
        for (order_cues.items) |c| try self.cues.append(self.arena, .{
            .name = try self.arena.dupe(u8, c.name),
            // IT ticks into tempura's own grid (plan 03, "The grid").
            .at = c.at * Grid.IT_TICK,
            .span = .{ .start = 0, .end = 0 },
        });
    }

    fn itLane(
        self: *Deriver,
        anchor: Doc.AnchorId,
        name: []const u8,
        kind: Doc.LaneKind,
        channel: u6,
        column: ?Doc.ItColumn,
    ) Error!void {
        try self.lanes.append(self.arena, lane(try self.arena.dupe(u8, anchor), name, kind, .{
            .it = .{
                .channel = channel,
                .column = column,
                // A curve over the effect column needs a LETTER, and the
                // column carries commands rather than a level, so there is
                // no one value to read: an `fx` lane is the author's or the
                // residue's, never a guess (plan 06, "Bound lanes").
                .fx = null,
            },
        }));
    }
};

/// A bound lane with no content of its own — which is what every lane a
/// skeleton derives is (plan 04: the file's content stays in the file).
fn lane(anchor: Doc.AnchorId, name: []const u8, kind: Doc.LaneKind, address: Doc.Address) Doc.Lane {
    return .{
        .name = name,
        .kind = kind,
        // `:target` defaults to `:name`, so the printer writes neither.
        .target = name,
        .range = null,
        .binding = .{ .anchor = anchor, .address = address },
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = .{ .start = 0, .end = 0 },
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// A document holding one inline tier and nothing else: the shape a
/// `.mid` or a `.it` dumps to before rule 1 has run.
fn docWith(gpa: Allocator, midi: []Doc.SmfTier, it: []Doc.ItTier) Doc.Doc {
    var d: Doc.Doc = .empty(gpa);
    d.midi = midi;
    d.it = it;
    return d;
}

/// A two-track sequence: a conductor track with a marker and a cue
/// point, and a drum track whose channel 10 carries notes, a controller
/// that moves, a controller that does not, a bend that moves and a
/// channel pressure that does not.
fn smfFixture(gpa: Allocator) !smf.Sequence {
    var b: smf.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = 480 };

    const conductor = try b.addTrack();
    try b.addEvent(conductor, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(conductor, 7680, .marker, .{ .bytes = try b.addBytes("drop") });
    try b.addEvent(conductor, 960, .cue_point, .{ .bytes = try b.addBytes("verse") });
    try b.addEvent(conductor, 15360, .end_of_track, .empty);

    const drums = try b.addTrack();
    try b.addEvent(drums, 0, .note_on, .{ .note = .{ .ch = 9, .key = 36, .vel = 110 } });
    try b.addEvent(drums, 120, .note_off, .{ .note = .{ .ch = 9, .key = 36, .vel = 0 } });
    // `cc 7` moves; `cc 10` is set once and never moves again.
    try b.addEvent(drums, 0, .control_change, .{ .control = .{ .ch = 9, .num = 7, .val = 100 } });
    try b.addEvent(drums, 480, .control_change, .{ .control = .{ .ch = 9, .num = 7, .val = 60 } });
    try b.addEvent(drums, 0, .control_change, .{ .control = .{ .ch = 9, .num = 10, .val = 64 } });
    try b.addEvent(drums, 480, .control_change, .{ .control = .{ .ch = 9, .num = 10, .val = 64 } });
    try b.addEvent(drums, 0, .pitch_bend, .{ .bend = .{ .ch = 9, .value = 8192 } });
    try b.addEvent(drums, 480, .pitch_bend, .{ .bend = .{ .ch = 9, .value = 9000 } });
    try b.addEvent(drums, 0, .channel_pressure, .{ .pressure = .{ .ch = 9, .val = 80 } });
    // A second channel that only ever gets a program change: no lane.
    try b.addEvent(drums, 0, .program_change, .{ .program = .{ .ch = 0, .num = 4 } });
    try b.addEvent(drums, 15360, .end_of_track, .empty);

    return b.finish();
}

test "skeleton: tracks past the 65,535 a lane can address derive no lane, and never trap" {
    // `smf/read` keeps every MTrk it finds, and 65,536 empty ones fit in
    // half a mebibyte. The track number was `@intCast` to the `u16` a
    // `(lane :track …)` holds; past it there is no lane to derive.
    const gpa = testing.allocator;
    var b: smf.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 480 };
    for (0..65_537) |_| _ = try b.addTrack();
    const last_addressable: u32 = 65_534;
    for ([_]u32{ last_addressable, 65_535, 65_536 }) |t| {
        try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 90 } });
    }

    var tiers = [_]Doc.SmfTier{.{ .anchor = "wide", .sequence = try b.finish() }};
    var doc = docWith(gpa, &tiers, &.{});
    defer doc.deinit();

    var sk = try derive(gpa, &doc, .{});
    defer sk.deinit();
    try testing.expectEqual(@as(usize, 1), sk.lanes.len);
    try testing.expectEqualStrings("t65535-ch1", sk.lanes[0].name);
    try testing.expectEqual(@as(u16, 65_535), sk.lanes[0].binding.?.address.smf.track);
}

test "skeleton: an SMF tier names one notes lane per address and one curve per mover" {
    const gpa = testing.allocator;

    var tiers = [_]Doc.SmfTier{.{ .anchor = "song", .sequence = try smfFixture(gpa) }};
    var doc = docWith(gpa, &tiers, &.{});
    defer doc.deinit();

    var sk = try derive(gpa, &doc, .{});
    defer sk.deinit();

    try testing.expectEqualStrings("song", sk.conductor.?);

    // The addresses the file uses, in track then channel then
    // controller order — and nothing else.
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    for (sk.lanes, 0..) |l, i| {
        if (i > 0) try names.appendSlice(gpa, " ");
        try names.appendSlice(gpa, l.name);
    }
    try testing.expectEqualStrings("t2-ch10 t2-ch10-cc7 t2-ch10-bend", names.items);

    const notes = sk.laneByName("t2-ch10").?;
    try testing.expectEqual(Doc.LaneKind.notes, notes.kind);
    try testing.expectEqualStrings("t2-ch10", notes.target);
    try testing.expectEqualStrings("song", notes.binding.?.anchor);
    try testing.expectEqual(@as(u16, 2), notes.binding.?.address.smf.track);
    try testing.expect(notes.binding.?.address.smf.ch.eql(.single(9)));
    // One lane per ADDRESS, never per key: a drum split is the author's.
    try testing.expect(notes.binding.?.address.smf.key == null);
    try testing.expect(notes.binding.?.address.smf.curve == null);
    try testing.expectEqual(@as(usize, 0), notes.notes.len);

    const cc = sk.laneByName("t2-ch10-cc7").?;
    try testing.expectEqual(Doc.LaneKind.curve, cc.kind);
    try testing.expectEqual(@as(u7, 7), cc.binding.?.address.smf.curve.?.cc);

    const bend = sk.laneByName("t2-ch10-bend").?;
    try testing.expectEqual(Doc.SmfCurve.bend, bend.binding.?.address.smf.curve.?);
}

test "skeleton: an SMF tier's markers and cue points become cues, in tick order" {
    const gpa = testing.allocator;

    var tiers = [_]Doc.SmfTier{.{ .anchor = "song", .sequence = try smfFixture(gpa) }};
    var doc = docWith(gpa, &tiers, &.{});
    defer doc.deinit();

    var sk = try derive(gpa, &doc, .{});
    defer sk.deinit();

    try testing.expectEqual(@as(usize, 2), sk.cues.len);
    // 960 SMF ticks at 480 PPQ is two quarter notes.
    try testing.expectEqualStrings("verse", sk.cues[0].name);
    try testing.expectEqual(@as(i64, 2 * Grid.TPQ), sk.cues[0].at);
    try testing.expectEqualStrings("drop", sk.cues[1].name);
    try testing.expectEqual(@as(i64, 16 * Grid.TPQ), sk.cues[1].at);
}

/// A module whose channel 1 carries notes, channel 2 a volume column
/// that moves and a pan code that does not, and channel 3 nothing but an
/// effect.
fn itFixture(gpa: Allocator) !itf.Module {
    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();

    const p = try b.addPattern(8);
    p.at(0, 0).* = .{ .note = 60, .ins = 1 };
    p.at(4, 0).* = .{ .note = model.note_off };
    p.at(0, 1).* = .{ .vol = 0 };
    p.at(2, 1).* = .{ .vol = 64 };
    p.at(4, 1).* = .{ .vol = 128 + 16 };
    // A tone portamento: an effect the timing walk never reads, so the
    // song's second pass repeats its state at once and the walk stops
    // where it started.
    p.at(0, 2).* = .{ .fx = 'G' - '@', .param = 0x80 };

    const q = try b.addPattern(8);
    q.at(0, 0).* = .{ .note = 62, .ins = 1 };

    try b.addOrder(0);
    try b.addOrder(1);
    try b.addOrder(walk.order_end);
    return b.finish();
}

test "skeleton: an IT tier names a lane per channel with notes and per column that moves" {
    const gpa = testing.allocator;

    var tiers = [_]Doc.ItTier{.{ .anchor = "song", .module = try itFixture(gpa) }};
    var doc = docWith(gpa, &.{}, &tiers);
    defer doc.deinit();

    var sk = try derive(gpa, &doc, .{});
    defer sk.deinit();

    try testing.expectEqualStrings("song", sk.conductor.?);

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    for (sk.lanes, 0..) |l, i| {
        if (i > 0) try names.appendSlice(gpa, " ");
        try names.appendSlice(gpa, l.name);
    }
    // Channel 2's pan code appears once, so it never moved: no lane.
    // Channel 3 carries only an effect, which is a command and not a
    // level, so the skeleton names nothing there either.
    try testing.expectEqualStrings("ch1 ch2-vol", names.items);

    const notes = sk.laneByName("ch1").?;
    try testing.expectEqual(Doc.LaneKind.notes, notes.kind);
    try testing.expectEqual(@as(u6, 0), notes.binding.?.address.it.channel);
    try testing.expect(notes.binding.?.address.it.column == null);

    const vol = sk.laneByName("ch2-vol").?;
    try testing.expectEqual(Doc.LaneKind.curve, vol.kind);
    try testing.expectEqual(@as(u6, 1), vol.binding.?.address.it.channel);
    try testing.expectEqual(Doc.ItColumn.vol, vol.binding.?.address.it.column.?);
}

test "skeleton: IT order cues only with --cues" {
    const gpa = testing.allocator;

    var tiers = [_]Doc.ItTier{.{ .anchor = "song", .module = try itFixture(gpa) }};
    var doc = docWith(gpa, &.{}, &tiers);
    defer doc.deinit();

    var quiet = try derive(gpa, &doc, .{});
    defer quiet.deinit();
    try testing.expectEqual(@as(usize, 0), quiet.cues.len);

    var loud = try derive(gpa, &doc, .{ .cues = true });
    defer loud.deinit();
    try testing.expectEqual(@as(usize, 2), loud.cues.len);
    try testing.expectEqualStrings("order 0 — pattern 0", loud.cues[0].name);
    try testing.expectEqual(@as(i64, 0), loud.cues[0].at);
    try testing.expectEqualStrings("order 1 — pattern 1", loud.cues[1].name);
    // Eight rows of six ticks, in tempura's own grid.
    try testing.expectEqual(@as(i64, 48 * Grid.IT_TICK), loud.cues[1].at);
}

test "skeleton: a document with no inline tier derives nothing and says so" {
    const gpa = testing.allocator;
    var doc: Doc.Doc = .empty(gpa);
    defer doc.deinit();

    var sk = try derive(gpa, &doc, .{});
    defer sk.deinit();
    try testing.expectEqual(@as(usize, 0), sk.lanes.len);
    try testing.expectEqual(@as(usize, 0), sk.cues.len);
    try testing.expect(sk.conductor == null);
}
