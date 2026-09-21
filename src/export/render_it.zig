//! `renderIt` — a native timeline as an Impulse Tracker module (plan 08,
//! "Rendering to `.it`").
//!
//! The tracker's view of a document. A row is `speed` IT ticks, a
//! pattern is `rows` rows, and one order plays each pattern once:
//!
//!   * **Positions land on the row grid.** A tick that is a whole
//!     number of rows is the row; one that is a whole number of IT ticks
//!     within 15 of a row start is that row with an `SDx` note delay,
//!     when the cell's effect column is still free; anything else is the
//!     nearest row and `render_inexact`.
//!   * **`notes` → cells.** The note number is the document's key (`C4`
//!     is 60 and IT's `C-5` is 60 too), `:ins 1` with `it_no_instrument`
//!     when the module carries none — the file holds timing and silence,
//!     a tracker adds the samples, the residue remembers — `:vol` from
//!     the velocity, and a `^^^` (note cut) at the note's end so a
//!     duration survives a grid that has no note offs.
//!   * **One cell holds one note**, so a lane takes as many channels as
//!     its maximum polyphony: the lowest free channel of the lane's set,
//!     capped by `voices`, past which `render_polyphony_exceeded` names
//!     the tick and the note rides in the essence alone.
//!   * **`curve` → the volume column** at rows, or an `fx` letter's
//!     parameter byte with `opts.fx`. `hold` is the keyframes, `linear`
//!     is sampled per row, and every other easing is its keyframes only,
//!     recorded in the lane record — as for `.mid`, because tempura never
//!     evaluates a named curve.
//!   * **Tempo points → `Txx`** at their rows, integers only
//!     (`tempo_inexact` otherwise); the **meter** → the highlight for the
//!     first point and the essence for the rest; sections and cues → the
//!     message tail, which `build` appends.
//!
//! **Into an anchor.** With `base`, the module's own patterns, orders,
//! samples, instruments and every opaque region come across untouched and
//! the lanes take channels ABOVE the highest one the module uses
//! (`render_channels_exhausted` past 64). The row grid is then the
//! anchor's own walk, so a tick is placed where the tracker would play
//! it; a pattern the order list plays twice is written once and sounds
//! twice, which is the tracker's own arithmetic and why plan 08 leaves
//! the structure to the essence.

const std = @import("std");

const Diag = @import("../Diag.zig");
const Doc = @import("../doc/Value.zig");
const Grid = @import("../time/Grid.zig");
const derive = @import("../time/derive.zig");
const itf = @import("../itf/itf.zig");
const records = @import("../residue/records.zig");
const reconcile = @import("../residue/reconcile.zig");

const Allocator = std.mem.Allocator;
const model = itf.model;
const testing = std.testing;

/// Rendering can only fail the way any allocation fails.
pub const Error = error{OutOfMemory};

/// `Sxy`, `Txx` and `Axx` by ITTECH's numbering (`cmd = letter − '@'`).
const fx_s: u8 = 'S' - '@';
const fx_t: u8 = 'T' - '@';

/// `SDx` — delay the note by `x` ticks. The high nibble is the family.
const sd: u8 = 0xD0;

/// IT's own tempo domain (it 04): the header floors at 31, a `Txx`
/// clamps to 32.
const tempo_min: u32 = 32;
const tempo_max: u32 = 255;

/// The strict pattern ceiling (it 05). A document longer than this is
/// truncated rather than allowed to allocate without bound.
const max_patterns: usize = 240;

pub const Options = struct {
    /// Ticks per row of a FRESH module. An anchor's own speed wins.
    speed: u8 = 6,
    /// Rows per pattern of a fresh module.
    rows: u16 = 64,
    /// `--voices`: how many channels one lane may take.
    voices: u8 = 4,
    /// `--fx "Z"`: render curves as this effect letter's parameter byte
    /// rather than as volume-column values.
    fx: ?u8 = null,
};

/// A rendered module, the records that describe it, and the report.
pub const Result = struct {
    module: itf.Module,
    lanes: []const records.LaneRecord,
    /// Present exactly when the DOCUMENT conducts (plan 04).
    conductor: ?records.ConductorRecord,
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        self.diags.deinit();
        self.module.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Render `doc` into a `Module`, into `base` when there is one.
pub fn renderIt(
    gpa: Allocator,
    doc: *const Doc.Doc,
    derived: *const derive.Derived,
    base: ?*const itf.Module,
    opts: Options,
) Error!Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var r: Render = .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .doc = doc,
        .derived = derived,
        .base = base,
        .opts = opts,
        .diags = &diags,
        .speed = if (base) |m| m.header.effectiveSpeed() else @max(opts.speed, 1),
    };
    r.row_ticks = @as(i64, r.speed) * Grid.IT_TICK;
    defer r.deinit();

    var module = try r.run();
    errdefer module.deinit();

    // The hashes, over the module as it will be written. The walk is the
    // one a dump will make of the same bytes, so the addresses agree.
    var rows = try itf.walk.derive(gpa, &module, .{});
    defer rows.deinit();
    // ONE owner for "which patterns sound": `reconcile` computes it when
    // it re-hashes a lane, and a hash both sides compute has to be over
    // the same set.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const played = try reconcile.playedPatterns(scratch.allocator(), &rows);

    for (r.lanes.items) |*rec| {
        rec.hash = records.hashItLane(&module, &rows, &[_]u8{rec.address.it.channel}, played);
    }
    const conductor: ?records.ConductorRecord = if (doc.conductor == null)
        .{ .hash = records.hashItConductor(&module) }
    else
        null;

    return .{
        .module = module,
        .lanes = r.lanes.items,
        .conductor = conductor,
        .diags = diags,
        .arena = arena,
    };
}

