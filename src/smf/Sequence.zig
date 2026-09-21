//! A Standard MIDI File as a value: typed events on absolute ticks, one
//! byte pool behind every payload, and the `Builder` that makes one.
//!
//! The shape is plan 05's: a `Sequence` holds the header fields, the
//! tracks in file order, the unknown chunks it preserved, and the arena
//! all of it lives in. Every event is a FIXED-SIZE value (`Event` is 24
//! bytes, pinned below) so a track is a flat slice a consumer can walk
//! without chasing pointers; the bytes a sysex, a text meta or a residue
//! body carries live in `pool` and the event holds `{ off, len }` into
//! it. Ticks are ABSOLUTE and in the file's own division — the reader
//! sums the deltas and the writer re-derives them, so nothing above this
//! layer ever writes a delta.
//!
//! Imports `std` and nothing else (it raises no diagnostic of its own —
//! the reader and the writer do).

const std = @import("std");

const testing = std.testing;

/// This module's error set: building a value can only fail the way any
/// allocation fails.
pub const Error = error{OutOfMemory};

/// The header's `division` field, as read.
///
/// The conversion to a pulses-per-quarter grid is
/// `pulsesPerQuarter()` — it cannot be spelled `ppq()` because the
/// variant already claims that name, and the variant is the one a
/// consumer pattern-matches on. The conversion has ONE seam beside it,
/// `tempoOnGrid()`: what a `set-tempo` says once its ticks are on that
/// grid. The two are a pair, and anything that emits a SMPTE sequence
/// on its converted grid — the canonical writer, the `midi/` bridge's
/// printer — uses both, or the wall clock the grid was chosen to keep
/// is lost.
pub const Division = union(enum) {
    /// Bit 15 clear: pulses per quarter note, 1..32767.
    ppq: u15,
    /// Bit 15 set: a negative frame rate (24, 25, 29 for 30 drop, 30) and
    /// ticks per frame. Wall-clock, not musical — the reader converts and
    /// says so in the `SourceMap`.
    smpte: struct { fps: u8, tpf: u8 },

    /// The tempo `tempoOnGrid` answers for every SMPTE `set-tempo`:
    /// 500 000 microseconds a quarter, 120 quarter notes per minute —
    /// the premise of the `fps · tpf / 2` approximation, and an
    /// integer, so the one SMPTE segment keeps plan 03's integer path.
    pub const smpte_tempo_us: u32 = 500_000;

    /// The grid this file's ticks are on.
    ///
    /// For SMPTE this is OpenMPT's approximation (`Load_mid.cpp:661-669`,
    /// `frames · subframes / 2`), exact only at 120 quarter notes per
    /// minute: `fps · tpf` ticks a second read as `fps · tpf / 2` a
    /// quarter is a second of two quarters. That premise is why the SMF
    /// conductor of a SMPTE file is one 120 QPM segment and its
    /// `set-tempo` events are ignored for timing (`smpte_tempo_ignored`,
    /// plan 03), and why `tempoOnGrid` rewrites them on the way out. A
    /// zero falls back to 96, as OpenMPT's loader does, so no caller
    /// ever divides by nothing.
    pub fn pulsesPerQuarter(self: Division) u15 {
        const raw: u32 = switch (self) {
            .ppq => |p| p,
            .smpte => |s| (@as(u32, s.fps) * @as(u32, s.tpf)) / 2,
        };
        if (raw == 0 or raw > std.math.maxInt(u15)) return 96;
        return @intCast(raw);
    }

    /// What a `set-tempo` of `us` microseconds a quarter says ONCE its
    /// ticks are on `pulsesPerQuarter()`'s grid.
    ///
    /// For `.ppq` that is `us` itself: the grid is the file's own. For
    /// `.smpte` it is `smpte_tempo_us`, whatever the event said, because
    /// 120 QPM is the tempo the approximation ASSUMED — a SMPTE tick is a
    /// fixed slice of the wall clock, and on a musical grid it stays one
    /// only while that grid is read at the tempo it was derived for. A
    /// `set-tempo` copied unchanged beside the converted division would
    /// CONDUCT: at 60 QPM every second of the file would become two,
    /// which is exactly what the reader's `smpte_tempo_ignored` promised
    /// never happens (plan 03; plan 05, "Chunks"). The reader keeps the
    /// event as read and the `Sequence` stays faithful; this is the rule
    /// for the two places that EMIT the event on the converted grid, the
    /// canonical writer and the bridge's printer.
    pub fn tempoOnGrid(self: Division, us: u32) u32 {
        return switch (self) {
            .ppq => us,
            .smpte => smpte_tempo_us,
        };
    }
};

/// Which member of `Payload` carries an event's data. One variant per
/// union member, so a `switch` over it is exhaustive by construction and
/// a new payload shape cannot be forgotten.
pub const Field = enum {
    /// `end_of_track`: nothing at all.
    none,
    note,
    poly,
    control,
    program,
    pressure,
    bend,
    /// A run in the pool: sysex, escape, every text meta, the
    /// sequencer-specific ones and the easing hint.
    bytes,
    /// A type byte and a run in the pool.
    meta,
    number,
    byte,
    tempo,
    smpte,
    time_sig,
    key_sig,
    /// The residue envelope: four bytes and a run in the pool.
    residue,
};

