//! `tempura build DOC [-o FILE]` — a document as a `.mid` or a `.it`.
//!
//! Plan 10's row: "document → file, kind from `-o`'s extension or
//! `--kind`; renders native lanes and attaches the residue; `--format 0`,
//! `--ppq N [--round]`, `--no-running-status`; `--compress` is refused
//! (no codec; pass-through only), `--loose`, `--in-place`; `--no-residue`
//! for a file that carries nothing".
//!
//! ## What phase 1 writes
//!
//! The document's own INLINE TIER, through the canonical writer, and
//! nothing else. Two halves of that row are later work and are refused
//! out loud rather than half-done:
//!
//!   - **Rendering native lanes** into a file is P106's (plan 08), so a
//!     document with no inline tier — a native timeline, or one whose
//!     anchor is by reference — is refused with the same sentence the
//!     corpus golden already uses, and exit 2.
//!   - **The residue** is P104's (plan 04, E3). Until it lands every
//!     build is a `--no-residue` build, and a build that did NOT ask for
//!     that is told so on stderr: the user asked for a file carrying the
//!     timeline and is getting one that does not.
//!
//! What IS here is the whole writer surface: plan 05's `--format 0`,
//! `--ppq N [--round]` and `--no-running-status`, plan 06's `--loose` and
//! `--in-place`, and `--compress`'s refusal (`Args.zig` makes that one,
//! because it can be answered without reading anything).
//!
//! ## `--in-place`
//!
//! Plan 06: "The toolchain never mutates the anchor: building onto the
//! anchor path is `--in-place` only (read everything, write a temp,
//! rename)." Both halves are here — `-o` naming the anchor's own file is
//! refused, and `--in-place` goes through a temporary and a rename, so a
//! failure leaves the anchor as it was rather than half written.

const std = @import("std");
const tempura = @import("tempura");

const Args = @import("Args.zig");
const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const Io = std.Io;

/// Why a native timeline cannot be built yet — the corpus golden's own
/// sentence, so the CLI and `expected.sjon` say one thing.
pub const no_tier_smf = "this document carries no (midi/smf …) tier; rendering a native timeline to bytes is P110's work (plan 08)";
pub const no_tier_it = "this document carries no (it/module …) tier; rendering a native timeline to bytes is P110's work (plan 08)";

pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    const source = Cli.load(ctx.a, ctx.io, ctx.cmd.path) catch |e|
        return Cli.reportLoadFailure(ctx, e);

    var index = try Diags.LineIndex.build(ctx.a, source);
    defer index.deinit(ctx.a);

    var schema = try tempura.Schema.load(ctx.gpa);
    defer schema.deinit();

    var store = tempura.doc.fs(ctx.gpa, ctx.io, ctx.inputDir());
    defer store.deinit();

    var res = try tempura.doc.fromSource(ctx.gpa, &schema, source, store.resolver());
    defer res.deinit();

    // A defective document does not get to produce bytes. Every other
    // verb here is best-effort because its product is a VIEW; this one's
    // product is a file somebody will play, and a file built from a
    // document that does not hold together is worse than no file.
    if (res.diags.hasErrors()) {
        try ctx.report(&index, res.diags.items());
        return Cli.Exit.errors;
    }

    const kind = resolveKind(ctx, &res.doc) orelse {
        try ctx.err.writeAll(
            "tempura: build needs a format: `--kind mid|it`, an `-o` whose extension says so, " ++
                "or a document with exactly one anchor\n",
        );
        return Cli.Exit.usage;
    };

    // Plan 08, "Cross-kind builds": v1 builds a document into its own
    // anchor's kind, and refuses the other one — the mechanism exists,
    // the residue story for it does not.
    for (res.doc.anchors) |anchor| {
        if (anchor.kind == anchorKind(kind)) break;
    } else if (res.doc.anchors.len > 0) {
        var diags: tempura.Diag.List = .init(ctx.gpa);
        defer diags.deinit();
        try diags.add(
            .build_cross_kind,
            .err,
            res.doc.anchors[0].span,
            "this document's anchor is kind `{s}`; building it as `{s}` is refused (plan 08, \"Cross-kind builds\")",
            .{ @tagName(res.doc.anchors[0].kind), @tagName(kind) },
        );
        try ctx.report(&index, diags.items());
        return Cli.Exit.errors;
    }

    // The two writers return two DIFFERENT `Written` types — one owns a
    // `Sequence`'s arena, the other an `.it`'s — so each branch runs to
    // the end on its own and they meet again at `finish`.
    switch (kind) {
        .mid => {
            if (res.doc.midi.len == 0) return try refuseNative(ctx, no_tier_smf);
            var written = try tempura.smf.write(ctx.gpa, &res.doc.midi[0].sequence, .{
                .running_status = ctx.cmd.build.running_status,
                .format0 = ctx.cmd.build.format0,
                .ppq = ctx.cmd.build.ppq,
                .round = ctx.cmd.build.round,
            });
            defer written.deinit();
            return try finish(ctx, &res.doc, written.bytes, &written.diags);
        },
        .it => {
            if (res.doc.it.len == 0) return try refuseNative(ctx, no_tier_it);
            const tier = &res.doc.it[0];
            // The opaque regions are copied out of the ANCHOR's bytes,
            // which `fromSource` has already verified against `:size`
            // and `:sha256`; the store cached them on that read, so this
            // is a lookup and not a second trip to the disk.
            const anchor_bytes = anchorBytes(&store, &res.doc, tier.anchor);
            var written = try tempura.itf.write.write(ctx.gpa, &tier.module, anchor_bytes, .{
                .loose = ctx.cmd.build.loose,
                // Not a build flag: the block is in the document only
                // because `dump --preserve-history` put it there, and
                // dropping it at build would make that flag a lie.
                .preserve_history = tier.module.edit_history != null,
            });
            defer written.deinit();
            return try finish(ctx, &res.doc, written.bytes, &written.diags);
        },
    }
}

/// What both writers' output does next: refuse on an error, place the
/// bytes, report the warnings, and say whether a residue rode along.
///
/// A WRITER's span is an offset into the bytes it is producing
/// (`smf/write.zig`'s `Emit.diag` takes the emission's own cursor), not
/// into the document — so these are rendered through an index over an
/// empty source and read as `doc.sjon:1:1`. Pointing them at a line of
/// the document would name a place that has nothing to do with them, and
/// every one of these messages already carries the tick or the record it
/// is about.
fn finish(
    ctx: *const Cli.Ctx,
    doc: *const tempura.doc.Doc,
    bytes: []const u8,
    diags: *const tempura.Diag.List,
) Cli.Error!u8 {
    var index = try Diags.LineIndex.build(ctx.a, "");
    defer index.deinit(ctx.a);

    if (diags.hasErrors()) {
        try ctx.report(&index, diags.items());
        return Cli.Exit.errors;
    }

    const code = try place(ctx, doc, bytes);
    // Warnings survive a successful write and are worth saying: a
    // promoted format or a rounded rescale is a file that is not quite
    // the document.
    try ctx.report(&index, diags.items());
    if (code != Cli.Exit.ok) return code;

    if (!ctx.cmd.build.no_residue) try ctx.err.writeAll(
        "tempura: this file carries no residue — attaching one is P104's work (plan 04), " ++
            "which lands at E3; pass --no-residue to ask for exactly what you got\n",
    );
    return Cli.Exit.ok;
}

fn refuseNative(ctx: *const Cli.Ctx, why: []const u8) Cli.Error!u8 {
    try ctx.err.print("tempura: {s}: {s}\n", .{ Diags.label(ctx.cmd.path), why });
    return Cli.Exit.usage;
}

