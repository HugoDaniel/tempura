//! The IT timing walk: `Module` → `RowMap`.
//!
//! it 06's `Timeline.derive` with the audio chain off (plan 06, "The
//! timing walk"): the order walk with every timing-affecting effect,
//! over `Module` and nothing else, all integers. The unit is the **IT
//! tick**; turning ticks into tempura ticks (`× 1 921 920`) and tempo
//! into `qpm` is plan 03's job, not this file's.

const std = @import("std");
const Diag = @import("../Diag.zig");
const model = @import("Module.zig");

const Module = model.Module;
const testing = std.testing;

/// Only resource exhaustion is an error; everything the walk finds wrong
/// with a module is a diagnostic on the returned map.
pub const Error = error{OutOfMemory};

// ---- the output ----

/// One row the walk PLAYED, in order of play. `start_tick` and `ticks`
/// are IT ticks; `pattern` is the pattern `order` named, carried so a
/// consumer need not re-read the order list.
///
/// One entry per row READ: an `SEx` row delay repeats a row without
/// re-reading it, so its repeats are inside this entry's `ticks` — which
/// is also what a tracker shows, the cursor held on the row for the
/// whole delay.
pub const PlayedRow = struct {
    order: u16,
    pattern: u16,
    row: u16,
    start_tick: i64,
    ticks: u16,
};

/// The tempo in force from `start_tick` until the next segment. One per
/// tempo CHANGE (plan 06, "The timing walk"), the first at tick 0 with
/// the module's initial tempo; `start_tick`s strictly increase.
pub const TempoSeg = struct {
    start_tick: i64,
    tempo: u8,
};

/// A cell that carries a note, at the tick it sounds: the row's start
/// plus its `SDx` delay. Every note spelling is here — a pitch, `^^^`,
/// `===` and `~~~` alike — because what ENDS a note is a cell too (plan
/// 06, "Bound lanes over a module"). `row_index` indexes `RowMap.rows`.
pub const Onset = struct {
    channel: u8,
    tick: i64,
    row_index: u32,
    cell: model.Cell,
};

/// What `orderRowAt` answers: the tracker position at a tick.
pub const Position = struct {
    order: u16,
    row: u16,
    tick_in_row: u16,
};

/// The walk's bounds (plan 06: "`--loops N` and `--max-rows` bound it
/// for the CLI"). `max_rows` rows played trips `walk_runaway`; `loops`
/// is how many times the walk may enter one timing state before it
/// stops, so 1 — the default — walks the song to its loop point once,
/// and 2 goes round the loop one more time. 0 is read as 1.
pub const Options = struct {
    max_rows: u32 = 1 << 20,
    loops: u8 = 1,
};

/// The timing map of a module: every played row with its start and
/// length, the tempo at every tick, the note onsets, the total and the
/// loop point.
///
/// Arena-backed: `deinit()` frees the lot. `loop_row` indexes `rows` —
/// the row the walk would have replayed when it stopped, or null when it
/// stopped for another reason (the runaway cap, an unplayable module).
///
/// `rows` are contiguous and cover `[0, total_ticks)`: each starts where
/// the one before it ended, which is what `orderRowAt` searches. `onsets`
/// come in (row, channel) order — time order within a channel, but not
/// across channels, since `SDx` moves one channel's note late.
pub const RowMap = struct {
    arena: std.heap.ArenaAllocator,
    rows: []PlayedRow = &.{},
    segments: []TempoSeg = &.{},
    onsets: []Onset = &.{},
    total_ticks: i64 = 0,
    loop_row: ?u32 = null,
    diags: Diag.List,

    pub fn deinit(self: *RowMap) void {
        self.diags.deinit();
        self.arena.deinit();
    }
};

// ---- the timing effects, by ITTECH's command number ----
//
// `Cell.fx` is 1–26 for A–Z (`cmd = letter - '@'`). Which effects are
// "timing" is plan 06's closed list: everything else changes what
// sounds, not when a row starts, and the walk ignores it.

/// `Axx` — set speed.
const fx_a: u8 = 'A' - '@';
/// `Bxx` — jump to order.
const fx_b: u8 = 'B' - '@';
/// `Cxx` — break to row.
const fx_c: u8 = 'C' - '@';
/// `Sxy` — the special family: `S6x`, `SBx`, `SDx`, `SEx` here.
const fx_s: u8 = 'S' - '@';
/// `Txx` — set tempo or slide it.
const fx_t: u8 = 'T' - '@';

/// A slide never takes the tempo outside IT's range (plan 06: "clamped
/// 32–255"); the HEADER's own floor is 31, one lower, and lives in
/// `Header.effectiveTempo`.
const tempo_min: i16 = 32;
const tempo_max: i16 = 255;

// ---- the order list's two markers (it 04 §Header) ----

/// `+++` — this order plays nothing and the walk moves on.
pub const order_skip: u8 = 254;
/// `---` — the song ends here.
pub const order_end: u8 = 255;

// ---- the walk ----

/// `Module` → `RowMap`, in IT ticks. Reads the module and nothing else
/// (plan 06: "the walk reads `Module` and nothing else"), so the same
/// module always gives the same map.
pub fn derive(gpa: std.mem.Allocator, module: *const Module, opts: Options) Error!RowMap {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var w: Walker = .{
        .a = arena.allocator(),
        .module = module,
        .opts = opts,
        .diags = &diags,
        .speed = module.header.effectiveSpeed(),
        .tempo = module.header.effectiveTempo(),
    };
    // "the first at tick 0 with the initial tempo" (plan 06).
    try w.segments.append(w.a, .{ .start_tick = 0, .tempo = w.tempo });
    try w.run(gpa);

    return .{
        .arena = arena,
        .rows = w.rows.items,
        .segments = w.segments.items,
        .onsets = w.onsets.items,
        .total_ticks = w.tick,
        .loop_row = w.loop_row,
        .diags = diags,
    };
}

/// The tracker position at `tick`: the `(order, row)` the walk was
/// playing and how far into it the tick falls, by binary search over
/// `map.rows`. Null before the walk's start and at or past its end.
///
/// The rows are contiguous — each starts where the one before it ended —
/// so the answer is the last row that starts at or before `tick`.
pub fn orderRowAt(map: *const RowMap, tick: i64) ?Position {
    if (map.rows.len == 0 or tick < 0 or tick >= map.total_ticks) return null;

    var lo: usize = 0;
    var hi: usize = map.rows.len;
    // Invariant: `rows[lo].start_tick <= tick < rows[hi].start_tick`,
    // with `hi` one past the end standing for the total.
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (map.rows[mid].start_tick <= tick) lo = mid else hi = mid;
    }

    const r = map.rows[lo];
    return .{
        .order = r.order,
        .row = r.row,
        .tick_in_row = @intCast(tick - r.start_tick),
    };
}

/// What one channel remembers between rows: the timing effects' memories
/// (it 06's effect table — `mem_tempo` is what `T00` recalls).
const Chan = struct {
    mem_tempo: u8 = 0,
    mem_special: u8 = 0,
    /// Where `SB0` last marked this channel's pattern loop.
    loop_start: u16 = 0,
    /// How many times round the loop is left to go; 0 = no loop running.
    loop_count: u8 = 0,
};