// ---------------------------------------------------------------------
// The render
// ---------------------------------------------------------------------

/// Where a tick lands on the row grid.
const Slot = struct {
    pattern: u16,
    row: u16,
    /// `SDx` ticks, 0 when the position is the row itself.
    delay: u8,
};

const Render = struct {
    gpa: Allocator,
    /// The result's arena: every record's name and segments.
    arena: Allocator,
    doc: *const Doc.Doc,
    derived: *const derive.Derived,
    base: ?*const itf.Module,
    opts: Options,
    diags: *Diag.List,
    speed: u8,
    row_ticks: i64 = 0,
    lanes: std.ArrayList(records.LaneRecord) = .empty,

    /// The module under construction: `patterns` are borrowed from the
    /// builder and stay valid, because a builder's patterns never move.
    patterns: std.ArrayList(itf.Pattern) = .empty,
    rows_per_pattern: u16 = 0,
    /// The base's walk, for the anchored path. Null for a fresh module.
    rows: ?itf.walk.RowMap = null,
    orders: []const u8 = &.{},
    /// The first channel this render may write to: 0 for a fresh module,
    /// one past the anchor's highest used channel otherwise. The
    /// conductor's own `Txx` cells obey it too — nothing tempura writes
    /// goes into a cell the anchor was using.
    first_channel: u16 = 0,
    said_no_instrument: bool = false,
    inexact: usize = 0,
    /// How many notes were dropped because the voice's cell was already
    /// taken by another note of the same lane.
    collisions: usize = 0,

    fn deinit(self: *Render) void {
        self.patterns.deinit(self.gpa);
        if (self.rows) |*r| r.deinit();
    }

    fn run(self: *Render) Error!itf.Module {
        var b: itf.Builder = .init(self.gpa);
        errdefer b.deinit();

        self.first_channel = try self.layout(&b);

        // The conductor goes down FIRST: a `Txx` owns the effect column
        // of the cell it lands in, and a note that wanted an `SDx` there
        // has to know (plan 08, "when the cell's effect column is free").
        try self.conductorCells();

        var channel: u16 = self.first_channel;
        for (self.doc.lanes, 0..) |*lane, i| {
            if (!try self.renders(lane)) continue;
            const want: u16 = switch (lane.kind) {
                .notes => @max(1, @min(
                    @as(u16, @max(self.opts.voices, 1)),
                    @as(u16, @intCast(maxPolyphony(self.derived.lanes[i].onsets))),
                )),
                else => 1,
            };
            if (channel + want > model.channels) {
                try self.diags.add(
                    .render_channels_exhausted,
                    .warning,
                    lane.span,
                    "the lane '{s}' needs {d} channel(s) and this module has none left of its {d}; its content rides in the residue alone",
                    .{ lane.name, want, model.channels },
                );
                continue;
            }
            switch (lane.kind) {
                .notes => try self.notesLane(lane, &self.derived.lanes[i], @intCast(channel), @intCast(want)),
                .curve => try self.curveLane(lane, &self.derived.lanes[i], @intCast(channel)),
                .query, .formula => unreachable,
            }
            channel += want;
        }

        if (self.inexact > 0) try self.diags.add(
            .render_inexact,
            .warning,
            .{ .start = 0, .end = 0 },
            "{d} position(s) do not land on this module's row grid ({d} ticks to the row) and were written to the nearest row",
            .{ self.inexact, self.speed },
        );
        if (self.collisions > 0) try self.diags.add(
            .render_inexact,
            .warning,
            .{ .start = 0, .end = 0 },
            "{d} note(s) rounded onto a cell one of their own lane's notes already held; a cell holds one note, so the later one was not written and rides in the residue alone",
            .{self.collisions},
        );

        return b.finish();
    }

    /// The module's shape: the base's patterns and orders carried over,
    /// or a fresh grid long enough to hold the document. Answers the
    /// first channel the lanes may use.
    fn layout(self: *Render, b: *itf.Builder) Error!u16 {
        if (self.base) |src| {
            b.module.header = src.header;
            b.module.midi_config = src.midi_config;
            b.module.edit_history = src.edit_history;
            try b.setMessage(src.message);
            b.module.tmpu = src.tmpu;
            for (src.orders) |o| try b.addOrder(o);
            for (src.patterns) |p| {
                const dst = try b.addPattern(p.rows);
                @memcpy(dst.cells, p.cells);
                try self.patterns.append(self.gpa, dst);
            }
            for (src.instruments) |ins| try b.addInstrument(model.nameText(&ins.name), ins.raw);
            for (src.samples) |s| try b.addSample(s);
            for (src.foreign) |f| try b.addForeign(f.tag, f.raw);
            self.orders = src.orders;
            self.rows = try itf.walk.derive(self.gpa, src, .{});
            return highestUsed(src);
        }

        self.rows_per_pattern = @max(self.opts.rows, 1);
        try self.header(b);

        const row_span = @as(i64, self.rows_per_pattern) * self.row_ticks;
        const length = @max(self.derived.map.length, self.contentEnd());
        var wanted: usize = @intCast(@divFloor(length, row_span) + 1);
        if (wanted > max_patterns) {
            try self.diags.add(
                .it_count_exceeds_spec,
                .warning,
                .{ .start = 0, .end = 0 },
                "this timeline needs {d} patterns of {d} rows and a module holds {d}; the tail is not rendered and rides in the residue alone",
                .{ wanted, self.rows_per_pattern, max_patterns },
            );
            wanted = max_patterns;
        }
        var i: usize = 0;
        while (i < wanted) : (i += 1) {
            try self.patterns.append(self.gpa, try b.addPattern(self.rows_per_pattern));
            try b.addOrder(@intCast(i));
        }
        return 0;
    }

    /// The furthest tick the document places anything at — a document
    /// whose `:length` stops short of its own content still renders all
    /// of it.
    fn contentEnd(self: *Render) i64 {
        var end: i64 = 0;
        for (self.derived.lanes) |l| {
            for (l.onsets) |o| end = @max(end, o.tick +| @max(o.dur, 0));
            for (l.steps) |s| end = @max(end, s.tick);
        }
        for (self.doc.tempo) |t| end = @max(end, t.tick);
        return end;
    }

    /// A fresh module's header: the speed, the initial tempo from the
    /// document's own first tempo point, and the highlight from its first
    /// meter point.
    fn header(self: *Render, b: *itf.Builder) Error!void {
        b.module.header.initial_speed = self.speed;
        if (self.doc.title) |t| b.setTitle(t);

        if (self.doc.tempo.len > 0 and self.doc.conductor == null) {
            b.module.header.initial_tempo = try self.tempoByte(self.doc.tempo[0]);
        }
        if (self.doc.meter.len > 0) {
            const m = self.doc.meter[0];
            if (m.d != 0 and m.n != 0) {
                const beat = Grid.beatTicks(m.d);
                const bar = Grid.barTicks(m.n, m.d);
                if (@rem(beat, self.row_ticks) == 0 and @rem(bar, self.row_ticks) == 0) {
                    const minor = @divExact(beat, self.row_ticks);
                    const major = @divExact(bar, self.row_ticks);
                    if (minor >= 1 and minor <= 255 and major >= 1 and major <= 255) {
                        b.module.header.highlight_minor = @intCast(minor);
                        b.module.header.highlight_major = @intCast(major);
                        b.module.header.special |= model.special.highlight;
                    }
                }
            }
        }
    }

    /// One tempo point as an IT tempo byte. IT's tempo IS the quarter
    /// notes per minute under the 24-ticks-per-quarter convention (plan
    /// 06), so the only question is whether the number is an integer in
    /// 32..255 — and `tempo_inexact` is the answer when it is not.
    fn tempoByte(self: *Render, point: Doc.TempoPoint) Error!u8 {
        const qpm: f64 = switch (point.tempo) {
            .qpm => |v| v,
            .us => |us| if (us == 0) 0 else 60_000_000.0 / @as(f64, @floatFromInt(us)),
        };
        const rounded = @round(qpm);
        const clamped = std.math.clamp(rounded, @as(f64, tempo_min), @as(f64, tempo_max));
        if (rounded != qpm or clamped != rounded) try self.diags.add(
            .tempo_inexact,
            .warning,
            point.span,
            "an Impulse Tracker tempo is a whole number 32..255 and this point is {d} quarter notes per minute; it was written as {d} and the residue keeps the tempo the document states",
            .{ qpm, clamped },
        );
        return @intFromFloat(clamped);
    }

    /// `Txx` for every tempo point past the first, at the row it falls
    /// on. Only for a document that conducts itself: a `:conductor`
    /// names the anchor as the owner of time and its cells are already
    /// there (plan 03).
    fn conductorCells(self: *Render) Error!void {
        if (self.doc.conductor != null) return;
        for (self.doc.tempo, 0..) |point, i| {
            // The first point IS the header's initial tempo when it sits
            // at tick 0; anywhere else it is a change like any other.
            if (i == 0 and point.tick == 0 and self.base == null) continue;
            const slot = self.slotAt(point.tick) orelse continue;
            const param = try self.tempoByte(point);
            if (!self.placeFx(slot, fx_t, param)) try self.diags.add(
                .render_inexact,
                .warning,
                point.span,
                "every effect column of row {d} of pattern {d} is taken, so this tempo point could not be written there",
                .{ slot.row, slot.pattern },
            );
        }
    }

    /// Whether this lane becomes cells, and the diagnostic for every
    /// lane that does not.
    fn renders(self: *Render, lane: *const Doc.Lane) Error!bool {
        if (lane.binding != null) return false;
        switch (lane.kind) {
            .notes, .curve => return true,
            .query, .formula => {
                try self.diags.add(
                    .residue_only,
                    .warning,
                    lane.span,
                    "the {t} lane '{s}' is computed, and a .it holds no query or formula: it rides in the residue alone",
                    .{ lane.kind, lane.name },
                );
                return false;
            },
        }
    }

    // ---- a notes lane ----

    fn notesLane(
        self: *Render,
        lane: *const Doc.Lane,
        index: *const derive.LaneIndex,
        first: u8,
        voices: u8,
    ) Error!void {
        // `busy[v]` is the tick the voice is free again at, and
        // `last[v]` the slot its last note ended on — where the `^^^`
        // goes when the next note is farther away than the duration.
        const busy = try self.gpa.alloc(i64, voices);
        defer self.gpa.free(busy);
        @memset(busy, std.math.minInt(i64));
        const cuts = try self.gpa.alloc(?Slot, voices);
        defer self.gpa.free(cuts);
        @memset(cuts, null);

        var exceeded: usize = 0;
        for (index.onsets) |o| {
            const slot = self.slotAt(o.tick) orelse continue;
            const end = o.tick +| @max(o.dur, 0);

            var voice: ?u8 = null;
            for (busy, 0..) |free_at, v| {
                if (free_at <= o.tick) {
                    voice = @intCast(v);
                    break;
                }
            }
            const v = voice orelse {
                exceeded += 1;
                if (exceeded == 1) try self.diags.add(
                    .render_polyphony_exceeded,
                    .warning,
                    lane.span,
                    "the lane '{s}' sounds more than {d} note(s) at once from tick {d}; the ones past the cap ride in the residue alone",
                    .{ lane.name, voices, o.tick },
                );
                continue;
            };

            // The pending cut of the voice's previous note, placed only
            // where it does not land on this note's own cell.
            if (cuts[v]) |cut| self.placeCut(cut, first + v, slot);
            cuts[v] = self.slotAt(end);
            busy[v] = end;

            try self.placeNote(slot, first + v, o);
        }
        for (cuts, 0..) |cut, v| {
            if (cut) |c| self.placeCut(c, first + @as(u8, @intCast(v)), null);
        }

        var ch: u8 = 0;
        while (ch < voices) : (ch += 1) try self.lanes.append(self.arena, .{
            .lane = try self.arena.dupe(u8, lane.name),
            .address = .{ .it = .{ .channel = @intCast(first + ch), .column = null, .fx = null } },
            .hash = @splat(0),
        });
    }

    fn placeNote(self: *Render, slot: Slot, channel: u8, o: derive.Onset) Error!void {
        const cell = self.cellAt(slot, channel) orelse return;
        // One cell holds one note. Two notes of one voice that round
        // onto the same cell are not a note and a louder note — the
        // second would silently replace the first — so the cell keeps
        // what it has and the loss is counted.
        if (cell.note != model.note_none and cell.note != model.note_cut) {
            self.collisions += 1;
            return;
        }
        cell.note = @min(o.key, model.note_max);
        cell.ins = 1;
        cell.vol = volumeOf(o.vel);
        if (slot.delay > 0) {
            if (cell.fx == 0) {
                cell.fx = fx_s;
                cell.param = sd | slot.delay;
            } else {
                // The effect column is taken — by a `Txx`, the conductor
                // having gone down first — so the delay cannot be said
                // and the note sounds at the row instead (plan 08: "when
                // the cell's effect column is free, else nearest row and
                // `render_inexact`").
                self.inexact += 1;
            }
        }
        if (!self.said_no_instrument and self.instrumentless()) {
            self.said_no_instrument = true;
            try self.noInstrument();
        }
    }

    /// `^^^` at `cut`, unless the next note lands on the same cell — a
    /// cut there would silence the note it was meant to follow.
    ///
    /// Only the NOTE column has to be free. A cell with a `Txx` in it is
    /// still a cell that can end a note, and requiring the whole cell to
    /// be empty meant a note whose end fell on a tempo change's row rang
    /// on for ever — the one place a duration was silently lost.
    fn placeCut(self: *Render, cut: Slot, channel: u8, next: ?Slot) void {
        if (next) |n| {
            if (n.pattern == cut.pattern and n.row == cut.row) return;
        }
        const cell = self.cellAt(cut, channel) orelse return;
        if (cell.note != model.note_none) return;
        cell.note = model.note_cut;
        // The end is a position like any other: an `SDx` says it exactly.
        if (cut.delay > 0 and cell.fx == 0) {
            cell.fx = fx_s;
            cell.param = sd | cut.delay;
        }
    }

    fn instrumentless(self: *Render) bool {
        const src = self.base orelse return true;
        return src.instruments.len == 0 and src.samples.len == 0;
    }

    fn noInstrument(self: *Render) Error!void {
        try self.diags.add(
            .it_no_instrument,
            .warning,
            .{ .start = 0, .end = 0 },
            "this module carries no instrument or sample, so every rendered cell names instrument 1: the file holds the timing and a tracker brings the sound",
            .{},
        );
    }

    // ---- a curve lane ----

    fn curveLane(
        self: *Render,
        lane: *const Doc.Lane,
        index: *const derive.LaneIndex,
        channel: u8,
    ) Error!void {
        const range = lane.range orelse [2]f32{ 0, 1 };
        var steps_only: std.ArrayList(records.Segment) = .empty;

        for (index.steps, 0..) |step, i| {
            if (i > 0) {
                const prev = index.steps[i - 1];
                if (std.mem.eql(u8, step.ease_src, "linear")) {
                    // One sample a row, which is the finest a tracker can
                    // say anything at.
                    var at = prev.tick + self.row_ticks;
                    while (at < step.tick) : (at += self.row_ticks) {
                        const span = step.tick - prev.tick;
                        const u = @as(f64, @floatFromInt(at - prev.tick)) / @as(f64, @floatFromInt(span));
                        const v = @as(f64, prev.value[0]) + (@as(f64, step.value[0]) - @as(f64, prev.value[0])) * u;
                        self.placeCurve(at, channel, v, range);
                    }
                } else if (!std.mem.eql(u8, step.ease_src, "hold")) {
                    try steps_only.append(self.arena, .{
                        .at = step.tick,
                        .ease = try self.arena.dupe(u8, step.ease_src),
                    });
                }
            }
            self.placeCurve(step.tick, channel, step.value[0], range);
        }

        try self.lanes.append(self.arena, .{
            .lane = try self.arena.dupe(u8, lane.name),
            .address = .{ .it = .{
                .channel = @intCast(channel),
                .column = if (self.opts.fx == null) .vol else .fx,
                .fx = self.opts.fx,
            } },
            .hash = @splat(0),
            .steps_only = steps_only.items,
        });
    }

    fn placeCurve(self: *Render, tick: i64, channel: u8, v: f64, range: [2]f32) void {
        const slot = self.slotAt(tick) orelse return;
        const cell = self.cellAt(slot, channel) orelse return;
        if (self.opts.fx) |letter| {
            if (cell.fx != 0) return;
            cell.fx = letter -% '@';
            cell.param = scale(v, range, 255);
        } else {
            cell.vol = scale(v, range, 64);
        }
    }

    // ---- the grid ----

    /// Where a tempura tick lands, or null when it lands outside the
    /// module altogether.
    fn slotAt(self: *Render, tick: i64) ?Slot {
        if (tick < 0) return null;
        if (self.rows) |*map| {
            // The anchored path: the row the tracker would be playing.
            const it_tick = @divFloor(tick, Grid.IT_TICK);
            const pos = itf.walk.orderRowAt(map, it_tick) orelse {
                self.inexact += 1;
                return self.lastSlot();
            };
            if (pos.order >= self.orders.len) return null;
            const pattern = self.orders[pos.order];
            if (pattern >= self.patterns.items.len) return null;
            // An `SDx` says a sub-row position EXACTLY, so it is not a
            // rounding and is not counted as one; a position that is not
            // a whole IT tick, or more than 15 of them into a row, is.
            const on_tick = @rem(tick, Grid.IT_TICK) == 0;
            const on_row = on_tick and pos.tick_in_row == 0;
            const can_delay = on_tick and pos.tick_in_row <= 15;
            if (!on_row and !can_delay) self.inexact += 1;
            return .{
                .pattern = pattern,
                .row = pos.row,
                .delay = if (can_delay) @intCast(pos.tick_in_row) else 0,
            };
        }

        const rows = @divFloor(tick, self.row_ticks);
        const rem = tick - rows * self.row_ticks;
        const pattern_index: usize = @intCast(@divFloor(rows, @as(i64, self.rows_per_pattern)));
        if (pattern_index >= self.patterns.items.len) return null;
        const row: u16 = @intCast(@rem(rows, @as(i64, self.rows_per_pattern)));

        if (rem == 0) return .{ .pattern = @intCast(pattern_index), .row = row, .delay = 0 };
        // `SDx` first: a delay of `x` whole IT ticks says the position
        // exactly, and only what it cannot say is rounded and counted.
        if (@rem(rem, Grid.IT_TICK) == 0) {
            const ticks = @divExact(rem, Grid.IT_TICK);
            if (ticks <= 15) return .{
                .pattern = @intCast(pattern_index),
                .row = row,
                .delay = @intCast(ticks),
            };
        }
        self.inexact += 1;
        // Nearest row, ties up — the row the position is closer to.
        const nearest = if (2 * rem >= self.row_ticks) rows + 1 else rows;
        const pi: usize = @intCast(@divFloor(nearest, @as(i64, self.rows_per_pattern)));
        if (pi >= self.patterns.items.len) return self.lastSlot();
        return .{
            .pattern = @intCast(pi),
            .row = @intCast(@rem(nearest, @as(i64, self.rows_per_pattern))),
            .delay = 0,
        };
    }

    /// The last cell of the module — where a position past its end is
    /// clamped, so a note is late rather than lost.
    fn lastSlot(self: *Render) ?Slot {
        if (self.patterns.items.len == 0) return null;
        const last = self.patterns.items.len - 1;
        const p = self.patterns.items[last];
        if (p.rows == 0) return null;
        return .{ .pattern = @intCast(last), .row = p.rows - 1, .delay = 0 };
    }

    fn cellAt(self: *Render, slot: Slot, channel: u8) ?*model.Cell {
        if (slot.pattern >= self.patterns.items.len) return null;
        const p = self.patterns.items[slot.pattern];
        if (slot.row >= p.rows or channel >= model.channels) return null;
        return p.at(slot.row, channel);
    }

    /// An effect into the lowest channel of `slot`'s row whose effect
    /// column is still free. False when every one of them is taken.
    fn placeFx(self: *Render, slot: Slot, fx: u8, param: u8) bool {
        // From the first channel this render owns: an anchor's cells are
        // its own, and a conductor effect is not a reason to touch one.
        var c: u8 = @intCast(self.first_channel);
        while (c < model.channels) : (c += 1) {
            const cell = self.cellAt(slot, c) orelse return false;
            if (cell.fx != 0) continue;
            cell.fx = fx;
            cell.param = param;
            return true;
        }
        return false;
    }
};

