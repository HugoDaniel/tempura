//! `tempura check-residue FILE` — what a file carries, and whether the
//! file still agrees with it.
//!
//! Plan 10's row: "reports what the file carries (essence version, lane
//! records and their hash verdicts, IT chunk and tail), the survival
//! measurement's tool".
//!
//! The whole verb is `doc.pipeline.checkResidue` plus the channel policy.
//! Nothing is restored, no schema is loaded and no document is built:
//! this is the view of the CARRIER, which is exactly what you want when
//! the question is "did this DAW keep the payload". `dump` is the verb
//! that acts on the answer.
//!
//! ## Which channel
//!
//! The table rides STDOUT, for `inspect`'s reason: it is not a
//! diagnostic, it is the thing you pipe into `grep` or paste into a
//! survival log. The reader's own complaints about the bytes ride stderr
//! beside it, in the file's coordinate space. Neither takes `-o` — a
//! shell redirect is the whole of what one would add.
//!
//! ## The exit code
//!
//! The verdicts are FACTS, not failures: a lane whose hash differs is a
//! file somebody edited, which is the normal case this tool exists to
//! see, and reporting it as an error would make `check-residue` useless
//! in a `&&` chain. So only the reader's and the carrier's own
//! diagnostics move the code — a truncated chunk is a defect in the
//! file, a stale hash is not.

const std = @import("std");
const tempura = @import("tempura");

const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    const bytes = Cli.load(ctx.a, ctx.io, ctx.cmd.path) catch |e|
        return Cli.reportLoadFailure(ctx, e);

    const kind = try ctx.sniffKind(bytes) orelse return Cli.Exit.usage;

    var report = try tempura.doc.pipeline.checkResidue(ctx.gpa, bytes, Cli.anchorKind(kind));
    defer report.deinit();

    try ctx.out.writeAll(report.text);
    try ctx.report(.bytes, report.diags.items());
    return Diags.exitCode(report.diags.items());
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "check-residue: a file with no residue says so in one line, and exits ok" {
    const path = try Cli.repoPath(t.allocator, "corpus/skeleton-smf/song.mid");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "check-residue", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());
    try t.expectEqualStrings("essence: none\nconductor: no record\n", c.out.written());
}

test "check-residue: a .it reports both carriers before the table" {
    const path = try Cli.repoPath(t.allocator, "corpus/it-passthrough/song.it");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "check-residue", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    // The fixture carries a `TMPU` chunk another tool's shape wrote, so
    // the two carrier lines are the first thing the table says.
    try t.expect(std.mem.startsWith(u8, c.out.written(), "chunk: "));
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\ntail: ") != null);
}

test "check-residue: a file that is neither kind is a usage error with an empty stdout" {
    const path = try Cli.repoPath(t.allocator, "corpus/it-minimal/times.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "check-residue", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
}