/// What an event IS — every row of plan 05's channel, system and meta
/// tables, plus the three tempura adds.
///
/// APPEND-ONLY: the ordinal crosses no wire today, but the bridge's head
/// names and the residue's records are derived from it, and a reorder
/// would silently rename events in every document. New rows go at the
/// END.
pub const Kind = enum(u8) {
    // Channel messages (plan 05, "Events").
    note_off,
    note_on,
    poly_pressure,
    control_change,
    program_change,
    channel_pressure,
    pitch_bend,

    // System exclusive and escape.
    sysex,
    escape,

    // Meta events, in RP-001's type order.
    sequence_number,
    text_event,
    copyright_notice,
    sequence_name,
    instrument_name,
    lyric,
    marker,
    cue_point,
    program_name,
    device_name,
    midi_channel_prefix,
    midi_port,
    end_of_track,
    set_tempo,
    smpte_offset,
    time_signature,
    key_signature,
    sequencer_specific,

    /// A meta type this reader has no row for, or a known type whose
    /// length disagreed with RP-001's: type byte and bytes, round-tripped
    /// verbatim.
    meta_unknown,

    /// midivia's easing hint, a `7F` payload tagged `7D 'pau'` (midi 03).
    /// The body stays bytes — naming pacer vocabulary is the bridge's
    /// job, not the reader's.
    ease_hint,

    /// tempura's own residue record, a `7F` payload tagged `7D 'tem'`
    /// (plan 04, "The SMF carrier"), parsed into `TempuraResidue`.
    tempura_residue,

    /// The status nibble a channel message is written with, or `null` for
    /// everything else. Note-off is `8n` and stays `8n`: a note off
    /// spelled `9n` with velocity 0 in the file was read as `note_on`
    /// and is written back that way (plan 05, the canonical writer).
    pub fn status(self: Kind) ?u8 {
        return switch (self) {
            .note_off => 0x80,
            .note_on => 0x90,
            .poly_pressure => 0xA0,
            .control_change => 0xB0,
            .program_change => 0xC0,
            .channel_pressure => 0xD0,
            .pitch_bend => 0xE0,
            else => null,
        };
    }

    /// The kind a channel status byte names, or `null` when the byte is
    /// not one (`F0`..`FF`, or a data byte). The inverse of `status()`,
    /// and the reader's one table.
    pub fn fromStatus(status_byte: u8) ?Kind {
        return switch (status_byte & 0xF0) {
            0x80 => .note_off,
            0x90 => .note_on,
            0xA0 => .poly_pressure,
            0xB0 => .control_change,
            0xC0 => .program_change,
            0xD0 => .channel_pressure,
            0xE0 => .pitch_bend,
            else => null,
        };
    }

    /// Whether the event carries a channel in its payload.
    pub fn isChannel(self: Kind) bool {
        return self.status() != null;
    }

    /// Which member of `Payload` this kind's events read — the table in
    /// `Payload`'s doc comment, as a value.
    ///
    /// The union is EXTERN and its inactive bytes are indeterminate, so
    /// nothing may compare, hash or copy a `Payload` whole: everything
    /// that walks events generically (the equality of two sequences, the
    /// residue's hashes, a bridge's printer) goes through here first.
    pub fn payloadField(self: Kind) Field {
        return switch (self) {
            .note_off, .note_on => .note,
            .poly_pressure => .poly,
            .control_change => .control,
            .program_change => .program,
            .channel_pressure => .pressure,
            .pitch_bend => .bend,
            .sysex,
            .escape,
            .text_event,
            .copyright_notice,
            .sequence_name,
            .instrument_name,
            .lyric,
            .marker,
            .cue_point,
            .program_name,
            .device_name,
            .sequencer_specific,
            .ease_hint,
            => .bytes,
            .meta_unknown => .meta,
            .sequence_number => .number,
            .midi_channel_prefix, .midi_port => .byte,
            .set_tempo => .tempo,
            .smpte_offset => .smpte,
            .time_signature => .time_sig,
            .key_signature => .key_sig,
            .tempura_residue => .residue,
            .end_of_track => .none,
        };
    }

    /// The `FF <type>` byte, or `null` when the kind is not a meta event
    /// or carries its own type byte (`meta_unknown`).
    pub fn metaType(self: Kind) ?u8 {
        return switch (self) {
            .sequence_number => 0x00,
            .text_event => 0x01,
            .copyright_notice => 0x02,
            .sequence_name => 0x03,
            .instrument_name => 0x04,
            .lyric => 0x05,
            .marker => 0x06,
            .cue_point => 0x07,
            .program_name => 0x08,
            .device_name => 0x09,
            .midi_channel_prefix => 0x20,
            .midi_port => 0x21,
            .end_of_track => 0x2F,
            .set_tempo => 0x51,
            .smpte_offset => 0x54,
            .time_signature => 0x58,
            .key_signature => 0x59,
            .sequencer_specific, .ease_hint, .tempura_residue => 0x7F,
            else => null,
        };
    }

    /// How many data bytes follow the status byte of a channel message.
    pub fn dataBytes(self: Kind) u8 {
        return switch (self) {
            .program_change, .channel_pressure => 1,
            else => 2,
        };
    }
};

/// A run of bytes in the `Sequence`'s pool: the one indirection an event
/// has. Kept extern so the `Payload` union has a C layout and its size is
/// the same in every optimisation mode.
pub const Bytes = extern struct { off: u32, len: u32 };

/// `note_off`, `note_on`.
pub const Note = extern struct { ch: u8, key: u8, vel: u8 };

/// `poly_pressure`.
pub const KeyVal = extern struct { ch: u8, key: u8, val: u8 };

/// `control_change` — controllers 0..119 and the channel-mode messages
/// 120..127 alike.
pub const NumVal = extern struct { ch: u8, num: u8, val: u8 };

