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
//! **The other hint source is not wired, and cannot be here.** Plan 08
//! also names midivia's `ease-hint` events, which the SMF reader types
//! as `.ease_hint` and keeps as BYTES: decoding that payload into pacer's
//! easing vocabulary has no decoder in this tree (`doc/bridge_smf.zig`
//! says so where it spells the head), so an inline `midi/` tier's hints
//! are unavailable to every caller, not only to this one.

const std = @import("std");
const tempura = @import("tempura");

const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const exporter = tempura.exporter;
const pipeline = tempura.doc.pipeline;

pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    const bytes = Cli.load(ctx.a, ctx.io, ctx.cmd.path) catch |e|
        return Cli.reportLoadFailure(ctx, e);

    // A `.mid` or a `.it` is dumped first; anything else is a document.
    // The MAGIC decides, never the extension alone: `Cli.sniff` would
    // call an empty `.sjon` nothing at all, and a document is what a
    // document verb should assume when the bytes say nothing.
    if (nativeKind(bytes)) |kind| return fromFile(ctx, bytes, kind);
    return fromDocument(ctx);
}

/// The native format these bytes ARE, by magic alone. The extension gets
/// no turn here: `export-score` takes a document by default and a file
/// only when the bytes announce themselves.
fn nativeKind(bytes: []const u8) ?tempura.doc.AnchorKind {
    if (std.mem.startsWith(u8, bytes, "MThd")) return .smf;
    if (std.mem.startsWith(u8, bytes, "IMPM")) return .it;
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "RIFF") and
        std.mem.eql(u8, bytes[8..12], "RMID")) return .smf;
    return null;
}

fn fromDocument(ctx: *const Cli.Ctx) Cli.Error!u8 {
    var loaded = switch (try ctx.loadDoc()) {
        .failed => |code| return code,
        .ok => |l| l,
    };
    defer loaded.deinit();

    var derived = try tempura.time.derive.derive(ctx.gpa, &loaded.result.doc);
    defer derived.deinit();

    var all: std.ArrayList(tempura.Diag.Diagnostic) = .empty;
    defer all.deinit(ctx.a);
    try all.appendSlice(ctx.a, loaded.result.diags.items());
    try all.appendSlice(ctx.a, derived.diags.items());

    return emit(ctx, &loaded.result.doc, &derived, &.{}, all.items, loaded.space());
}

fn fromFile(ctx: *const Cli.Ctx, bytes: []const u8, kind: tempura.doc.AnchorKind) Cli.Error!u8 {
    var schema = try tempura.Schema.load(ctx.gpa);
    defer schema.deinit();

    var dumped = try pipeline.dump(ctx.gpa, &schema, bytes, kind, .{
        .file = std.fs.path.basename(Diags.label(ctx.cmd.path)),
    });
    defer dumped.deinit();

    var derived = try tempura.time.derive.derive(ctx.gpa, &dumped.doc);
    defer derived.deinit();

    // Plan 04's rule 2: a stale curve lane keeps the easing the record
    // hinted at, for the segments the file's own steps confirm. The
    // verdict already dropped the rest (`ease_hint_mismatch`), so what is
    // left is exactly what the exporter should honour.
    var hints: std.ArrayList(exporter.EaseHint) = .empty;
    defer hints.deinit(ctx.a);
    for (dumped.verdicts) |v| {
        for (v.hints) |h| try hints.append(ctx.a, .{
            .lane = v.lane,
            .from = h.from,
            .to = h.to,
            .ease = h.ease,
        });
    }

    var all: std.ArrayList(tempura.Diag.Diagnostic) = .empty;
    defer all.deinit(ctx.a);
    try all.appendSlice(ctx.a, dumped.diags.items());
    try all.appendSlice(ctx.a, derived.diags.items());

    return emit(ctx, &dumped.doc, &derived, hints.items, all.items, .bytes);
}

fn emit(
    ctx: *const Cli.Ctx,
    doc: *const tempura.doc.Doc,
    derived: *const tempura.time.derive.Derived,
    hints: []const exporter.EaseHint,
    before: []const tempura.Diag.Diagnostic,
    space: Diags.Space,
) Cli.Error!u8 {
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
    const dest = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/s.score.sjon", .{tmp.sub_path}, 0);
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
