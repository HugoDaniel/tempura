//! Argument parsing — PURE. No io, no printing, no process state:
//! `parse` returns a value and the caller renders it, which is what lets
//! every invocation be tested by calling one function (pacer's
//! `src/cli/Args.zig`, same arrangement and the same reason).
//!
//! Flag style is BOTH `--flag VALUE` and `--flag=VALUE`, because plan 10
//! spells the table both ways in one row (`--patterns=bin` beside
//! `--format 0` and `--ppq N`) and a user should never have to remember
//! which of two spellings a particular flag took.
//!
//! Everything a `Command` borrows — the input path, `-o`'s path — ALIASES
//! argv, which lives on the process arena for the whole run. A caller
//! that synthesises argv (a test) must keep it alive just as long.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Phase 1 of plan 10's table. The remaining verbs (`export-score`,
/// `export`, `inline`, `edit`, `at`, `check-residue`) land at E2/E3 and
/// are deliberately absent rather than stubbed: an unknown verb with a
/// usage message says more than a verb that exists and does nothing.
///
/// `timing` is absent for a different reason and for good: it existed for
/// the studio's timing provider, and pstudio is not a host (the ruling of
/// 2026-09-20), so its payload has no consumer. The golden case
/// `unknown-verb` asks for it by name, which is how that stays true.
pub const Verb = enum { dump, build, validate, inspect, timeline };

/// Which native format a `build` writes.
pub const Kind = enum { mid, it };

/// `dump`'s switches — plan 10's row, plus it 03's three.
pub const DumpOpts = struct {
    /// `--spans`: the reader's byte offsets, as comments.
    spans: bool = false,
    /// `--patterns=bin`: packed pattern data by reference, not rows.
    patterns_bin: bool = false,
    /// `--preserve-foreign`: keep the trailing chunks another tracker
    /// wrote.
    preserve_foreign: bool = false,
    /// `--preserve-history`: keep the edit-history block.
    preserve_history: bool = false,
    /// `--cues`: one cue per played IT order.
    cues: bool = false,
};

/// `build`'s switches — plan 10's row, over plan 05's and plan 06's
/// writer options.
pub const BuildOpts = struct {
    /// `--kind mid|it`; null means "take it from `-o`'s extension".
    kind: ?Kind = null,
    /// `--format 0`: merge every track into one.
    format0: bool = false,
    /// `--ppq N`: rescale every tick onto a new division.
    ppq: ?u15 = null,
    /// `--round`: accept an inexact rescale, rounding half to even.
    round: bool = false,
    /// `--no-running-status` turns this off.
    running_status: bool = true,
    /// `--loose`: OpenMPT's itEx bounds instead of IT's strict clamps.
    loose: bool = false,
    /// `--in-place`: write back onto the anchor's own file, through a
    /// temporary and a rename (plan 06, "The binary model").
    in_place: bool = false,
    /// `--no-residue`: a file that carries nothing. Phase 1 writes no
    /// residue at all, so this is the only behaviour there is — it is
    /// accepted now so a script written today keeps working when P104
    /// lands.
    no_residue: bool = false,
};

pub const Command = struct {
    verb: Verb,
    /// The input path, or `-` for stdin. Aliases argv.
    path: []const u8,
    /// `-o`: where the artifact goes. Null is stdout. Aliases argv.
    out: ?[]const u8 = null,
    /// `timeline --json`.
    json: bool = false,
    dump: DumpOpts = .{},
    build: BuildOpts = .{},
};

pub const Action = union(enum) {
    help,
    version,
    /// A message for stderr. The caller prints it and the usage text.
    usage: []const u8,
    command: Command,
};

/// The format `-o`'s extension names, or null when it names none.
///
/// `.midi` as well as `.mid`, because both are in the wild and refusing
/// one would be a riddle rather than a rule. Case-insensitive: a
/// `SONG.MID` off a DOS-era disk is a `.mid`.
pub fn kindFromPath(path: []const u8) ?Kind {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const ext = path[dot + 1 ..];
    if (eqIgnoreCase(ext, "mid") or eqIgnoreCase(ext, "midi")) return .mid;
    if (eqIgnoreCase(ext, "it")) return .it;
    return null;
}

/// Which verb owns a flag. A flag is never silently ignored by the verb
/// that does not have it: `build --cues` would produce a file the user
/// asked to have cues in and does not, and that is the one outcome a CLI
/// must never have.
fn owner(flag: []const u8) ?Verb {
    if (eq(flag, "--spans") or eq(flag, "--patterns") or eq(flag, "--preserve-foreign") or
        eq(flag, "--preserve-history") or eq(flag, "--cues")) return .dump;
    if (eq(flag, "--kind") or eq(flag, "--format") or eq(flag, "--ppq") or eq(flag, "--round") or
        eq(flag, "--no-running-status") or eq(flag, "--loose") or eq(flag, "--in-place") or
        eq(flag, "--no-residue") or eq(flag, "--compress")) return .build;
    if (eq(flag, "--json")) return .timeline;
    return null;
}

