//! `Module` → `.it` bytes, in plan 06's canonical layout.
//!
//! ```
//! 0x0000  header (192 B)
//! 0x00C0  orders (trimmed + exactly one trailing 255, min length 2)
//!         parapointers: instruments ×4, samples ×4, patterns ×4
//!         [edit history]   [MIDI config]   [message + residue tail]
//!         instruments (554 B each, copied)
//!         sample headers (80 B each, copied, SamplePointer back-patched)
//!         patterns (8 B header + packed; empty 64-row → parapointer 0)
//!         sample data (sample-index order, copied)
//!         [foreign chunks, verbatim, in order]
//!         ['TMPU' u32 len payload — the residue, last]
//! ```
//!
//! The section order and every pad byte are FIXED, so one module is one
//! file on every host (plan 09), and `write(read(bytes)) == bytes` for
//! any file this writer produced. Opaque regions are copied out of
//! `source` — the anchor's bytes — and never decoded (plan 06, "The
//! canonical writer"; it 05 §"Canonical layout"). The layout freezes at
//! E1.
//!
//! Strict clamps are it 05's and are DIAGNOSTICS, never silent: 200
//! patterns, 99 instruments and samples, rows 32–200 (a shorter pattern
//! gets a `C00` break on its last row), tempo 32–255, speed 1–255.
//! `loose` lifts the counts to OpenMPT's itEx bounds.
//!
//! Diagnostic spans are offsets into the OUTPUT — the writer has no input
//! file to point at, and where a record landed is what a reader of the
//! result needs.

const std = @import("std");
const Diag = @import("../Diag.zig");
const model = @import("Module.zig");
const pattern = @import("pattern.zig");

const Builder = model.Builder;
const Cell = model.Cell;
const Module = model.Module;
const Region = model.Region;
const hdr = model.hdr;
const testing = std.testing;

/// Only resource exhaustion is an error (plan 01).
pub const Error = error{OutOfMemory};

/// What the caller wants of a write.
pub const Options = struct {
    /// Copy the anchor's edit-history block through (it 03: dropped
    /// unless asked for).
    preserve_history: bool = false,
    /// Lift the strict count clamps to OpenMPT's itEx bounds (it 05).
    loose: bool = false,
    /// The residue's trailing-chunk payload (plan 04). When null, a
    /// `TMPU` chunk the module was READ with is copied through instead.
    tmpu: ?[]const u8 = null,
    /// The residue's message tail, appended to the song message (plan 04,
    /// "The IT carriers").
    message_tail: ?[]const u8 = null,
};

/// The bytes and everything that had to give to produce them.
pub const Written = struct {
    arena: std.heap.ArenaAllocator,
    bytes: []const u8,
    diags: Diag.List,

    pub fn deinit(self: *Written) void {
        self.diags.deinit();
        self.arena.deinit();
    }
};

/// it 05's clamps. `strict` is a file IT 2.14 itself loads; `loose` is
/// OpenMPT's itEx bounds, for people who know their target player.
const Limits = struct {
    patterns: usize,
    instruments: usize,
    samples: usize,
    rows_min: u16,
    rows_max: u16,

    const strict: Limits = .{
        .patterns = 200,
        .instruments = 99,
        .samples = 99,
        .rows_min = 32,
        .rows_max = 200,
    };
    const loose: Limits = .{
        .patterns = 240,
        .instruments = 255,
        .samples = 3999,
        .rows_min = 1,
        .rows_max = 1024,
    };
};

/// IT's `Cxx` — break to row xx of the next order (`'C' - '@'`), the one
/// effect the writer ever synthesises (it 05: a short pattern's break).
const cmd_break: u8 = 'C' - '@';

/// `OrdNum` is a u16 and IT's own list is 256 entries.
const max_orders: usize = 256;
/// `MsgLgth` is a u16, and the NUL terminator has to fit inside it.
const max_message: usize = std.math.maxInt(u16) - 1;

/// Writes `module` as an Impulse Tracker module.
///
/// `source` is the anchor's bytes, where every opaque region is copied
/// from; it may be null only when the module carries no regions (a module
/// tempura authored). A region that cannot be copied is a diagnostic and
/// a zeroed record — never a refusal to write.
pub fn write(
    gpa: std.mem.Allocator,
    module: *const Module,
    source: ?[]const u8,
    opts: Options,
) Error!Written {
    module.invariants();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var w: Writer = .{
        .arena = arena_state.allocator(),
        .module = module,
        .source = source,
        .opts = opts,
        .limits = if (opts.loose) .loose else .strict,
        .diags = &diags,
    };
    try w.run();

    return .{ .arena = arena_state, .bytes = w.out.items, .diags = diags };
}

