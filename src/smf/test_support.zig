//! Test-only fixtures for the SMF core: a small byte writer and the
//! hand-built files every reader and writer test parses.
//!
//! No binary file lives in this repo (plan 09's rule for the format
//! cores' own fixtures): a fixture is BYTES A TEST WROTE, so the bytes a
//! test asserts on are visible in the same repository, reviewable in a
//! diff, and impossible to corrupt by a stray `git add`.
//!
//! Only referenced from `test { … }` bodies, so Zig never analyses this
//! file in a normal build (pacer's `test_support.zig` precedent).

const std = @import("std");

/// A big-endian byte sink with the SMF spellings on it. Owns its buffer
/// until `toOwnedSlice`.
pub const ByteWriter = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) ByteWriter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ByteWriter) void {
        self.buf.deinit(self.gpa);
    }

    pub fn raw(self: *ByteWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.gpa, bytes);
    }

    pub fn byte(self: *ByteWriter, v: u8) !void {
        try self.buf.append(self.gpa, v);
    }

    pub fn u16be(self: *ByteWriter, v: u16) !void {
        try self.raw(&[_]u8{ @intCast(v >> 8), @truncate(v) });
    }

    pub fn u32be(self: *ByteWriter, v: u32) !void {
        try self.raw(&[_]u8{
            @truncate(v >> 24),
            @truncate(v >> 16),
            @truncate(v >> 8),
            @truncate(v),
        });
    }

    /// A variable-length quantity, written the way the file writes it.
    /// Spelled out here rather than calling `vlq.write`, so a fixture
    /// never agrees with the code under test by construction.
    pub fn vlq(self: *ByteWriter, v: u32) !void {
        var stack: [5]u8 = undefined;
        var n: usize = 0;
        var x = v;
        while (true) {
            stack[n] = @truncate(x & 0x7F);
            n += 1;
            x >>= 7;
            if (x == 0) break;
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            try self.byte(stack[i] | (if (i == 0) @as(u8, 0) else 0x80));
        }
    }

    /// `<tag> <u32be length> <body>`.
    pub fn chunk(self: *ByteWriter, tag: *const [4]u8, body: []const u8) !void {
        try self.raw(tag);
        try self.u32be(@intCast(body.len));
        try self.raw(body);
    }

    pub fn toOwnedSlice(self: *ByteWriter) ![]u8 {
        return self.buf.toOwnedSlice(self.gpa);
    }
};

/// What `buildFile` puts in the header.
pub const FileOptions = struct {
    format: u16 = 0,
    division: u16 = 96,
    /// `null` means "as many as there are tracks" — the honest count.
    ntrks: ?u16 = null,
    /// Bytes appended to the six the header must carry; the declared
    /// length grows with them (RP-001 lets a reader meet a longer header).
    header_extra: []const u8 = &.{},
};

/// `MThd` + one `MTrk` per body. The caller owns the bytes.
pub fn buildFile(
    gpa: std.mem.Allocator,
    opts: FileOptions,
    tracks: []const []const u8,
) ![]u8 {
    var head = ByteWriter.init(gpa);
    defer head.deinit();
    try head.u16be(opts.format);
    try head.u16be(opts.ntrks orelse @intCast(tracks.len));
    try head.u16be(opts.division);
    try head.raw(opts.header_extra);

    var w = ByteWriter.init(gpa);
    errdefer w.deinit();
    try w.chunk("MThd", head.buf.items);
    for (tracks) |t| try w.chunk("MTrk", t);
    return w.toOwnedSlice();
}

/// The `7D 74 65 6D` residue payload of the two-track fixture: version 1,
/// kind 1 (essence), part 0 of 1, body `"hi"` (plan 04, "The SMF carrier").
pub const residue_payload = [_]u8{ 0x7D, 0x74, 0x65, 0x6D, 0x01, 0x01, 0x00, 0x01, 'h', 'i' };

/// midivia's 25-byte `7D 70 61 75` easing hint (midi 03): version 1,
/// channel 0, lane `cc`, controller 0x4A, op 2, four zero f32 parameters.
pub const ease_hint_payload = [_]u8{ 0x7D, 0x70, 0x61, 0x75, 0x01, 0x00, 0x00, 0x4A, 0x02 } ++ [_]u8{0} ** 16;

/// A Yamaha sequencer-specific payload: manufacturer `43`, somebody
/// else's bytes, kept verbatim.
pub const yamaha_payload = [_]u8{ 0x43, 0x7B, 0x01, 0x02 };

/// The sysex of the two-track fixture — bytes ≥ 0x80 INSIDE the payload,
/// which a reader must never mistake for status bytes.
pub const sysex_payload = [_]u8{ 0x43, 0x12, 0x80, 0xF0, 0xF7 };

