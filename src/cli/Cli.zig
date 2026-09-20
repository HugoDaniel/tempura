//! Verb dispatch, the input path every verb shares, and the channel
//! policy of plan 10.
//!
//! `run` is the TEST SEAM: it takes its two writers and its argv as
//! parameters, so every end-to-end test drives exactly the code the
//! binary runs, in process, under `std.testing.allocator` — which is also
//! the leak gate.
//!
//! ## Channels (plan 10, "The `tempura` CLI")
//!
//! > Everything honours `NO_COLOR`, writes diagnostics to stderr and
//! > artifacts to stdout or `-o`.
//!
//! So: `dump`, `build` and `timeline` put their ARTIFACT on stdout (or in
//! `-o`'s file) and every diagnostic on stderr.
//!
//! The two verbs with no artifact split: `validate`'s product IS
//! diagnostics, so the whole report goes to stderr and stdout stays empty
//! — `tempura validate d.sjon && tempura dump s.mid` is then a pipeline
//! and not a mess. `inspect`'s annotated map is not a diagnostic; it is
//! the thing you pipe into `grep`, so it rides stdout while the reader's
//! own diagnostics ride stderr beside it. Neither takes `-o`: plan 10's
//! table gives it to three rows, and a shell redirect is the whole of
//! what a fourth would add.
//!
//! Who still emits when the input is defective is a per-verb judgement,
//! and each one is stated where it is made: `dump` and `inspect` are how
//! you find out what is wrong with a file, so they always produce their
//! text; `build` refuses to write bytes a defective document would have
//! made wrong.
//!
//! ## The public module is the whole surface
//!
//! Every tempura name here arrives through `@import("tempura")`. The CLI
//! is a CONSUMER like any host (`build.zig` says so in as many words), so
//! a surface a verb needs and `src/root.zig` does not export fails the
//! `cli` build rather than quietly reaching around it.

const std = @import("std");
const tempura = @import("tempura");

const Args = @import("Args.zig");
const Diags = @import("Diags.zig");
const build_verb = @import("build.zig");
const dump_verb = @import("dump.zig");
const inspect_verb = @import("inspect.zig");
const timeline_verb = @import("timeline.zig");
const validate_verb = @import("validate.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

/// Exit codes — SJON's table, not a private one. A tempura document IS an
/// SJON document and the two binaries sit in the same pipelines, so
/// `sjon check x.sjon && tempura validate x.sjon` must not mean two
/// different things by the same number.
pub const Exit = struct {
    /// Ran, and nothing of severity `err` was found.
    pub const ok: u8 = 0;
    /// The document or the file has diagnostics of severity `err`.
    pub const errors: u8 = 1;
    /// Bad invocation: unknown verb or flag, a refused option, or an
    /// input that could not be read. A file you named that is not there
    /// is a user error like any other.
    pub const usage: u8 = 2;
    /// Anything `run` propagates — OOM, a dead stdout. `main` collapses
    /// the error set here rather than letting the Zig runtime print a
    /// trace and exit 1, which would be indistinguishable from "your
    /// document has errors".
    pub const internal: u8 = 3;
};

/// Everything `run` propagates to `main`, which collapses all of it to
/// `Exit.internal`. The narrowness IS the contract: a verb reports the
/// USER's problem as a message and an exit code, never as a Zig error.
pub const Error = Allocator.Error || Writer.Error;

/// Input cap. A `.it` with a few minutes of 16-bit stereo samples is
/// tens of megabytes and entirely ordinary; the cap exists so a named
/// device or a runaway pipe is refused with a message rather than eating
/// the machine.
pub const MAX_INPUT_BYTES: usize = 256 * 1024 * 1024;

/// What `main` learned about the process that a verb must not go and ask
/// for itself. Passed in so every rule over it is testable.
pub const Env = struct {
    /// Already resolved through `Diags.colorEnabled`.
    color: bool = false,
};

pub const usage_text =
    \\tempura — the timeline as a value: SJON documents, `.mid` and `.it`.
    \\
    \\Usage:
    \\  tempura dump FILE [-o DOC]      A .mid or .it as a timeline document.
    \\  tempura build DOC [-o FILE]     A document as a .mid or .it.
    \\  tempura validate DOC            Schema and host checks, with spans.
    \\  tempura inspect FILE            The annotated byte map of a .mid or .it.
    \\  tempura timeline DOC [-o MAP]   The TimeMap as data.
    \\
    \\`-` reads stdin. Artifacts go to stdout unless `-o` names a file;
    \\diagnostics always go to stderr.
    \\
    \\Options for dump:
    \\  --spans                 Annotate the dump with the reader's byte offsets.
    \\  --patterns=bin          Keep .it pattern data by reference, not as rows.
    \\  --preserve-foreign      Keep the trailing chunks another tracker wrote.
    \\  --preserve-history      Keep the .it edit-history block.
    \\  --cues                  One cue per played order (.it).
    \\
    \\Options for build:
    \\  --kind mid|it           The format to write; the default comes from -o.
    \\  --format 0              Merge every track into one (.mid).
    \\  --ppq N                 Rescale onto an N-pulse division (.mid).
    \\  --round                 Accept an inexact rescale, rounding half to even.
    \\  --no-running-status     Write every status byte (.mid).
    \\  --loose                 OpenMPT's itEx bounds instead of IT's clamps (.it).
    \\  --in-place              Write back onto the anchor's own file.
    \\  --no-residue            Write a file that carries no timeline.
    \\
    \\Options for timeline:
    \\  --json                  The same data as JSON.
    \\
    \\  -o PATH                 Where the artifact goes (dump, build, timeline).
    \\  -h, --help              Show this help.
    \\  -V, --version           Show the version.
    \\
    \\Exit codes:
    \\  0  No diagnostics of severity `error`.
    \\  1  The document or the file has errors.
    \\  2  Usage error (bad flags, a refused option, or an unreadable input).
    \\  3  Internal error (out of memory, or a dead output stream).
    \\
;

/// Everything a verb is given, and nothing it is not: no process state,
/// no environment lookups, no second allocator policy. `a` is an arena
/// that lives exactly as long as the invocation.
pub const Ctx = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    cmd: Args.Command,
    out: *Writer,
    err: *Writer,
    style: Diags.Style,

    /// Put an artifact where the invocation asked for it.
    ///
    /// Returns false when `-o`'s file could not be written, having said
    /// so on stderr; the caller then returns `Exit.usage`, because a path
    /// that cannot be written is the user's problem and not the
    /// document's.
    pub fn emit(self: *const Ctx, bytes: []const u8) Error!bool {
        const path = self.cmd.out orelse {
            try self.out.writeAll(bytes);
            return true;
        };
        return self.writeFile(path, bytes);
    }

    pub fn writeFile(self: *const Ctx, path: []const u8, bytes: []const u8) Error!bool {
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch |e| {
            try self.err.print("tempura: {s}: could not write ({s})\n", .{ path, @errorName(e) });
            return false;
        };
        return true;
    }

    /// The report half: every diagnostic, then nothing. No summary line —
    /// a verb whose product is an artifact should not editorialise about
    /// it on the other channel.
    pub fn report(self: *const Ctx, index: *const Diags.LineIndex, diags: []const tempura.Diag.Diagnostic) Error!void {
        try Diags.render(self.err, self.cmd.path, index, diags, self.style);
    }

    /// The input's directory, for an anchor's `:file` — plan 02 resolves
    /// one "relative to the document". `.` when the path has none, and
    /// for stdin, where there is no document directory to speak of.
    pub fn inputDir(self: *const Ctx) []const u8 {
        if (Diags.isStdin(self.cmd.path)) return ".";
        return std.fs.path.dirname(self.cmd.path) orelse ".";
    }
};

