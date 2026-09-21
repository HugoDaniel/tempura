//! `tempura inline DOC [--anchor id] [-o DOC]` — an anchor's tiers,
//! dumped into the document.
//!
//! Plan 10's row: "dumps a by-reference anchor's tiers into the document
//! so its content becomes editable (07, "Bound content"); writes the
//! document back with layout preserved".
//!
//! ## The verb is the choosing, the reading and the printing
//!
//! The computation — the anchor's file read and printed as its tier, the
//! root the tier lands after, the `insert_root` plan — is the core's:
//! `edit.inlineAnchor`, one pure function a wasm host can call as well.
//! Its header says why the tier goes in as a plan applied with the layout
//! kept, why it lands straight after its anchor, why its own layout is
//! SJON's printer's, and why an `it/` tier still names its file. What
//! stays here is the invocation: which anchor, its bytes from the store
//! the load already read them through, the messages and the exit code.
//!
//! ## Idempotent
//!
//! An anchor that already carries its dump is not an error, it is nothing
//! to do: the document is emitted unchanged and a line on stderr says so.
//! `tempura inline d.sjon -o d.sjon` twice is the same file twice, which
//! is what makes it safe in a script.

const std = @import("std");
const tempura = @import("tempura");

const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const edit = tempura.edit;

/// The verb: choose the anchor, take its bytes from the load's store,
/// plan the inline in the core, apply it with the layout kept and emit
/// the document. Every value it builds is freed before it returns; the
/// exit code is `Diags.exitCode` over what the reader said about the
/// FILE, `Exit.usage` for a bad `--anchor` or an unwritable `-o`, and
/// `Exit.internal` for a tempura defect.
pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    var loaded = switch (try ctx.loadDoc()) {
        .failed => |code| return code,
        .ok => |l| l,
    };
    defer loaded.deinit();
    const doc = &loaded.result.doc;

    // A document that does not hold together does not get inlined. The
    // usual failure here IS a document diagnostic — `anchor_unavailable`
    // is precisely "the file this verb was about to read is not there" —
    // so reporting it and stopping says more than any sentence this verb
    // could invent.
    if (loaded.result.diags.hasErrors()) {
        try ctx.report(loaded.space(), loaded.result.diags.items());
        return Cli.Exit.errors;
    }

    const anchor = switch (try choose(ctx, doc)) {
        .ok => |x| x,
        .nothing => {
            try ctx.err.writeAll(
                "tempura: every anchor already carries its dump; the document is unchanged\n",
            );
            return if (try ctx.emit(loaded.source)) Cli.Exit.ok else Cli.Exit.usage;
        },
        .failed => |code| return code,
    };

    const bytes = loaded.store.resolver().read(anchor.file) orelse {
        // Unreachable through `fromSource`, which raises
        // `anchor_unavailable` for exactly this and is checked above —
        // but a verb must not be the thing that panics.
        try ctx.err.print("tempura: {s}: the anchor's file could not be read\n", .{anchor.file});
        return Cli.Exit.errors;
    };

    var inlined = try edit.inlineAnchor(ctx.gpa, loaded.source, anchor, bytes);
    defer inlined.deinit();
    const plan = switch (inlined.outcome) {
        .plan => |*p| p,
        else => return refused(ctx, &inlined.outcome),
    };

    var applied = try edit.apply(ctx.gpa, loaded.source, plan);
    defer applied.deinit();
    if (applied.diags.hasErrors()) {
        try ctx.report(loaded.space(), applied.diags.items());
        return Cli.Exit.errors;
    }

    if (!try ctx.emit(applied.text)) return Cli.Exit.usage;
    // The reader's complaints about the FILE, in the file's own
    // coordinate space — the document's spans are somebody else's.
    const file_diags = inlined.file_diags.items();
    try Diags.render(ctx.err, anchor.file, .bytes, file_diags, ctx.style);
    return Diags.exitCode(file_diags);
}