/// An escape (`F7`) payload.
pub const escape_payload = [_]u8{ 0x41, 0x42, 0xF7 };

/// The two-track format 1 fixture of plan 05's phase 1, division 96.
///
/// Track 0 is the conductor: a sequence number, a name, 4/4, 500 000 µs
/// (`FF 51 03 07 A1 20`), a key signature, a port, tempura's residue,
/// midivia's easing hint, a Yamaha sequencer-specific event, an unknown
/// meta type, a marker at 192 and the end of track at 384.
///
/// Track 1 is the music: two note-ons (the second on running status),
/// two note-offs (the second on running status), the sysex, an escape,
/// two control changes (the second on running status, after the sysex
/// reset it), a program change, a pitch bend and the end of track at 288.
///
/// It is also CANONICAL — laid out exactly as `write` lays a `Sequence`
/// out — so `write(read(fixture))` must give these bytes back.
pub fn twoTrackFixture(gpa: std.mem.Allocator) ![]u8 {
    var t0 = ByteWriter.init(gpa);
    defer t0.deinit();
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x00, 0x02, 0x00, 0x01 }); // sequence number 1
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x03, 0x07 });
    try t0.raw("Tempura"); // sequence name
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08 }); // 4/4
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20 }); // 500 000 µs
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x59, 0x02, 0xFF, 0x00 }); // one flat, major
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x21, 0x01, 0x00 }); // port 0
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x7F, residue_payload.len });
    try t0.raw(&residue_payload);
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x7F, ease_hint_payload.len });
    try t0.raw(&ease_hint_payload);
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x7F, yamaha_payload.len });
    try t0.raw(&yamaha_payload);
    try t0.vlq(0);
    try t0.raw(&[_]u8{ 0xFF, 0x0A, 0x02, 0xAB, 0xCD }); // an unknown meta type
    try t0.vlq(192);
    try t0.raw(&[_]u8{ 0xFF, 0x06, 0x05 });
    try t0.raw("verse"); // marker at 192
    try t0.vlq(192);
    try t0.raw(&[_]u8{ 0xFF, 0x2F, 0x00 }); // end of track at 384

    var t1 = ByteWriter.init(gpa);
    defer t1.deinit();
    try t1.vlq(0);
    try t1.raw(&[_]u8{ 0x90, 0x3C, 0x64 }); // note on 60
    try t1.vlq(0);
    try t1.raw(&[_]u8{ 0x40, 0x64 }); // note on 64, running status
    try t1.vlq(96);
    try t1.raw(&[_]u8{ 0x80, 0x3C, 0x40 }); // note off 60
    try t1.vlq(0);
    try t1.raw(&[_]u8{ 0x40, 0x40 }); // note off 64, running status
    try t1.vlq(0);
    try t1.raw(&[_]u8{ 0xF0, sysex_payload.len });
    try t1.raw(&sysex_payload);
    try t1.vlq(0);
    try t1.raw(&[_]u8{ 0xF7, escape_payload.len });
    try t1.raw(&escape_payload);
    try t1.vlq(0);
    try t1.raw(&[_]u8{ 0xB0, 0x07, 0x7F }); // volume: status again, sysex reset it
    try t1.vlq(0);
    try t1.raw(&[_]u8{ 0x0A, 0x40 }); // pan, running status
    try t1.vlq(96);
    try t1.raw(&[_]u8{ 0xC0, 0x05 }); // program change
    try t1.vlq(0);
    try t1.raw(&[_]u8{ 0xE0, 0x00, 0x40 }); // pitch bend, centre
    try t1.vlq(96);
    try t1.raw(&[_]u8{ 0xFF, 0x2F, 0x00 }); // end of track at 288

    return buildFile(gpa, .{ .format = 1, .division = 96 }, &.{ t0.buf.items, t1.buf.items });
}

/// A FOREIGN layout of the same music: no running status anywhere and
/// note-offs spelled `9n` with velocity 0, the way plenty of DAWs export.
///
/// The reader keeps both as read (`note_on` with velocity 0 stays a
/// `note_on`), so `read(write(read(f)))` equals `read(f)` event for event
/// while the bytes themselves differ — rung 2 of the ladder.
pub fn foreignFixture(gpa: std.mem.Allocator) ![]u8 {
    var t = ByteWriter.init(gpa);
    defer t.deinit();
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x3C, 0x64 });
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x40, 0x64 }); // no running status
    try t.vlq(96);
    try t.raw(&[_]u8{ 0x90, 0x3C, 0x00 }); // a note off spelled as a note on
    try t.vlq(0);
    try t.raw(&[_]u8{ 0x90, 0x40, 0x00 });
    try t.vlq(0);
    try t.raw(&[_]u8{ 0xFF, 0x2F, 0x00 });

    return buildFile(gpa, .{ .format = 0, .division = 96 }, &.{t.buf.items});
}