/// `program_change`.
pub const ChNum = extern struct { ch: u8, num: u8 };

/// `channel_pressure`.
pub const ChVal = extern struct { ch: u8, val: u8 };

/// `pitch_bend`, 14-bit, centre 8192 — LSB-first on the wire, one number
/// here.
pub const Bend = extern struct { ch: u8, value: u16 };

/// `meta_unknown`: the type byte RP-001 has no row for (or a known row
/// whose length was wrong) and the payload verbatim.
pub const MetaUnknown = extern struct { bytes: Bytes, meta_type: u8 };

/// `time_signature`: numerator, denominator as a power of two, MIDI
/// clocks per metronome click, 32nd notes per quarter.
pub const TimeSig = extern struct { nn: u8, dd: u8, cc: u8, bb: u8 };

/// `key_signature`: sharps (positive) or flats (negative), major or minor.
pub const KeySig = extern struct { sf: i8, mi: u8 };

/// `smpte_offset`, stored and unused.
pub const SmpteOffset = extern struct { hr: u8, mn: u8, se: u8, fr: u8, ff: u8 };

/// A parsed `7D 74 65 6D` payload — tempura's residue envelope (plan 04).
///
/// `ver` is the envelope version (1 today), `kind` is `01` essence, `02`
/// lane record, `03` conductor record, `04` an adopted easing hint, and
/// `seq`/`total` number the parts of a body split across events. `body`
/// is everything after those eight bytes; the writer rebuilds the whole
/// payload from these fields, so the round trip is byte-exact.
pub const TempuraResidue = extern struct {
    ver: u8,
    kind: u8,
    seq: u8,
    total: u8,
    body: Bytes,
};

/// Everything an event can carry, in 12 bytes.
///
/// An EXTERN union on purpose: `Event.kind` is the tag, and an extern
/// union has no hidden one, so `@sizeOf(Event)` is the same in Debug and
/// in ReleaseSmall and the comptime pins below mean something. Read the
/// field the kind names:
///
/// | kind | field |
/// |---|---|
/// | `note_off`, `note_on` | `note` |
/// | `poly_pressure` | `poly` |
/// | `control_change` | `control` |
/// | `program_change` | `program` |
/// | `channel_pressure` | `pressure` |
/// | `pitch_bend` | `bend` |
/// | `sysex`, `escape`, every text meta, `sequencer_specific`, `ease_hint` | `bytes` |
/// | `meta_unknown` | `meta` |
/// | `sequence_number` | `number` |
/// | `midi_channel_prefix`, `midi_port` | `byte` |
/// | `set_tempo` | `tempo` |
/// | `smpte_offset` | `smpte` |
/// | `time_signature` | `time_sig` |
/// | `key_signature` | `key_sig` |
/// | `tempura_residue` | `residue` |
/// | `end_of_track` | nothing (`.empty`) |
pub const Payload = extern union {
    none: u32,
    note: Note,
    poly: KeyVal,
    control: NumVal,
    program: ChNum,
    pressure: ChVal,
    bend: Bend,
    bytes: Bytes,
    meta: MetaUnknown,
    number: u16,
    byte: u8,
    tempo: u32,
    smpte: SmpteOffset,
    time_sig: TimeSig,
    key_sig: KeySig,
    residue: TempuraResidue,

    /// The payload of an event that carries none.
    pub const empty: Payload = .{ .none = 0 };

    /// The run into the pool this payload points at, or `null` when the
    /// kind keeps everything inline. The one place the "which kinds
    /// carry bytes" table is written down.
    pub fn poolBytes(self: Payload, kind: Kind) ?Bytes {
        return switch (kind.payloadField()) {
            .bytes => self.bytes,
            .meta => self.meta.bytes,
            .residue => self.residue.body,
            else => null,
        };
    }

    /// The channel and the data bytes of a channel message, in wire
    /// order — `d2` is 0 for the one-byte kinds — or null when the kind
    /// is not one. The writer spells the status and data bytes from it
    /// and the reader's postconditions check them; the bytes come back
    /// AS HELD (a builder may have seated a 200), which is why the
    /// writer still masks.
    pub fn channelData(self: Payload, kind: Kind) ?ChannelData {
        return switch (kind.payloadField()) {
            .note => .{ .ch = self.note.ch, .d1 = self.note.key, .d2 = self.note.vel },
            .poly => .{ .ch = self.poly.ch, .d1 = self.poly.key, .d2 = self.poly.val },
            .control => .{ .ch = self.control.ch, .d1 = self.control.num, .d2 = self.control.val },
            .program => .{ .ch = self.program.ch, .d1 = self.program.num, .d2 = 0 },
            .pressure => .{ .ch = self.pressure.ch, .d1 = self.pressure.val, .d2 = 0 },
            // 14 bits, LSB first, centre 8192.
            .bend => .{
                .ch = self.bend.ch,
                .d1 = @truncate(self.bend.value & 0x7F),
                .d2 = @truncate((self.bend.value >> 7) & 0x7F),
            },
            else => null,
        };
    }

    /// Whether two payloads of the same kind agree on everything they
    /// hold THEMSELVES.
    ///
    /// The pool runs are deliberately not compared: two sequences spell
    /// the same bytes with their own offsets, so a caller that is
    /// comparing across sequences takes `poolBytes` and `bytesOf` to
    /// those. Field by field, never `asBytes` of the union — an extern
    /// union's inactive bytes are indeterminate.
    pub fn eqlOutsidePool(self: Payload, other: Payload, kind: Kind) bool {
        return switch (kind.payloadField()) {
            .none, .bytes => true,
            .note => std.meta.eql(self.note, other.note),
            .poly => std.meta.eql(self.poly, other.poly),
            .control => std.meta.eql(self.control, other.control),
            .program => std.meta.eql(self.program, other.program),
            .pressure => std.meta.eql(self.pressure, other.pressure),
            .bend => std.meta.eql(self.bend, other.bend),
            .meta => self.meta.meta_type == other.meta.meta_type,
            .number => self.number == other.number,
            .byte => self.byte == other.byte,
            .tempo => self.tempo == other.tempo,
            .smpte => std.meta.eql(self.smpte, other.smpte),
            .time_sig => std.meta.eql(self.time_sig, other.time_sig),
            .key_sig => std.meta.eql(self.key_sig, other.key_sig),
            .residue => self.residue.ver == other.residue.ver and
                self.residue.kind == other.residue.kind and
                self.residue.seq == other.residue.seq and
                self.residue.total == other.residue.total,
        };
    }
};

