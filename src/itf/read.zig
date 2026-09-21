//! `.it` bytes → `Module`, `SourceMap` and diagnostics.
//!
//! Bounded everywhere: every read is against a slice with an explicit
//! end, every count is clamped to a spec maximum, and a malformed file
//! yields diagnostics plus a best-effort `Module` — never a crash, never
//! an error (it 04 §"Robustness rules"; plan 01's collection-over-abort
//! discipline). The only failure is running out of memory.
//!
//! What is materialised is what carries time; everything else becomes a
//! `Region` into the bytes that were read, recorded on the `SourceMap` so
//! the document bridge can spell `(bin :at :len)` against the anchor
//! (it 03). Diagnostic spans are byte offsets into those same bytes.

const std = @import("std");
const Diag = @import("../Diag.zig");
const model = @import("Module.zig");
const pattern = @import("pattern.zig");
const regions = @import("regions.zig");

const Cell = model.Cell;
const Module = model.Module;
const Region = model.Region;
const hdr = model.hdr;
const testing = std.testing;

/// Only resource exhaustion is an error (plan 01).
pub const Error = error{OutOfMemory};

// ---- Reader-side caps. Generous on purpose: these keep a malformed
// header from asking for an unbounded walk, while the STRICT IT limits
// (99 instruments, 200 patterns…) are the WRITER's, where refusing is
// the right answer (it 04 §"Robustness rules", it 05 §"Strict clamps").

/// IT's order list is at most 256 entries.
pub const max_orders: u16 = 256;
/// it 04 §Header: `InsNum ≤ 255`.
pub const max_instruments: u16 = 255;
/// it 04 §Header: Schism's `MAX_SAMPLES` practical bound.
pub const max_samples: u16 = 236;
/// OpenMPT's itEx bound (it 04/05).
pub const max_patterns: u16 = 240;
/// it 04 §"Pattern unpacking": 32–200 strict, 1–1024 accepted with a
/// diagnostic.
pub const max_pattern_rows: u16 = 1024;
const strict_rows_min: u16 = 32;
const strict_rows_max: u16 = 200;
/// A pattern with no parapointer is synthesised at this height — the one
/// shape `model.empty_pattern_rows` names, shared with the writer so the
/// two cannot drift.
const empty_pattern_rows: u16 = model.empty_pattern_rows;

/// Where every region the reader honoured came from — it 03's `(bin :at
/// :len)` material, and `--spans` for materialised forms.
pub const SourceMap = struct {
    pub const Kind = enum {
        header,
        orders,
        /// The three parapointer arrays, as one run.
        parapointers,
        edit_history,
        midi_config,
        message,
        instrument,
        sample_header,
        sample_data,
        pattern,
        foreign,
        /// tempura's own residue chunk's payload.
        tmpu,
    };

    pub const Entry = struct {
        kind: Kind,
        /// The record's index within its kind (0 for the singletons).
        index: u32 = 0,
        region: Region,
    };

    /// In reading order. Borrowed from the module's arena — valid until
    /// `Result.deinit`.
    entries: []const Entry = &.{},

    pub fn find(self: SourceMap, kind: Kind, index: u32) ?Region {
        for (self.entries) |e| {
            if (e.kind == kind and e.index == index) return e.region;
        }
        return null;
    }
};

/// What `read` returns: the module, the map of what came from where, and
/// everything that was wrong with the file.
pub const Result = struct {
    module: Module,
    source_map: SourceMap,
    diags: Diag.List,

    pub fn deinit(self: *Result) void {
        self.diags.deinit();
        self.module.deinit();
    }
};

/// Reads `bytes` as an Impulse Tracker module.
///
/// The module's opaque regions point INTO `bytes`, which the caller keeps
/// owning: a `Module` is only meaningful against the file it was read
/// from (it 03, "The anchor").
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) Error!Result {
    var module: Module = .init(gpa);
    errdefer module.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    // IT offsets are u32 by construction; anything past 4 GiB cannot be
    // pointed at, so it cannot be read either.
    const src = bytes[0..@min(bytes.len, std.math.maxInt(u32))];

    var map: std.ArrayList(SourceMap.Entry) = .empty;
    var r: Reader = .{
        .gpa = gpa,
        .src = src,
        .arena = module.allocator(),
        .module = &module,
        .diags = &diags,
        .map = &map,
    };
    try r.run();

    const result: Result = .{
        .module = module,
        .source_map = .{ .entries = map.items },
        .diags = diags,
    };
    result.module.invariants();
    postconditions(&result, src.len);
    return result;
}

