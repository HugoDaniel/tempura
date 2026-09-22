//! `tempura export-score DOC [-o s.score.sjon]` — the pacer skeleton.
//!
//! Plan 10's row: "the pacer skeleton (08): `--velocity`, `--ease
//! linear`, `--eps`, `--no-hints`, `--tempo-eps`, `--max-keys-per-track`,
//! `--section-markers`".
//!
//! Every flag is one field of `export/score.zig`'s `Options`, so this
//! verb is the exporter plus the channel policy — with two decisions of
//! its own.
//!
//! ## The source name
//!
//! The header comment plan 08 prints opens with "exported from X", and X
//! is what the user typed, basename and all: a score is read beside the
//! document it came from, and an absolute path in a comment is noise a
//! person then has to strip. Stdin has no name and says so.
//!
//! ## A FILE is a document too
//!
//! Plan 10's row spells `export-score doc.sjon`, and a `.mid` or a `.it`
//! is accepted as well — it is dumped first, through the same
//! `doc/pipeline.zig` `dump` the `dump` verb runs, and the score is
//! exported from the document that comes back. Two reasons, and the
//! second is the load-bearing one:
//!
//!   1. `tempura dump song.it -o d.sjon && tempura export-score d.sjon`
//!      is two commands for one question, and the intermediate file is
//!      not wanted by anyone;
//!   2. the EASING HINTS of a stale curve lane exist only on a dump.
//!      Plan 04's rule 2 says a lane whose hash differs keeps "its
//!      easing per segment as a hint that is verified against the steps
//!      and dropped where it disagrees", and `reconcile` computes
//!      exactly that — `LaneVerdict.hints`. A document read from a
//!      `.sjon` carries no verdicts, so on that path there are none to
//!      pass; on this one there are, and they are passed.
//!
//! ## A conducted document whose file is not here is REFUSED
//!
//! Plan 03 gives a conducted document's time to its anchor. When neither
//! an inline tier nor the anchor's own verified bytes are in hand
//! (`doc.conductedPlaceholder`), every position the document answers is
//! plan 03's placeholder — 120 quarter notes per minute in `[4 4]` — and
//! the one line a score exists to carry would say `:bpm 120` under a
//! header that names the conductor. That is a wrong score, not a score
//! with a warning, and nothing downstream can tell it from a piece that
//! really is at 120. So this verb writes NOTHING and exits 1, with the
//! `anchor_unavailable` the load and the derivation raised as the reason.
//! `tempura inline` is the verb that fixes it.
//!
//! **The other hint source is not wired, and cannot be here.** Plan 08
//! also names midivia's `ease-hint` events, which the SMF reader types
//! as `.ease_hint` and keeps as BYTES: decoding that payload into pacer's
//! easing vocabulary has no decoder in this tree (`doc/bridge_smf.zig`
//! says so where it spells the head), so an inline `midi/` tier's hints
//! are unavailable to every caller, not only to this one.

const std = @import("std");
const tempura = @import("tempura");

const Args = @import("Args.zig");
const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const exporter = tempura.exporter;
const pipeline = tempura.doc.pipeline;

/// The verb: read the input once, dump it first when its bytes announce
/// a `.mid` or a `.it`, and emit the pacer score of the document — or
/// nothing, exiting `Exit.errors`, for a conducted document whose file is
/// not here. Otherwise exits with the worse of the document's and the
/// exporter's verdicts. Every value it builds is freed before it returns.
pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    // Read ONCE, then decide, and the bytes go to whichever half wants
    // them. `Ctx.loadDoc` would read the path again, and for `-` on a
    // pipe the second read of stdin is EOF — an empty document,
    // `timeline_missing` on stderr, and the placeholder's transport
    // already out on stdout.
    const bytes = Cli.load(ctx.arena, ctx.io, ctx.cmd.path) catch |e|
        return Cli.reportLoadFailure(ctx, e);

    // A `.mid` or a `.it` is dumped first; anything else is a document.
    // The MAGIC decides, never the extension: `export-score` takes a
    // document by default and a file only when the bytes announce
    // themselves (`Cli.sniff` would give the name a turn, and an empty
    // `.sjon` is a document a document verb should assume).
    if (Cli.sniffMagic(bytes)) |kind| return fromFile(ctx, bytes, kind);
    return fromDocument(ctx, bytes);
}

fn fromDocument(ctx: *const Cli.Ctx, source: [:0]u8) Cli.Error!u8 {
    var loaded = try ctx.loadDocFrom(source);
    defer loaded.deinit();

    var derived = try tempura.time.derive.derive(ctx.gpa, &loaded.result.doc);
    defer derived.deinit();

    var all: std.ArrayList(tempura.Diag.Diagnostic) = .empty;
    defer all.deinit(ctx.arena);
    try all.appendSlice(ctx.arena, loaded.result.diags.items());
    try all.appendSlice(ctx.arena, derived.diags.items());

    return emit(ctx, &loaded.result.doc, &derived, &.{}, all.items, loaded.space());
}

