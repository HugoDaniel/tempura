//! Never-panic fuzz harnesses for tempura's byte-eating and
//! arbitrary-input entrypoints.
//!
//! Each harness generates an input (via `std.testing.fuzz` + `Smith`, or
//! the baked-in corpus on a plain `zig build fuzz`), feeds it to the
//! target, and asserts ONLY invariants that must hold for ARBITRARY
//! input — never "it parsed" or "no diagnostics", since random bytes trip
//! every diagnostic there is. Leaks are caught by `testing.allocator`.
//!
//! Shipped as a SEPARATE target so `zig build test` and `verify` stay
//! fast (the SJON precedent) — `fuzz` carries the imported parts' own
//! tests along with the harnesses, which is the price of reaching their
//! entry points and no burden on the default gates. Every harness is
//! also a plain `test {}`, so its corpus runs on each invocation even
//! without the instrumented fuzzer.
//!
//! # The shape every harness has
//!
//! A harness is THREE things, and the middle one is what makes it a
//! harness rather than a smoke test:
//!
//!   1. a `checkX(bytes) !Seen` that runs the target and asserts the
//!      invariants — the only code that knows what is being claimed;
//!   2. a `test "… bites …"` that hands `checkX` a KNOWN-BAD input and
//!      asserts the diagnostic or the count it must come back with. A
//!      harness whose invariants no input can reach proves nothing, so
//!      each one is made to fire on purpose once, in the open;
//!   3. a `test "fuzz …"` that walks the same `checkX` over a corpus and,
//!      under `--fuzz`, over Smith's generated inputs.
//!
//! # What is claimed, per target
//!
//!   * `smf.vlq.read` — every read is `.ok` with a value in RP-001's
//!     domain and a cursor that advanced by at most `MAX_LEN`, or `.err`
//!     with one of exactly two codes and a cursor inside the input.
//!   * `smf.read` — total; every diagnostic span is inside the bytes;
//!     every mapped chunk's body is a slice a consumer may take; and
//!     `read ∘ write` of whatever came out is total again and keeps the
//!     track count (the canonical writer eats its own reader's output).
//!   * `itf.read` — total; spans inside the bytes; every mapped region
//!     inside the bytes.
//!   * `itf.pattern.unpack` — the cell grid is exactly `rows × 64`, every
//!     command is one ITTECH names, and `unpack ∘ pack ∘ unpack` is
//!     `unpack`: the packer is lossless over whatever the unpacker can
//!     produce, which is the round trip a `.it` write depends on.
//!   * `residue.records` — `readHead` is null or tempura's magic;
//!     `decodeLane` borrows only from the body it was handed and is
//!     STABLE under a re-encode; `decodeConductor` is null unless the
//!     body is 32 bytes; `reassemble` returns nothing or exactly the
//!     parts' bytes.
//!   * `residue.essence.unpack` — total; an `.ok` text is NUL-terminated
//!     and parses (not necessarily cleanly — SJON's parser is total too).
//!   * `residue.smf.detach` — total over a sequence read from arbitrary
//!     bytes; the detached sequence keeps every track and loses only
//!     residue events; detaching twice changes nothing.
//!   * `residue.it.parseChunk` / `parseTail` / `splitMessage` — total;
//!     the split's two halves are slices of the message it was given; a
//!     parsed tail is never longer than the text it came from.
//!   * `doc.fromSource`, then everything downstream of it — the load
//!     returns and `mapOf` agrees with its map; `time.derive`,
//!     `Playhead.at`/`atTick` at NaN, the infinities and both ends of
//!     i64, and `exportScore` all return, so no text reaches one of plan
//!     12's `invariants()` assertions.
//!   * `doc.pipeline.dump`, both kinds — total; the document text is
//!     NUL-terminated, the rule is one of plan 04's five, every verdict
//!     is findable by its own name, and every diagnostic's span is
//!     well-formed.
//!
//! Spans are checked against the INPUT only where the producer parsed
//! the input: a `dump` mixes file spans with document-text spans by
//! design (`Diag.Span`'s header), so there only `start <= end` is
//! claimed.
//!
//! Note for anyone running `--fuzz` rather than the corpus: a crafted IT
//! header can ask the reader for 240 patterns of 1024 rows, which is a
//! large but bounded allocation (the reader's own caps). It is slow, not
//! unsound.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("Diag.zig");
const Schema = @import("Schema.zig");
const smf = @import("smf/smf.zig");
const itf = @import("itf/itf.zig");
const residue = @import("residue/residue.zig");
const records = residue.records;
const pipeline = @import("doc/pipeline.zig");
const Doc = @import("doc/Value.zig");
/// The document PART, for the two harnesses that load a whole document:
/// `fromSource`, `mapOf` and `conductedPlaceholder` are its, not the
/// value file's.
const doc_part = @import("doc/doc.zig");
const edit = @import("edit/edit.zig");
const time = @import("time/time.zig");
const exporter = @import("export/export.zig");
/// The edit part's own fixtures — a test-only file, imported by a
/// test-only target, so an operation harness plans over the same
/// document the edit tests do.
const edit_support = @import("edit/test_support.zig");

const Smith = std.testing.Smith;
const testing = std.testing;

/// Maximum input any harness eats. Keeps fuzzing cheap; nothing here has
/// a length contract of its own.
const MAX_INPUT: usize = 1024;

/// What a harness saw, so a bite test can assert that the invariants it
/// claims were reached and not merely compiled.
///
/// `codes` is every diagnostic code the run raised, `diags` how many
/// were raised at all, and `hits` a tally each harness documents for
/// itself (values decoded, tracks read, cells packed…).
const Seen = struct {
    codes: std.EnumSet(Diag.Code) = .initEmpty(),
    diags: usize = 0,
    hits: usize = 0,

    /// Record a list, asserting the one invariant every diagnostic has
    /// whatever was parsed: a span that does not run backwards.
    fn note(self: *Seen, list: *const Diag.List) !void {
        for (list.items()) |d| {
            try testing.expect(d.span.start <= d.span.end);
            self.codes.insert(d.code);
            self.diags += 1;
        }
    }

    /// `note`, plus the stronger claim a producer that parsed BYTES
    /// makes: the span points inside those bytes.
    fn noteIn(self: *Seen, list: *const Diag.List, len: usize) !void {
        for (list.items()) |d| {
            try testing.expect(d.span.start <= d.span.end);
            try testing.expect(d.span.end <= len);
            self.codes.insert(d.code);
            self.diags += 1;
        }
    }

    fn has(self: Seen, code: Diag.Code) bool {
        return self.codes.contains(code);
    }
};

// ---------------------------------------------------------------------------
// Seeds. Three hand-assembled files, so the corpus reaches past the first
// byte of every reader. Assembled at comptime rather than spelled as a
// string literal because an offset table is readable and a 273-byte
// escape sequence is not.
// ---------------------------------------------------------------------------

/// Format 0, one `MTrk`, division 96, nothing but an end of track.
const minimal_smf: []const u8 =
    "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60" ++
    "MTrk\x00\x00\x00\x04\x00\xff\x2f\x00";

/// The same file with one residue payload seated at tick 0: a `kind 03`
/// conductor record whose hash is 32 zero bytes.
const residue_smf: []const u8 = blk: {
    var f: [14 + 8 + 48]u8 = @splat(0);
    f[0..14].* = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60".*;
    f[14..18].* = "MTrk".*;
    std.mem.writeInt(u32, f[18..22], 48, .big);
    // delta 0, `FF 7F`, 40 body bytes.
    f[22] = 0;
    f[23] = 0xFF;
    f[24] = 0x7F;
    f[25] = 40;
    f[26..30].* = .{ 0x7D, 't', 'e', 'm' };
    f[30] = 1; // ver
    f[31] = 3; // kind: the conductor record
    f[32] = 0; // seq
    f[33] = 1; // total
    // 34..66 is the 32-byte hash, all zero.
    f[66] = 0;
    f[67] = 0xFF;
    f[68] = 0x2F;
    f[69] = 0x00;
    const out = f;
    break :blk &out;
};