/// What the READER establishes over and above `Module.invariants()`,
/// asserted once per `read` (plan 12, "The invariants"): the record
/// counts are inside the reader's caps; every pattern is 1..1024 rows (a
/// height the header could not be trusted on became the empty 64);
/// every cell's note is a pitch or one of tempura's four sentinels and
/// its command one ITTECH names (`pattern.unpack`'s tables); a MIDI
/// configuration the module carries is the block's whole 4896 bytes;
/// and every region on the map lies inside the bytes that were read.
/// Properties of the reader's own clamps and tables, never of the file:
/// random bytes satisfy them.
fn postconditions(result: *const Result, len: usize) void {
    const m = &result.module;
    std.debug.assert(m.orders.len <= max_orders);
    std.debug.assert(m.instruments.len <= max_instruments);
    std.debug.assert(m.samples.len <= max_samples);
    std.debug.assert(m.patterns.len <= max_patterns);
    for (m.patterns) |p| {
        std.debug.assert(p.rows >= 1);
        std.debug.assert(p.rows <= max_pattern_rows);
        for (p.cells) |c| {
            std.debug.assert(c.note <= model.note_max or c.note >= model.note_fade);
            std.debug.assert(c.fx <= pattern.cmd_max);
        }
    }
    if (m.midi_config_bytes) |block| std.debug.assert(block.len == model.midi_config_size);
    for (result.source_map.entries) |e| std.debug.assert(e.region.end() <= len);
}

