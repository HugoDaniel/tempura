//! Variable-length quantities — SMF's delta times and payload lengths.
//!
//! A VLQ is 1..4 big-endian 7-bit groups, the high bit set on every byte
//! but the last, so the domain is `0 .. MAX` (`0x0FFF_FFFF`, RP-001). It
//! is the one number format a `.mid` uses for lengths and delta times,
//! and it is read from arbitrary bytes, so `read` reports through
//! `Diag.Code` and never asserts: a fifth continuation byte is
//! `vlq_too_long` and a value that runs off the end is
//! `smf_track_truncated`, both with the cursor left ON the offending
//! byte so the caller's span is one byte wide.
//!
//! `write` and `len` are the writer's half and are total on the domain:
//! they assert `value <= MAX`, which is an INTERNAL invariant (the
//! writer clamps its deltas before it gets here), never a check on
//! user input.

const std = @import("std");
const Diag = @import("../Diag.zig");

const testing = std.testing;

/// This module's error set: only the sink `write` writes into can fail,
/// and with an `Allocating` writer that failure IS allocation. Reading
/// cannot fail at all — malformed bytes come back as `Result.err`, a
/// diagnostic code the caller reports with a span.
pub const Error = std.Io.Writer.Error;

/// The largest value four 7-bit groups can hold; RP-001's ceiling for a
/// delta time and a payload length alike.
pub const MAX: u32 = 0x0FFF_FFFF;

/// The most bytes a value in the domain occupies.
pub const MAX_LEN: u8 = 4;

/// What `read` found: a value, or the code that says what the bytes did
/// instead. Never an error — a malformed file is a diagnostic.
pub const Result = union(enum) {
    ok: u32,
    err: Diag.Code,
};

/// Decode the VLQ at `pos.*`, advancing `pos` past it.
///
/// On `.ok` the cursor sits on the byte AFTER the value. On `.err` it
/// sits on the byte that failed — the fifth continuation byte for
/// `vlq_too_long`, the end of the input for `smf_track_truncated` — so a
/// caller spans `[pos, pos+1)` for the first and `[pos, pos)` for the
/// second without re-deriving anything.
pub fn read(bytes: []const u8, pos: *usize) Result {
    var value: u32 = 0;
    var i = pos.*;
    var taken: u8 = 0;
    while (true) {
        if (i >= bytes.len) {
            pos.* = i;
            return .{ .err = .smf_track_truncated };
        }
        if (taken == MAX_LEN) {
            pos.* = i;
            return .{ .err = .vlq_too_long };
        }
        const b = bytes[i];
        value = (value << 7) | (b & 0x7F);
        i += 1;
        taken += 1;
        if (b & 0x80 == 0) {
            pos.* = i;
            return .{ .ok = value };
        }
    }
}

/// How many bytes `write` will emit for `value`. Minimal by
/// construction: `0` is one byte, never `80 00`.
pub fn len(value: u32) u8 {
    std.debug.assert(value <= MAX);
    if (value < 0x80) return 1;
    if (value < 0x4000) return 2;
    if (value < 0x20_0000) return 3;
    return 4;
}

/// Emit `value` as the minimal VLQ. The canonical writer's rule "VLQ
/// lengths are minimal" (plan 05) is this function having no other mode.
pub fn write(w: *std.Io.Writer, value: u32) Error!void {
    std.debug.assert(value <= MAX);
    var buf: [MAX_LEN]u8 = undefined;
    const n = len(value);
    var v = value;
    var i: u8 = n;
    while (i > 0) {
        i -= 1;
        buf[i] = @as(u8, @truncate(v & 0x7F)) | (if (i == n - 1) @as(u8, 0) else 0x80);
        v >>= 7;
    }
    try w.writeAll(buf[0..n]);
}

test "vlq.read: RP-001's edge values decode and advance the cursor" {
    const Case = struct { bytes: []const u8, value: u32 };
    const cases = [_]Case{
        .{ .bytes = &.{0x00}, .value = 0 },
        .{ .bytes = &.{0x40}, .value = 64 },
        .{ .bytes = &.{0x7F}, .value = 127 },
        .{ .bytes = &.{ 0x81, 0x00 }, .value = 128 },
        .{ .bytes = &.{ 0xC0, 0x00 }, .value = 8192 },
        .{ .bytes = &.{ 0xFF, 0x7F }, .value = 16383 },
        .{ .bytes = &.{ 0x81, 0x80, 0x00 }, .value = 16384 },
        .{ .bytes = &.{ 0xFF, 0xFF, 0x7F }, .value = 2097151 },
        .{ .bytes = &.{ 0x81, 0x80, 0x80, 0x00 }, .value = 2097152 },
        .{ .bytes = &.{ 0xFF, 0xFF, 0xFF, 0x7F }, .value = 0x0FFF_FFFF },
    };
    for (cases) |c| {
        var pos: usize = 0;
        try testing.expectEqual(Result{ .ok = c.value }, read(c.bytes, &pos));
        try testing.expectEqual(c.bytes.len, pos);
    }
}

