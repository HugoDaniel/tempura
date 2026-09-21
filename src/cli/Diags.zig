//! Diagnostics for a person: source coordinates, the one rendered line,
//! and the colour policy.
//!
//! Every span tempura produces is a RAW BYTE OFFSET into the source
//! (`Diag.Span`, SJON's own convention: the manifests are preloaded
//! beside the document rather than prepended to it, so a span is document
//! coordinates by construction and the library translates them nowhere).
//! The CLI is the first consumer that has to show a person WHERE, so the
//! conversion lives here and only here.
//!
//! The rendered shape is SJON's and pacer's, so that `sjon check x.sjon`,
//! `pacer check x.score.sjon` and `tempura validate x.sjon` all produce
//! lines one editor's error parser and one `grep` pipeline understand:
//!
//! ```text
//! doc.sjon:12:5: error anchor_missing: no (anchor …) is named `song`
//! ```
//!
//! ## Two coordinate spaces, and the line says which
//!
//! A span means different things depending on who raised it, so `Space`
//! makes the caller say. A DOCUMENT diagnostic's span indexes the source
//! text and becomes a line and a column. A FILE diagnostic's — the SMF and
//! IT readers', and the writers', whose `Emit.diag` carries the emission's
//! own cursor — indexes bytes that are not that text at all, and is shown
//! as the offset it is:
//!
//! ```text
//! song.mid:0x0000002b: error smf_track_truncated: 40 bytes declared, 31 present
//! ```
//!
//! Rendering the second as a line and column was a bug this CLI shipped
//! for an afternoon: `build --ppq 7` blamed line 1 column 34 of a header
//! comment for a tick the writer could not rescale.
//!
//! Colour is decided ONCE, by `main`, through `colorEnabled` — a pure
//! function of the two facts that matter, so `NO_COLOR` is a tested rule
//! and not an untestable `if` in an entry point.

const std = @import("std");
const tempura = @import("tempura");

const Diag = tempura.Diag;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// What a diagnostic line calls this input.
pub fn label(path: []const u8) []const u8 {
    return if (isStdin(path)) "<stdin>" else path;
}

pub fn isStdin(path: []const u8) bool {
    return path.len == 1 and path[0] == '-';
}

/// no-color.org's rule, and nothing beyond it: colour when the stream is
/// a terminal and `NO_COLOR` is not set to anything non-empty. A
/// redirected stream is never coloured, which is what keeps the goldens
/// plain without the golden script having to say so.
pub fn colorEnabled(no_color_set: bool, is_tty: bool) bool {
    return is_tty and !no_color_set;
}

/// The three SGR sequences this CLI uses, and nothing more: a severity
/// word is the only thing worth colouring in a line whose whole value is
/// that it is greppable.
pub const Style = struct {
    enabled: bool = false,

    pub fn severity(self: Style, w: *Writer, sev: Diag.Severity) Writer.Error!void {
        if (!self.enabled) return;
        try w.writeAll(switch (sev) {
            .err => "\x1b[31m",
            .warning => "\x1b[33m",
            .info => "\x1b[36m",
        });
    }

    pub fn reset(self: Style, w: *Writer) Writer.Error!void {
        if (self.enabled) try w.writeAll("\x1b[0m");
    }
};

pub const Counts = struct { errors: u32 = 0, warnings: u32 = 0, infos: u32 = 0 };

pub fn count(diags: []const Diag.Diagnostic) Counts {
    var c: Counts = .{};
    for (diags) |d| switch (d.severity) {
        .err => c.errors += 1,
        .warning => c.warnings += 1,
        .info => c.infos += 1,
    };
    return c;
}

pub fn severityWord(sev: Diag.Severity) []const u8 {
    return switch (sev) {
        .err => "error",
        .warning => "warning",
        .info => "info",
    };
}

/// The exit code a set of diagnostics earns: errors are the document's
/// problem and set the code; a warning never does.
pub fn exitCode(diags: []const Diag.Diagnostic) u8 {
    return if (count(diags).errors > 0) 1 else 0;
}