pub const LoadError = error{ ReadFailed, TooLarge, OutOfMemory };

/// Read an input whole, NUL-terminated.
///
/// The sentinel costs one byte and buys two things: `fromSource` takes a
/// `[:0]const u8`, and a binary reader can still take the slice without
/// it. `-` is stdin, sniffed nowhere — a path is a name here, not a type
/// tag; the VERB decides what the bytes are.
pub fn load(a: Allocator, io: Io, path: []const u8) LoadError![:0]u8 {
    if (Diags.isStdin(path)) {
        var file = Io.File.stdin();
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);
        return reader.interface.allocRemainingAlignedSentinel(
            a,
            .limited(MAX_INPUT_BYTES),
            .of(u8),
            0,
        ) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => error.TooLarge,
            else => error.ReadFailed,
        };
    }
    return Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        a,
        .limited(MAX_INPUT_BYTES),
        .of(u8),
        0,
    ) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong, error.FileTooBig => error.TooLarge,
        else => error.ReadFailed,
    };
}

/// Which native format these bytes are.
///
/// The MAGIC first, the extension only as a tie-break: a `.mid` is
/// `MThd` (or a `RIFF`/`RMID` wrapper around one) and a `.it` is `IMPM`,
/// and those four bytes are a far better answer than a file name a user
/// typed. The extension still gets a turn, because an empty or truncated
/// file has no magic and "I could not tell what this is" is a worse
/// message than the reader's own diagnostics about the bytes.
pub fn sniff(bytes: []const u8, path: []const u8) ?Args.Kind {
    if (std.mem.startsWith(u8, bytes, "MThd")) return .mid;
    if (std.mem.startsWith(u8, bytes, "IMPM")) return .it;
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "RIFF") and
        std.mem.eql(u8, bytes[8..12], "RMID")) return .mid;
    return Args.kindFromPath(path);
}

