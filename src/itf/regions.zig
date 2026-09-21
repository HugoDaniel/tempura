//! Where the opaque regions end.
//!
//! The writer must know where every sacred region stops, and none of
//! them carries its length: a sample's extent is dispatched on its
//! ENCODING (never assumed from the compression flag alone), the edit
//! history is guarded against a flag without a block, and the MIDI
//! configuration is only there when the header asks for it (plan 06,
//! "Sample data extents"; it 04 §"Edit history & MIDI config
//! detection").
//!
//! Everything here is a pure function of bytes plus a descriptor:
//! bounded, allocation-free, and total — a malformed file yields a
//! truncated extent, never a read past the end. The DIAGNOSTICS belong to
//! the caller, which knows the file offsets to span.

const std = @import("std");
const model = @import("Module.zig");

const Region = model.Region;
const testing = std.testing;

/// What a sample's data looks like on disk, as the 80-byte header spells
/// it (it 04 §Samples).
pub const Descriptor = struct {
    /// `Length`, in sample frames.
    frames: u32,
    /// 8 or 16.
    bits: u8,
    /// 1, or 2 for a split-stereo sample.
    channels: u8,
    enc: model.Encoding,
};

/// A region plus whether the file ran out before it did. Truncation is
/// recorded, never fatal, and the ref keeps the TRUNCATED length (it 03,
/// "Compressed-slice length").
pub const Extent = struct {
    region: Region,
    truncated: bool = false,
};

/// IT compresses into blocks of 0x8000 BYTES of output — 32768 frames at
/// 8 bits, 16384 at 16 (it 04 §"IT214/IT215 sample decompression").
const compression_block_bytes: u32 = 0x8000;

/// Where a sample's data ends, without decoding a byte of it.
pub fn sampleExtent(bytes: []const u8, off: u32, desc: Descriptor) Extent {
    if (off > bytes.len) return .{ .region = .{ .off = off, .len = 0 }, .truncated = true };
    const available: u32 = @intCast(bytes.len - off);

    const channels: u64 = @max(1, desc.channels);
    const want: u64 = switch (desc.enc) {
        // Length × bytes-per-frame × channels; split stereo is the same
        // total, left block then right (plan 06).
        .pcm => @as(u64, desc.frames) * @as(u64, if (desc.bits == 16) 2 else 1) * channels,
        // ModPlug's ADPCM hack: a 16-byte nibble table then the packed
        // nibbles, per channel (plan 06; 8-bit only in the wild).
        .adpcm => (16 + (@as(u64, desc.frames) + 1) / 2) * channels,
        // Walk the block headers instead — the header stores no
        // compressed length (it 03, "Compressed-slice length").
        .it214, .it215 => return walkBlocks(bytes, off, available, desc),
    };

    if (want > available) {
        return .{ .region = .{ .off = off, .len = available }, .truncated = true };
    }
    return .{ .region = .{ .off = off, .len = @intCast(want) }, .truncated = false };
}

/// `u16 compressed_size` + payload, repeated until the frame count is
/// satisfied, once per channel (it 04 §Samples).
fn walkBlocks(bytes: []const u8, off: u32, available: u32, desc: Descriptor) Extent {
    const per_block: u32 = if (desc.bits == 16)
        compression_block_bytes / 2
    else
        compression_block_bytes;

    var walked: u32 = 0;
    var channel: u32 = 0;
    while (channel < @max(1, desc.channels)) : (channel += 1) {
        var remaining = desc.frames;
        while (remaining > 0) {
            if (walked + 2 > available) {
                return .{ .region = .{ .off = off, .len = available }, .truncated = true };
            }
            const at = off + walked;
            const size = std.mem.readInt(u16, bytes[at..][0..2], .little);
            const block = 2 + @as(u64, size);
            if (walked + block > available) {
                return .{ .region = .{ .off = off, .len = available }, .truncated = true };
            }
            walked += @intCast(block);
            remaining -= @min(remaining, per_block);
        }
    }
    return .{ .region = .{ .off = off, .len = walked }, .truncated = false };
}

/// The lowest byte anything points at — `min(non-zero parapointers,
/// MsgOffset)`, the ceiling the edit-history block must fit under
/// (it 04's guard, `Load_it.cpp:642-690`). A zero pointer means "no
/// region", so it never lowers the ceiling.
pub const MinPointer = struct {
    value: u32,

    pub fn init(fallback: u32) MinPointer {
        return .{ .value = fallback };
    }

    pub fn offer(self: *MinPointer, pointer: u32) void {
        if (pointer != 0 and pointer < self.value) self.value = pointer;
    }
};