/// Whether a verb's product is an ARTIFACT, which `-o` may name a file
/// for. Plan 10's table gives `-o` to exactly three rows: `dump`,
/// `build` and `timeline` make a thing you keep. `validate`'s product is
/// its diagnostics, which go to stderr by the same table's rule, and
/// `inspect`'s annotated map is a report you read or pipe — a shell
/// redirect is the whole of what `-o` would add, so neither takes one.
fn takesOutput(verb: Verb) bool {
    return switch (verb) {
        .dump, .build, .timeline => true,
        .validate, .inspect => false,
    };
}

pub fn parse(a: Allocator, argv: []const [:0]const u8) Action {
    // `--help` anywhere wins, scanned up front so it answers even when a
    // required positional is missing (`tempura dump --help` must print
    // help, not "dump requires a path").
    for (argv[@min(1, argv.len)..]) |arg| {
        if (eq(arg, "--help") or eq(arg, "-h")) return .help;
        if (eq(arg, "--version") or eq(arg, "-V")) return .version;
    }
    if (argv.len < 2) return .{ .usage = "expected a verb" };

    const verb = std.meta.stringToEnum(Verb, argv[1]) orelse
        return .{ .usage = say(a, "unknown verb `{s}`", .{argv[1]}, "unknown verb") };

    var out: Command = .{ .verb = verb, .path = undefined };
    var path: ?[]const u8 = null;

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        // One splitter for both spellings: `--ppq=96` and `--ppq 96`
        // reach the same branch with the same `value`, and a flag that
        // takes none refuses an `=` rather than dropping it.
        const arg = argv[i];
        const name, const glued: ?[]const u8 = if (isFlag(arg))
            if (std.mem.indexOfScalar(u8, arg, '=')) |at|
                .{ arg[0..at], arg[at + 1 ..] }
            else
                .{ arg, null }
        else
            .{ arg, null };

        if (!isFlag(arg)) {
            if (path != null) return .{ .usage = say(a, "unexpected extra argument `{s}`", .{arg}, "unexpected extra argument") };
            path = arg;
            continue;
        }

        if (owner(name)) |who| {
            if (who != verb) return .{ .usage = say(
                a,
                "`{s}` is only valid for {s}",
                .{ name, @tagName(who) },
                "flag belongs to another verb",
            ) };
        }

        // A flag that takes a value: the glued half, or the next argv.
        var value: ?[]const u8 = glued;
        const wants_value = eq(name, "-o") or eq(name, "--patterns") or
            eq(name, "--kind") or eq(name, "--format") or eq(name, "--ppq");
        if (wants_value and value == null) {
            i += 1;
            if (i >= argv.len) return .{ .usage = say(a, "`{s}` requires a value", .{name}, "flag requires a value") };
            value = argv[i];
        }
        if (!wants_value and glued != null)
            return .{ .usage = say(a, "`{s}` takes no value", .{name}, "flag takes no value") };

        if (eq(name, "-o")) {
            if (!takesOutput(verb)) return .{ .usage = say(
                a,
                "{s} produces a report, not an artifact, and takes no `-o` (redirect it)",
                .{@tagName(verb)},
                "this verb takes no -o",
            ) };
            out.out = value.?;
        } else if (eq(name, "--spans")) {
            out.dump.spans = true;
        } else if (eq(name, "--patterns")) {
            if (!eq(value.?, "bin")) return .{ .usage = say(
                a,
                "`--patterns` takes `bin` (the only view there is), got `{s}`",
                .{value.?},
                "--patterns takes bin",
            ) };
            out.dump.patterns_bin = true;
        } else if (eq(name, "--preserve-foreign")) {
            out.dump.preserve_foreign = true;
        } else if (eq(name, "--preserve-history")) {
            out.dump.preserve_history = true;
        } else if (eq(name, "--cues")) {
            out.dump.cues = true;
        } else if (eq(name, "--kind")) {
            out.build.kind = std.meta.stringToEnum(Kind, value.?) orelse return .{ .usage = say(
                a,
                "`--kind` takes `mid` or `it`, got `{s}`",
                .{value.?},
                "--kind takes mid or it",
            ) };
        } else if (eq(name, "--format")) {
            // Format 1 is what the writer produces unasked and format 2
            // is `smf_format2`, refused by the core. So `0` is the only
            // number this flag has ever had a meaning for.
            if (!eq(value.?, "0")) return .{ .usage = say(
                a,
                "`--format` takes `0` (format 1 is the default, format 2 is refused), got `{s}`",
                .{value.?},
                "--format takes 0",
            ) };
            out.build.format0 = true;
        } else if (eq(name, "--ppq")) {
            const n = std.fmt.parseInt(u15, value.?, 10) catch return .{ .usage = say(
                a,
                "`--ppq` takes a division 1..32767, got `{s}`",
                .{value.?},
                "--ppq takes a division 1..32767",
            ) };
            if (n == 0) return .{ .usage = "`--ppq` takes a division 1..32767, got `0`" };
            out.build.ppq = n;
        } else if (eq(name, "--round")) {
            out.build.round = true;
        } else if (eq(name, "--no-running-status")) {
            out.build.running_status = false;
        } else if (eq(name, "--loose")) {
            out.build.loose = true;
        } else if (eq(name, "--in-place")) {
            out.build.in_place = true;
        } else if (eq(name, "--no-residue")) {
            out.build.no_residue = true;
        } else if (eq(name, "--compress")) {
            // Plan 10: refused, with the reason. tempura has no sample
            // codec and never will — bulk bytes are copied from the
            // anchor, so a compressed sample stays compressed and an
            // uncompressed one cannot be made into one.
            return .{ .usage = "`--compress` is refused: tempura has no sample codec, " ++
                "and sample data is pass-through only (plan 06, \"The binary model\")" };
        } else if (eq(name, "--json")) {
            out.json = true;
        } else {
            return .{ .usage = say(a, "unknown option `{s}`", .{name}, "unknown option") };
        }
    }

    out.path = path orelse return .{ .usage = say(
        a,
        "{s} requires a path (use `-` for stdin)",
        .{@tagName(verb)},
        "missing path",
    ) };
    return .{ .command = out };
}