/// The emission in progress.
const Writer = struct {
    /// The `Written`'s arena: the output and every scratch list live in
    /// it and are freed with it, never one by one.
    arena: std.mem.Allocator,
    module: *const Module,
    source: ?[]const u8,
    opts: Options,
    limits: Limits,
    diags: *Diag.List,
    out: std.ArrayList(u8) = .empty,

    fn here(self: *const Writer) u32 {
        return @intCast(self.out.items.len);
    }

    fn byte(self: *Writer, v: u8) Error!void {
        try self.out.append(self.arena, v);
    }

    fn word(self: *Writer, v: u16) Error!void {
        try self.out.appendSlice(self.arena, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
    }

    fn dword(self: *Writer, v: u32) Error!void {
        try self.out.appendSlice(self.arena, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }

    fn blob(self: *Writer, s: []const u8) Error!void {
        try self.out.appendSlice(self.arena, s);
    }

    fn zeros(self: *Writer, n: usize) Error!void {
        try self.out.appendNTimes(self.arena, 0, n);
    }

    fn patchWord(self: *Writer, at: u32, v: u16) void {
        std.mem.writeInt(u16, self.out.items[at..][0..2], v, .little);
    }

    fn patchDword(self: *Writer, at: u32, v: u32) void {
        std.mem.writeInt(u32, self.out.items[at..][0..4], v, .little);
    }

    fn note(
        self: *Writer,
        code: Diag.Code,
        severity: Diag.Severity,
        at: u32,
        end: u32,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        try self.diags.add(code, severity, .{ .start = at, .end = end }, fmt, args);
    }

    /// What the file is written with, settled before a byte goes out:
    /// the trimmed order list, the clamped record counts, the message
    /// with its tail, and `Flags`/`Special` as the sections that follow
    /// will justify them.
    const Plan = struct {
        orders: []u8,
        message: []u8,
        ins_count: usize,
        smp_count: usize,
        pat_count: usize,
        history: ?Region,
        embed_midi: bool,
        flags: u16,
        special: u16,
    };

    /// Where the three parapointer arrays sit, back-patched as each
    /// record lands.
    const Parapointers = struct { ins: u32, smp: u32, pat: u32 };

    /// The canonical layout, section by section, in the order the file
    /// header's diagram gives them. Each section is one call; the order
    /// of the calls IS the layout, frozen at E1.
    fn run(self: *Writer) Error!void {
        const plan = try self.settle();
        try self.writeHeader(.{
            .ord_num = @intCast(plan.orders.len),
            .ins_num = @intCast(plan.ins_count),
            .smp_num = @intCast(plan.smp_count),
            .pat_num = @intCast(plan.pat_count),
            .flags = plan.flags,
            .special = plan.special,
        });
        try self.blob(plan.orders);
        const pp = try self.reserveParapointers(plan);
        try self.writeBlocks(plan);
        try self.writeInstruments(pp.ins, plan.ins_count);
        const sample_headers = try self.writeSampleHeaders(pp.smp, plan.smp_count);
        try self.writePatterns(pp.pat, plan.pat_count);
        try self.writeSampleData(sample_headers);
        try self.writeTail();
    }

    /// Everything the header has to say before its sections exist, in
    /// the order the diagnostics have always come: orders, the three
    /// counts, the message, then the bits.
    fn settle(self: *Writer) Error!Plan {
        const m = self.module;
        const orders = try self.trimOrders();
        const limits = self.limits;
        const ins_count =
            try self.clampCount(m.instruments.len, limits.instruments, "instruments", hdr.ins_num);
        const smp_count =
            try self.clampCount(m.samples.len, limits.samples, "samples", hdr.smp_num);
        const pat_count =
            try self.clampCount(m.patterns.len, limits.patterns, "patterns", hdr.pat_num);
        const message = try self.buildMessage();

        // Special b1 is set only when a block is really written — never
        // flag-without-block, the bug the reader guards against (it 05).
        const history: ?Region = if (self.opts.preserve_history) m.edit_history else null;
        const embed_midi = m.midi_config_bytes != null or
            m.midi_config != null or
            m.header.flags & model.flag.embed_midi != 0 or
            m.header.special & model.special.midi_config != 0;

        var special = m.header.special;
        special = setBit(special, model.special.message, message.len > 0);
        special = setBit(special, model.special.edit_history, history != null);
        special = setBit(special, model.special.midi_config, embed_midi);
        // An embedded configuration sets BOTH bits — `Special` b3 and
        // `Flags` b7 (it 05 §"Header field policy") — so a reader that
        // keys on either one finds the block.
        const flags = setBit(m.header.flags, model.flag.embed_midi, embed_midi);

        return .{
            .orders = orders,
            .message = message,
            .ins_count = ins_count,
            .smp_count = smp_count,
            .pat_count = pat_count,
            .history = history,
            .embed_midi = embed_midi,
            .flags = flags,
            .special = special,
        };
    }

    /// The three parapointer arrays, zeroed for now: instruments,
    /// samples, patterns, four bytes a record.
    fn reserveParapointers(self: *Writer, plan: Plan) Error!Parapointers {
        const ins = self.here();
        try self.zeros(plan.ins_count * 4);
        const smp = self.here();
        try self.zeros(plan.smp_count * 4);
        const pat = self.here();
        try self.zeros(plan.pat_count * 4);
        return .{ .ins = ins, .smp = smp, .pat = pat };
    }

    /// The optional blocks between the parapointers and the records:
    /// the edit history, the MIDI configuration and the message, each
    /// only when the plan says so.
    fn writeBlocks(self: *Writer, plan: Plan) Error!void {
        const m = self.module;
        if (plan.history) |region| {
            try self.copyRegion(region, region.len, .it_truncated, "the edit-history block");
        }
        if (plan.embed_midi) {
            if (m.midi_config_bytes) |bytes| {
                // The block the module OWNS — a document's `(it/midi …)`
                // lowered, or a read module's copy — ahead of the region,
                // which needs an anchor a built module does not have.
                try self.copyBytes(bytes, model.midi_config_size, "the MIDI configuration");
            } else if (m.midi_config) |region| {
                try self.copyRegion(
                    region,
                    model.midi_config_size,
                    .it_truncated,
                    "the MIDI configuration",
                );
            } else {
                // The flags demand a block and the module has none: IT's
                // default table goes back (it 03, "What becomes a ref").
                try self.zeros(model.midi_config_size);
            }
        }
        if (plan.message.len > 0) {
            self.patchWord(hdr.message_length, @intCast(plan.message.len));
            self.patchDword(hdr.message_offset, self.here());
            try self.blob(plan.message);
        }
    }

    /// The instrument records, each one's parapointer patched to where
    /// it landed.
    fn writeInstruments(self: *Writer, pp: u32, count: usize) Error!void {
        for (self.module.instruments[0..count], 0..) |instrument, i| {
            self.patchDword(pp + @as(u32, @intCast(i)) * 4, self.here());
            // The region is the instrument, so a region the anchor
            // cannot give is a pointer that leads nowhere;
            // `it_no_instrument` is plan 08's, for a render with no
            // instrument to sound.
            try self.copyRegion(
                instrument.raw,
                model.instrument_size,
                .it_parapointer_out_of_range,
                "an instrument body",
            );
        }
    }

    /// The sample headers, parapointers patched; returns where each
    /// header landed, so `writeSampleData` can patch its data pointer.
    fn writeSampleHeaders(self: *Writer, pp: u32, count: usize) Error![]u32 {
        const headers = try self.arena.alloc(u32, count);
        for (self.module.samples[0..count], 0..) |sample, i| {
            self.patchDword(pp + @as(u32, @intCast(i)) * 4, self.here());
            headers[i] = self.here();
            try self.copyRegion(
                sample.raw,
                model.sample_header_size,
                .it_sample_extent_truncated,
                "a sample header",
            );
        }
        return headers;
    }

    /// The patterns. An empty 64-row pattern is a parapointer 0 and no
    /// data — exactly what IT writes (it 05, `D_SaveIT1`). Any other
    /// height has to be written, because a 0 would read back as 64 rows.
    fn writePatterns(self: *Writer, pp: u32, count: usize) Error!void {
        for (self.module.patterns[0..count], 0..) |p, i| {
            if (p.rows == model.empty_pattern_rows and p.isEmpty()) continue;
            self.patchDword(pp + @as(u32, @intCast(i)) * 4, self.here());
            try self.writePattern(p, i);
        }
    }

    /// The sample data, in sample-index order, each header's pointer
    /// patched to its data — or to 0 when there is none, or none the
    /// anchor can give.
    fn writeSampleData(self: *Writer, headers: []const u32) Error!void {
        for (self.module.samples[0..headers.len], headers, 0..) |sample, header_at, i| {
            const pointer_at = header_at + model.smp.sample_pointer;
            if (sample.data.isEmpty()) {
                self.patchDword(pointer_at, 0);
                continue;
            }
            const bytes = self.regionBytes(sample.data) orelse {
                try self.note(
                    .it_sample_extent_truncated,
                    .warning,
                    pointer_at,
                    pointer_at + 4,
                    "sample {d}'s data is not inside the anchor's bytes; written without data",
                    .{i},
                );
                self.patchDword(pointer_at, 0);
                continue;
            };
            self.patchDword(pointer_at, self.here());
            try self.blob(bytes);
        }
    }

    /// The foreign chunks verbatim and in order, then the residue chunk
    /// last, where every tracker puts its own extensions (plan 04, "The
    /// IT carriers").
    fn writeTail(self: *Writer) Error!void {
        const m = self.module;
        for (m.foreign) |chunk| {
            try self.copyRegion(chunk.raw, chunk.raw.len, .it_truncated, "a foreign chunk");
        }
        const payload: ?[]const u8 = self.opts.tmpu orelse
            if (m.tmpu) |region| self.regionBytes(region) else null;
        if (payload) |bytes| {
            try self.blob("TMPU");
            try self.dword(@intCast(bytes.len));
            try self.blob(bytes);
        }
    }

    const HeaderCounts = struct {
        ord_num: u16,
        ins_num: u16,
        smp_num: u16,
        pat_num: u16,
        flags: u16,
        special: u16,
    };

    fn writeHeader(self: *Writer, counts: HeaderCounts) Error!void {
        const h = self.module.header;
        try self.blob("IMPM");
        try self.blob(&h.title);
        try self.byte(h.highlight_minor);
        try self.byte(h.highlight_major);
        try self.word(counts.ord_num);
        try self.word(counts.ins_num);
        try self.word(counts.smp_num);
        try self.word(counts.pat_num);
        // A module READ from a file keeps its own identification; a fresh
        // one carries tempura's, applied when the Builder made it
        // (plan 06, "Header policy").
        try self.word(h.cwtv);
        try self.word(h.cmwt);
        try self.word(counts.flags);
        try self.word(counts.special);
        try self.byte(h.global_volume);
        try self.byte(h.mix_volume);
        try self.byte(try self.clampSpeed());
        try self.byte(try self.clampTempo());
        try self.byte(h.pan_separation);
        try self.byte(h.pitch_wheel_depth);
        try self.word(0); // MsgLgth, back-patched
        try self.dword(0); // MsgOffset, back-patched
        try self.dword(h.reserved);
        // The channel tables go back as they came: `Module` carries all
        // 64 entries, so there is nothing for the writer to invent.
        try self.blob(&h.channel_pan);
        try self.blob(&h.channel_vol);
        std.debug.assert(self.here() == model.header_size);
    }

    /// The order list, trimmed of its trailing end markers and given
    /// exactly one, at least two bytes long (it 05's canonical layout).
    fn trimOrders(self: *Writer) Error![]u8 {
        const orders = self.module.orders;
        var n = orders.len;
        while (n > 0 and orders[n - 1] == 255) n -= 1;
        // The mandatory end marker is one of the 256 entries, so the
        // orders themselves get at most 255 of them.
        if (n > max_orders - 1) {
            try self.note(
                .it_count_exceeds_spec,
                .err,
                hdr.ord_num,
                hdr.ord_num + 2,
                "the module has {d} orders; IT's list is {d} entries including the end marker, " ++
                    "so the rest are dropped",
                .{ n, max_orders },
            );
            n = max_orders - 1;
        }

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.arena, orders[0..n]);
        try out.append(self.arena, 255);
        if (out.items.len < 2) try out.append(self.arena, 255);
        return out.items;
    }

    /// The song message plus the residue's tail, CR newlines kept and one
    /// NUL terminator (plan 06; plan 04, "The IT carriers").
    fn buildMessage(self: *Writer) Error![]u8 {
        const body = self.module.message;
        const tail = self.opts.message_tail orelse "";
        if (body.len == 0 and tail.len == 0) return &.{};

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.arena, body);
        try out.appendSlice(self.arena, tail);
        // `MsgLgth` is a u16 (it 04's header table), terminator included.
        if (out.items.len > max_message) {
            try self.note(
                .it_truncated,
                .warning,
                hdr.message_length,
                hdr.message_length + 2,
                "the song message is {d} bytes; MsgLgth is a u16, so it was cut to {d}",
                .{ out.items.len, max_message },
            );
            out.shrinkRetainingCapacity(max_message);
        }
        try out.append(self.arena, 0);
        return out.items;
    }

    /// One pattern record: its rows clamped to IT's range — a long one
    /// cut, a short one padded (`padShort`) — then the 8-byte header and
    /// the stream packed straight into the file, its length back-patched:
    /// one list, in the `Written`'s arena, and no second report to copy.
    fn writePattern(self: *Writer, p: model.Pattern, index: usize) Error!void {
        const at = self.here();
        var rows = p.rows;
        var cells = p.cells;

        if (rows > self.limits.rows_max) {
            try self.note(
                .it_pattern_rows_out_of_range,
                .err,
                at,
                at + 8,
                "pattern {d} has {d} rows, past IT's {d}; the extra rows are dropped",
                .{ index, rows, self.limits.rows_max },
            );
            rows = self.limits.rows_max;
            cells = cells[0..@min(cells.len, @as(usize, rows) * model.channels)];
        } else if (rows < self.limits.rows_min) {
            const padded = try padShort(self.arena, cells, rows, self.limits.rows_min);
            try self.shortPattern(at, index, rows, padded);
            rows = self.limits.rows_min;
            cells = padded.cells;
        }

        try self.zeros(8);
        const stream_at = self.out.items.len;
        try pattern.packInto(self.arena, &self.out, cells, rows, self.diags, at);
        self.patchWord(at, @intCast(self.out.items.len - stream_at));
        self.patchWord(at + 2, rows);
    }

    /// What padding a `rows`-row pattern cost, said at its record `at`:
    /// written empty when it had no rows, a `C00` break where a channel
    /// was free, and — loudly — the command a break had to displace.
    fn shortPattern(self: *Writer, at: u32, index: usize, rows: u16, padded: Padded) Error!void {
        const min = self.limits.rows_min;
        const channel = padded.channel orelse return self.note(
            .it_pattern_rows_out_of_range,
            .warning,
            at,
            at + 8,
            "pattern {d} has no rows; written as {d} empty rows",
            .{ index, min },
        );
        const last = rows - 1;
        if (padded.displaced) |old| {
            // Every channel on that row already carried a command, and
            // which rows caused it is the diagnostic's whole point.
            var name_buf: [5]u8 = undefined;
            return self.note(
                .it_pattern_rows_out_of_range,
                .err,
                at,
                at + 8,
                "pattern {d} has {d} rows, under IT's {d}; the C00 break on row {d} " ++
                    "overwrote channel {d}'s command {s}{x:0>2}",
                .{ index, rows, min, last, channel + 1, commandName(&name_buf, old.fx), old.param },
            );
        }
        try self.note(
            .it_pattern_rows_out_of_range,
            .warning,
            at,
            at + 8,
            "pattern {d} has {d} rows, under IT's {d}; written {d} rows with a C00 " ++
                "break on row {d}, channel {d}",
            .{ index, rows, min, min, last, channel + 1 },
        );
    }

    /// The bytes of an opaque region, or null when the anchor cannot
    /// give them.
    fn regionBytes(self: *const Writer, region: Region) ?[]const u8 {
        if (region.isEmpty()) return null;
        const source = self.source orelse return null;
        return region.slice(source);
    }

    /// Copies bytes the module owns, padded or truncated to `size` — the
    /// fixed-size records have to be their size whatever a producer
    /// handed over, and a short one says so.
    fn copyBytes(
        self: *Writer,
        bytes: []const u8,
        size: u32,
        comptime what: []const u8,
    ) Error!void {
        const at = self.here();
        const take = @min(bytes.len, size);
        try self.blob(bytes[0..take]);
        if (take < size) {
            try self.note(
                .it_truncated,
                .warning,
                at,
                at + size,
                what ++ " is {d} bytes of the {d} it must be; zero-padded to size",
                .{ take, size },
            );
            try self.zeros(size - take);
        }
    }

    /// Copies an opaque region, padded or truncated to `size`. A region
    /// the anchor cannot give is a diagnostic and a zeroed record: the
    /// file stays structurally sound.
    fn copyRegion(
        self: *Writer,
        region: Region,
        size: u32,
        code: Diag.Code,
        comptime what: []const u8,
    ) Error!void {
        const at = self.here();
        if (self.regionBytes(region)) |bytes| {
            const take = @min(bytes.len, size);
            try self.blob(bytes[0..take]);
            if (take < size) {
                // A record the anchor holds only part of: the rest is
                // zeroed, and the file says so.
                try self.note(
                    .it_truncated,
                    .warning,
                    at,
                    at + size,
                    what ++ " is {d} bytes of the {d} it must be; zero-padded to size",
                    .{ take, size },
                );
                try self.zeros(size - take);
            }
            return;
        }
        if (size > 0) {
            try self.note(
                code,
                .warning,
                at,
                at + size,
                what ++ " is not inside the anchor's bytes; wrote {d} zero bytes",
                .{size},
            );
            try self.zeros(size);
        }
    }

    fn clampCount(
        self: *Writer,
        have: usize,
        cap: usize,
        comptime what: []const u8,
        field: u32,
    ) Error!usize {
        if (have <= cap) return have;
        try self.note(
            .it_count_exceeds_spec,
            .err,
            field,
            field + 2,
            "the module has {d} " ++ what ++ ", past IT's {d}; the rest are dropped",
            .{ have, cap },
        );
        return cap;
    }

    fn clampTempo(self: *Writer) Error!u8 {
        const tempo = self.module.header.initial_tempo;
        if (tempo >= 32) return tempo;
        try self.note(
            .it_count_exceeds_spec,
            .warning,
            hdr.initial_tempo,
            hdr.initial_tempo + 1,
            "an initial tempo of {d} is under IT's 32; written as 32",
            .{tempo},
        );
        return 32;
    }

    fn clampSpeed(self: *Writer) Error!u8 {
        const speed = self.module.header.initial_speed;
        if (speed >= 1) return speed;
        // IT's own loader reads a zero speed as 6, so 6 is what keeps the
        // music (plan 06's header table), not the bare minimum 1.
        try self.note(
            .it_count_exceeds_spec,
            .warning,
            hdr.initial_speed,
            hdr.initial_speed + 1,
            "an initial speed of 0 is outside IT's 1–255; written as IT's default 6",
            .{},
        );
        return 6;
    }
};