/// The state a revisited `(order, row)` is compared on — the walk ends at
/// the first `(order, row)` reached twice in the same timing state, and
/// that is the loop point (plan 06, "Termination": "speed, tempo, loop
/// counters, effect memories").
///
/// The 64 channels' state is folded into two independently seeded
/// digests rather than carried whole, so the seen-set's key stays small
/// however many channels carry memories: a false loop point would have
/// to collide in both digests at once.
const Key = struct {
    order: u16,
    row: u16,
    speed: u8,
    tempo: u8,
    h0: u64,
    h1: u64,
};

/// What the end of a row does, in the one slot `Bxx` and `SBx` share.
const Pending = union(enum) {
    none,
    /// `Bxx`: the order to play next.
    jump: u8,
    /// `SBx`: the row in THIS pattern to go back to.
    loop: u16,
};

const Seen = struct {
    /// The index into `rows` of the first visit — the loop point.
    first: u32,
    /// Counted, not flagged, because `Options.loops` may ask for more
    /// than one time round.
    visits: u32,
};

/// What one row READ asks of the walk. The state changes its tick-0
/// effects made — speed, tempo, memories, loop counters — are already in
/// the walker; this is what is left to say about the row itself.
const RowRead = struct {
    /// `S6x`, cleared with the row it lengthened.
    frame_delay: u16 = 0,
    /// `SEx` + 1: how many times the row plays.
    row_plays: u16 = 1,
    /// `Bxx` / `SBx`, in the one slot they share.
    pending: Pending = .none,
    /// `Cxx`.
    break_row: ?u8 = null,
    /// `T0x` / `T1x` per channel, applied on every non-row tick.
    slides: [model.channels]i8 = @splat(0),
    any_slide: bool = false,
    /// `SDx` per channel; 0 is "no delay", since `SD0` is `SD1`.
    delays: [model.channels]u8 = @splat(0),
};

/// Where the walk goes when a row is over.
const Next = struct {
    order: u16,
    row: u16,
};