/// One order over one 64-row pattern with a single note on channel 0 —
/// enough to reach the pattern unpacker, the walk and the bridge.
const minimal_it: []const u8 = blk: {
    var f: [273]u8 = @splat(0);
    f[0..4].* = "IMPM".*;
    f[0x1E] = 4; // highlight, minor
    f[0x1F] = 16; // highlight, major
    std.mem.writeInt(u16, f[0x20..0x22], 2, .little); // OrdNum: order + end marker
    std.mem.writeInt(u16, f[0x26..0x28], 1, .little); // PatNum
    std.mem.writeInt(u16, f[0x28..0x2A], 0x0214, .little); // Cwtv
    std.mem.writeInt(u16, f[0x2A..0x2C], 0x0214, .little); // Cmwt
    f[0x30] = 128; // global volume
    f[0x31] = 48; // mix volume
    f[0x32] = 6; // initial speed
    f[0x33] = 125; // initial tempo
    f[0x34] = 128; // pan separation
    @memset(f[0x40..0x80], 32); // channel pan
    @memset(f[0x80..0xC0], 64); // channel volume
    f[0xC0] = 0x00; // order 0 plays pattern 0
    f[0xC1] = 0xFF; // end marker
    std.mem.writeInt(u32, f[0xC2..0xC6], 0xC6, .little); // the one pattern parapointer
    std.mem.writeInt(u16, f[0xC6..0xC8], 67, .little); // packed length
    std.mem.writeInt(u16, f[0xC8..0xCA], 64, .little); // rows
    // 0xCA..0xCE is the block's four reserved bytes; the stream follows.
    f[0xCE] = 0x81; // lead: channel 0 (IT's channel 1), a mask byte follows
    f[0xCF] = 0x01; // mask: note
    f[0xD0] = 60; // C-5
    // 0xD1 ends row 0; the 63 zero bytes after it are the empty rows.
    const out = f;
    break :blk &out;
};

// ---------------------------------------------------------------------------
// 1. Diag.List — arbitrary message bytes.
// ---------------------------------------------------------------------------

/// A diagnostic message quotes its input — a lane name, a chunk tag, a
/// stretch of a `.it`'s CP437 text — so arbitrary bytes reach the
/// formatter. Invariants for ANY input: the message is a byte-for-byte
/// copy owned by the list, entries keep insertion order, `hasErrors`
/// tracks only severity, and `count` only the code.
fn checkDiagList(input: []const u8) !Seen {
    var list: Diag.List = .init(testing.allocator);
    defer list.deinit();

    const end: u32 = @intCast(input.len);
    const span: Diag.Span = .{ .start = 0, .end = end };

    try list.add(.it_message_encoding_lossy, .warning, span, "{s}", .{input});
    try testing.expect(!list.hasErrors());

    try list.add(.smf_unknown_chunk, .err, span, "chunk {s} at {d}", .{ input, end });
    try testing.expect(list.hasErrors());

    const got = list.items();
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings(input, got[0].message);
    try testing.expectEqual(Diag.Code.it_message_encoding_lossy, got[0].code);
    try testing.expectEqual(@as(usize, 1), list.count(.smf_unknown_chunk));
    try testing.expectEqual(@as(usize, 0), list.count(.walk_runaway));

    var seen: Seen = .{};
    try seen.noteIn(&list, input.len);
    seen.hits = got[0].message.len;
    return seen;
}

fn fuzzDiagList(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkDiagList(buf[0..smith.sliceWithHash(&buf, 0x7D_1A_67)]);
}

test "fuzz Diag.List bites: a format specifier in the DATA stays data" {
    // The one way this harness can fail is a producer that formats its
    // input as a format string; the `{s}` below would then be eaten.
    const seen = try checkDiagList("{s} {d} {{");
    try testing.expectEqual(@as(usize, 10), seen.hits);
    try testing.expect(seen.has(.it_message_encoding_lossy));
    try testing.expect(seen.has(.smf_unknown_chunk));
}

test "fuzz Diag.List: arbitrary message bytes are copied whole and never panic" {
    try testing.fuzz({}, fuzzDiagList, .{
        .corpus = &.{
            "",
            "kick",
            // A format specifier in the DATA must stay data.
            "{s} {d} {{",
            // Invalid UTF-8: `.it` text is CP437, `.mid` text is anything.
            "\xff\xfe\x00\x80",
        },
    });
}

// ---------------------------------------------------------------------------
// 2. smf.vlq.read — RP-001's domain, or one of two codes.
// ---------------------------------------------------------------------------

/// Walk the whole input as a run of VLQs. `hits` counts the values that
/// decoded before the walk ran out of bytes.
fn checkVlq(input: []const u8) !Seen {
    var seen: Seen = .{};
    var pos: usize = 0;
    while (true) {
        const start = pos;
        switch (smf.vlq.read(input, &pos)) {
            .ok => |value| {
                try testing.expect(value <= smf.vlq.MAX);
                // A value consumed at least one byte and at most four,
                // and the cursor sits after it, inside the input.
                try testing.expect(pos > start);
                try testing.expect(pos - start <= smf.vlq.MAX_LEN);
                try testing.expect(pos <= input.len);
                // The canonical spelling is never longer than the one
                // that was read: `write` would fit where `read` looked.
                try testing.expect(smf.vlq.len(value) <= pos - start);
                seen.hits += 1;
            },
            .err => |code| {
                // Exactly two ways to fail, both with the cursor ON the
                // byte that failed (`vlq.read`'s contract), so a caller's
                // span is one byte wide or empty.
                try testing.expect(code == .vlq_too_long or code == .smf_track_truncated);
                try testing.expect(pos >= start and pos <= input.len);
                if (code == .vlq_too_long) try testing.expectEqual(start + smf.vlq.MAX_LEN, pos);
                if (code == .smf_track_truncated) try testing.expectEqual(input.len, pos);
                seen.codes.insert(code);
                seen.diags += 1;
                return seen;
            },
        }
    }
}

fn fuzzVlq(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkVlq(buf[0..smith.sliceWithHash(&buf, 0x71_90_00)]);
}

test "fuzz smf.vlq.read bites: a fifth continuation byte and a run that ends mid-value" {
    // Five continuation bytes: the domain's ceiling is four groups.
    const long = try checkVlq("\xff\xff\xff\xff\xff");
    try testing.expectEqual(@as(usize, 0), long.hits);
    try testing.expect(long.has(.vlq_too_long));

    // Two values, then a high bit with nothing after it.
    const cut = try checkVlq("\x81\x00\x7f\x80");
    try testing.expectEqual(@as(usize, 2), cut.hits);
    try testing.expect(cut.has(.smf_track_truncated));
    try testing.expect(!cut.has(.vlq_too_long));
}

test "fuzz smf.vlq.read: a value in the domain or one of two codes, never a panic" {
    try testing.fuzz({}, fuzzVlq, .{
        .corpus = &.{
            "",
            "\x00",
            "\x7f",
            "\x81\x00",
            "\xff\xff\xff\x7f", // the ceiling, 0x0FFFFFFF
            "\xff\xff\xff\xff\xff", // one group too many
            "\x80", // a value that runs off the end
            "\x80\x80\x80\x80\x00",
        },
    });
}

// ---------------------------------------------------------------------------
// 3. smf.read — total, spans in the file, and the writer eats its output.
// ---------------------------------------------------------------------------

/// `hits` is the number of tracks the read produced.
fn checkSmfRead(input: []const u8) !Seen {
    var seen: Seen = .{};

    var result = try smf.read(testing.allocator, input);
    defer result.deinit();
    try seen.noteIn(&result.diags, input.len);
    seen.hits = result.sequence.tracks.len;

    // Every mapped chunk names a body a consumer may slice, which is
    // what `clamped_len` is for: the DECLARED length may run past the
    // file, the clamped one never does.
    for (result.source_map.chunks) |c| {
        try testing.expect(c.clamped_len <= c.len);
        try testing.expect(@as(u64, c.offset) + 8 + c.clamped_len <= input.len);
    }
    for (result.source_map.foreign) |c| {
        try testing.expect(@as(u64, c.offset) + 8 + c.clamped_len <= input.len);
    }

    // What came out is written back and read again: the canonical writer
    // is total over whatever the reader can produce, and its output is a
    // file this reader agrees about.
    var written = try smf.write(testing.allocator, &result.sequence, .{});
    defer written.deinit();
    try seen.note(&written.diags);

    var again = try smf.read(testing.allocator, written.bytes);
    defer again.deinit();
    try seen.noteIn(&again.diags, written.bytes.len);
    try testing.expectEqual(result.sequence.tracks.len, again.sequence.tracks.len);
    try testing.expectEqual(result.sequence.format, again.sequence.format);

    return seen;
}

