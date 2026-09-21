//! `tempura inline DOC [--anchor id] [-o DOC]` — an anchor's tiers,
//! dumped into the document.
//!
//! Plan 10's row: "dumps a by-reference anchor's tiers into the document
//! so its content becomes editable (07, "Bound content"); writes the
//! document back with layout preserved".
//!
//! ## Why it goes through the edit engine
//!
//! Layout. A document is a person's text — comments, blank lines, the
//! spelling of every number — and re-printing it to add one root would
//! rewrite all of it. So the tier is added the way every other change to
//! a document is made: as SJON edit actions, applied with `layout =
//! .preserve`, which splices each action's own span and leaves every
//! other byte exactly as the author wrote it (plan 07, "The contract";
//! `SJON/docs/LANGUAGE.md` §11.5). One `insert_root` per root of the
//! dump.
//!
//! ## Where the tier lands
//!
//! Directly after the `(anchor …)` it pairs with, because that pairing is
//! POSITIONAL (plan 02): an `(it/module …)` belongs to the anchor above
//! it, and a tier that landed anywhere else would read back as belonging
//! to a different anchor or to none. The anchor's own root index is found
//! by matching the span the document layer recorded for it against the
//! roots of a fresh parse — the same span-to-address join the edit engine
//! makes, minus the paths, because a root needs none.
//!
//! ## The tier's own layout is SJON's, not the bridge's
//!
//! The forms are the bridge's and the LAYOUT is SJON's printer's: an
//! action carries a JSON value, and SJON's canonical encoding of a form
//! puts its keywords before its positional children, so a tier that the
//! `dump` verb would write as `(it/pattern 0 :rows 64 …)` lands here as
//! `(it/pattern :rows 64 0 …)`. The same form, the same value, the same
//! document — and the author's own bytes, which are the ones this verb
//! promises to leave alone, are untouched either way.
//!
//! ## What it does NOT do
//!
//! Inlining does not free a document from its file (plan 10's own risk
//! note): an inline `it/` dump keeps its `:raw` and `data` regions as
//! `(bin :at :len)` references into the anchor's bytes, because bytes are
//! sacred (plan 06) and a base64 copy of a 12 MB sample bank is not a
//! document. What becomes editable is the MUSIC — the patterns, the
//! orders, the events — which is what plan 07's bound operations act on.
//!
//! ## Idempotent
//!
//! An anchor that already carries its dump is not an error, it is nothing
//! to do: the document is emitted unchanged and a line on stderr says so.
//! `tempura inline d.sjon -o d.sjon` twice is the same file twice, which
//! is what makes it safe in a script.

const std = @import("std");
const sjon = @import("sjon");
const tempura = @import("tempura");

const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const Allocator = std.mem.Allocator;
const edit = tempura.edit;

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

    var file_diags: tempura.Diag.List = .init(ctx.gpa);
    defer file_diags.deinit();
    const tier = try tierText(ctx, anchor.kind, bytes, &file_diags);
    defer ctx.gpa.free(tier);

    const at = try rootIndexOf(ctx, loaded.source, anchor.span) orelse {
        try ctx.err.writeAll("tempura: the anchor is not a root of this document\n");
        return Cli.Exit.errors;
    };

    var plan = switch (try planInsert(ctx, tier, at + 1)) {
        .ok => |p| p,
        .failed => |code| return code,
    };
    defer plan.deinit();

    var applied = try edit.apply(ctx.gpa, loaded.source, &plan);
    defer applied.deinit();
    if (applied.diags.hasErrors()) {
        try ctx.report(loaded.space(), applied.diags.items());
        return Cli.Exit.errors;
    }

    if (!try ctx.emit(applied.text)) return Cli.Exit.usage;
    // The reader's complaints about the FILE, in the file's own
    // coordinate space — the document's spans are somebody else's.
    try Diags.render(ctx.err, anchor.file, .bytes, file_diags.items(), ctx.style);
    return Diags.exitCode(file_diags.items());
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

/// The anchor's file, as the tier forms it dumps to. The `dump` verb's
/// own bridges, with the bridges' default switches: `inline` is about
/// making content EDITABLE, and it 03's three compaction switches all
/// take content away.
fn tierText(
    ctx: *const Cli.Ctx,
    kind: tempura.doc.AnchorKind,
    bytes: []const u8,
    diags: *tempura.Diag.List,
) Cli.Error![]u8 {
    switch (kind) {
        .smf => {
            var res = try tempura.smf.read(ctx.gpa, bytes);
            defer res.deinit();
            for (res.diags.items()) |d| try diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
            return tempura.doc.bridge_smf.sequenceToForms(ctx.gpa, &res.sequence, null, .{ .qualify = true });
        },
        .it => {
            var res = try tempura.itf.read.read(ctx.gpa, bytes);
            defer res.deinit();
            for (res.diags.items()) |d| try diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
            return tempura.doc.bridge_it.moduleToForms(ctx.gpa, &res.module, .{
                .qualify = true,
                .source_map = &res.source_map,
                .diags = diags,
            });
        },
    }
}

