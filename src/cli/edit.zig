//! `tempura edit DOC --op '<json>' [--dry-run] [--select …]` — plan and
//! apply one operation.
//!
//! Plan 10's row, over plan 07's contract: "plans and applies one
//! operation (07); `--dry-run` prints the actions; `--select` takes the
//! selection spelling".
//!
//! ## One operation, two artifacts
//!
//! The verb runs the same two steps either way — `edit.plan` then
//! `edit.apply` — and `--dry-run` stops after the first and prints what
//! it produced. The actions are the plan's own text (`Plan.text`), which
//! is exactly what the corpus pins for an `edit-*` case: a rehearsal a
//! person reads and a golden a machine diffs are the same bytes, so
//! there is no second rendering to drift.
//!
//! ## `--select` is a `"sel"`, and nothing new
//!
//! Plan 10 gives `--select` "the selection spelling". The spelling
//! already exists: `"sel"` inside `--op`'s JSON, documented in
//! `edit/edit.zig`'s header (`{"lanes": […], "range": [from, to),
//! "kinds": […], "keys": […]}`). So `--select` takes that object and is
//! MERGED into the operation — a second vocabulary for one question would
//! be a second thing to get wrong. Given both, `--select` wins, because a
//! flag on the command line is the later word.
//!
//! ## Which load errors stop an edit
//!
//! All of them but two, and `blocksEdit` says which two and why: an
//! anchor's FILE being unreadable or not matching its `:size` /
//! `:sha256` is not about anything an edit acts on, because a bound
//! operation walks the inline dump's own forms in the tree. Such a
//! diagnostic is still PRINTED — it is an error and the user hears it —
//! and the edit goes through, so the exit code is 0 with an error line
//! on stderr. That combination is deliberate: the verb's product is the
//! document's text, the document's text was produced correctly, and the
//! thing that is wrong is a file this invocation never needed.
//!
//! ## A refusal is an answer
//!
//! Plan 07: "an operation that cannot be done yields an empty action list
//! and a diagnostic with the span of the node it refused on". So a
//! refusal prints its diagnostic, writes NO document, and exits 1 — the
//! document code, because the refusal is a fact about this document and
//! this ask. An operation that is not an operation at all (bad JSON, an
//! unknown head) is the INVOCATION's fault and exits 2.

const std = @import("std");
const sjon = @import("sjon");
const tempura = @import("tempura");

const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const edit = tempura.edit;

pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    var loaded = switch (try ctx.loadDoc()) {
        .failed => |code| return code,
        .ok => |l| l,
    };
    defer loaded.deinit();

    // An edit over a document that does not hold together would plan
    // against addresses the document layer has already complained
    // about — so a load error stops the verb, with two exceptions named
    // in `blocksEdit`. The report goes out either way: a tolerated error
    // is still an error and the user hears it.
    const blocking = firstBlocker(loaded.result.diags.items());
    try ctx.report(loaded.space(), loaded.result.diags.items());
    if (blocking) return Cli.Exit.errors;

    const op_json = switch (try merged(ctx)) {
        .ok => |text| text,
        .failed => |code| return code,
    };

    var parsed = try edit.fromJson(ctx.gpa, op_json);
    defer parsed.deinit();
    const op = parsed.op orelse {
        // The spans index the OPERATION's text, not the document's.
        try Diags.render(ctx.err, "<--op>", .bytes, parsed.diags.items(), ctx.style);
        return Cli.Exit.usage;
    };

    var tree = try sjon.parse(ctx.gpa, loaded.source);
    defer tree.deinit();

    // The map is the one `fromSource` already derived; handing it in is
    // what keeps the document's time from being derived twice.
    var plan = try edit.planWith(ctx.gpa, &loaded.result.doc, &tree, &loaded.result.map, op);
    defer plan.deinit();

    if (plan.summary.refused or plan.diags.hasErrors()) {
        try ctx.report(loaded.space(), plan.diags.items());
        return Cli.Exit.errors;
    }

    const artifact: []const u8 = if (ctx.cmd.edit.dry_run) blk: {
        break :blk try plan.text(ctx.gpa);
    } else blk: {
        var applied = try edit.apply(ctx.gpa, loaded.source, &plan);
        defer applied.deinit();
        if (applied.diags.hasErrors()) {
            try ctx.report(loaded.space(), applied.diags.items());
            return Cli.Exit.errors;
        }
        break :blk try ctx.gpa.dupe(u8, applied.text);
    };
    defer ctx.gpa.free(artifact);

    if (!try ctx.emit(artifact)) return Cli.Exit.usage;
    // Warnings survive a successful edit and are worth saying: an
    // `edit_inexact` is a document that is not quite what was asked for.
    try ctx.report(loaded.space(), plan.diags.items());
    return Cli.Exit.ok;
}

