//! The IT value model: `Module` and everything it holds.
//!
//! A `Module` is an Impulse Tracker module as a VALUE. What carries time
//! is materialised — the header's timing fields, the orders, every
//! pattern's dense `rows × 64` cells, the song message — and everything
//! else is a sacred opaque `Region` (`{off, len}`) into the anchor's
//! bytes: instrument bodies, sample headers and data, the MIDI
//! configuration, the edit history, foreign trailing chunks, and
//! tempura's own `TMPU` residue chunk (plan 06, "The binary model").
//! Nothing opaque is decoded, here or anywhere: the writer copies the
//! bytes back. The MIDI configuration is the one region whose BYTES the
//! module also carries (`midi_config_bytes`): the document spells it as
//! `(it/midi …)` rather than referencing it, so a module built from a
//! document has the block and no file to point into.
//!
//! Every region is meaningful only against the exact file it was read
//! from (it 03, "The anchor") — a `Module` plus the wrong bytes is
//! nonsense, which is why `write` takes the source bytes explicitly.
//!
//! Memory: one arena per module, `deinit()` frees the lot (plan 01's
//! pacer conventions). `Builder` constructs a module WITHOUT bytes, for
//! tests and for the document bridge.

const std = @import("std");
const Diag = @import("../Diag.zig");

const testing = std.testing;

/// Only resource exhaustion is an error here; every malformed-input
/// condition is a diagnostic on a returned value.
pub const Error = error{OutOfMemory};

// ---- ITTECH record sizes (it 04 §"Parse pipeline": "Struct sizes are
// comptime-asserted: header 192, instrument 554, sample 80") ----

/// The Impulse Header, `IMPM` included.
pub const header_size: u32 = 192;
/// One instrument record — 554 bytes on disk in BOTH formats (it 04
/// §Instruments: the new format uses 547 and pads 7).
pub const instrument_size: u32 = 554;
/// One `IMPS` sample header. Sample DATA is elsewhere, behind its own
/// parapointer.
pub const sample_header_size: u32 = 80;
/// The embedded MIDI configuration: 9 global + 16 SFx + 128 Zxx macros ×
/// 32 ASCII chars (it 04 §"Edit history & MIDI config detection").
pub const midi_config_size: u32 = 4896;
/// Channels per pattern row. IT's is a fixed 64 (it 04 §"Pattern
/// unpacking": the header stores no channel count).
pub const channels: u16 = 64;

/// The height of the pattern a parapointer 0 stands for — synthesised by
/// the reader, and the only shape the writer may spell as a 0 in return
/// (it 04 §"Pattern unpacking"; it 05's canonical layout). It is 64 for
/// the same reason `channels` is, and they are NOT the same 64.
pub const empty_pattern_rows: u16 = 64;

/// Byte offsets into the 192-byte header (it 04 §Header, ITTECH's
/// "Impulse Header Layout").
pub const hdr = struct {
    pub const magic: u32 = 0x00;
    pub const title: u32 = 0x04;
    pub const highlight_minor: u32 = 0x1E;
    pub const highlight_major: u32 = 0x1F;
    pub const ord_num: u32 = 0x20;
    pub const ins_num: u32 = 0x22;
    pub const smp_num: u32 = 0x24;
    pub const pat_num: u32 = 0x26;
    pub const cwtv: u32 = 0x28;
    pub const cmwt: u32 = 0x2A;
    pub const flags: u32 = 0x2C;
    pub const special: u32 = 0x2E;
    pub const global_volume: u32 = 0x30;
    pub const mix_volume: u32 = 0x31;
    pub const initial_speed: u32 = 0x32;
    pub const initial_tempo: u32 = 0x33;
    pub const pan_separation: u32 = 0x34;
    pub const pitch_wheel_depth: u32 = 0x35;
    pub const message_length: u32 = 0x36;
    pub const message_offset: u32 = 0x38;
    pub const reserved: u32 = 0x3C;
    pub const channel_pan: u32 = 0x40;
    pub const channel_vol: u32 = 0x80;
    /// The order list starts where the header ends.
    pub const orders: u32 = 0xC0;
};