/// Why there is no plan, said on stderr, and the exit code it earns. An
/// anchor that is not a root and a text past SJON's ceiling are about the
/// input (`Exit.errors`); the other three are tempura's own defects
/// (`Exit.internal`), and say so rather than blame a document that did
/// nothing wrong. `.plan` never reaches here: `run` takes it first.
fn refused(ctx: *const Cli.Ctx, outcome: *const edit.inline_anchor.Outcome) Cli.Error!u8 {
    switch (outcome.*) {
        .plan, .not_a_root => {
            try ctx.err.writeAll("tempura: the anchor is not a root of this document\n");
            return Cli.Exit.errors;
        },
        .too_large => |n| {
            try ctx.err.print(
                "tempura: {d} bytes is past SJON's file ceiling; the anchor's dump cannot be " ++
                    "spliced\n",
                .{n},
            );
            return Cli.Exit.errors;
        },
        .unparsed => try ctx.err.writeAll(
            "tempura: the anchor's dump did not parse back (a tempura defect)\n",
        ),
        .unencoded => |name| try ctx.err.print(
            "tempura: the anchor's dump did not encode ({s})\n",
            .{name},
        ),
        .unread => |*p| {
            try Diags.render(ctx.err, "<inline>", .bytes, p.diags.items(), ctx.style);
            try ctx.err.writeAll(
                "tempura: the anchor's dump did not read back as an action list " ++
                    "(a tempura defect)\n",
            );
        },
    }
    return Cli.Exit.internal;
}

const Chosen = union(enum) { ok: *const tempura.doc.Anchor, nothing, failed: u8 };

/// Which anchor to inline: the one `--anchor` names, or the document's
/// one by-reference anchor.
///
/// Two anchors and no `--anchor` is a question and not a guess — a
/// document may be arranged around a `.mid` and a `.it` at once, and
/// inlining the wrong one is a large edit to undo.
fn choose(ctx: *const Cli.Ctx, doc: *const tempura.doc.Doc) Cli.Error!Chosen {
    if (ctx.cmd.inl.anchor) |id| {
        const anchor = doc.anchorById(id) orelse {
            try ctx.err.print("tempura: no (anchor …) is named `{s}`\n", .{id});
            return .{ .failed = Cli.Exit.usage };
        };
        return if (anchor.inline_dump) .nothing else .{ .ok = anchor };
    }

    var found: ?*const tempura.doc.Anchor = null;
    for (doc.anchors) |*a| {
        if (a.inline_dump) continue;
        if (found != null) {
            try ctx.err.writeAll(
                "tempura: this document has more than one anchor by reference; " ++
                    "say which with `--anchor id`\n",
            );
            return .{ .failed = Cli.Exit.usage };
        }
        found = a;
    }
    if (doc.anchors.len == 0) {
        try ctx.err.writeAll("tempura: this document has no (anchor …) to inline\n");
        return .{ .failed = Cli.Exit.usage };
    }
    return if (found) |a| .{ .ok = a } else .nothing;
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A scratch directory holding a copy of one corpus file and a document
/// whose anchor names it BY REFERENCE — the shape `inline` exists for.
const ByRef = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    doc: [:0]u8,

    fn init(rel_file: []const u8, name: []const u8, kind: []const u8) !ByRef {
        const gpa = t.allocator;
        const src = try Cli.repoPath(gpa, rel_file);
        defer gpa.free(src);

        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        const cwd = std.Io.Dir.cwd();
        const bytes = try cwd.readFileAlloc(std.testing.io, src, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });

        // `:size` and `:sha256` are the file's own: a by-reference
        // anchor that declares neither is `anchor_mismatch` the moment a
        // resolver reads it (plan 02, "(anchor …)").
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const text = try std.fmt.allocPrint(gpa,
            \\; a document arranged around a file it does not carry
            \\(timeline :length 1bar)
            \\
            \\(tempo-point :at 0q :qpm 120)
            \\(meter-point :at 0bar :sig [4 4])
            \\
            \\(anchor :id song :kind {s} :file "{s}" :size {d} :sha256 "{x}")
            \\
            \\(lane :name flash :target flash
            \\  ; the downbeat
            \\  (note :at 0q :dur 0.5q :key 36 :vel 110))
            \\
        , .{ kind, name, bytes.len, &digest });
        defer gpa.free(text);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "doc.sjon", .data = text });

        const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer gpa.free(dir);
        return .{
            .tmp = tmp,
            .dir = dir,
            .doc = try std.fmt.allocPrintSentinel(gpa, "{s}/doc.sjon", .{dir}, 0),
        };
    }

    fn deinit(self: *ByRef) void {
        t.allocator.free(self.dir);
        t.allocator.free(self.doc);
        self.tmp.cleanup();
    }
};

