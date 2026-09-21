//! `tempura dump FILE [-o DOC]` — a `.mid` or a `.it` as a document.
//!
//! Plan 10's row: "file → document: the `midi/` or `it/` tier inline, the
//! timeline tier from the residue or derived; `--spans` adds byte offsets
//! as comments; `--patterns=bin`, `--preserve-foreign`,
//! `--preserve-history`; `--cues` emits a cue per played order".
//!
//! ## The whole dump is `doc/pipeline.zig`
//!
//! Read, detach or choose the carrier, bridge the file into its tier,
//! reconcile plan 04's five rules, splice, and load the result back as a
//! document — one function, `pipeline.dump`, because the assembly needs
//! every layer at once and a host that did it itself would be a second
//! opinion about what a file means. This verb is the invocation: which
//! bytes, which switches, where the text goes, and who hears about what.
//!
//! The rule that ran is visible in the FIRST LINE of what comes back:
//! a restored document opens with the author's own text, and an inferred
//! one opens with `; skeleton: derived, …` naming why (no residue, a
//! newer version, a payload that would not decode) or `; partial: …` for
//! the IT message tail alone.
//!
//! ## `--spans` is the CLI's, and stays the CLI's
//!
//! The annotated offsets are a READING AID — a comment block naming
//! where in the file each chunk, event or region came from — and no
//! document was ever meant to carry them: they are not part of the
//! dumped value, `build` ignores them, and a second reader would have to
//! strip them. So they are produced here, from a second read of the same
//! bytes, and spliced in front of the tier the pipeline already placed.
//! The second read costs one pass over a file the user asked to have
//! annotated; the alternative is a source map threaded through an
//! assembly that has no other use for one.
//!
//! ## Two coordinate spaces, one report
//!
//! `pipeline.dump` returns "everything the read, the carrier, the
//! reconciliation and the re-load had to say, in that order". The first
//! three count the FILE's bytes; the last counts the assembled text, and
//! can only ever mean a tempura defect (a dump that does not read back as
//! a document). `Diag.Diagnostic` records no space, so the whole report
//! is rendered in the file's — an offset is a true coordinate for the
//! three that matter, and the CODE says which bytes any given line
//! counts.

const std = @import("std");
const tempura = @import("tempura");

const Args = @import("Args.zig");
const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const Writer = std.Io.Writer;
const pipeline = tempura.doc.pipeline;

/// The anchor id every dumped document uses. One file per dump, so one
/// name, and it is the one every corpus fixture already spells.
pub const anchor_id = pipeline.anchor_id;

pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    const bytes = Cli.load(ctx.a, ctx.io, ctx.cmd.path) catch |e|
        return Cli.reportLoadFailure(ctx, e);

    const kind = try ctx.sniffKind(bytes) orelse return Cli.Exit.usage;

    var schema = try tempura.Schema.load(ctx.gpa);
    defer schema.deinit();

    var dumped = try pipeline.dump(ctx.gpa, &schema, bytes, Cli.anchorKind(kind), .{
        .file = anchorFile(ctx, kind),
        .cues = ctx.cmd.dump.cues,
        .patterns_bin = ctx.cmd.dump.patterns_bin,
        .preserve_foreign = ctx.cmd.dump.preserve_foreign,
        .preserve_history = ctx.cmd.dump.preserve_history,
    });
    defer dumped.deinit();

    var art: Writer.Allocating = .init(ctx.gpa);
    defer art.deinit();
    if (ctx.cmd.dump.spans) {
        const block = try spansBlock(ctx, kind, bytes);
        defer ctx.gpa.free(block);
        try spliceAfterAnchor(&art.writer, dumped.text, block);
    } else {
        try art.writer.writeAll(dumped.text);
    }

    if (!try ctx.emit(art.written())) return Cli.Exit.usage;

    try Diags.render(ctx.err, ctx.cmd.path, .bytes, dumped.diags.items(), ctx.style);
    return Diags.exitCode(dumped.diags.items());
}

