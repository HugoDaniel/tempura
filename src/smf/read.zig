//! The SMF reader: bytes in, a `Sequence` + a `SourceMap` + diagnostics
//! out.
//!
//! Total on ARBITRARY bytes. There is no input this function refuses and
//! none it panics on: a malformed chunk, a truncated track, a VLQ that
//! runs off the end, a status byte that cannot be one — each is a
//! `Diag` entry with the byte offset that caused it, and the walk keeps
//! whatever it parsed before that point (collection over abort, the SJON
//! discipline applied to bytes). `zig build fuzz` and the property test
//! at the bottom of this file hold that line.
//!
//! Two rules worth stating once:
//!
//!   * **Spans are offsets into the bytes the caller handed in.** A
//!     `RIFF`-wrapped file is unwrapped by moving the WINDOW, never by
//!     re-slicing, so an offset in a diagnostic or in the `SourceMap` is
//!     an offset a hex editor can be pointed at.
//!   * **A length-delimited payload is never inspected for status
//!     bits.** `FF 51 03 07 A1 20` is 120 BPM and its `A1` is data; the
//!     same goes for a sysex carrying `F0` or `FF` inside.
//!
//! What a chunk length says is what the walk believes: a chunk that
//! claims more bytes than the file holds is clamped to what is there and
//! reported, and the events inside a track are read against the TRACK's
//! end, never the file's.

const std = @import("std");
const Diag = @import("../Diag.zig");
const sequence = @import("Sequence.zig");
const vlq = @import("vlq.zig");

const testing = std.testing;
const support = @import("test_support.zig");
const Kind = sequence.Kind;
const Payload = sequence.Payload;

/// This module's error set: reading can only fail the way any allocation
/// fails. A defective file is diagnostics, never an error.
pub const Error = error{OutOfMemory};

/// One top-level chunk, as the file spelled it.
pub const Chunk = struct {
    tag: [4]u8,
    /// Where the eight-byte chunk header starts.
    offset: u32,
    /// The DECLARED body length, even when the file was too short to
    /// hold it (which is `smf_chunk_truncated`).
    len: u32,
    /// The body length that is actually there: `len` clamped to what the
    /// file holds. `bytes[offset + 8 ..][0..clamped_len]` is always a
    /// slice a consumer may take.
    clamped_len: u32,
};

/// Where one event came from, and whether it was read on running status.
pub const EventSite = struct {
    offset: u32,
    running_status: bool,
};

/// The per-track half of the map, parallel to `Sequence.tracks`.
pub const TrackMap = struct {
    /// Index into `SourceMap.chunks` of the `MTrk` this track came from.
    chunk: u32,
    events: []EventSite,
};

/// The SMPTE division the reader converted, and what it became.
pub const SmpteConversion = struct {
    fps: u8,
    tpf: u8,
    ppq: u15,
};

/// A byte range of the input.
pub const Region = struct {
    offset: u32,
    len: u32,
};

/// Everything the reader saw that the `Sequence` itself does not say:
/// `tempura inspect` prints it, the residue uses it, and a test asserts
/// on it instead of counting bytes by hand.
pub const SourceMap = struct {
    arena: std.heap.ArenaAllocator,
    /// Every top-level chunk in file order, `MThd` and `MTrk` included.
    chunks: []Chunk,
    /// Parallel to `Sequence.tracks`.
    tracks: []TrackMap,
    /// The chunks that were neither, parallel to `Sequence.foreign`.
    foreign: []Chunk,
    /// Set when the header's division was SMPTE.
    smpte: ?SmpteConversion,
    /// Set when the file was `RIFF`/`RMID`-wrapped: the region the SMF
    /// was found in.
    riff: ?Region,

    pub fn deinit(self: *SourceMap) void {
        self.arena.deinit();
    }
};

/// What `read` returns. Three owned pieces, three `deinit`s, one call.
pub const Result = struct {
    sequence: sequence.Sequence,
    source_map: SourceMap,
    diags: Diag.List,

    pub fn deinit(self: *Result) void {
        self.sequence.deinit();
        self.source_map.deinit();
        self.diags.deinit();
    }
};

/// The most bytes the reader will look at. Offsets are `u32` (a chunk
/// length is), so a larger input is read up to here and the rest is not
/// addressable — no SMF in the wild is anywhere near it.
const MAX_INPUT: usize = std.math.maxInt(u32);

/// Read a Standard MIDI File.
///
/// The returned `Result` owns everything in it and borrows nothing from
/// `bytes`: payloads are copied into the sequence's pool, so the caller
/// may free the input the moment this returns.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) Error!Result {
    var r: Walk = .{
        .bytes = bytes[0..@min(bytes.len, MAX_INPUT)],
        .builder = .init(gpa),
        .diags = .init(gpa),
        .arena = .init(gpa),
    };
    // What a file with no readable header reads as: one track's worth of
    // everything, on a division the file never stated. `Division.ppq(0)`
    // is OpenMPT's 96 the moment anybody asks for a grid, and the value
    // still says plainly that nothing was read.
    r.builder.format = 0;
    r.builder.division = .{ .ppq = 0 };
    errdefer {
        r.builder.deinit();
        r.diags.deinit();
        r.arena.deinit();
    }

    try r.run();

    const arena = r.arena.allocator();
    const map: SourceMap = .{
        .chunks = try r.chunks.toOwnedSlice(arena),
        .tracks = try r.tracks.toOwnedSlice(arena),
        .foreign = try r.foreign.toOwnedSlice(arena),
        .smpte = r.smpte,
        .riff = r.riff,
        .arena = r.arena,
    };
    const result: Result = .{
        .sequence = try r.builder.finish(),
        .source_map = map,
        .diags = r.diags,
    };
    result.sequence.invariants();
    postconditions(&result);
    return result;
}

/// What the READER establishes over and above `Sequence.invariants()`,
/// asserted once per `read` (plan 12, "The invariants"): ticks are
/// non-negative and never go backwards inside a track (the deltas are
/// summed, saturating); every channel event carries a channel in 0..15
/// and data bytes under 0x80 (the status nibble and the 0x7F mask, so a
/// pitch bend is 14 bits); and the map is parallel to the sequence — one
/// site per event, one entry per track and per foreign chunk, every
/// track pointing at a chunk on the map. Properties of the walk's own
/// arithmetic, never of the file: random bytes satisfy them.
fn postconditions(result: *const Result) void {
    const seq = &result.sequence;
    const map = &result.source_map;
    std.debug.assert(seq.tracks.len == map.tracks.len);
    std.debug.assert(seq.foreign.len == map.foreign.len);
    for (seq.tracks, map.tracks) |track, track_map| {
        std.debug.assert(track.events.len == track_map.events.len);
        std.debug.assert(track_map.chunk < map.chunks.len);
        var previous: i64 = 0;
        for (track.events) |e| {
            std.debug.assert(e.at >= 0);
            std.debug.assert(e.at >= previous);
            previous = e.at;
            const data = e.payload.channelData(e.kind) orelse continue;
            std.debug.assert(data.ch < 16);
            std.debug.assert(data.d1 < 0x80);
            std.debug.assert(data.d2 < 0x80);
            if (e.kind == .pitch_bend) std.debug.assert(e.payload.bend.value <= 0x3FFF);
        }
    }
}