/// Whether any of these diagnostics stops the edit.
fn firstBlocker(diags: []const tempura.Diag.Diagnostic) bool {
    for (diags) |d| {
        if (d.severity == .err and blocksEdit(d.code)) return true;
    }
    return false;
}

/// Which load errors an edit cannot be planned over.
///
/// **Every one but two.** A plan's addresses come from a fresh parse of
/// the document's own text and its targets from the `Doc` the walk built,
/// so anything that made either of those wrong makes the plan wrong: a
/// parse error, a duplicate `(timeline …)`, a lane that names itself
/// twice, an address the schema cannot read. Those stop the verb, for
/// `build`'s reason — the product is a document somebody keeps.
///
/// The two exceptions are the two that are about an anchor's FILE rather
/// than about the document: `anchor_unavailable` (no resolver could read
/// it) and `anchor_mismatch` (it was read and does not match the `:size`
/// or `:sha256` the anchor declares). Neither touches what an edit acts
/// on. A NATIVE operation never looks at an anchor at all, and a BOUND
/// one walks the inline dump's own `(midi/mtrk …)` events or
/// `(it/pattern …)` cells IN THE TREE — the file is where those bytes
/// came from, not where they are. The one thing the file does carry is an
/// `it/` tier's `(bin :at :len)` regions, and a selection over a tier
/// that kept its patterns by reference finds no `(ev …)` form to address,
/// so the plan comes back empty rather than wrong.
///
/// Refusing them was this verb's own bug: every `edit-bound-*` document
/// names a file that is not beside it, so no bound edit was reachable
/// through the CLI at all while the engine planned them correctly.
fn blocksEdit(code: tempura.Diag.Code) bool {
    return switch (code) {
        .anchor_unavailable, .anchor_mismatch => false,
        else => true,
    };
}

const Merged = union(enum) { ok: []const u8, failed: u8 };

/// `--op`, with `--select`'s object under its `"sel"` key.
///
/// Both are JSON, so the merge is JSON's: parse, set, print. Neither is
/// interpreted here — `Op.fromJson` is the one reader of this grammar and
/// every complaint about it should come from there, with its wording.
fn merged(ctx: *const Cli.Ctx) Cli.Error!Merged {
    const op_text = ctx.cmd.edit.op.?;
    const sel_text = ctx.cmd.edit.select orelse return .{ .ok = op_text };

    var op = std.json.parseFromSlice(std.json.Value, ctx.gpa, op_text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("tempura: --op is not JSON ({s})\n", .{@errorName(e)});
            return .{ .failed = Cli.Exit.usage };
        },
    };
    defer op.deinit();
    var sel = std.json.parseFromSlice(std.json.Value, ctx.gpa, sel_text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("tempura: --select is not JSON ({s})\n", .{@errorName(e)});
            return .{ .failed = Cli.Exit.usage };
        },
    };
    defer sel.deinit();

    if (op.value != .object) {
        try ctx.err.writeAll("tempura: --op takes one JSON object\n");
        return .{ .failed = Cli.Exit.usage };
    }
    if (sel.value != .object) {
        try ctx.err.writeAll("tempura: --select takes one JSON object of lanes, range, kinds and keys\n");
        return .{ .failed = Cli.Exit.usage };
    }

    // WRITTEN, never mutated. `parseFromSlice`'s `ObjectMap` holds its
    // storage in the `Parsed`'s own arena, and `put`ting into it with any
    // other allocator frees the old index header with the wrong one the
    // moment the map outgrows its capacity — a heap corruption this verb
    // shipped for an afternoon, reachable from an `--op` with fifteen
    // keys and a `--select` beside it. So the merge emits TEXT: each of
    // the operation's own pairs, then `"sel"`, into the invocation's
    // arena, with nothing written back into either parse.
    var out: std.Io.Writer.Allocating = .init(ctx.a);
    const w = &out.writer;
    try w.writeByte('{');
    var it = op.value.object.iterator();
    while (it.next()) |entry| {
        // The flag is the later word, so the operation's own `"sel"` is
        // dropped rather than emitted twice.
        if (std.mem.eql(u8, entry.key_ptr.*, "sel")) continue;
        try writeJson(w, entry.key_ptr.*);
        try w.writeByte(':');
        try writeJson(w, entry.value_ptr.*);
        try w.writeByte(',');
    }
    try w.writeAll("\"sel\":");
    try writeJson(w, sel.value);
    try w.writeByte('}');
    return .{ .ok = out.written() };
}