fn fuzzSmfRead(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkSmfRead(buf[0..smith.sliceWithHash(&buf, 0x5D_F1_00)]);
}

test "fuzz smf.read bites: a header that lies about ntrks and a track that stops short" {
    // `ntrks` says two, the file holds one.
    const lying = try checkSmfRead(
        "MThd\x00\x00\x00\x06\x00\x00\x00\x02\x00\x60" ++
            "MTrk\x00\x00\x00\x04\x00\xff\x2f\x00",
    );
    try testing.expectEqual(@as(usize, 1), lying.hits);
    try testing.expect(lying.has(.smf_ntrks_mismatch));

    // A track whose declared length runs past the file.
    const short = try checkSmfRead(
        "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60" ++
            "MTrk\x00\x00\x00\x40\x00\xff",
    );
    try testing.expect(short.has(.smf_chunk_truncated));

    // Nothing that is a file at all still reads, with no header.
    const junk = try checkSmfRead("\xff\xfe\x00\x80");
    try testing.expectEqual(@as(usize, 0), junk.hits);
    try testing.expect(junk.has(.smf_bad_header));
}

test "fuzz smf.read: arbitrary bytes read, write and re-read without a panic" {
    try testing.fuzz({}, fuzzSmfRead, .{
        .corpus = &.{
            "",
            "MThd",
            minimal_smf,
            residue_smf,
            // A header that promises more tracks than are there.
            "MThd\x00\x00\x00\x06\x00\x01\x00\x09\x00\x60",
            // A SMPTE division (-25 frames, 40 subframes).
            "MThd\x00\x00\x00\x06\x00\x00\x00\x01\xe7\x28MTrk\x00\x00\x00\x04\x00\xff\x2f\x00",
            // Running status with no status to run from.
            "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60MTrk\x00\x00\x00\x03\x00\x40\x40",
            "\xff\xfe\x00\x80",
            "RIFF\x00\x00\x00\x00RMID",
        },
    });
}

// ---------------------------------------------------------------------------
// 4. itf.read — total, spans in the file, regions in the file.
// ---------------------------------------------------------------------------

/// `hits` is the number of patterns the read produced.
fn checkItRead(input: []const u8) !Seen {
    var seen: Seen = .{};

    var result = try itf.read.read(testing.allocator, input);
    defer result.deinit();
    try seen.noteIn(&result.diags, input.len);
    seen.hits = result.module.patterns.len;

    // A region is an `{off, len}` into the anchor's bytes and a consumer
    // slices it unchecked, so it had better be inside them.
    for (result.source_map.entries) |e| {
        try testing.expect(e.region.end() <= input.len);
    }
    for (result.module.samples) |s| {
        try testing.expect(s.data.end() <= input.len);
    }

    // Every cell the reader produced is one the model admits: notes are
    // 0..119 or a sentinel, commands are 0..26.
    for (result.module.patterns) |p| {
        try testing.expectEqual(@as(usize, p.rows) * itf.model.channels, p.cells.len);
        for (p.cells) |c| try testing.expect(c.fx <= 26);
    }

    return seen;
}

fn fuzzItRead(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkItRead(buf[0..smith.sliceWithHash(&buf, 0x17_F1_10)]);
}

test "fuzz itf.read bites: the wrong magic and a header that stops inside itself" {
    const wrong = try checkItRead("IMPX" ++ ("\x00" ** 188));
    try testing.expectEqual(@as(usize, 0), wrong.hits);
    try testing.expect(wrong.has(.it_bad_magic));

    const short = try checkItRead("IMPM\x00\x00");
    try testing.expect(short.has(.it_truncated));

    // The seed is a whole module: one pattern, and no complaint about it.
    const module = try checkItRead(minimal_it);
    try testing.expectEqual(@as(usize, 1), module.hits);
    try testing.expect(!module.has(.it_truncated));
    try testing.expect(!module.has(.it_bad_magic));
}

test "fuzz itf.read: arbitrary bytes read with every region inside the file" {
    try testing.fuzz({}, fuzzItRead, .{
        .corpus = &.{
            "",
            "IMPM",
            minimal_it,
            "IMPX" ++ ("\x00" ** 188),
            // A header claiming counts nothing backs.
            "IMPM" ++ ("\x00" ** 28) ++ "\xff\x00\xff\x00\xff\x00\xff\x00" ++ ("\x00" ** 152),
            "\xff" ** 64,
        },
    });
}

// ---------------------------------------------------------------------------
// 5. itf.pattern.unpack — the grid is dense, and pack is its inverse.
// ---------------------------------------------------------------------------

/// The rows a stream is unpacked at, drawn from the input's first byte so
/// the walk reaches short patterns, IT's strict range and its ceiling.
fn rowsFor(input: []const u8) u16 {
    const pick: u16 = if (input.len == 0) 0 else input[0];
    return switch (pick % 4) {
        0 => 1,
        1 => 16,
        2 => 64,
        else => 200,
    };
}

/// `hits` is the number of non-empty cells the stream produced.
fn checkPatternUnpack(input: []const u8) !Seen {
    var seen: Seen = .{};
    const rows = rowsFor(input);

    var un = try itf.pattern.unpack(testing.allocator, input, rows);
    defer un.deinit();
    try seen.noteIn(&un.diags, input.len);

    // Dense by construction: the bridge and the walk index into this and
    // never decode, so a short grid would be an out-of-bounds read.
    try testing.expectEqual(@as(usize, rows) * itf.model.channels, un.cells.len);
    for (un.cells) |c| {
        try testing.expect(c.fx <= 26);
        // `fx` 0 is "no effect", and no effect carries no parameter.
        if (c.fx == 0) try testing.expectEqual(@as(u8, 0), c.param);
        if (!c.isEmpty()) seen.hits += 1;
    }

    // The packer is lossless over everything the unpacker can produce:
    // `unpack ∘ pack ∘ unpack == unpack`. This is the round trip a `.it`
    // write rests on, and the one property arbitrary bytes can check.
    var re = try itf.pattern.pack(testing.allocator, un.cells, rows);
    defer re.deinit();
    try seen.note(&re.diags);
    if (re.diags.count(.it_pattern_too_large) == 0) {
        var back = try itf.pattern.unpack(testing.allocator, re.bytes, rows);
        defer back.deinit();
        try testing.expectEqualSlices(itf.Cell, un.cells, back.cells);
    }

    return seen;
}

fn fuzzPatternUnpack(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkPatternUnpack(buf[0..smith.sliceWithHash(&buf, 0x9A_77_E0)]);
}

test "fuzz itf.pattern.unpack bites: a stream that stops mid-cell and a command with no letter" {
    // `rowsFor` picks 64 rows for a leading 0x02. A lead byte with the
    // mask bit set and nothing after it is a stream that ends mid-cell.
    const cut = try checkPatternUnpack("\x02\x81");
    try testing.expectEqual(@as(usize, 0), cut.hits);
    try testing.expect(cut.has(.it_truncated));

    // Lead 0x81 (channel 0, mask follows), mask 0x08 (command), command
    // byte 30 — inside ITTECH's range, naming no letter.
    const unknown = try checkPatternUnpack("\x02\x81\x08\x1e\x40");
    try testing.expect(unknown.has(.it_command_unknown));
    // Read as NO effect, so the cell is empty and the round trip above
    // still held.
    try testing.expectEqual(@as(usize, 0), unknown.hits);

    // A note, a volume and a command that IS a letter: one live cell.
    const live = try checkPatternUnpack("\x02\x81\x0d\x3c\x20\x14\x20");
    try testing.expectEqual(@as(usize, 1), live.hits);
    try testing.expect(!live.has(.it_command_unknown));
}

test "fuzz itf.pattern.unpack: a dense grid and a lossless repack" {
    try testing.fuzz({}, fuzzPatternUnpack, .{
        .corpus = &.{
            "",
            "\x00",
            // One note on channel 0, then empty rows.
            "\x02\x81\x01\x3c\x00",
            // Every mask bit at once, then the repeat bits.
            "\x02\x81\x0f\x3c\x01\x40\x14\x20\x00\x01\x00",
            // A command byte with no letter.
            "\x02\x81\x08\x1e\x40",
            // A repeat bit naming a slot the stream never carried.
            "\x02\x81\xf0\x00",
            "\xff" ** 32,
            "\x80" ** 32,
        },
    });
}