/// Byte offsets into an 80-byte `IMPS` sample header (ITTECH's sample
/// diagram, restated by it 04 §Samples — the fields tempura needs are the
/// ones that give the DATA's extent and descriptor).
pub const smp = struct {
    pub const magic: u32 = 0x00;
    pub const global_volume: u32 = 0x11;
    pub const flags: u32 = 0x12;
    pub const volume: u32 = 0x13;
    pub const name: u32 = 0x14;
    pub const convert: u32 = 0x2E;
    pub const default_pan: u32 = 0x2F;
    pub const length: u32 = 0x30;
    pub const loop_begin: u32 = 0x34;
    pub const loop_end: u32 = 0x38;
    pub const c5speed: u32 = 0x3C;
    pub const sus_begin: u32 = 0x40;
    pub const sus_end: u32 = 0x44;
    pub const sample_pointer: u32 = 0x48;
    pub const vibrato_speed: u32 = 0x4C;
    pub const vibrato_depth: u32 = 0x4D;
    pub const vibrato_rate: u32 = 0x4E;
    pub const vibrato_type: u32 = 0x4F;
};

/// The one field tempura reads out of an instrument record; the other 528
/// bytes are opaque (plan 06, "The binary model" table). ITTECH's
/// instrument table puts the 26-byte name at 0x20 in both the old and the
/// new layout.
pub const ins = struct {
    pub const magic: u32 = 0x00;
    pub const name: u32 = 0x20;
};

/// Sample `Flg` bits (it 04 §Samples).
pub const sample_flag = struct {
    pub const has_data: u8 = 1 << 0;
    pub const bits16: u8 = 1 << 1;
    pub const stereo: u8 = 1 << 2;
    pub const compressed: u8 = 1 << 3;
    pub const loop: u8 = 1 << 4;
    pub const sus_loop: u8 = 1 << 5;
    pub const pingpong: u8 = 1 << 6;
    pub const pingpong_sus: u8 = 1 << 7;
};

/// Sample `Cvt` bits (it 04 §Samples). `0xFF` as a WHOLE byte is
/// ModPlug's ADPCM hack, not a bit.
pub const sample_convert = struct {
    pub const signed: u8 = 1 << 0;
    pub const big_endian: u8 = 1 << 1;
    /// With `Flg` b3 set this selects IT215's double delta.
    pub const delta: u8 = 1 << 2;
    pub const ptm_delta: u8 = 1 << 3;
    pub const adpcm: u8 = 0xFF;
};

/// Header `Flags` bits (it 04 §Header).
pub const flag = struct {
    pub const stereo: u16 = 1 << 0;
    pub const vol0_optimise: u16 = 1 << 1;
    pub const instruments: u16 = 1 << 2;
    pub const linear_slides: u16 = 1 << 3;
    pub const old_effects: u16 = 1 << 4;
    pub const compat_gxx: u16 = 1 << 5;
    pub const midi_pitch: u16 = 1 << 6;
    /// "Request embedded MIDI configuration".
    pub const embed_midi: u16 = 1 << 7;
};

/// Header `Special` bits (it 04 §Header: ITTECH labels b1 and b2
/// "reserved", and IT's own writer sets them anyway).
pub const special = struct {
    pub const message: u16 = 1 << 0;
    pub const edit_history: u16 = 1 << 1;
    pub const highlight: u16 = 1 << 2;
    pub const midi_config: u16 = 1 << 3;
};

/// `Cwt/v` for a module tempura authored: nibble 0xB's upper half, plus
/// the version counter (plan 06, "The canonical writer" — batida takes
/// `0xB000 | version`, tempura the top of that range; version 0.1 is the
/// low byte 0x01).
pub const cwtv_tempura: u16 = 0xB800 | 0x001;
/// `Cmwt` tempura writes: compatible with IT 2.14 (plan 06).
pub const cmwt_tempura: u16 = 0x0214;