test "inline: an SMF anchor's tier lands after its anchor, with the layout kept" {
    var s = try ByRef.init("corpus/skeleton-smf/song.mid", "song.mid", "smf");
    defer s.deinit();

    var c = try Cli.invoke(&.{ "tempura", "inline", s.doc });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());

    const text = c.out.written();
    // The tier is there…
    const anchor_at = std.mem.indexOf(u8, text, "(anchor :id song").?;
    const tier_at = std.mem.indexOf(u8, text, "(midi/smf ").?;
    const lane_at = std.mem.indexOf(u8, text, "(lane :name flash").?;
    // …between the anchor it pairs with and everything that followed it.
    try t.expect(anchor_at < tier_at);
    try t.expect(tier_at < lane_at);
    // …and every authored byte survived, comment included.
    try t.expect(
        std.mem.indexOf(u8, text, "; a document arranged around a file it does not carry") != null,
    );
    try t.expect(
        std.mem.indexOf(
            u8,
            text,
            "  ; the downbeat\n  (note :at 0q :dur 0.5q :key 36 :vel 110))",
        ) != null,
    );
}

test "inline: the document it produces is a document, and its content is editable" {
    const a = t.allocator;
    var s = try ByRef.init("corpus/it-minimal/song.it", "song.it", "it");
    defer s.deinit();

    const dest = try std.fmt.allocPrintSentinel(a, "{s}/inlined.sjon", .{s.dir}, 0);
    defer a.free(dest);

    var c = try Cli.invoke(&.{ "tempura", "inline", s.doc, "-o", dest });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.out.written());

    // It validates — the anchor's `(bin …)` regions resolve against the
    // very file the anchor names, which is the round trip.
    var v = try Cli.invoke(&.{ "tempura", "validate", dest });
    defer v.deinit();
    try t.expectEqual(Cli.Exit.ok, v.code);

    const written = try s.tmp.dir.readFileAlloc(
        std.testing.io,
        "inlined.sjon",
        a,
        .limited(1 << 20),
    );
    defer a.free(written);
    try t.expect(std.mem.indexOf(u8, written, "(it/module") != null);
    try t.expect(std.mem.indexOf(u8, written, "(it/pattern") != null);
    try t.expect(std.mem.indexOf(u8, written, "(ev ") != null);
}

test "inline: a second run changes nothing and says so" {
    const a = t.allocator;
    var s = try ByRef.init("corpus/skeleton-smf/song.mid", "song.mid", "smf");
    defer s.deinit();

    const dest = try std.fmt.allocPrintSentinel(a, "{s}/once.sjon", .{s.dir}, 0);
    defer a.free(dest);
    var once = try Cli.invoke(&.{ "tempura", "inline", s.doc, "-o", dest });
    defer once.deinit();
    try t.expectEqual(Cli.Exit.ok, once.code);

    var twice = try Cli.invoke(&.{ "tempura", "inline", dest });
    defer twice.deinit();
    try t.expectEqual(Cli.Exit.ok, twice.code);
    try t.expect(std.mem.indexOf(u8, twice.err.written(), "already carries its dump") != null);

    const first = try s.tmp.dir.readFileAlloc(std.testing.io, "once.sjon", a, .limited(1 << 20));
    defer a.free(first);
    try t.expectEqualStrings(first, twice.out.written());
}

test "inline: --anchor names one, and an unknown id is a usage error" {
    var s = try ByRef.init("corpus/skeleton-smf/song.mid", "song.mid", "smf");
    defer s.deinit();

    var ok = try Cli.invoke(&.{ "tempura", "inline", s.doc, "--anchor", "song" });
    defer ok.deinit();
    try t.expectEqual(Cli.Exit.ok, ok.code);
    try t.expect(std.mem.indexOf(u8, ok.out.written(), "(midi/smf ") != null);

    var bad = try Cli.invoke(&.{ "tempura", "inline", s.doc, "--anchor", "drums" });
    defer bad.deinit();
    try t.expectEqual(Cli.Exit.usage, bad.code);
    try t.expectEqualStrings("", bad.out.written());
    try t.expect(std.mem.indexOf(u8, bad.err.written(), "drums") != null);
}

test "inline: a document whose anchor cannot be read is refused, not half done" {
    const path = try Cli.repoPath(t.allocator, "src/cli/testdata/missing-anchor.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "inline", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expectEqualStrings("", c.out.written());
}

test "inline: a document with no anchor at all is a usage error" {
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-three-conductors-native/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "inline", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.usage, c.code);
    try t.expect(std.mem.indexOf(u8, c.err.written(), "no (anchor") != null);
}