/// One pass over one file. Everything mutable the walk needs, so the
/// functions below read as the specification reads.
const Walk = struct {
    bytes: []const u8,
    builder: sequence.Builder,
    diags: Diag.List,
    /// The `SourceMap`'s arena, and the only allocator its slices use.
    arena: std.heap.ArenaAllocator,
    chunks: std.ArrayList(Chunk) = .empty,
    tracks: std.ArrayList(TrackMap) = .empty,
    foreign: std.ArrayList(Chunk) = .empty,
    smpte: ?SmpteConversion = null,
    riff: ?Region = null,
    header_seen: bool = false,
    ntrks: u16 = 0,
    mtrk_count: u32 = 0,
    header_span: Diag.Span = .{ .start = 0, .end = 0 },

    fn diag(
        self: *Walk,
        code: Diag.Code,
        severity: Diag.Severity,
        start: usize,
        end: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        try self.diags.add(code, severity, .{
            .start = @intCast(start),
            .end = @intCast(end),
        }, fmt, args);
    }

    fn run(self: *Walk) Error!void {
        var start: usize = 0;
        var end: usize = self.bytes.len;
        if (try self.unwrapRiff()) |region| {
            start = region.offset;
            end = region.offset + region.len;
            self.riff = region;
        }

        var pos = start;
        // Bounded by the file: every chunk moves the cursor past its
        // eight-byte header.
        while (pos + 8 <= end) {
            const index: u32 = @intCast(self.chunks.items.len);
            const chunk = try self.chunkHeader(pos, end);
            const body = pos + 8;
            const chunk_end = body + chunk.clamped_len;

            if (std.mem.eql(u8, &chunk.tag, "MThd") and !self.header_seen) {
                try self.header(body, chunk_end);
            } else if (std.mem.eql(u8, &chunk.tag, "MTrk")) {
                self.mtrk_count += 1;
                try self.track(index, body, chunk_end);
            } else {
                try self.foreignChunk(index, chunk.tag, body, chunk_end);
            }

            pos = chunk_end;
        }

        // Trailing bytes after the last chunk are junk appended to a
        // whole file, not a file cut short, so they are an unknown chunk
        // that never had a header rather than a truncation — a caller
        // that meant to read the music still can.
        if (pos < end) try self.diag(
            .smf_unknown_chunk,
            .warning,
            pos,
            end,
            "{d} trailing bytes after the last chunk, too few for a chunk header",
            .{end - pos},
        );

        if (!self.header_seen) {
            try self.diag(
                .smf_bad_header,
                .err,
                start,
                @min(start + 8, end),
                "no MThd header chunk",
                .{},
            );
        } else if (self.ntrks != self.mtrk_count) {
            try self.diag(
                .smf_ntrks_mismatch,
                .warning,
                self.header_span.start,
                self.header_span.end,
                "the header declares {d} tracks and the file holds {d}",
                .{ self.ntrks, self.mtrk_count },
            );
        }
    }

    /// The chunk header at `pos` (the caller has checked eight bytes are
    /// there): its tag, its DECLARED length and the length that is
    /// actually inside `end` — a claim past the file is clamped and
    /// diagnosed. Recorded on the map before it is returned, so the
    /// caller's index into `chunks` is this chunk's.
    fn chunkHeader(self: *Walk, pos: usize, end: usize) Error!Chunk {
        const tag: [4]u8 = self.bytes[pos..][0..4].*;
        const declared = std.mem.readInt(u32, self.bytes[pos + 4 ..][0..4], .big);
        const body = pos + 8;
        const available = end - body;
        var len: usize = declared;
        if (len > available) {
            len = available;
            try self.diag(
                .smf_chunk_truncated,
                .err,
                pos,
                body,
                "chunk {s} claims {d} bytes and the file holds {d}",
                .{ &tag, declared, available },
            );
        }
        const chunk: Chunk = .{
            .tag = tag,
            .offset = @intCast(pos),
            .len = declared,
            .clamped_len = @intCast(len),
        };
        try self.chunks.append(self.arena.allocator(), chunk);
        return chunk;
    }

    /// `RIFF <size le> RMID data <size le> <the SMF>` — the `.rmi`
    /// wrapper (OpenMPT's `Load_mid.cpp:587-613`). Returns the region the
    /// file proper lives in, or null when this is not one.
    fn unwrapRiff(self: *Walk) Error!?Region {
        const b = self.bytes;
        if (b.len < 12) return null;
        if (!std.mem.eql(u8, b[0..4], "RIFF")) return null;
        if (!std.mem.eql(u8, b[8..12], "RMID")) return null;

        const outer = std.mem.readInt(u32, b[4..8][0..4], .little);
        const outer_end = @min(b.len, 8 + @as(usize, outer));

        var pos: usize = 12;
        while (pos + 8 <= outer_end) {
            const tag = b[pos..][0..4];
            const len = std.mem.readInt(u32, b[pos + 4 ..][0..4], .little);
            const body = pos + 8;
            const clamped = @min(@as(usize, len), outer_end - body);
            if (std.mem.eql(u8, tag, "data")) {
                try self.diag(
                    .smf_riff_unwrapped,
                    .info,
                    0,
                    12,
                    "RIFF/RMID wrapper: the file starts at {d}",
                    .{body},
                );
                return .{ .offset = @intCast(body), .len = @intCast(clamped) };
            }
            // RIFF pads odd-sized chunks to an even boundary.
            pos = body + clamped + (clamped & 1);
        }
        return null;
    }

    fn header(self: *Walk, body: usize, end: usize) Error!void {
        self.header_seen = true;
        self.header_span = .{ .start = @intCast(body), .end = @intCast(@min(body + 6, end)) };
        if (end - body < 6) {
            try self.diag(
                .smf_bad_header,
                .err,
                body,
                end,
                "MThd holds {d} bytes, six are the minimum",
                .{end - body},
            );
            return;
        }

        // A u16 on the wire and a u8 on the value: checked as READ, then
        // saturated, so 256 is neither a wrap to format 0 nor unnamed.
        const format = std.mem.readInt(u16, self.bytes[body..][0..2], .big);
        self.builder.format = std.math.cast(u8, format) orelse std.math.maxInt(u8);
        self.ntrks = std.mem.readInt(u16, self.bytes[body + 2 ..][0..2], .big);

        const raw = std.mem.readInt(u16, self.bytes[body + 4 ..][0..2], .big);
        if (raw & 0x8000 != 0) {
            // Bits 8..14 are a NEGATIVE frame rate; bits 0..7 the ticks
            // per frame. OpenMPT's `frames · subframes / 2` is what the
            // grid becomes (`Load_mid.cpp:661-669`), and the file's
            // tempo events stop conducting (plan 03).
            const signed: i8 = @bitCast(@as(u8, @truncate(raw >> 8)));
            const fps: u8 = if (signed < 0) @intCast(-@as(i16, signed)) else @intCast(signed);
            const tpf: u8 = @truncate(raw);
            const division: sequence.Division = .{ .smpte = .{ .fps = fps, .tpf = tpf } };
            self.builder.division = division;
            self.smpte = .{ .fps = fps, .tpf = tpf, .ppq = division.pulsesPerQuarter() };
        } else {
            self.builder.division = .{ .ppq = @intCast(raw) };
            if (raw == 0) try self.diag(
                .smf_bad_header,
                .warning,
                body + 4,
                body + 6,
                "a zero division; reading the file on 96 pulses per quarter",
                .{},
            );
        }

        if (format > 2) try self.diag(
            .smf_bad_header,
            .warning,
            body,
            body + 2,
            "format {d} is none of 0, 1 or 2",
            .{format},
        );
    }

    fn foreignChunk(self: *Walk, index: u32, tag: [4]u8, body: usize, end: usize) Error!void {
        const kept = try self.builder.addBytes(self.bytes[body..end]);
        try self.builder.addForeign(tag, kept);
        try self.foreign.append(self.arena.allocator(), self.chunks.items[index]);
        try self.diag(
            .smf_unknown_chunk,
            .info,
            body - 8,
            end,
            "chunk {s} is neither the header nor a track; skipped by length and kept",
            .{&tag},
        );
    }

    /// Running status, as the walk carries it from event to event: the
    /// last CHANNEL status byte, and whether a meta or a sysex has come
    /// since. RP-001 forbids reusing it across one; the reader tolerates
    /// that the way OpenMPT does and says so.
    const Running = struct { last: u8 = 0, cancelled: bool = false };

    /// The status an event is read under, and whether the file implied
    /// it rather than spelling it.
    const Status = struct { byte: u8, running: bool };

    /// One `MTrk` body: `<delta event>*`, ending at `FF 2F 00`.
    ///
    /// The parent keeps the cursor, the running tick and the three
    /// verdicts (an end of track seen, the walk aborted); each leaf
    /// below reads one thing and answers null when the bytes gave out,
    /// having said so.
    fn track(self: *Walk, chunk_index: u32, body: usize, end: usize) Error!void {
        const ti = try self.builder.addTrack();
        var sites: std.ArrayList(EventSite) = .empty;

        var pos = body;
        var at: i64 = 0;
        var running: Running = .{};
        var saw_end = false;
        var aborted = false;

        // Bounded by the track's bytes: every turn consumes at least one.
        while (pos < end) {
            const delta = try self.readDelta(&pos, end) orelse {
                aborted = true;
                break;
            };
            at +|= delta;

            const at_offset = pos;
            const status = try self.resolveStatus(&pos, &running) orelse {
                aborted = true;
                break;
            };

            if (isSystemMessage(status.byte)) {
                if (!try self.skipSystemMessage(status.byte, at_offset, &pos, end)) {
                    aborted = true;
                    break;
                }
                continue;
            }

            // RP-001: a meta or a sysex cancels running status.
            if (status.byte >= 0xF0) running.cancelled = true;
            const event = try self.parseEvent(status.byte, &pos, end) orelse {
                aborted = true;
                break;
            };

            try self.builder.addEvent(ti, at, event.kind, event.payload);
            try sites.append(self.arena.allocator(), .{
                .offset = @intCast(at_offset),
                .running_status = status.running,
            });
            try self.tempoDiagnostics(event, at_offset, pos);

            if (event.kind == .end_of_track) {
                saw_end = true;
                try self.endOfTrack(at_offset, pos, end);
                break;
            }
        }

        if (!saw_end and !aborted) try self.diag(
            .end_of_track_missing,
            .warning,
            end,
            end,
            "the track ends without FF 2F 00",
            .{},
        );

        try self.tracks.append(self.arena.allocator(), .{
            .chunk = chunk_index,
            .events = try sites.toOwnedSlice(self.arena.allocator()),
        });
    }

    /// The delta time at `pos`, or null (diagnosed) when the bytes are
    /// not one or nothing follows it. On success the cursor sits on the
    /// event's first byte, which is inside the track.
    fn readDelta(self: *Walk, pos: *usize, end: usize) Error!?u32 {
        const delta: u32 = switch (vlq.read(self.bytes[0..end], pos)) {
            .ok => |d| d,
            .err => |code| {
                const span_end = @min(pos.* + 1, end);
                try self.diag(code, .err, pos.*, span_end, "a delta time that is not one", .{});
                return null;
            },
        };
        if (pos.* >= end) {
            const msg = "the track ends after a delta time";
            try self.diag(.smf_track_truncated, .err, pos.*, end, msg, .{});
            return null;
        }
        return delta;
    }

    /// The status the event at `pos` is read under: the byte there when
    /// it is one (a channel status becomes the running one), or the
    /// running status when a data byte sits there instead. Null
    /// (diagnosed) when a data byte is due and nothing is running —
    /// guessing would invent music.
    fn resolveStatus(self: *Walk, pos: *usize, running: *Running) Error!?Status {
        const byte = self.bytes[pos.*];
        if (byte >= 0x80) {
            pos.* += 1;
            if (byte < 0xF0) running.* = .{ .last = byte, .cancelled = false };
            return .{ .byte = byte, .running = false };
        }
        if (running.last == 0) {
            try self.diag(
                .smf_status_invalid,
                .err,
                pos.*,
                pos.* + 1,
                "a data byte {x:0>2} where a status byte was due and no running status " ++
                    "is in effect",
                .{byte},
            );
            return null;
        }
        if (running.cancelled) try self.diag(
            .smf_running_status_across_meta,
            .warning,
            pos.*,
            pos.* + 1,
            "running status reused across a meta or sysex event",
            .{},
        );
        return .{ .byte = running.last, .running = true };
    }

    /// A system common or real-time byte has no place in a file (RP-001
    /// gives them none, and they do not update running status) but
    /// plenty of files carry one anyway, dumped from a live stream.
    /// Skipped with its data bytes so the track goes on — the reader
    /// keeps what it parsed; false (diagnosed) when the data bytes run
    /// past the track.
    fn skipSystemMessage(
        self: *Walk,
        status: u8,
        at_offset: usize,
        pos: *usize,
        end: usize,
    ) Error!bool {
        const data = systemDataBytes(status);
        try self.diag(
            .smf_status_invalid,
            .warning,
            at_offset,
            at_offset + 1,
            "status {x:0>2} is a system message a file has no room for; skipped",
            .{status},
        );
        if (pos.* + data > end) {
            try self.diag(
                .smf_track_truncated,
                .err,
                pos.*,
                end,
                "a system message needs {d} data bytes and the track holds {d}",
                .{ data, end - pos.* },
            );
            return false;
        }
        pos.* += data;
        return true;
    }

    /// The event `status` starts at `pos`: a channel message, a sysex or
    /// an escape, or a meta event. Null (diagnosed) when the bytes ran
    /// out inside it.
    fn parseEvent(self: *Walk, status: u8, pos: *usize, end: usize) Error!?Parsed {
        if (status < 0xF0) return self.channelEvent(status, pos, end);
        return switch (status) {
            0xF0, 0xF7 => self.bytesEvent(status, pos, end),
            else => self.metaEvent(pos, end),
        };
    }

    /// The end of track ends the track: what follows it in the chunk is
    /// not the track's, and the walk says so.
    fn endOfTrack(self: *Walk, at_offset: usize, pos: usize, end: usize) Error!void {
        if (pos < end) try self.diag(
            .end_of_track_early,
            .warning,
            at_offset,
            pos,
            "end of track with {d} bytes of the chunk left",
            .{end - pos},
        );
    }

    /// What the walk says about a `set_tempo` it kept: a zero is refused
    /// (and still kept), and one in a SMPTE file is kept and not believed
    /// (plan 03).
    fn tempoDiagnostics(self: *Walk, event: Parsed, at_offset: usize, pos: usize) Error!void {
        if (event.kind != .set_tempo) return;
        if (event.payload.tempo == 0) try self.diag(
            .smf_set_tempo_zero,
            .err,
            at_offset,
            pos,
            "a set-tempo of zero microseconds per quarter note",
            .{},
        );
        if (self.smpte != null) try self.diag(
            .smpte_tempo_ignored,
            .info,
            at_offset,
            pos,
            "a SMPTE file's tempo event is kept and not believed",
            .{},
        );
    }

    /// An event the walk built, or nothing when the bytes ran out.
    const Parsed = struct { kind: Kind, payload: Payload };

    /// Whether a status byte is a system common or real-time message —
    /// everything from `F1` up but the escape (`F7`) and the meta prefix
    /// (`FF`), which RP-001 does give a file.
    fn isSystemMessage(status: u8) bool {
        return status >= 0xF1 and status != 0xF7 and status != 0xFF;
    }

    /// How many data bytes follow a system common or real-time status:
    /// one for MIDI time code (`F1`) and song select (`F3`), two for song
    /// position (`F2`), none for tune request, the undefined ones and
    /// every real-time byte (`F8`..`FE`).
    fn systemDataBytes(status: u8) usize {
        return switch (status) {
            0xF1, 0xF3 => 1,
            0xF2 => 2,
            else => 0,
        };
    }

    fn channelEvent(self: *Walk, status: u8, pos: *usize, end: usize) Error!?Parsed {
        const kind = Kind.fromStatus(status).?;
        const ch: u8 = status & 0x0F;
        const n = kind.dataBytes();
        if (pos.* + n > end) {
            try self.diag(
                .smf_track_truncated,
                .err,
                pos.*,
                end,
                "a {s} needs {d} data bytes and the track holds {d}",
                .{ @tagName(kind), n, end - pos.* },
            );
            return null;
        }
        // A data byte is seven bits by definition; the mask is what makes
        // "every payload field is in range" an invariant a consumer can
        // rely on, whatever the file said.
        const d1: u8 = self.bytes[pos.*] & 0x7F;
        const d2: u8 = if (n == 2) self.bytes[pos.* + 1] & 0x7F else 0;
        pos.* += n;

        return .{
            .kind = kind,
            .payload = switch (kind) {
                .note_off, .note_on => .{ .note = .{ .ch = ch, .key = d1, .vel = d2 } },
                .poly_pressure => .{ .poly = .{ .ch = ch, .key = d1, .val = d2 } },
                .control_change => .{ .control = .{ .ch = ch, .num = d1, .val = d2 } },
                .program_change => .{ .program = .{ .ch = ch, .num = d1 } },
                .channel_pressure => .{ .pressure = .{ .ch = ch, .val = d1 } },
                // 14 bits, LSB first, centre 8192.
                else => .{ .bend = .{ .ch = ch, .value = @as(u16, d1) | (@as(u16, d2) << 7) } },
            },
        };
    }

    /// `F0` / `F7`: a VLQ length and that many bytes, stored verbatim —
    /// a trailing `F7` included, so a split message survives whole.
    fn bytesEvent(self: *Walk, status: u8, pos: *usize, end: usize) Error!?Parsed {
        const payload = try self.payloadBytes(pos, end) orelse return null;
        return .{
            .kind = if (status == 0xF0) .sysex else .escape,
            .payload = .{ .bytes = payload },
        };
    }

    /// The `<len VLQ> <bytes>` tail both sysex and meta events carry,
    /// copied into the pool.
    fn payloadBytes(self: *Walk, pos: *usize, end: usize) Error!?sequence.Bytes {
        const len: usize = switch (vlq.read(self.bytes[0..end], pos)) {
            .ok => |n| n,
            .err => |code| {
                try self.diag(
                    code,
                    .err,
                    pos.*,
                    @min(pos.* + 1, end),
                    "a payload length that is not one",
                    .{},
                );
                return null;
            },
        };
        if (pos.* + len > end) {
            try self.diag(
                .smf_track_truncated,
                .err,
                pos.*,
                end,
                "a payload of {d} bytes with {d} left in the track",
                .{ len, end - pos.* },
            );
            return null;
        }
        const kept = try self.builder.addBytes(self.bytes[pos.*..][0..len]);
        pos.* += len;
        return kept;
    }

    /// `FF <type> <len VLQ> <bytes>`.
    ///
    /// A known type whose length disagrees with RP-001 is kept as
    /// `meta_unknown` rather than forced into a shape it does not have:
    /// the bytes round-trip, and no consumer reads a field the file never
    /// wrote.
    fn metaEvent(self: *Walk, pos: *usize, end: usize) Error!?Parsed {
        if (pos.* >= end) {
            try self.diag(
                .smf_track_truncated,
                .err,
                pos.*,
                end,
                "a meta event with no type byte",
                .{},
            );
            return null;
        }
        const meta_type = self.bytes[pos.*];
        pos.* += 1;

        const payload = try self.payloadBytes(pos, end) orelse return null;
        const raw = self.builder.bytesOf(payload);
        return typedMeta(meta_type, raw, payload) orelse .{
            .kind = .meta_unknown,
            .payload = .{ .meta = .{ .bytes = payload, .meta_type = meta_type } },
        };
    }
};