// ---------------------------------------------------------------------------
// 6. residue.records — the envelope and the two record bodies.
// ---------------------------------------------------------------------------

/// `hits` is 1 when the body decoded as a lane record, 0 otherwise.
fn checkRecords(input: []const u8) !Seen {
    var seen: Seen = .{};
    const gpa = testing.allocator;

    try checkHead(input);
    try checkConductor(input);
    if (try checkLane(gpa, input)) seen.hits = 1;
    try checkReassembly(gpa, input, &seen);
    return seen;
}

/// The envelope: null, or tempura's four magic bytes and nothing invented
/// — the head is a view on the input, never a parse.
fn checkHead(input: []const u8) !void {
    if (records.readHead(input)) |head| {
        try testing.expect(input.len >= records.head_len);
        try testing.expectEqualSlices(u8, &records.magic, input[0..4]);
        try testing.expectEqual(input[4], head.ver);
        try testing.expectEqual(input[5], head.kind);
        try testing.expectEqual(input[6], head.seq);
        try testing.expectEqual(input[7], head.total);
    } else {
        try testing.expect(input.len < records.head_len or
            !std.mem.eql(u8, input[0..4], &records.magic));
    }
}

/// A conductor body is 32 bytes or it is nothing.
fn checkConductor(input: []const u8) !void {
    if (records.decodeConductor(input)) |cond| {
        try testing.expectEqual(@as(usize, 32), input.len);
        try testing.expectEqualSlices(u8, input, &cond.hash);
    } else {
        try testing.expect(input.len != 32);
    }
}

/// A lane body either fails or borrows only from itself — and a re-encode
/// of what came out decodes to the same bytes again, which is the
/// stability the carriers rest on. True when the body decoded.
fn checkLane(gpa: std.mem.Allocator, input: []const u8) !bool {
    var decoded = try records.decodeLane(gpa, input);
    defer decoded.deinit(gpa);
    switch (decoded) {
        .corrupt => |code| {
            try testing.expectEqual(Diag.Code.residue_corrupt, code);
            return false;
        },
        .ok => |rec| {
            try expectSubslice(rec.lane, input);
            for (rec.steps_only) |seg| try expectSubslice(seg.ease, input);

            const again = try records.encodeLane(gpa, rec);
            defer gpa.free(again);
            var twice = try records.decodeLane(gpa, again);
            defer twice.deinit(gpa);
            try testing.expect(twice == .ok);
            const third = try records.encodeLane(gpa, twice.ok);
            defer gpa.free(third);
            try testing.expectEqualSlices(u8, again, third);
            return true;
        },
    }
}

/// Reassembly: nothing at all, or exactly the parts' bytes in `seq`
/// order. `partsOf` cuts the input into a contiguous split and tears it
/// one of three ways depending on the last byte, so both branches are
/// reached — a whole split must come back byte for byte, and a torn one
/// must come back as nothing, with `residue_corrupt`.
fn checkReassembly(gpa: std.mem.Allocator, input: []const u8, seen: *Seen) !void {
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();
    var parts: [4]records.Part = undefined;
    const n = partsOf(input, &parts);
    if (try records.reassemble(gpa, parts[0..n], &diags)) |body| {
        defer gpa.free(body);
        // The parts are the input, cut up in order, so the reassembly is
        // the input again — nothing dropped, nothing reordered, nothing
        // invented.
        try testing.expectEqualSlices(u8, input, body);
        try testing.expectEqual(@as(usize, 0), diags.count(.residue_corrupt));
    } else if (n > 0) {
        // Nothing came back, so the split was torn and said so.
        try testing.expect(diags.count(.residue_corrupt) > 0);
    }
    try seen.note(&diags);
}

/// Cut `input` into up to four parts, numbered as a split essence is —
/// and TEAR the split sometimes, so `reassemble`'s all-or-none branch is
/// reached and not merely compiled.
///
/// The first byte picks how many parts; the LAST byte picks the tear:
/// `0` whole, `1` a hole where the last part should be, `2` two parts
/// claiming to be the first, `3` a part whose `total` disagrees with its
/// siblings'. A zero-length input is no parts at all, which is "no
/// residue" rather than a tear and raises nothing.
fn partsOf(input: []const u8, out: *[4]records.Part) usize {
    if (input.len == 0) return 0;
    const total: u8 = @intCast(1 + (input[0] % 4));
    const step = input.len / total;
    var i: u8 = 0;
    while (i < total) : (i += 1) {
        const from = @as(usize, i) * step;
        const to = if (i + 1 == total) input.len else from + step;
        out[i] = .{ .seq = i, .total = total, .body = input[from..to] };
    }
    return switch (input[input.len - 1] % 4) {
        // A hole: the last part never arrived. Only when there is one to
        // lose — dropping the only part leaves no parts at all, which is
        // a different answer entirely.
        1 => if (total > 1) total - 1 else total,
        // A repeated `seq`: the last part claims to be the first, so one
        // number is missing and one is there twice.
        2 => blk: {
            if (total > 1) out[total - 1].seq = 0;
            break :blk total;
        },
        // A `total` the others do not agree with. This one tears a
        // single-part split too, which is why it is the last arm.
        3 => blk: {
            out[total - 1].total = total +% 1;
            break :blk total;
        },
        else => total,
    };
}

fn expectSubslice(inner: []const u8, outer: []const u8) !void {
    const base = @intFromPtr(outer.ptr);
    const at = @intFromPtr(inner.ptr);
    try testing.expect(at >= base);
    try testing.expect(at + inner.len <= base + outer.len);
}

fn fuzzRecords(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkRecords(buf[0..smith.sliceWithHash(&buf, 0x7E_C5_00)]);
}

test "fuzz residue.records bites: a body that promises more than it holds" {
    // 32 hash bytes, an SMF address, `name_len` 5 with no name after it.
    const lying = try checkRecords(
        ("\x00" ** 32) ++ "\x00\x01\x00\x00\xff\xff\x00\x00" ++ "\x05\x00\x00\x00",
    );
    try testing.expectEqual(@as(usize, 0), lying.hits);

    // The same body with the name there: a record, and a stable one.
    const whole = try checkRecords(
        ("\x00" ** 32) ++ "\x00\x01\x00\x00\xff\xff\x00\x00" ++ "\x04\x00\x00\x00" ++ "kick",
    );
    try testing.expectEqual(@as(usize, 1), whole.hits);

    // A trailing byte nobody reads is as broken as a missing one.
    const trailing = try checkRecords(
        ("\x00" ** 32) ++ "\x00\x01\x00\x00\xff\xff\x00\x00" ++ "\x04\x00\x00\x00" ++ "kick!",
    );
    try testing.expectEqual(@as(usize, 0), trailing.hits);

    // The envelope, read as a head and nothing more.
    const head = try checkRecords("\x7dtem\x01\x02\x00\x01");
    try testing.expectEqual(@as(usize, 0), head.hits);

    // A split body is all or none. These four differ only in their LAST
    // byte, which is what `partsOf` reads to tear the split: whole, a
    // hole, a repeated `seq`, a disagreeing `total`. The first byte
    // makes it a two-part split in every case.
    try testing.expect(!(try checkRecords("\x01aaaaaaaa\x00")).has(.residue_corrupt));
    try testing.expect((try checkRecords("\x01aaaaaaaa\x01")).has(.residue_corrupt));
    try testing.expect((try checkRecords("\x01aaaaaaaa\x02")).has(.residue_corrupt));
    try testing.expect((try checkRecords("\x01aaaaaaaa\x03")).has(.residue_corrupt));
}

test "fuzz residue.records: heads, bodies and a reassembly that invents nothing" {
    try testing.fuzz({}, fuzzRecords, .{
        .corpus = &.{
            "",
            "\x7dtem\x01\x01\x00\x01",
            "\x7dtem\x02\x01\x00\x01", // a newer envelope version
            "\x7dpau\x01\x01\x00\x01", // somebody else's tag
            "\x00" ** 32, // a conductor body
            ("\x00" ** 32) ++ "\x00\x01\x00\x00\xff\xff\x00\x00" ++ "\x04\x00\x00\x00" ++ "kick",
            // A lane body with one easing segment.
            ("\x11" ** 32) ++ "\x01\x03\x00\x00\x00\x00\x00\x00" ++ "\x03\x00\x01\x00" ++ "hat" ++
                "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x06\x00" ++ "linear",
            // The four splits `partsOf` can cut, whole and torn three ways.
            "\x01aaaaaaaa\x00",
            "\x01aaaaaaaa\x01",
            "\x01aaaaaaaa\x02",
            "\x01aaaaaaaa\x03",
            "\xff" ** 48,
        },
    });
}