/// One JSON value onto `w`. `Stringify.value` fails only the way the
/// writer does, and this one is allocating, so the only failure is
/// exhaustion.
fn writeJson(w: *std.Io.Writer, v: anytype) Cli.Error!void {
    std.json.Stringify.value(v, .{}, w) catch |e| switch (e) {
        error.WriteFailed => return error.WriteFailed,
    };
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A scratch copy of the edit engine's own native fixture, as a file the
/// CLI can be pointed at.
const Doc = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    const source =
        \\; impulsos — the native fixture
        \\(timeline :title "impulsos" :length 8bar :end loop)
        \\
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\
        \\(section :name intro :at 0bar :dur 4bar)
        \\(cue :name "the drop" :at 4bar)
        \\
        \\(lane :name flash :target flash
        \\  ; the downbeat
        \\  (note :at 0q :dur 0.5q :key 36 :vel 110)
        \\  (note :at 1q :dur 0.5q :key 60 :vel 90)
        \\  (note :at 2q :dur 0.5q :key 36 :vel 80))
        \\(lane :name glow :kind curve :target glow
        \\  (keyframe :at 0q :value 0.2 :ease hold)
        \\  (keyframe :at 4q :value 0.9 :ease in-cubic))
        \\
    ;

    fn init() !Doc {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "doc.sjon", .data = source });
        return .{
            .tmp = tmp,
            .path = try std.fmt.allocPrintSentinel(
                t.allocator,
                ".zig-cache/tmp/{s}/doc.sjon",
                .{tmp.sub_path},
                0,
            ),
        };
    }

    fn deinit(self: *Doc) void {
        t.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

test "edit --dry-run: the actions are printed and the document is not touched" {
    const a = t.allocator;
    var d = try Doc.init();
    defer d.deinit();

    var c = try Cli.invoke(&.{
        "tempura", "edit",                                                                    d.path, "--dry-run",
        "--op",    "{\"op\":\"transpose\",\"sel\":{\"lanes\":[\"flash\"]},\"semitones\":12}",
    });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());

    // Plan 07's action grammar, one action per line, as the corpus pins
    // it — three notes, three `set_keyword :key`s.
    try t.expect(std.mem.startsWith(u8, c.out.written(), "[\n{\"op\":\"set_keyword\""));
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"key\":\"key\",\"value\":48") != null);

    const after = try d.tmp.dir.readFileAlloc(std.testing.io, "doc.sjon", a, .limited(1 << 20));
    defer a.free(after);
    try t.expectEqualStrings(Doc.source, after);
}

test "edit: the applied document keeps every byte the edit did not touch" {
    var d = try Doc.init();
    defer d.deinit();

    var c = try Cli.invoke(&.{
        "tempura", "edit",                                                                           d.path,
        "--op",    "{\"op\":\"velocity\",\"sel\":{\"lanes\":[\"flash\"],\"keys\":[36]},\"vel\":64}",
    });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);

    const text = c.out.written();
    try t.expect(std.mem.indexOf(u8, text, "  ; the downbeat\n  (note :at 0q :dur 0.5q :key 36 :vel 64)") != null);
    // The key that was not selected is untouched.
    try t.expect(std.mem.indexOf(u8, text, "(note :at 1q :dur 0.5q :key 60 :vel 90)") != null);
    // …and so is the header comment.
    try t.expect(std.mem.startsWith(u8, text, "; impulsos — the native fixture\n"));
}

