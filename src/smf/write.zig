//! The canonical SMF writer: a `Sequence` in, the bytes of a Standard
//! MIDI File out.
//!
//! One layout, frozen at E1 (plan 05, "The canonical writer"):
//!
//!   * the header carries the sequence's `format` and the track count,
//!     and a division that is always PULSES PER QUARTER — a file read
//!     with a SMPTE division is written on the grid it converted to,
//!     and every `set-tempo` on that grid says 500 000 µs, the tempo
//!     the conversion assumed (`Division.tempoOnGrid`), so the wall
//!     clock the SMPTE ticks measured survives the rewrite;
//!   * each track's events are STABLE-sorted by absolute tick (document
//!     order breaks ties, which is what the residue's placement rule
//!     stands on) and the deltas re-derived;
//!   * running status is used for consecutive channel messages of the
//!     same status, and reset by every meta and sysex event;
//!   * a note off is `8n`; a `note_on` with velocity 0 was read as one
//!     and is written back as one;
//!   * every track ends with exactly one `FF 2F 00`, and every VLQ is
//!     minimal.
//!
//! With those rules `write(read(bytes)) == bytes` for any file this
//! writer produced (rung 1), and `read(write(read(bytes)))` equals
//! `read(bytes)` event for event for any file at all (rung 2).
//!
//! Failures are diagnostics on the returned value, never errors: a
//! mid-track end of track is `end_of_track_early`, a `--ppq` rescale
//! that does not land is `ppq_rescale_inexact` (refusing rather than
//! rounding, unless `round`), and a delta no VLQ can hold is
//! `tick_overflow` — the one place this writer reaches for the tick
//! grid's code, because a delta above `0x0FFF_FFFF` is exactly a tick
//! SMF cannot represent. The bytes are still produced and still
//! readable; the caller asks `hasErrors()` before keeping them.
//!
//! Spans are offsets into the bytes being PRODUCED (there is no input
//! text to point at), which is what `tempura inspect` wants anyway.
//!
//! Foreign chunks are not re-emitted: a canonical file is a header and
//! its tracks. They stay on the `Sequence` for `inspect` and the residue.

const std = @import("std");
const Diag = @import("../Diag.zig");
const sequence = @import("Sequence.zig");
const vlq = @import("vlq.zig");
const reader = @import("read.zig");

const testing = std.testing;
const support = @import("test_support.zig");
const Kind = sequence.Kind;
const Sequence = sequence.Sequence;
const Event = sequence.Event;
const Writer = std.Io.Writer;

/// This module's error set: writing can only fail the way any allocation
/// fails.
pub const Error = error{OutOfMemory};

/// The writer's switches, each one a CLI flag of plan 05.
pub const Options = struct {
    /// `--no-running-status` turns this off.
    running_status: bool = true,
    /// `--format 0`: merge every track into one, by tick, stable, the
    /// first track's events first at a tie.
    format0: bool = false,
    /// `--ppq N`: rescale every tick onto a new division, 1..32767.
    /// The writer does not second-guess the number — a zero is written
    /// as a zero division, and the reader that meets it says so.
    ppq: ?u15 = null,
    /// `--round`: accept a rescaled tick that does not land exactly,
    /// rounding half to even, instead of refusing it.
    round: bool = false,
};

/// The bytes and what the writer thought of them. Arena-backed: one
/// `deinit` frees the file and the report.
pub const Written = struct {
    arena: std.heap.ArenaAllocator,
    bytes: []u8,
    diags: Diag.List,

    pub fn deinit(self: *Written) void {
        self.diags.deinit();
        self.arena.deinit();
    }
};

/// Write `seq` as a Standard MIDI File.
///
/// Borrows the sequence and never mutates it — the sort happens on a copy
/// of each track's events.
pub fn write(gpa: std.mem.Allocator, seq: *const Sequence, opts: Options) Error!Written {
    seq.invariants();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    const a = arena.allocator();
    const grid = seq.division.pulsesPerQuarter();

    // `--ppq 0` asks for a division no file can carry and no tick can
    // land on. It is refused rather than obeyed — obeying it would
    // collapse every tick to zero and lose the music silently — and the
    // file is written on the division it already had.
    var to_ppq = opts.ppq orelse grid;
    if (opts.ppq) |requested| {
        if (requested == 0) {
            try diags.add(
                .ppq_rescale_inexact,
                .err,
                .{ .start = 0, .end = 0 },
                "a division of zero pulses per quarter holds no tick; writing on {d}",
                .{grid},
            );
            to_ppq = grid;
        }
    }

    var emit: Emit = .{
        .seq = seq,
        .opts = opts,
        .diags = &diags,
        .a = a,
        .from_ppq = grid,
        .to_ppq = to_ppq,
        .out = .init(a),
    };
    emit.run() catch |err| switch (err) {
        // An `Allocating` writer fails one way only.
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };

    return .{ .arena = arena, .bytes = emit.out.written(), .diags = diags };
}