/// The typed event a meta `meta_type` with payload `raw` (stored at
/// `payload` in the pool) is, or null when RP-001 has no row for it or
/// its length is not the one RP-001 gives — the caller keeps those as
/// `meta_unknown`. `FF 7F` is `Sequence.classifySequencerSpecific`'s:
/// tempura's envelope, midivia's hint or somebody else's, the same way
/// for the document bridge's reader. Pure over the bytes.
fn typedMeta(meta_type: u8, raw: []const u8, payload: sequence.Bytes) ?Walk.Parsed {
    return switch (meta_type) {
        0x00 => if (raw.len == 2) .{
            .kind = .sequence_number,
            .payload = .{ .number = std.mem.readInt(u16, raw[0..2], .big) },
        } else null,
        0x01 => .{ .kind = .text_event, .payload = .{ .bytes = payload } },
        0x02 => .{ .kind = .copyright_notice, .payload = .{ .bytes = payload } },
        0x03 => .{ .kind = .sequence_name, .payload = .{ .bytes = payload } },
        0x04 => .{ .kind = .instrument_name, .payload = .{ .bytes = payload } },
        0x05 => .{ .kind = .lyric, .payload = .{ .bytes = payload } },
        0x06 => .{ .kind = .marker, .payload = .{ .bytes = payload } },
        0x07 => .{ .kind = .cue_point, .payload = .{ .bytes = payload } },
        0x08 => .{ .kind = .program_name, .payload = .{ .bytes = payload } },
        0x09 => .{ .kind = .device_name, .payload = .{ .bytes = payload } },
        0x20 => if (raw.len == 1) .{
            .kind = .midi_channel_prefix,
            .payload = .{ .byte = raw[0] },
        } else null,
        0x21 => if (raw.len == 1) .{ .kind = .midi_port, .payload = .{ .byte = raw[0] } } else null,
        0x2F => if (raw.len == 0) .{ .kind = .end_of_track, .payload = .empty } else null,
        0x51 => if (raw.len == 3) .{
            .kind = .set_tempo,
            .payload = .{ .tempo = (@as(u32, raw[0]) << 16) | (@as(u32, raw[1]) << 8) | raw[2] },
        } else null,
        0x54 => if (raw.len == 5) .{ .kind = .smpte_offset, .payload = .{ .smpte = .{
            .hr = raw[0],
            .mn = raw[1],
            .se = raw[2],
            .fr = raw[3],
            .ff = raw[4],
        } } } else null,
        0x58 => if (raw.len == 4) .{ .kind = .time_signature, .payload = .{ .time_sig = .{
            .nn = raw[0],
            .dd = raw[1],
            .cc = raw[2],
            .bb = raw[3],
        } } } else null,
        0x59 => if (raw.len == 2) .{ .kind = .key_signature, .payload = .{ .key_sig = .{
            .sf = @bitCast(raw[0]),
            .mi = raw[1],
        } } } else null,
        0x7F => blk: {
            const c = sequence.classifySequencerSpecific(raw, payload);
            break :blk .{ .kind = c.kind, .payload = c.payload };
        },
        else => null,
    };
}