/// Where the bytes go: `--in-place` onto the anchor's own file through a
/// temporary, `-o`'s path, or stdout.
fn place(ctx: *const Cli.Ctx, doc: *const tempura.doc.Doc, bytes: []const u8) Cli.Error!u8 {
    const anchor_path: ?[]const u8 = if (doc.anchors.len > 0)
        try std.fs.path.join(ctx.a, &.{ ctx.inputDir(), doc.anchors[0].file })
    else
        null;

    if (ctx.cmd.build.in_place) {
        // The contradiction is checked FIRST: an invocation that named two
        // destinations should be told that, not told something about its
        // anchors.
        if (ctx.cmd.out != null) {
            try ctx.err.writeAll("tempura: --in-place and -o name two different destinations; pick one\n");
            return Cli.Exit.usage;
        }
        const dest = anchor_path orelse {
            try ctx.err.writeAll("tempura: --in-place needs a document with an anchor to write back onto\n");
            return Cli.Exit.usage;
        };
        return if (try writeThroughTemp(ctx, dest, bytes)) Cli.Exit.ok else Cli.Exit.usage;
    }

    // Plan 06: the toolchain never mutates the anchor. `-o` naming it is
    // refused rather than silently doing what `--in-place` exists for.
    if (ctx.cmd.out) |out| {
        if (anchor_path) |anchor| {
            if (samePath(ctx.a, out, anchor)) {
                try ctx.err.print(
                    "tempura: {s} is this document's anchor; building onto it is --in-place only (plan 06)\n",
                    .{out},
                );
                return Cli.Exit.usage;
            }
        }
    }
    return if (try ctx.emit(bytes)) Cli.Exit.ok else Cli.Exit.usage;
}

/// Read everything, write a temp, rename (plan 06). The rename is what
/// makes the replacement atomic on every platform tempura targets, so an
/// interrupted build leaves the anchor whole.
fn writeThroughTemp(ctx: *const Cli.Ctx, dest: []const u8, bytes: []const u8) Cli.Error!bool {
    const tmp = try std.fmt.allocPrint(ctx.a, "{s}.tempura-tmp", .{dest});
    if (!try ctx.writeFile(tmp, bytes)) return false;
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), dest, ctx.io) catch |e| {
        Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
        try ctx.err.print("tempura: {s}: could not replace ({s})\n", .{ dest, @errorName(e) });
        return false;
    };
    return true;
}

/// Whether two spellings name one file. Textual, after normalising `.`
/// and `..` — enough to catch `-o song.it` beside `:file "song.it"`,
/// which is the mistake plan 06's rule is about. A symlink or a hard
/// link pointing at the anchor under another name is not caught, and
/// nothing short of opening both files would catch it.
fn samePath(a: std.mem.Allocator, x: []const u8, y: []const u8) bool {
    const rx = std.fs.path.resolve(a, &.{x}) catch return false;
    const ry = std.fs.path.resolve(a, &.{y}) catch return false;
    return std.mem.eql(u8, rx, ry);
}

fn anchorBytes(store: *const tempura.doc.Fs, doc: *const tempura.doc.Doc, id: tempura.doc.AnchorId) ?[]const u8 {
    const anchor = doc.anchorById(id) orelse return null;
    return store.resolver().read(anchor.file);
}

fn anchorKind(kind: Args.Kind) tempura.doc.AnchorKind {
    return switch (kind) {
        .mid => .smf,
        .it => .it,
    };
}