/// What `Payload.channelData` answers: a channel message's channel and
/// its one or two data bytes, in the order the file spells them.
pub const ChannelData = struct { ch: u8, d1: u8, d2: u8 };

/// One event at an ABSOLUTE tick in the file's division.
pub const Event = struct {
    at: i64,
    kind: Kind,
    payload: Payload,
};

/// One `MTrk`, in file order. Events are non-decreasing in `at` by
/// construction — the reader sums deltas, the writer stable-sorts.
pub const Track = struct { events: []Event };

/// A chunk whose type is neither `MThd` nor `MTrk`: skipped by length and
/// kept, as RP-001 requires of a reader. The canonical writer does not
/// re-emit them (it emits a header and its tracks and nothing else);
/// `tempura inspect` and the residue are what they are kept for.
pub const ForeignChunk = struct {
    /// The four-character chunk type, verbatim.
    tag: [4]u8,
    /// The chunk's body in the pool, without the eight-byte header.
    bytes: Bytes,
};

/// A whole `.mid` as a value. Arena-backed: `deinit` frees the tracks,
/// the pool and every slice in one call, and the struct never retains the
/// caller's GPA.
pub const Sequence = struct {
    /// 0 one track, 1 simultaneous tracks, 2 independent sequences.
    format: u8,
    /// The header's division, as read — SMPTE stays SMPTE here.
    division: Division,
    /// Tracks in file order.
    tracks: []Track,
    /// Preserved unknown chunks, in file order.
    foreign: []ForeignChunk,
    /// Every payload byte in the file, in the order the reader met them.
    pool: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Sequence) void {
        self.arena.deinit();
    }

    /// The bytes a payload names, borrowed from the pool and valid until
    /// `deinit`.
    pub fn bytesOf(self: *const Sequence, b: Bytes) []const u8 {
        return self.pool[b.off..][0..b.len];
    }

    /// How many events the whole sequence holds — the one number a
    /// consumer needs to size its own tables.
    pub fn eventCount(self: *const Sequence) usize {
        var n: usize = 0;
        for (self.tracks) |t| n += t.events.len;
        return n;
    }

    /// What holds of EVERY `Sequence`, whoever built it — the reader,
    /// a `Builder`, the residue's rebuild, the document bridge: each run
    /// an event or a foreign chunk names lies inside `pool`, so `bytesOf`
    /// is total. Asserted at the end of the reader and the entry of the
    /// writer (plan 12, "The invariants"). Nothing about the VALUES is
    /// claimed: a builder may seat a data byte of 200 or events out of
    /// tick order, and the writer masks the one and sorts the other; what
    /// the READER establishes beyond this is asserted in `read.zig`.
    pub fn invariants(self: *const Sequence) void {
        for (self.tracks) |t| {
            for (t.events) |e| {
                const run = e.payload.poolBytes(e.kind) orelse continue;
                std.debug.assert(run.off <= self.pool.len);
                std.debug.assert(run.len <= self.pool.len - run.off);
            }
        }
        for (self.foreign) |chunk| {
            std.debug.assert(chunk.bytes.off <= self.pool.len);
            std.debug.assert(chunk.bytes.len <= self.pool.len - chunk.bytes.off);
        }
    }
};