fn fromFile(ctx: *const Cli.Ctx, bytes: []const u8, kind: Args.Kind) Cli.Error!u8 {
    var schema = try tempura.Schema.load(ctx.gpa);
    defer schema.deinit();

    // The anchor is named the way `dump` names it: one spelling, so a
    // `.mid` on stdin is `stdin.mid` here as there.
    var dumped = try pipeline.dump(ctx.gpa, &schema, bytes, Cli.anchorKind(kind), .{
        .file = ctx.anchorFile(kind),
    });
    defer dumped.deinit();

    var derived = try tempura.time.derive.derive(ctx.gpa, &dumped.doc);
    defer derived.deinit();

    // Plan 04's rule 2: a stale curve lane keeps the easing the record
    // hinted at, for the segments the file's own steps confirm — one
    // spelling in the core, the corpus runner's and the wasm's too.
    const hints = try dumped.easeHints(ctx.arena);

    var all: std.ArrayList(tempura.Diag.Diagnostic) = .empty;
    defer all.deinit(ctx.arena);
    try all.appendSlice(ctx.arena, dumped.diags.items());
    try all.appendSlice(ctx.arena, derived.diags.items());

    return emit(ctx, &dumped.doc, &derived, hints, all.items, .bytes);
}

fn emit(
    ctx: *const Cli.Ctx,
    doc: *const tempura.doc.Doc,
    derived: *const tempura.time.derive.Derived,
    hints: []const exporter.EaseHint,
    before: []const tempura.Diag.Diagnostic,
    space: Diags.Space,
) Cli.Error!u8 {
    // A conducted document whose file nobody could produce is REFUSED
    // rather than exported. Plan 03 says the anchor keeps time, and the
    // one field a score exists to carry — `(transport :bpm …)` — would
    // be the placeholder's 120 under a header that names the conductor:
    // wrong, not approximate, and indistinguishable downstream from a
    // piece that really is at 120. The load and the derivation already
    // said why (`anchor_unavailable`, an error), so the reason rides out
    // on stderr and stdout stays empty.
    if (tempura.doc.conductedPlaceholder(doc)) {
        try Diags.render(ctx.err, ctx.cmd.path, space, before, ctx.style);
        return Cli.Exit.errors;
    }

    var res = try exporter.exportScore(ctx.gpa, doc, derived, hints, options(ctx));
    defer res.deinit();

    // The score is emitted even when the document complained: plan 08's
    // own losses ride OUT as comments in the text ("; warning: meter
    // changes …"), so a person reads the score and the reason together,
    // and the exit code carries the verdict.
    if (!try ctx.emit(res.text)) return Cli.Exit.usage;

    try Diags.render(ctx.err, ctx.cmd.path, space, before, ctx.style);
    // The exporter's own spans index the DOCUMENT, and on the file path
    // there is no document text to count lines in — `.bytes` is then the
    // honest space for both halves.
    try Diags.render(ctx.err, ctx.cmd.path, space, res.diags.items(), ctx.style);
    return @max(Diags.exitCode(before), Diags.exitCode(res.diags.items()));
}

/// The flags, as one `Options`. A flag that was not given is absent
/// rather than re-spelled: the exporter's defaults are the plan's, and a
/// second copy of them here could only ever disagree.
fn options(ctx: *const Cli.Ctx) exporter.Options {
    const s = ctx.cmd.score;
    var opts: exporter.Options = .{
        .velocity = s.velocity,
        .ease_linear = s.ease_linear,
        .no_hints = s.no_hints,
        .section_markers = s.section_markers,
        .source_name = sourceName(ctx),
        .version = tempura.version,
    };
    if (s.eps) |x| opts.eps = x;
    if (s.tempo_eps) |x| opts.tempo_eps = x;
    if (s.max_keys_per_track) |x| opts.max_keys_per_track = x;
    return opts;
}

fn sourceName(ctx: *const Cli.Ctx) []const u8 {
    if (Diags.isStdin(ctx.cmd.path)) return "<stdin>";
    return std.fs.path.basename(ctx.cmd.path);
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "export-score: a native document becomes a pacer score on stdout" {
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-three-conductors-native/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "export-score", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);

    const text = c.out.written();
    // The header names the document by its BASENAME and this build by
    // its version, then the transport is the first form.
    try t.expect(std.mem.indexOf(u8, text, "exported from doc.sjon") != null);
    try t.expect(std.mem.indexOf(u8, text, "by tempura " ++ tempura.version) != null);
    try t.expect(std.mem.indexOf(u8, text, "(transport :bpm 125") != null);
}

test "export-score --velocity: a notes lane gains its sibling track" {
    const path = try Cli.repoPath(t.allocator, "corpus/playhead-sections-cues/doc.sjon");
    defer t.allocator.free(path);

    var plain = try Cli.invoke(&.{ "tempura", "export-score", path });
    defer plain.deinit();
    var vel = try Cli.invoke(&.{ "tempura", "export-score", path, "--velocity" });
    defer vel.deinit();

    try t.expectEqual(Cli.Exit.ok, vel.code);
    try t.expect(std.mem.indexOf(u8, plain.out.written(), "-vel") == null);
    try t.expect(std.mem.indexOf(u8, vel.out.written(), "-vel") != null);
}

