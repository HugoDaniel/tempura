//! tempura CLI entry point.
//!
//! The binary is built against the PUBLIC `tempura` module, not the
//! sources: it is a consumer like any host, so a surface it needs and
//! `src/root.zig` does not export fails the `cli` build (build.zig says
//! why).
//!
//! Thin dispatcher: build the stdio writers, read the two facts about the
//! process that a verb must not go looking for itself (`NO_COLOR`, and
//! whether stderr is a terminal), collect argv off the process arena,
//! hand everything to `Cli.run`. Every behavioural concern — argument
//! parsing, source loading, rendering, exit policy — lives in `Cli.zig`,
//! so the in-source tests drive the same code the binary runs.
//!
//! The one thing that cannot live behind that seam is the outermost
//! catch: `run` returns `!u8`, and anything it propagates would otherwise
//! reach the Zig runtime, which prints a trace and exits 1 — the same
//! code as "your document has diagnostics".
//!
//! `writerStreaming`, not `writer`, on both channels: `File.writer`
//! defaults to POSITIONAL writing, which starts at offset 0. That is
//! right for a file this process opened and wrong for one the shell
//! handed us, and `{ echo A; tempura dump s.mid; } > f` would write over
//! the `A` (SJON hit exactly this and its `main.zig` records it).

const std = @import("std");
const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

fn reportInternal(stderr: *std.Io.Writer, err: anyerror) u8 {
    // `catch {}` with no fallback: this IS the fallback. If stderr is
    // itself the failing channel there is nowhere left to report, and the
    // exit code has to carry the whole signal.
    stderr.print("tempura: internal error: {s}\n", .{@errorName(err)}) catch {};
    return Cli.Exit.internal;
}

/// The process: stdio writers and the two process facts in, `Cli.run`,
/// both channels flushed, and the exit code out — `Cli.Exit.internal`
/// for anything `run` propagates or a channel that would not flush.
/// Owns nothing past its return; argv lives in the process arena.
pub fn main(init: std.process.Init) u8 {
    // A dump of a large `.it` is megabytes of text; a big stdout buffer
    // keeps that one write rather than thousands.
    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writerStreaming(init.io, &stdout_buf);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writerStreaming(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Built BEFORE argv is collected, so even an OOM in `toSlice` has
    // somewhere to be reported.
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err|
        return reportInternal(stderr, err);

    // Colour is a property of the channel the diagnostics ride on, which
    // is stderr. A failed TTY probe degrades to "not a terminal", which
    // is the safe default (no escapes in a log file).
    const is_tty = stderr_file.isTty(init.io) catch false;
    const no_color = init.minimal.environ.containsUnempty(init.gpa, "NO_COLOR") catch false;

    var code = Cli.run(init.gpa, init.io, args, &stdout_writer.interface, stderr, .{
        .color = Diags.colorEnabled(no_color, is_tty),
    }) catch |err| reportInternal(stderr, err);

    // A failed stdout flush means the user never received the artifact
    // the exit code is describing — that outranks whatever `run` decided.
    stdout_writer.interface.flush() catch |err| {
        code = reportInternal(stderr, err);
    };
    stderr.flush() catch return Cli.Exit.internal;
    return code;
}