/// Builds a `Sequence` programmatically: the tests' fixtures, the
/// renderer that has no file to read, and the residue layer that rebuilds
/// a sequence with its payloads seated in it all go through here.
///
/// Lifetime: `init`, then either `finish` (which MOVES the arena into the
/// returned `Sequence` and leaves the builder spent) or `deinit` (which
/// frees everything). Never both.
pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    tracks: std.ArrayList(std.ArrayList(Event)) = .empty,
    foreign: std.ArrayList(ForeignChunk) = .empty,
    pool: std.ArrayList(u8) = .empty,

    /// The header fields the finished `Sequence` carries. Set them
    /// directly; they have file-typical defaults so a fixture that does
    /// not care can ignore them.
    format: u8 = 1,
    division: Division = .{ .ppq = 480 },

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .arena = .init(gpa) };
    }

    /// Frees an ABANDONED builder. A builder that reached `finish` is
    /// spent — the `Sequence` owns the arena from then on.
    pub fn deinit(self: *Builder) void {
        self.arena.deinit();
    }

    /// Appends an empty track and returns its index.
    pub fn addTrack(self: *Builder) Error!u32 {
        const arena = self.arena.allocator();
        try self.tracks.append(arena, .empty);
        return @intCast(self.tracks.items.len - 1);
    }

    /// Copies `bytes` into the pool and returns the run that names them.
    /// The copy is why a caller may hand in a stack buffer or a slice of
    /// the file it is reading.
    pub fn addBytes(self: *Builder, bytes: []const u8) Error!Bytes {
        const arena = self.arena.allocator();
        const off: u32 = @intCast(self.pool.items.len);
        try self.pool.appendSlice(arena, bytes);
        return .{ .off = off, .len = @intCast(bytes.len) };
    }

    /// Keeps a chunk that is neither `MThd` nor `MTrk`. The reader's,
    /// mostly: a hand-built sequence has none.
    pub fn addForeign(self: *Builder, tag: [4]u8, bytes: Bytes) Error!void {
        try self.foreign.append(self.arena.allocator(), .{ .tag = tag, .bytes = bytes });
    }

    /// The bytes a run names, borrowed from the pool being built —
    /// valid until the next `addBytes`, which may move it.
    pub fn bytesOf(self: *const Builder, b: Bytes) []const u8 {
        return self.pool.items[b.off..][0..b.len];
    }

    /// Appends an event to `track`, in document order.
    pub fn addEvent(self: *Builder, track: u32, at: i64, kind: Kind, payload: Payload) Error!void {
        const arena = self.arena.allocator();
        try self.tracks.items[track].append(arena, .{ .at = at, .kind = kind, .payload = payload });
    }

    /// How many events `track` holds so far.
    pub fn eventCount(self: *const Builder, track: u32) usize {
        return self.tracks.items[track].items.len;
    }

    /// Freezes the builder into a `Sequence` that owns the arena.
    pub fn finish(self: *Builder) Error!Sequence {
        const arena = self.arena.allocator();
        const tracks = try arena.alloc(Track, self.tracks.items.len);
        for (self.tracks.items, 0..) |*t, i| tracks[i] = .{ .events = try t.toOwnedSlice(arena) };
        const pool = try self.pool.toOwnedSlice(arena);
        return .{
            .format = self.format,
            .division = self.division,
            .tracks = tracks,
            .foreign = try self.foreign.toOwnedSlice(arena),
            .pool = pool,
            .arena = self.arena,
        };
    }
};

comptime {
    // The layout pins, as pacer pins its blobs: an event is a value a
    // consumer may hold by the thousand in a flat slice, and the extern
    // union keeps that true in every optimisation mode.
    std.debug.assert(@sizeOf(Bytes) == 8);
    std.debug.assert(@sizeOf(Payload) == 12);
    std.debug.assert(@alignOf(Payload) == 4);
    std.debug.assert(@sizeOf(Event) == 24);
    std.debug.assert(@alignOf(Event) == 8);

    // The reader's one table is the inverse of the writer's: a kind with
    // a status byte is the kind that byte names, and a kind without one
    // is named by no byte at all. A build break rather than a per-event
    // assert, since it is a property of the two tables and not of a
    // value.
    for (std.enums.values(Kind)) |kind| {
        if (kind.status()) |status_byte| {
            std.debug.assert(Kind.fromStatus(status_byte) == kind);
            std.debug.assert(kind.dataBytes() == 1 or kind.dataBytes() == 2);
        } else {
            std.debug.assert(!kind.isChannel());
        }
    }
}

test "Division: the grid PPQ is as read, OpenMPT's conversion for SMPTE, 96 for a zero" {
    try testing.expectEqual(@as(u15, 480), (Division{ .ppq = 480 }).pulsesPerQuarter());
    try testing.expectEqual(@as(u15, 1), (Division{ .ppq = 1 }).pulsesPerQuarter());
    try testing.expectEqual(@as(u15, 32767), (Division{ .ppq = 32767 }).pulsesPerQuarter());

    // OpenMPT's `frames · subframes / 2` (Load_mid.cpp:661-669).
    try testing.expectEqual(@as(u15, 500), (Division{ .smpte = .{ .fps = 25, .tpf = 40 } }).pulsesPerQuarter());
    try testing.expectEqual(@as(u15, 1200), (Division{ .smpte = .{ .fps = 30, .tpf = 80 } }).pulsesPerQuarter());
    try testing.expectEqual(@as(u15, 48), (Division{ .smpte = .{ .fps = 24, .tpf = 4 } }).pulsesPerQuarter());

    // A zero division is OpenMPT's 96 in both arms, never a divide by nothing.
    try testing.expectEqual(@as(u15, 96), (Division{ .ppq = 0 }).pulsesPerQuarter());
    try testing.expectEqual(@as(u15, 96), (Division{ .smpte = .{ .fps = 0, .tpf = 0 } }).pulsesPerQuarter());
    try testing.expectEqual(@as(u15, 96), (Division{ .smpte = .{ .fps = 1, .tpf = 1 } }).pulsesPerQuarter());
}

test "Division: tempoOnGrid is the tempo as read on a PPQ grid, and 120 QPM on a converted one" {
    // A PPQ file's grid is its own: every tempo passes through.
    try testing.expectEqual(@as(u32, 1_000_000), (Division{ .ppq = 480 }).tempoOnGrid(1_000_000));
    try testing.expectEqual(@as(u32, 1), (Division{ .ppq = 1 }).tempoOnGrid(1));
    try testing.expectEqual(@as(u32, 0), (Division{ .ppq = 96 }).tempoOnGrid(0));

    // A SMPTE grid was derived at 120 QPM, and is read at 120 QPM
    // whatever the event said — a 60 on it would double every second.
    const smpte = Division{ .smpte = .{ .fps = 25, .tpf = 40 } };
    try testing.expectEqual(Division.smpte_tempo_us, smpte.tempoOnGrid(1_000_000));
    try testing.expectEqual(@as(u32, 500_000), smpte.tempoOnGrid(500_000));
    try testing.expectEqual(@as(u32, 500_000), smpte.tempoOnGrid(0));
    // The 96 fallback is still a converted grid.
    try testing.expectEqual(@as(u32, 500_000), (Division{ .smpte = .{ .fps = 0, .tpf = 0 } }).tempoOnGrid(250_000));
}