/// One pass over one sequence.
const Emit = struct {
    seq: *const Sequence,
    opts: Options,
    diags: *Diag.List,
    a: std.mem.Allocator,
    from_ppq: u15,
    to_ppq: u15,
    out: Writer.Allocating,

    const Fail = error{ WriteFailed, OutOfMemory };

    fn diag(
        self: *Emit,
        code: Diag.Code,
        severity: Diag.Severity,
        at: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) Fail!void {
        const start: u32 = @intCast(@min(at, std.math.maxInt(u32)));
        try self.diags.add(code, severity, .{ .start = start, .end = start }, fmt, args);
    }

    fn run(self: *Emit) Fail!void {
        const w = &self.out.writer;
        const tracks: u16 = @intCast(@min(
            if (self.opts.format0) @as(usize, 1) else self.seq.tracks.len,
            std.math.maxInt(u16),
        ));

        try w.writeAll("MThd");
        try writeInt(w, u32, 6);
        try writeInt(w, u16, if (self.opts.format0) 0 else self.seq.format);
        try writeInt(w, u16, tracks);
        try writeInt(w, u16, self.to_ppq);

        if (self.opts.format0) {
            // Merged in TRACK order, then stable-sorted: at a tie the
            // conductor track's events come first, because they came
            // first in the list.
            //
            // Each source track brought its own `FF 2F 00`, and the one
            // file being written wants exactly one — so they are dropped
            // HERE, keeping the latest of their ticks for the end the
            // merged track gets. Dropping them in the emitting loop
            // instead would report every one but the last as a mid-track
            // end of track, which is a merge, not a defect.
            var merged: std.ArrayList(Event) = .empty;
            var ends_at: ?i64 = null;
            for (self.seq.tracks) |t| {
                for (t.events, 0..) |e, i| {
                    if (e.kind == .end_of_track) {
                        // A genuinely mid-track end of track is still
                        // one, merge or no merge.
                        if (i + 1 != t.events.len) try self.diag(
                            .end_of_track_early,
                            .warning,
                            self.out.written().len,
                            "an end of track with {d} events after it in its own track",
                            .{t.events.len - i - 1},
                        );
                        ends_at = @max(ends_at orelse e.at, e.at);
                        continue;
                    }
                    try merged.append(self.a, e);
                }
            }
            try self.track(merged.items, ends_at);
        } else {
            for (self.seq.tracks) |t| {
                const copy = try self.a.dupe(Event, t.events);
                try self.track(copy, null);
            }
        }
    }

    /// One `MTrk`. `events` is this function's to sort.
    ///
    /// `ends_at` is the tick the single `FF 2F 00` belongs at when the
    /// caller already took the ends of track out of `events` (the
    /// `format0` merge does); `null` leaves them in the list, where each
    /// one but the last is a `end_of_track_early`.
    fn track(self: *Emit, events: []Event, ends_at: ?i64) Fail!void {
        std.mem.sort(Event, events, {}, byTick);

        var body: Writer.Allocating = .init(self.a);
        const w = &body.writer;
        // Where this body will land in the file, so a diagnostic's span
        // is a file offset and not a track offset.
        const base = self.out.written().len + 8;

        var last: i64 = 0;
        var running: u8 = 0;
        var end_at: ?i64 = if (ends_at) |at| try self.scaled(at, base) else null;

        for (events, 0..) |e, i| {
            const at = try self.scaled(e.at, base + body.written().len);
            if (e.kind == .end_of_track) {
                if (i + 1 != events.len) try self.diag(
                    .end_of_track_early,
                    .warning,
                    base + body.written().len,
                    "an end of track with {d} events after it; one is written, at the end",
                    .{events.len - i - 1},
                );
                end_at = at;
                continue;
            }
            try self.delta(w, at - last, base + body.written().len);
            last = at;
            try self.event(w, e, &running);
        }

        try self.delta(w, @max(end_at orelse last, last) - last, base + body.written().len);
        try w.writeAll(&[_]u8{ 0xFF, 0x2F, 0x00 });

        const out = &self.out.writer;
        try out.writeAll("MTrk");
        try writeInt(out, u32, @intCast(body.written().len));
        try out.writeAll(body.written());
    }

    fn byTick(_: void, x: Event, y: Event) bool {
        return x.at < y.at;
    }

    /// A tick on the target grid.
    ///
    /// Exact rational arithmetic in `i128`, so the only question is
    /// whether the remainder is zero. It is the rounding `--round` asks
    /// for that is half-to-even, matching how the document's own literals
    /// round (plan 03).
    fn scaled(self: *Emit, at: i64, offset: usize) Fail!i64 {
        if (self.to_ppq == self.from_ppq) return at;

        const numerator = @as(i128, at) * @as(i128, self.to_ppq);
        const denominator = @as(i128, self.from_ppq);
        const quotient = @divFloor(numerator, denominator);
        const remainder = numerator - quotient * denominator;
        if (remainder == 0) return clampTick(quotient);

        if (!self.opts.round) {
            try self.diag(
                .ppq_rescale_inexact,
                .err,
                offset,
                "tick {d} does not land on {d} pulses per quarter (it was {d})",
                .{ at, self.to_ppq, self.from_ppq },
            );
            return clampTick(quotient);
        }

        const twice = remainder * 2;
        const up = twice > denominator or (twice == denominator and @rem(quotient, 2) != 0);
        return clampTick(quotient + @intFromBool(up));
    }

    fn clampTick(value: i128) i64 {
        return @intCast(std.math.clamp(
            value,
            @as(i128, std.math.minInt(i64)),
            @as(i128, std.math.maxInt(i64)),
        ));
    }

    /// A delta time. Negative cannot be written and is zero; too large
    /// cannot be written either and is the ceiling, with `tick_overflow`
    /// saying so.
    fn delta(self: *Emit, w: *Writer, value: i64, offset: usize) Fail!void {
        if (value <= 0) return vlq.write(w, 0);
        if (value > vlq.MAX) {
            try self.diag(
                .tick_overflow,
                .err,
                offset,
                "a delta of {d} ticks; SMF stops at {d}",
                .{ value, vlq.MAX },
            );
            return vlq.write(w, vlq.MAX);
        }
        try vlq.write(w, @intCast(value));
    }

    fn event(self: *Emit, w: *Writer, e: Event, running: *u8) Fail!void {
        if (e.kind.status()) |high| {
            const p = e.payload;
            const parts: struct { u8, u8, u8 } = switch (e.kind) {
                .note_off, .note_on => .{ p.note.ch, p.note.key, p.note.vel },
                .poly_pressure => .{ p.poly.ch, p.poly.key, p.poly.val },
                .control_change => .{ p.control.ch, p.control.num, p.control.val },
                .program_change => .{ p.program.ch, p.program.num, 0 },
                .channel_pressure => .{ p.pressure.ch, p.pressure.val, 0 },
                // 14 bits, LSB first, centre 8192.
                else => .{
                    p.bend.ch,
                    @truncate(p.bend.value & 0x7F),
                    @truncate((p.bend.value >> 7) & 0x7F),
                },
            };
            const status = high | (parts[0] & 0x0F);
            if (!self.opts.running_status or running.* != status) {
                try w.writeByte(status);
                running.* = status;
            }
            try w.writeByte(parts[1] & 0x7F);
            if (e.kind.dataBytes() == 2) try w.writeByte(parts[2] & 0x7F);
            return;
        }

        // RP-001: a meta or a sysex cancels running status.
        running.* = 0;
        switch (e.kind) {
            .sysex, .escape => {
                try w.writeByte(if (e.kind == .sysex) @as(u8, 0xF0) else 0xF7);
                try self.payload(w, self.seq.bytesOf(e.payload.bytes));
            },
            .sequence_number => try self.meta(w, 0x00, &[_]u8{
                @truncate(e.payload.number >> 8),
                @truncate(e.payload.number),
            }),
            .midi_channel_prefix, .midi_port => try self.meta(
                w,
                e.kind.metaType().?,
                &[_]u8{e.payload.byte},
            ),
            .set_tempo => {
                // The number on the file's grid, not the number as read:
                // for a SMPTE sequence that is 500 000 µs whatever the
                // event said, or the converted division would be
                // conducted at a tempo it was never derived for
                // (`Division.tempoOnGrid`).
                const us = self.seq.division.tempoOnGrid(e.payload.tempo);
                try self.meta(w, 0x51, &[_]u8{
                    @truncate(us >> 16),
                    @truncate(us >> 8),
                    @truncate(us),
                });
            },
            .smpte_offset => {
                const s = e.payload.smpte;
                try self.meta(w, 0x54, &[_]u8{ s.hr, s.mn, s.se, s.fr, s.ff });
            },
            .time_signature => {
                const t = e.payload.time_sig;
                try self.meta(w, 0x58, &[_]u8{ t.nn, t.dd, t.cc, t.bb });
            },
            .key_signature => {
                const k = e.payload.key_sig;
                try self.meta(w, 0x59, &[_]u8{ @bitCast(k.sf), k.mi });
            },
            .meta_unknown => try self.meta(
                w,
                e.payload.meta.meta_type,
                self.seq.bytesOf(e.payload.meta.bytes),
            ),
            .tempura_residue => {
                // The envelope is rebuilt from the typed fields, so the
                // payload is byte-identical to the one that was read
                // (plan 04, "The SMF carrier").
                const r = e.payload.residue;
                const body = self.seq.bytesOf(r.body);
                try w.writeAll(&[_]u8{ 0xFF, 0x7F });
                try vlq.write(w, @intCast(@min(body.len + 8, vlq.MAX)));
                try w.writeAll(&[_]u8{ 0x7D, 't', 'e', 'm', r.ver, r.kind, r.seq, r.total });
                try w.writeAll(body[0..@min(body.len, vlq.MAX - 8)]);
            },
            // Every text meta, the sequencer-specific ones, and the
            // easing hint: the stored bytes, whatever they are. Which
            // kinds those are is `payloadField() == .bytes`, asked
            // through `poolBytes` so the table lives in one file.
            else => try self.meta(
                w,
                e.kind.metaType() orelse 0x7F,
                self.seq.bytesOf(e.payload.poolBytes(e.kind).?),
            ),
        }
    }

    fn meta(self: *Emit, w: *Writer, meta_type: u8, bytes: []const u8) Fail!void {
        try w.writeAll(&[_]u8{ 0xFF, meta_type });
        try self.payload(w, bytes);
    }

    /// `<len VLQ> <bytes>`. A payload longer than a VLQ can measure is
    /// unreachable from any file this reader produced (a chunk is at most
    /// four gigabytes and a VLQ holds 256 megabytes), and is cut rather
    /// than mis-measured.
    fn payload(_: *Emit, w: *Writer, bytes: []const u8) Fail!void {
        const n = @min(bytes.len, vlq.MAX);
        try vlq.write(w, @intCast(n));
        try w.writeAll(bytes[0..n]);
    }
};