fn setBit(value: u16, bit: u16, on: bool) u16 {
    return if (on) value | bit else value & ~bit;
}

/// A pattern shorter than IT's shortest, as `padShort` wrote it.
const Padded = struct {
    /// `rows_min × 64` cells in the arena, the pattern's own first.
    cells: []Cell,
    /// The channel of the last real row the `C00` break went into, or
    /// null for a pattern with no rows — no last row to break on, so it
    /// is written empty.
    channel: ?usize,
    /// The command the break replaced, when every channel of that row
    /// already carried one.
    displaced: ?Cell,
};

/// A short pattern padded to `rows_min` rows and told to break where it
/// used to end (it 05): its cells, then empty ones, with `C00` in the
/// leftmost free effect column of its last row — or, when that row has
/// none free, in its last channel, over the command there. The cells are
/// `arena`'s; the caller says what it cost.
fn padShort(arena: std.mem.Allocator, cells: []const Cell, rows: u16, rows_min: u16) Error!Padded {
    std.debug.assert(rows < rows_min);
    const padded = try arena.alloc(Cell, @as(usize, rows_min) * model.channels);
    @memset(padded, .empty);
    const kept = @min(cells.len, padded.len);
    @memcpy(padded[0..kept], cells[0..kept]);
    if (rows == 0) return .{ .cells = padded, .channel = null, .displaced = null };

    const last: usize = @as(usize, rows) - 1;
    const free = breakChannel(padded, last);
    const channel = free orelse model.channels - 1;
    const slot = &padded[last * model.channels + channel];
    const displaced: ?Cell = if (free == null) slot.* else null;
    slot.fx = cmd_break;
    slot.param = 0;
    return .{ .cells = padded, .channel = channel, .displaced = displaced };
}