test "read: the hand-built two-track fixture parses to the expected Sequence" {
    const gpa = testing.allocator;
    const bytes = try support.twoTrackFixture(gpa);
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    const seq = &result.sequence;
    try testing.expectEqual(@as(usize, 0), result.diags.items().len);
    try testing.expectEqual(@as(u8, 1), seq.format);
    try testing.expectEqual(sequence.Division{ .ppq = 96 }, seq.division);
    try testing.expectEqual(@as(usize, 2), seq.tracks.len);
    try testing.expectEqual(@as(usize, 0), seq.foreign.len);

    const t0 = seq.tracks[0].events;
    try testing.expectEqual(@as(usize, 12), t0.len);

    try testing.expectEqual(Kind.sequence_number, t0[0].kind);
    try testing.expectEqual(@as(u16, 1), t0[0].payload.number);
    try testing.expectEqual(@as(i64, 0), t0[0].at);

    try testing.expectEqual(Kind.sequence_name, t0[1].kind);
    try testing.expectEqualStrings("Tempura", seq.bytesOf(t0[1].payload.bytes));

    try testing.expectEqual(Kind.time_signature, t0[2].kind);
    try testing.expectEqual(
        sequence.TimeSig{ .nn = 4, .dd = 2, .cc = 24, .bb = 8 },
        t0[2].payload.time_sig,
    );

    // `FF 51 03 07 A1 20` is 500 000 µs per quarter — 120 BPM — and its
    // `A1` has the high bit set, which is nothing at all inside a
    // length-delimited payload.
    try testing.expectEqual(Kind.set_tempo, t0[3].kind);
    try testing.expectEqual(@as(u32, 500_000), t0[3].payload.tempo);

    try testing.expectEqual(Kind.key_signature, t0[4].kind);
    try testing.expectEqual(sequence.KeySig{ .sf = -1, .mi = 0 }, t0[4].payload.key_sig);

    try testing.expectEqual(Kind.midi_port, t0[5].kind);
    try testing.expectEqual(@as(u8, 0), t0[5].payload.byte);

    // tempura's own `7D 'tem'` envelope, parsed typed.
    try testing.expectEqual(Kind.tempura_residue, t0[6].kind);
    const residue = t0[6].payload.residue;
    try testing.expectEqual(@as(u8, 1), residue.ver);
    try testing.expectEqual(@as(u8, 1), residue.kind);
    try testing.expectEqual(@as(u8, 0), residue.seq);
    try testing.expectEqual(@as(u8, 1), residue.total);
    try testing.expectEqualStrings("hi", seq.bytesOf(residue.body));

    // midivia's `7D 'pau'` hint: typed as a kind, body kept as bytes.
    try testing.expectEqual(Kind.ease_hint, t0[7].kind);
    try testing.expectEqualSlices(u8, &support.ease_hint_payload, seq.bytesOf(t0[7].payload.bytes));

    // Somebody else's `7F` payload stays bytes.
    try testing.expectEqual(Kind.sequencer_specific, t0[8].kind);
    try testing.expectEqualSlices(u8, &support.yamaha_payload, seq.bytesOf(t0[8].payload.bytes));

    try testing.expectEqual(Kind.meta_unknown, t0[9].kind);
    try testing.expectEqual(@as(u8, 0x0A), t0[9].payload.meta.meta_type);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD }, seq.bytesOf(t0[9].payload.meta.bytes));

    try testing.expectEqual(Kind.marker, t0[10].kind);
    try testing.expectEqual(@as(i64, 192), t0[10].at);
    try testing.expectEqualStrings("verse", seq.bytesOf(t0[10].payload.bytes));

    try testing.expectEqual(Kind.end_of_track, t0[11].kind);
    try testing.expectEqual(@as(i64, 384), t0[11].at);

    const t1 = seq.tracks[1].events;
    try testing.expectEqual(@as(usize, 11), t1.len);

    try testing.expectEqual(Kind.note_on, t1[0].kind);
    try testing.expectEqual(sequence.Note{ .ch = 0, .key = 60, .vel = 100 }, t1[0].payload.note);
    // Running status: a data byte where a status byte was expected.
    try testing.expectEqual(Kind.note_on, t1[1].kind);
    try testing.expectEqual(sequence.Note{ .ch = 0, .key = 64, .vel = 100 }, t1[1].payload.note);
    try testing.expectEqual(@as(i64, 0), t1[1].at);

    try testing.expectEqual(Kind.note_off, t1[2].kind);
    try testing.expectEqual(@as(i64, 96), t1[2].at);
    try testing.expectEqual(sequence.Note{ .ch = 0, .key = 60, .vel = 64 }, t1[2].payload.note);
    try testing.expectEqual(Kind.note_off, t1[3].kind);
    try testing.expectEqual(sequence.Note{ .ch = 0, .key = 64, .vel = 64 }, t1[3].payload.note);

    // A sysex whose payload carries bytes ≥ 0x80, kept whole.
    try testing.expectEqual(Kind.sysex, t1[4].kind);
    try testing.expectEqualSlices(u8, &support.sysex_payload, seq.bytesOf(t1[4].payload.bytes));
    try testing.expectEqual(Kind.escape, t1[5].kind);
    try testing.expectEqualSlices(u8, &support.escape_payload, seq.bytesOf(t1[5].payload.bytes));

    try testing.expectEqual(Kind.control_change, t1[6].kind);
    try testing.expectEqual(
        sequence.NumVal{ .ch = 0, .num = 7, .val = 127 },
        t1[6].payload.control,
    );
    try testing.expectEqual(Kind.control_change, t1[7].kind);
    try testing.expectEqual(
        sequence.NumVal{ .ch = 0, .num = 10, .val = 64 },
        t1[7].payload.control,
    );

    try testing.expectEqual(Kind.program_change, t1[8].kind);
    try testing.expectEqual(sequence.ChNum{ .ch = 0, .num = 5 }, t1[8].payload.program);
    try testing.expectEqual(@as(i64, 192), t1[8].at);

    try testing.expectEqual(Kind.pitch_bend, t1[9].kind);
    try testing.expectEqual(sequence.Bend{ .ch = 0, .value = 8192 }, t1[9].payload.bend);

    try testing.expectEqual(Kind.end_of_track, t1[10].kind);
    try testing.expectEqual(@as(i64, 288), t1[10].at);
}