comptime {
    // The layout pins as build breaks (plan 01, "Code style"). Each one
    // is an ITTECH size restated by its own field offsets, so a typo in
    // the tables above cannot compile.
    std.debug.assert(hdr.channel_pan + 64 == hdr.channel_vol);
    std.debug.assert(hdr.channel_vol + 64 == hdr.orders);
    std.debug.assert(hdr.orders == header_size);
    std.debug.assert(smp.vibrato_type + 1 == sample_header_size);
    std.debug.assert(ins.name + 26 <= instrument_size);
    std.debug.assert(midi_config_size == (9 + 16 + 128) * 32);
    std.debug.assert(@sizeOf(Cell) == 5);
}

/// A slice of the anchor's bytes, by offset and length. The one currency
/// of the pass-through model (it 03, "The `bin` form").
pub const Region = struct {
    off: u32 = 0,
    len: u32 = 0,

    /// The region that is not there.
    pub const none: Region = .{};

    pub fn isEmpty(self: Region) bool {
        return self.len == 0;
    }

    /// One past the last byte, in u64 so a bogus `off + len` cannot wrap.
    pub fn end(self: Region) u64 {
        return @as(u64, self.off) + self.len;
    }

    /// The bytes, or null when the region does not fit inside `source` —
    /// the only way a caller may turn a region into bytes.
    pub fn slice(self: Region, source: []const u8) ?[]const u8 {
        if (self.end() > source.len) return null;
        return source[self.off..][0..self.len];
    }
};

// ---- Pattern cells ----

/// No note in this cell. tempura's own spelling: IT's stream says "no
/// note" by leaving the field out, so the sentinel is ours.
pub const note_none: u8 = 255;
/// `^^^` — note cut (ITTECH's on-disk 254).
pub const note_cut: u8 = 254;
/// `===` — note off (ITTECH's on-disk 255).
pub const note_off: u8 = 253;
/// `~~~` — note fade (ITTECH: any on-disk 120–253; Schism writes 246).
pub const note_fade: u8 = 252;
/// The highest real note, `B-9` (ITTECH: notes are 0–119, C-0 at 0).
pub const note_max: u8 = 119;
/// No volume-column entry in this cell.
pub const vol_none: u8 = 255;

/// One event: a note, an instrument, a volume-column byte and a command,
/// each with its own "absent" spelling. The volume column keeps IT's RAW
/// byte (0–64 volume, 65–124 the slide families, 128–192 pan, 193–202
/// tone porta, 203–212 vibrato — it 04 §"Pattern unpacking"), because
/// tempura decides what it means at the document boundary, not here.
pub const Cell = struct {
    note: u8 = note_none,
    ins: u8 = 0,
    vol: u8 = vol_none,
    /// 0 none, 1–26 = A–Z (ITTECH's `cmd = letter - '@'`).
    fx: u8 = 0,
    param: u8 = 0,

    pub const empty: Cell = .{};

    pub fn isEmpty(self: Cell) bool {
        return std.meta.eql(self, empty);
    }
};

/// A pattern: `rows × 64` cells, row-major and dense. IT's own storage is
/// sparse and cached; density is tempura's, so the walk and the bridge
/// index instead of decode.
pub const Pattern = struct {
    rows: u16,
    cells: []Cell,

    /// The cell at `(row, channel)`. Callers stay inside `rows` and
    /// `channels`; this is an internal invariant, not user input.
    pub fn at(self: Pattern, row: usize, channel: usize) *Cell {
        std.debug.assert(row < self.rows);
        std.debug.assert(channel < channels);
        return &self.cells[row * channels + channel];
    }

    /// Whether no cell carries anything — what the writer needs to decide
    /// between a parapointer and a packed stream (it 05's canonical
    /// layout).
    pub fn isEmpty(self: Pattern) bool {
        for (self.cells) |c| {
            if (!c.isEmpty()) return false;
        }
        return true;
    }
};

// ---- Opaque records ----