/// A command as a diagnostic names it: its letter (`A`), or `#200 ` for
/// a byte no letter spells — a builder may seat any.
fn commandName(buf: *[5]u8, fx: u8) []const u8 {
    if (model.fxLetter(fx)) |letter| {
        buf[0] = letter;
        return buf[0..1];
    }
    // `#`, at most three digits and a space: five bytes, the buffer's.
    return std.fmt.bufPrint(buf, "#{d} ", .{fx}) catch unreachable;
}

/// The leftmost channel with no command on that row — where a
/// synthesised `C00` break displaces nothing. Null when the row is full,
/// which the caller has to report rather than swallow.
fn breakChannel(cells: []const Cell, row: usize) ?usize {
    for (0..model.channels) |channel| {
        if (cells[row * model.channels + channel].fx == 0) return channel;
    }
    return null;
}

// Test support only: the reader, to prove what the writer wrote, and the
// shared `.it` byte writer for the pass-through fixtures. Neither is
// reachable from `write`.
const read_it = @import("read.zig");
const Fixture = @import("test_support.zig").Fixture;

fn minimalModule(gpa: std.mem.Allocator) !Module {
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    try b.addOrder(0);
    const p = try b.addPattern(64);
    p.at(0, 0).* = .{ .note = 60, .ins = 1, .vol = 64, .fx = 1, .param = 6 };
    return b.finish();
}

