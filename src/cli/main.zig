//! tempura CLI entry point.
//!
//! The binary is built against the PUBLIC `tempura` module, not the
//! sources: it is a consumer like any host, so a surface it needs and
//! `src/root.zig` does not export fails the `cli` build (build.zig says
//! why). Verb dispatch, argument parsing and rendering will live behind a
//! `run(gpa, io, argv, stdout, stderr) !u8` seam in `src/cli/Cli.zig`
//! (pacer's arrangement) so the in-source tests drive the code the binary
//! runs; nothing is implemented yet.
//!
//! Channels, once verbs exist: artifacts to stdout or `-o`, diagnostics
//! and usage to stderr, `NO_COLOR` honoured. Exit codes are SJON's —
//! 0 ok, 1 diagnostics, 2 usage, 3 internal — because a tempura document
//! IS an SJON document and the two binaries sit in the same pipelines.

const std = @import("std");
const tempura = @import("tempura");

/// The verb set of plan 10, "The `tempura` CLI". `timing` is deliberately
/// absent: it existed for the studio's timing provider, and pstudio is not
/// a host (ruling of 2026-09-20), so the payload has no consumer.
const usage = "usage: tempura <dump|build|validate|inspect|timeline|export-score|export|inline|edit|at|check-residue> [options]\n";

pub fn main(init: std.process.Init) u8 {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    stderr.print("tempura {s}: no verb is implemented yet (P108)\n{s}", .{ tempura.version, usage }) catch return 3;
    stderr.flush() catch return 3;
    return 2;
}