/// Which root of `source` has exactly this span.
///
/// The document layer recorded the anchor's span when it walked the
/// tree; a fresh parse of the same bytes gives the same spans, so the
/// match is a lookup and not a search for something like it.
fn rootIndexOf(ctx: *const Cli.Ctx, source: [:0]const u8, span: tempura.Diag.Span) Cli.Error!?u32 {
    var tree = try sjon.parse(ctx.gpa, source);
    defer tree.deinit();
    for (tree.root, 0..) |node, i| {
        const s = tree.spanOf(node);
        if (s.start == span.start and s.end == span.end) return @intCast(i);
    }
    return null;
}

const Planned = union(enum) { ok: edit.Plan, failed: u8 };

/// The tier's roots as `insert_root` actions, starting at root `at`.
///
/// The bridge produces SJON TEXT and an action carries a JSON VALUE, so
/// the text is parsed and encoded through SJON's own JSON bridge (§9) —
/// the encoding SJON decodes and prints on the way back in, which is why
/// the tier lands as the forms it was rather than as a string.
///
/// The plan is built by hand rather than by an operation's planner
/// because `inline` is not one of plan 07's operations: it changes what
/// the document HOLDS rather than what it says about the music, and no
/// selection resolves against a file that is not in the document yet.
fn planInsert(ctx: *const Cli.Ctx, tier: []const u8, at: u32) Cli.Error!Planned {
    const text = try ctx.a.dupeZ(u8, tier);
    var tree = try sjon.parse(ctx.gpa, text);
    defer tree.deinit();
    if (tree.hasErrors()) {
        try ctx.err.writeAll("tempura: the anchor's dump did not parse back (a tempura defect)\n");
        return .{ .failed = Cli.Exit.internal };
    }

    var encoded = sjon.toJsonRoots(ctx.gpa, tree, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("tempura: the anchor's dump did not encode ({s})\n", .{@errorName(e)});
            return .{ .failed = Cli.Exit.internal };
        },
    };
    defer encoded.deinit();

    const roots = switch (encoded.value) {
        .object => |o| switch (o.get("$roots") orelse .null) {
            .array => |xs| xs.items,
            else => &.{},
        },
        else => &.{},
    };

    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    errdefer arena.deinit();
    var diags: tempura.Diag.List = .init(ctx.gpa);
    errdefer diags.deinit();
    const a = arena.allocator();

    const actions = try a.alloc(edit.Action, roots.len);
    for (roots, actions, 0..) |value, *action, i| {
        const slot: u32 = at + @as(u32, @intCast(i));
        const json = std.json.Stringify.valueAlloc(a, value, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        action.* = .{
            .json = try std.fmt.allocPrint(
                a,
                "{{\"op\":\"insert_root\",\"index\":{d},\"value\":{s}}}",
                .{ slot, json },
            ),
            .kind = .insert_root,
            // The two forest operations carry the root list's own empty
            // address and say everything in `slot` (§11.3).
            .site = .{ .root = 0, .path = &.{} },
            .slot = slot,
        };
    }

    return .{ .ok = .{
        .actions = actions,
        .diags = diags,
        .summary = .{ .inserted = @intCast(actions.len) },
        .arena = arena,
    } };
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
        const a = t.allocator;
        const src = try Cli.repoPath(a, rel_file);
        defer a.free(src);

        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, src, a, .limited(1 << 20));
        defer a.free(bytes);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });

        // `:size` and `:sha256` are the file's own: a by-reference
        // anchor that declares neither is `anchor_mismatch` the moment a
        // resolver reads it (plan 02, "(anchor …)").
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const text = try std.fmt.allocPrint(a,
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
        defer a.free(text);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "doc.sjon", .data = text });

        const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer a.free(dir);
        return .{
            .tmp = tmp,
            .dir = dir,
            .doc = try std.fmt.allocPrintSentinel(a, "{s}/doc.sjon", .{dir}, 0),
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
    try t.expect(std.mem.indexOf(u8, text, "; a document arranged around a file it does not carry") != null);
    try t.expect(std.mem.indexOf(u8, text, "  ; the downbeat\n  (note :at 0q :dur 0.5q :key 36 :vel 110))") != null);
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

    const written = try s.tmp.dir.readFileAlloc(std.testing.io, "inlined.sjon", a, .limited(1 << 20));
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