fn writeInt(w: *Writer, comptime T: type, value: T) Writer.Error!void {
    var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .big);
    try w.writeAll(&buf);
}

/// Builds the two-note sequence the byte-exact tests below write out.
fn twoNotes(gpa: std.mem.Allocator) !Sequence {
    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const t = try b.addTrack();
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(t, 96, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
    return b.finish();
}

test "write: the header is the format and the track count, and never a SMPTE division" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    // Read as SMPTE; written as the PPQ it converted to, because a
    // canonical file's division is musical (plan 05).
    b.division = .{ .smpte = .{ .fps = 25, .tpf = 40 } };
    const t0 = try b.addTrack();
    try b.addEvent(t0, 0, .end_of_track, .empty);
    _ = try b.addTrack();

    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{});
    defer out.deinit();

    try testing.expectEqualSlices(u8, &[_]u8{
        'M', 'T', 'h', 'd', 0, 0, 0, 6,
        0, 1, // format 1
        0, 2, // two tracks
        0x01, 0xF4, // 500 pulses per quarter
    }, out.bytes[0..14]);
    try testing.expect(!out.diags.hasErrors());
}

test "write: a SMPTE sequence's set-tempo is written as 500 000 µs, the tempo its grid assumed" {
    const gpa = testing.allocator;

    // 25 fps × 40 tpf: 1000 ticks a second, on a 500-pulse grid. The
    // file says 60 QPM; the grid was derived at 120, and a 60 on it
    // would make every second two (`Division.tempoOnGrid`).
    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .smpte = .{ .fps = 25, .tpf = 40 } };
    const t = try b.addTrack();
    try b.addEvent(t, 0, .set_tempo, .{ .tempo = 1_000_000 });
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(t, 1000, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
    try b.addEvent(t, 1000, .end_of_track, .empty);
    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{});
    defer out.deinit();
    try testing.expect(!out.diags.hasErrors());

    // The tempo bytes are `07 A1 20`, never `0F 42 40`; the ticks are
    // untouched.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20 }, out.bytes[22..29]);
    try testing.expect(std.mem.indexOf(u8, out.bytes, &[_]u8{ 0x0F, 0x42, 0x40 }) == null);

    var back = try reader.read(gpa, out.bytes);
    defer back.deinit();
    const events = back.sequence.tracks[0].events;
    try testing.expectEqual(sequence.Division{ .ppq = 500 }, back.sequence.division);
    try testing.expectEqual(Kind.set_tempo, events[0].kind);
    try testing.expectEqual(@as(u32, 500_000), events[0].payload.tempo);
    try testing.expectEqual(@as(i64, 1000), events[2].at);
    // The value itself was never touched: the rewrite is the writer's.
    try testing.expectEqual(@as(u32, 1_000_000), seq.tracks[0].events[0].payload.tempo);
}