test "Kind: the ordinals are the wire, pinned by name and append-only" {
    const all = [_]Kind{
        .note_off,
        .note_on,
        .poly_pressure,
        .control_change,
        .program_change,
        .channel_pressure,
        .pitch_bend,
        .sysex,
        .escape,
        .sequence_number,
        .text_event,
        .copyright_notice,
        .sequence_name,
        .instrument_name,
        .lyric,
        .marker,
        .cue_point,
        .program_name,
        .device_name,
        .midi_channel_prefix,
        .midi_port,
        .end_of_track,
        .set_tempo,
        .smpte_offset,
        .time_signature,
        .key_signature,
        .sequencer_specific,
        .meta_unknown,
        .ease_hint,
        .tempura_residue,
    };
    try testing.expectEqual(@typeInfo(Kind).@"enum".fields.len, all.len);
    for (all, 0..) |k, i| try testing.expectEqual(i, @intFromEnum(k));
    try testing.expectEqual(u8, @typeInfo(Kind).@"enum".tag_type);
}

test "Kind: the status and meta-type tables the reader and the writer share" {
    try testing.expectEqual(@as(?u8, 0x80), Kind.note_off.status());
    try testing.expectEqual(@as(?u8, 0x90), Kind.note_on.status());
    try testing.expectEqual(@as(?u8, 0xA0), Kind.poly_pressure.status());
    try testing.expectEqual(@as(?u8, 0xB0), Kind.control_change.status());
    try testing.expectEqual(@as(?u8, 0xC0), Kind.program_change.status());
    try testing.expectEqual(@as(?u8, 0xD0), Kind.channel_pressure.status());
    try testing.expectEqual(@as(?u8, 0xE0), Kind.pitch_bend.status());
    try testing.expectEqual(@as(?u8, null), Kind.sysex.status());
    try testing.expectEqual(@as(?u8, null), Kind.set_tempo.status());

    try testing.expect(Kind.note_off.isChannel());
    try testing.expect(Kind.pitch_bend.isChannel());
    try testing.expect(!Kind.sysex.isChannel());
    try testing.expect(!Kind.end_of_track.isChannel());

    try testing.expectEqual(@as(?u8, 0x00), Kind.sequence_number.metaType());
    try testing.expectEqual(@as(?u8, 0x01), Kind.text_event.metaType());
    try testing.expectEqual(@as(?u8, 0x06), Kind.marker.metaType());
    try testing.expectEqual(@as(?u8, 0x09), Kind.device_name.metaType());
    try testing.expectEqual(@as(?u8, 0x20), Kind.midi_channel_prefix.metaType());
    try testing.expectEqual(@as(?u8, 0x21), Kind.midi_port.metaType());
    try testing.expectEqual(@as(?u8, 0x2F), Kind.end_of_track.metaType());
    try testing.expectEqual(@as(?u8, 0x51), Kind.set_tempo.metaType());
    try testing.expectEqual(@as(?u8, 0x54), Kind.smpte_offset.metaType());
    try testing.expectEqual(@as(?u8, 0x58), Kind.time_signature.metaType());
    try testing.expectEqual(@as(?u8, 0x59), Kind.key_signature.metaType());
    try testing.expectEqual(@as(?u8, 0x7F), Kind.sequencer_specific.metaType());
    try testing.expectEqual(@as(?u8, 0x7F), Kind.ease_hint.metaType());
    try testing.expectEqual(@as(?u8, 0x7F), Kind.tempura_residue.metaType());
    // `meta_unknown` carries its own type byte in the payload.
    try testing.expectEqual(@as(?u8, null), Kind.meta_unknown.metaType());
    try testing.expectEqual(@as(?u8, null), Kind.sysex.metaType());
}

test "Kind: fromStatus is the inverse of status, for channel bytes and nothing else" {
    var status: u16 = 0;
    while (status <= 0xFF) : (status += 1) {
        const byte: u8 = @intCast(status);
        const kind = Kind.fromStatus(byte);
        if (byte < 0x80 or byte >= 0xF0) {
            try testing.expectEqual(@as(?Kind, null), kind);
        } else {
            // Round trip: the kind's status byte is this one's high
            // nibble, whatever channel it named.
            try testing.expectEqual(byte & 0xF0, kind.?.status().?);
            try testing.expect(kind.?.isChannel());
        }
    }
}

