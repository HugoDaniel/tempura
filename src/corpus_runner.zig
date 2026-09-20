//! Golden-corpus runner — the native half of tempura's determinism gate.
//!
//! Each `corpus/<case>/` directory will hold a pinned input (`doc.sjon`,
//! `song.mid` or `song.it`), the harness that says what to ask of it
//! (`times.sjon`, validated against `schema/tempura-corpus.sjon`), and a
//! GENERATED `expected.sjon` golden. This runner is the AUTHORITY for that
//! text: the wasm half re-derives the same bytes and compares against the
//! same goldens, which is where native-vs-wasm equality is asserted.
//!
//! `zig build corpus -- --update` regenerates the goldens; the diff is
//! reviewed, and a golden is never hand-edited.
//!
//! The case format and the walk itself land with P107. Until then the
//! runner only enumerates: an empty corpus is a PASS (there is nothing to
//! disagree about), and a case directory that exists while nothing can run
//! it is a FAILURE — an unrun case must never be reported green.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    const out = &stderr_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    var corpus_path: ?[]const u8 = null;
    var update = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--update")) {
            update = true;
        } else if (corpus_path == null) {
            corpus_path = arg;
        } else {
            try out.print("usage: corpus-runner <corpus-dir> [--update]\n", .{});
            return 2;
        }
    }
    const root = corpus_path orelse {
        try out.print("usage: corpus-runner <corpus-dir> [--update]\n", .{});
        return 2;
    };

    // Collect case directories, sorted — filesystem iteration order is
    // unspecified and the report has to be stable.
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
        try out.print("corpus: cannot open `{s}`: {s}\n", .{ root, @errorName(err) });
        return 1;
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    try out.print("corpus: {d} cases\n", .{names.items.len});
    if (names.items.len == 0) {
        if (update) try out.print("corpus: --update has no case to regenerate\n", .{});
        return 0;
    }
    for (names.items) |name| {
        try out.print("  UNRUN {s} — the case format lands with P107\n", .{name});
    }
    return 1;
}