test "write: events are stable-sorted by tick and the deltas re-derived" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const t = try b.addTrack();
    // Document order is NOT tick order, and two events share a tick.
    try b.addEvent(t, 96, .control_change, .{ .control = .{ .ch = 0, .num = 1, .val = 1 } });
    try b.addEvent(t, 0, .control_change, .{ .control = .{ .ch = 0, .num = 2, .val = 2 } });
    try b.addEvent(t, 96, .control_change, .{ .control = .{ .ch = 0, .num = 3, .val = 3 } });

    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{});
    defer out.deinit();

    var back = try reader.read(gpa, out.bytes);
    defer back.deinit();

    const events = back.sequence.tracks[0].events;
    try testing.expectEqual(@as(usize, 4), events.len);
    try testing.expectEqual(@as(i64, 0), events[0].at);
    try testing.expectEqual(@as(u8, 2), events[0].payload.control.num);
    // The tie keeps DOCUMENT order: 1 before 3, as they were added.
    try testing.expectEqual(@as(i64, 96), events[1].at);
    try testing.expectEqual(@as(u8, 1), events[1].payload.control.num);
    try testing.expectEqual(@as(i64, 96), events[2].at);
    try testing.expectEqual(@as(u8, 3), events[2].payload.control.num);
}

test "write: running status runs, and a meta or a sysex resets it" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const t = try b.addTrack();
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 62, .vel = 100 } });
    // A different channel is a different status byte.
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 1, .key = 64, .vel = 100 } });
    const text = try b.addBytes("x");
    try b.addEvent(t, 0, .marker, .{ .bytes = text });
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 1, .key = 66, .vel = 100 } });
    try b.addEvent(t, 96, .end_of_track, .empty);

    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{});
    defer out.deinit();

    var track = support.ByteWriter.init(gpa);
    defer track.deinit();
    try track.vlq(0);
    try track.raw(&[_]u8{ 0x90, 60, 100 });
    try track.vlq(0);
    try track.raw(&[_]u8{ 62, 100 }); // running status
    try track.vlq(0);
    try track.raw(&[_]u8{ 0x91, 64, 100 }); // another channel
    try track.vlq(0);
    try track.raw(&[_]u8{ 0xFF, 0x06, 0x01, 'x' });
    try track.vlq(0);
    try track.raw(&[_]u8{ 0x91, 66, 100 }); // the meta reset it
    try track.vlq(96);
    try track.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const expected = try support.buildFile(gpa, .{ .format = 0, .division = 96 }, &.{track.buf.items});
    defer gpa.free(expected);
    try testing.expectEqualSlices(u8, expected, out.bytes);
}