/// An instrument: a name for the document to show, and 554 bytes tempura
/// never looks inside (plan 06, "The binary model").
pub const Opaque = struct {
    name: [26]u8 = @splat(0),
    raw: Region = .none,
};

/// How a sample's bytes are encoded. Copied from the header's flags so
/// the document reads truthfully; nothing here decodes (plan 06, "Sample
/// data extents").
pub const Encoding = enum { pcm, it214, it215, adpcm };

/// A sample: an opaque 80-byte header, an opaque data extent, and the
/// descriptor that says how long the data is.
pub const Sample = struct {
    name: [26]u8 = @splat(0),
    raw: Region = .none,
    data: Region = .none,
    bits: u8 = 8,
    channels: u8 = 1,
    enc: Encoding = .pcm,
};

/// A trailing chunk another tracker wrote (OpenMPT's `STPM`/`XTPM`,
/// plugin chunks…): kept verbatim, re-emitted in order, never parsed
/// (it 03, "What becomes a ref").
pub const Foreign = struct {
    tag: [4]u8 = @splat(0),
    raw: Region = .none,
};

/// The 192-byte header, materialised. Every field ITTECH names is here,
/// and `raw` keeps the bytes as read so a consumer can prove what was
/// there (plan 06's header table).
pub const Header = struct {
    title: [26]u8 = @splat(0),
    highlight_minor: u8 = 0,
    highlight_major: u8 = 0,
    ord_num: u16 = 0,
    ins_num: u16 = 0,
    smp_num: u16 = 0,
    pat_num: u16 = 0,
    cwtv: u16 = 0,
    cmwt: u16 = 0,
    flags: u16 = 0,
    special: u16 = 0,
    global_volume: u8 = 0,
    mix_volume: u8 = 0,
    initial_speed: u8 = 0,
    initial_tempo: u8 = 0,
    pan_separation: u8 = 0,
    pitch_wheel_depth: u8 = 0,
    message_length: u16 = 0,
    message_offset: u32 = 0,
    reserved: u32 = 0,
    channel_pan: [64]u8 = @splat(32),
    channel_vol: [64]u8 = @splat(64),
    /// The header's bytes AS READ — all zero for a module that was never
    /// read from a file.
    raw: [header_size]u8 = @splat(0),

    /// Everything zero but the channel tables: what a reader starts from.
    pub const blank: Header = .{};

    /// A module tempura authored: IT's own new-song defaults (GV 128,
    /// MV 48, speed 6, tempo 125, separation 128 — the ranges are it 04
    /// §Header), stereo and linear slides on, the highlight valid, and
    /// tempura's `Cwt/v` / `Cmwt` policy (plan 06).
    pub const fresh: Header = .{
        .highlight_minor = 4,
        .highlight_major = 16,
        .cwtv = cwtv_tempura,
        .cmwt = cmwt_tempura,
        .flags = flag.stereo | flag.linear_slides,
        .special = special.highlight,
        .global_volume = 128,
        .mix_volume = 48,
        .initial_speed = 6,
        .initial_tempo = 125,
        .pan_separation = 128,
    };

    /// Ticks per row as the walk must take it: IT's loader skips a zero
    /// `IS` and keeps its default 6 (plan 06's header table). The FIELD
    /// keeps the raw byte, so the writer can hand back what it was given.
    pub fn effectiveSpeed(self: Header) u8 {
        return if (self.initial_speed == 0) 6 else self.initial_speed;
    }

    /// The tempo as the walk must take it: floored at 31 on load
    /// (`Load_it.cpp:557`, per plan 06's header table).
    pub fn effectiveTempo(self: Header) u8 {
        return @max(31, self.initial_tempo);
    }
};