const Walker = struct {
    a: std.mem.Allocator,
    module: *const Module,
    opts: Options,
    diags: *Diag.List,

    speed: u8,
    tempo: u8,
    tick: i64 = 0,
    loop_row: ?u32 = null,
    chans: [model.channels]Chan = @splat(.{}),

    rows: std.ArrayList(PlayedRow) = .empty,
    segments: std.ArrayList(TempoSeg) = .empty,
    onsets: std.ArrayList(Onset) = .empty,

    /// The timing state a `(order, row)` is revisited with.
    fn key(self: *const Walker, order: u16, row: u16) Key {
        return .{
            .order = order,
            .row = row,
            .speed = self.speed,
            .tempo = self.tempo,
            .h0 = self.chanDigest(0x7465_6D70_7572_6100),
            .h1 = self.chanDigest(0x7761_6C6B_5F69_7400),
        };
    }

    /// The per-channel state, hashed byte by byte so the digest does not
    /// depend on the host's struct layout or endianness.
    fn chanDigest(self: *const Walker, seed: u64) u64 {
        var h: std.hash.Wyhash = .init(seed);
        for (self.chans) |c| h.update(&.{
            c.mem_tempo,
            c.mem_special,
            c.loop_count,
            @truncate(c.loop_start),
            @truncate(c.loop_start >> 8),
        });
        return h.final();
    }

    /// The parameter an `Sxy` acts on: its own, remembered for the
    /// channel, or — for `S00` — the one byte the channel remembers, the
    /// whole `Sxy` and not just its low nibble (it 06: `mem_special`,
    /// "S00 recalls").
    fn specialParam(self: *Walker, ch: usize, param: u8) u8 {
        if (param == 0) return self.chans[ch].mem_special;
        self.chans[ch].mem_special = param;
        return param;
    }

    /// The parameter a `Txx` acts on: its own, remembered for the
    /// channel, or — for `T00` — the one the channel remembers.
    fn tempoParam(self: *Walker, ch: usize, param: u8) u8 {
        if (param == 0) return self.chans[ch].mem_tempo;
        self.chans[ch].mem_tempo = param;
        return param;
    }

    /// Record the tempo in force from `at`. Nothing is recorded when the
    /// value did not change ("one per tempo CHANGE"), and a change at a
    /// tick a segment already starts on rewrites that segment, so the
    /// starts strictly increase.
    fn pushTempo(self: *Walker, at: i64) Error!void {
        const last = &self.segments.items[self.segments.items.len - 1];
        if (last.tempo == self.tempo) return;
        if (last.start_tick == at) {
            last.tempo = self.tempo;
            return;
        }
        try self.segments.append(self.a, .{ .start_tick = at, .tempo = self.tempo });
    }

    /// The order list's next playable entry at or after `from`, skipping
    /// what plays nothing and wrapping once at the end — "the song ends
    /// and loops" (plan 06). Null when the module has no playable order
    /// at all, which ends the walk.
    fn resolveOrder(self: *const Walker, from: u32) ?u16 {
        const orders = self.module.orders;
        var i: u32 = from;
        var wrapped = false;
        var guard: u32 = 0;
        while (guard <= 2 * orders.len + 2) : (guard += 1) {
            // `---`, and the end of the list, are both the end of the
            // song: it loops back to order 0. Twice round without a row
            // to play means there is nothing to play at all.
            if (i >= orders.len or orders[i] == order_end) {
                if (wrapped) return null;
                wrapped = true;
                i = 0;
                continue;
            }
            // `+++` plays nothing and the walk moves on. An order
            // naming a pattern the module does not have, or one with no
            // rows, plays nothing either — and a rowless pattern has to
            // be refused HERE, or a list of them would step from order
            // to order for ever. The reader produces neither (a rowless
            // pattern becomes an empty 64-row one), so they are guards
            // and not diagnostics.
            if (orders[i] == order_skip or
                orders[i] >= self.module.patterns.len or
                self.module.patterns[orders[i]].rows == 0)
            {
                i += 1;
                continue;
            }
            return @intCast(i);
        }
        return null;
    }

    /// Read a row's cells and run the tick-0 effects that touch time,
    /// channel by channel from the LEFT (plan 06 step 2: "Read the row's
    /// cells; process the tick-0 effects that touch time"). Which
    /// effects those are is plan 06's closed list; everything else
    /// changes what sounds, not when a row starts.
    fn readRow(self: *Walker, pat: model.Pattern, row: u16) RowRead {
        var out: RowRead = .{};
        var row_plays_set = false;

        for (0..model.channels) |ch| {
            const c = pat.at(row, ch).*;
            switch (c.fx) {
                // `Axx` sets the speed, `A00` keeps it — IT gives Axx no
                // memory (it 06's effect table).
                fx_a => if (c.param != 0) {
                    self.speed = c.param;
                },
                // `Bxx` — jump to order xx when this row is over.
                fx_b => out.pending = .{ .jump = c.param },
                // `Cxx` — break to row xx of the next order.
                fx_c => out.break_row = c.param,
                // The `Sxy` family.
                fx_s => {
                    const p = self.specialParam(ch, c.param);
                    switch (p >> 4) {
                        // `S6x` — fine pattern delay: x more ticks on
                        // this row.
                        0x6 => out.frame_delay += p & 0x0F,
                        // `SBx` — pattern loop. `SB0` marks; `SBx` runs
                        // the loop x times from the mark, the counter
                        // coming down to 0 when it is done.
                        0xB => {
                            const x: u8 = p & 0x0F;
                            const chan = &self.chans[ch];
                            if (x == 0) {
                                chan.loop_start = row;
                            } else {
                                if (chan.loop_count == 0) {
                                    chan.loop_count = x;
                                } else {
                                    chan.loop_count -= 1;
                                }
                                if (chan.loop_count > 0 and out.pending != .loop) {
                                    out.pending = .{ .loop = chan.loop_start };
                                }
                            }
                        },
                        // `SDx` — note delay. `SD0` sounds a tick late
                        // like `SD1` (plan 06, per OpenMPT's IT
                        // handling).
                        0xD => out.delays[ch] = @max(1, p & 0x0F),
                        // `SEx` — row delay, leftmost channel wins.
                        0xE => if (!row_plays_set) {
                            out.row_plays = (p & 0x0F) + 1;
                            row_plays_set = true;
                        },
                        else => {},
                    }
                },
                // `Txx` with `xx >= 0x20` sets the tempo. `T00` reads
                // this CHANNEL's memory before anything else applies,
                // and any other parameter becomes that memory (plan 06;
                // it 06's `mem_tempo`).
                fx_t => {
                    const p = self.tempoParam(ch, c.param);
                    if (p >= 0x20) {
                        self.tempo = p;
                    } else if (p >= 0x10) {
                        // `T1x`: up by x on every non-row tick.
                        out.slides[ch] = @intCast(p & 0x0F);
                        out.any_slide = true;
                    } else if (p > 0) {
                        // `T0x`: down by x. `T00` with nothing
                        // remembered lands here as 0 and does nothing.
                        out.slides[ch] = -@as(i8, @intCast(p));
                        out.any_slide = true;
                    }
                },
                else => {},
            }
        }
        return out;
    }

    /// The row's note onsets, in (row, channel) order — once per row
    /// READ, because a repeated row is not re-read and IT does not
    /// retrigger its notes. A delay of x ticks or more into a row that
    /// is only x ticks long suppresses the note altogether (plan 06);
    /// the measure is the row's own first play.
    fn emitOnsets(
        self: *Walker,
        pat: model.Pattern,
        row: u16,
        row_index: u32,
        start: i64,
        first_ticks: u16,
        delays: [model.channels]u8,
    ) Error!void {
        for (0..model.channels) |ch| {
            const c = pat.at(row, ch).*;
            if (c.note == model.note_none) continue;
            const delay = delays[ch];
            if (delay >= first_ticks) continue;
            try self.onsets.append(self.a, .{
                .channel = @intCast(ch),
                .tick = start + delay,
                .row_index = row_index,
                .cell = c,
            });
        }
    }

    /// The row's NON-row ticks: the tempo slides, one segment per tick
    /// the value actually changed (plan 06 step 1). Every play of a
    /// repeated row slides, because the latched effect keeps running
    /// even though the row is not read again.
    fn slideTempo(self: *Walker, start: i64, first_ticks: u16, r: RowRead) Error!void {
        var play: u16 = 0;
        var base = start;
        while (play < r.row_plays) : (play += 1) {
            const n = if (play == 0) first_ticks else self.speed;
            var t: u16 = 1;
            while (t < n) : (t += 1) {
                for (r.slides) |d| {
                    if (d == 0) continue;
                    self.tempo = @intCast(std.math.clamp(
                        @as(i16, self.tempo) + d,
                        tempo_min,
                        tempo_max,
                    ));
                }
                try self.pushTempo(base + t);
            }
            base += n;
        }
    }

    /// Where the row just played sends the walk, or null when the song
    /// has nothing left to play.
    fn advance(self: *const Walker, order: u16, row: u16, rows_in_pattern: u16, r: RowRead) ?Next {
        switch (r.pending) {
            // A loop stays inside the pattern and takes the break with
            // it.
            .loop => |target| return .{ .order = order, .row = target },
            // A jump lands on row 0, or on a `Cxx` row when the same row
            // asked for both.
            .jump => |target| return .{
                .order = self.resolveOrder(target) orelse return null,
                .row = r.break_row orelse 0,
            },
            .none => {
                if (r.break_row) |target| return .{
                    .order = self.resolveOrder(@as(u32, order) + 1) orelse return null,
                    .row = target,
                };
                if (row + 1 < rows_in_pattern) return .{ .order = order, .row = row + 1 };
                return .{
                    .order = self.resolveOrder(@as(u32, order) + 1) orelse return null,
                    .row = 0,
                };
            },
        }
    }

    fn run(self: *Walker, gpa: std.mem.Allocator) Error!void {
        var seen: std.AutoHashMap(Key, Seen) = .init(gpa);
        defer seen.deinit();
        const loops = @max(1, self.opts.loops);

        var order = self.resolveOrder(0) orelse return;
        var row: u16 = 0;

        while (true) {
            const pat_idx = self.module.orders[order];
            const pat = self.module.patterns[pat_idx];
            // A jump or a break can name a row the pattern does not
            // reach; the walk moves on to the next order, as IT does.
            if (row >= pat.rows) {
                order = self.resolveOrder(@as(u32, order) + 1) orelse break;
                row = 0;
                continue;
            }

            // The cap. A module whose timing state never repeats — a
            // tempo that slides for ever, a `Bxx` backwards onto a
            // changed state — would walk without end, so the walk gives
            // up and says so (plan 06, "Termination").
            if (self.rows.items.len >= self.opts.max_rows) {
                try self.diags.add(
                    .walk_runaway,
                    .err,
                    .{ .start = 0, .end = 0 },
                    "the walk gave up at order {d} row {d} after {d} rows: the module's timing state never repeated",
                    .{ order, row, self.opts.max_rows },
                );
                break;
            }

            // The walk ends at the first `(order, row)` revisited with an
            // identical timing state, and that first visit is the loop
            // point (plan 06, "Termination").
            const gop = try seen.getOrPut(self.key(order, row));
            if (gop.found_existing) {
                gop.value_ptr.visits += 1;
                if (gop.value_ptr.visits > loops) {
                    self.loop_row = gop.value_ptr.first;
                    break;
                }
            } else {
                gop.value_ptr.* = .{ .first = @intCast(self.rows.items.len), .visits = 1 };
            }

            const row_index: u32 = @intCast(self.rows.items.len);
            const start = self.tick;

            const r = self.readRow(pat, row);
            try self.pushTempo(start);

            // The row is as long as the state its OWN tick-0 effects
            // leave: plan 06 sketches the reload as "tick_count = speed +
            // frame_delay" before the read, but `S6x` ("fine pattern
            // delay") is defined to lengthen the row it sits on, so the
            // reload is the state at the moment the row starts playing —
            // OpenMPT's `GetNumTicksOnCurrentRow()`. Its first play
            // carries the frame delay; every `SEx` repeat is a plain
            // `speed`, because the row's effects do not run again.
            const first_ticks: u16 = self.speed + r.frame_delay;
            const ticks: u16 = first_ticks + (r.row_plays - 1) * self.speed;
            try self.rows.append(self.a, .{
                .order = order,
                .pattern = pat_idx,
                .row = row,
                .start_tick = start,
                .ticks = ticks,
            });
            try self.emitOnsets(pat, row, row_index, start, first_ticks, r.delays);
            if (r.any_slide) try self.slideTempo(start, first_ticks, r);
            self.tick = start + ticks;

            const next = self.advance(order, row, pat.rows, r) orelse break;
            order = next.order;
            row = next.row;
        }
    }
};

// ---- tests: one per red in plan 06's "Phases" item 4 ----