test "write: the canonical layout, byte by byte, on the minimal module" {
    const gpa = testing.allocator;
    var m = try minimalModule(gpa);
    defer m.deinit();

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    const out = w.bytes;

    try testing.expectEqual(@as(usize, 0), w.diags.items().len);

    // 0x0000 the header.
    try testing.expectEqualStrings("IMPM", out[0..4]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 26), out[4..30]);
    try testing.expectEqual(@as(u8, 4), out[hdr.highlight_minor]);
    try testing.expectEqual(@as(u8, 16), out[hdr.highlight_major]);
    // Orders: the one order plus exactly one trailing 255.
    try testing.expectEqual(@as(u16, 2), word(out, hdr.ord_num));
    try testing.expectEqual(@as(u16, 0), word(out, hdr.ins_num));
    try testing.expectEqual(@as(u16, 0), word(out, hdr.smp_num));
    try testing.expectEqual(@as(u16, 1), word(out, hdr.pat_num));
    // A module tempura authored identifies as tempura (plan 06).
    try testing.expectEqual(@as(u16, 0xB801), word(out, hdr.cwtv));
    try testing.expectEqual(@as(u16, 0x0214), word(out, hdr.cmwt));
    try testing.expectEqual(model.flag.stereo | model.flag.linear_slides, word(out, hdr.flags));
    try testing.expectEqual(model.special.highlight, word(out, hdr.special));
    try testing.expectEqual(@as(u8, 128), out[hdr.global_volume]);
    try testing.expectEqual(@as(u8, 48), out[hdr.mix_volume]);
    try testing.expectEqual(@as(u8, 6), out[hdr.initial_speed]);
    try testing.expectEqual(@as(u8, 125), out[hdr.initial_tempo]);
    try testing.expectEqual(@as(u8, 128), out[hdr.pan_separation]);
    try testing.expectEqual(@as(u8, 0), out[hdr.pitch_wheel_depth]);
    // No message, no history, no MIDI config.
    try testing.expectEqual(@as(u16, 0), word(out, hdr.message_length));
    try testing.expectEqual(@as(u32, 0), dword(out, hdr.message_offset));
    try testing.expectEqual(@as(u32, 0), dword(out, hdr.reserved));
    try testing.expectEqualSlices(u8, &([_]u8{32} ** 64), out[hdr.channel_pan..][0..64]);
    try testing.expectEqualSlices(u8, &([_]u8{64} ** 64), out[hdr.channel_vol..][0..64]);

    // 0x00C0 the orders, then the one parapointer array.
    try testing.expectEqualSlices(u8, &.{ 0, 255 }, out[0xC0..0xC2]);
    try testing.expectEqual(@as(u32, 0xC6), dword(out, 0xC2));

    // 0x00C6 the pattern: 8-byte header then the packed stream.
    try testing.expectEqual(@as(u16, 71), word(out, 0xC6));
    try testing.expectEqual(@as(u16, 64), word(out, 0xC8));
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 4), out[0xCA..0xCE]);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x0F, 60, 1, 64, 1, 6, 0x00 }, out[0xCE..0xD6]);
    // 63 empty rows, one end-of-row byte each.
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 63), out[0xD6..][0..63]);
    try testing.expectEqual(@as(usize, 0xCE + 71), out.len);
}

test "write: orders are trimmed to exactly one 255, minimum length 2" {
    const gpa = testing.allocator;

    var b: Builder = .init(gpa);
    defer b.deinit();
    for ([_]u8{ 0, 1, 254, 2, 255, 255, 255 }) |o| try b.addOrder(o);
    var m = b.finish();
    defer m.deinit();

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    try testing.expectEqualSlices(u8, &.{ 0, 1, 254, 2, 255 }, w.bytes[0xC0..][0..5]);
    try testing.expectEqual(@as(u16, 5), word(w.bytes, hdr.ord_num));

    // A module with no orders at all still writes two bytes.
    var e: Builder = .init(gpa);
    defer e.deinit();
    var em = e.finish();
    defer em.deinit();
    var ew = try write(gpa, &em, null, .{});
    defer ew.deinit();
    try testing.expectEqual(@as(u16, 2), word(ew.bytes, hdr.ord_num));
    try testing.expectEqualSlices(u8, &.{ 255, 255 }, ew.bytes[0xC0..][0..2]);
}

test "write: the order list is 256 entries INCLUDING the end marker" {
    const gpa = testing.allocator;

    // 255 orders fill the list exactly — 255 plus the marker — and
    // nothing is dropped.
    var fit: Builder = .init(gpa);
    defer fit.deinit();
    for (0..255) |i| try fit.addOrder(@intCast(i % 200));
    var fm = fit.finish();
    defer fm.deinit();
    var fw = try write(gpa, &fm, null, .{});
    defer fw.deinit();
    try testing.expectEqual(@as(u16, 256), word(fw.bytes, hdr.ord_num));
    try testing.expectEqual(@as(u8, 255), fw.bytes[0xC0 + 255]);
    try testing.expectEqual(@as(usize, 0), fw.diags.count(.it_count_exceeds_spec));

    // 256 orders do not: the marker has to have one of the 256 slots, so
    // the last order goes, and says so.
    var over: Builder = .init(gpa);
    defer over.deinit();
    for (0..256) |i| try over.addOrder(@intCast(i % 200));
    var om = over.finish();
    defer om.deinit();
    var ow = try write(gpa, &om, null, .{});
    defer ow.deinit();
    try testing.expectEqual(@as(u16, 256), word(ow.bytes, hdr.ord_num));
    try testing.expectEqual(@as(u8, 255), ow.bytes[0xC0 + 255]);
    try testing.expectEqual(@as(usize, 1), ow.diags.count(.it_count_exceeds_spec));

    // And what came back out is what IT will read: exactly one marker,
    // at the end.
    var r = try read_it.read(gpa, ow.bytes);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 256), r.module.orders.len);
    try testing.expectEqual(@as(usize, 255), std.mem.indexOfScalar(u8, r.module.orders, 255).?);
}

test "write: an empty 64-row pattern is a parapointer 0 and no data" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    _ = try b.addPattern(64);
    // A 32-row empty pattern is NOT the same thing: parapointer 0 means
    // 64 rows, so this one has to be written.
    _ = try b.addPattern(32);
    var m = b.finish();
    defer m.deinit();

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    try testing.expectEqual(@as(u32, 0), dword(w.bytes, 0xC2));
    const second = dword(w.bytes, 0xC6);
    try testing.expectEqual(@as(u32, 0xCA), second);
    try testing.expectEqual(@as(u16, 32), word(w.bytes, second + 2));
}

test "write: a short pattern is padded to 32 rows with a C00 break" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    const p = try b.addPattern(16);
    p.at(0, 0).* = .{ .note = 60 };
    var m = b.finish();
    defer m.deinit();

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), w.diags.count(.it_pattern_rows_out_of_range));
    try testing.expectEqual(@as(u16, 32), word(w.bytes, 0xC8));

    // Read it back: the break sits on the last row the module had.
    var r = try read_it.read(gpa, w.bytes);
    defer r.deinit();
    const back = r.module.patterns[0];
    try testing.expectEqual(@as(u16, 32), back.rows);
    try testing.expectEqual(@as(u8, 3), back.at(15, 0).fx); // 'C'
    try testing.expectEqual(@as(u8, 0), back.at(15, 0).param);
    try testing.expectEqual(@as(u8, 60), back.at(0, 0).note);
}