/// An Impulse Tracker module as a value, arena-backed.
///
/// `orders`, `patterns`, `instruments`, `samples`, `message` and
/// `foreign` all live in `arena`; the opaque regions point at the
/// ANCHOR's bytes, which the module does not own and never copies.
pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    header: Header = .blank,
    /// 0–199 a pattern, 254 `+++` skip, 255 `---` end (it 04 §Header).
    orders: []u8 = &.{},
    patterns: []Pattern = &.{},
    instruments: []Opaque = &.{},
    samples: []Sample = &.{},
    /// The song message as READ: CP437 bytes, CR newlines, no NUL. The
    /// transcoders below take it to and from UTF-8.
    message: []const u8 = &.{},
    /// Present only when the file's block is not IT's default table
    /// (see `regions.midiConfig`).
    midi_config: ?Region = null,
    /// The block's 4896 bytes, OWNED by the arena — the one opaque
    /// region the module carries as bytes as well as by reference. The
    /// reader fills it beside `midi_config` (the document bridge spells
    /// the slots and has no file to point into), `Builder.setMidiConfig`
    /// and the bridge fill it alone, and the writer emits it ahead of
    /// the region. Always `midi_config_size` long when present.
    midi_config_bytes: ?[]const u8 = null,
    edit_history: ?Region = null,
    foreign: []Foreign = &.{},
    /// tempura's own residue chunk's PAYLOAD (plan 04, "The IT
    /// carriers"): recorded here, decoded by the residue layer.
    tmpu: ?Region = null,

    /// An empty module. Callers fill it through `allocator()`.
    pub fn init(gpa: std.mem.Allocator) Module {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Module) void {
        self.arena.deinit();
    }

    /// The module's own arena — everything a producer puts in a `Module`
    /// must come from here.
    pub fn allocator(self: *Module) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// What holds of EVERY `Module`, whoever built it — the reader, a
    /// `Builder`, the document bridge: each pattern's cell grid is dense,
    /// exactly `rows × 64`, so `at` indexes and never decodes. Asserted
    /// at the end of the reader and the entry of the writer and the walk
    /// (plan 12, "The invariants"). Nothing about the VALUES is claimed:
    /// a builder may add 300 orders, a 0-row pattern or a two-byte MIDI
    /// configuration, and the writer diagnoses each of them; what the
    /// READER establishes beyond this is asserted in `read.zig`.
    pub fn invariants(self: *const Module) void {
        for (self.patterns) |p| {
            std.debug.assert(p.cells.len == @as(usize, p.rows) * channels);
        }
    }
};

/// Builds a `Module` programmatically — no bytes, no anchor.
///
/// The fresh-module header policy is applied at `init` (plan 06): a
/// module nobody read from a file identifies as tempura. `finish()` hands
/// the module over, arena and all; the builder is spent afterwards.
pub const Builder = struct {
    module: Module,
    finished: bool = false,
    orders: std.ArrayList(u8) = .empty,
    patterns: std.ArrayList(Pattern) = .empty,
    instruments: std.ArrayList(Opaque) = .empty,
    samples: std.ArrayList(Sample) = .empty,
    foreign: std.ArrayList(Foreign) = .empty,

    pub fn init(gpa: std.mem.Allocator) Builder {
        var m: Module = .init(gpa);
        m.header = .fresh;
        return .{ .module = m };
    }

    /// Frees everything — only when `finish` was never called.
    pub fn deinit(self: *Builder) void {
        if (!self.finished) self.module.deinit();
    }

    pub fn addOrder(self: *Builder, order: u8) Error!void {
        try self.orders.append(self.module.allocator(), order);
    }

    /// A new empty pattern. The returned value borrows the cells, which
    /// never move, so it stays usable after further `addPattern` calls.
    pub fn addPattern(self: *Builder, rows: u16) Error!Pattern {
        const arena = self.module.allocator();
        const cells = try arena.alloc(Cell, @as(usize, rows) * channels);
        @memset(cells, .empty);
        const p: Pattern = .{ .rows = rows, .cells = cells };
        try self.patterns.append(arena, p);
        return p;
    }

    pub fn addInstrument(self: *Builder, name: []const u8, raw: Region) Error!void {
        var o: Opaque = .{ .raw = raw };
        copyName(&o.name, name);
        try self.instruments.append(self.module.allocator(), o);
    }

    pub fn addSample(self: *Builder, sample: Sample) Error!void {
        try self.samples.append(self.module.allocator(), sample);
    }

    pub fn addForeign(self: *Builder, tag: [4]u8, raw: Region) Error!void {
        try self.foreign.append(self.module.allocator(), .{ .tag = tag, .raw = raw });
    }

    /// Copies the CP437 message into the module's arena.
    pub fn setMessage(self: *Builder, cp437: []const u8) Error!void {
        self.module.message = try self.module.allocator().dupe(u8, cp437);
    }

    /// Copies a whole MIDI configuration block into the module's arena.
    /// The size is the type's, so a block of any other length is a
    /// compile error rather than a short write.
    pub fn setMidiConfig(self: *Builder, block: *const [midi_config_size]u8) Error!void {
        self.module.midi_config_bytes = try self.module.allocator().dupe(u8, block);
    }

    pub fn setTitle(self: *Builder, title: []const u8) void {
        copyName(&self.module.header.title, title);
    }

    /// The module, owning the arena. The builder is spent: `deinit` after
    /// this is a no-op, and nothing else may be added.
    pub fn finish(self: *Builder) Module {
        var m = self.module;
        m.orders = self.orders.items;
        m.patterns = self.patterns.items;
        m.instruments = self.instruments.items;
        m.samples = self.samples.items;
        m.foreign = self.foreign.items;
        m.header.ord_num = @intCast(self.orders.items.len);
        m.header.ins_num = @intCast(self.instruments.items.len);
        m.header.smp_num = @intCast(self.samples.items.len);
        m.header.pat_num = @intCast(self.patterns.items.len);
        self.finished = true;
        return m;
    }
};