/// Which bytes a diagnostic's span is counting.
pub const Space = union(enum) {
    /// Into a source TEXT: the span becomes a 1-based line and column
    /// through this index.
    text: *const LineIndex,
    /// Into a FILE, or into the bytes a writer is producing. There is no
    /// text to count lines in, so the offset is printed as an offset —
    /// which is also the coordinate `tempura inspect` prints, so the two
    /// can be read side by side.
    bytes,
};

/// One `path:LINE:COL:` or `path:0xOFFSET:` line per diagnostic, then
/// `severity code: message`.
///
/// In the order the producer found them — never sorted, because the order
/// a walk reports in is information (the first error is usually the
/// cause of the rest) and a sort would hide it.
pub fn render(
    w: *Writer,
    path: []const u8,
    space: Space,
    diags: []const Diag.Diagnostic,
    style: Style,
) Writer.Error!void {
    // The read side of `Diag.List`'s contract, over whatever the verb
    // joined: every code has a name to print.
    Diag.invariantsOf(diags);
    const name = label(path);
    for (diags) |d| {
        switch (space) {
            .text => |index| {
                const pos = index.at(d.span.start);
                try w.print("{s}:{d}:{d}: ", .{ name, pos.line, pos.col });
            },
            .bytes => try w.print("{s}:0x{X:0>8}: ", .{ name, d.span.start }),
        }
        try style.severity(w, d.severity);
        try w.writeAll(severityWord(d.severity));
        try style.reset(w);
        try w.print(" {s}: {s}\n", .{ @tagName(d.code), d.message });
    }
}

/// The trailing count line: what a CI log reads at a glance.
pub fn summary(w: *Writer, path: []const u8, diags: []const Diag.Diagnostic) Writer.Error!void {
    const c = count(diags);
    if (c.errors == 0 and c.warnings == 0 and c.infos == 0) {
        try w.print("{s}: no diagnostics\n", .{label(path)});
        return;
    }
    try w.print("{d} error{s}, {d} warning{s}", .{
        c.errors,   if (c.errors == 1) "" else "s",
        c.warnings, if (c.warnings == 1) "" else "s",
    });
    // `info` is a producer reporting a CHOICE, not a defect; it earns a
    // place in the count only when there is one, so the usual line stays
    // the two numbers everybody already reads.
    if (c.infos > 0) try w.print(", {d} note{s}", .{ c.infos, if (c.infos == 1) "" else "s" });
    try w.writeAll("\n");
}

pub const Pos = struct { line: u32, col: u32 };

/// Byte offset → 1-based (line, column) over one loaded source.
///
/// `line` counts `'\n'` only, so a lone `'\r'` is an ordinary column and a
/// CRLF file's `'\r'` sits at the end of the previous line — what every
/// editor shows, and what SJON's own renderer does.
///
/// `col` counts UNICODE CODEPOINTS, not bytes: that is what a person
/// means by "column 7". An offset landing INSIDE a sequence rounds DOWN
/// to that codepoint's first byte, so a span clipped mid-character still
/// points at the character.
///
/// Built once per source (one pass for the line starts, binary search per
/// lookup): a document with many diagnostics asks many times.
pub const LineIndex = struct {
    source: []const u8,
    /// Byte offset of each line's first byte. `[0] == 0`, ascending.
    line_starts: []const u32,

    /// `line_starts` is owned by the returned index and freed by `deinit`
    /// with the same `gpa`; `source` is borrowed for the index's life.
    pub fn build(gpa: Allocator, source: []const u8) Allocator.Error!LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);
        try starts.append(gpa, 0);
        for (source, 0..) |b, i| {
            if (b == '\n') try starts.append(gpa, @intCast(i + 1));
        }
        return .{ .source = source, .line_starts = try starts.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: *LineIndex, gpa: Allocator) void {
        gpa.free(self.line_starts);
        self.* = undefined;
    }

    pub fn at(self: *const LineIndex, offset: u32) Pos {
        // Past-EOF clamps rather than panicking: a span is host data
        // here, and an EOF span (`start == source.len`) is ordinary.
        var off: usize = @min(offset, self.source.len);
        // Round down out of the middle of a sequence.
        while (off > 0 and off < self.source.len and isContinuation(self.source[off])) off -= 1;

        const line = upperBound(self.line_starts, off);
        const start = self.line_starts[line];

        var col: u32 = 1;
        var i: usize = start;
        while (i < off) {
            const len = std.unicode.utf8ByteSequenceLength(self.source[i]) catch 1;
            // A truncated tail still advances, so this cannot spin.
            i += @min(@as(usize, len), off - i);
            col += 1;
        }
        return .{ .line = @intCast(line + 1), .col = col };
    }
};

