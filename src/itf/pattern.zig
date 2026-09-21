//! ITTECH's pattern packing, both directions.
//!
//! IT stores a pattern as a byte stream with a per-channel MASK and four
//! per-channel caches: a mask byte is sent only when it changes, and a
//! field that repeats its channel's last value is sent as a bit instead
//! of a byte (it 04 §"Pattern unpacking", it 05 §"Pattern packing" —
//! OpenMPT's `Load_it.cpp:1755-1977`). tempura's `Pattern` is dense
//! `rows × 64` instead, so the walk and the bridge index rather than
//! decode; this file is the whole distance between the two.
//!
//! The two properties that hold, and are tested below: `unpack(pack(x))
//! == x` for any cells tempura can hold, and `pack(unpack(pack(x))) ==
//! pack(x)` — packing is a fixed point. `pack(unpack(y)) == y` for an
//! ARBITRARY stream `y` is not a property and never will be: IT's own
//! packer leaves redundant fields in, and a fade note has 134 on-disk
//! spellings that all mean one thing.
//!
//! Bounded everywhere: a stream that ends mid-cell stops there with a
//! diagnostic, and no read ever leaves the slice.

const std = @import("std");
const Diag = @import("../Diag.zig");
const model = @import("Module.zig");

const Cell = model.Cell;
const testing = std.testing;

/// Only resource exhaustion is an error; malformed streams are
/// diagnostics.
pub const Error = error{OutOfMemory};

/// The most packed bytes a pattern may carry: its 8-byte header plus the
/// stream must stay inside IT's 64 KB ceiling, and `packed_len` is a u16
/// (it 05 §"Pattern packing", point 4).
pub const max_packed: usize = 65535 - 8;

// Mask bits (it 04's algorithm): b0–b3 say a field FOLLOWS, b4–b7 say a
// field repeats the channel's cache.
const mask_note: u8 = 1 << 0;
const mask_ins: u8 = 1 << 1;
const mask_vol: u8 = 1 << 2;
const mask_cmd: u8 = 1 << 3;
const mask_note_repeat: u8 = 1 << 4;
const mask_ins_repeat: u8 = 1 << 5;
const mask_vol_repeat: u8 = 1 << 6;
const mask_cmd_repeat: u8 = 1 << 7;

/// The on-disk note byte Schism writes for a fade (it 05 §"Pattern
/// packing": any byte ≥ 120 plays as fade).
const disk_note_fade: u8 = 246;
/// ITTECH's on-disk note off.
const disk_note_off: u8 = 255;
/// ITTECH's on-disk note cut.
const disk_note_cut: u8 = 254;
/// The highest command byte ITTECH's range admits; 27–31 name no letter
/// (it 04 §"Pattern unpacking"). Public so the reader can assert that
/// every command it kept is one of these.
pub const cmd_max: u8 = 26;

/// What one channel remembers between rows, on both sides of the stream.
const Cache = struct {
    mask: u8 = 0,
    note: u8 = model.note_none,
    ins: u8 = 0,
    vol: u8 = model.vol_none,
    fx: u8 = 0,
    param: u8 = 0,
    /// Whether the slot was ever written in THIS pattern — a repeat bit
    /// may only name a value the stream already carried (it 05, point 2).
    note_set: bool = false,
    ins_set: bool = false,
    vol_set: bool = false,
    cmd_set: bool = false,
};

/// A pattern's cells and what was wrong with the stream that held them.
pub const Unpacked = struct {
    arena: std.heap.ArenaAllocator,
    /// `rows × 64`, row-major and dense.
    cells: []Cell,
    diags: Diag.List,

    pub fn deinit(self: *Unpacked) void {
        self.diags.deinit();
        self.arena.deinit();
    }
};

/// Packed stream → dense cells. Spans are offsets into `bytes`; a caller
/// that read `bytes` out of a file rebases them onto the file.
///
/// The parent keeps the cursor, the row and the diagnostics; `readEntry`
/// reads one channel entry into its cache and `cellOf` spells the cell
/// that cache holds.
pub fn unpack(gpa: std.mem.Allocator, bytes: []const u8, rows: u16) Error!Unpacked {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    const cells = try arena_state.allocator().alloc(Cell, @as(usize, rows) * model.channels);
    @memset(cells, .empty);

    var cache: [model.channels]Cache = @splat(.{});
    var row: u16 = 0;
    var p: usize = 0;
    // Bounded by the stream: every turn consumes its lead byte at least.
    while (row < rows and p < bytes.len) {
        const lead = bytes[p];
        p += 1;
        if (lead == 0) {
            row += 1;
            continue;
        }
        const channel = (lead -% 1) & 63;
        const c = &cache[channel];
        switch (readEntry(bytes, &p, lead, c)) {
            .truncated => {
                try truncated(&diags, p, bytes.len);
                break;
            },
            .unknown_command => |at| try diags.add(
                .it_command_unknown,
                .warning,
                .{ .start = @intCast(at), .end = @intCast(at + 2) },
                "command byte {d} names no IT effect; read as no effect",
                .{bytes[at]},
            ),
            .ok => {},
        }
        cells[@as(usize, row) * model.channels + channel] = cellOf(c.*);
    }

    return .{ .arena = arena_state, .cells = cells, .diags = diags };
}