/// How many notes of `onsets` ever sound at once — how many channels the
/// lane needs before `--voices` caps it.
///
/// A note's window is HALF-OPEN, the same rule the voice allocator below
/// uses (`busy[v] <= tick`): a note that ends exactly where the next one
/// starts is not sounding with it, so a monophonic line stays on one
/// channel. A note of no duration still sounds at its own tick, which is
/// the `other.tick == o.tick` arm.
fn maxPolyphony(onsets: []const derive.Onset) usize {
    var most: usize = 0;
    for (onsets) |o| {
        var n: usize = 0;
        for (onsets) |other| {
            const end = other.tick +| @max(other.dur, 0);
            if (other.tick <= o.tick and (o.tick < end or other.tick == o.tick)) n += 1;
        }
        most = @max(most, n);
    }
    return most;
}

/// A velocity as IT's volume column: `round(vel × 64 / 127)`, the
/// inverse of `doc/bridge_it.zig`'s `velocityOf`.
fn volumeOf(vel: u7) u8 {
    return @intCast((@as(u16, vel) * 64 + 63) / 127);
}

/// `round((v − lo) / (hi − lo) · top)`, clamped to `0..top`.
fn scale(v: f64, range: [2]f32, top: u8) u8 {
    const lo: f64 = range[0];
    const hi: f64 = range[1];
    if (hi == lo or !std.math.isFinite(lo) or !std.math.isFinite(hi) or !std.math.isFinite(v)) return 0;
    const scaled = @round((v - lo) / (hi - lo) * @as(f64, @floatFromInt(top)));
    if (!(scaled > 0)) return 0;
    if (scaled >= @as(f64, @floatFromInt(top))) return top;
    return @intFromFloat(scaled);
}