test "Kind: payloadField names one member per kind, and poolBytes finds the runs" {
    // Exhaustive by construction: every kind answers, and the answer is
    // the member `Payload`'s table names.
    for (std.enums.values(Kind)) |kind| {
        const field = kind.payloadField();
        switch (field) {
            .bytes, .meta, .residue => {
                const payload: Payload = switch (field) {
                    .bytes => .{ .bytes = .{ .off = 3, .len = 4 } },
                    .meta => .{ .meta = .{ .bytes = .{ .off = 3, .len = 4 }, .meta_type = 0x0A } },
                    else => .{ .residue = .{
                        .ver = 1,
                        .kind = 1,
                        .seq = 0,
                        .total = 1,
                        .body = .{ .off = 3, .len = 4 },
                    } },
                };
                try testing.expectEqual(Bytes{ .off = 3, .len = 4 }, payload.poolBytes(kind).?);
            },
            else => try testing.expectEqual(@as(?Bytes, null), Payload.empty.poolBytes(kind)),
        }
    }

    try testing.expectEqual(Field.note, Kind.note_on.payloadField());
    try testing.expectEqual(Field.bend, Kind.pitch_bend.payloadField());
    try testing.expectEqual(Field.bytes, Kind.ease_hint.payloadField());
    try testing.expectEqual(Field.meta, Kind.meta_unknown.payloadField());
    try testing.expectEqual(Field.residue, Kind.tempura_residue.payloadField());
    try testing.expectEqual(Field.tempo, Kind.set_tempo.payloadField());
    try testing.expectEqual(Field.none, Kind.end_of_track.payloadField());
}

test "Payload: channelData is the wire order of every channel kind, and null for the rest" {
    const Case = struct { kind: Kind, payload: Payload, want: ChannelData };
    const cases = [_]Case{
        .{
            .kind = .note_on,
            .payload = .{ .note = .{ .ch = 3, .key = 60, .vel = 100 } },
            .want = .{ .ch = 3, .d1 = 60, .d2 = 100 },
        },
        .{
            .kind = .note_off,
            .payload = .{ .note = .{ .ch = 3, .key = 60, .vel = 64 } },
            .want = .{ .ch = 3, .d1 = 60, .d2 = 64 },
        },
        .{
            .kind = .poly_pressure,
            .payload = .{ .poly = .{ .ch = 1, .key = 2, .val = 3 } },
            .want = .{ .ch = 1, .d1 = 2, .d2 = 3 },
        },
        .{
            .kind = .control_change,
            .payload = .{ .control = .{ .ch = 0, .num = 7, .val = 127 } },
            .want = .{ .ch = 0, .d1 = 7, .d2 = 127 },
        },
        // The one-byte kinds answer a zero second byte the writer never
        // emits.
        .{
            .kind = .program_change,
            .payload = .{ .program = .{ .ch = 9, .num = 5 } },
            .want = .{ .ch = 9, .d1 = 5, .d2 = 0 },
        },
        .{
            .kind = .channel_pressure,
            .payload = .{ .pressure = .{ .ch = 9, .val = 80 } },
            .want = .{ .ch = 9, .d1 = 80, .d2 = 0 },
        },
        // 14 bits, LSB first: centre 8192 is `00 40`, 8193 is `01 40`.
        .{
            .kind = .pitch_bend,
            .payload = .{ .bend = .{ .ch = 0, .value = 8192 } },
            .want = .{ .ch = 0, .d1 = 0x00, .d2 = 0x40 },
        },
        .{
            .kind = .pitch_bend,
            .payload = .{ .bend = .{ .ch = 0, .value = 8193 } },
            .want = .{ .ch = 0, .d1 = 0x01, .d2 = 0x40 },
        },
    };
    for (cases) |c| try testing.expectEqual(c.want, c.payload.channelData(c.kind).?);
    // Everything else carries no channel.
    for (std.enums.values(Kind)) |kind| {
        if (kind.isChannel()) continue;
        try testing.expectEqual(@as(?ChannelData, null), Payload.empty.channelData(kind));
    }
}

test "Sequence.invariants: a built sequence holds, run by run" {
    // Exercised on purpose (an invariant no value reaches proves
    // nothing): the runs a builder seats are inside its pool, foreign
    // chunks included, and the check walks them without complaint.
    var b: Builder = .init(testing.allocator);
    errdefer b.deinit();
    const t0 = try b.addTrack();
    try b.addEvent(t0, 0, .marker, .{ .bytes = try b.addBytes("intro") });
    const unknown = try b.addBytes("\xAB");
    try b.addEvent(t0, 0, .meta_unknown, .{ .meta = .{ .bytes = unknown, .meta_type = 0x0A } });
    try b.addEvent(t0, 0, .tempura_residue, .{ .residue = .{
        .ver = 1,
        .kind = 1,
        .seq = 0,
        .total = 1,
        .body = try b.addBytes("hi"),
    } });
    try b.addEvent(t0, 96, .end_of_track, .empty);
    try b.addForeign("XFIH".*, try b.addBytes("somebody's chunk"));
    var seq = try b.finish();
    defer seq.deinit();
    seq.invariants();
    try testing.expectEqual(@as(usize, 5 + 1 + 2 + 16), seq.pool.len);
}

test "Payload: eqlOutsidePool compares the active member, never the union's other bytes" {
    // The trap this exists to close: an EXTERN union's inactive bytes are
    // indeterminate, so two payloads that mean the same thing can differ
    // byte for byte. Assign a wide member first, then the narrow one, and
    // the tail keeps whatever the wide one left there.
    var a: Payload = .{ .residue = .{
        .ver = 0xAA,
        .kind = 0xAA,
        .seq = 0xAA,
        .total = 0xAA,
        .body = .{ .off = 0xAAAA_AAAA, .len = 0xAAAA_AAAA },
    } };
    a.note = .{ .ch = 2, .key = 60, .vel = 100 };

    var b: Payload = .{ .bytes = .{ .off = 0, .len = 0 } };
    b.note = .{ .ch = 2, .key = 60, .vel = 100 };

    try testing.expect(a.eqlOutsidePool(b, .note_on));
    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)));

    // And it still tells two different notes apart.
    b.note = .{ .ch = 2, .key = 61, .vel = 100 };
    try testing.expect(!a.eqlOutsidePool(b, .note_on));

    // A run into the pool is not this function's business; what the run
    // POINTS AT is compared through `bytesOf` by whoever has the pools.
    const one: Payload = .{ .bytes = .{ .off = 0, .len = 4 } };
    const other: Payload = .{ .bytes = .{ .off = 99, .len = 7 } };
    try testing.expect(one.eqlOutsidePool(other, .marker));
    // Everything BESIDE the run is: a meta type, a residue envelope.
    const m1: Payload = .{ .meta = .{ .bytes = .{ .off = 0, .len = 1 }, .meta_type = 0x0A } };
    const m2: Payload = .{ .meta = .{ .bytes = .{ .off = 5, .len = 1 }, .meta_type = 0x0B } };
    try testing.expect(!m1.eqlOutsidePool(m2, .meta_unknown));
}