/// The parse in progress. Every read goes through the bounded accessors
/// below, so no path can leave `src`.
const Reader = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    arena: std.mem.Allocator,
    module: *Module,
    diags: *Diag.List,
    map: *std.ArrayList(SourceMap.Entry),
    /// One past the last byte any honoured region covers — where the
    /// trailing chunks begin.
    high_water: u32 = 0,

    fn len(self: *const Reader) u32 {
        return @intCast(self.src.len);
    }

    fn byteAt(self: *const Reader, off: u32) u8 {
        return if (off < self.src.len) self.src[off] else 0;
    }

    fn wordAt(self: *const Reader, off: u32) u16 {
        if (@as(u64, off) + 2 > self.src.len) return 0;
        return std.mem.readInt(u16, self.src[off..][0..2], .little);
    }

    fn dwordAt(self: *const Reader, off: u32) u32 {
        if (@as(u64, off) + 4 > self.src.len) return 0;
        return std.mem.readInt(u32, self.src[off..][0..4], .little);
    }

    fn note(
        self: *Reader,
        code: Diag.Code,
        severity: Diag.Severity,
        span: Diag.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        try self.diags.add(code, severity, span, fmt, args);
    }

    fn mark(self: *Reader, kind: SourceMap.Kind, index: u32, region: Region) Error!void {
        try self.map.append(self.arena, .{ .kind = kind, .index = index, .region = region });
        self.consume(region);
    }

    /// Spoken for, but not a region of the module: the bytes count
    /// against the trailing-chunk scan without appearing on the map. The
    /// default MIDI configuration is the one case — it is there, and the
    /// module deliberately records nothing (it 03).
    fn consume(self: *Reader, region: Region) void {
        const end: u32 = @intCast(@min(region.end(), self.len()));
        if (end > self.high_water) self.high_water = end;
    }

    fn run(self: *Reader) Error!void {
        if (!try self.readHeader()) return;
        const orders_end = try self.readOrders();
        const pointers = try self.readParapointers(orders_end);
        const after_history = try self.readEditHistory(pointers);
        try self.readMidiConfig(after_history);
        try self.readMessage();
        try self.readInstruments(pointers);
        try self.readSamples(pointers);
        try self.readPatterns(pointers);
        try self.readTail();
    }

    /// The 192-byte header. Returns false when the file is not an IT at
    /// all — the one condition that stops the parse.
    fn readHeader(self: *Reader) Error!bool {
        const n = self.len();
        if (n < 4) {
            try self.note(.it_truncated, .err, .{ .start = 0, .end = n }, "an IT file is 192 bytes of header; this one is {d}", .{n});
            return false;
        }
        if (!std.mem.eql(u8, self.src[0..4], "IMPM")) {
            try self.note(.it_bad_magic, .err, .{ .start = 0, .end = 4 }, "expected the magic 'IMPM', found '{f}'", .{std.ascii.hexEscape(self.src[0..4], .lower)});
            return false;
        }

        // A short header is read from a zero-padded copy: the fields that
        // are there are honoured, the rest read as zero.
        var raw: [model.header_size]u8 = @splat(0);
        const have: u32 = @min(n, model.header_size);
        @memcpy(raw[0..have], self.src[0..have]);
        if (n < model.header_size) {
            try self.note(.it_truncated, .err, .{ .start = 0, .end = n }, "the header needs 192 bytes; the file ends after {d}", .{n});
        }

        var h: model.Header = .blank;
        h.raw = raw;
        @memcpy(&h.title, raw[hdr.title..][0..26]);
        h.highlight_minor = raw[hdr.highlight_minor];
        h.highlight_major = raw[hdr.highlight_major];
        h.ord_num = std.mem.readInt(u16, raw[hdr.ord_num..][0..2], .little);
        h.ins_num = std.mem.readInt(u16, raw[hdr.ins_num..][0..2], .little);
        h.smp_num = std.mem.readInt(u16, raw[hdr.smp_num..][0..2], .little);
        h.pat_num = std.mem.readInt(u16, raw[hdr.pat_num..][0..2], .little);
        h.cwtv = std.mem.readInt(u16, raw[hdr.cwtv..][0..2], .little);
        h.cmwt = std.mem.readInt(u16, raw[hdr.cmwt..][0..2], .little);
        h.flags = std.mem.readInt(u16, raw[hdr.flags..][0..2], .little);
        h.special = std.mem.readInt(u16, raw[hdr.special..][0..2], .little);
        h.global_volume = raw[hdr.global_volume];
        h.mix_volume = raw[hdr.mix_volume];
        h.initial_speed = raw[hdr.initial_speed];
        h.initial_tempo = raw[hdr.initial_tempo];
        h.pan_separation = raw[hdr.pan_separation];
        h.pitch_wheel_depth = raw[hdr.pitch_wheel_depth];
        h.message_length = std.mem.readInt(u16, raw[hdr.message_length..][0..2], .little);
        h.message_offset = std.mem.readInt(u32, raw[hdr.message_offset..][0..4], .little);
        h.reserved = std.mem.readInt(u32, raw[hdr.reserved..][0..4], .little);
        @memcpy(&h.channel_pan, raw[hdr.channel_pan..][0..64]);
        @memcpy(&h.channel_vol, raw[hdr.channel_vol..][0..64]);
        self.module.header = h;

        try self.mark(.header, 0, .{ .off = 0, .len = have });
        return true;
    }

    /// The order list, right after the header. Returns where it ends —
    /// where the parapointers begin.
    fn readOrders(self: *Reader) Error!u32 {
        const h = self.module.header;
        const want: u32 = try self.clampCount(h.ord_num, max_orders, hdr.ord_num, "orders");
        const available: u32 = if (self.len() > hdr.orders) self.len() - hdr.orders else 0;
        const take: u32 = @min(want, available);
        if (take < want) {
            try self.note(.it_truncated, .err, .{ .start = hdr.orders, .end = self.len() }, "the order list wants {d} bytes; {d} are there", .{ want, available });
        }
        if (take > 0) {
            self.module.orders = try self.arena.dupe(u8, self.src[hdr.orders..][0..take]);
            try self.mark(.orders, 0, .{ .off = hdr.orders, .len = take });
        }
        // The NEXT section sits after the order list the HEADER declared,
        // whatever tempura kept of it.
        return @intCast(@min(@as(u64, hdr.orders) + h.ord_num, self.len()));
    }

    /// The three parapointer arrays: instruments, samples, patterns.
    const Pointers = struct {
        ins: u32,
        smp: u32,
        pat: u32,
        /// Where the arrays end — where the edit history would start.
        end: u32,
        /// The lowest byte anything points at (it 04's history guard).
        min_ptr: u32,
    };

    fn readParapointers(self: *Reader, at: u32) Error!Pointers {
        const h = self.module.header;
        // The clamps are raised HERE, once, so the record loops below can
        // simply take the first `cap` of each kind.
        _ = try self.clampCount(h.ins_num, max_instruments, hdr.ins_num, "instruments");
        _ = try self.clampCount(h.smp_num, max_samples, hdr.smp_num, "samples");
        _ = try self.clampCount(h.pat_num, max_patterns, hdr.pat_num, "patterns");

        // Positions follow the HEADER's counts, since that is how the
        // file was laid out, even when tempura keeps fewer records.
        const declared: u64 = (@as(u64, h.ins_num) + h.smp_num + h.pat_num) * 4;
        const end: u32 = @intCast(@min(@as(u64, at) + declared, self.len()));
        if (declared > 0) {
            if (@as(u64, at) + declared > self.len()) {
                try self.note(.it_truncated, .err, .{ .start = at, .end = self.len() }, "the parapointer arrays want {d} bytes; the file ends first", .{declared});
            }
            try self.mark(.parapointers, 0, .{ .off = at, .len = end - at });
        }

        var p: Pointers = .{
            .ins = at,
            .smp = at + @as(u32, h.ins_num) * 4,
            .pat = at + (@as(u32, h.ins_num) + h.smp_num) * 4,
            .end = end,
            .min_ptr = 0,
        };

        var min: regions.MinPointer = .init(self.len());
        var i: u32 = 0;
        while (i < @as(u32, h.ins_num) + h.smp_num + h.pat_num) : (i += 1) {
            min.offer(self.dwordAt(at + i * 4));
        }
        min.offer(h.message_offset);
        p.min_ptr = min.value;
        return p;
    }

    /// The edit-history block, with it 04's flag-without-block guard.
    /// Returns where the MIDI configuration would start.
    fn readEditHistory(self: *Reader, p: Pointers) Error!u32 {
        switch (regions.editHistory(self.src, p.end, self.module.header.special, p.min_ptr)) {
            .absent => return p.end,
            .flag_without_block => {
                try self.note(
                    .it_history_flag_without_block,
                    .warning,
                    .{ .start = p.end, .end = @min(p.end + 2, self.len()) },
                    "Special b1 claims an edit-history block that does not fit before offset {d}; read as absent",
                    .{p.min_ptr},
                );
                return p.end;
            },
            .present => |region| {
                self.module.edit_history = region;
                try self.mark(.edit_history, 0, region);
                return @intCast(region.end());
            },
        }
    }

    fn readMidiConfig(self: *Reader, at: u32) Error!void {
        const h = self.module.header;
        switch (regions.midiConfig(self.src, at, h.flags, h.special)) {
            .absent => {},
            .default_table => |region| self.consume(region),
            .truncated => try self.note(
                .it_truncated,
                .err,
                .{ .start = at, .end = self.len() },
                "an embedded MIDI configuration is flagged at offset {d}; the file ends first",
                .{at},
            ),
            .present => |region| {
                self.module.midi_config = region;
                // The bytes too: the document bridge spells the block's
                // slots and has no anchor to slice, so a read module
                // carries what a built one would (`Module.midi_config_bytes`).
                // `regions.midiConfig` already proved the region fits.
                self.module.midi_config_bytes = try self.arena.dupe(u8, self.src[region.off..][0..region.len]);
                try self.mark(.midi_config, 0, region);
            },
        }
    }

    /// The song message: `MsgLgth` bytes at `MsgOffset`, CR newlines, NUL
    /// terminating (it 04 §"Robustness rules").
    fn readMessage(self: *Reader) Error!void {
        const h = self.module.header;
        if (h.message_length == 0 or h.message_offset == 0) return;

        const want = h.message_length;
        const declared: Region = .{ .off = h.message_offset, .len = want };
        if (declared.end() > self.len()) {
            try self.note(.it_truncated, .warning, .{ .start = h.message_offset, .end = self.len() }, "the song message wants {d} bytes at offset {d}; the file ends first", .{ want, h.message_offset });
        }
        if (h.message_offset >= self.len()) return;

        const available: u32 = @intCast(@min(want, self.len() - h.message_offset));
        const raw = self.src[h.message_offset..][0..available];
        const text = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];
        self.module.message = try self.arena.dupe(u8, text);
        try self.mark(.message, 0, .{ .off = h.message_offset, .len = available });
    }

    fn readInstruments(self: *Reader, p: Pointers) Error!void {
        const count = @min(self.module.header.ins_num, max_instruments);
        if (count == 0) return;
        const list = try self.arena.alloc(model.Opaque, count);
        @memset(list, .{});

        for (list, 0..) |*slot, i| {
            const field = p.ins + @as(u32, @intCast(i)) * 4;
            const at = self.dwordAt(field);
            if (at == 0) continue; // a blank slot, not an error (it 04)
            const region: Region = .{ .off = at, .len = model.instrument_size };
            if (region.end() > self.len()) {
                try self.outOfRange(field, at, "instrument", i);
                continue;
            }
            slot.raw = region;
            @memcpy(&slot.name, self.src[at + model.ins.name ..][0..26]);
            try self.mark(.instrument, @intCast(i), region);
        }
        self.module.instruments = list;
    }

    fn readSamples(self: *Reader, p: Pointers) Error!void {
        const count = @min(self.module.header.smp_num, max_samples);
        if (count == 0) return;
        const list = try self.arena.alloc(model.Sample, count);
        @memset(list, .{});

        for (list, 0..) |*slot, i| {
            const field = p.smp + @as(u32, @intCast(i)) * 4;
            const at = self.dwordAt(field);
            if (at == 0) continue;
            const region: Region = .{ .off = at, .len = model.sample_header_size };
            if (region.end() > self.len()) {
                try self.outOfRange(field, at, "sample header", i);
                continue;
            }
            slot.raw = region;
            @memcpy(&slot.name, self.src[at + model.smp.name ..][0..26]);
            try self.mark(.sample_header, @intCast(i), region);

            const flags = self.byteAt(at + model.smp.flags);
            const convert = self.byteAt(at + model.smp.convert);
            const frames = self.dwordAt(at + model.smp.length);
            const data_at = self.dwordAt(at + model.smp.sample_pointer);

            slot.bits = if (flags & model.sample_flag.bits16 != 0) 16 else 8;
            // The stereo flag is only honoured from Cwt/v 0x214 — older
            // ITs left it set spuriously (it 04 §Samples).
            slot.channels = if (flags & model.sample_flag.stereo != 0 and
                self.module.header.cwtv >= 0x0214) 2 else 1;
            slot.enc = if (convert == model.sample_convert.adpcm)
                .adpcm
            else if (flags & model.sample_flag.compressed != 0)
                (if (convert & model.sample_convert.delta != 0) .it215 else .it214)
            else
                .pcm;

            if (flags & model.sample_flag.has_data == 0 or frames == 0 or data_at == 0) continue;
            if (data_at >= self.len()) {
                try self.outOfRange(at + model.smp.sample_pointer, data_at, "sample data", i);
                continue;
            }

            const extent = regions.sampleExtent(self.src, data_at, .{
                .frames = frames,
                .bits = slot.bits,
                .channels = slot.channels,
                .enc = slot.enc,
            });
            if (extent.truncated) {
                try self.note(
                    .it_sample_extent_truncated,
                    .warning,
                    .{ .start = data_at, .end = self.len() },
                    "sample {d}'s data runs past the end of the file; kept at {d} bytes",
                    .{ i, extent.region.len },
                );
            }
            slot.data = extent.region;
            try self.mark(.sample_data, @intCast(i), extent.region);
        }
        self.module.samples = list;
    }

    fn readPatterns(self: *Reader, p: Pointers) Error!void {
        const count = @min(self.module.header.pat_num, max_patterns);
        if (count == 0) return;
        const list = try self.arena.alloc(model.Pattern, count);

        for (list, 0..) |*slot, i| {
            const field = p.pat + @as(u32, @intCast(i)) * 4;
            const at = self.dwordAt(field);
            // Parapointer 0 is an empty 64-row pattern — synthesised,
            // never sought (it 04 §"Pattern unpacking").
            if (at == 0) {
                slot.* = try self.emptyPattern(empty_pattern_rows);
                continue;
            }
            if (@as(u64, at) + 8 > self.len()) {
                try self.outOfRange(field, at, "pattern", i);
                slot.* = try self.emptyPattern(empty_pattern_rows);
                continue;
            }

            const packed_len = self.wordAt(at);
            const rows = self.wordAt(at + 2);
            if (rows == 0 or rows > max_pattern_rows) {
                try self.note(
                    .it_pattern_rows_out_of_range,
                    .err,
                    .{ .start = at + 2, .end = at + 4 },
                    "pattern {d} claims {d} rows, outside the 1–{d} a reader can honour; read as empty",
                    .{ i, rows, max_pattern_rows },
                );
                slot.* = try self.emptyPattern(empty_pattern_rows);
                continue;
            }
            if (rows < strict_rows_min or rows > strict_rows_max) {
                try self.note(
                    .it_pattern_rows_out_of_range,
                    .warning,
                    .{ .start = at + 2, .end = at + 4 },
                    "pattern {d} has {d} rows, outside IT's strict {d}–{d}",
                    .{ i, rows, strict_rows_min, strict_rows_max },
                );
            }

            const data_at = at + 8;
            var end: u64 = @as(u64, data_at) + packed_len;
            if (end > self.len()) {
                try self.note(
                    .it_truncated,
                    .warning,
                    .{ .start = data_at, .end = self.len() },
                    "pattern {d} declares {d} packed bytes; the file ends first",
                    .{ i, packed_len },
                );
                end = self.len();
            }

            var unpacked = try pattern.unpack(self.gpa, self.src[data_at..@intCast(end)], rows);
            defer unpacked.deinit();
            for (unpacked.diags.items()) |d| {
                try self.note(d.code, d.severity, .{
                    .start = data_at + d.span.start,
                    .end = data_at + d.span.end,
                }, "{s}", .{d.message});
            }
            slot.* = .{ .rows = rows, .cells = try self.arena.dupe(Cell, unpacked.cells) };
            try self.mark(.pattern, @intCast(i), .{ .off = at, .len = @intCast(end - at) });
        }
        self.module.patterns = list;
    }

    /// Everything after the last region anything points at: another
    /// tracker's chunks, then tempura's own `TMPU` (plan 04, "The IT
    /// carriers").
    ///
    /// OpenMPT's extension chunks have no uniform length header (it 03),
    /// so the foreign area is NOT parsed: it is kept as one verbatim
    /// region tagged with its first four bytes, which is all the writer
    /// needs to put it back. `TMPU` is tempura's own framing and is
    /// recognised only when its chunk ends exactly at the end of the file
    /// — where the canonical writer puts it.
    fn readTail(self: *Reader) Error!void {
        const n = self.len();
        var start = self.high_water;
        if (start >= n) return;

        var tmpu_at: ?u32 = null;
        var tmpu_len: u32 = 0;
        var p = start;
        while (@as(u64, p) + 8 <= n) : (p += 1) {
            if (!std.mem.eql(u8, self.src[p..][0..4], "TMPU")) continue;
            const payload = self.dwordAt(p + 4);
            if (@as(u64, p) + 8 + payload == n) {
                tmpu_at = p;
                tmpu_len = payload;
                break;
            }
        }

        const foreign_end = tmpu_at orelse n;
        if (foreign_end > start) {
            const region: Region = .{ .off = start, .len = foreign_end - start };
            var tag: [4]u8 = @splat(0);
            const have = @min(@as(usize, 4), region.len);
            @memcpy(tag[0..have], self.src[start..][0..have]);
            const list = try self.arena.alloc(model.Foreign, 1);
            list[0] = .{ .tag = tag, .raw = region };
            self.module.foreign = list;
            try self.mark(.foreign, 0, region);
            start = foreign_end;
        }

        if (tmpu_at) |at| {
            const payload: Region = .{ .off = at + 8, .len = tmpu_len };
            self.module.tmpu = payload;
            try self.mark(.tmpu, 0, payload);
        }
    }

    fn emptyPattern(self: *Reader, rows: u16) Error!model.Pattern {
        const cells = try self.arena.alloc(Cell, @as(usize, rows) * model.channels);
        @memset(cells, .empty);
        return .{ .rows = rows, .cells = cells };
    }

    fn clampCount(self: *Reader, count: u16, cap: u16, field: u32, comptime what: []const u8) Error!u16 {
        if (count <= cap) return count;
        try self.note(
            .it_count_exceeds_spec,
            .warning,
            .{ .start = field, .end = field + 2 },
            "the header declares {d} " ++ what ++ ", past the {d} a reader honours",
            .{ count, cap },
        );
        return cap;
    }

    fn outOfRange(self: *Reader, field: u32, at: u32, comptime what: []const u8, index: usize) Error!void {
        try self.note(
            .it_parapointer_out_of_range,
            .warning,
            .{ .start = field, .end = field + 4 },
            what ++ " {d} points at offset {d}, past the end of a {d}-byte file",
            .{ index, at, self.len() },
        );
    }
};