test "read: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails
    // with error.OutOfMemory and testing.allocator sees no leak; past
    // the last index it succeeds. Bounded by the number of allocations
    // the call makes, which the loop discovers.
    const gpa = testing.allocator;
    const bytes = try support.twoTrackFixture(gpa);
    defer gpa.free(bytes);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const result = read(failing.allocator(), bytes);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var value = try result;
            value.deinit();
            break;
        }
    }
    // An arena asks its backing allocator for chunks, not for every
    // slice, so the count is small — but a sweep of one index would
    // prove nothing, so it is at least two.
    try testing.expect(fail_index > 1);
}

test "read: the SourceMap carries the chunks, the event offsets and the running-status reuse" {
    const gpa = testing.allocator;
    const bytes = try support.twoTrackFixture(gpa);
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    const map = &result.source_map;
    try testing.expectEqual(@as(usize, 3), map.chunks.len);
    try testing.expectEqualSlices(u8, "MThd", &map.chunks[0].tag);
    try testing.expectEqual(@as(u32, 0), map.chunks[0].offset);
    try testing.expectEqual(@as(u32, 6), map.chunks[0].len);
    try testing.expectEqualSlices(u8, "MTrk", &map.chunks[1].tag);
    try testing.expectEqual(@as(u32, 14), map.chunks[1].offset);
    try testing.expectEqualSlices(u8, "MTrk", &map.chunks[2].tag);
    try testing.expectEqual(@as(?SmpteConversion, null), map.smpte);
    try testing.expectEqual(@as(?Region, null), map.riff);
    try testing.expectEqual(@as(usize, 0), map.foreign.len);

    try testing.expectEqual(@as(usize, 2), map.tracks.len);
    for (map.tracks, result.sequence.tracks) |tm, t| {
        try testing.expectEqual(t.events.len, tm.events.len);
        // Every event names a byte offset inside its own chunk, and the
        // offsets only go forward.
        const chunk = map.chunks[tm.chunk];
        var prev: u32 = 0;
        for (tm.events) |site| {
            try testing.expect(site.offset > prev);
            try testing.expect(site.offset >= chunk.offset + 8);
            try testing.expect(site.offset < chunk.offset + 8 + chunk.len);
            prev = site.offset;
        }
    }

    // The first event of track 1 sits one byte into the chunk body: the
    // delta `00`, then the status.
    try testing.expectEqual(map.chunks[2].offset + 8 + 1, map.tracks[1].events[0].offset);

    // Exactly three events of track 1 were read on running status.
    const reuse = map.tracks[1].events;
    for (reuse, 0..) |site, i| {
        const expected = i == 1 or i == 3 or i == 7;
        try testing.expectEqual(expected, site.running_status);
    }
    for (map.tracks[0].events) |site| try testing.expect(!site.running_status);
}