test "walk.derive: constant speed and tempo — four rows of six ticks" {
    // Hand computation. Header: speed 6, tempo 125 (`Header.fresh`).
    // Orders [0]; pattern 0 is four empty rows but for a C-5 on channel
    // 0 of row 0.
    //
    //   (order 0, pattern 0, row 0)  start 0   ticks 6
    //   (0, 0, 1)                    start 6   ticks 6
    //   (0, 0, 2)                    start 12  ticks 6
    //   (0, 0, 3)                    start 18  ticks 6
    //   past row 3 → order 1 → past the end of the orders → the song
    //   ends and loops to order 0, row 0, whose state (speed 6, tempo
    //   125, no memories) is the state of its first visit → the walk
    //   ends there and that first visit is the loop point.
    //
    //   total 24 ticks, one tempo segment {0, 125}, one onset at 0.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(4);
    pat.at(0, 0).* = .{ .note = 60 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqual(@as(usize, 4), map.rows.len);
    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 6, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 12, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 3, .start_tick = 18, .ticks = 6 },
    }, map.rows);
    try testing.expectEqual(@as(i64, 24), map.total_ticks);
    try testing.expectEqual(@as(?u32, 0), map.loop_row);
    try testing.expectEqualSlices(TempoSeg, &.{.{ .start_tick = 0, .tempo = 125 }}, map.segments);
    try testing.expectEqual(@as(usize, 1), map.onsets.len);
    try testing.expectEqual(@as(u8, 0), map.onsets[0].channel);
    try testing.expectEqual(@as(i64, 0), map.onsets[0].tick);
    try testing.expectEqual(@as(u32, 0), map.onsets[0].row_index);
    try testing.expectEqual(@as(u8, 60), map.onsets[0].cell.note);
    try testing.expectEqual(@as(usize, 0), map.diags.items().len);
}

test "walk.derive: Axx sets the speed from the row it is on, A00 keeps it" {
    // Hand computation. Speed 6, tempo 125; orders [0]; pattern 0 is
    // four rows with `A03` on channel 0 of row 2 and `A00` on channel 1
    // of row 3.
    //
    // `Axx` is a tick-0 effect on the row it appears on, so that row is
    // already the new length (it 06: "Axx set speed (tick0)"); `A00`
    // reuses nothing — IT gives Axx no memory — so it keeps what it
    // found.
    //
    //   idx  (order,row)  start  ticks  state BEFORE the row
    //   0    (0,0)        0      6      speed 6
    //   1    (0,1)        6      6      speed 6
    //   2    (0,2)        12     3      speed 6   ← A03 shortens THIS row
    //   3    (0,3)        15     3      speed 3   ← A00 keeps 3
    //   the song ends and loops to (0,0), whose state is now speed 3 and
    //   not the speed 6 of index 0, so the walk goes on:
    //   4    (0,0)        18     3      speed 3
    //   5    (0,1)        21     3      speed 3
    //   6    (0,2)        24     3      speed 3
    //   and the next row, (0,3) at speed 3, is index 3's state exactly —
    //   the FIRST `(order, row)` revisited with an identical timing
    //   state (plan 06, "Termination"), so the walk ends there and the
    //   loop point is index 3, not index 4. Total 27 ticks.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(4);
    pat.at(2, 0).* = .{ .fx = fx_a, .param = 3 };
    pat.at(3, 1).* = .{ .fx = fx_a, .param = 0 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 6, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 12, .ticks = 3 },
        .{ .order = 0, .pattern = 0, .row = 3, .start_tick = 15, .ticks = 3 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 18, .ticks = 3 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 21, .ticks = 3 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 24, .ticks = 3 },
    }, map.rows);
    try testing.expectEqual(@as(i64, 27), map.total_ticks);
    try testing.expectEqual(@as(?u32, 3), map.loop_row);
    try testing.expectEqualSlices(TempoSeg, &.{.{ .start_tick = 0, .tempo = 125 }}, map.segments);
}

test "walk.derive: the loop point compares the effect memories too" {
    // Hand computation. Speed 6, tempo 125; orders [0]; pattern 0 is
    // four rows, `T80` on channel 0 of row 1 (tempo 128) and `T7D` on
    // channel 0 of row 2 (tempo 125 again — 0x7D = 125).
    //
    // Speed and tempo come home at the end of the pattern, so ONLY the
    // memory tells the second pass from the first: after row 1 channel
    // 0 remembers 0x80, after row 2 it remembers 0x7D, and a `T00` on
    // that channel would recall it. The state a revisited row is
    // compared on therefore carries the per-channel effect memories
    // (plan 06, "Termination": "speed, tempo, loop counters, effect
    // memories").
    //
    //   idx  (order,row)  start  ticks  state BEFORE the row
    //   0    (0,0)        0      6      tempo 125, mem_tempo[0] = 0x00
    //   1    (0,1)        6      6      tempo 125, mem_tempo[0] = 0x00
    //   2    (0,2)        12     6      tempo 128, mem_tempo[0] = 0x80
    //   3    (0,3)        18     6      tempo 125, mem_tempo[0] = 0x7D
    //   the song ends and loops; (0,0) now carries mem_tempo[0] = 0x7D
    //   where index 0 carried 0x00, so the walk goes on:
    //   4    (0,0)        24     6      tempo 125, mem_tempo[0] = 0x7D
    //   5    (0,1)        30     6      tempo 125, mem_tempo[0] = 0x7D
    //   and the next row, (0,2) with tempo 128 and mem_tempo[0] = 0x80,
    //   is index 2's state exactly → the walk ends, loop point index 2.
    //   Total 36 ticks; the tempo changes at 6, 12 and 30.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(4);
    pat.at(1, 0).* = .{ .fx = fx_t, .param = 0x80 };
    pat.at(2, 0).* = .{ .fx = fx_t, .param = 0x7D };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 6, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 12, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 3, .start_tick = 18, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 24, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 30, .ticks = 6 },
    }, map.rows);
    try testing.expectEqual(@as(i64, 36), map.total_ticks);
    try testing.expectEqual(@as(?u32, 2), map.loop_row);
    try testing.expectEqualSlices(TempoSeg, &.{
        .{ .start_tick = 0, .tempo = 125 },
        .{ .start_tick = 6, .tempo = 128 },
        .{ .start_tick = 12, .tempo = 125 },
        .{ .start_tick = 30, .tempo = 128 },
    }, map.segments);
}