/// `--kind`, then `-o`'s extension, then the document's own anchor.
///
/// The third is not in plan 10's row and is the obvious completion of it:
/// `tempura build doc.sjon > song.it` names no kind anywhere, and a
/// document with exactly one anchor has already said which it is. Two
/// anchors, or none, and the CLI asks rather than guesses.
fn resolveKind(ctx: *const Cli.Ctx, doc: *const tempura.doc.Doc) ?Args.Kind {
    if (ctx.cmd.build.kind) |k| return k;
    if (ctx.cmd.out) |out| {
        if (Args.kindFromPath(out)) |k| return k;
    }
    if (doc.anchors.len == 1) return switch (doc.anchors[0].kind) {
        .smf => .mid,
        .it => .it,
    };
    return null;
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A scratch directory holding a copy of one corpus file plus the
/// document `dump` makes of it — the only honest fixture for `build`,
/// because a build reads the anchor's bytes and checks them.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    doc: [:0]u8,
    file: [:0]u8,

    fn init(rel_file: []const u8, name: []const u8) !Scratch {
        const a = t.allocator;
        const src = try Cli.repoPath(a, rel_file);
        defer a.free(src);

        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        const bytes = try Io.Dir.cwd().readFileAlloc(std.testing.io, src, a, .limited(1 << 20));
        defer a.free(bytes);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });

        const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer a.free(dir);
        const doc = try std.fmt.allocPrintSentinel(a, "{s}/doc.sjon", .{dir}, 0);
        errdefer a.free(doc);
        const file = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
        errdefer a.free(file);

        var d = try Cli.invoke(&.{ "tempura", "dump", file, "-o", doc });
        defer d.deinit();
        try t.expectEqual(Cli.Exit.ok, d.code);

        return .{ .tmp = tmp, .dir = dir, .doc = doc, .file = file };
    }

    fn read(self: *Scratch, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, name, t.allocator, .limited(1 << 20));
    }

    fn deinit(self: *Scratch) void {
        t.allocator.free(self.dir);
        t.allocator.free(self.doc);
        t.allocator.free(self.file);
        self.tmp.cleanup();
    }
};

test "build: a dumped .it rebuilds to bytes, and the kind comes from -o" {
    var s = try Scratch.init("corpus/it-minimal/song.it", "song.it");
    defer s.deinit();
    const a = t.allocator;

    const out = try std.fmt.allocPrintSentinel(a, "{s}/out.it", .{s.dir}, 0);
    defer a.free(out);
    var c = try Cli.invoke(&.{ "tempura", "build", s.doc, "-o", out });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.out.written());
    // Phase 1 attaches no residue, and says so when it was not asked to.
    try t.expect(std.mem.indexOf(u8, c.err.written(), "carries no residue") != null);

    const built = try s.read("out.it");
    defer a.free(built);
    try t.expect(std.mem.startsWith(u8, built, "IMPM"));
}

test "build: --no-residue is the behaviour phase 1 already has, and silences the note" {
    var s = try Scratch.init("corpus/it-minimal/song.it", "song.it");
    defer s.deinit();
    const a = t.allocator;

    const out = try std.fmt.allocPrintSentinel(a, "{s}/out.it", .{s.dir}, 0);
    defer a.free(out);
    var with = try Cli.invoke(&.{ "tempura", "build", s.doc, "-o", out, "--no-residue" });
    defer with.deinit();
    try t.expectEqual(Cli.Exit.ok, with.code);
    try t.expectEqualStrings("", with.err.written());
}