test "vlq.read: the cursor starts where it is told and stops after the value" {
    const bytes = [_]u8{ 0xAA, 0xBB, 0x81, 0x00, 0xCC };
    var pos: usize = 2;
    try testing.expectEqual(Result{ .ok = 128 }, read(&bytes, &pos));
    try testing.expectEqual(@as(usize, 4), pos);
}

test "vlq.read: a fifth continuation byte is vlq_too_long at that byte" {
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x7F };
    var pos: usize = 0;
    try testing.expectEqual(Result{ .err = .vlq_too_long }, read(&bytes, &pos));
    // The cursor names the offending byte, so the caller's span is that
    // byte and not the whole run.
    try testing.expectEqual(@as(usize, 4), pos);
}

test "vlq.read: a value that runs past the end is smf_track_truncated" {
    {
        var pos: usize = 0;
        try testing.expectEqual(Result{ .err = .smf_track_truncated }, read(&.{}, &pos));
        try testing.expectEqual(@as(usize, 0), pos);
    }
    {
        const bytes = [_]u8{0x81};
        var pos: usize = 0;
        try testing.expectEqual(Result{ .err = .smf_track_truncated }, read(&bytes, &pos));
        try testing.expectEqual(@as(usize, 1), pos);
    }
    {
        // Four continuation bytes and no last byte: truncation, not
        // vlq_too_long — the fifth byte is not there to be too long.
        const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
        var pos: usize = 0;
        try testing.expectEqual(Result{ .err = .smf_track_truncated }, read(&bytes, &pos));
        try testing.expectEqual(@as(usize, 4), pos);
    }
}

test "vlq.len and vlq.write: the encoding is minimal" {
    const Case = struct { value: u32, bytes: []const u8 };
    const cases = [_]Case{
        .{ .value = 0, .bytes = &.{0x00} },
        .{ .value = 127, .bytes = &.{0x7F} },
        .{ .value = 128, .bytes = &.{ 0x81, 0x00 } },
        .{ .value = 16383, .bytes = &.{ 0xFF, 0x7F } },
        .{ .value = 16384, .bytes = &.{ 0x81, 0x80, 0x00 } },
        .{ .value = 2097151, .bytes = &.{ 0xFF, 0xFF, 0x7F } },
        .{ .value = 2097152, .bytes = &.{ 0x81, 0x80, 0x80, 0x00 } },
        .{ .value = MAX, .bytes = &.{ 0xFF, 0xFF, 0xFF, 0x7F } },
    };
    for (cases) |c| {
        var buf: [MAX_LEN]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try write(&w, c.value);
        try testing.expectEqualSlices(u8, c.bytes, w.buffered());
        try testing.expectEqual(@as(u8, @intCast(c.bytes.len)), len(c.value));
    }
}

test "vlq: read(write(v)) == v over the edges and 10 000 pseudo-random values" {
    const edges = [_]u32{
        0,       1,       126,     127,
        128,     129,     255,     256,
        16382,   16383,   16384,   16385,
        2097150, 2097151, 2097152, 2097153,
        MAX - 1, MAX,
    };

    var buf: [MAX_LEN]u8 = undefined;
    for (edges) |v| {
        var w = std.Io.Writer.fixed(&buf);
        try write(&w, v);
        var pos: usize = 0;
        try testing.expectEqual(Result{ .ok = v }, read(w.buffered(), &pos));
        try testing.expectEqual(@as(usize, len(v)), pos);
    }

    var prng = std.Random.DefaultPrng.init(0x53_4D_46_76); // 'SMFv'
    const rand = prng.random();
    var n: usize = 0;
    while (n < 10_000) : (n += 1) {
        const v = rand.uintAtMost(u32, MAX);
        var w = std.Io.Writer.fixed(&buf);
        try write(&w, v);
        try testing.expectEqual(@as(u8, @intCast(w.buffered().len)), len(v));
        var pos: usize = 0;
        try testing.expectEqual(Result{ .ok = v }, read(w.buffered(), &pos));
        try testing.expectEqual(@as(usize, len(v)), pos);
    }
}