test "walk.derive: Txx sets the tempo and T00 recalls it on its own channel only" {
    // Hand computation. Speed 6, tempo 125; orders [0]; pattern 0 is six
    // rows:
    //
    //   row 1  channel 0  T80  → tempo 0x80 = 128, mem_tempo[0] = 0x80
    //   row 2  channel 1  T40  → tempo 0x40 = 64,  mem_tempo[1] = 0x40
    //   row 3  channel 0  T00  → recalls CHANNEL 0's 0x80 → tempo 128
    //   row 4  channel 2  T00  → channel 2 remembers nothing → no change
    //
    // `T00` reads its memory before anything else applies (plan 06), and
    // a memory belongs to one channel: channel 2's `T00` is not channel
    // 0's `T80`.
    //
    //   idx  (order,row)  start  state BEFORE the row (tempo; mem 0,1,2)
    //   0    (0,0)        0      125; 00 00 00
    //   1    (0,1)        6      125; 00 00 00
    //   2    (0,2)        12     128; 80 00 00
    //   3    (0,3)        18      64; 80 40 00
    //   4    (0,4)        24     128; 80 40 00
    //   5    (0,5)        30     128; 80 40 00
    //   the song loops; (0,0) now carries the memories → the walk goes on
    //   6    (0,0)        36     128; 80 40 00
    //   7    (0,1)        42     128; 80 40 00   (T80 → 128 again: no
    //                                             change, no segment)
    //   8    (0,2)        48     128; 80 40 00   (index 2 had mem 1 = 00)
    //   and the next row, (0,3) with tempo 64 and mem 80 40 00, is index
    //   3's state → the walk ends. Nine rows, 54 ticks, loop point 3.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(6);
    pat.at(1, 0).* = .{ .fx = fx_t, .param = 0x80 };
    pat.at(2, 1).* = .{ .fx = fx_t, .param = 0x40 };
    pat.at(3, 0).* = .{ .fx = fx_t, .param = 0x00 };
    pat.at(4, 2).* = .{ .fx = fx_t, .param = 0x00 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqual(@as(usize, 9), map.rows.len);
    try testing.expectEqual(@as(i64, 54), map.total_ticks);
    try testing.expectEqual(@as(?u32, 3), map.loop_row);
    try testing.expectEqualSlices(TempoSeg, &.{
        .{ .start_tick = 0, .tempo = 125 },
        .{ .start_tick = 6, .tempo = 128 },
        .{ .start_tick = 12, .tempo = 64 },
        .{ .start_tick = 18, .tempo = 128 },
        .{ .start_tick = 48, .tempo = 64 },
    }, map.segments);
}

test "walk.derive: T0x and T1x slide the tempo once per NON-row tick, clamped 32-255" {
    // Hand computation. Speed 6, tempo 125; orders [0]; pattern 0 is two
    // rows: `T02` on channel 0 of row 0 (slide down 2) and `T12` on
    // channel 1 of row 1 (slide up 2). A slide moves on every tick of
    // the row but tick 0 — five ticks of a six-tick row — so each row
    // walks the tempo ten steps and back (it 06: "slide T0x−, T1x+ per
    // non-row tick"), and every step is its own segment.
    //
    //   row 0, start 0:   tick 1  2   3   4   5
    //                     tempo 123 121 119 117 115
    //   row 1, start 6:   tick 7  8   9   10  11
    //                     tempo 117 119 121 123 125
    //
    // The tempo comes home at 125, but channel 0 now remembers 0x02 and
    // channel 1 0x12, so the loop goes round twice: the second pass
    // repeats the same ten steps at ticks 13–17 and 19–23, and its first
    // row (index 2) is the loop point. Four rows, 24 ticks.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(2);
    pat.at(0, 0).* = .{ .fx = fx_t, .param = 0x02 };
    pat.at(1, 1).* = .{ .fx = fx_t, .param = 0x12 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqual(@as(usize, 4), map.rows.len);
    try testing.expectEqual(@as(i64, 24), map.total_ticks);
    try testing.expectEqual(@as(?u32, 2), map.loop_row);
    try testing.expectEqualSlices(TempoSeg, &.{
        .{ .start_tick = 0, .tempo = 125 },
        .{ .start_tick = 1, .tempo = 123 },
        .{ .start_tick = 2, .tempo = 121 },
        .{ .start_tick = 3, .tempo = 119 },
        .{ .start_tick = 4, .tempo = 117 },
        .{ .start_tick = 5, .tempo = 115 },
        .{ .start_tick = 7, .tempo = 117 },
        .{ .start_tick = 8, .tempo = 119 },
        .{ .start_tick = 9, .tempo = 121 },
        .{ .start_tick = 10, .tempo = 123 },
        .{ .start_tick = 11, .tempo = 125 },
        .{ .start_tick = 13, .tempo = 123 },
        .{ .start_tick = 14, .tempo = 121 },
        .{ .start_tick = 15, .tempo = 119 },
        .{ .start_tick = 16, .tempo = 117 },
        .{ .start_tick = 17, .tempo = 115 },
        .{ .start_tick = 19, .tempo = 117 },
        .{ .start_tick = 20, .tempo = 119 },
        .{ .start_tick = 21, .tempo = 121 },
        .{ .start_tick = 22, .tempo = 123 },
        .{ .start_tick = 23, .tempo = 125 },
    }, map.segments);

    // And the floor. Hand computation: tempo 33, one row, `T05` on
    // channel 0. Tick 1 takes 33 down to 28, which clamps to 32 and is
    // a change worth a segment; ticks 2–5 stay at 32, which is not, so
    // the row has exactly one segment. The second pass starts at 32
    // with the memory set and repeats the state of nothing, so it too
    // plays once and the walk ends: two rows, 12 ticks.
    var b2: model.Builder = .init(testing.allocator);
    defer b2.deinit();
    try b2.addOrder(0);
    const pat2 = try b2.addPattern(1);
    pat2.at(0, 0).* = .{ .fx = fx_t, .param = 0x05 };
    var m2 = b2.finish();
    defer m2.deinit();
    m2.header.initial_tempo = 33;

    var map2 = try derive(testing.allocator, &m2, .{});
    defer map2.deinit();

    try testing.expectEqual(@as(usize, 2), map2.rows.len);
    try testing.expectEqual(@as(i64, 12), map2.total_ticks);
    try testing.expectEqual(@as(?u32, 1), map2.loop_row);
    try testing.expectEqualSlices(TempoSeg, &.{
        .{ .start_tick = 0, .tempo = 33 },
        .{ .start_tick = 1, .tempo = 32 },
    }, map2.segments);
}

test "walk.derive: S6x lengthens its own row and S00 recalls it per channel" {
    // Hand computation. Speed 6, tempo 125; orders [0]; pattern 0 is
    // four rows:
    //
    //   row 0  channel 0  S62  → frame delay 2: the row is 6 + 2 = 8
    //                            ticks, and mem_special[0] = 0x62
    //   row 2  channel 0  S00  → recalls 0x62 → 8 ticks again
    //   row 3  channel 1  S00  → channel 1 remembers nothing: `S00` is
    //                            no timing effect at all → 6 ticks
    //
    // The frame delay is cleared once its row is over (plan 06 step 2),
    // so row 1 is a plain six.
    //
    //   idx  (order,row)  start  ticks  state BEFORE (mem_special 0,1)
    //   0    (0,0)        0      8      00 00
    //   1    (0,1)        8      6      62 00
    //   2    (0,2)        14     8      62 00
    //   3    (0,3)        22     6      62 00
    //   the song loops; (0,0) now carries 0x62 where index 0 carried
    //   nothing, so the walk plays it again:
    //   4    (0,0)        28     8      62 00
    //   and the next row, (0,1) with 62 00, is index 1's state → the
    //   walk ends. Five rows, 36 ticks, loop point 1.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(4);
    pat.at(0, 0).* = .{ .fx = fx_s, .param = 0x62 };
    pat.at(2, 0).* = .{ .fx = fx_s, .param = 0x00 };
    pat.at(3, 1).* = .{ .fx = fx_s, .param = 0x00 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 8 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 8, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 14, .ticks = 8 },
        .{ .order = 0, .pattern = 0, .row = 3, .start_tick = 22, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 28, .ticks = 8 },
    }, map.rows);
    try testing.expectEqual(@as(i64, 36), map.total_ticks);
    try testing.expectEqual(@as(?u32, 1), map.loop_row);
}