test "write: a pattern with no rows is written empty, never a row -1" {
    // `rows == 0` is representable in `Pattern`, and the last row a break
    // would go on is `rows - 1`: the underflow was a panic in both modes
    // (review round 1). There is no row to break on, so there is no
    // break.
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    _ = try b.addPattern(0);
    var m = b.finish();
    defer m.deinit();

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), w.diags.count(.it_pattern_rows_out_of_range));
    try testing.expectEqual(@as(u16, 32), word(w.bytes, 0xC8));

    var r = try read_it.read(gpa, w.bytes);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 32), r.module.patterns[0].rows);
    try testing.expect(r.module.patterns[0].isEmpty());

    // Loose mode's floor is 1 row, and it survives the same way.
    var loose = try write(gpa, &m, null, .{ .loose = true });
    defer loose.deinit();
    try testing.expectEqual(@as(u16, 1), word(loose.bytes, 0xC8));
    try testing.expectEqual(@as(usize, 1), loose.diags.count(.it_pattern_rows_out_of_range));
}

test "write: a C00 break with nowhere free overwrites a command, loudly" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    const p = try b.addPattern(4);
    // Every channel of the last row already carries an A05.
    for (0..model.channels) |ch| p.at(3, ch).* = .{ .fx = 1, .param = 5 };
    var m = b.finish();
    defer m.deinit();

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();

    try testing.expectEqual(@as(usize, 1), w.diags.count(.it_pattern_rows_out_of_range));
    try testing.expect(w.diags.hasErrors());
    try testing.expect(std.mem.indexOf(u8, w.diags.items()[0].message, "overwrote") != null);
    try testing.expect(std.mem.indexOf(u8, w.diags.items()[0].message, "A05") != null);

    var r = try read_it.read(gpa, w.bytes);
    defer r.deinit();
    const back = r.module.patterns[0];
    try testing.expectEqual(@as(u8, 3), back.at(3, 63).fx); // the break
    try testing.expectEqual(@as(u8, 0), back.at(3, 63).param);
    try testing.expectEqual(@as(u8, 1), back.at(3, 0).fx); // every other channel kept its own
    try testing.expectEqual(@as(u8, 5), back.at(3, 0).param);
}

test "write: a displaced command that is no letter is named without a letter, never a wrap" {
    // `Module.invariants` lets a builder seat any `fx`, and `'@' + 200`
    // is past a u8: the diagnostic names the command by its number.
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    const p = try b.addPattern(4);
    for (0..model.channels) |ch| p.at(3, ch).* = .{ .fx = 200, .param = 5 };
    var m = b.finish();
    defer m.deinit();

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), w.diags.count(.it_pattern_rows_out_of_range));
    const message = w.diags.items()[0].message;
    try testing.expect(std.mem.indexOf(u8, message, "command #200 05") != null);
}

test "write: strict clamps are diagnostics, and --loose lifts the counts" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    for (0..250) |_| _ = try b.addPattern(64);
    for (0..120) |_| try b.addInstrument("x", .none);
    var m = b.finish();
    defer m.deinit();
    m.header.initial_tempo = 10;
    m.header.initial_speed = 0;

    var strict = try write(gpa, &m, null, .{});
    defer strict.deinit();
    try testing.expectEqual(@as(u16, 200), word(strict.bytes, hdr.pat_num));
    try testing.expectEqual(@as(u16, 99), word(strict.bytes, hdr.ins_num));
    try testing.expectEqual(@as(u8, 32), strict.bytes[hdr.initial_tempo]);
    try testing.expectEqual(@as(u8, 6), strict.bytes[hdr.initial_speed]);
    // Two counts and two out-of-range header values, all of them "past
    // what the IT spec allows" — one code, four messages.
    try testing.expectEqual(@as(usize, 4), strict.diags.count(.it_count_exceeds_spec));
    try testing.expect(strict.diags.hasErrors());

    var loose = try write(gpa, &m, null, .{ .loose = true });
    defer loose.deinit();
    try testing.expectEqual(@as(u16, 240), word(loose.bytes, hdr.pat_num));
    try testing.expectEqual(@as(u16, 120), word(loose.bytes, hdr.ins_num));
}

test "write: the message, its residue tail and the TMPU chunk last" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    try b.setMessage("hello\rworld");
    var m = b.finish();
    defer m.deinit();

    var w = try write(gpa, &m, null, .{
        .message_tail = ";; tempura\r(timeline)",
        .tmpu = "residue",
    });
    defer w.deinit();
    const out = w.bytes;

    try testing.expect(word(out, hdr.special) & model.special.message != 0);
    const at = dword(out, hdr.message_offset);
    const n = word(out, hdr.message_length);
    try testing.expectEqualStrings("hello\rworld;; tempura\r(timeline)\x00", out[at..][0..n]);

    // The residue chunk is the last thing in the file.
    const chunk_at = out.len - (8 + 7);
    try testing.expectEqualStrings("TMPU", out[chunk_at..][0..4]);
    try testing.expectEqual(@as(u32, 7), dword(out, @intCast(chunk_at + 4)));
    try testing.expectEqualStrings("residue", out[chunk_at + 8 ..]);

    // And re-reading finds exactly that payload and message.
    var r = try read_it.read(gpa, out);
    defer r.deinit();
    try testing.expectEqualStrings("hello\rworld;; tempura\r(timeline)", r.module.message);
    try testing.expectEqualStrings("residue", r.module.tmpu.?.slice(out).?);
}