// Test support only: the shared `.it` byte writer (see
// `test_support.zig`); nothing in the reader's own surface uses it.
const Fixture = @import("test_support.zig").Fixture;

/// The packed stream of the minimal fixture's only pattern: one note on
/// channel 1 of row 0, every other row empty.
const minimal_stream = [_]u8{ 0x81, 0x03, 60, 1, 0x00 };

/// The fixture plan 06's phase 1 names: a module with a header, two
/// orders and one pattern, and nothing else.
fn minimal(gpa: std.mem.Allocator) ![]u8 {
    var f: Fixture = .init(gpa);
    defer f.deinit();

    try f.header(.{ .ord = 2, .pat = 1 });
    try f.blob(&.{ 0, 255 });
    const pat_pp = f.here();
    try f.dword(0);

    f.patchDword(pat_pp, f.here());
    try f.word(minimal_stream.len);
    try f.word(64);
    try f.zeros(4);
    try f.blob(&minimal_stream);

    return f.toOwned();
}

test "read: a hand-built minimal module parses" {
    const gpa = testing.allocator;
    const bytes = try minimal(gpa);
    defer gpa.free(bytes);

    var r = try read(gpa, bytes);
    defer r.deinit();

    try testing.expect(!r.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), r.diags.items().len);

    const h = r.module.header;
    try testing.expectEqual(@as(u16, 2), h.ord_num);
    try testing.expectEqual(@as(u16, 1), h.pat_num);
    try testing.expectEqual(@as(u8, 4), h.highlight_minor);
    try testing.expectEqual(@as(u8, 16), h.highlight_major);
    try testing.expectEqual(@as(u8, 6), h.initial_speed);
    try testing.expectEqual(@as(u8, 125), h.initial_tempo);
    try testing.expectEqual(@as(u8, 128), h.global_volume);
    try testing.expectEqual(@as(u8, 32), h.channel_pan[0]);
    try testing.expectEqual(@as(u8, 64), h.channel_vol[63]);
    try testing.expectEqualSlices(u8, bytes[0..192], &h.raw);

    try testing.expectEqualSlices(u8, &.{ 0, 255 }, r.module.orders);
    try testing.expectEqual(@as(usize, 1), r.module.patterns.len);
    try testing.expectEqual(@as(u16, 64), r.module.patterns[0].rows);
    try testing.expectEqual(Cell{ .note = 60, .ins = 1 }, r.module.patterns[0].at(0, 0).*);
    try testing.expectEqual(Cell.empty, r.module.patterns[0].at(1, 0).*);

    // Every region the reader honoured is on the map.
    try testing.expectEqual(Region{ .off = 0, .len = 192 }, r.source_map.find(.header, 0).?);
    try testing.expectEqual(Region{ .off = 0xC0, .len = 2 }, r.source_map.find(.orders, 0).?);
    try testing.expectEqual(Region{ .off = 0xC2, .len = 4 }, r.source_map.find(.parapointers, 0).?);
    try testing.expectEqual(Region{ .off = 0xC6, .len = 8 + minimal_stream.len }, r.source_map.find(.pattern, 0).?);
}