/// One past the highest channel any cell of `module` uses.
fn highestUsed(module: *const itf.Module) u16 {
    var highest: u16 = 0;
    for (module.patterns) |p| {
        if (p.cells.len < @as(usize, p.rows) * model.channels) continue;
        var row: u16 = 0;
        while (row < p.rows) : (row += 1) {
            var c: u16 = 0;
            while (c < model.channels) : (c += 1) {
                if (!p.cells[@as(usize, row) * model.channels + c].isEmpty()) highest = @max(highest, c + 1);
            }
        }
    }
    return highest;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const Schema = @import("../Schema.zig");
const fromSjon = @import("../doc/fromSjon.zig");

const q: i64 = Grid.TPQ;

const Fixture = struct {
    doc: Doc.Doc,
    derived: derive.Derived,

    fn deinit(self: *Fixture) void {
        self.derived.deinit();
        self.doc.deinit();
    }
};

fn load(gpa: Allocator, source: [:0]const u8) !Fixture {
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var loaded = try fromSjon.fromSource(gpa, &schema, source, null);
    errdefer loaded.doc.deinit();
    defer {
        loaded.map.deinit();
        loaded.diags.deinit();
    }
    if (loaded.diags.hasErrors()) {
        for (loaded.diags.items()) |d| std.debug.print("fixture: {t}: {s}\n", .{ d.code, d.message });
        return error.FixtureDoesNotLoad;
    }
    var d = loaded.doc;
    errdefer d.deinit();
    const derived = try derive.derive(gpa, &d);
    return .{ .doc = d, .derived = derived };
}

fn cellOf(module: *const itf.Module, pattern: usize, row: u16, channel: u8) model.Cell {
    return module.patterns[pattern].at(row, channel).*;
}

test "volumeOf: the inverse of the bridge's velocityOf, at both ends" {
    try testing.expectEqual(@as(u8, 64), volumeOf(127));
    try testing.expectEqual(@as(u8, 32), volumeOf(64));
    try testing.expectEqual(@as(u8, 0), volumeOf(0));
}

test "renderIt: notes land on rows with :ins 1, a volume and a cut at the end" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 125)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 127)
        \\  (note :at 2q :dur 1q :key 62 :vel 64))
    );
    defer fx.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    // Speed 6 makes a row a 16th note, so 1q is row 4 and 2q is row 8.
    try testing.expectEqual(@as(u8, 6), out.module.header.initial_speed);
    try testing.expectEqual(@as(u8, 125), out.module.header.initial_tempo);
    try testing.expectEqual(@as(u8, 4), out.module.header.highlight_minor);
    try testing.expectEqual(@as(u8, 16), out.module.header.highlight_major);

    const first = cellOf(&out.module, 0, 0, 0);
    try testing.expectEqual(@as(u8, 60), first.note);
    try testing.expectEqual(@as(u8, 1), first.ins);
    try testing.expectEqual(@as(u8, 64), first.vol);
    // The cut at the note's end, because the next note is farther away.
    try testing.expectEqual(@as(u8, model.note_cut), cellOf(&out.module, 0, 4, 0).note);
    try testing.expectEqual(@as(u8, 62), cellOf(&out.module, 0, 8, 0).note);
    try testing.expectEqual(@as(u8, 32), cellOf(&out.module, 0, 8, 0).vol);
    try testing.expectEqual(@as(u8, model.note_cut), cellOf(&out.module, 0, 12, 0).note);

    // No instrument in the module, so the cells name 1 and say so.
    try testing.expectEqual(@as(usize, 1), out.diags.count(.it_no_instrument));
    try testing.expect(out.conductor != null);
}