/// Left-justified, NUL-padded, truncated — how IT stores every name.
pub fn copyName(dst: []u8, name: []const u8) void {
    @memset(dst, 0);
    const n = @min(dst.len, name.len);
    @memcpy(dst[0..n], name[0..n]);
}

/// The text of a name field, up to its first NUL.
pub fn nameText(name: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, name, 0) orelse name.len;
    return name[0..end];
}

// ---- CP437 ⇄ UTF-8 ----

/// CP437's upper half as Unicode. IT text is CP437 and documents are
/// UTF-8 (plan 06, "The message and its encoding"); the low half is
/// ASCII, control bytes included — IT's own newline is CR and its
/// terminator is NUL, so neither is remapped.
///
/// Source: OpenMPT's `CharsetTableCP437`
/// (`src/mpt/string_transcode/transcode.hpp:134`, BSD-3-Clause, itself
/// generated from Unicode's `CP437.TXT`), which it 05 §"Message
/// encoding" names as the table to take. Attribution is the condition
/// OpenMPT's licence and `THIRD_PARTY_NOTICES.md` put on porting it.
const cp437_high = [128]u21{
    0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
    0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
    0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
    0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
    0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
    0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
    0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
    0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
    0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
    0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
    0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
    0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
    0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
    0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
};

/// What a transcoder returns: the bytes and what was lost on the way.
pub const Text = struct {
    arena: std.heap.ArenaAllocator,
    bytes: []const u8,
    diags: Diag.List,

    pub fn deinit(self: *Text) void {
        self.diags.deinit();
        self.arena.deinit();
    }
};

/// CP437 bytes → UTF-8. Total: every byte has a character, so the
/// diagnostics list comes back empty. CR and NUL pass through as
/// themselves.
pub fn cp437ToUtf8(gpa: std.mem.Allocator, bytes: []const u8) Error!Text {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, bytes.len);
    for (bytes) |b| {
        if (b < 0x80) {
            try out.append(arena, b);
        } else {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp437_high[b - 0x80], &buf) catch unreachable;
            try out.appendSlice(arena, buf[0..n]);
        }
    }

    return .{ .arena = arena_state, .bytes = out.items, .diags = .init(gpa) };
}