/// What reading one channel entry found.
const Entry = union(enum) {
    ok,
    /// The command byte at this offset names no letter; the cache took
    /// no effect in its place.
    unknown_command: usize,
    /// The stream ended inside the entry; the cursor sits where the
    /// missing byte would have been.
    truncated,
};

/// One channel entry after its lead byte: the mask when the lead says a
/// new one follows, then the fields the mask names, each into the
/// channel's cache — the cache is what `cellOf` then reads, repeat bits
/// and all. The cursor is advanced past what was read.
fn readEntry(bytes: []const u8, p: *usize, lead: u8, c: *Cache) Entry {
    if (lead & 0x80 != 0) {
        c.mask = takeByte(bytes, p) orelse return .truncated;
    }
    if (c.mask & mask_note != 0) {
        c.note = decodeNote(takeByte(bytes, p) orelse return .truncated);
        c.note_set = true;
    }
    if (c.mask & mask_ins != 0) {
        c.ins = takeByte(bytes, p) orelse return .truncated;
        c.ins_set = true;
    }
    if (c.mask & mask_vol != 0) {
        c.vol = takeByte(bytes, p) orelse return .truncated;
        c.vol_set = true;
    }
    if (c.mask & mask_cmd != 0) {
        if (p.* + 2 > bytes.len) return .truncated;
        const at = p.*;
        const raw_cmd = bytes[at];
        const param = bytes[at + 1];
        p.* += 2;
        c.cmd_set = true;
        if (raw_cmd > cmd_max) {
            // 27–31 sit in ITTECH's range and name no letter; above that
            // is garbage. Both read as NO EFFECT, with the command dropped
            // on write (it 04).
            c.fx = 0;
            c.param = 0;
            return .{ .unknown_command = at };
        }
        c.fx = raw_cmd;
        c.param = param;
    }
    return .ok;
}

/// The byte at the cursor, advancing past it, or null at the end of
/// the stream (the cursor stays on the end).
fn takeByte(bytes: []const u8, p: *usize) ?u8 {
    if (p.* >= bytes.len) return null;
    const b = bytes[p.*];
    p.* += 1;
    return b;
}

/// The cell a channel's cache spells under its mask: a field the mask
/// names as sent or as repeated is the cache's, the rest are absent.
fn cellOf(c: Cache) Cell {
    var cell: Cell = .empty;
    if (c.mask & (mask_note | mask_note_repeat) != 0) cell.note = c.note;
    if (c.mask & (mask_ins | mask_ins_repeat) != 0) cell.ins = c.ins;
    if (c.mask & (mask_vol | mask_vol_repeat) != 0) cell.vol = c.vol;
    if (c.mask & (mask_cmd | mask_cmd_repeat) != 0) {
        cell.fx = c.fx;
        cell.param = c.param;
    }
    return cell;
}

fn truncated(diags: *Diag.List, at: usize, end: usize) Error!void {
    try diags.add(
        .it_truncated,
        .warning,
        .{ .start = @intCast(at), .end = @intCast(end) },
        "the packed pattern stream ends mid-cell at byte {d}",
        .{at},
    );
}

/// ITTECH's note byte → tempura's. 0–119 are notes, 254 cuts, 255 is an
/// off, and everything between 120 and 253 fades (it 04, it 05).
fn decodeNote(disk: u8) u8 {
    return switch (disk) {
        0...model.note_max => disk,
        disk_note_cut => model.note_cut,
        disk_note_off => model.note_off,
        else => model.note_fade,
    };
}

/// tempura's note byte → ITTECH's, the inverse where one exists.
fn encodeNote(note: u8) u8 {
    return switch (note) {
        0...model.note_max => note,
        model.note_cut => disk_note_cut,
        model.note_off => disk_note_off,
        else => disk_note_fade,
    };
}