// ---------------------------------------------------------------------------
// 7. residue.essence.unpack — Binary IR, or one of two refusals.
// ---------------------------------------------------------------------------

/// `hits` is the number of roots an `.ok` essence re-printed.
fn checkEssenceUnpack(input: []const u8) !Seen {
    var seen: Seen = .{};
    const gpa = testing.allocator;

    var un = try residue.essence.unpack(gpa, input);
    defer un.deinit(gpa);

    switch (un) {
        .corrupt => |code| try testing.expectEqual(Diag.Code.residue_corrupt, code),
        .version => |v| {
            // The version byte is the wire header's fifth, and a body
            // too short to have one reports 0.
            try testing.expectEqual(if (input.len > 4) input[4] else 0, v);
            seen.codes.insert(.residue_version);
        },
        .ok => |e| {
            seen.hits = e.roots;
            // NUL-terminated, because `reconcile` hands the text
            // straight to `fromSource`, and the sentinel is what makes
            // that safe. The sentinel is checked AT the length, not by
            // scanning: a text may legitimately hold an inner NUL.
            try testing.expectEqual(@as(u8, 0), e.text[e.text.len]);
            // The printer's output is SJON source. Parsing is total, so
            // this claims no cleanliness — only that the round back
            // through the parser cannot panic.
            var tree = try sjon.parse(gpa, e.text);
            defer tree.deinit();
            try testing.expectEqual(e.roots, @as(u32, @intCast(tree.root.len)));
        },
    }
    return seen;
}

fn fuzzEssenceUnpack(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkEssenceUnpack(buf[0..smith.sliceWithHash(&buf, 0xE5_5C_30)]);
}

test "fuzz residue.essence.unpack bites: real IR round-trips, garbage is corrupt" {
    const gpa = testing.allocator;

    // A real essence, packed from source by the part that writes them.
    var packed_ = try residue.essence.packFor(gpa, "; a comment\n(timeline :name piece)\n", null);
    defer packed_.deinit(gpa);
    try testing.expect(packed_.bytes.len > 0);

    const good = try checkEssenceUnpack(packed_.bytes);
    try testing.expectEqual(@as(usize, 1), good.hits);

    // The same bytes with the body mangled past its header.
    const broken = try gpa.dupe(u8, packed_.bytes);
    defer gpa.free(broken);
    @memset(broken[8..], 0xAB);
    const bad = try checkEssenceUnpack(broken);
    try testing.expectEqual(@as(usize, 0), bad.hits);

    // Not Binary IR at all.
    _ = try checkEssenceUnpack("\xff\xfe\x00\x80");
}

test "fuzz residue.essence.unpack: arbitrary bodies are corrupt, versioned or text" {
    try testing.fuzz({}, fuzzEssenceUnpack, .{
        .corpus = &.{
            "",
            "\x00\x00\x00\x00\x00",
            "SJON\x05\x00\x00\x00",
            "SJON\xff\x00\x00\x00",
            "\xff" ** 16,
        },
    });
}

// ---------------------------------------------------------------------------
// 8. residue.smf.detach — over a sequence read from arbitrary bytes.
// ---------------------------------------------------------------------------

/// `hits` is the number of payloads the detach recovered, records and
/// essence together.
fn checkSmfDetach(input: []const u8) !Seen {
    var seen: Seen = .{};
    const gpa = testing.allocator;

    var result = try smf.read(gpa, input);
    defer result.deinit();
    try seen.noteIn(&result.diags, input.len);

    var out = try residue.smf.detach(gpa, &result.sequence);
    defer out.deinit();
    try seen.note(&out.diags);
    seen.hits = out.payloads.lanes.len +
        @intFromBool(out.payloads.essence != null) +
        @intFromBool(out.payloads.conductor != null);

    // Every track survives; only residue events are taken out.
    try testing.expectEqual(result.sequence.tracks.len, out.sequence.tracks.len);
    for (result.sequence.tracks, out.sequence.tracks) |before, after| {
        try testing.expect(after.events.len <= before.events.len);
    }
    try testing.expectEqual(result.sequence.foreign.len, out.sequence.foreign.len);

    // Detaching twice takes nothing more: a sequence with no residue in
    // it is a fixed point.
    var twice = try residue.smf.detach(gpa, &out.sequence);
    defer twice.deinit();
    try testing.expectEqual(out.sequence.tracks.len, twice.sequence.tracks.len);
    for (out.sequence.tracks, twice.sequence.tracks) |before, after| {
        try testing.expectEqual(before.events.len, after.events.len);
    }
    try testing.expectEqual(@as(usize, 0), twice.payloads.lanes.len);
    try testing.expect(twice.payloads.essence == null);
    try testing.expect(twice.payloads.conductor == null);

    // Whatever rode in is decodable-or-corrupt, never a panic.
    for (out.payloads.lanes) |body| {
        var lane = try records.decodeLane(gpa, body);
        defer lane.deinit(gpa);
    }
    if (out.payloads.conductor) |body| _ = records.decodeConductor(body);

    return seen;
}

fn fuzzSmfDetach(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkSmfDetach(buf[0..smith.sliceWithHash(&buf, 0xDE_7A_C0)]);
}

test "fuzz residue.smf.detach bites: a seated payload comes out and a foreign one stays" {
    // The seed carries one conductor record; the detach consumes it and
    // the second pass finds nothing.
    const seated = try checkSmfDetach(residue_smf);
    try testing.expectEqual(@as(usize, 1), seated.hits);
    try testing.expectEqual(@as(usize, 0), (try checkSmfDetach(minimal_smf)).hits);

    // A `7F` payload without tempura's tag belongs to somebody else and
    // is never touched — so `residue_version` is not raised either.
    const foreign =
        "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60" ++
        "MTrk\x00\x00\x00\x0c\x00\xff\x7f\x04\x7dpau\x00\xff\x2f\x00";
    const other = try checkSmfDetach(foreign);
    try testing.expect(!other.has(.residue_version));

    // A payload of a newer envelope version stays in the file and says so.
    const newer =
        "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60" ++
        "MTrk\x00\x00\x00\x10\x00\xff\x7f\x08\x7dtem\x09\x01\x00\x01\x00\xff\x2f\x00";
    const ahead = try checkSmfDetach(newer);
    try testing.expect(ahead.has(.residue_version));
}

test "fuzz residue.smf.detach: every track survives and a second detach is a no-op" {
    try testing.fuzz({}, fuzzSmfDetach, .{
        .corpus = &.{
            "",
            minimal_smf,
            residue_smf,
            "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60MTrk\x00\x00\x00\x0c\x00\xff\x7f\x04" ++
                "\x7dpau\x00\xff\x2f\x00",
            "\xff\xfe\x00\x80",
        },
    });
}

// ---------------------------------------------------------------------------
// 9. residue.it — the chunk, the split and the tail.
// ---------------------------------------------------------------------------

/// `hits` is the number of payloads a readable chunk held, records and
/// essence together.
fn checkItCarriers(input: []const u8) !Seen {
    var seen: Seen = .{};
    const gpa = testing.allocator;

    var parsed = try residue.it.parseChunk(gpa, input);
    defer parsed.deinit();
    switch (parsed) {
        .corrupt => |code| try testing.expectEqual(Diag.Code.residue_corrupt, code),
        .version => |v| {
            try testing.expect(v != records.version);
            seen.codes.insert(.residue_version);
        },
        .ok => |*p| {
            seen.hits = p.payloads.lanes.len +
                @intFromBool(p.payloads.essence != null) +
                @intFromBool(p.payloads.conductor != null);
            for (p.payloads.lanes) |body| {
                var lane = try records.decodeLane(gpa, body);
                defer lane.deinit(gpa);
            }
            if (p.payloads.conductor) |body| _ = records.decodeConductor(body);
        },
    }

    // The split is a view on the message: both halves are slices of it,
    // the human half always a prefix, the tail always at a line start.
    const split = residue.it.splitMessage(input);
    try expectSubslice(split.human, input);
    if (input.len > 0) try testing.expect(split.human.ptr == input.ptr);
    if (split.tail) |t| {
        try expectSubslice(t, input);
        try testing.expect(std.mem.startsWith(u8, t, residue.it.marker));
        const at = @intFromPtr(t.ptr) - @intFromPtr(input.ptr);
        try testing.expect(at == 0 or input[at - 1] == '\r' or input[at - 1] == '\n');
        try testing.expect(split.human.len <= at);
    } else {
        try testing.expectEqual(input.len, split.human.len);
    }

    // The tail parses back to SJON source: the escaping only ever
    // shrinks, and the result carries the sentinel `fromSource` needs.
    const text = try residue.it.parseTail(gpa, input);
    defer gpa.free(text);
    try testing.expect(text.len <= input.len);
    try testing.expectEqual(@as(u8, 0), text[text.len]);

    return seen;
}