fn isContinuation(b: u8) bool {
    return b & 0xc0 == 0x80;
}

/// Index of the last entry `<= off`. `starts[0] == 0 <= off` always, so
/// this is total.
fn upperBound(starts: []const u32, off: usize) usize {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (starts[mid] <= off) lo = mid else hi = mid;
    }
    return lo;
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn idx(source: []const u8) !LineIndex {
    return LineIndex.build(t.allocator, source);
}

test "LineIndex: ASCII offsets map to 1-based line and column" {
    var li = try idx("abc\ndef\n");
    defer li.deinit(t.allocator);
    try t.expectEqual(Pos{ .line = 1, .col = 1 }, li.at(0));
    try t.expectEqual(Pos{ .line = 1, .col = 3 }, li.at(2));
    try t.expectEqual(Pos{ .line = 2, .col = 1 }, li.at(4));
    try t.expectEqual(Pos{ .line = 2, .col = 3 }, li.at(6));
}

test "LineIndex: columns count codepoints, and a mid-sequence offset rounds down" {
    // "é" is 2 bytes, "€" 3, "🎛" 4 — the 'x' after them is column 4.
    const src = "é€🎛x";
    var li = try idx(src);
    defer li.deinit(t.allocator);
    try t.expectEqual(@as(u32, 4), li.at(@intCast(src.len - 1)).col);

    const mid = "a€b"; // '€' occupies bytes 1..3
    var m = try idx(mid);
    defer m.deinit(t.allocator);
    try t.expectEqual(@as(u32, 2), m.at(1).col);
    try t.expectEqual(@as(u32, 2), m.at(2).col);
    try t.expectEqual(@as(u32, 3), m.at(4).col);
}

test "LineIndex: a CR is an ordinary column; only LF advances the line" {
    var li = try idx("ab\r\ncd");
    defer li.deinit(t.allocator);
    try t.expectEqual(Pos{ .line = 1, .col = 3 }, li.at(2));
    try t.expectEqual(Pos{ .line = 2, .col = 1 }, li.at(4));
}

test "LineIndex: EOF, past-EOF and an invalid lead byte clamp instead of panicking" {
    const src = "abc";
    var li = try idx(src);
    defer li.deinit(t.allocator);
    try t.expectEqual(Pos{ .line = 1, .col = 4 }, li.at(3));
    try t.expectEqual(Pos{ .line = 1, .col = 4 }, li.at(999));

    var bad = try idx("a\x80\x80b");
    defer bad.deinit(t.allocator);
    try t.expectEqual(@as(u32, 4), bad.at(3).col);

    var empty = try idx("");
    defer empty.deinit(t.allocator);
    try t.expectEqual(Pos{ .line = 1, .col = 1 }, empty.at(0));
}

test "label: `-` reads as <stdin>, a path reads as itself" {
    try t.expectEqualStrings("<stdin>", label("-"));
    try t.expectEqualStrings("doc.sjon", label("doc.sjon"));
}

test "colorEnabled: NO_COLOR wins, and a redirected stream is never coloured" {
    try t.expectEqual(true, colorEnabled(false, true));
    try t.expectEqual(false, colorEnabled(true, true));
    try t.expectEqual(false, colorEnabled(false, false));
    try t.expectEqual(false, colorEnabled(true, false));
}