/// A packed stream and what had to give to produce it.
pub const Packed = struct {
    arena: std.heap.ArenaAllocator,
    bytes: []const u8,
    diags: Diag.List,

    pub fn deinit(self: *Packed) void {
        self.diags.deinit();
        self.arena.deinit();
    }
};

/// Dense cells → packed stream, it 05's two-cache scheme.
///
/// `cells` is `rows × 64` row-major; a short slice packs the rows it
/// has. Diagnostic spans are relative to the OUTPUT (a caller that lands
/// the pattern in a file rebases them), because there is no input file to
/// point at — the rows are named in the message instead.
///
/// The parent keeps the row, the output and the ceiling; `maskFor`
/// decides what one cell sends and `writeEntry` spells it.
pub fn pack(gpa: std.mem.Allocator, cells: []const Cell, rows: u16) Error!Packed {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    var cache: [model.channels]Cache = @splat(.{});

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const row_start = out.items.len;
        const base = @as(usize, row) * model.channels;
        if (base >= cells.len) break;

        for (0..model.channels) |channel| {
            const at = base + channel;
            if (at >= cells.len) break;
            const c = &cache[channel];
            const mask = maskFor(cells[at], c);
            if (mask == 0) continue;
            try writeEntry(&out, arena, @intCast(channel), mask, c, cells[at]);
        }
        try out.append(arena, 0);

        if (out.items.len > max_packed) {
            // The refusal has to say WHICH rows to split (it 05's risk
            // note): everything from this row on is dropped, and the
            // pattern keeps the rows that fit.
            out.shrinkRetainingCapacity(row_start);
            try diags.add(
                .it_pattern_too_large,
                .err,
                .{ .start = 0, .end = 0 },
                "a {d}-row pattern packs past IT's 64 KB ceiling; split it at row {d} " ++
                    "(rows {d}–{d} were dropped)",
                .{ rows, row, row, rows - 1 },
            );
            break;
        }
    }

    return .{ .arena = arena_state, .bytes = out.items, .diags = diags };
}

/// The mask one cell packs under, and the cache it leaves behind: a
/// field that is absent sends nothing, one that repeats what the channel
/// last sent is a repeat bit, and anything else is sent and becomes the
/// channel's value (it 05's two caches). Zero for an empty cell.
fn maskFor(cell: Cell, c: *Cache) u8 {
    var mask: u8 = 0;
    if (cell.note != model.note_none) {
        if (c.note_set and c.note == cell.note) {
            mask |= mask_note_repeat;
        } else {
            mask |= mask_note;
            c.note = cell.note;
            c.note_set = true;
        }
    }
    if (cell.ins != 0) {
        if (c.ins_set and c.ins == cell.ins) {
            mask |= mask_ins_repeat;
        } else {
            mask |= mask_ins;
            c.ins = cell.ins;
            c.ins_set = true;
        }
    }
    if (cell.vol != model.vol_none) {
        if (c.vol_set and c.vol == cell.vol) {
            mask |= mask_vol_repeat;
        } else {
            mask |= mask_vol;
            c.vol = cell.vol;
            c.vol_set = true;
        }
    }
    if (cell.fx != 0 or cell.param != 0) {
        if (c.cmd_set and c.fx == cell.fx and c.param == cell.param) {
            mask |= mask_cmd_repeat;
        } else {
            mask |= mask_cmd;
            c.fx = cell.fx;
            c.param = cell.param;
            c.cmd_set = true;
        }
    }
    return mask;
}

/// One channel entry's bytes: the lead, the mask when it differs from
/// the one the channel last sent (which it then becomes), then every
/// field the mask says is sent. `out` grows in the `Packed`'s arena.
fn writeEntry(
    out: *std.ArrayList(u8),
    arena: std.mem.Allocator,
    channel: u8,
    mask: u8,
    c: *Cache,
    cell: Cell,
) Error!void {
    const lead: u8 = channel + 1;
    if (mask != c.mask) {
        try out.append(arena, lead | 0x80);
        try out.append(arena, mask);
        c.mask = mask;
    } else {
        try out.append(arena, lead);
    }
    if (mask & mask_note != 0) try out.append(arena, encodeNote(cell.note));
    if (mask & mask_ins != 0) try out.append(arena, cell.ins);
    if (mask & mask_vol != 0) try out.append(arena, cell.vol);
    if (mask & mask_cmd != 0) {
        try out.append(arena, cell.fx);
        try out.append(arena, cell.param);
    }
}