fn fuzzItCarriers(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkItCarriers(buf[0..smith.sliceWithHash(&buf, 0x17_CA_44)]);
}

test "fuzz residue.it bites: a chunk record, a marker mid-line, and the escaping" {
    // One conductor record in chunk framing: envelope, length, 32 bytes.
    const one = try checkItCarriers(
        "\x7dtem\x01\x03\x00\x01" ++ "\x20\x00\x00\x00" ++ ("\x00" ** 32),
    );
    try testing.expectEqual(@as(usize, 1), one.hits);
    try testing.expect(!one.has(.residue_version));

    // An essence record and a lane record beside it: three payloads.
    const three = try checkItCarriers(
        "\x7dtem\x01\x01\x00\x01" ++ "\x04\x00\x00\x00" ++ "SJON" ++
            "\x7dtem\x01\x02\x00\x01" ++ "\x30\x00\x00\x00" ++
            ("\x00" ** 32) ++ "\x00\x01\x00\x00\xff\xff\x00\x00" ++ "\x04\x00\x00\x00" ++ "kick" ++
            "\x7dtem\x01\x03\x00\x01" ++ "\x20\x00\x00\x00" ++ ("\x00" ** 32),
    );
    try testing.expectEqual(@as(usize, 3), three.hits);

    // A length that runs past the chunk is corrupt framing, and the
    // variant says so rather than coming back as an empty chunk.
    const short = try checkItCarriers("\x7dtem\x01\x03\x00\x01" ++ "\xff\x00\x00\x00" ++ "\x00");
    try testing.expectEqual(@as(usize, 0), short.hits);
    var framing = try residue.it.parseChunk(
        testing.allocator,
        "\x7dtem\x01\x03\x00\x01" ++ "\xff\x00\x00\x00" ++ "\x00",
    );
    defer framing.deinit();
    try testing.expect(framing == .corrupt);

    // Only this build's version inside: the whole chunk is a newer
    // tempura's and is left alone.
    const newer = try checkItCarriers(
        "\x7dtem\x09\x03\x00\x01" ++ "\x20\x00\x00\x00" ++ ("\x00" ** 32),
    );
    try testing.expect(newer.has(.residue_version));

    // The marker counts at a line start and nowhere else.
    try testing.expect(residue.it.splitMessage("see ;; tempura for more").tail == null);
    const found = residue.it.splitMessage("hello\r;; tempura\r(timeline)");
    try testing.expect(found.tail != null);
    try testing.expectEqualStrings("hello", found.human);

    // `%XX` comes back as the byte it stood for, and `%25` as `%`.
    const gpa = testing.allocator;
    const undone = try residue.it.parseTail(gpa, ";; tempura\r(cue :name %C3%A9%25)");
    defer gpa.free(undone);
    try testing.expectEqualStrings("(cue :name \xc3\xa9%)", undone);
}

test "fuzz residue.it: a chunk, a split and a tail over arbitrary bytes" {
    try testing.fuzz({}, fuzzItCarriers, .{
        .corpus = &.{
            "",
            "\x7dtem\x01\x03\x00\x01" ++ "\x20\x00\x00\x00" ++ ("\x00" ** 32),
            "\x7dtem\x01\x01\x00\x01" ++ "\x04\x00\x00\x00" ++ "SJON",
            "\x7dtem\x09\x03\x00\x01" ++ "\x20\x00\x00\x00" ++ ("\x00" ** 32),
            ";; tempura\r(timeline :name x)\r",
            "a song text\r;; tempura\r(cue :name %25%7b)\r",
            "%",
            "%z",
            "\xff" ** 24,
        },
    });
}

// ---------------------------------------------------------------------------
// 10. doc.pipeline.dump — a whole file to a document, both kinds.
// ---------------------------------------------------------------------------

/// `hits` is the number of lane verdicts the reconciliation produced.
fn checkDump(schema: *const Schema, input: []const u8, kind: Doc.AnchorKind) !Seen {
    var seen: Seen = .{};

    var dumped = try pipeline.dump(testing.allocator, schema, input, kind, .{});
    defer dumped.deinit();

    // Spans only get `start <= end` here: a dump's report mixes spans
    // into the FILE with spans into the document text it produced
    // (`Diag.Span`'s header), and nothing may assume which.
    try seen.note(&dumped.diags);
    seen.hits = dumped.verdicts.len;

    // NUL-terminated, because the pipeline re-loads its own text.
    try testing.expectEqual(@as(u8, 0), dumped.text[dumped.text.len]);
    // One of plan 04's five rules, always.
    switch (dumped.rule) {
        .derived, .restored, .version, .corrupt, .partial => {},
    }
    // Every verdict is findable by the name it carries.
    for (dumped.verdicts) |v| {
        try testing.expect(dumped.verdictFor(v.lane) != null);
    }
    return seen;
}

fn fuzzDumpSmf(schema: *const Schema, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkDump(schema, buf[0..smith.sliceWithHash(&buf, 0xD0_5F_00)], .smf);
}

fn fuzzDumpIt(schema: *const Schema, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkDump(schema, buf[0..smith.sliceWithHash(&buf, 0xD0_17_00)], .it);
}

test "fuzz doc.pipeline.dump bites: no residue is rule 1, a torn one is rule 4" {
    var schema = try Schema.load(testing.allocator);
    defer schema.deinit();

    // A file with nothing in it: the skeleton path, and no verdicts.
    var plain = try pipeline.dump(testing.allocator, &schema, minimal_smf, .smf, .{});
    defer plain.deinit();
    try testing.expectEqual(residue.reconcile.Rule.derived, plain.rule);

    // A split essence with one part of two: all or none, so rule 4.
    const torn =
        "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60" ++
        "MTrk\x00\x00\x00\x11\x00\xff\x7f\x09\x7dtem\x01\x01\x00\x02\x00\x00\xff\x2f\x00";
    var broken = try pipeline.dump(testing.allocator, &schema, torn, .smf, .{});
    defer broken.deinit();
    try testing.expectEqual(residue.reconcile.Rule.corrupt, broken.rule);
    try testing.expect(broken.diags.count(.residue_corrupt) > 0);

    // The `.it` half: the seed carries no residue either, so it takes
    // rule 1 as well — and its one note on channel 0 becomes exactly one
    // bound lane, which is the verdict the harness counts.
    var plain_it = try pipeline.dump(testing.allocator, &schema, minimal_it, .it, .{});
    defer plain_it.deinit();
    try testing.expectEqual(residue.reconcile.Rule.derived, plain_it.rule);
    try testing.expectEqual(@as(usize, 0), plain_it.diags.count(.residue_corrupt));

    // And the harness itself runs over all three, agreeing on the count.
    _ = try checkDump(&schema, minimal_smf, .smf);
    _ = try checkDump(&schema, torn, .smf);
    const it_seen = try checkDump(&schema, minimal_it, .it);
    try testing.expectEqual(plain_it.verdicts.len, it_seen.hits);
    try testing.expectEqual(@as(usize, 1), it_seen.hits);
}

test "fuzz doc.pipeline.dump: arbitrary bytes dump as a document, .mid" {
    var schema = try Schema.load(testing.allocator);
    defer schema.deinit();
    const ctx: *const Schema = &schema;
    try testing.fuzz(ctx, fuzzDumpSmf, .{
        .corpus = &.{
            "",
            minimal_smf,
            residue_smf,
            "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60MTrk\x00\x00\x00\x08\x00\x90\x3c\x40" ++
                "\x60\x80\x3c\x40",
            "\xff\xfe\x00\x80",
        },
    });
}