/// UTF-8 → CP437. Partial: a codepoint CP437 cannot spell (and any
/// invalid UTF-8) becomes `?` with an `it_message_encoding_lossy`
/// diagnostic spanning the offending bytes of the INPUT.
pub fn utf8ToCp437(gpa: std.mem.Allocator, text: []const u8) Error!Text {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, text.len);

    var i: usize = 0;
    // Bounded by the text: every turn consumes at least one byte.
    while (i < text.len) {
        const lead = text[i];
        if (lead < 0x80) {
            try out.append(arena, lead);
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(lead) catch {
            try lossy(&diags, &out, arena, i, i + 1, null);
            i += 1;
            continue;
        };
        if (i + n > text.len) {
            try lossy(&diags, &out, arena, i, text.len, null);
            break;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch {
            try lossy(&diags, &out, arena, i, i + n, null);
            i += n;
            continue;
        };
        if (std.mem.indexOfScalar(u21, &cp437_high, cp)) |at| {
            try out.append(arena, @intCast(0x80 + at));
        } else {
            try lossy(&diags, &out, arena, i, i + n, cp);
        }
        i += n;
    }

    return .{ .arena = arena_state, .bytes = out.items, .diags = diags };
}

/// A `?` for what CP437 cannot spell, and the diagnostic that says what
/// was lost. `out` grows in the `Text`'s arena.
fn lossy(
    diags: *Diag.List,
    out: *std.ArrayList(u8),
    arena: std.mem.Allocator,
    start: usize,
    end: usize,
    cp: ?u21,
) Error!void {
    try out.append(arena, '?');
    const span: Diag.Span = .{ .start = @intCast(start), .end = @intCast(end) };
    if (cp) |c| {
        try diags.add(.it_message_encoding_lossy, .warning, span, "U+{X:0>4} has no CP437 spelling; wrote '?'", .{c});
    } else {
        try diags.add(.it_message_encoding_lossy, .warning, span, "invalid UTF-8 at byte {d}; wrote '?'", .{start});
    }
}

test "Module: the ITTECH record sizes and header offsets are pinned" {
    try testing.expectEqual(@as(u32, 192), header_size);
    try testing.expectEqual(@as(u32, 554), instrument_size);
    try testing.expectEqual(@as(u32, 80), sample_header_size);
    try testing.expectEqual(@as(u32, 0xC0), hdr.orders);
    try testing.expectEqual(@as(usize, 5), @sizeOf(Cell));
}

test "Module.Builder: a fresh module carries tempura's Cwt/v and IT's defaults" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    try b.addOrder(0);
    const pat = try b.addPattern(64);
    pat.at(3, 5).* = .{ .note = 60, .ins = 1, .vol = 64, .fx = 1, .param = 6 };

    var m = b.finish();
    defer m.deinit();

    // The fresh-module header policy (plan 06, "The canonical writer"):
    // nibble 0xB8 plus tempura's version counter, compatible with 2.14.
    try testing.expectEqual(@as(u16, 0xB801), m.header.cwtv);
    try testing.expectEqual(@as(u16, 0x0214), m.header.cmwt);
    try testing.expectEqual(@as(u8, 6), m.header.initial_speed);
    try testing.expectEqual(@as(u8, 125), m.header.initial_tempo);
    try testing.expectEqual(@as(usize, 1), m.orders.len);
    try testing.expectEqual(@as(usize, 1), m.patterns.len);
    try testing.expectEqual(@as(u16, 64), m.patterns[0].rows);
    try testing.expectEqual(@as(usize, 64 * 64), m.patterns[0].cells.len);
    try testing.expectEqual(@as(u8, 60), m.patterns[0].at(3, 5).note);
    try testing.expect(m.patterns[0].at(0, 0).isEmpty());
}

test "Module.invariants: a built module holds, pattern by pattern" {
    // Exercised on purpose: a 0-row pattern and a 200-row one are both
    // dense, and the check walks them without complaint.
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    _ = try b.addPattern(0);
    _ = try b.addPattern(200);
    try b.addOrder(1);
    var m = b.finish();
    defer m.deinit();
    m.invariants();
    try testing.expectEqual(@as(usize, 0), m.patterns[0].cells.len);
    try testing.expectEqual(@as(usize, 200 * channels), m.patterns[1].cells.len);
}