test "read: a SMPTE division converts OpenMPT's way and its tempo events are recorded as ignored" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20 });
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    // 25 frames per second, 40 ticks per frame: `E7 28`.
    const bytes = try support.buildFile(gpa, .{ .format = 0, .division = 0xE728 }, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(
        sequence.Division{ .smpte = .{ .fps = 25, .tpf = 40 } },
        result.sequence.division,
    );
    try testing.expectEqual(@as(u15, 500), result.sequence.division.pulsesPerQuarter());
    try testing.expectEqual(
        SmpteConversion{ .fps = 25, .tpf = 40, .ppq = 500 },
        result.source_map.smpte.?,
    );

    // The event is kept; the timing walk is told not to believe it.
    try testing.expectEqual(Kind.set_tempo, result.sequence.tracks[0].events[0].kind);
    try testing.expectEqual(@as(usize, 1), result.diags.count(.smpte_tempo_ignored));
    try testing.expect(!result.diags.hasErrors());
}

test "read: an unknown chunk is skipped by length, preserved and recorded" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    var w = support.ByteWriter.init(gpa);
    defer w.deinit();
    try w.chunk("MThd", &[_]u8{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x60 });
    // RP-001: a reader skips a chunk type it does not know, by length.
    // Its body carries `MTrk` bytes, which must not tempt the walk.
    try w.chunk("XFIH", &[_]u8{ 'M', 'T', 'r', 'k', 0xFF, 0x2F, 0x00 });
    try w.chunk("MTrk", t.buf.items);
    const bytes = try w.toOwnedSlice();
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.sequence.tracks.len);
    try testing.expectEqual(@as(usize, 1), result.sequence.foreign.len);
    try testing.expectEqualSlices(u8, "XFIH", &result.sequence.foreign[0].tag);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 'M', 'T', 'r', 'k', 0xFF, 0x2F, 0x00 },
        result.sequence.bytesOf(result.sequence.foreign[0].bytes),
    );
    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_unknown_chunk));
    try testing.expect(!result.diags.hasErrors());

    try testing.expectEqual(@as(usize, 3), result.source_map.chunks.len);
    try testing.expectEqual(@as(usize, 1), result.source_map.foreign.len);
    try testing.expectEqual(@as(u32, 14), result.source_map.foreign[0].offset);
}

test "read: a RIFF/RMID wrapper is unwrapped, recorded, and its spans stay file offsets" {
    const gpa = testing.allocator;

    const inner = try support.twoTrackFixture(gpa);
    defer gpa.free(inner);

    var w = support.ByteWriter.init(gpa);
    defer w.deinit();
    try w.raw("RIFF");
    // RIFF sizes are LITTLE-endian; the payload is `RMID` + `data` + the file.
    const data_len: u32 = @intCast(inner.len);
    const riff_len: u32 = 4 + 8 + data_len;
    try w.raw(&[_]u8{
        @truncate(riff_len),
        @truncate(riff_len >> 8),
        @truncate(riff_len >> 16),
        @truncate(riff_len >> 24),
    });
    try w.raw("RMID");
    try w.raw("data");
    try w.raw(&[_]u8{
        @truncate(data_len),
        @truncate(data_len >> 8),
        @truncate(data_len >> 16),
        @truncate(data_len >> 24),
    });
    try w.raw(inner);
    const bytes = try w.toOwnedSlice();
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.sequence.tracks.len);
    try testing.expectEqual(@as(usize, 12), result.sequence.tracks[0].events.len);
    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_riff_unwrapped));
    try testing.expect(!result.diags.hasErrors());

    // The unwrap is recorded, and every offset in the map is an offset
    // into the bytes the caller handed in — not into the unwrapped region.
    try testing.expectEqual(
        Region{ .offset = 20, .len = @intCast(inner.len) },
        result.source_map.riff.?,
    );
    try testing.expectEqual(@as(u32, 20), result.source_map.chunks[0].offset);
}

test "read: ntrks that disagrees with the MTrk count is a diagnostic and the walk goes on" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const bytes = try support.buildFile(
        gpa,
        .{ .format = 1, .ntrks = 4 },
        &.{ t.buf.items, t.buf.items },
    );
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    // Both tracks present are read (collection over abort), and the
    // header's span is what the diagnostic points at.
    try testing.expectEqual(@as(usize, 2), result.sequence.tracks.len);
    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_ntrks_mismatch));
    const d = result.diags.items()[0];
    try testing.expectEqual(Diag.Span{ .start = 8, .end = 14 }, d.span);
}