test "read: IMPM is the gate, and a short file is truncated, never a crash" {
    const gpa = testing.allocator;

    var bad = try minimal(gpa);
    defer gpa.free(bad);
    bad[3] = 'X';
    var r = try read(gpa, bad);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diags.count(.it_bad_magic));
    try testing.expect(r.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), r.module.patterns.len);

    var empty = try read(gpa, "");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 1), empty.diags.count(.it_truncated));

    var stub = try read(gpa, "IMPM" ++ ([_]u8{0} ** 20));
    defer stub.deinit();
    try testing.expectEqual(@as(usize, 1), stub.diags.count(.it_truncated));
    try testing.expectEqual(@as(usize, 0), stub.module.orders.len);
}

test "read: counts past the spec maxima are clamped with a diagnostic" {
    const gpa = testing.allocator;
    var f: Fixture = .init(gpa);
    defer f.deinit();

    try f.header(.{ .ord = 2, .ins = 300 });
    try f.blob(&.{ 0, 255 });
    try f.zeros(300 * 4);
    const bytes = try f.toOwned();
    defer gpa.free(bytes);

    var r = try read(gpa, bytes);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.diags.count(.it_count_exceeds_spec));
    try testing.expectEqual(@as(usize, max_instruments), r.module.instruments.len);
    // The header keeps what the file said; the SLICES are what was read.
    try testing.expectEqual(@as(u16, 300), r.module.header.ins_num);
}

