//! `tempura dump FILE [-o DOC]` — a `.mid` or a `.it` as a document.
//!
//! Plan 10's row: "file → document: the `midi/` or `it/` tier inline, the
//! timeline tier from the residue or derived; `--spans` adds byte offsets
//! as comments; `--patterns=bin`, `--preserve-foreign`,
//! `--preserve-history`; `--cues` emits a cue per played order".
//!
//! ## What phase 1 does, and what it does not
//!
//! **Reconciliation is P104's** (plan 04, "Reconciliation", and Task 15).
//! Until it lands, `dump` takes rule 1's branch every time: the timeline
//! tier is DERIVED from what the file uses — `doc.skeleton.derive` — and
//! the document opens with `skeleton.header_comment`, in as many words,
//! so nobody mistakes an inference for a restoration. A file that DOES
//! carry an essence gets the same treatment for now, and `inspect` is
//! where you can see that it had one.
//!
//! ## The shape of the assembly
//!
//! Three pieces, and each is produced by exactly one thing:
//!
//!   1. the FILE TIER, `bridge_smf.sequenceToForms` or
//!      `bridge_it.moduleToForms`, which is also the only place it 03's
//!      three switches have any meaning;
//!   2. the TIMELINE TIER, `skeleton.derive` over the document those
//!      forms lower back to;
//!   3. the canonical TEXT, `doc.toSjon.print`.
//!
//! The round trip in the middle is deliberate, not incidental: the forms
//! are read back through `doc.fromSource` before anything is printed, so
//! a dump that does not parse as a document fails HERE, on the way out,
//! rather than in the user's editor. It is also what resolves the `(bin
//! :at :len)` regions an `it/` dump keeps — the reader's bytes are handed
//! back through an in-memory resolver, so nothing touches the disk twice.
//!
//! **The printer's tier is bypassed.** `toSjon.print` re-prints an inline
//! dump with the bridge's DEFAULT switches, which would undo
//! `--patterns=bin`, `--preserve-foreign`, `--preserve-history` and
//! `--spans`. So the tier is taken out of the document for the print and
//! the text produced in step 1 is spliced back in at the place the
//! printer left for it — straight after the `(anchor …)` it pairs with,
//! because that pairing is positional (plan 02). An ask for Task 15's
//! `pipeline.zig`: `toSjon.Options` should carry the bridge's switches,
//! and then this splice is one line of options instead.

const std = @import("std");
const tempura = @import("tempura");

const Args = @import("Args.zig");
const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const Writer = std.Io.Writer;

/// The anchor id every dumped document uses. One file per dump, so one
/// name, and it is the one every corpus fixture already spells.
pub const anchor_id = "song";

pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    const bytes = Cli.load(ctx.a, ctx.io, ctx.cmd.path) catch |e|
        return Cli.reportLoadFailure(ctx, e);

    const kind = Cli.sniff(bytes, ctx.cmd.path) orelse {
        try ctx.err.print(
            "tempura: {s}: not a .mid (MThd/RMID) or a .it (IMPM), and the name does not say which\n",
            .{Diags.label(ctx.cmd.path)},
        );
        return Cli.Exit.usage;
    };

    // Diagnostics ABOUT THE FILE have byte offsets into bytes, not into
    // any text, so they are rendered through an index over an empty
    // source: line 1, column 1, and the message carries the detail.
    var file_index = try Diags.LineIndex.build(ctx.a, "");
    defer file_index.deinit(ctx.a);

    var file_diags: tempura.Diag.List = .init(ctx.gpa);
    defer file_diags.deinit();

    const tier = switch (kind) {
        .mid => try smfTier(ctx, bytes, &file_diags),
        .it => try itTier(ctx, bytes, &file_diags),
    };
    defer ctx.gpa.free(tier.text);
    defer ctx.gpa.free(tier.spans);

    const file_name = anchorFile(ctx, kind);
    const assembled = try std.fmt.allocPrintSentinel(
        ctx.a,
        "(timeline :conductor {s})\n\n(anchor :id {0s} :kind {1s} :file \"{2s}\" :size {3d} :sha256 \"{4s}\")\n{5s}",
        .{ anchor_id, @tagName(anchorKind(kind)), file_name, bytes.len, &hexDigest(bytes), tier.text },
        0,
    );

    var schema = try tempura.Schema.load(ctx.gpa);
    defer schema.deinit();

    // The reader's OWN bytes, handed back by name: the anchor's `:size`
    // and `:sha256` were computed from them a moment ago, so they verify
    // by construction and every `(bin :at :len)` resolves without a
    // second read of anything.
    const table: tempura.doc.Memory = .{ .entries = &.{.{ .path = file_name, .bytes = bytes }} };

    var res = try tempura.doc.fromSource(ctx.gpa, &schema, assembled, tempura.doc.memory(&table));
    defer res.deinit();

    var sk = try tempura.doc.skeleton.derive(ctx.gpa, &res.doc, .{ .cues = ctx.cmd.dump.cues });
    defer sk.deinit();
    // Borrowed from `sk`'s arena, which outlives the print below. The
    // document's own arena never sees them, and `Doc.deinit` frees an
    // arena rather than these slices, so the borrow is sound.
    res.doc.lanes = sk.lanes;
    res.doc.cues = sk.cues;

    var derived = try tempura.time.derive.derive(ctx.gpa, &res.doc);
    defer derived.deinit();

    const head = blk: {
        // See the header: the printer would re-render the tier with the
        // bridge's defaults, so it is taken out for the print and the
        // text spliced back into the gap the printer leaves.
        const saved_midi = res.doc.midi;
        const saved_it = res.doc.it;
        res.doc.midi = &.{};
        res.doc.it = &.{};
        defer {
            res.doc.midi = saved_midi;
            res.doc.it = saved_it;
        }
        break :blk try tempura.doc.print(ctx.gpa, &res.doc, &derived.map, .{});
    };
    defer ctx.gpa.free(head);

    var art: Writer.Allocating = .init(ctx.gpa);
    defer art.deinit();
    try art.writer.writeAll(tempura.doc.skeleton.header_comment);
    try art.writer.writeAll("\n");
    try spliceAfterAnchor(&art.writer, head, tier.spans, tier.text);

    if (!try ctx.emit(art.written())) return Cli.Exit.usage;

    // Two reports, two coordinate spaces, and the labels say which is
    // which: the FILE's diagnostics point at bytes, and the assembled
    // document's point at the text the bridge just produced — the second
    // set can only ever mean a tempura defect, so it is never swallowed.
    try Diags.render(ctx.err, ctx.cmd.path, &file_index, file_diags.items(), ctx.style);
    var doc_index = try Diags.LineIndex.build(ctx.a, assembled);
    defer doc_index.deinit(ctx.a);
    try Diags.render(ctx.err, "<dump>", &doc_index, res.diags.items(), ctx.style);

    return @max(Diags.exitCode(file_diags.items()), Diags.exitCode(res.diags.items()));
}

/// The tier's text, and the `--spans` comment block that goes before it
/// (empty when `--spans` was not asked for). Both owned by the caller.
const Tier = struct { text: []u8, spans: []u8 };