/// A bare `-` is deliberately NOT a flag: it is the stdin path and must
/// reach the positional branch.
fn isFlag(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn eqIgnoreCase(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(x, y);
}

/// Format a usage message, falling back to a static one when the arena is
/// exhausted — a failure to allocate the words must not become a
/// different KIND of failure (pacer's `say`).
fn say(a: Allocator, comptime fmt: []const u8, args: anytype, comptime fallback: []const u8) []const u8 {
    return std.fmt.allocPrint(a, fmt, args) catch fallback;
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn parseOk(a: Allocator, argv: []const [:0]const u8) !Command {
    return switch (parse(a, argv)) {
        .command => |c| c,
        else => error.TestExpectedCommand,
    };
}

fn usageMessage(a: Allocator, argv: []const [:0]const u8) ![]const u8 {
    return switch (parse(a, argv)) {
        .usage => |m| m,
        else => error.TestExpectedUsage,
    };
}

test "parse: each of the five verbs takes one positional path" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ "dump", "build", "validate", "inspect", "timeline" }) |name| {
        const cmd = try parseOk(a, &.{ "tempura", name, "song.x" });
        try t.expectEqual(@field(Verb, name), cmd.verb);
        try t.expectEqualStrings("song.x", cmd.path);
        try t.expectEqual(@as(?[]const u8, null), cmd.out);
    }
}

test "parse: a bare `-` is the stdin path, not an unknown flag" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const cmd = try parseOk(arena.allocator(), &.{ "tempura", "validate", "-" });
    try t.expectEqualStrings("-", cmd.path);
}

test "parse: --help and --version answer before a missing positional does" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(Action.help, parse(a, &.{ "tempura", "--help" }));
    try t.expectEqual(Action.help, parse(a, &.{ "tempura", "dump", "--help" }));
    try t.expectEqual(Action.help, parse(a, &.{ "tempura", "-h" }));
    try t.expectEqual(Action.version, parse(a, &.{ "tempura", "--version" }));
    try t.expectEqual(Action.version, parse(a, &.{ "tempura", "-V" }));
}

test "parse: no arguments, an unknown verb and a missing path are usage errors" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try usageMessage(a, &.{"tempura"});
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "wat", "x" }), "wat") != null);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "dump" }), "dump") != null);
    // A verb of a LATER phase is an unknown verb, not a silent no-op.
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "edit", "x" }), "edit") != null);
}

test "parse: -o takes the artifact's path, spelled either way" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("d.sjon", (try parseOk(a, &.{ "tempura", "dump", "s.mid", "-o", "d.sjon" })).out.?);
    try t.expectEqualStrings("d.sjon", (try parseOk(a, &.{ "tempura", "dump", "s.mid", "-o=d.sjon" })).out.?);
    _ = try usageMessage(a, &.{ "tempura", "dump", "s.mid", "-o" });
}