test "read: parapointer 0 is an empty 64-row pattern, out of range is a diagnostic" {
    const gpa = testing.allocator;
    var f: Fixture = .init(gpa);
    defer f.deinit();

    try f.header(.{ .ord = 2, .ins = 1, .pat = 2 });
    try f.blob(&.{ 0, 255 });
    const ins_pp = f.here();
    try f.dword(0xDEAD_BEEF);
    try f.dword(0); // pattern 0: synthesised, never sought
    try f.dword(0xCAFE_0000); // pattern 1: past the end
    _ = ins_pp;
    const bytes = try f.toOwned();
    defer gpa.free(bytes);

    var r = try read(gpa, bytes);
    defer r.deinit();

    // The instrument and the second pattern are both out of range.
    try testing.expectEqual(@as(usize, 2), r.diags.count(.it_parapointer_out_of_range));
    try testing.expectEqual(@as(usize, 1), r.module.instruments.len);
    try testing.expect(r.module.instruments[0].raw.isEmpty());

    try testing.expectEqual(@as(usize, 2), r.module.patterns.len);
    for (r.module.patterns) |p| {
        try testing.expectEqual(@as(u16, 64), p.rows);
        try testing.expect(p.isEmpty());
    }
    try testing.expectEqual(@as(?Region, null), r.source_map.find(.pattern, 0));
}