pub fn run(
    gpa: Allocator,
    io: Io,
    argv: []const [:0]const u8,
    out: *Writer,
    err: *Writer,
    env: Env,
) Error!u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    switch (Args.parse(a, argv)) {
        .help => {
            try err.writeAll(usage_text);
            return Exit.ok;
        },
        .version => {
            try err.print("tempura {s}\n", .{tempura.version});
            return Exit.ok;
        },
        .usage => |message| {
            try err.print("tempura: {s}\n\n", .{message});
            try err.writeAll(usage_text);
            return Exit.usage;
        },
        .command => |cmd| {
            const ctx: Ctx = .{
                .gpa = gpa,
                .a = a,
                .io = io,
                .cmd = cmd,
                .out = out,
                .err = err,
                .style = .{ .enabled = env.color },
            };
            return switch (cmd.verb) {
                .dump => dump_verb.run(&ctx),
                .build => build_verb.run(&ctx),
                .validate => validate_verb.run(&ctx),
                .inspect => inspect_verb.run(&ctx),
                .timeline => timeline_verb.run(&ctx),
            };
        },
    }
}

/// The one place a verb turns a failed read into the user's answer.
pub fn reportLoadFailure(ctx: *const Ctx, e: LoadError) Error!u8 {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    try ctx.err.print("tempura: {s}: {s}\n", .{ Diags.label(ctx.cmd.path), switch (e) {
        error.TooLarge => "input exceeds the 256 MiB cap",
        error.ReadFailed => "could not read",
        error.OutOfMemory => unreachable,
    } });
    return Exit.usage;
}

const t = std.testing;

test {
    // `src/root.zig`'s discovery block cannot reach these: they
    // `@import("tempura")`, which inside the core test binary would
    // resolve to a second, distinct instance of the module. So `Cli.zig`
    // plays root.zig's role one level down, and `build.zig` roots the CLI
    // test artifact here.
    _ = Args;
    _ = Diags;
    _ = build_verb;
    _ = dump_verb;
    _ = inspect_verb;
    _ = timeline_verb;
    _ = validate_verb;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub const Captured = struct {
    code: u8,
    out: Writer.Allocating,
    err: Writer.Allocating,
    pub fn deinit(self: *Captured) void {
        self.out.deinit();
        self.err.deinit();
    }
};

/// Drive `run` in process, under `std.testing.allocator` so a leak in any
/// verb fails the test rather than merely being reported.
pub fn invoke(argv: []const [:0]const u8) !Captured {
    return invokeEnv(argv, .{});
}

pub fn invokeEnv(argv: []const [:0]const u8, env: Env) !Captured {
    var out: Writer.Allocating = .init(t.allocator);
    errdefer out.deinit();
    var err: Writer.Allocating = .init(t.allocator);
    errdefer err.deinit();
    const code = try run(t.allocator, std.testing.io, argv, &out.writer, &err.writer, env);
    return .{ .code = code, .out = out, .err = err };
}

/// An absolute path to a repo file. Handed in by `build.zig` rather than
/// resolved from the cwd, which depends on where `zig build` was invoked.
pub fn repoPath(a: Allocator, rel: []const u8) ![:0]u8 {
    const root = @import("build_options").repo_root;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, rel }, 0);
}

test "--help exits ok on stderr; stdout stays free for artifacts" {
    var c = try invoke(&.{ "tempura", "--help" });
    defer c.deinit();
    try t.expectEqual(Exit.ok, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "tempura dump") != null);
}

test "--version prints the module's version and nothing else" {
    var c = try invoke(&.{ "tempura", "--version" });
    defer c.deinit();
    try t.expectEqual(Exit.ok, c.code);
    try t.expectEqualStrings("tempura " ++ tempura.version ++ "\n", c.err.written());
}

test "a usage error writes nothing to stdout, so a piped consumer sees no half artifact" {
    var c = try invoke(&.{ "tempura", "dump", "--bogus", "song.mid" });
    defer c.deinit();
    try t.expectEqual(Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "--bogus") != null);
}

test "sniff: the magic decides, and the extension only breaks a tie" {
    try t.expectEqual(@as(?Args.Kind, .mid), sniff("MThd\x00\x00\x00\x06", "x.it"));
    try t.expectEqual(@as(?Args.Kind, .it), sniff("IMPM", "x.mid"));
    try t.expectEqual(@as(?Args.Kind, .mid), sniff("RIFF\x00\x00\x00\x00RMID", "x"));
    // No magic: the name gets its turn, and then there is no answer.
    try t.expectEqual(@as(?Args.Kind, .it), sniff("", "song.it"));
    try t.expectEqual(@as(?Args.Kind, null), sniff("", "-"));
}

test "an unreadable input is a usage error, not an internal one, for every verb" {
    inline for (.{ "dump", "build", "validate", "inspect", "timeline" }) |verb| {
        var c = try invoke(&.{ "tempura", verb, "no/such/input.sjon" });
        defer c.deinit();
        try t.expectEqual(Exit.usage, c.code);
        try t.expectEqualStrings("", c.out.written());
        try t.expect(std.mem.indexOf(u8, c.err.written(), "could not read") != null);
    }
}