test "write: running_status off spells every status byte" {
    const gpa = testing.allocator;

    var seq = try twoNotes(gpa);
    defer seq.deinit();

    var out = try write(gpa, &seq, .{ .running_status = false });
    defer out.deinit();

    var with = try write(gpa, &seq, .{});
    defer with.deinit();

    var track = support.ByteWriter.init(gpa);
    defer track.deinit();
    try track.vlq(0);
    try track.raw(&[_]u8{ 0x90, 60, 100 });
    try track.vlq(96);
    try track.raw(&[_]u8{ 0x80, 60, 64 });
    try track.vlq(0);
    try track.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const expected = try support.buildFile(gpa, .{ .format = 0, .division = 96 }, &.{track.buf.items});
    defer gpa.free(expected);
    try testing.expectEqualSlices(u8, expected, out.bytes);
    // Two different statuses, so running status changes nothing here.
    try testing.expectEqualSlices(u8, expected, with.bytes);
}

test "write: a note off is 8n, and a note_on with velocity 0 stays 9n 00" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const t = try b.addTrack();
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    // Stored as read: a `9n` with velocity 0 is written back as one.
    try b.addEvent(t, 96, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 0 } });
    // And a note_off is `8n`, never `9n` with velocity 0.
    try b.addEvent(t, 192, .note_off, .{ .note = .{ .ch = 0, .key = 62, .vel = 0 } });
    try b.addEvent(t, 192, .end_of_track, .empty);

    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{});
    defer out.deinit();

    var track = support.ByteWriter.init(gpa);
    defer track.deinit();
    try track.vlq(0);
    try track.raw(&[_]u8{ 0x90, 60, 100 });
    try track.vlq(96);
    try track.raw(&[_]u8{ 60, 0 }); // running status, still a note on
    try track.vlq(96);
    try track.raw(&[_]u8{ 0x80, 62, 0 });
    try track.vlq(0);
    try track.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const expected = try support.buildFile(gpa, .{ .format = 0, .division = 96 }, &.{track.buf.items});
    defer gpa.free(expected);
    try testing.expectEqualSlices(u8, expected, out.bytes);
}

test "write: a track with no end-of-track gets one at the last event's tick" {
    const gpa = testing.allocator;

    var seq = try twoNotes(gpa); // no end_of_track event at all
    defer seq.deinit();

    var out = try write(gpa, &seq, .{});
    defer out.deinit();

    var back = try reader.read(gpa, out.bytes);
    defer back.deinit();

    const events = back.sequence.tracks[0].events;
    try testing.expectEqual(Kind.end_of_track, events[events.len - 1].kind);
    try testing.expectEqual(@as(i64, 96), events[events.len - 1].at);
    try testing.expectEqual(@as(usize, 0), back.diags.count(.end_of_track_missing));
    try testing.expect(!out.diags.hasErrors());
}