test "read: a format past a byte is diagnosed as read, and saturates rather than wrapping" {
    // `format` is a u16 on the wire and a u8 on the value. 256 truncated
    // to 0 would read as a valid format 0 and skip the warning; it is
    // named as the file spelled it, and kept as 255 — still no format.
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const bytes = try support.buildFile(gpa, .{ .format = 256 }, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_bad_header));
    try testing.expect(std.mem.indexOf(u8, result.diags.items()[0].message, "256") != null);
    try testing.expectEqual(@as(u8, 255), result.sequence.format);
}

test "read: a header longer than six bytes keeps its extra bytes out of the walk" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const bytes = try support.buildFile(
        gpa,
        .{ .format = 0, .division = 480, .header_extra = &[_]u8{ 0xDE, 0xAD } },
        &.{t.buf.items},
    );
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(sequence.Division{ .ppq = 480 }, result.sequence.division);
    try testing.expectEqual(@as(usize, 1), result.sequence.tracks.len);
    try testing.expect(!result.diags.hasErrors());
}

test "read: a track that stops mid-event keeps the prefix and says where it stopped" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x3C, 0x64 });
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x3E }); // one data byte short

    const bytes = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.sequence.tracks[0].events.len);
    try testing.expectEqual(Kind.note_on, result.sequence.tracks[0].events[0].kind);
    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_track_truncated));
    // The abort explains the end: no second diagnostic about the missing
    // FF 2F 00 on top of it.
    try testing.expectEqual(@as(usize, 0), result.diags.count(.end_of_track_missing));
    try testing.expect(result.diags.hasErrors());
}

test "read: a chunk that claims more bytes than the file holds is clamped and reported" {
    const gpa = testing.allocator;

    var w = support.ByteWriter.init(gpa);
    defer w.deinit();
    try w.chunk("MThd", &[_]u8{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x60 });
    try w.raw("MTrk");
    try w.u32be(999); // and then four bytes of track
    try w.raw(&[_]u8{ 0x00, 0xFF, 0x2F, 0x00 });
    const bytes = try w.toOwnedSlice();
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_chunk_truncated));
    // The map keeps both numbers: what the file CLAIMED, and what a
    // consumer may actually slice.
    try testing.expectEqual(@as(u32, 999), result.source_map.chunks[1].len);
    try testing.expectEqual(@as(u32, 4), result.source_map.chunks[1].clamped_len);
    for (result.source_map.chunks) |chunk| {
        try testing.expect(chunk.offset + 8 + chunk.clamped_len <= bytes.len);
        try testing.expect(chunk.clamped_len <= chunk.len);
    }
    // What is there still parses: the end of track is the whole track.
    try testing.expectEqual(@as(usize, 1), result.sequence.tracks[0].events.len);
    try testing.expectEqual(Kind.end_of_track, result.sequence.tracks[0].events[0].kind);
}

test "read: bytes trailing the last chunk are junk, not a file cut short" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const file = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(file);

    var w = support.ByteWriter.init(gpa);
    defer w.deinit();
    try w.raw(file);
    try w.raw(&[_]u8{ '\n', 0x00, 0x00 }); // three bytes some tool appended
    const bytes = try w.toOwnedSlice();
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_unknown_chunk));
    try testing.expectEqual(@as(usize, 0), result.diags.count(.smf_chunk_truncated));
    // The music is whole, so nothing here is an error.
    try testing.expect(!result.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), result.sequence.tracks.len);
    try testing.expectEqual(Diag.Span{
        .start = @intCast(file.len),
        .end = @intCast(bytes.len),
    }, result.diags.items()[0].span);
}

test "read: a five-byte delta time is vlq_too_long and stops the track there" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x3C, 0x64 });
    try t.raw(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x7F }); // a delta with five bytes
    try t.raw(&[_]u8{ 0x90, 0x3E, 0x64 });

    const bytes = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.sequence.tracks[0].events.len);
    try testing.expectEqual(@as(usize, 1), result.diags.count(.vlq_too_long));
    // The span is the fifth byte: `MThd` (14) + `MTrk` header (8) + the
    // first event (4) + four continuation bytes.
    try testing.expectEqual(Diag.Span{ .start = 30, .end = 31 }, result.diags.items()[0].span);
}

test "read: running status reused across a meta event is tolerated and warned about" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x3C, 0x64 });
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x01, 0x01, 'x' }); // RP-001 cancels running status here
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x3E, 0x64 }); // OpenMPT reads it anyway, and so do we
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const bytes = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    const events = result.sequence.tracks[0].events;
    try testing.expectEqual(@as(usize, 4), events.len);
    try testing.expectEqual(Kind.note_on, events[2].kind);
    try testing.expectEqual(@as(u8, 62), events[2].payload.note.key);
    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_running_status_across_meta));
    try testing.expect(!result.diags.hasErrors());
    try testing.expect(result.source_map.tracks[0].events[2].running_status);
}

test "read: a set-tempo of zero is refused, and the event is still kept" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x51, 0x03, 0x00, 0x00, 0x00 });
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const bytes = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_set_tempo_zero));
    try testing.expect(result.diags.hasErrors());
    try testing.expectEqual(Kind.set_tempo, result.sequence.tracks[0].events[0].kind);
    try testing.expectEqual(@as(u32, 0), result.sequence.tracks[0].events[0].payload.tempo);
}

test "read: a track with no end-of-track, and one with bytes after it" {
    const gpa = testing.allocator;

    var missing = support.ByteWriter.init(gpa);
    defer missing.deinit();
    try missing.vlq(0);
    try missing.raw(&[_]u8{ 0x90, 0x3C, 0x64 });

    var early = support.ByteWriter.init(gpa);
    defer early.deinit();
    try early.vlq(0);
    try early.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });
    try early.vlq(0);
    try early.raw(&[_]u8{ 0x90, 0x3C, 0x64 });
    try early.vlq(0);
    try early.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const bytes = try support.buildFile(
        gpa,
        .{ .format = 1 },
        &.{ missing.buf.items, early.buf.items },
    );
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.diags.count(.end_of_track_missing));
    try testing.expectEqual(@as(usize, 1), result.diags.count(.end_of_track_early));
    try testing.expect(!result.diags.hasErrors());

    try testing.expectEqual(@as(usize, 1), result.sequence.tracks[0].events.len);
    // The end of track ends the track: what follows it in the chunk is
    // not the track's.
    try testing.expectEqual(@as(usize, 1), result.sequence.tracks[1].events.len);
    try testing.expectEqual(Kind.end_of_track, result.sequence.tracks[1].events[0].kind);
}

test "read: a data byte with no running status aborts the track" {
    const gpa = testing.allocator;

    // Nothing to run with: the byte cannot be read as anything, and
    // guessing would invent music.
    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x3C, 0x64 });

    const bytes = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_status_invalid));
    try testing.expectEqual(Diag.Severity.err, result.diags.items()[0].severity);
    try testing.expect(result.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), result.sequence.tracks[0].events.len);
}