test "renderIt: a sub-row position uses SDx, and one that cannot rounds" {
    const gpa = testing.allocator;
    // A row is 6 IT ticks of 1 921 920 each, so one IT tick past row 0
    // is `SD1` — the delay plan 08 reaches for before it rounds.
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 1921920t :dur 11531520t :key 60 :vel 100))
    );
    defer fx.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    const cell = cellOf(&out.module, 0, 0, 0);
    try testing.expectEqual(@as(u8, 60), cell.note);
    try testing.expectEqual(fx_s, cell.fx);
    try testing.expectEqual(@as(u8, sd | 1), cell.param);
    // A delay says the position exactly, so nothing was rounded.
    try testing.expectEqual(@as(usize, 0), out.diags.count(.render_inexact));

    // Half an IT tick is a position no cell can hold: nearest row, and
    // the lane says how many of them there were.
    var half = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 960960t :dur 11531520t :key 60 :vel 100))
    );
    defer half.deinit();
    var rounded = try renderIt(gpa, &half.doc, &half.derived, null, .{});
    defer rounded.deinit();
    try testing.expectEqual(@as(usize, 1), rounded.diags.count(.render_inexact));
    try testing.expectEqual(@as(u8, 60), cellOf(&rounded.module, 0, 0, 0).note);
    try testing.expectEqual(@as(u8, 0), cellOf(&rounded.module, 0, 0, 0).fx);
}