/// A file with one of everything opaque: an instrument, a PCM sample, an
/// ADPCM sample and a compressed one (hand-built block headers, no real
/// codec), a message, an edit-history block, a foreign chunk and a TMPU
/// chunk.
fn richFixture(gpa: std.mem.Allocator) ![]u8 {
    var f: Fixture = .init(gpa);
    defer f.deinit();

    try f.header(.{
        .ord = 3,
        .ins = 1,
        .smp = 3,
        .pat = 2,
        .special = model.special.message | model.special.edit_history,
    });
    try f.blob(&.{ 0, 254, 255 });
    const ins_pp = f.here();
    try f.dword(0);
    const smp_pp = f.here();
    try f.zeros(3 * 4);
    const pat_pp = f.here();
    try f.zeros(2 * 4);

    // The edit history sits right after the parapointers.
    try f.word(2);
    try f.zeros(16);

    const message_at = f.here();
    try f.blob("a wild module\rsecond line\x00");
    f.patchWord(hdr.message_length, 25);
    f.patchDword(hdr.message_offset, message_at);

    f.patchDword(ins_pp, f.here());
    _ = try f.instrument("piano");

    var headers: [3]u32 = undefined;
    headers[0] = try f.sampleHeader(
        .{
            .name = "pcm",
            .flags = model.sample_flag.has_data | model.sample_flag.bits16,
            .length = 6,
        },
    );
    headers[1] = try f.sampleHeader(
        .{ .name = "adpcm", .convert = model.sample_convert.adpcm, .length = 16 },
    );
    headers[2] = try f.sampleHeader(.{
        .name = "packed",
        .flags = model.sample_flag.has_data | model.sample_flag.compressed,
        .length = 40000,
    });
    for (headers, 0..) |at, i| f.patchDword(smp_pp + @as(u32, @intCast(i)) * 4, at);

    // Pattern 0 is real; pattern 1 is a parapointer 0.
    f.patchDword(pat_pp, f.here());
    const stream = [_]u8{ 0x81, 0x0F, 60, 1, 64, 1, 6, 0x00, 0x01, 62, 2, 32, 4, 0x10, 0x00 };
    try f.word(stream.len);
    try f.word(64);
    try f.zeros(4);
    try f.blob(&stream);

    f.patchDword(headers[0] + model.smp.sample_pointer, f.here());
    try f.blob(&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 });
    f.patchDword(headers[1] + model.smp.sample_pointer, f.here());
    for (0..24) |i| try f.byte(@intCast(0x40 + i));
    f.patchDword(headers[2] + model.smp.sample_pointer, f.here());
    try f.word(4);
    try f.blob(&.{ 0xDE, 0xAD, 0xBE, 0xEF });
    try f.word(3);
    try f.blob(&.{ 0x11, 0x22, 0x33 });

    try f.blob("STPM\x07\x08");
    try f.blob("TMPU");
    try f.dword(4);
    try f.blob("resd");

    return f.toOwned();
}

test "write: the opaque regions come back byte-equal after read → write" {
    const gpa = testing.allocator;
    const source = try richFixture(gpa);
    defer gpa.free(source);

    var r = try read_it.read(gpa, source);
    defer r.deinit();
    try testing.expect(!r.diags.hasErrors());

    var w = try write(gpa, &r.module, source, .{ .preserve_history = true });
    defer w.deinit();

    var back = try read_it.read(gpa, w.bytes);
    defer back.deinit();
    try testing.expect(!back.diags.hasErrors());

    // Every sacred region survives, byte for byte.
    try testing.expectEqualSlices(
        u8,
        r.module.instruments[0].raw.slice(source).?,
        back.module.instruments[0].raw.slice(w.bytes).?,
    );
    try testing.expectEqual(@as(usize, 3), back.module.samples.len);
    for (r.module.samples, back.module.samples) |before, after| {
        try testing.expectEqual(before.enc, after.enc);
        try testing.expectEqual(before.bits, after.bits);
        // Everything but the 4 back-patched SamplePointer bytes: the
        // fields before it AND the auto-vibrato bytes after it.
        const head = model.smp.sample_pointer;
        const tail = model.smp.sample_pointer + 4;
        try testing.expectEqualSlices(
            u8,
            before.raw.slice(source).?[0..head],
            after.raw.slice(w.bytes).?[0..head],
        );
        try testing.expectEqualSlices(
            u8,
            before.raw.slice(source).?[tail..model.sample_header_size],
            after.raw.slice(w.bytes).?[tail..model.sample_header_size],
        );
        try testing.expectEqualSlices(u8, before.data.slice(source).?, after.data.slice(w.bytes).?);
    }
    try testing.expectEqualSlices(
        u8,
        r.module.edit_history.?.slice(source).?,
        back.module.edit_history.?.slice(w.bytes).?,
    );
    try testing.expectEqualSlices(
        u8,
        r.module.foreign[0].raw.slice(source).?,
        back.module.foreign[0].raw.slice(w.bytes).?,
    );
    try testing.expectEqualStrings("resd", back.module.tmpu.?.slice(w.bytes).?);
    try testing.expectEqualStrings("a wild module\rsecond line", back.module.message);
    try testing.expectEqualSlices(u8, &.{ 0, 254, 255 }, back.module.orders);
    try testing.expectEqual(r.module.patterns[0].cells[0], back.module.patterns[0].cells[0]);
    try testing.expectEqual(r.module.patterns[0].cells[64], back.module.patterns[0].cells[64]);
    try testing.expect(back.module.patterns[1].isEmpty());
}

test "write: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails
    // with error.OutOfMemory and testing.allocator sees no leak; past
    // the last index it succeeds. Bounded by the number of allocations
    // the call makes, which the loop discovers. The module is the rich
    // fixture as read, against its own bytes, so every section — the
    // history, the message, the records, the pattern packer's own
    // transient results — is on the path.
    const gpa = testing.allocator;
    const bytes = try richFixture(gpa);
    defer gpa.free(bytes);
    var r = try read_it.read(gpa, bytes);
    defer r.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const written = write(failing.allocator(), &r.module, bytes, .{
            .preserve_history = true,
            .message_tail = "\rtail",
        });
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, written);
        } else {
            var value = try written;
            value.deinit();
            break;
        }
    }
    // Small, since an arena takes chunks and not slices; more than one,
    // or the sweep proved nothing.
    try testing.expect(fail_index > 1);
}

test "write: write(read(bytes)) == bytes on the writer's own output" {
    const gpa = testing.allocator;
    const source = try richFixture(gpa);
    defer gpa.free(source);

    var r = try read_it.read(gpa, source);
    defer r.deinit();
    var once = try write(gpa, &r.module, source, .{ .preserve_history = true });
    defer once.deinit();

    var back = try read_it.read(gpa, once.bytes);
    defer back.deinit();
    var twice = try write(gpa, &back.module, once.bytes, .{ .preserve_history = true });
    defer twice.deinit();

    try testing.expectEqualSlices(u8, once.bytes, twice.bytes);

    // The same fixed point for the module tempura authored itself.
    var m = try minimalModule(gpa);
    defer m.deinit();
    var a = try write(gpa, &m, null, .{ .tmpu = "x", .message_tail = ";; tempura" });
    defer a.deinit();
    var ar = try read_it.read(gpa, a.bytes);
    defer ar.deinit();
    var c = try write(gpa, &ar.module, a.bytes, .{});
    defer c.deinit();
    try testing.expectEqualSlices(u8, a.bytes, c.bytes);
}

