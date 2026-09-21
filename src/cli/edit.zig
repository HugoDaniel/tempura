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
    // against addresses the document layer has already complained about.
    // `build`'s rule, for `build`'s reason: the product is a document
    // somebody keeps.
    if (loaded.result.diags.hasErrors()) {
        try ctx.report(loaded.space(), loaded.result.diags.items());
        return Cli.Exit.errors;
    }

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

    var object = op.value.object;
    object.put(ctx.gpa, "sel", sel.value) catch return error.OutOfMemory;
    const text = std.json.Stringify.valueAlloc(ctx.a, std.json.Value{ .object = object }, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .ok = text };
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