test "write: an end-of-track that is not last is end_of_track_early, and exactly one is written" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const t = try b.addTrack();
    try b.addEvent(t, 0, .end_of_track, .empty);
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(t, 96, .end_of_track, .empty);

    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.end_of_track_early));

    var back = try reader.read(gpa, out.bytes);
    defer back.deinit();
    const events = back.sequence.tracks[0].events;
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(Kind.note_on, events[0].kind);
    try testing.expectEqual(Kind.end_of_track, events[1].kind);
    try testing.expectEqual(@as(i64, 96), events[1].at);
    try testing.expectEqual(@as(usize, 0), back.diags.count(.end_of_track_early));
}

test "write: meta text is the stored bytes, and its length is a minimal VLQ" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const t = try b.addTrack();
    const long = try b.addBytes("x" ** 200);
    try b.addEvent(t, 0, .text_event, .{ .bytes = long });
    try b.addEvent(t, 0, .end_of_track, .empty);

    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{});
    defer out.deinit();

    // 200 bytes is `81 48`, two groups, and nothing longer.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xFF, 0x01, 0x81, 0x48 }, out.bytes[22..27]);
    try testing.expectEqualSlices(u8, "x" ** 200, out.bytes[27..227]);
}

test "write: format0 merges the tracks by tick, stable, the tempo track first" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = 96 };

    const conductor = try b.addTrack();
    try b.addEvent(conductor, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(conductor, 96, .set_tempo, .{ .tempo = 400_000 });
    try b.addEvent(conductor, 96, .end_of_track, .empty);

    const music = try b.addTrack();
    try b.addEvent(music, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(music, 48, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
    try b.addEvent(music, 192, .end_of_track, .empty);

    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{ .format0 = true });
    defer out.deinit();

    var back = try reader.read(gpa, out.bytes);
    defer back.deinit();

    try testing.expectEqual(@as(u8, 0), back.sequence.format);
    try testing.expectEqual(@as(usize, 1), back.sequence.tracks.len);
    const events = back.sequence.tracks[0].events;
    try testing.expectEqual(@as(usize, 5), events.len);
    // At tick 0 the conductor's event comes first, because its track did.
    try testing.expectEqual(Kind.set_tempo, events[0].kind);
    try testing.expectEqual(Kind.note_on, events[1].kind);
    try testing.expectEqual(Kind.note_off, events[2].kind);
    try testing.expectEqual(@as(i64, 48), events[2].at);
    try testing.expectEqual(Kind.set_tempo, events[3].kind);
    try testing.expectEqual(@as(i64, 96), events[3].at);
    // One end of track, at the latest tick of the tracks merged.
    try testing.expectEqual(Kind.end_of_track, events[4].kind);
    try testing.expectEqual(@as(i64, 192), events[4].at);

    // And an ordinary merge says NOTHING: every source track brought its
    // own end of track, and dropping all but one of them is the merge
    // doing its job, not a defect to report.
    try testing.expectEqual(@as(usize, 0), out.diags.items().len);
}

test "write: format0 still reports an end of track that is early in its own track" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = 96 };

    const first = try b.addTrack();
    try b.addEvent(first, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(first, 96, .end_of_track, .empty);

    const second = try b.addTrack();
    // This one ends and then carries on: a defect of the SEQUENCE, which
    // survives the merge as a diagnostic.
    try b.addEvent(second, 0, .end_of_track, .empty);
    try b.addEvent(second, 48, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(second, 192, .end_of_track, .empty);

    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{ .format0 = true });
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.end_of_track_early));
    try testing.expectEqual(@as(usize, 1), out.diags.items().len);

    var back = try reader.read(gpa, out.bytes);
    defer back.deinit();
    const events = back.sequence.tracks[0].events;
    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqual(Kind.set_tempo, events[0].kind);
    try testing.expectEqual(Kind.note_on, events[1].kind);
    // Exactly one end of track, at the latest end the sources named.
    try testing.expectEqual(Kind.end_of_track, events[2].kind);
    try testing.expectEqual(@as(i64, 192), events[2].at);
}

test "write: a zero ppq is refused, and the file keeps the division it had" {
    const gpa = testing.allocator;

    var seq = try twoNotes(gpa);
    defer seq.deinit();

    var out = try write(gpa, &seq, .{ .ppq = 0 });
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.ppq_rescale_inexact));
    try testing.expect(out.diags.hasErrors());

    // Refused, not obeyed: the ticks are where they were, on the
    // division the sequence already carried.
    var back = try reader.read(gpa, out.bytes);
    defer back.deinit();
    try testing.expect(!back.diags.hasErrors());
    try testing.expectEqual(sequence.Division{ .ppq = 96 }, back.sequence.division);
    try testing.expectEqual(@as(i64, 96), back.sequence.tracks[0].events[1].at);
}