test "renderIt: a fractional tempo is tempo_inexact and the residue keeps it" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 125.5)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 100))
    );
    defer fx.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    try testing.expect(out.diags.count(.tempo_inexact) >= 1);
    try testing.expectEqual(@as(u8, 126), out.module.header.initial_tempo);
}

test "renderIt: a tempo change becomes a Txx at its row" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 125)
        \\(tempo-point :at 1q :qpm 150)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 100))
    );
    defer fx.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    const cell = cellOf(&out.module, 0, 4, 0);
    try testing.expectEqual(fx_t, cell.fx);
    try testing.expectEqual(@as(u8, 150), cell.param);
    // The note ends on that same row, and a `Txx` in the cell is no
    // reason to lose its duration: the cut needs the NOTE column, not
    // the whole cell.
    try testing.expectEqual(@as(u8, model.note_cut), cell.note);
}

test "renderIt: a note whose voice's cell is already taken is counted, never overwritten" {
    const gpa = testing.allocator;
    // A row is 6 IT ticks; two notes half an IT tick apart round onto
    // the same cell, and a cell holds one note.
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 960960t :key 60 :vel 100)
        \\  (note :at 960960t :dur 960960t :key 62 :vel 90))
    );
    defer fx.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    // The first note kept the cell; the second is named and dropped.
    try testing.expectEqual(@as(u8, 60), cellOf(&out.module, 0, 0, 0).note);
    try testing.expect(out.diags.count(.render_inexact) >= 1);
    var said = false;
    for (out.diags.items()) |d| {
        if (std.mem.indexOf(u8, d.message, "a cell holds one note") != null) said = true;
    }
    try testing.expect(said);
}