test "fuzz doc.pipeline.dump: arbitrary bytes dump as a document, .it" {
    var schema = try Schema.load(testing.allocator);
    defer schema.deinit();
    const ctx: *const Schema = &schema;
    try testing.fuzz(ctx, fuzzDumpIt, .{
        .corpus = &.{
            "",
            "IMPM",
            minimal_it,
            "IMPX" ++ ("\x00" ** 188),
            "\xff" ** 64,
        },
    });
}

// ---------------------------------------------------------------------------
// 11. doc.fromSource — a whole DOCUMENT from arbitrary text.
// ---------------------------------------------------------------------------

/// `hits` is the number of roots the document came back with — anchors,
/// lanes, phrases and pass-through forms together.
///
/// This is the first of the two harnesses over the TEXT boundaries, and
/// it exists because of what the final review found there: nine
/// narrowing casts on user numbers, every one of them a panic natively
/// and a trap in the wasm (`(anchor … :size 1e30)` was the shortest).
/// `src/fuzz.zig` covered only the byte-eating entry points, so the
/// class had nowhere to be caught.
///
/// What is claimed is what holds for ARBITRARY text: the load RETURNS
/// (no panic, no assert, no leak), every diagnostic's span does not run
/// backwards and points inside the source it was read from, a saturated
/// `:size` is still a `u64`, and — the invariant that ties this to the
/// conductor rules — `mapOf` over the finished value never disagrees
/// with the map the load stored. Nothing is claimed about cleanliness:
/// random text trips every diagnostic there is.
fn checkFromSource(schema: *const Schema, input: [:0]const u8) !Seen {
    var seen: Seen = .{};
    const gpa = testing.allocator;

    var res = try doc_part.fromSource(gpa, schema, input, null);
    defer res.deinit();

    // Spans index the SOURCE here: one text in, one text's coordinates
    // out (a dump is the mixed case, and has its own harness).
    try seen.noteIn(&res.diags, input.len);
    seen.hits = res.doc.anchors.len + res.doc.lanes.len +
        res.doc.phrases.len + res.doc.passthrough.len;

    // The map is a map: a length that is not negative, and segments in
    // tick order.
    try testing.expect(res.map.length >= 0);
    var prev: i64 = -1;
    for (res.map.segments) |s| {
        try testing.expect(s.tick > prev);
        prev = s.tick;
    }

    // `mapOf` is the same answer over the finished value — the property
    // `fromSjon`'s own test pins over three documents, here over
    // whatever text came in. One document has one map or the edit engine
    // and the exporters are measuring different pieces.
    var again = try doc_part.fromSjon.mapOf(gpa, &res.doc);
    defer again.deinit();
    try testing.expectEqual(res.map.length, again.length);
    try testing.expectEqual(res.map.segments.len, again.segments.len);
    try testing.expectEqual(res.map.meters.len, again.meters.len);

    // A conducted document is either timed by its conductor or told that
    // it is not: the placeholder is never silent (the review's C1).
    if (doc_part.conductedPlaceholder(&res.doc)) {
        try testing.expect(res.diags.count(.anchor_unavailable) > 0);
    }

    try checkDownstream(gpa, &res.doc);
    return seen;
}

/// Everything a host can do with a document once it has loaded, with or
/// without errors: derive it, ask the playhead where a second or a tick
/// falls (`tpr_at` and `tpr_atTick` hand a host's number straight in,
/// NaN and the ends of i64 included), and export the pacer score. Each of
/// these asserts plan 12's invariants at its entry and on its answer;
/// this is the gate that proves no document reaches one of them — in the
/// ReleaseSmall wasm a violated assertion is undefined behaviour.
fn checkDownstream(gpa: std.mem.Allocator, doc: *const Doc.Doc) !void {
    var derived = try time.derive.derive(gpa, doc);
    defer derived.deinit();

    const seconds = [_]f64{ -1.0, 0.0, 0.5, 7.25, 1e9, std.math.inf(f64), std.math.nan(f64) };
    for (seconds) |s| {
        var pos = time.Playhead.at(gpa, &derived, s) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.TickOverflow, error.NonFiniteTime => continue,
        };
        pos.deinit(gpa);
    }
    const ticks = [_]i64{
        std.math.minInt(i64), -1, 0, 1449, time.Grid.MAX_TICK, std.math.maxInt(i64),
    };
    for (ticks) |t| {
        var pos = try time.Playhead.atTick(gpa, &derived, t);
        pos.deinit(gpa);
    }

    var score = try exporter.exportScore(gpa, doc, &derived, &.{}, .{});
    score.deinit();
}

fn fuzzFromSource(schema: *const Schema, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT + 1]u8 = undefined;
    const len = smith.sliceWithHash(buf[0..MAX_INPUT], 0xD0_C5_00);
    buf[len] = 0;
    _ = try checkFromSource(schema, buf[0..len :0]);
}

/// The known-bad document texts, kept beside the harness: each one
/// panicked somewhere before the final review's I1 was fixed, or is one
/// token away from a shape that did.
const bad_documents = [_][:0]const u8{
    // `@intFromFloat` to `u64`, `fromSjon.readAnchors`.
    "(timeline)\n(anchor :id s :kind smf :file \"x.mid\" :size 1e30)\n",
    "(timeline)\n(anchor :id s :kind smf :file \"x.mid\" :size -1e30)\n",
    // …and the same key inside an inline module, `bridge_it.readSource`.
    "(timeline :conductor s)\n(anchor :id s :kind it :file \"x.it\")\n" ++
        "(it/module (it/source :file \"x.it\" :size 1e30) (it/timing :speed 6 :tempo 125)" ++
        " (it/orders 0) (it/pattern 0 :rows 4))\n",
    // A conducted anchor with nothing to read: the placeholder, said.
    "(timeline :conductor s)\n(anchor :id s :kind smf :file \"x.mid\")\n",
    // Positions at and past the grid ceiling.
    "(timeline :length 1e30q)\n(tempo-point :at 0q :qpm 120)\n(meter-point :at 0bar :sig [4 4])\n",
    "(timeline)\n(tempo-point :at 0q :qpm 1e30)\n(meter-point :at 0bar :sig [4 4])\n",
    // A tempo no i128 holds once scaled, spelled by the score's header.
    "(timeline)\n(tempo-point :at 0q :qpm 1e300)\n(meter-point :at 0bar :sig [4 4])\n",
    "(timeline)\n(tempo-point :at 0q :us 0)\n(meter-point :at 0bar :sig [0 0])\n",
    // A row and a cell past the module's own domains.
    "(timeline :conductor s)\n(anchor :id s :kind it :file \"x.it\")\n" ++
        "(it/module (it/timing :speed 6 :tempo 125) (it/orders 0)" ++
        " (it/pattern 0 :rows 8 (row 70000 (ev 5000000000 \"C-5\"))))\n",
};

/// The corpus's own documents, by name — the seeds that are real
/// documents rather than corners.
///
/// A NAMED list and not a directory walk: the point is a reviewable set
/// of shapes (native, conducted three ways, bound to each format, every
/// position unit), and a walk would silently stop covering one the day
/// somebody renamed a case.
const corpus_documents = [_][]const u8{
    "examples-native",
    "positions-units",
    "tempo-three-conductors-native",
    "tempo-three-conductors-smf",
    "tempo-three-conductors-it",
    "tempo-by-reference-conductor",
    "edit-bound-it-cell",
    "edit-bound-smf-pair",
    "printer-rule",
};

/// Read each of `corpus_documents` into `out`, NUL-terminated. Caller
/// frees every slice.
fn readCorpusDocuments(gpa: std.mem.Allocator, out: *std.ArrayList([:0]const u8)) !void {
    const repo_root = @import("build_options").repo_root;
    for (corpus_documents) |case| {
        const path = try std.fs.path.join(gpa, &.{ repo_root, "corpus", case, "doc.sjon" });
        defer gpa.free(path);
        const text = try std.Io.Dir.cwd().readFileAllocOptions(
            testing.io,
            path,
            gpa,
            .limited(1 << 20),
            .of(u8),
            0,
        );
        errdefer gpa.free(text);
        try out.append(gpa, text);
    }
}