test "write: ppq rescales exactly, refuses what does not land, and rounds when told to" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 480 };
    const t = try b.addTrack();
    try b.addEvent(t, 240, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(t, 480, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
    try b.addEvent(t, 480, .end_of_track, .empty);

    var seq = try b.finish();
    defer seq.deinit();

    // 480 → 96 divides every tick here.
    {
        var out = try write(gpa, &seq, .{ .ppq = 96 });
        defer out.deinit();
        try testing.expectEqual(@as(usize, 0), out.diags.count(.ppq_rescale_inexact));

        var back = try reader.read(gpa, out.bytes);
        defer back.deinit();
        try testing.expectEqual(sequence.Division{ .ppq = 96 }, back.sequence.division);
        try testing.expectEqual(@as(i64, 48), back.sequence.tracks[0].events[0].at);
        try testing.expectEqual(@as(i64, 96), back.sequence.tracks[0].events[1].at);
    }

    // 480 → 100 does not: 240 lands on 50, 480 on 100, but a tick of 1
    // would be 0.208…, so the refusal is per event.
    var odd: sequence.Builder = .init(gpa);
    errdefer odd.deinit();
    odd.format = 0;
    odd.division = .{ .ppq = 480 };
    const ot = try odd.addTrack();
    try odd.addEvent(ot, 1, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try odd.addEvent(ot, 3, .end_of_track, .empty);
    var odd_seq = try odd.finish();
    defer odd_seq.deinit();

    {
        var out = try write(gpa, &odd_seq, .{ .ppq = 96 });
        defer out.deinit();
        // Refusing rather than rounding: the caller checks hasErrors.
        try testing.expectEqual(@as(usize, 2), out.diags.count(.ppq_rescale_inexact));
        try testing.expect(out.diags.hasErrors());
    }
    {
        var out = try write(gpa, &odd_seq, .{ .ppq = 96, .round = true });
        defer out.deinit();
        try testing.expectEqual(@as(usize, 0), out.diags.count(.ppq_rescale_inexact));

        var back = try reader.read(gpa, out.bytes);
        defer back.deinit();
        // 1 · 96 / 480 = 0.2 → 0, and 3 · 96 / 480 = 0.6 → 1.
        try testing.expectEqual(@as(i64, 0), back.sequence.tracks[0].events[0].at);
        try testing.expectEqual(@as(i64, 1), back.sequence.tracks[0].events[1].at);
    }
}

test "write: a delta a VLQ cannot hold is tick_overflow, and the file stays readable" {
    const gpa = testing.allocator;

    var b: sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const t = try b.addTrack();
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(t, vlq.MAX + 1, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });

    var seq = try b.finish();
    defer seq.deinit();

    var out = try write(gpa, &seq, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.tick_overflow));
    try testing.expect(out.diags.hasErrors());

    var back = try reader.read(gpa, out.bytes);
    defer back.deinit();
    try testing.expect(!back.diags.hasErrors());
    try testing.expectEqual(@as(i64, vlq.MAX), back.sequence.tracks[0].events[1].at);
}

test "write ∘ read is the fixed point: the canonical fixture comes back byte for byte" {
    const gpa = testing.allocator;

    const fixture = try support.twoTrackFixture(gpa);
    defer gpa.free(fixture);

    var result = try reader.read(gpa, fixture);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.diags.items().len);

    var out = try write(gpa, &result.sequence, .{});
    defer out.deinit();
    try testing.expect(!out.diags.hasErrors());
    try testing.expectEqualSlices(u8, fixture, out.bytes);

    // And on the writer's own output, which is what rung 1 promises for
    // every file this writer ever produced.
    var again = try reader.read(gpa, out.bytes);
    defer again.deinit();
    var twice = try write(gpa, &again.sequence, .{});
    defer twice.deinit();
    try testing.expectEqualSlices(u8, out.bytes, twice.bytes);
}

test "write ∘ read is the fixed point: on what the writer made of a foreign file" {
    const gpa = testing.allocator;

    const foreign = try support.foreignFixture(gpa);
    defer gpa.free(foreign);

    var first = try reader.read(gpa, foreign);
    defer first.deinit();

    var canonical = try write(gpa, &first.sequence, .{});
    defer canonical.deinit();
    // The foreign layout is not canonical: running status was not used.
    try testing.expect(!std.mem.eql(u8, foreign, canonical.bytes));

    var second = try reader.read(gpa, canonical.bytes);
    defer second.deinit();
    var again = try write(gpa, &second.sequence, .{});
    defer again.deinit();
    try testing.expectEqualSlices(u8, canonical.bytes, again.bytes);
}