test "build: the bytes go to stdout when no -o names a file" {
    var s = try Scratch.init("corpus/smf-format0/song.mid", "song.mid");
    defer s.deinit();
    var c = try Cli.invoke(&.{ "tempura", "build", s.doc, "--kind", "mid", "--no-residue" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expect(std.mem.startsWith(u8, c.out.written(), "MThd"));
}

test "build --ppq: an inexact rescale is refused, and --round accepts it" {
    // `smf-vlq-edges` is the fixture with ticks that are not multiples of
    // its own division (127 and 255 on a 96-pulse grid), which is the
    // only way a rescale has anything to round.
    var s = try Scratch.init("corpus/smf-vlq-edges/song.mid", "song.mid");
    defer s.deinit();

    // 96 → 7 pulses per quarter cannot land tick 127 exactly.
    var strict = try Cli.invoke(&.{ "tempura", "build", s.doc, "--kind", "mid", "--ppq", "7", "--no-residue" });
    defer strict.deinit();
    try t.expectEqual(Cli.Exit.errors, strict.code);
    try t.expectEqualStrings("", strict.out.written());
    try t.expect(std.mem.indexOf(u8, strict.err.written(), "ppq_rescale_inexact") != null);

    var rounded = try Cli.invoke(&.{ "tempura", "build", s.doc, "--kind", "mid", "--ppq", "7", "--round", "--no-residue" });
    defer rounded.deinit();
    try t.expectEqual(Cli.Exit.ok, rounded.code);
    try t.expect(std.mem.startsWith(u8, rounded.out.written(), "MThd"));
}

test "build --format 0: the tracks merge into one" {
    var s = try Scratch.init("corpus/skeleton-smf/song.mid", "song.mid");
    defer s.deinit();
    const a = t.allocator;

    var one = try Cli.invoke(&.{ "tempura", "build", s.doc, "--kind", "mid", "--format", "0", "--no-residue" });
    defer one.deinit();
    try t.expectEqual(Cli.Exit.ok, one.code);
    // The header's `format` word is bytes 8..10 and `ntrks` 10..12.
    const bytes = one.out.written();
    try t.expect(bytes.len > 12);
    try t.expectEqual(@as(u8, 0), bytes[9]);
    try t.expectEqual(@as(u8, 1), bytes[11]);
    _ = a;
}

test "build: a native document is refused, with the sentence the corpus golden uses" {
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-three-conductors-native/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "build", path, "--kind", "mid" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), no_tier_smf) != null);
}

test "build: a cross-kind build is refused with build_cross_kind" {
    var s = try Scratch.init("corpus/it-minimal/song.it", "song.it");
    defer s.deinit();
    var c = try Cli.invoke(&.{ "tempura", "build", s.doc, "--kind", "mid" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "build_cross_kind") != null);
}

test "build: -o naming the anchor is refused; --in-place replaces it through a temp" {
    var s = try Scratch.init("corpus/it-minimal/song.it", "song.it");
    defer s.deinit();
    const a = t.allocator;

    var refused = try Cli.invoke(&.{ "tempura", "build", s.doc, "-o", s.file, "--no-residue" });
    defer refused.deinit();
    try t.expectEqual(Cli.Exit.usage, refused.code);
    try t.expect(std.mem.indexOf(u8, refused.err.written(), "--in-place") != null);

    const before = try s.read("song.it");
    defer a.free(before);

    var ok = try Cli.invoke(&.{ "tempura", "build", s.doc, "--in-place", "--no-residue" });
    defer ok.deinit();
    try t.expectEqual(Cli.Exit.ok, ok.code);
    try t.expectEqualStrings("", ok.out.written());

    const after = try s.read("song.it");
    defer a.free(after);
    try t.expect(std.mem.startsWith(u8, after, "IMPM"));
    // The temporary is gone, whatever happened.
    try t.expectError(error.FileNotFound, s.tmp.dir.access(std.testing.io, "song.it.tempura-tmp", .{}));
}

test "build: --in-place and -o together name two destinations and are refused" {
    var s = try Scratch.init("corpus/it-minimal/song.it", "song.it");
    defer s.deinit();
    const a = t.allocator;
    const out = try std.fmt.allocPrintSentinel(a, "{s}/out.it", .{s.dir}, 0);
    defer a.free(out);

    var c = try Cli.invoke(&.{ "tempura", "build", s.doc, "--in-place", "-o", out, "--no-residue" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.usage, c.code);
}

test "build: a defective document writes no bytes at all" {
    const path = try Cli.repoPath(t.allocator, "src/cli/testdata/bad-doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "build", path, "--kind", "mid" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "lane_duplicate") != null);
}

test "build: with no --kind, no -o and no anchor there is nothing to guess from" {
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-three-conductors-native/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "build", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.usage, c.code);
    try t.expect(std.mem.indexOf(u8, c.err.written(), "--kind") != null);
}