test "walk.derive: SEx repeats the row without reprocessing its effects" {
    // Hand computation. Speed 6, tempo 125; orders [0]; pattern 0 is
    // three rows, all the work on row 0:
    //
    //   channel 0  S62      frame delay 2
    //   channel 1  SE1      row delay: the row plays 1 + 1 = 2 times
    //   channel 2  C-5      a note, to count the onsets
    //   channel 3  SE3      ignored — the LEFTMOST SEx wins (plan 06)
    //
    // The repeat does not re-read the row, so its tick-0 handlers do not
    // run again (plan 06 step 2: "the row repeats (`SEx` row delay: row
    // effects are **not** reprocessed)"). Only the first play carries
    // the frame delay, and the note sounds once:
    //
    //   row 0 = (6 + 2) + 6 = 14 ticks, one onset at tick 0
    //
    // A repeated row is one row READ, so it is one `PlayedRow` whose
    // `ticks` span both plays — which is also what a tracker's position
    // display does, holding the cursor on the row for the whole delay.
    //
    //   idx  (order,row)  start  ticks
    //   0    (0,0)        0      14
    //   1    (0,1)        14     6
    //   2    (0,2)        20     6
    //   the song loops; (0,0) now carries the S and E memories:
    //   3    (0,0)        26     14      one onset at 26
    //   and the next row, (0,1), repeats index 1's state → the walk
    //   ends. Four rows, 40 ticks, two onsets, loop point 1.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(3);
    pat.at(0, 0).* = .{ .fx = fx_s, .param = 0x62 };
    pat.at(0, 1).* = .{ .fx = fx_s, .param = 0xE1 };
    pat.at(0, 2).* = .{ .note = 60 };
    pat.at(0, 3).* = .{ .fx = fx_s, .param = 0xE3 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 14 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 14, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 20, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 26, .ticks = 14 },
    }, map.rows);
    try testing.expectEqual(@as(i64, 40), map.total_ticks);
    try testing.expectEqual(@as(?u32, 1), map.loop_row);
    try testing.expectEqual(@as(usize, 2), map.onsets.len);
    try testing.expectEqual(@as(i64, 0), map.onsets[0].tick);
    try testing.expectEqual(@as(i64, 26), map.onsets[1].tick);
}

test "walk.derive: Bxx jumps to an order, forwards and backwards" {
    // Hand computation. Speed 6, tempo 125; orders [0, 1, 2] naming
    // patterns 0, 1 and 2, two rows each. `B02` sits on channel 0 of
    // pattern 0's row 0 (a jump FORWARD, over order 1) and `B01` on
    // channel 0 of pattern 2's row 0 (a jump BACKWARD). A jump takes
    // effect when its row is over, and lands on row 0 of its order.
    //
    //   idx  order  pattern  row  start  what the row does
    //   0    0      0        0    0      B02 → order 2
    //   1    2      2        0    6      B01 → order 1
    //   2    1      1        0    12
    //   3    1      1        1    18     end of pattern → order 2
    //
    // `Bxx` has no memory and nothing else here touches the state, so
    // order 2 row 0 is revisited in exactly the state of index 1 — the
    // walk ends there with the loop point at index 1. Four rows, 24
    // ticks, and the backward jump is what makes the song a loop that
    // never plays order 0 again.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    try b.addOrder(1);
    try b.addOrder(2);
    const pat0 = try b.addPattern(2);
    _ = try b.addPattern(2);
    const pat2 = try b.addPattern(2);
    pat0.at(0, 0).* = .{ .fx = fx_b, .param = 2 };
    pat2.at(0, 0).* = .{ .fx = fx_b, .param = 1 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 6 },
        .{ .order = 2, .pattern = 2, .row = 0, .start_tick = 6, .ticks = 6 },
        .{ .order = 1, .pattern = 1, .row = 0, .start_tick = 12, .ticks = 6 },
        .{ .order = 1, .pattern = 1, .row = 1, .start_tick = 18, .ticks = 6 },
    }, map.rows);
    try testing.expectEqual(@as(i64, 24), map.total_ticks);
    try testing.expectEqual(@as(?u32, 1), map.loop_row);
}

test "walk.derive: an SBx loop in progress beats a Cxx on the same row" {
    // Hand computation. Speed 6, tempo 125; orders [0, 1] naming
    // patterns 0 and 1, four rows each. Pattern 0 carries a pattern
    // loop with a break inside it:
    //
    //   row 0  channel 0  SB0  → mark the loop start at row 0
    //   row 2  channel 0  SB1  → loop once back to the mark
    //          channel 1  C02  → break to row 2 of the next order
    //
    // `SB0` marks; `SBx` with the channel's counter at 0 sets it to x
    // and jumps back to the mark, and the next time round the counter
    // comes down to 0 and the loop is done. A loop IN PROGRESS wins over
    // `Cxx` (plan 06), so the break on row 2 does nothing the first time
    // and is honoured the second, when there is no loop left to make.
    //
    //   idx  order  pattern  row  start  what the row does
    //   0    0      0        0    0      SB0: mark row 0
    //   1    0      0        1    6
    //   2    0      0        2    12     SB1: count 0 → 1, loop to row 0
    //                                    (C02 loses)
    //   3    0      0        0    18     SB0
    //   4    0      0        1    24
    //   5    0      0        2    30     SB1: count 1 → 0, no loop;
    //                                    now C02 breaks to order 1 row 2
    //   6    1      1        2    36
    //   7    1      1        3    42     end of pattern → past the last
    //                                    order → the song loops
    //   8    0      0        0    48     (index 0 had no memory, index 3
    //                                    had the loop counter at 1)
    //   the next row, (0,1) with mem_special 0xB0 and the counter back
    //   at 0, is index 1's state → the walk ends. Nine rows, 54 ticks,
    //   loop point 1.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    try b.addOrder(1);
    const pat0 = try b.addPattern(4);
    _ = try b.addPattern(4);
    pat0.at(0, 0).* = .{ .fx = fx_s, .param = 0xB0 };
    pat0.at(2, 0).* = .{ .fx = fx_s, .param = 0xB1 };
    pat0.at(2, 1).* = .{ .fx = fx_c, .param = 2 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 6, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 12, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 18, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 24, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 30, .ticks = 6 },
        .{ .order = 1, .pattern = 1, .row = 2, .start_tick = 36, .ticks = 6 },
        .{ .order = 1, .pattern = 1, .row = 3, .start_tick = 42, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 48, .ticks = 6 },
    }, map.rows);
    try testing.expectEqual(@as(i64, 54), map.total_ticks);
    try testing.expectEqual(@as(?u32, 1), map.loop_row);
}

