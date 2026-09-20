//! Test support for `src/itf/` — the byte-writer that builds `.it`
//! fixtures in-test ("Fixtures are built in-test by a byte-writer
//! helper", plan 06's phase 1).
//!
//! It lives in its own file so the reader and the writer can share one
//! fixture builder without either one carrying test scaffolding in its
//! production surface. Nothing here is part of the IT core's API, and
//! nothing outside a `test {}` body may call it.

const std = @import("std");
const model = @import("Module.zig");

/// An in-test `.it` byte writer: a header with IT's defaults, instrument
/// and sample records, and the low-level `byte`/`word`/`dword`/`blob`/
/// `zeros`/`patch*` the layout tests need.
pub const Fixture = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub const Counts = struct {
        ord: u16 = 0,
        ins: u16 = 0,
        smp: u16 = 0,
        pat: u16 = 0,
        flags: u16 = 0,
        special: u16 = 0,
        cwtv: u16 = 0x0214,
        cmwt: u16 = 0x0214,
        title: []const u8 = "fixture",
    };

    pub const SampleSpec = struct {
        name: []const u8 = "",
        flags: u8 = model.sample_flag.has_data,
        convert: u8 = model.sample_convert.signed,
        length: u32 = 0,
    };

    pub fn init(gpa: std.mem.Allocator) Fixture {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Fixture) void {
        self.buf.deinit(self.gpa);
    }

    pub fn here(self: *const Fixture) u32 {
        return @intCast(self.buf.items.len);
    }

    pub fn bytes(self: *const Fixture) []const u8 {
        return self.buf.items;
    }

    pub fn toOwned(self: *Fixture) ![]u8 {
        return self.buf.toOwnedSlice(self.gpa);
    }

    pub fn byte(self: *Fixture, v: u8) !void {
        try self.buf.append(self.gpa, v);
    }

    pub fn word(self: *Fixture, v: u16) !void {
        try self.buf.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
    }

    pub fn dword(self: *Fixture, v: u32) !void {
        try self.buf.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }

    pub fn blob(self: *Fixture, s: []const u8) !void {
        try self.buf.appendSlice(self.gpa, s);
    }

    pub fn zeros(self: *Fixture, n: usize) !void {
        try self.buf.appendNTimes(self.gpa, 0, n);
    }

    pub fn patchWord(self: *Fixture, at: usize, v: u16) void {
        std.mem.writeInt(u16, self.buf.items[at..][0..2], v, .little);
    }

    pub fn patchDword(self: *Fixture, at: usize, v: u32) void {
        std.mem.writeInt(u32, self.buf.items[at..][0..4], v, .little);
    }

    /// A 192-byte header with `IMPM`, IT's own defaults and the counts
    /// given; anything else is patched through `model.hdr`'s offsets.
    pub fn header(self: *Fixture, counts: Counts) !void {
        const start = self.here();
        try self.blob("IMPM");
        var title: [26]u8 = undefined;
        model.copyName(&title, counts.title);
        try self.blob(&title);
        try self.byte(4); // highlight minor
        try self.byte(16); // highlight major
        try self.word(counts.ord);
        try self.word(counts.ins);
        try self.word(counts.smp);
        try self.word(counts.pat);
        try self.word(counts.cwtv);
        try self.word(counts.cmwt);
        try self.word(counts.flags);
        try self.word(counts.special);
        try self.byte(128); // global volume
        try self.byte(48); // mix volume
        try self.byte(6); // initial speed
        try self.byte(125); // initial tempo
        try self.byte(128); // pan separation
        try self.byte(0); // pitch wheel depth
        try self.word(0); // message length
        try self.dword(0); // message offset
        try self.dword(0); // reserved
        try self.buf.appendNTimes(self.gpa, 32, 64); // channel pan
        try self.buf.appendNTimes(self.gpa, 64, 64); // channel volume
        std.debug.assert(self.here() - start == model.header_size);
    }

    /// A 554-byte instrument record with `IMPI` and a name; the body is
    /// zeros, which is all an opaque region needs to be. Returns its
    /// offset.
    pub fn instrument(self: *Fixture, name: []const u8) !u32 {
        const at = self.here();
        try self.blob("IMPI");
        try self.zeros(model.ins.name - 4);
        var buf: [26]u8 = undefined;
        model.copyName(&buf, name);
        try self.blob(&buf);
        try self.zeros(model.instrument_size - model.ins.name - 26);
        std.debug.assert(self.here() - at == model.instrument_size);
        return at;
    }

    /// An 80-byte `IMPS` sample header; the data pointer is patched by
    /// the caller once the data lands. Returns its offset.
    pub fn sampleHeader(self: *Fixture, spec: SampleSpec) !u32 {
        const at = self.here();
        try self.blob("IMPS");
        try self.zeros(model.smp.global_volume - 4);
        try self.byte(64); // global volume
        try self.byte(spec.flags);
        try self.byte(64); // volume
        var buf: [26]u8 = undefined;
        model.copyName(&buf, spec.name);
        try self.blob(&buf);
        try self.byte(spec.convert);
        try self.byte(32); // default pan
        try self.dword(spec.length);
        try self.dword(0); // loop begin
        try self.dword(0); // loop end
        try self.dword(8363); // C5 speed
        try self.dword(0); // sustain loop begin
        try self.dword(0); // sustain loop end
        try self.dword(0); // sample pointer, patched later
        try self.zeros(4); // auto-vibrato
        std.debug.assert(self.here() - at == model.sample_header_size);
        return at;
    }
};