/// What sits after the parapointers.
pub const History = union(enum) {
    /// `Special` b1 clear: nothing to look for.
    absent,
    /// The block, `u16 count` included.
    present: Region,
    /// Flagged, and the block would overlap the first region anyone
    /// points at (or the end of the file): old Schism's bug. The caller
    /// raises `it_history_flag_without_block` and reads on as if absent.
    flag_without_block,
};

/// The edit-history block: `u16 count` + count × 8 bytes, immediately
/// after the parapointers (it 04 §"Edit history & MIDI config
/// detection").
pub fn editHistory(bytes: []const u8, pos: u32, special: u16, min_ptr: u32) History {
    if (special & model.special.edit_history == 0) return .absent;
    if (@as(u64, pos) + 2 > bytes.len) return .flag_without_block;

    const count = std.mem.readInt(u16, bytes[pos..][0..2], .little);
    const len: u64 = 2 + @as(u64, count) * 8;
    const end = @as(u64, pos) + len;
    if (end > min_ptr or end > bytes.len) return .flag_without_block;
    return .{ .present = .{ .off = pos, .len = @intCast(len) } };
}

/// What sits after the edit history.
pub const MidiConfig = union(enum) {
    /// Neither `Special` b3 nor `Flags` b7: no block.
    absent,
    /// There, and byte-equal to IT's default table: the module records
    /// nothing and the writer emits the default back (it 03, "What
    /// becomes a ref"). The region comes along anyway, because the
    /// reader still has to know those bytes were spoken for.
    default_table: Region,
    present: Region,
    /// Flagged, and the file ends first.
    truncated,
};

/// The embedded MIDI configuration: 4896 bytes when `Flags` b7 or
/// `Special` b3 (it 04 §"Edit history & MIDI config detection").
pub fn midiConfig(bytes: []const u8, pos: u32, flags: u16, special: u16) MidiConfig {
    const wanted = (flags & model.flag.embed_midi != 0) or
        (special & model.special.midi_config != 0);
    if (!wanted) return .absent;

    const end = @as(u64, pos) + model.midi_config_size;
    if (end > bytes.len) return .truncated;

    const region: Region = .{ .off = pos, .len = model.midi_config_size };
    const block = bytes[pos..][0..model.midi_config_size];
    if (isDefaultTable(block)) return .{ .default_table = region };
    return .{ .present = region };
}

/// Whether a MIDI-configuration block is IT's own default.
///
/// ASSUMPTION (reported at E0): the it plan set does not spell IT's
/// 4896-byte `ITMIDI.CFG` default, and neither ITTECH.TXT nor OpenMPT is
/// on this machine, so "byte-equal to the default" is taken to mean ALL
/// ZERO — which is what a block IT never filled in holds, and what
/// tempura's own writer emits when the flags demand a block it has no
/// content for. Replace the predicate, not its callers, once the table is
/// in hand.
pub fn isDefaultTable(block: []const u8) bool {
    for (block) |b| {
        if (b != 0) return false;
    }
    return true;
}

test "regions.sampleExtent: plain PCM is frames × bytes-per-frame × channels" {
    const bytes = [_]u8{0} ** 64;

    const mono8 = sampleExtent(&bytes, 4, .{ .frames = 10, .bits = 8, .channels = 1, .enc = .pcm });
    try testing.expectEqual(Region{ .off = 4, .len = 10 }, mono8.region);
    try testing.expect(!mono8.truncated);

    // Split stereo (left block then right) is the same total.
    const stereo16 = sampleExtent(
        &bytes,
        0,
        .{ .frames = 10, .bits = 16, .channels = 2, .enc = .pcm },
    );
    try testing.expectEqual(Region{ .off = 0, .len = 40 }, stereo16.region);

    const nothing = sampleExtent(
        &bytes,
        4,
        .{ .frames = 0, .bits = 8, .channels = 1, .enc = .pcm },
    );
    try testing.expectEqual(Region{ .off = 4, .len = 0 }, nothing.region);
}

test "regions.sampleExtent: a 16-frame ADPCM sample spans 24 bytes" {
    // ModPlug's hack: a 16-byte nibble table then the packed nibbles,
    // `16 + ceil(len/2)` per channel (plan 06, "Sample data extents").
    const bytes = [_]u8{0} ** 64;
    const e = sampleExtent(&bytes, 0, .{ .frames = 16, .bits = 8, .channels = 1, .enc = .adpcm });
    try testing.expectEqual(Region{ .off = 0, .len = 24 }, e.region);

    const odd = sampleExtent(&bytes, 0, .{ .frames = 15, .bits = 8, .channels = 1, .enc = .adpcm });
    try testing.expectEqual(@as(u32, 16 + 8), odd.region.len);
}