test "pattern.unpack: ITTECH's mask algorithm over hand-packed rows" {
    const stream = [_]u8{
        // row 0: channel 1 with a new mask (note+ins+vol+cmd), then
        // channel 4 with a note only.
        0x81, 0x0F, 60,   1,    64,   1,    6,
        0x84, 0x01, 62,   0x00,
        // row 1: channel 1 REUSES its mask — no 0x80, no mask byte.
        0x01, 62,   1,
        32,   4,    0x10, 0x00,
        // row 2: a new mask of nothing but repeat bits.
        0x81, 0xF0, 0x00,
    };

    var u = try unpack(testing.allocator, &stream, 3);
    defer u.deinit();

    try testing.expectEqual(@as(usize, 3 * 64), u.cells.len);
    try testing.expectEqual(
        Cell{ .note = 60, .ins = 1, .vol = 64, .fx = 1, .param = 6 },
        u.cells[0],
    );
    try testing.expectEqual(Cell{ .note = 62 }, u.cells[3]);
    try testing.expectEqual(
        Cell{ .note = 62, .ins = 1, .vol = 32, .fx = 4, .param = 0x10 },
        u.cells[64],
    );
    // Every repeat bit read its channel's cache.
    try testing.expectEqual(u.cells[64], u.cells[128]);
    try testing.expectEqual(Cell.empty, u.cells[1]);
    try testing.expectEqual(@as(usize, 0), u.diags.items().len);
}

test "pattern.unpack: ITTECH's note sentinels become tempura's" {
    // Disk 255 is note OFF, 254 is CUT, and anything 120–253 fades
    // (it 05: 246 is what Schism writes).
    const stream = [_]u8{
        0x81, 0x01, 255,  0x00,
        0x01, 254,  0x00, 0x01,
        246,  0x00, 0x01, 200,
        0x00, 0x01, 119,  0x00,
    };

    var u = try unpack(testing.allocator, &stream, 5);
    defer u.deinit();

    try testing.expectEqual(model.note_off, u.cells[0].note);
    try testing.expectEqual(model.note_cut, u.cells[64].note);
    try testing.expectEqual(model.note_fade, u.cells[128].note);
    try testing.expectEqual(model.note_fade, u.cells[192].note);
    try testing.expectEqual(@as(u8, 119), u.cells[256].note);
}

test "pattern.unpack: command bytes 27–31 are no effect with a diagnostic" {
    // Inside ITTECH's 0–31 range, naming no letter: OpenMPT reads its own
    // extensions there, strict IT has nothing (it 04 §"Pattern unpacking").
    const stream = [_]u8{ 0x81, 0x08, 27, 5, 0x00, 0x01, 31, 9, 0x00 };

    var u = try unpack(testing.allocator, &stream, 2);
    defer u.deinit();

    try testing.expectEqual(Cell.empty, u.cells[0]);
    try testing.expectEqual(Cell.empty, u.cells[64]);
    try testing.expectEqual(@as(usize, 2), u.diags.count(.it_command_unknown));
    try testing.expectEqual(Diag.Span{ .start = 2, .end = 4 }, u.diags.items()[0].span);
}

test "pattern.unpack: a stream that ends mid-cell stops where it ran out" {
    const stream = [_]u8{ 0x81, 0x0F, 60, 1 };

    var u = try unpack(testing.allocator, &stream, 2);
    defer u.deinit();

    try testing.expectEqual(@as(usize, 2 * 64), u.cells.len);
    try testing.expectEqual(Cell.empty, u.cells[0]);
    try testing.expectEqual(@as(usize, 1), u.diags.count(.it_truncated));

    // An empty stream is an empty pattern, not a failure.
    var e = try unpack(testing.allocator, &.{}, 64);
    defer e.deinit();
    try testing.expectEqual(@as(usize, 64 * 64), e.cells.len);
    try testing.expectEqual(@as(usize, 0), e.diags.items().len);
}

test "pattern.pack: the two-cache scheme drops repeats and reuses masks" {
    const gpa = testing.allocator;
    var cells: [4 * 64]Cell = @splat(.empty);
    cells[0] = .{ .note = 60, .ins = 1, .vol = 64, .fx = 1, .param = 6 };
    cells[3] = .{ .note = 62 };
    cells[64] = .{ .note = 62, .ins = 1, .vol = 32, .fx = 4, .param = 0x10 };
    cells[128] = cells[64];
    cells[192] = cells[64];

    var p = try pack(gpa, &cells, 4);
    defer p.deinit();

    try testing.expectEqualSlices(u8, &.{
        // row 0: both channels are new, so both send a mask.
        0x81, 0x0F, 60,   1,    64,   1,    6,
        0x84, 0x01, 62,   0x00,
        // row 1: the instrument repeats (b5), the rest is present.
        0x81, 0x2D, 62,
        32,   4,    0x10, 0x00,
        // row 2: every field repeats — a mask of nothing but repeat bits.
        0x81, 0xF0, 0x00,
        // row 3: the same mask again, so no mask byte at all.
        0x01, 0x00,
    }, p.bytes);
    try testing.expectEqual(@as(usize, 0), p.diags.items().len);
}