/// Render `diags` over `source` into an owned string, the way a verb
/// does. The test join.
fn rendered(source: []const u8, diags: []const Diag.Diagnostic, style: Style) ![]u8 {
    var li = try LineIndex.build(t.allocator, source);
    defer li.deinit(t.allocator);
    var out: Writer.Allocating = .init(t.allocator);
    errdefer out.deinit();
    try render(&out.writer, "doc.sjon", .{ .text = &li }, diags, style);
    try summary(&out.writer, "doc.sjon", diags);
    return out.toOwnedSlice();
}

test "render: the line is path:line:col: severity code: message, in producer order" {
    const source = "(timeline)\n(anchor :id song)\n";
    var list: Diag.List = .init(t.allocator);
    defer list.deinit();
    try list.add(
        .anchor_missing,
        .err,
        .{ .start = 11, .end = 27 },
        "no anchor named {s}",
        .{"song"},
    );
    try list.add(
        .division_inexact,
        .warning,
        .{ .start = 0, .end = 10 },
        "480 does not divide",
        .{},
    );

    const text = try rendered(source, list.items(), .{});
    defer t.allocator.free(text);
    try t.expectEqualStrings(
        \\doc.sjon:2:1: error anchor_missing: no anchor named song
        \\doc.sjon:1:1: warning division_inexact: 480 does not divide
        \\1 error, 1 warning
        \\
    , text);
}

test "render: a clean document says so, and colour is the severity word alone" {
    const empty = try rendered("(timeline)\n", &.{}, .{});
    defer t.allocator.free(empty);
    try t.expectEqualStrings("doc.sjon: no diagnostics\n", empty);

    var list: Diag.List = .init(t.allocator);
    defer list.deinit();
    try list.add(.tick_overflow, .err, .{ .start = 0, .end = 1 }, "past the ceiling", .{});
    const plain = try rendered("(x)\n", list.items(), .{ .enabled = false });
    defer t.allocator.free(plain);
    const colored = try rendered("(x)\n", list.items(), .{ .enabled = true });
    defer t.allocator.free(colored);
    try t.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    try t.expect(std.mem.indexOf(u8, colored, "\x1b[31merror\x1b[0m") != null);
    // Everything else on the line is untouched, so the two differ only
    // by the escapes.
    try t.expect(std.mem.indexOf(u8, colored, "tick_overflow: past the ceiling") != null);
}

test "exitCode and the counts: a warning never fails, an error always does" {
    var list: Diag.List = .init(t.allocator);
    defer list.deinit();
    try list.add(.smpte_tempo_ignored, .warning, .{ .start = 0, .end = 0 }, "ignored", .{});
    try list.add(.residue_only, .info, .{ .start = 0, .end = 0 }, "noted", .{});
    try t.expectEqual(@as(u8, 0), exitCode(list.items()));
    try t.expectEqual(Counts{ .errors = 0, .warnings = 1, .infos = 1 }, count(list.items()));

    try list.add(.smf_bad_header, .err, .{ .start = 0, .end = 0 }, "bad", .{});
    try t.expectEqual(@as(u8, 1), exitCode(list.items()));
}

test "render: a file diagnostic shows its byte offset, not a line and a column" {
    // The readers' and the writers' spans index bytes that are not the
    // text being reported against, so a line and a column would name a
    // place with nothing to do with them.
    var list: Diag.List = .init(t.allocator);
    defer list.deinit();
    try list.add(
        .smf_track_truncated,
        .err,
        .{ .start = 0x2b, .end = 0x2b },
        "40 declared, 31 present",
        .{},
    );

    var out: Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try render(&out.writer, "song.mid", .bytes, list.items(), .{});
    try t.expectEqualStrings(
        "song.mid:0x0000002B: error smf_track_truncated: 40 declared, 31 present\n",
        out.written(),
    );
}