test "walk.derive: SDx delays the onset, SD0 delays by one, a late one never sounds" {
    // Hand computation. Speed 6, tempo 125; orders [0]; pattern 0 is two
    // rows, four notes on row 0:
    //
    //   channel 0  C-5 SD3  → sounds at row start + 3
    //   channel 1  D-5 SD0  → `SD0` behaves as `SD1` → row start + 1
    //   channel 2  E-5 SD6  → 6 is the row's whole tick count, so the
    //                         note never sounds: no onset at all
    //   channel 3  F-5      → no delay: the row's own start
    //
    // The delayed cell sounds late but is still the row's cell (the IT
    // bug plan 06 keeps), and onsets come out in (row, channel) order,
    // which is time order within a channel and not across them.
    //
    //   idx  (order,row)  start  onsets
    //   0    (0,0)        0      ch0 @ 3, ch1 @ 1, ch3 @ 0
    //   1    (0,1)        6      —
    //   the song loops; (0,0) now carries the three `SDx` memories:
    //   2    (0,0)        12     ch0 @ 15, ch1 @ 13, ch3 @ 12
    //   and the next row, (0,1), repeats index 1's state → the walk
    //   ends. Three rows, 18 ticks, six onsets, loop point 1.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(2);
    pat.at(0, 0).* = .{ .note = 60, .fx = fx_s, .param = 0xD3 };
    pat.at(0, 1).* = .{ .note = 62, .fx = fx_s, .param = 0xD0 };
    pat.at(0, 2).* = .{ .note = 64, .fx = fx_s, .param = 0xD6 };
    pat.at(0, 3).* = .{ .note = 65 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqual(@as(usize, 3), map.rows.len);
    try testing.expectEqual(@as(i64, 18), map.total_ticks);
    try testing.expectEqual(@as(?u32, 1), map.loop_row);
    try testing.expectEqual(@as(usize, 6), map.onsets.len);

    const want = [_]struct { ch: u8, tick: i64, note: u8, row_index: u32 }{
        .{ .ch = 0, .tick = 3, .note = 60, .row_index = 0 },
        .{ .ch = 1, .tick = 1, .note = 62, .row_index = 0 },
        .{ .ch = 3, .tick = 0, .note = 65, .row_index = 0 },
        .{ .ch = 0, .tick = 15, .note = 60, .row_index = 2 },
        .{ .ch = 1, .tick = 13, .note = 62, .row_index = 2 },
        .{ .ch = 3, .tick = 12, .note = 65, .row_index = 2 },
    };
    for (want, map.onsets) |w, got| {
        try testing.expectEqual(w.ch, got.channel);
        try testing.expectEqual(w.tick, got.tick);
        try testing.expectEqual(w.note, got.cell.note);
        try testing.expectEqual(w.row_index, got.row_index);
    }
}

test "walk.derive: +++ is skipped and --- ends the song, which then loops" {
    // Hand computation. Speed 6, tempo 125; orders
    //
    //   [0, +++, 1, ---, 2]  =  [0, 254, 1, 255, 2]
    //
    // naming patterns 0, 1 and 2, two rows each. `+++` plays nothing and
    // the walk moves on; `---` is where the song ends and loops back to
    // order 0, so the last order never plays at all (plan 06 step 2:
    // "254 skipped, 255 (or the end) → the song ends and loops").
    //
    //   idx  order  pattern  row  start
    //   0    0      0        0    0
    //   1    0      0        1    6
    //   (order 1 is +++ → order 2)
    //   2    2      1        0    12
    //   3    2      1        1    18
    //   (order 3 is --- → back to order 0, in the state index 0 had)
    //
    // Nothing touched the state, so the walk ends at the loop with the
    // loop point at index 0. Four rows, 24 ticks.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    try b.addOrder(order_skip);
    try b.addOrder(1);
    try b.addOrder(order_end);
    try b.addOrder(2);
    _ = try b.addPattern(2);
    _ = try b.addPattern(2);
    _ = try b.addPattern(2);
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 6, .ticks = 6 },
        .{ .order = 2, .pattern = 1, .row = 0, .start_tick = 12, .ticks = 6 },
        .{ .order = 2, .pattern = 1, .row = 1, .start_tick = 18, .ticks = 6 },
    }, map.rows);
    try testing.expectEqual(@as(i64, 24), map.total_ticks);
    try testing.expectEqual(@as(?u32, 0), map.loop_row);
}

test "walk.derive: max_rows trips walk_runaway and the map stops there" {
    // Hand computation. Speed 6, tempo 125; orders [0]; pattern 0 is
    // four empty rows, which the walk would play once for 24 ticks —
    // but `max_rows = 3` stops it first. The cap is what plan 06's
    // "cap of 2^20 rows trips `walk_runaway`" is for: a module whose
    // timing state never repeats would otherwise walk for ever.
    //
    //   idx  (order,row)  start  ticks
    //   0    (0,0)        0      6
    //   1    (0,1)        6      6
    //   2    (0,2)        12     6
    //   the cap → one `walk_runaway`, 18 ticks, and NO loop point: the
    //   walk never found one.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    _ = try b.addPattern(4);
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{ .max_rows = 3 });
    defer map.deinit();

    try testing.expectEqual(@as(usize, 3), map.rows.len);
    try testing.expectEqual(@as(i64, 18), map.total_ticks);
    try testing.expectEqual(@as(?u32, null), map.loop_row);
    try testing.expectEqual(@as(usize, 1), map.diags.count(.walk_runaway));
    try testing.expectEqual(Diag.Severity.err, map.diags.items()[0].severity);

    // And the same module without the cap walks to its loop point.
    var full = try derive(testing.allocator, &m, .{});
    defer full.deinit();
    try testing.expectEqual(@as(usize, 4), full.rows.len);
    try testing.expectEqual(@as(usize, 0), full.diags.count(.walk_runaway));
}

test "walk.orderRowAt: the binary search finds every tick, and only those" {
    // Hand computation, over the `Bxx` map above: orders [0, 1, 2],
    // patterns of two rows, `B02` on pattern 0's row 0 and `B01` on
    // pattern 2's row 0, so the walk plays
    //
    //   idx  order  row  ticks
    //   0    0      0    0–5
    //   1    2      0    6–11
    //   2    1      0    12–17
    //   3    1      1    18–23   ← the last row
    //
    // and 24 is past the end. The rows are contiguous, so the search is
    // for the last row starting at or before the tick.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    try b.addOrder(1);
    try b.addOrder(2);
    const pat0 = try b.addPattern(2);
    _ = try b.addPattern(2);
    const pat2 = try b.addPattern(2);
    pat0.at(0, 0).* = .{ .fx = fx_b, .param = 2 };
    pat2.at(0, 0).* = .{ .fx = fx_b, .param = 1 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqual(Position{ .order = 0, .row = 0, .tick_in_row = 0 }, orderRowAt(&map, 0).?);
    try testing.expectEqual(Position{ .order = 0, .row = 0, .tick_in_row = 5 }, orderRowAt(&map, 5).?);
    try testing.expectEqual(Position{ .order = 2, .row = 0, .tick_in_row = 0 }, orderRowAt(&map, 6).?);
    try testing.expectEqual(Position{ .order = 2, .row = 0, .tick_in_row = 5 }, orderRowAt(&map, 11).?);
    try testing.expectEqual(Position{ .order = 1, .row = 0, .tick_in_row = 0 }, orderRowAt(&map, 12).?);
    try testing.expectEqual(Position{ .order = 1, .row = 1, .tick_in_row = 0 }, orderRowAt(&map, 18).?);
    // The last row, to its last tick, and then past the end.
    try testing.expectEqual(Position{ .order = 1, .row = 1, .tick_in_row = 5 }, orderRowAt(&map, 23).?);
    try testing.expectEqual(@as(?Position, null), orderRowAt(&map, 24));
    try testing.expectEqual(@as(?Position, null), orderRowAt(&map, 1000));
    try testing.expectEqual(@as(?Position, null), orderRowAt(&map, -1));

    // A module with nothing to play has no positions at all.
    var b2: model.Builder = .init(testing.allocator);
    defer b2.deinit();
    try b2.addOrder(order_end);
    _ = try b2.addPattern(4);
    var m2 = b2.finish();
    defer m2.deinit();

    var empty = try derive(testing.allocator, &m2, .{});
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.rows.len);
    try testing.expectEqual(@as(i64, 0), empty.total_ticks);
    try testing.expectEqual(@as(?u32, null), empty.loop_row);
    try testing.expectEqual(@as(?Position, null), orderRowAt(&empty, 0));
}