test "Module.Builder: a MIDI configuration is copied whole into the arena" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    var block: [midi_config_size]u8 = @splat(0);
    @memcpy(block[0..2], "FA");
    try b.setMidiConfig(&block);
    // The builder copied, so the caller's block is not what the module
    // points at.
    block[0] = 'X';

    var m = b.finish();
    defer m.deinit();
    try testing.expectEqual(@as(usize, midi_config_size), m.midi_config_bytes.?.len);
    try testing.expectEqualStrings("FA", m.midi_config_bytes.?[0..2]);
    try testing.expectEqual(@as(?Region, null), m.midi_config);
}

test "Module.Header: the loader defaults live in accessors, not in the fields" {
    // The reader materialises the RAW bytes so the writer can give them
    // back; IT's own loader defaults (speed 6 for a zero, tempo floored at
    // 31) are what the WALK reads (plan 06, header table).
    var h: Header = .blank;
    h.initial_speed = 0;
    h.initial_tempo = 7;
    try testing.expectEqual(@as(u8, 6), h.effectiveSpeed());
    try testing.expectEqual(@as(u8, 31), h.effectiveTempo());

    h.initial_speed = 3;
    h.initial_tempo = 150;
    try testing.expectEqual(@as(u8, 3), h.effectiveSpeed());
    try testing.expectEqual(@as(u8, 150), h.effectiveTempo());
}

test "Module.cp437ToUtf8: high bytes become their characters, CR survives" {
    var t = try cp437ToUtf8(testing.allocator, "hi\r\x0dJo\x81rgen \xe1\xfe");
    defer t.deinit();

    try testing.expectEqualStrings("hi\r\rJoürgen ß■", t.bytes);
    try testing.expectEqual(@as(usize, 0), t.diags.items().len);
}

test "Module.utf8ToCp437: mappable text round-trips, the rest is lossy" {
    var t = try utf8ToCp437(testing.allocator, "Joürgen ß■");
    defer t.deinit();
    try testing.expectEqualStrings("Jo\x81rgen \xe1\xfe", t.bytes);
    try testing.expectEqual(@as(usize, 0), t.diags.items().len);

    var lossy_text = try utf8ToCp437(testing.allocator, "a\u{2603}b");
    defer lossy_text.deinit();
    try testing.expectEqualStrings("a?b", lossy_text.bytes);
    try testing.expectEqual(@as(usize, 1), lossy_text.diags.count(.it_message_encoding_lossy));
    try testing.expectEqual(Diag.Span{ .start = 1, .end = 4 }, lossy_text.diags.items()[0].span);
}

test "Module.utf8ToCp437: invalid UTF-8 is lossy too, and never panics" {
    var t = try utf8ToCp437(testing.allocator, "a\xffb\xe2\x82");
    defer t.deinit();
    try testing.expectEqualStrings("a?b?", t.bytes);
    try testing.expectEqual(@as(usize, 2), t.diags.count(.it_message_encoding_lossy));
}

test "Module.Region: slicing is bounded and never wraps" {
    const source = "0123456789";
    try testing.expectEqualStrings("234", (Region{ .off = 2, .len = 3 }).slice(source).?);
    try testing.expectEqual(@as(?[]const u8, null), (Region{ .off = 8, .len = 4 }).slice(source));
    try testing.expectEqual(@as(?[]const u8, null), (Region{ .off = 0xFFFF_FFFF, .len = 2 }).slice(source));
    try testing.expect((Region.none).isEmpty());
}

test "Module: names are NUL-padded and read back to their text" {
    var name: [26]u8 = undefined;
    copyName(&name, "kick");
    try testing.expectEqualStrings("kick", nameText(&name));
    try testing.expectEqual(@as(u8, 0), name[25]);

    copyName(&name, "a name far longer than twenty-six bytes");
    try testing.expectEqualStrings("a name far longer than twe", nameText(&name));
}