test "Event: the layout is pinned, as pacer pins its blobs" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Bytes));
    try testing.expectEqual(@as(usize, 12), @sizeOf(Payload));
    try testing.expectEqual(@as(usize, 4), @alignOf(Payload));
    try testing.expectEqual(@as(usize, 24), @sizeOf(Event));
    try testing.expectEqual(@as(usize, 8), @alignOf(Event));
    try testing.expectEqual(@as(usize, 12), @sizeOf(TempuraResidue));
}

test "Builder: tracks, document order, and one byte pool behind every payload" {
    var b: Builder = .init(testing.allocator);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = 96 };

    const t0 = try b.addTrack();
    const name = try b.addBytes("drums");
    try b.addEvent(t0, 0, .sequence_name, .{ .bytes = name });
    try b.addEvent(t0, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(t0, 384, .end_of_track, .empty);

    const t1 = try b.addTrack();
    try b.addEvent(t1, 0, .note_on, .{ .note = .{ .ch = 9, .key = 36, .vel = 110 } });
    try b.addEvent(t1, 96, .note_off, .{ .note = .{ .ch = 9, .key = 36, .vel = 64 } });
    try b.addEvent(t1, 96, .end_of_track, .empty);

    var seq = try b.finish();
    defer seq.deinit();

    try testing.expectEqual(@as(u8, 1), seq.format);
    try testing.expectEqual(@as(u15, 96), seq.division.pulsesPerQuarter());
    try testing.expectEqual(@as(usize, 2), seq.tracks.len);
    try testing.expectEqual(@as(usize, 0), seq.foreign.len);

    try testing.expectEqual(@as(usize, 3), seq.tracks[0].events.len);
    try testing.expectEqual(Kind.sequence_name, seq.tracks[0].events[0].kind);
    try testing.expectEqualStrings("drums", seq.bytesOf(seq.tracks[0].events[0].payload.bytes));
    try testing.expectEqual(@as(u32, 500_000), seq.tracks[0].events[1].payload.tempo);
    try testing.expectEqual(@as(i64, 384), seq.tracks[0].events[2].at);

    try testing.expectEqual(@as(usize, 3), seq.tracks[1].events.len);
    try testing.expectEqual(Kind.note_on, seq.tracks[1].events[0].kind);
    try testing.expectEqual(@as(u8, 36), seq.tracks[1].events[0].payload.note.key);
    try testing.expectEqual(@as(u8, 110), seq.tracks[1].events[0].payload.note.vel);
    try testing.expectEqual(@as(i64, 96), seq.tracks[1].events[1].at);

    // One pool for the whole sequence: "drums" and nothing else was asked for.
    try testing.expectEqualStrings("drums", seq.pool);
}

test "Builder: document order decides among events at one tick" {
    // The residue's placement rule (plan 04) rests on this: an essence
    // event belongs at tick 0 of the conductor track *before any other
    // event at that tick*, and the canonical writer's stable sort keeps
    // document order among equal ticks — so a builder that appends it
    // first is what makes it first in the file. (`src/residue/smf.zig`
    // rebuilds each track for exactly this reason, which is why there is
    // no `insertEvent` here: nothing ever needed to seat an event into a
    // track that was already built.)
    var b: Builder = .init(testing.allocator);
    errdefer b.deinit();

    const t0 = try b.addTrack();
    const body = try b.addBytes("\x01\x02");
    try b.addEvent(t0, 0, .tempura_residue, .{
        .residue = .{ .ver = 1, .kind = 1, .seq = 0, .total = 1, .body = body },
    });
    try b.addEvent(t0, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(t0, 0, .time_signature, .{ .time_sig = .{ .nn = 4, .dd = 2, .cc = 24, .bb = 8 } });
    try b.addEvent(t0, 96, .end_of_track, .empty);
    try testing.expectEqual(@as(usize, 4), b.eventCount(t0));

    var seq = try b.finish();
    defer seq.deinit();

    const events = seq.tracks[0].events;
    try testing.expectEqual(@as(usize, 4), events.len);
    try testing.expectEqual(Kind.tempura_residue, events[0].kind);
    try testing.expectEqual(@as(i64, 0), events[0].at);
    try testing.expectEqual(Kind.set_tempo, events[1].kind);
    try testing.expectEqual(Kind.time_signature, events[2].kind);
    try testing.expectEqualStrings("\x01\x02", seq.bytesOf(events[0].payload.residue.body));
}

test "Builder: an abandoned builder frees everything it took" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    const t0 = try b.addTrack();
    _ = try b.addBytes("a payload nobody will read");
    try b.addEvent(t0, 0, .end_of_track, .empty);
}