test "renderIt: a three-voice chord takes three channels and a fifth voice trips the cap" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name chord :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 100)
        \\  (note :at 0q :dur 1q :key 64 :vel 100)
        \\  (note :at 0q :dur 1q :key 67 :vel 100))
    );
    defer fx.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    try testing.expectEqual(@as(u8, 60), cellOf(&out.module, 0, 0, 0).note);
    try testing.expectEqual(@as(u8, 64), cellOf(&out.module, 0, 0, 1).note);
    try testing.expectEqual(@as(u8, 67), cellOf(&out.module, 0, 0, 2).note);
    try testing.expectEqual(@as(usize, 0), out.diags.count(.render_polyphony_exceeded));
    // Three channels, three records — a record names ONE channel, so a
    // lane spread over a set names each of them.
    try testing.expectEqual(@as(usize, 3), out.lanes.len);

    var five = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name chord :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 100)
        \\  (note :at 0q :dur 1q :key 62 :vel 100)
        \\  (note :at 0q :dur 1q :key 64 :vel 100)
        \\  (note :at 0q :dur 1q :key 65 :vel 100)
        \\  (note :at 0q :dur 1q :key 67 :vel 100))
    );
    defer five.deinit();
    var capped = try renderIt(gpa, &five.doc, &five.derived, null, .{ .voices = 4 });
    defer capped.deinit();
    try testing.expectEqual(@as(usize, 1), capped.diags.count(.render_polyphony_exceeded));
    try testing.expectEqual(@as(usize, 4), capped.lanes.len);
}

test "renderIt: a curve writes the volume column, linear per row, in-cubic as steps" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name glow :kind curve
        \\  (keyframe :at 0q :value 0)
        \\  (keyframe :at 1q :value 1 :ease linear))
    );
    defer fx.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    try testing.expectEqual(@as(u8, 0), cellOf(&out.module, 0, 0, 0).vol);
    try testing.expectEqual(@as(u8, 16), cellOf(&out.module, 0, 1, 0).vol);
    try testing.expectEqual(@as(u8, 32), cellOf(&out.module, 0, 2, 0).vol);
    try testing.expectEqual(@as(u8, 48), cellOf(&out.module, 0, 3, 0).vol);
    try testing.expectEqual(@as(u8, 64), cellOf(&out.module, 0, 4, 0).vol);
    try testing.expectEqual(Doc.ItColumn.vol, out.lanes[0].address.it.column.?);

    var eased = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name glow :kind curve
        \\  (keyframe :at 0q :value 0)
        \\  (keyframe :at 1q :value 1 :ease in-cubic))
    );
    defer eased.deinit();
    var steps = try renderIt(gpa, &eased.doc, &eased.derived, null, .{});
    defer steps.deinit();
    try testing.expectEqual(@as(u8, model.vol_none), cellOf(&steps.module, 0, 1, 0).vol);
    try testing.expectEqual(@as(usize, 1), steps.lanes[0].steps_only.len);
    try testing.expectEqualStrings("in-cubic", steps.lanes[0].steps_only[0].ease);
}