test "regions.sampleExtent: a compressed sample is its walked block stream" {
    // Two blocks of a 40000-frame 8-bit sample (32768 per block), each a
    // u16 compressed size then that many bytes.
    var bytes: [32]u8 = @splat(0xAA);
    std.mem.writeInt(u16, bytes[4..6], 5, .little);
    std.mem.writeInt(u16, bytes[11..13], 3, .little);

    const e = sampleExtent(
        &bytes,
        4,
        .{ .frames = 40000, .bits = 8, .channels = 1, .enc = .it214 },
    );
    try testing.expectEqual(Region{ .off = 4, .len = 12 }, e.region);
    try testing.expect(!e.truncated);

    // 16-bit halves the frames per block; stereo walks one stream per
    // channel, left fully then right.
    var st: [16]u8 = @splat(0);
    std.mem.writeInt(u16, st[0..2], 2, .little);
    std.mem.writeInt(u16, st[4..6], 4, .little);
    const s = sampleExtent(&st, 0, .{ .frames = 100, .bits = 16, .channels = 2, .enc = .it215 });
    try testing.expectEqual(Region{ .off = 0, .len = 4 + 6 }, s.region);
}

test "regions.sampleExtent: truncation is recorded and the walked length kept" {
    // A block header that promises more than the file holds: the ref
    // keeps the truncated length, the reader raises the diagnostic.
    var bytes: [10]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[2..4], 99, .little);
    const e = sampleExtent(&bytes, 2, .{ .frames = 4000, .bits = 8, .channels = 1, .enc = .it214 });
    try testing.expectEqual(Region{ .off = 2, .len = 8 }, e.region);
    try testing.expect(e.truncated);

    // PCM past the end truncates too, and a pointer past the end is empty.
    const pcm = sampleExtent(&bytes, 6, .{ .frames = 100, .bits = 8, .channels = 1, .enc = .pcm });
    try testing.expectEqual(Region{ .off = 6, .len = 4 }, pcm.region);
    try testing.expect(pcm.truncated);

    const past = sampleExtent(&bytes, 20, .{ .frames = 1, .bits = 8, .channels = 1, .enc = .pcm });
    try testing.expectEqual(@as(u32, 0), past.region.len);
    try testing.expect(past.truncated);
}

test "regions.MinPointer: zero pointers never lower the ceiling" {
    var min: MinPointer = .init(1000);
    try testing.expectEqual(@as(u32, 1000), min.value);
    min.offer(0);
    try testing.expectEqual(@as(u32, 1000), min.value);
    min.offer(600);
    min.offer(900);
    try testing.expectEqual(@as(u32, 600), min.value);
}

test "regions.editHistory: the block is accepted only when it fits under minPtr" {
    // `u16 count` then count × 8 bytes, right after the parapointers.
    var bytes: [64]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[10..12], 3, .little);

    // 2 + 3*8 = 26 bytes, ending at 36: fits under a minPtr of 40.
    try testing.expectEqual(
        History{ .present = .{ .off = 10, .len = 26 } },
        editHistory(&bytes, 10, model.special.edit_history, 40),
    );

    // Old Schism set the flag and wrote no block: the would-be block
    // overlaps the first parapointer, so it is absent (it 04's guard).
    try testing.expectEqual(
        History.flag_without_block,
        editHistory(&bytes, 10, model.special.edit_history, 30),
    );

    // No flag, no block — and a flagged block running past the FILE is
    // the same refusal, whatever minPtr says.
    try testing.expectEqual(History.absent, editHistory(&bytes, 10, 0, 40));
    std.mem.writeInt(u16, bytes[40..42], 1000, .little);
    try testing.expectEqual(
        History.flag_without_block,
        editHistory(&bytes, 40, model.special.edit_history, 0xFFFF),
    );
}

test "regions.midiConfig: embedded on Special b3 or Flags b7, omitted when default" {
    var bytes: [5000]u8 = @splat(0);

    // All-zero is IT's default table as far as tempura is concerned: the
    // block is there, the module records nothing, and the bytes are
    // still spoken for.
    const whole: Region = .{ .off = 40, .len = 4896 };
    try testing.expectEqual(
        MidiConfig{ .default_table = whole },
        midiConfig(&bytes, 40, 0, model.special.midi_config),
    );
    try testing.expectEqual(
        MidiConfig{ .default_table = whole },
        midiConfig(&bytes, 40, model.flag.embed_midi, 0),
    );
    try testing.expectEqual(MidiConfig.absent, midiConfig(&bytes, 40, 0, 0));

    bytes[40 + 17] = 'F';
    try testing.expectEqual(
        MidiConfig{ .present = .{ .off = 40, .len = 4896 } },
        midiConfig(&bytes, 40, 0, model.special.midi_config),
    );

    // Flagged but not there: truncated, never a read past the end.
    try testing.expectEqual(
        MidiConfig.truncated,
        midiConfig(&bytes, 200, 0, model.special.midi_config),
    );
}