test "edit --select: the flag supplies the operation's selection" {
    var d = try Doc.init();
    defer d.deinit();

    // The operation carries no `"sel"` at all; the flag is the whole of
    // it.
    var c = try Cli.invoke(&.{
        "tempura", "edit",                                   d.path,     "--dry-run",
        "--op",    "{\"op\":\"transpose\",\"semitones\":1}", "--select", "{\"lanes\":[\"flash\"],\"keys\":[60]}",
    });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    // One note carries key 60, so one action.
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"value\":61") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, c.out.written(), "set_keyword"));
}

test "edit: an operation that is not one is a usage error and writes nothing" {
    var d = try Doc.init();
    defer d.deinit();

    for ([_][:0]const u8{ "{", "{\"op\":\"rewind\"}", "[]" }) |bad| {
        var c = try Cli.invoke(&.{ "tempura", "edit", d.path, "--op", bad });
        defer c.deinit();
        try t.expectEqual(Cli.Exit.usage, c.code);
        try t.expectEqualStrings("", c.out.written());
        try t.expect(std.mem.indexOf(u8, c.err.written(), "sjon_diagnostic") != null);
    }
}

test "edit: a refusal writes no document and carries the engine's diagnostic" {
    var d = try Doc.init();
    defer d.deinit();

    // A meter point off a bar line is plan 07's `edit_off_bar`.
    var c = try Cli.invoke(&.{
        "tempura", "edit",                                                    d.path,
        "--op",    "{\"op\":\"insert-meter\",\"at\":46126080,\"sig\":[3,4]}",
    });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "edit_off_bar") != null);
}

test "edit --select: a large --op object merges without freeing anybody else's memory" {
    // The bug: `--select` used to `put` into the `ObjectMap`
    // `parseFromSlice` returned, with the CLI's allocator rather than the
    // parse's arena. Under sixteen keys the map never grows and nothing
    // happens; past a capacity boundary the old index header is freed
    // with the wrong allocator and the process aborts (exit 134 under a
    // non-debug allocator, a detected invalid free under this one).
    //
    // Twenty keys, so the boundary is crossed whatever the growth policy,
    // and the merge is checked to have kept every one of them.
    const a = t.allocator;
    var d = try Doc.init();
    defer d.deinit();

    var op: std.Io.Writer.Allocating = .init(a);
    defer op.deinit();
    try op.writer.writeAll("{\"op\":\"transpose\",\"semitones\":12");
    for (0..20) |i| try op.writer.print(",\"k{d}\":{d}", .{ i, i });
    try op.writer.writeAll("}");
    const op_json = try a.dupeZ(u8, op.written());
    defer a.free(op_json);

    var c = try Cli.invoke(&.{
        "tempura", "edit",  d.path,     "--dry-run",
        "--op",    op_json, "--select", "{\"lanes\":[\"flash\"],\"kinds\":[\"note\"]}",
    });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    // The operation still transposes — the merge kept `"op"` and
    // `"semitones"` and did not truncate at the boundary.
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, c.out.written(), "set_keyword"));
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"value\":48") != null);
}

test "edit --select: the flag's selection replaces the operation's own" {
    var d = try Doc.init();
    defer d.deinit();

    // Both carry a `"sel"`; the flag is the later word, and the merged
    // object carries exactly one.
    var c = try Cli.invoke(&.{
        "tempura",
        "edit",
        d.path,
        "--dry-run",
        "--op",
        "{\"op\":\"transpose\",\"semitones\":1,\"sel\":{\"lanes\":[\"glow\"]}}",
        "--select",
        "{\"lanes\":[\"flash\"],\"keys\":[60]}",
    });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    // Key 60 is the one note the flag's selection covers; `glow` has no
    // notes at all, so the operation's own `"sel"` would have planned
    // nothing.
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, c.out.written(), "set_keyword"));
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"value\":61") != null);
}