test "export-score: the artifact goes where -o names, and stdout stays empty" {
    const a = t.allocator;
    const path = try Cli.repoPath(a, "corpus/tempo-three-conductors-native/doc.sjon");
    defer a.free(path);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dest = try std.fmt.allocPrintSentinel(
        a,
        ".zig-cache/tmp/{s}/s.score.sjon",
        .{tmp.sub_path},
        0,
    );
    defer a.free(dest);

    var c = try Cli.invoke(&.{ "tempura", "export-score", path, "-o", dest });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.out.written());

    const written = try tmp.dir.readFileAlloc(std.testing.io, "s.score.sjon", a, .limited(1 << 20));
    defer a.free(written);
    try t.expect(std.mem.indexOf(u8, written, "(transport ") != null);
}

test "export-score: a .mid is dumped first, and the score is of that document" {
    const path = try Cli.repoPath(t.allocator, "corpus/skeleton-smf/song.mid");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "export-score", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "exported from song.mid") != null);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "(transport ") != null);
}

test "export-score: a conducted document whose file is not here is refused" {
    // C1's third leg. The other two are the load's and the derivation's
    // diagnostics; this is the artifact, and the claim is that there
    // ISN'T one: a score whose transport came from the placeholder must
    // not leave the process.
    const path = try Cli.repoPath(t.allocator, "src/cli/testdata/conducted-absent.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "export-score", path });
    defer c.deinit();

    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "anchor_unavailable") != null);
    try t.expect(std.mem.indexOf(u8, c.err.written(), "(transport") == null);
}

test "export-score: a BY-REFERENCE conductor's transport is the file's tempo" {
    // …and the same verb over the same shape WITH the file beside it:
    // the corpus's `tempo-by-reference-conductor` names `song.mid` and
    // carries no inline dump, and its tempo track says 480 000
    // microseconds — 125 quarter notes per minute. Before C1 was fixed
    // this said `:bpm 120`, from plan 03's placeholder, with no
    // diagnostic anywhere.
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-by-reference-conductor/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "export-score", path });
    defer c.deinit();

    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "(transport :bpm 125") != null);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "conductor: song.mid") != null);
}

test "export-score: --eps and --max-keys-per-track reach the exporter" {
    // A budget of one key per track is small enough that any curve lane
    // trips it, which is the flag arriving rather than being ignored.
    const path = try Cli.repoPath(t.allocator, "corpus/playhead-sections-cues/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{
        "tempura", "export-score", path, "--eps", "0.5", "--max-keys-per-track", "1",
    });
    defer c.deinit();
    // The verdict is the document's, not the flag's: a warning never
    // moves the exit code.
    try t.expectEqual(Cli.Exit.ok, c.code);
}

test "export-score: a stale curve lane's score is the core's, easing hints and all" {
    // The verb and the core agree byte for byte on the score of a FILE
    // whose curve lane is stale — the one input a file's score has and a
    // document's lacks. `Dumped.easeHints` is the step both take, and the
    // wasm's `tpr_exportScore` after `tpr_loadFile` too (the npm parity
    // walk pins that leg against the same case's golden).
    const a = t.allocator;
    const path = try Cli.repoPath(a, "corpus/residue-stale-curve/song.mid");
    defer a.free(path);

    var c = try Cli.invoke(&.{ "tempura", "export-score", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20));
    defer a.free(bytes);
    var schema = try tempura.Schema.load(a);
    defer schema.deinit();
    var dumped = try pipeline.dump(a, &schema, bytes, .smf, .{ .file = "song.mid" });
    defer dumped.deinit();
    var derived = try tempura.time.derive.derive(a, &dumped.doc);
    defer derived.deinit();
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const hints = try dumped.easeHints(scratch.allocator());
    // The case exists for this: one hint kept, and the score spends it.
    try t.expectEqual(@as(usize, 1), hints.len);

    var core = try exporter.exportScore(a, &dumped.doc, &derived, hints, .{
        .source_name = "song.mid",
        .version = tempura.version,
    });
    defer core.deinit();
    try t.expectEqualStrings(core.text, c.out.written());
    try t.expect(std.mem.indexOf(u8, core.text, ":ease in-cubic") != null);

    // …and the hint is what made it so: without it the segment is the
    // file's stair, which is what the wasm printed before it kept hints.
    var bare = try Cli.invoke(&.{ "tempura", "export-score", path, "--no-hints" });
    defer bare.deinit();
    try t.expect(!std.mem.eql(u8, bare.out.written(), c.out.written()));
    try t.expect(std.mem.indexOf(u8, bare.out.written(), ":ease in-cubic") == null);
}