fn smfTier(ctx: *const Cli.Ctx, bytes: []const u8, diags: *tempura.Diag.List) Cli.Error!Tier {
    var res = try tempura.smf.read(ctx.gpa, bytes);
    defer res.deinit();
    for (res.diags.items()) |d| try diags.add(d.code, d.severity, d.span, "{s}", .{d.message});

    const text = try tempura.doc.bridge_smf.sequenceToForms(
        ctx.gpa,
        &res.sequence,
        &res.source_map,
        .{ .qualify = true },
    );
    errdefer ctx.gpa.free(text);

    var spans: Writer.Allocating = .init(ctx.gpa);
    errdefer spans.deinit();
    if (ctx.cmd.dump.spans) {
        const w = &spans.writer;
        try w.print("; spans: the reader's byte offsets into \"{s}\"\n", .{
            anchorFile(ctx, .mid),
        });
        for (res.source_map.chunks, 0..) |c, i| {
            try w.print(";   chunk {d}  {s}  at 0x{X:0>8}  body {d}\n", .{
                i, tagText(&c.tag), c.offset, c.len,
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
    }
    return .{ .text = text, .spans = try spans.toOwnedSlice() };
}

fn itTier(ctx: *const Cli.Ctx, bytes: []const u8, diags: *tempura.Diag.List) Cli.Error!Tier {
    var res = try tempura.itf.read.read(ctx.gpa, bytes);
    defer res.deinit();
    for (res.diags.items()) |d| try diags.add(d.code, d.severity, d.span, "{s}", .{d.message});

    const text = try tempura.doc.bridge_it.moduleToForms(ctx.gpa, &res.module, .{
        .qualify = true,
        .patterns_bin = ctx.cmd.dump.patterns_bin,
        .preserve_foreign = ctx.cmd.dump.preserve_foreign,
        .preserve_history = ctx.cmd.dump.preserve_history,
        .source_map = &res.source_map,
        .diags = diags,
    });
    errdefer ctx.gpa.free(text);

    var spans: Writer.Allocating = .init(ctx.gpa);
    errdefer spans.deinit();
    if (ctx.cmd.dump.spans) {
        const w = &spans.writer;
        try w.print("; spans: the reader's byte offsets into \"{s}\"\n", .{anchorFile(ctx, .it)});
        for (res.source_map.entries) |e| {
            try w.print(";   {s: <14} #{d}  at 0x{X:0>8}  len {d}\n", .{
                @tagName(e.kind), e.index, e.region.off, e.region.len,
            });
        }
    }
    return .{ .text = text, .spans = try spans.toOwnedSlice() };
}

/// Write `head` with `spans` and `tier` inserted straight after its
/// `(anchor …)` line.
///
/// The printer emits an anchor on ONE line and leaves the inline dump's
/// place directly after it, because plan 02's anchor/dump pairing is
/// positional — a tier that landed anywhere else would read back as
/// belonging to no anchor. When there is no anchor at all (nothing in
/// this verb produces that, but a renderer must not be the thing that
/// panics), the pieces are appended in the same order, which is still the
/// order they were written in.
pub fn spliceAfterAnchor(w: *Writer, head: []const u8, spans: []const u8, tier: []const u8) Writer.Error!void {
    const at = std.mem.indexOf(u8, head, "(anchor ") orelse {
        try w.writeAll(head);
        try w.writeAll(spans);
        try w.writeAll(tier);
        return;
    };
    const eol = std.mem.indexOfScalarPos(u8, head, at, '\n') orelse head.len;
    const cut = @min(eol + 1, head.len);
    try w.writeAll(head[0..cut]);
    try w.writeAll(spans);
    try w.writeAll(tier);
    try w.writeAll(head[cut..]);
}

fn anchorKind(kind: Args.Kind) tempura.doc.AnchorKind {
    return switch (kind) {
        .mid => .smf,
        .it => .it,
    };
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

fn hexDigest(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0xf];
    }
    return out;
}

fn tagText(tag: *const [4]u8) [4]u8 {
    var out: [4]u8 = undefined;
    for (tag, &out) |b, *o| o.* = if (b >= 0x20 and b < 0x7f) b else '.';
    return out;
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "spliceAfterAnchor: the tier lands on the line after the anchor, never elsewhere" {
    var out: Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try spliceAfterAnchor(
        &out.writer,
        "(timeline :conductor song)\n\n(anchor :id song :kind it :file \"x.it\")\n\n(lane :name a)\n",
        "; spans\n",
        "(it/module)\n",
    );
    try t.expectEqualStrings(
        \\(timeline :conductor song)
        \\
        \\(anchor :id song :kind it :file "x.it")
        \\; spans
        \\(it/module)
        \\
        \\(lane :name a)
        \\
    , out.written());
}

test "spliceAfterAnchor: no anchor appends rather than panicking" {
    var out: Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try spliceAfterAnchor(&out.writer, "(timeline)\n", "", "(it/module)\n");
    try t.expectEqualStrings("(timeline)\n(it/module)\n", out.written());
}

test "hexDigest: the digest the anchor carries is sha256, lowercase, 64 digits" {
    const got = hexDigest("impulse");
    var want: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("impulse", &want, .{});
    var expect: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&expect, "{x}", .{&want});
    try t.expectEqualStrings(&expect, &got);
}

test "dump: an SMF becomes a document with the header comment, an anchor and the tier" {
    const path = try Cli.repoPath(t.allocator, "corpus/skeleton-smf/song.mid");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "dump", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());

    const text = c.out.written();
    try t.expect(std.mem.startsWith(u8, text, "; skeleton: derived, no residue found\n(timeline"));
    try t.expect(std.mem.indexOf(u8, text, ":conductor song") != null);
    try t.expect(std.mem.indexOf(u8, text, "(anchor :id song :kind smf :file \"song.mid\" :size ") != null);
    try t.expect(std.mem.indexOf(u8, text, "(midi/smf ") != null);
    // Rule 1's derived tier: a bound lane per address the file uses.
    try t.expect(std.mem.indexOf(u8, text, ":from song") != null);
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