test "parse: dump's five switches, and --patterns takes bin and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = try parseOk(a, &.{
        "tempura",        "dump",   "s.it",               "--spans",
        "--patterns=bin", "--cues", "--preserve-foreign", "--preserve-history",
    });
    try t.expectEqual(DumpOpts{
        .spans = true,
        .patterns_bin = true,
        .preserve_foreign = true,
        .preserve_history = true,
        .cues = true,
    }, cmd.dump);
    // The space spelling too, because plan 10's row mixes both.
    try t.expect((try parseOk(a, &.{ "tempura", "dump", "s.it", "--patterns", "bin" })).dump.patterns_bin);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "dump", "s.it", "--patterns=rows" }), "bin") != null);
}

test "parse: build's writer switches" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = try parseOk(a, &.{
        "tempura",             "build",   "d.sjon",     "--kind",       "mid",
        "--format",            "0",       "--ppq",      "96",           "--round",
        "--no-running-status", "--loose", "--in-place", "--no-residue",
    });
    try t.expectEqual(BuildOpts{
        .kind = .mid,
        .format0 = true,
        .ppq = 96,
        .round = true,
        .running_status = false,
        .loose = true,
        .in_place = true,
        .no_residue = true,
    }, cmd.build);
}

test "parse: --compress is refused with a message naming the pass-through rule" {
    // Plan 10: "no codec; pass-through only". A flag that cannot work
    // must fail loudly rather than be ignored into a silently wrong file.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const msg = try usageMessage(arena.allocator(), &.{ "tempura", "build", "d.sjon", "--compress" });
    try t.expect(std.mem.indexOf(u8, msg, "--compress") != null);
    try t.expect(std.mem.indexOf(u8, msg, "pass-through") != null);
}

test "parse: --format takes 0 alone and --ppq a 1..32767 division" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][:0]const u8{ "1", "2", "-1", "x", "" }) |bad| {
        _ = usageMessage(a, &.{ "tempura", "build", "d.sjon", "--format", bad }) catch |e| {
            std.debug.print("expected a usage error for --format {s}\n", .{bad});
            return e;
        };
    }
    for ([_][:0]const u8{ "0", "32768", "-1", "x", "" }) |bad| {
        _ = usageMessage(a, &.{ "tempura", "build", "d.sjon", "--ppq", bad }) catch |e| {
            std.debug.print("expected a usage error for --ppq {s}\n", .{bad});
            return e;
        };
    }
    try t.expectEqual(@as(?u15, 32767), (try parseOk(a, &.{ "tempura", "build", "d.sjon", "--ppq", "32767" })).build.ppq);
}

test "parse: --kind takes mid or it, and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(?Kind, .it), (try parseOk(a, &.{ "tempura", "build", "d.sjon", "--kind=it" })).build.kind);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "build", "d.sjon", "--kind", "wav" }), "wav") != null);
}

test "parse: a flag of another verb is a usage error that names the verb" {
    // `--cues` shapes a DUMP; on `build` it would silently do nothing,
    // which is the one outcome a CLI must never have.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "build", "d.sjon", "--cues" }), "dump") != null);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "dump", "s.mid", "--loose" }), "build") != null);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "validate", "d.sjon", "--json" }), "timeline") != null);
    // `validate` and `inspect` produce a report, not an artifact.
    _ = try usageMessage(a, &.{ "tempura", "validate", "d.sjon", "-o", "x" });
    _ = try usageMessage(a, &.{ "tempura", "inspect", "s.mid", "-o", "x" });
}

test "parse: an unknown flag and a second positional are usage errors" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "dump", "--bogus", "s.mid" }), "--bogus") != null);
    _ = try usageMessage(a, &.{ "tempura", "dump", "a.mid", "b.mid" });
}

test "parse: timeline --json" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expect((try parseOk(arena.allocator(), &.{ "tempura", "timeline", "d.sjon", "--json" })).json);
}

test "kindFromPath: the extension names the format, case and .midi included" {
    try t.expectEqual(@as(?Kind, .mid), kindFromPath("song.mid"));
    try t.expectEqual(@as(?Kind, .mid), kindFromPath("a/b/SONG.MIDI"));
    try t.expectEqual(@as(?Kind, .it), kindFromPath("song.It"));
    try t.expectEqual(@as(?Kind, null), kindFromPath("song"));
    try t.expectEqual(@as(?Kind, null), kindFromPath("song.wav"));
    // A dot in a DIRECTORY name is not an extension of the file.
    try t.expectEqual(@as(?Kind, .it), kindFromPath("v1.2/song.it"));
}
