//! `tempura validate DOC` — the schema and host checks, with spans.
//!
//! Plan 10's row: "schema + host checks (anchors, addresses, cross-refs,
//! the walk's diagnostics) with spans; exit code for CI; SJON's
//! diagnostic output shape".
//!
//! There is nothing here but a load and a render, and that is the point:
//! `doc.fromSource` already runs every rule — SJON's validation of the
//! four composed manifests, then `doc/checks.zig`'s lane names, scene
//! names, note overlap, clip placement and anchor verification — and
//! returns them all as one list of spans. A CLI that re-stated any of
//! them would be a second spelling of a rule that already has one.
//!
//! The anchors ARE resolved: a `tempura.FsStore` is pointed at the
//! document's own directory, because plan 02 resolves an `:file` "relative to the
//! document" and because an anchor that cannot be read, or whose bytes
//! disagree with its `:size` / `:sha256`, is exactly what a CI gate is
//! for. That is the one thing this verb does that a pure parse would not.
//!
//! The report goes to STDERR and stdout stays empty (plan 10: diagnostics
//! to stderr, artifacts to stdout). `validate` has no artifact, so
//! `tempura validate d.sjon && tempura dump s.mid -o d.sjon` composes.

const std = @import("std");

const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

/// The verb: load the document with its anchors resolved and render the
/// whole report on stderr; stdout stays empty. Exits with the report's
/// verdict. Every value it builds is freed before it returns.
pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    var loaded = switch (try ctx.loadDoc()) {
        .failed => |code| return code,
        .ok => |l| l,
    };
    defer loaded.deinit();

    const items = loaded.result.diags.items();
    try Diags.render(ctx.err, ctx.cmd.path, loaded.space(), items, ctx.style);
    try Diags.summary(ctx.err, ctx.cmd.path, items);
    return Diags.exitCode(items);
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "validate: a clean corpus document is exit 0, empty stdout, one summary line" {
    const path = try Cli.repoPath(t.allocator, "corpus/playhead-sections-cues/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "validate", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.endsWith(u8, c.err.written(), ": no diagnostics\n"));
}

test "validate: a defective document is exit 1 with one line per diagnostic" {
    const path = try Cli.repoPath(t.allocator, "src/cli/testdata/bad-doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "validate", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expectEqualStrings("", c.out.written());
    // The shape, with the fixture's own path as the label: a span is a
    // byte offset in the library and a line and column here.
    try t.expect(std.mem.indexOf(u8, c.err.written(), "bad-doc.sjon:") != null);
    try t.expect(std.mem.indexOf(u8, c.err.written(), ": error ") != null);
    try t.expect(std.mem.indexOf(u8, c.err.written(), "lane_duplicate") != null);
}

test "validate: an anchor the document's own directory cannot produce is reported" {
    // The resolver is pointed at the DOCUMENT's directory, so this is a
    // real read that really fails, not a parse rule.
    const path = try Cli.repoPath(t.allocator, "src/cli/testdata/missing-anchor.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "validate", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expect(std.mem.indexOf(u8, c.err.written(), "anchor_unavailable") != null);
}

test "validate: a document on stdin is labelled <stdin>" {
    // Not through `run` — stdin is the process's, and a test that
    // redirected it would be testing the harness. The label rule is what
    // the CLI owns, and it is pure.
    try t.expectEqualStrings("<stdin>", Diags.label("-"));
}