test "read: a system message is skipped with its data bytes and the track goes on" {
    const gpa = testing.allocator;

    // `F1` takes one data byte, `F2` two, `F8` none. RP-001 gives a file
    // no room for any of them, and files carry them anyway — dumped from
    // a live stream. None of them touches running status (plan 05).
    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x3C, 0x64 });
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xF1, 0x7F }); // MIDI time code quarter frame
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x3E, 0x64 }); // still running on 90
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xF2, 0x00, 0x40 }); // song position
    try t.vlq(96);
    try t.raw(&[_]u8{0xF8}); // a clock byte mid-track
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x40, 0x64 }); // and the music carries on
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const bytes = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.diags.count(.smf_status_invalid));
    try testing.expect(!result.diags.hasErrors());
    for (result.diags.items()) |d| {
        if (d.code == .smf_status_invalid) try testing.expectEqual(
            Diag.Severity.warning,
            d.severity,
        );
    }
    // A system byte does not cancel running status, so no warning about
    // reusing it either.
    try testing.expectEqual(@as(usize, 0), result.diags.count(.smf_running_status_across_meta));

    const events = result.sequence.tracks[0].events;
    try testing.expectEqual(@as(usize, 4), events.len);
    try testing.expectEqual(@as(u8, 60), events[0].payload.note.key);
    try testing.expectEqual(@as(u8, 62), events[1].payload.note.key);
    try testing.expectEqual(Kind.note_on, events[2].kind);
    try testing.expectEqual(@as(u8, 64), events[2].payload.note.key);
    try testing.expectEqual(@as(i64, 96), events[2].at);
    try testing.expectEqual(Kind.end_of_track, events[3].kind);
    try testing.expect(result.source_map.tracks[0].events[2].running_status);
}

test "read: a system message whose data bytes run past the track end stops there" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x3C, 0x64 });
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xF2, 0x00 }); // song position, one byte short

    const bytes = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_status_invalid));
    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_track_truncated));
    try testing.expectEqual(@as(usize, 1), result.sequence.tracks[0].events.len);
}

test "read: bytes that are no MIDI file at all are one diagnostic and an empty sequence" {
    const gpa = testing.allocator;

    var result = try read(gpa, "this is not a Standard MIDI File");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.sequence.tracks.len);
    try testing.expectEqual(@as(usize, 1), result.diags.count(.smf_bad_header));
    try testing.expect(result.diags.hasErrors());
    // No header was read, so the value claims nothing: format 0 and a
    // division of zero, which is 96 pulses the moment anybody asks.
    try testing.expectEqual(@as(u8, 0), result.sequence.format);
    try testing.expectEqual(sequence.Division{ .ppq = 0 }, result.sequence.division);
    try testing.expectEqual(@as(u15, 96), result.sequence.division.pulsesPerQuarter());

    var empty = try read(gpa, "");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 1), empty.diags.count(.smf_bad_header));
    try testing.expectEqual(@as(usize, 0), empty.sequence.tracks.len);
}

test "read: a note-on with velocity 0 stays a note_on, as the file wrote it" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x3C, 0x64 });
    try t.vlq(96);
    try t.raw(&[_]u8{ 0x90, 0x3C, 0x00 });
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const bytes = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    const events = result.sequence.tracks[0].events;
    try testing.expectEqual(Kind.note_on, events[1].kind);
    try testing.expectEqual(@as(u8, 0), events[1].payload.note.vel);
    try testing.expect(!result.diags.hasErrors());
}

test "read: a 7D 'tem' payload too short for the envelope stays sequencer_specific" {
    const gpa = testing.allocator;

    var t = support.ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x7F, 0x05, 0x7D, 0x74, 0x65, 0x6D, 0x01 }); // eight bytes short of one
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    const bytes = try support.buildFile(gpa, .{}, &.{t.buf.items});
    defer gpa.free(bytes);

    var result = try read(gpa, bytes);
    defer result.deinit();

    const events = result.sequence.tracks[0].events;
    try testing.expectEqual(Kind.sequencer_specific, events[0].kind);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x7D, 0x74, 0x65, 0x6D, 0x01 },
        result.sequence.bytesOf(events[0].payload.bytes),
    );
}

/// Everything that must hold about a `Result` for ANY input at all.
///
/// Deliberately says nothing about what parsed — random bytes trip every
/// diagnostic there is — and everything about the value's own shape: the
/// map is parallel to the sequence, no offset points outside what it
/// indexes, and ticks never go backwards inside a track.
fn expectWellFormed(result: *const Result, input_len: usize) !void {
    const seq = &result.sequence;
    const map = &result.source_map;

    try testing.expectEqual(seq.tracks.len, map.tracks.len);
    try testing.expectEqual(seq.foreign.len, map.foreign.len);

    for (seq.tracks, map.tracks) |track, track_map| {
        try testing.expectEqual(track.events.len, track_map.events.len);
        try testing.expect(track_map.chunk < map.chunks.len);

        var previous: i64 = 0;
        for (track.events, track_map.events) |event, site| {
            try testing.expect(event.at >= previous);
            previous = event.at;
            try testing.expect(site.offset < input_len);

            if (event.payload.poolBytes(event.kind)) |b| {
                try testing.expect(@as(usize, b.off) + b.len <= seq.pool.len);
            }
        }
    }

    for (seq.foreign) |chunk| {
        try testing.expect(@as(usize, chunk.bytes.off) + chunk.bytes.len <= seq.pool.len);
    }
    for (map.chunks) |chunk| try testing.expect(chunk.offset < input_len);
}

test "read: never panics — 2 000 pseudo-random inputs and every prefix of the fixture" {
    const gpa = testing.allocator;

    const fixture = try support.twoTrackFixture(gpa);
    defer gpa.free(fixture);

    // Every truncation of a real file: the walk meets a chunk header cut
    // in half, a delta with no event, a payload that claims more than is
    // left — one prefix per byte.
    for (0..fixture.len + 1) |n| {
        var result = try read(gpa, fixture[0..n]);
        defer result.deinit();
        try expectWellFormed(&result, @max(n, 1));
    }

    var prng = std.Random.DefaultPrng.init(0x74_65_6D_70); // 'temp'
    const rand = prng.random();
    var buf: [512]u8 = undefined;

    // A thousand strings of noise, and a thousand mutations of the
    // fixture — noise alone rarely gets past the header, and mutations
    // reach the deep paths where the events are.
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const len = rand.uintAtMost(usize, buf.len);
        rand.bytes(buf[0..len]);
        if (len >= 4 and rand.boolean()) @memcpy(buf[0..4], "MThd");
        var result = try read(gpa, buf[0..len]);
        defer result.deinit();
        try expectWellFormed(&result, @max(len, 1));
    }

    const mutable = try gpa.alloc(u8, fixture.len);
    defer gpa.free(mutable);
    n = 0;
    while (n < 1000) : (n += 1) {
        @memcpy(mutable, fixture);
        const edits = rand.uintAtMost(usize, 8) + 1;
        for (0..edits) |_| mutable[rand.uintLessThan(usize, mutable.len)] = rand.int(u8);
        const len = rand.uintAtMost(usize, mutable.len);
        var result = try read(gpa, mutable[0..len]);
        defer result.deinit();
        try expectWellFormed(&result, @max(len, 1));
    }
}