test "walk.derive: the leftmost SBx is the loop taken, and a Bxx right of it suppresses it" {
    // Two readings plan 06 leaves to it 06, pinned here.
    //
    // Hand computation A — "leftmost channel" (plan 06's rule for `SEx`,
    // and the brief's for `SBx`). Speed 6, tempo 125; orders [0, 1];
    // pattern 0 is three rows, pattern 1 one row:
    //
    //   row 0  channel 1  SB0   → channel 1 marks row 0
    //   row 1  channel 3  SB0   → channel 3 marks row 1
    //   row 2  channel 1  SB1   → both loop, and the LEFTMOST is taken,
    //          channel 3  SB1     so the walk goes back to row 0
    //
    //   idx  order  row  start  state BEFORE (ch1: mem/start/count,
    //   0    0      0    0       ch3: mem/start/count)
    //                            (00 0 0, 00 0 0)
    //   1    0      1    6       (B0 0 0, 00 0 0)
    //   2    0      2    12      (B0 0 0, B0 1 0)  → loop to row 0
    //   3    0      0    18      (B1 0 1, B1 1 1)  ← row 0, not row 1
    //   4    0      1    24      (B0 0 1, B1 1 1)
    //   5    0      2    30      (B0 0 1, B0 1 1)  → both counters reach
    //                            0: no loop, on to order 1
    //   6    1      0    36      (B1 0 0, B1 1 0)  → the song loops
    //   7    0      0    42      (B1 0 0, B1 1 0)
    //   8    0      1    48      (B0 0 0, B1 1 0)
    //   and (0,2) with (B0 0 0, B0 1 0) is index 2's state → the walk
    //   ends. Nine rows, 54 ticks, loop point 2.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    try b.addOrder(1);
    const pat0 = try b.addPattern(3);
    _ = try b.addPattern(1);
    pat0.at(0, 1).* = .{ .fx = fx_s, .param = 0xB0 };
    pat0.at(1, 3).* = .{ .fx = fx_s, .param = 0xB0 };
    pat0.at(2, 1).* = .{ .fx = fx_s, .param = 0xB1 };
    pat0.at(2, 3).* = .{ .fx = fx_s, .param = 0xB1 };
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 6, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 12, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 18, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 24, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 2, .start_tick = 30, .ticks = 6 },
        .{ .order = 1, .pattern = 1, .row = 0, .start_tick = 36, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 42, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 48, .ticks = 6 },
    }, map.rows);
    try testing.expectEqual(@as(i64, 54), map.total_ticks);
    try testing.expectEqual(@as(?u32, 2), map.loop_row);

    // Hand computation B — `Bxx` is handled INLINE and "placed right of
    // SBx it can suppress the loop" (it 06's effect table), while `Cxx`
    // is deferred and only says which ROW the jump lands on. Orders
    // [0, 1], two rows each:
    //
    //   row 0  channel 0  SB0   → mark row 0
    //   row 1  channel 0  SB1   → a loop back to row 0 …
    //          channel 1  B01   → … suppressed: the jump is to order 1
    //          channel 2  C01   → and it lands on that order's row 1
    //
    //   idx  order  row  start  state BEFORE (mem/start/count)
    //   0    0      0    0      (00 0 0)
    //   1    0      1    6      (B0 0 0)   → order 1 row 1, no loop
    //   2    1      1    12     (B1 0 1)   → past the last order: loops
    //   3    0      0    18     (B1 0 1)
    //   4    0      1    24     (B0 0 1)   → the counter reaches 0 here
    //   5    1      1    30     (B1 0 0)
    //   6    0      0    36     (B1 0 0)
    //   and (0,1) with (B0 0 0) is index 1's state → the walk ends.
    //   Seven rows, 42 ticks, loop point 1. Row 0 never follows row 1:
    //   the loop is suppressed every time.
    var b2: model.Builder = .init(testing.allocator);
    defer b2.deinit();
    try b2.addOrder(0);
    try b2.addOrder(1);
    const p0 = try b2.addPattern(2);
    _ = try b2.addPattern(2);
    p0.at(0, 0).* = .{ .fx = fx_s, .param = 0xB0 };
    p0.at(1, 0).* = .{ .fx = fx_s, .param = 0xB1 };
    p0.at(1, 1).* = .{ .fx = fx_b, .param = 1 };
    p0.at(1, 2).* = .{ .fx = fx_c, .param = 1 };
    var m2 = b2.finish();
    defer m2.deinit();

    var map2 = try derive(testing.allocator, &m2, .{});
    defer map2.deinit();

    try testing.expectEqualSlices(PlayedRow, &.{
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 0, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 6, .ticks = 6 },
        .{ .order = 1, .pattern = 1, .row = 1, .start_tick = 12, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 18, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 1, .start_tick = 24, .ticks = 6 },
        .{ .order = 1, .pattern = 1, .row = 1, .start_tick = 30, .ticks = 6 },
        .{ .order = 0, .pattern = 0, .row = 0, .start_tick = 36, .ticks = 6 },
    }, map2.rows);
    try testing.expectEqual(@as(i64, 42), map2.total_ticks);
    try testing.expectEqual(@as(?u32, 1), map2.loop_row);
}

test "walk.derive: loops asks for another time round the loop" {
    // Hand computation. The four-row module of the first test above
    // walks 24 ticks to its loop point at index 0. `loops = 2` lets the
    // walk enter that state twice, so it plays the song through a second
    // time — eight rows, 48 ticks — and the loop point is still index 0,
    // the first visit.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    _ = try b.addPattern(4);
    var m = b.finish();
    defer m.deinit();

    var once = try derive(testing.allocator, &m, .{ .loops = 1 });
    defer once.deinit();
    try testing.expectEqual(@as(usize, 4), once.rows.len);
    try testing.expectEqual(@as(i64, 24), once.total_ticks);

    var twice = try derive(testing.allocator, &m, .{ .loops = 2 });
    defer twice.deinit();
    try testing.expectEqual(@as(usize, 8), twice.rows.len);
    try testing.expectEqual(@as(i64, 48), twice.total_ticks);
    try testing.expectEqual(@as(?u32, 0), twice.loop_row);
    try testing.expectEqual(
        PlayedRow{ .order = 0, .pattern = 0, .row = 0, .start_tick = 24, .ticks = 6 },
        twice.rows[4],
    );
}

test "walk.derive: a module with nothing playable ends instead of walking for ever" {
    // A pattern with no rows plays nothing, so an order list of them
    // plays nothing: the walk must end with an empty map rather than
    // stepping from order to order for ever. The reader never builds a
    // rowless pattern (it substitutes an empty 64-row one), but a
    // `Builder` and the document bridge can, and the walk is total over
    // any `Module` value.
    var b: model.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addOrder(0);
    try b.addOrder(1);
    _ = try b.addPattern(0);
    _ = try b.addPattern(0);
    var m = b.finish();
    defer m.deinit();

    var map = try derive(testing.allocator, &m, .{});
    defer map.deinit();

    try testing.expectEqual(@as(usize, 0), map.rows.len);
    try testing.expectEqual(@as(usize, 0), map.onsets.len);
    try testing.expectEqual(@as(i64, 0), map.total_ticks);
    try testing.expectEqual(@as(?u32, null), map.loop_row);
    try testing.expectEqual(@as(usize, 0), map.diags.items().len);
    // The one segment every map has: the initial tempo at tick 0.
    try testing.expectEqualSlices(TempoSeg, &.{.{ .start_tick = 0, .tempo = 125 }}, map.segments);
}