test "fuzz doc.fromSource bites: :size 1e30 saturates, a conducted placeholder speaks" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // The shortest reproduction of the review's I1: the cast is
    // saturating now, so the anchor's `:size` is `maxInt(u64)` and the
    // document says `anchor_mismatch` rather than dying.
    const seen = try checkFromSource(&schema, bad_documents[0]);
    try testing.expectEqual(@as(usize, 1), seen.hits);

    var res = try doc_part.fromSource(gpa, &schema, bad_documents[0], null);
    defer res.deinit();
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), res.doc.anchors[0].size.?);

    // …and C1's invariant fires on purpose: a conducted anchor with
    // nothing to read is `anchor_unavailable`, never a silent 120 qpm.
    var conducted = try doc_part.fromSource(gpa, &schema, bad_documents[3], null);
    defer conducted.deinit();
    try testing.expect(doc_part.conductedPlaceholder(&conducted.doc));
    try testing.expect(conducted.diags.count(.anchor_unavailable) > 0);

    // Every other known-bad text runs through the harness too, so the
    // whole list is exercised on a plain `zig build fuzz`.
    for (bad_documents) |text| _ = try checkFromSource(&schema, text);
}

test "fuzz doc.fromSource: arbitrary text loads as a document, never a panic" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var seeds: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (seeds.items) |s| gpa.free(s);
        seeds.deinit(gpa);
    }
    try readCorpusDocuments(gpa, &seeds);

    var corpus: std.ArrayList([]const u8) = .empty;
    defer corpus.deinit(gpa);
    try corpus.append(gpa, "");
    for (bad_documents) |text| try corpus.append(gpa, text);
    for (seeds.items) |text| try corpus.append(gpa, text);

    const ctx: *const Schema = &schema;
    try testing.fuzz(ctx, fuzzFromSource, .{ .corpus = corpus.items });
}

// ---------------------------------------------------------------------------
// 12. edit.Op.fromJson / edit.fromActionsJson — an operation and an
//     action list from arbitrary JSON-ish text.
// ---------------------------------------------------------------------------

/// `hits` is 1 when the text was an operation, 0 when it was refused.
///
/// The second text boundary, and the one the review's table is mostly
/// about: `{"at":1e30}`, `{"repeat":5000000000}`, `{"swing":-1e300}` all
/// panicked, and every operation goes through the same three readers. An
/// action list is here beside it because `Plan.fromActionsJson` is the
/// other half of plan 10's surface (`tpr_apply` takes one) and reads the
/// same numbers.
///
/// What is claimed: both readers RETURN for any text; an operation that
/// came back is one the planner accepts (so a refusal is a diagnostic
/// and never a half-built value); a refused one carries at least one
/// error; and a `:swing` / `:strength` that did come back is inside the
/// range its rule is defined on.
fn checkOpJson(fx: *const edit_support.Fixture, input: []const u8) !Seen {
    var seen: Seen = .{};
    const gpa = testing.allocator;

    var parsed = try edit.fromJson(gpa, input);
    defer parsed.deinit();
    try seen.note(&parsed.diags);

    if (parsed.op) |op| {
        seen.hits = 1;
        // The fractions are clamped at the reader, so a value that got
        // through is one the grid has a line for.
        if (op == .quantize) {
            try testing.expect(op.quantize.strength >= 0 and op.quantize.strength <= 1);
            try testing.expect(op.quantize.swing >= -1 and op.quantize.swing <= 1);
        }
        // …and it plans: TOTAL over the fixture, refused or not, with no
        // assertion on any number it carried in.
        var planned = try edit.plan(gpa, fx.doc_(), &fx.tree, op);
        defer planned.deinit();
        if (planned.summary.refused) try testing.expect(planned.actions.len == 0);
    } else {
        try testing.expect(parsed.diags.hasErrors());
    }

    // The action list reads the same numbers through its own door.
    var actions = try edit.fromActionsJson(gpa, input);
    defer actions.deinit();
    try seen.note(&actions.diags);
    return seen;
}

fn fuzzOpJson(fx: *const edit_support.Fixture, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    _ = try checkOpJson(fx, buf[0..smith.sliceWithHash(&buf, 0x0E_51_70)]);
}

/// The known-bad operation texts: the review's table, one row each.
const bad_ops = [_][]const u8{
    \\{"op":"retime","sel":{},"delta":1e30}
    ,
    \\{"op":"retime","sel":{},"delta":-1e30}
    ,
    \\{"op":"split","sel":{},"at":1e300}
    ,
    \\{"op":"resize","sel":{},"repeat":5000000000}
    ,
    \\{"op":"nudge","sel":{},"grid":"1/16","count":5000000000}
    ,
    \\{"op":"stretch","from":0,"to":9223372036854775807,"p":4294967295,"q":1}
    ,
    // The re-review's residual: `to -| from` saturated, so the ratio
    // ceiling did not fire and `stretched` overflowed on `tick - from`.
    \\{"op":"stretch","from":-9223372036854775808,"to":1,"p":1,"q":4000000000}
    ,
    // …and the other half of "an accepted plan is applicable": this
    // planned an `:at` the document could not load back.
    \\{"op":"retime","sel":{"lanes":["flash"],"kinds":["note"]},"delta":9223372036854775807}
    ,
    \\{"op":"quantize","sel":{},"grid":"1/8","swing":-1e300}
    ,
    \\{"op":"quantize","sel":{},"grid":"1/8","strength":1e300,"swing":1e300}
    ,
    \\{"op":"insert","lane":"flash","note":{"at":1e30,"dur":1e30,"key":1e30}}
    ,
    // …and a STRING where a tick goes, which read as the field's default
    // — tick 0 — and planned a point nobody asked for, with no complaint.
    \\{"op":"insert-tempo","at":"4q","qpm":110}
    ,
    \\[{"op":"set_keyword","root":4294967296,"path":[0],"key":"at","value":{"$num":[1e30,"q"]}}]
    ,
};

test "fuzz edit.Op.fromJson bites: every number of the review's table is refused" {
    const gpa = testing.allocator;
    var fx = try edit_support.Fixture.init(gpa, edit_support.native);
    defer fx.deinit();

    // The ones that name an impossible NUMBER are refused; the two that
    // name an impossible FRACTION are clamped and plan.
    for (bad_ops) |text| {
        const seen = try checkOpJson(&fx, text);
        try testing.expect(seen.diags > 0 or seen.hits == 1);
    }

    // Looked up by CONTENT and not by index, so a row added to the table
    // cannot quietly move which claim is made about what.
    var wild = try edit.fromJson(gpa, opNamed("\"delta\":1e30"));
    defer wild.deinit();
    try testing.expect(wild.op == null);
    try testing.expect(wild.diags.hasErrors());

    var swung = try edit.fromJson(gpa, opNamed("\"swing\":-1e300"));
    defer swung.deinit();
    try testing.expectEqual(@as(f64, -1), swung.op.?.quantize.swing);

    // The two the re-review found: each READS as an operation (the
    // numbers fit an `i64`) and is refused by the PLANNER with
    // `tick_overflow`, before the arithmetic that used to overflow and
    // before a document nothing could load back.
    for ([_][]const u8{
        opNamed("\"from\":-9223372036854775808"),
        opNamed("\"delta\":9223372036854775807"),
    }) |text| {
        var parsed = try edit.fromJson(gpa, text);
        defer parsed.deinit();
        try testing.expect(parsed.op != null);

        var planned = try edit.plan(gpa, fx.doc_(), &fx.tree, parsed.op.?);
        defer planned.deinit();
        try testing.expectEqual(@as(usize, 0), planned.actions.len);
        try testing.expect(planned.summary.refused);
        try testing.expect(planned.findDiag(.tick_overflow) != null);
    }
}

/// The entry of `bad_ops` that holds `needle`. A lookup by content, so
/// the bite test's claims cannot drift onto the wrong row.
fn opNamed(comptime needle: []const u8) []const u8 {
    for (bad_ops) |text| {
        if (std.mem.indexOf(u8, text, needle) != null) return text;
    }
    unreachable;
}

test "fuzz edit.Op.fromJson: arbitrary JSON-ish text is an operation or a refusal" {
    const gpa = testing.allocator;
    var fx = try edit_support.Fixture.init(gpa, edit_support.native);
    defer fx.deinit();

    var corpus: std.ArrayList([]const u8) = .empty;
    defer corpus.deinit(gpa);
    try corpus.append(gpa, "");
    try corpus.append(gpa, "{}");
    try corpus.append(gpa, "[]");
    try corpus.append(gpa, "not json");
    for (bad_ops) |text| try corpus.append(gpa, text);

    const ctx: *const edit_support.Fixture = &fx;
    try testing.fuzz(ctx, fuzzOpJson, .{ .corpus = corpus.items });
}