test "renderIt: rendering into an anchor keeps its patterns and takes channels above them" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 100))
    );
    defer fx.deinit();

    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    try b.addOrder(0);
    const p = try b.addPattern(64);
    p.at(0, 0).* = .{ .note = 48, .ins = 1, .vol = 64 };
    p.at(0, 1).* = .{ .note = 52, .ins = 1, .vol = 64 };
    var base = b.finish();
    defer base.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, &base, .{});
    defer out.deinit();

    // The anchor's own cells, untouched.
    try testing.expectEqual(@as(u8, 48), cellOf(&out.module, 0, 0, 0).note);
    try testing.expectEqual(@as(u8, 52), cellOf(&out.module, 0, 0, 1).note);
    try testing.expectEqual(@as(u8, 0), cellOf(&out.module, 0, 0, 0).fx);
    try testing.expectEqual(@as(u8, 0), cellOf(&out.module, 0, 0, 1).fx);
    // And the lane above them.
    try testing.expectEqual(@as(u8, 60), cellOf(&out.module, 0, 0, 2).note);
    try testing.expectEqual(@as(u6, 2), out.lanes[0].address.it.channel);
    try testing.expectEqual(@as(usize, 1), out.module.patterns.len);
}

test "renderIt: an anchored conductor's Txx goes above the anchor's channels too" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 125)
        \\(tempo-point :at 1q :qpm 150)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 100))
    );
    defer fx.deinit();

    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    try b.addOrder(0);
    const p = try b.addPattern(64);
    p.at(0, 0).* = .{ .note = 48, .ins = 1, .vol = 64 };
    var base = b.finish();
    defer base.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, &base, .{});
    defer out.deinit();

    // Row 4, channel 0 is the ANCHOR's column and stays empty; the
    // tempo change goes in the first channel this render owns.
    try testing.expect(cellOf(&out.module, 0, 4, 0).isEmpty());
    try testing.expectEqual(fx_t, cellOf(&out.module, 0, 4, 1).fx);
    try testing.expectEqual(@as(u8, 150), cellOf(&out.module, 0, 4, 1).param);
}

test "renderIt: a lane with no channel left is render_channels_exhausted" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 100))
    );
    defer fx.deinit();

    // An anchor that already uses the LAST channel: the lanes go above
    // the highest one the module uses, and there is nothing above 64.
    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();
    try b.addOrder(0);
    const p = try b.addPattern(64);
    p.at(0, model.channels - 1).* = .{ .note = 48, .ins = 1, .vol = 64 };
    var base = b.finish();
    defer base.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, &base, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.render_channels_exhausted));
    try testing.expectEqual(@as(usize, 0), out.lanes.len);
    // And the anchor's own cell is untouched.
    try testing.expectEqual(@as(u8, 48), cellOf(&out.module, 0, 0, model.channels - 1).note);
}

test "renderIt: a query lane is residue_only and no channel is spent on it" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name hats :kind query :query (euclid 3 8 1))
    );
    defer fx.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.diags.count(.residue_only));
    try testing.expectEqual(@as(usize, 0), out.lanes.len);
}

test "renderIt: the lane record's hash is the hash of the module that comes back" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 2bar)
        \\(tempo-point :at 0q :qpm 125)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 100)
        \\  (note :at 4q :dur 1q :key 62 :vel 90))
    );
    defer fx.deinit();

    var out = try renderIt(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    var written = try itf.write.write(gpa, &out.module, null, .{ .loose = true });
    defer written.deinit();
    var back = try itf.read.read(gpa, written.bytes);
    defer back.deinit();

    var rows = try itf.walk.derive(gpa, &back.module, .{});
    defer rows.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const played = try reconcile.playedPatterns(scratch.allocator(), &rows);

    try testing.expect(out.lanes.len > 0);
    for (out.lanes) |rec| {
        const now = records.hashItLane(&back.module, &rows, &[_]u8{rec.address.it.channel}, played);
        try testing.expectEqualSlices(u8, &rec.hash, &now);
    }
    try testing.expectEqualSlices(
        u8,
        &out.conductor.?.hash,
        &records.hashItConductor(&back.module),
    );
}

test "renderIt: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails with
    // error.OutOfMemory and testing.allocator sees no leak; past the last
    // index it succeeds. Bounded by the number of allocations the call
    // makes, which the loop discovers.
    // A notes lane, a curve lane and a tempo change: the three kinds of
    // cell the render places, so every allocating path is on the way.
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 125)
        \\(tempo-point :at 2q :qpm 150)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 60 :vel 127)
        \\  (note :at 2q :dur 1q :key 62 :vel 64))
        \\(lane :name swell :kind curve :range [0 1]
        \\  (keyframe :at 0q :value 0 :ease linear)
        \\  (keyframe :at 4q :value 1 :ease in-cubic))
    );
    defer fx.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const result = renderIt(failing.allocator(), &fx.doc, &fx.derived, null, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var value = try result;
            value.deinit();
            break;
        }
    }
}