test "read: rows outside 32–200 are accepted to 1024 with a diagnostic" {
    const gpa = testing.allocator;

    for ([_]u16{ 16, 512 }) |rows| {
        var f: Fixture = .init(gpa);
        defer f.deinit();
        try f.header(.{ .ord = 2, .pat = 1 });
        try f.blob(&.{ 0, 255 });
        const pp = f.here();
        try f.dword(0);
        f.patchDword(pp, f.here());
        try f.word(1);
        try f.word(rows);
        try f.zeros(4);
        try f.blob(&.{0x00});
        const bytes = try f.toOwned();
        defer gpa.free(bytes);

        var r = try read(gpa, bytes);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.diags.count(.it_pattern_rows_out_of_range));
        try testing.expectEqual(rows, r.module.patterns[0].rows);
    }

    // Past the itEx bound the header is not trusted at all: an empty
    // 64-row pattern, the same answer as a zero parapointer.
    var f: Fixture = .init(gpa);
    defer f.deinit();
    try f.header(.{ .ord = 2, .pat = 1 });
    try f.blob(&.{ 0, 255 });
    const pp = f.here();
    try f.dword(0);
    f.patchDword(pp, f.here());
    try f.word(1);
    try f.word(4000);
    try f.zeros(4);
    try f.blob(&.{0x00});
    const bytes = try f.toOwned();
    defer gpa.free(bytes);

    var r = try read(gpa, bytes);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diags.count(.it_pattern_rows_out_of_range));
    try testing.expectEqual(@as(u16, 64), r.module.patterns[0].rows);
}

test "read: the edit-history guard — a flag without a block" {
    const gpa = testing.allocator;

    // Special b1 set, and a count that would run the block over the
    // first parapointer: old Schism's bug (it 04's guard).
    var f: Fixture = .init(gpa);
    defer f.deinit();
    try f.header(.{ .ord = 2, .pat = 1, .special = model.special.edit_history });
    try f.blob(&.{ 0, 255 });
    const pp = f.here();
    try f.dword(0);
    // What sits where the history block would be is the pattern header's
    // first bytes — a "count" of 5 blocks, past the pattern's own start.
    f.patchDword(pp, f.here());
    try f.word(5);
    try f.word(64);
    try f.zeros(4);
    try f.blob(&minimal_stream);
    const bytes = try f.toOwned();
    defer gpa.free(bytes);

    var r = try read(gpa, bytes);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diags.count(.it_history_flag_without_block));
    try testing.expectEqual(@as(?Region, null), r.module.edit_history);
    // The pattern is still read: the guard rewinds, it does not give up.
    try testing.expectEqual(Cell{ .note = 60, .ins = 1 }, r.module.patterns[0].at(0, 0).*);

    // A block that fits is kept whole.
    var g: Fixture = .init(gpa);
    defer g.deinit();
    try g.header(.{ .ord = 2, .pat = 1, .special = model.special.edit_history });
    try g.blob(&.{ 0, 255 });
    const pp2 = g.here();
    try g.dword(0);
    const history_at = g.here();
    try g.word(2);
    try g.zeros(16);
    g.patchDword(pp2, g.here());
    try g.word(minimal_stream.len);
    try g.word(64);
    try g.zeros(4);
    try g.blob(&minimal_stream);
    const kept = try g.toOwned();
    defer gpa.free(kept);

    var k = try read(gpa, kept);
    defer k.deinit();
    try testing.expectEqual(@as(usize, 0), k.diags.items().len);
    try testing.expectEqual(Region{ .off = history_at, .len = 18 }, k.module.edit_history.?);
}

test "read: the message is read at MsgOffset, CR kept, NUL terminating" {
    const gpa = testing.allocator;
    var f: Fixture = .init(gpa);
    defer f.deinit();

    try f.header(.{ .ord = 2, .special = model.special.message });
    try f.blob(&.{ 0, 255 });
    const message_at = f.here();
    try f.blob("hello\rworld\x00trailing");
    f.patchWord(hdr.message_length, 20);
    f.patchDword(hdr.message_offset, message_at);
    const bytes = try f.toOwned();
    defer gpa.free(bytes);

    var r = try read(gpa, bytes);
    defer r.deinit();
    try testing.expectEqualStrings("hello\rworld", r.module.message);
    try testing.expectEqual(Region{ .off = message_at, .len = 20 }, r.source_map.find(.message, 0).?);
}