test "edit: an unresolved anchor does not block an edit whose tier is inline" {
    // The bug: the verb refused ANY load error, and every bound fixture
    // names a file that is not beside it (`anchor_unavailable`), so no
    // bound edit was reachable through the CLI at all. The diagnostic is
    // still printed — it is an error and the user hears it — and the
    // edit goes through.
    const a = t.allocator;
    const path = try Cli.repoPath(a, "corpus/edit-bound-it-shared/doc.sjon");
    defer a.free(path);

    var c = try Cli.invoke(&.{
        "tempura", "edit",                                                                                  path, "--dry-run",
        "--op",    "{\"op\":\"velocity\",\"sel\":{\"lanes\":[\"lead\"]},\"vel\":64,\"allow-shared\":true}",
    });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expect(std.mem.indexOf(u8, c.err.written(), "anchor_unavailable") != null);
    // 64 · 64/127 = 32, written into the volume column of the one cell.
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"key\":\"vol\",\"value\":32") != null);
}

test "edit: a document that does not PARSE is still refused" {
    // The narrowing is two codes wide and no wider: a parse error means
    // the addresses a plan names do not exist.
    const path = try Cli.repoPath(t.allocator, "src/cli/testdata/bad-doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{
        "tempura", "edit",                          path, "--dry-run",
        "--op",    "{\"op\":\"merge\",\"sel\":{}}",
    });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "lane_duplicate") != null);
}

test "edit: the two bound corpus cases run through the verb, not only the engine" {
    // `corpus/edit-bound-{smf-pair,it-cell}` carry their anchor's file
    // beside them (`zig build fixtures`), so they load clean and the
    // operation the corpus pins as a PLAN is applied here as TEXT — the
    // two halves of plan 07's contract over one document.
    const a = t.allocator;
    const cases = [_]struct { case: []const u8, op: [:0]const u8, want: []const u8 }{
        .{
            .case = "corpus/edit-bound-smf-pair/doc.sjon",
            .op = "{\"op\":\"retime\",\"sel\":{\"lanes\":[\"kick\"],\"kinds\":[\"note\"],\"range\":[0,1]},\"delta\":92252160}",
            // The pair moved a whole bar's half: the `note-on` is now at
            // SMF tick 960 and the `note-off` at 1200, after the events
            // it crossed.
            .want = "(note-on :at 960 :ch 1 :key 36 :vel 100)",
        },
        .{
            .case = "corpus/edit-bound-it-cell/doc.sjon",
            .op = "{\"op\":\"retime\",\"sel\":{\"lanes\":[\"lead\"],\"kinds\":[\"note\"],\"range\":[92252160,92252161]},\"delta\":5765760}",
            // Three of the twenty-four ticks a row holds at speed 24, so
            // the cell is delayed inside the row it already sits in.
            .want = "SD3",
        },
    };

    for (cases) |c| {
        const path = try Cli.repoPath(a, c.case);
        defer a.free(path);
        var got = try Cli.invoke(&.{ "tempura", "edit", path, "--op", c.op });
        defer got.deinit();
        try t.expectEqual(Cli.Exit.ok, got.code);
        try t.expectEqualStrings("", got.err.written());
        try t.expect(std.mem.indexOf(u8, got.out.written(), c.want) != null);
        // Layout preserved: the document's own header comment survives.
        try t.expect(std.mem.startsWith(u8, got.out.written(), "; A document whose one anchor is an INLINE"));
    }
}

test "edit: -o writes the edited document, and the input is left alone" {
    const a = t.allocator;
    var d = try Doc.init();
    defer d.deinit();

    const dest = try std.fmt.allocPrintSentinel(
        a,
        ".zig-cache/tmp/{s}/edited.sjon",
        .{d.tmp.sub_path},
        0,
    );
    defer a.free(dest);

    var c = try Cli.invoke(&.{
        "tempura", "edit",                                                                                            d.path, "-o", dest,
        "--op",    "{\"op\":\"remove\",\"sel\":{\"lanes\":[\"flash\"],\"kinds\":[\"note\"],\"range\":[0,46126080]}}",
    });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.out.written());

    const before = try d.tmp.dir.readFileAlloc(std.testing.io, "doc.sjon", a, .limited(1 << 20));
    defer a.free(before);
    try t.expectEqualStrings(Doc.source, before);

    const after = try d.tmp.dir.readFileAlloc(std.testing.io, "edited.sjon", a, .limited(1 << 20));
    defer a.free(after);
    try t.expect(std.mem.indexOf(u8, after, ":key 36 :vel 110") == null);
    try t.expect(std.mem.indexOf(u8, after, ":key 60 :vel 90") != null);
}