test "write: a MIDI configuration the flags demand is written back" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    var m = b.finish();
    defer m.deinit();
    m.header.flags |= model.flag.embed_midi;

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    // An embedded block sets BOTH bits (it 05's header policy).
    try testing.expect(word(w.bytes, hdr.special) & model.special.midi_config != 0);
    try testing.expect(word(w.bytes, hdr.flags) & model.flag.embed_midi != 0);

    var r = try read_it.read(gpa, w.bytes);
    defer r.deinit();
    try testing.expectEqual(@as(?Region, null), r.module.midi_config);
    var again = try write(gpa, &r.module, w.bytes, .{});
    defer again.deinit();
    try testing.expectEqualSlices(u8, w.bytes, again.bytes);

    // The other way round: a module that asks through `Special` b3 alone
    // still gets `Flags` b7, so a reader keying on either one finds it.
    var s: Builder = .init(gpa);
    defer s.deinit();
    try s.addOrder(0);
    var sm = s.finish();
    defer sm.deinit();
    sm.header.special |= model.special.midi_config;

    var sw = try write(gpa, &sm, null, .{});
    defer sw.deinit();
    try testing.expect(word(sw.bytes, hdr.flags) & model.flag.embed_midi != 0);
    try testing.expect(word(sw.bytes, hdr.special) & model.special.midi_config != 0);

    // And a module that asks for neither gets neither, nor a block.
    var n: Builder = .init(gpa);
    defer n.deinit();
    try n.addOrder(0);
    var nm = n.finish();
    defer nm.deinit();
    var nw = try write(gpa, &nm, null, .{});
    defer nw.deinit();
    try testing.expectEqual(@as(u16, 0), word(nw.bytes, hdr.flags) & model.flag.embed_midi);
    try testing.expectEqual(@as(u16, 0), word(nw.bytes, hdr.special) & model.special.midi_config);
}

test "write: an owned MIDI configuration is written whole, and read back as bytes and as a region" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    var block: [model.midi_config_size]u8 = @splat(0);
    @memcpy(block[0..2], "FA"); // MIDI start
    @memcpy(block[9 * 32 ..][0..7], "F0F000z"); // SF0
    @memcpy(block[(9 + 16 + 127) * 32 ..][0..32], "0123456789ABCDEF0123456789ABCDEF"); // ZFF, full
    try b.setMidiConfig(&block);
    var m = b.finish();
    defer m.deinit();

    // No anchor: a built module has none, and the bytes need none.
    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    try testing.expectEqual(@as(usize, 0), w.diags.items().len);
    try testing.expect(word(w.bytes, hdr.special) & model.special.midi_config != 0);
    try testing.expect(word(w.bytes, hdr.flags) & model.flag.embed_midi != 0);
    // The block sits right after the parapointers (one order, no
    // records, no history): 192 + 2 orders.
    try testing.expectEqualSlices(u8, &block, w.bytes[0xC2..][0..model.midi_config_size]);

    // Read back, the module carries the block both ways — the region
    // for rung 2 and the source map, the bytes for the bridge.
    var r = try read_it.read(gpa, w.bytes);
    defer r.deinit();
    try testing.expectEqual(
        Region{ .off = 0xC2, .len = model.midi_config_size },
        r.module.midi_config.?,
    );
    try testing.expectEqualSlices(u8, &block, r.module.midi_config_bytes.?);

    // …and written again WITHOUT its source, the bytes still carry it.
    var again = try write(gpa, &r.module, null, .{});
    defer again.deinit();
    try testing.expectEqualSlices(u8, w.bytes, again.bytes);

    // A short block is padded and said so, never a short record.
    var short: Builder = .init(gpa);
    defer short.deinit();
    try short.addOrder(0);
    var sm = short.finish();
    defer sm.deinit();
    sm.midi_config_bytes = "FA";
    var sw = try write(gpa, &sm, null, .{});
    defer sw.deinit();
    try testing.expectEqual(@as(usize, 1), sw.diags.count(.it_truncated));
    try testing.expectEqualStrings("FA", sw.bytes[0xC2..][0..2]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 30), sw.bytes[0xC4..][0..30]);
}

test "write: a module with no bytes behind its regions is written with diagnostics" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    try b.addInstrument("ghost", .{ .off = 4000, .len = model.instrument_size });
    try b.addSample(
        .{
            .raw = .{ .off = 9000, .len = model.sample_header_size },
            .data = .{ .off = 9100, .len = 64 },
        },
    );
    var m = b.finish();
    defer m.deinit();

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    // A region the anchor cannot give is a pointer that leads nowhere.
    // (The code plan 08 reserves for a render with no instrument is NOT
    // named here on purpose: naming it would tell `audit-diagnostics`
    // that somebody covers it.)
    try testing.expectEqual(@as(usize, 1), w.diags.count(.it_parapointer_out_of_range));
    try testing.expect(w.diags.count(.it_sample_extent_truncated) > 0);
    // The file is still structurally sound: the records are there, zeroed.
    var r = try read_it.read(gpa, w.bytes);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.module.instruments.len);
    try testing.expectEqual(@as(u32, model.instrument_size), r.module.instruments[0].raw.len);
}

test "write: a region the anchor holds only part of is zero-padded and said so" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    // 300 bytes of the 554 an instrument record must be.
    try b.addInstrument("half", .{ .off = 0, .len = 300 });
    var m = b.finish();
    defer m.deinit();

    const source = [_]u8{0xAB} ** 300;
    var w = try write(gpa, &m, &source, .{});
    defer w.deinit();

    try testing.expectEqual(@as(usize, 1), w.diags.count(.it_truncated));
    const at = dword(w.bytes, 0xC2);
    try testing.expectEqualSlices(u8, &([_]u8{0xAB} ** 300), w.bytes[at..][0..300]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 254), w.bytes[at + 300 ..][0..254]);
}

test "write: whatever pseudo-random bytes read as can be written back" {
    // The other half of the never-panic contract: a module the reader
    // salvaged from noise still has to produce bytes, with its regions
    // pointing into that same noise.
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x2026_09_20);
    const rand = prng.random();

    var buf: [512]u8 = undefined;
    for (0..48) |i| {
        const n = rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..n]);
        if (i % 2 == 0 and n >= 4) @memcpy(buf[0..4], "IMPM");

        var r = try read_it.read(gpa, buf[0..n]);
        defer r.deinit();
        var w = try write(gpa, &r.module, buf[0..n], .{
            .preserve_history = i % 3 == 0,
            .loose = i % 5 == 0,
        });
        defer w.deinit();

        // And the result is readable, whatever went into it.
        var again = try read_it.read(gpa, w.bytes);
        again.deinit();
    }
}

test "write: a message past MsgLgth's u16 is cut, never a panic" {
    const gpa = testing.allocator;
    const huge = try gpa.alloc(u8, 70_000);
    defer gpa.free(huge);
    @memset(huge, 'a');

    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.addOrder(0);
    try b.setMessage(huge);
    var m = b.finish();
    defer m.deinit();

    var w = try write(gpa, &m, null, .{});
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), w.diags.count(.it_truncated));
    try testing.expectEqual(@as(u16, 65535), word(w.bytes, hdr.message_length));
}

fn word(bytes: []const u8, at: u32) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn dword(bytes: []const u8, at: u32) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