test "read: sample extents dispatch on the encoding, truncation is recorded" {
    const gpa = testing.allocator;
    var f: Fixture = .init(gpa);
    defer f.deinit();

    try f.header(.{ .ord = 2, .ins = 1, .smp = 4 });
    try f.blob(&.{ 0, 255 });
    const ins_pp = f.here();
    try f.dword(0);
    const smp_pp = f.here();
    try f.zeros(4 * 4);

    f.patchDword(ins_pp, f.here());
    _ = try f.instrument("piano");

    // 0: 16-bit PCM, 8 frames. 1: ADPCM, 16 frames. 2: IT215, 40000
    // frames in two blocks. 3: compressed and truncated.
    var headers: [4]u32 = undefined;
    headers[0] = try f.sampleHeader(.{ .name = "pcm", .flags = model.sample_flag.has_data | model.sample_flag.bits16, .length = 8 });
    headers[1] = try f.sampleHeader(.{ .name = "adpcm", .convert = model.sample_convert.adpcm, .length = 16 });
    headers[2] = try f.sampleHeader(.{
        .name = "it215",
        .flags = model.sample_flag.has_data | model.sample_flag.compressed,
        .convert = model.sample_convert.delta,
        .length = 40000,
    });
    headers[3] = try f.sampleHeader(.{
        .name = "short",
        .flags = model.sample_flag.has_data | model.sample_flag.compressed,
        .length = 40000,
    });
    for (headers, 0..) |at, i| f.patchDword(smp_pp + @as(u32, @intCast(i)) * 4, at);

    f.patchDword(headers[0] + model.smp.sample_pointer, f.here());
    try f.zeros(16);
    f.patchDword(headers[1] + model.smp.sample_pointer, f.here());
    try f.zeros(24);
    f.patchDword(headers[2] + model.smp.sample_pointer, f.here());
    try f.word(4);
    try f.zeros(4);
    try f.word(6);
    try f.zeros(6);
    f.patchDword(headers[3] + model.smp.sample_pointer, f.here());
    try f.word(99); // promises 99 bytes, the file ends after 3
    try f.zeros(3);

    const bytes = try f.toOwned();
    defer gpa.free(bytes);

    var r = try read(gpa, bytes);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.module.instruments.len);
    try testing.expectEqualStrings("piano", model.nameText(&r.module.instruments[0].name));
    try testing.expectEqual(@as(u32, 554), r.module.instruments[0].raw.len);

    const s = r.module.samples;
    try testing.expectEqual(@as(usize, 4), s.len);
    try testing.expectEqualStrings("pcm", model.nameText(&s[0].name));
    try testing.expectEqual(@as(u8, 16), s[0].bits);
    try testing.expectEqual(model.Encoding.pcm, s[0].enc);
    try testing.expectEqual(@as(u32, 16), s[0].data.len);
    try testing.expectEqual(model.Encoding.adpcm, s[1].enc);
    try testing.expectEqual(@as(u32, 24), s[1].data.len);
    try testing.expectEqual(model.Encoding.it215, s[2].enc);
    try testing.expectEqual(@as(u32, 14), s[2].data.len);
    try testing.expectEqual(model.Encoding.it214, s[3].enc);
    try testing.expectEqual(@as(u32, 5), s[3].data.len);
    try testing.expectEqual(@as(usize, 1), r.diags.count(.it_sample_extent_truncated));
}

test "read: the trailing area — a foreign chunk, then tempura's own TMPU" {
    const gpa = testing.allocator;
    var f: Fixture = .init(gpa);
    defer f.deinit();

    try f.header(.{ .ord = 2, .pat = 1 });
    try f.blob(&.{ 0, 255 });
    const pp = f.here();
    try f.dword(0);
    f.patchDword(pp, f.here());
    try f.word(minimal_stream.len);
    try f.word(64);
    try f.zeros(4);
    try f.blob(&minimal_stream);

    const foreign_at = f.here();
    try f.blob("STPM\x01\x02\x03");
    const tmpu_at = f.here();
    try f.blob("TMPU");
    try f.dword(5);
    try f.blob("hello");

    const bytes = try f.toOwned();
    defer gpa.free(bytes);

    var r = try read(gpa, bytes);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.module.foreign.len);
    try testing.expectEqualSlices(u8, "STPM", &r.module.foreign[0].tag);
    try testing.expectEqual(Region{ .off = foreign_at, .len = 7 }, r.module.foreign[0].raw);
    try testing.expectEqual(Region{ .off = tmpu_at + 8, .len = 5 }, r.module.tmpu.?);
    try testing.expectEqualStrings("hello", r.module.tmpu.?.slice(bytes).?);
}

test "read: pseudo-random bytes never panic" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x17_2026_09_20);
    const rand = prng.random();

    var buf: [1024]u8 = undefined;
    for (0..96) |i| {
        const n = rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        // Half the inputs pass the magic gate, so the parser goes deep.
        if (i % 2 == 0 and n >= 4) @memcpy(buf[0..4], "IMPM");

        var r = try read(gpa, buf[0..n]);
        r.deinit();
    }
}

test "read: every truncation prefix of the minimal fixture never panics" {
    const gpa = testing.allocator;
    const bytes = try minimal(gpa);
    defer gpa.free(bytes);

    for (0..bytes.len + 1) |n| {
        var r = try read(gpa, bytes[0..n]);
        r.deinit();
    }
}