test "pattern.pack: the note sentinels go back to ITTECH's bytes" {
    const gpa = testing.allocator;
    var cells: [64]Cell = @splat(.empty);
    cells[0] = .{ .note = model.note_off };
    cells[1] = .{ .note = model.note_cut };
    cells[2] = .{ .note = model.note_fade };

    var p = try pack(gpa, &cells, 1);
    defer p.deinit();

    try testing.expectEqualSlices(u8, &.{
        0x81, 0x01, 255,
        0x82, 0x01, 254,
        0x83, 0x01, 246,
        0x00,
    }, p.bytes);
}

test "pattern.pack: round trips — unpack∘pack is identity, pack is a fixed point" {
    const gpa = testing.allocator;

    // Hand-built rows that exercise every cache path: fresh fields,
    // repeated fields, a channel that goes quiet, mask reuse.
    var cells: [8 * 64]Cell = @splat(.empty);
    var prng: std.Random.DefaultPrng = .init(0x1701_D);
    const rand = prng.random();
    for (0..8) |row| {
        for (0..64) |ch| {
            const c = &cells[row * 64 + ch];
            if (rand.boolean()) continue;
            c.note = switch (rand.uintLessThan(u8, 8)) {
                0 => model.note_off,
                1 => model.note_cut,
                2 => model.note_fade,
                3 => model.note_none,
                else => rand.uintLessThan(u8, 120),
            };
            c.ins = if (rand.boolean()) 0 else rand.intRangeAtMost(u8, 1, 99);
            c.vol = if (rand.boolean()) model.vol_none else rand.uintLessThan(u8, 65);
            if (rand.boolean()) {
                c.fx = rand.intRangeAtMost(u8, 1, 26);
                c.param = rand.int(u8);
            }
        }
    }
    // A whole row of one repeated cell, then the same row again.
    for (0..64) |ch| cells[6 * 64 + ch] = .{
        .note = 48,
        .ins = 2,
        .vol = 40,
        .fx = 20,
        .param = 1,
    };
    @memcpy(cells[7 * 64 ..][0..64], cells[6 * 64 ..][0..64]);

    var once = try pack(gpa, &cells, 8);
    defer once.deinit();

    var back = try unpack(gpa, once.bytes, 8);
    defer back.deinit();
    try testing.expectEqualSlices(Cell, &cells, back.cells);

    var twice = try pack(gpa, back.cells, 8);
    defer twice.deinit();
    try testing.expectEqualSlices(u8, once.bytes, twice.bytes);
}

test "pattern.unpack: pseudo-random streams never panic, and re-pack" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x9E37_79B9);
    const rand = prng.random();

    var buf: [256]u8 = undefined;
    for (0..64) |_| {
        const n = rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        const rows = rand.intRangeAtMost(u16, 1, 64);

        var u = try unpack(gpa, buf[0..n], rows);
        defer u.deinit();
        try testing.expectEqual(@as(usize, rows) * model.channels, u.cells.len);

        // Whatever came out of noise still packs, and unpacks to itself.
        var p = try pack(gpa, u.cells, rows);
        defer p.deinit();
        var again = try unpack(gpa, p.bytes, rows);
        defer again.deinit();
        try testing.expectEqualSlices(Cell, u.cells, again.cells);
    }
}

test "pattern.pack: the 64 KB ceiling names the rows to split" {
    const gpa = testing.allocator;

    const rows = 200;
    const cells = try gpa.alloc(Cell, rows * 64);
    defer gpa.free(cells);
    for (cells, 0..) |*c, i| {
        c.* = .{
            .note = @intCast(i % 120),
            .ins = @intCast(1 + i % 99),
            .vol = @intCast(i % 65),
            .fx = @intCast(1 + i % 26),
            .param = @intCast(i % 256),
        };
    }

    var p = try pack(gpa, cells, rows);
    defer p.deinit();

    try testing.expectEqual(@as(usize, 1), p.diags.count(.it_pattern_too_large));
    try testing.expect(p.bytes.len <= max_packed);
    // The message says where to split.
    try testing.expect(std.mem.indexOf(u8, p.diags.items()[0].message, "row") != null);
}