/// The `--spans` comment block: one line per thing the reader placed,
/// with the offset it was placed at. Owned by the caller.
fn spansBlock(ctx: *const Cli.Ctx, kind: Args.Kind, bytes: []const u8) Cli.Error![]u8 {
    var out: Writer.Allocating = .init(ctx.gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("; spans: the reader's byte offsets into \"{s}\"\n", .{anchorFile(ctx, kind)});

    switch (kind) {
        .mid => {
            var res = try tempura.smf.read(ctx.gpa, bytes);
            defer res.deinit();
            for (res.source_map.chunks, 0..) |c, i| {
                try w.print(";   chunk {d}  {s}  at 0x{X:0>8}  body {d}\n", .{
                    i, Cli.printableTag(&c.tag), c.offset, c.len,
                });
            }
            for (res.source_map.tracks, res.sequence.tracks, 0..) |tm, tr, ti| {
                for (tm.events, tr.events, 0..) |site, ev, ei| {
                    try w.print(";   track {d} event {d}  at 0x{X:0>8}  tick {d}  {s}{s}\n", .{
                        ti + 1,                                              ei, site.offset, ev.at, @tagName(ev.kind),
                        if (site.running_status) "  running-status" else "",
                    });
                }
            }
        },
        .it => {
            var res = try tempura.itf.read.read(ctx.gpa, bytes);
            defer res.deinit();
            for (res.source_map.entries) |e| {
                try w.print(";   {s: <14} #{d}  at 0x{X:0>8}  len {d}\n", .{
                    @tagName(e.kind), e.index, e.region.off, e.region.len,
                });
            }
        },
    }
    return out.toOwnedSlice();
}

/// Write `text` with `block` inserted straight after its `(anchor …)`
/// line — in front of the tier the pipeline spliced there.
///
/// The printer emits an anchor on ONE line and the tier follows it,
/// because plan 02's anchor/dump pairing is positional. When there is no
/// anchor at all (nothing in this verb produces that, but a renderer must
/// not be the thing that panics), the block is appended, which is still
/// the order it was written in.
pub fn spliceAfterAnchor(w: *Writer, text: []const u8, block: []const u8) Writer.Error!void {
    const at = std.mem.indexOf(u8, text, "(anchor ") orelse {
        try w.writeAll(text);
        try w.writeAll(block);
        return;
    };
    const eol = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    const cut = @min(eol + 1, text.len);
    try w.writeAll(text[0..cut]);
    try w.writeAll(block);
    try w.writeAll(text[cut..]);
}

/// What the dumped anchor's `:file` says.
///
/// The BASENAME, because plan 02 resolves an `:file` "relative to the
/// document" and a dump usually lands beside its file. Stdin has no name
/// at all, so it gets one that says where it came from rather than a `-`
/// no resolver could ever honour.
fn anchorFile(ctx: *const Cli.Ctx, kind: Args.Kind) []const u8 {
    if (Diags.isStdin(ctx.cmd.path)) return switch (kind) {
        .mid => "stdin.mid",
        .it => "stdin.it",
    };
    return std.fs.path.basename(ctx.cmd.path);
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "spliceAfterAnchor: the block lands on the line after the anchor, never elsewhere" {
    var out: Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try spliceAfterAnchor(
        &out.writer,
        "(timeline :conductor song)\n\n(anchor :id song :kind it :file \"x.it\")\n(it/module)\n",
        "; spans\n",
    );
    try t.expectEqualStrings(
        \\(timeline :conductor song)
        \\
        \\(anchor :id song :kind it :file "x.it")
        \\; spans
        \\(it/module)
        \\
    , out.written());
}

test "spliceAfterAnchor: no anchor appends rather than panicking" {
    var out: Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try spliceAfterAnchor(&out.writer, "(timeline)\n", "; spans\n");
    try t.expectEqualStrings("(timeline)\n; spans\n", out.written());
}

test "dump: an SMF with no residue derives its tier and says so on the first line" {
    const path = try Cli.repoPath(t.allocator, "corpus/skeleton-smf/song.mid");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "dump", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());

    const text = c.out.written();
    try t.expect(std.mem.startsWith(u8, text, "; skeleton: derived, no residue found\n"));
    try t.expect(std.mem.indexOf(u8, text, ":conductor song") != null);
    try t.expect(std.mem.indexOf(u8, text, "(anchor :id song :kind smf :file \"song.mid\" :size ") != null);
    try t.expect(std.mem.indexOf(u8, text, "(midi/smf ") != null);
    // Rule 1's derived tier: a bound lane per address the file uses.
    try t.expect(std.mem.indexOf(u8, text, ":from song") != null);
}

test "dump: a file that carries a residue comes back as the document that was written" {
    // Round trip through the CLI: a native document built with the
    // residue attached, dumped back. Plan 04's rule 2 restores the
    // AUTHOR's text, not a re-derivation of it, so the header comment is
    // the document's own and not the skeleton's.
    const a = t.allocator;
    const src = try Cli.repoPath(a, "corpus/tempo-three-conductors-native/doc.sjon");
    defer a.free(src);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(dir);
    const built = try std.fmt.allocPrintSentinel(a, "{s}/song.mid", .{dir}, 0);
    defer a.free(built);

    var b = try Cli.invoke(&.{ "tempura", "build", src, "-o", built });
    defer b.deinit();
    try t.expectEqual(Cli.Exit.ok, b.code);

    var d = try Cli.invoke(&.{ "tempura", "dump", built });
    defer d.deinit();
    try t.expectEqual(Cli.Exit.ok, d.code);
    try t.expect(std.mem.indexOf(u8, d.out.written(), "; skeleton:") == null);
    // The document's own first line, restored verbatim.
    try t.expect(std.mem.indexOf(u8, d.out.written(), "; The three-segment map of plan 03") != null);
}

test "dump: an IT becomes a document, and --patterns=bin swaps rows for a ref" {
    const a = t.allocator;
    const path = try Cli.repoPath(a, "corpus/it-minimal/song.it");
    defer a.free(path);

    var rows = try Cli.invoke(&.{ "tempura", "dump", path });
    defer rows.deinit();
    try t.expectEqual(Cli.Exit.ok, rows.code);
    try t.expect(std.mem.indexOf(u8, rows.out.written(), "(it/module") != null);
    try t.expect(std.mem.indexOf(u8, rows.out.written(), "(row ") != null);

    var bin = try Cli.invoke(&.{ "tempura", "dump", path, "--patterns=bin" });
    defer bin.deinit();
    try t.expectEqual(Cli.Exit.ok, bin.code);
    try t.expect(std.mem.indexOf(u8, bin.out.written(), "(row ") == null);
    try t.expect(std.mem.indexOf(u8, bin.out.written(), "(bin ") != null);
    // The compaction is the point: it 03's skeleton view is smaller.
    try t.expect(bin.out.written().len < rows.out.written().len);
}

test "dump --spans: the reader's offsets ride as comments, and nothing else moves" {
    const a = t.allocator;
    const path = try Cli.repoPath(a, "corpus/smf-running-status/song.mid");
    defer a.free(path);

    var plain = try Cli.invoke(&.{ "tempura", "dump", path });
    defer plain.deinit();
    var spans = try Cli.invoke(&.{ "tempura", "dump", path, "--spans" });
    defer spans.deinit();

    try t.expect(std.mem.indexOf(u8, plain.out.written(), "; spans:") == null);
    try t.expect(std.mem.indexOf(u8, spans.out.written(), "; spans: the reader's byte offsets into \"song.mid\"") != null);
    try t.expect(std.mem.indexOf(u8, spans.out.written(), ";   chunk 0  MThd  at 0x00000000") != null);
    try t.expect(std.mem.indexOf(u8, spans.out.written(), "running-status") != null);
    // Every line of the plain dump is still in the annotated one.
    try t.expect(spans.out.written().len > plain.out.written().len);
}

test "dump --cues: an order list becomes cues, and without the flag it does not" {
    const a = t.allocator;
    const path = try Cli.repoPath(a, "corpus/skeleton-it/song.it");
    defer a.free(path);

    var quiet = try Cli.invoke(&.{ "tempura", "dump", path });
    defer quiet.deinit();
    var cues = try Cli.invoke(&.{ "tempura", "dump", path, "--cues" });
    defer cues.deinit();

    try t.expect(std.mem.indexOf(u8, quiet.out.written(), "(cue ") == null);
    try t.expect(std.mem.indexOf(u8, cues.out.written(), "(cue ") != null);
}

test "dump: the document it produces validates, which is the round trip" {
    // The dump is written to a temp directory BESIDE a copy of the file
    // it anchors, because the anchor carries a `:size` and a `:sha256`
    // and `validate` really checks them.
    const a = t.allocator;
    const src = try Cli.repoPath(a, "corpus/it-minimal/song.it");
    defer a.free(src);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, src, a, .limited(1 << 20));
    defer a.free(bytes);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "song.it", .data = bytes });

    const dest = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/doc.sjon", .{tmp.sub_path}, 0);
    defer a.free(dest);

    var d = try Cli.invoke(&.{ "tempura", "dump", src, "-o", dest });
    defer d.deinit();
    try t.expectEqual(Cli.Exit.ok, d.code);
    try t.expectEqualStrings("", d.out.written());

    var v = try Cli.invoke(&.{ "tempura", "validate", dest });
    defer v.deinit();
    try t.expectEqual(Cli.Exit.ok, v.code);
}

test "dump: a file that is neither kind is a usage error with an empty stdout" {
    const path = try Cli.repoPath(t.allocator, "corpus/it-minimal/times.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "dump", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
}