test "read ∘ write ∘ read equals read, event for event, on the foreign fixture" {
    const gpa = testing.allocator;

    const foreign = try support.foreignFixture(gpa);
    defer gpa.free(foreign);

    var first = try reader.read(gpa, foreign);
    defer first.deinit();

    var out = try write(gpa, &first.sequence, .{});
    defer out.deinit();

    var second = try reader.read(gpa, out.bytes);
    defer second.deinit();

    try expectSameEvents(&first.sequence, &second.sequence);

    // The same holds for the two-track fixture, whose events cover every
    // payload shape the reader builds.
    const fixture = try support.twoTrackFixture(gpa);
    defer gpa.free(fixture);
    var a = try reader.read(gpa, fixture);
    defer a.deinit();
    var written = try write(gpa, &a.sequence, .{ .running_status = false });
    defer written.deinit();
    var c = try reader.read(gpa, written.bytes);
    defer c.deinit();
    try expectSameEvents(&a.sequence, &c.sequence);
}

/// Event-for-event equality across two sequences whose pools are their
/// own: kinds, ticks, and payloads compared by MEANING.
///
/// `Payload` is an EXTERN union whose inactive bytes are indeterminate,
/// so this never compares one whole: `eqlOutsidePool` compares the member
/// the kind names, field by field, and `poolBytes` + `bytesOf` compare
/// what the runs point at — by content, never by offset, since two
/// sequences number their pools their own way.
fn expectSameEvents(a: *const Sequence, b: *const Sequence) !void {
    try testing.expectEqual(a.format, b.format);
    try testing.expectEqual(a.division.pulsesPerQuarter(), b.division.pulsesPerQuarter());
    try testing.expectEqual(a.tracks.len, b.tracks.len);
    for (a.tracks, b.tracks) |ta, tb| {
        try testing.expectEqual(ta.events.len, tb.events.len);
        for (ta.events, tb.events) |ea, eb| {
            try testing.expectEqual(ea.at, eb.at);
            try testing.expectEqual(ea.kind, eb.kind);
            try testing.expect(ea.payload.eqlOutsidePool(eb.payload, ea.kind));
            if (ea.payload.poolBytes(ea.kind)) |run| {
                try testing.expectEqualSlices(
                    u8,
                    a.bytesOf(run),
                    b.bytesOf(eb.payload.poolBytes(eb.kind).?),
                );
            }
        }
    }
}

test "write: never panics on a sequence read from arbitrary bytes" {
    const gpa = testing.allocator;

    const fixture = try support.twoTrackFixture(gpa);
    defer gpa.free(fixture);

    var prng = std.Random.DefaultPrng.init(0x77_72_69_74); // 'writ'
    const rand = prng.random();

    const mutable = try gpa.alloc(u8, fixture.len);
    defer gpa.free(mutable);

    var n: usize = 0;
    while (n < 500) : (n += 1) {
        @memcpy(mutable, fixture);
        for (0..rand.uintAtMost(usize, 8) + 1) |_| {
            mutable[rand.uintLessThan(usize, mutable.len)] = rand.int(u8);
        }
        const len = rand.uintAtMost(usize, mutable.len);

        var result = try reader.read(gpa, mutable[0..len]);
        defer result.deinit();

        const out_format0 = rand.boolean();
        var out = try write(gpa, &result.sequence, .{
            .running_status = rand.boolean(),
            .format0 = out_format0,
            .ppq = if (rand.boolean()) 480 else null,
            .round = rand.boolean(),
        });
        defer out.deinit();

        // Whatever went in, what comes out is STRUCTURALLY a file: the
        // reader has nothing to say about its chunks, its events or its
        // ends of track. (It may well have something to say about the
        // VALUES the sequence carried — a format byte the mutation set
        // to 7 is written back as a 7 — which is the header's business,
        // not the writer's.)
        var back = try reader.read(gpa, out.bytes);
        defer back.deinit();
        try testing.expectEqual(@as(usize, 0), back.diags.count(.smf_chunk_truncated));
        try testing.expectEqual(@as(usize, 0), back.diags.count(.smf_track_truncated));
        try testing.expectEqual(@as(usize, 0), back.diags.count(.smf_status_invalid));
        try testing.expectEqual(@as(usize, 0), back.diags.count(.vlq_too_long));
        try testing.expectEqual(@as(usize, 0), back.diags.count(.smf_ntrks_mismatch));
        try testing.expectEqual(@as(usize, 0), back.diags.count(.smf_running_status_across_meta));
        try testing.expectEqual(@as(usize, 0), back.diags.count(.end_of_track_missing));
        try testing.expectEqual(@as(usize, 0), back.diags.count(.end_of_track_early));
        try testing.expectEqual(
            if (out_format0) @as(usize, 1) else result.sequence.tracks.len,
            back.sequence.tracks.len,
        );
    }
}
