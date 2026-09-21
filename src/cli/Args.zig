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

/// Every row of plan 10's table.
///
/// `timing` is the one absence, and it is deliberate: it existed for the
/// studio's timing provider, and pstudio is not a host (the ruling of
/// 2026-09-20), so its payload has no consumer. The golden case
/// `unknown-verb` asks for it by name, which is how that stays true.
///
/// Two fields are spelled with Zig's escape because the verb IS a Zig
/// keyword, and two carry an underscore where the verb carries a dash —
/// `verbName` is the one translation, and `verbFromName` its inverse, so
/// a verb never has two spellings anywhere else.
pub const Verb = enum {
    dump,
    build,
    validate,
    inspect,
    timeline,
    export_score,
    @"export",
    @"inline",
    edit,
    at,
    check_residue,
};

/// What a verb is CALLED on the command line.
pub fn verbName(verb: Verb) []const u8 {
    return switch (verb) {
        .export_score => "export-score",
        .check_residue => "check-residue",
        else => @tagName(verb),
    };
}

/// The verb `name` names, or null. `std.meta.stringToEnum` cannot do it:
/// two of the names carry a dash the enum field spells as an underscore.
pub fn verbFromName(name: []const u8) ?Verb {
    inline for (@typeInfo(Verb).@"enum".fields) |f| {
        const verb: Verb = @enumFromInt(f.value);
        if (eq(name, verbName(verb))) return verb;
    }
    return null;
}

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
    /// `--no-residue`: a file that carries nothing the format cannot say
    /// itself. `export` is this switch with a verb of its own (plan 10).
    no_residue: bool = false,
    /// `--force-residue`: write this build's own residue even over one a
    /// NEWER tempura left in the anchor (plan 04, rule 3).
    force_residue: bool = false,
    /// `--cc N`: which controller a native curve lane renders onto
    /// (plan 08). A native lane carries no `:cc` of its own, so a `.mid`
    /// build of one has to be told.
    cc: ?u7 = null,
};

/// `export-score`'s switches — plan 10's row, over plan 08's exporter.
pub const ScoreOpts = struct {
    /// `--velocity`: a sibling `<name>-vel` track per notes lane.
    velocity: bool = false,
    /// `--ease linear`: a bound curve lane's steps as ramps, not stairs.
    ease_linear: bool = false,
    /// `--eps F`: the simplification tolerance. Null keeps the
    /// exporter's own default, which is the CC quantum.
    eps: ?f32 = null,
    /// `--no-hints`: ignore every easing hint, verified or not.
    no_hints: bool = false,
    /// `--tempo-eps F`: how close two tempo segments coalesce under the
    /// 512 cap.
    tempo_eps: ?f64 = null,
    /// `--max-keys-per-track N`: the per-track share of pacer's MAX_KEYS.
    max_keys_per_track: ?u32 = null,
    /// `--section-markers`. Read by THREE verbs and stored once: the
    /// exporter ignores it (a pacer score gets `(scene …)` forms, which
    /// is the same information in pacer's own vocabulary) and plan 08's
    /// `.mid` renderer writes a `marker` per section start, so `build`
    /// and `export` read this same field.
    section_markers: bool = false,
};

/// `at`'s two spellings of one question — plan 10's row,
/// `--seconds 12.5 | --pos 17bar`. Exactly one is required.
pub const AtOpts = struct {
    seconds: ?f64 = null,
    /// A position LITERAL, `Pos.parse`'s grammar: `17bar`, `2.5q`,
    /// `1t`, `0.5b`, `12.5s`. Aliases argv.
    pos: ?[]const u8 = null,
};

/// `inline`'s row: which anchor's tiers to dump into the document.
pub const InlineOpts = struct {
    /// `--anchor id`. Null takes the document's one by-reference anchor.
    anchor: ?[]const u8 = null,
};

/// `edit`'s row: the operation, the selection and the rehearsal.
pub const EditOpts = struct {
    /// `--op '<json>'` — the spelling `edit/edit.zig`'s header documents.
    op: ?[]const u8 = null,
    /// `--select '<json>'` — a `"sel"` object, merged into the operation.
    select: ?[]const u8 = null,
    /// `--dry-run`: print the actions instead of the edited document.
    dry_run: bool = false,
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
    score: ScoreOpts = .{},
    at: AtOpts = .{},
    inl: InlineOpts = .{},
    edit: EditOpts = .{},
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

/// Which VERBS may carry a flag.
///
/// A group and not one verb, because plan 10 gives one row's switches to
/// two rows: `export` is `build --no-residue` and takes every writer
/// switch `build` does. The prose name is what a refusal prints.
const Group = enum {
    dump,
    build,
    timeline,
    score,
    /// `--section-markers` alone: plan 08 gives it to the `.mid` RENDER
    /// (a `marker` per section start) and plan 10 lists it on
    /// `export-score`, so it is one flag read by three verbs.
    markers,
    at,
    anchor,
    edit,

    fn says(self: Group) []const u8 {
        return switch (self) {
            .dump => "dump",
            .build => "build and export",
            .timeline => "timeline",
            .score => "export-score",
            .markers => "export-score, build and export",
            .at => "at",
            .anchor => "inline",
            .edit => "edit",
        };
    }

    fn covers(self: Group, verb: Verb) bool {
        return switch (self) {
            .dump => verb == .dump,
            .build => verb == .build or verb == .@"export",
            .timeline => verb == .timeline,
            .score => verb == .export_score,
            .markers => verb == .export_score or verb == .build or verb == .@"export",
            .at => verb == .at,
            .anchor => verb == .@"inline",
            .edit => verb == .edit,
        };
    }
};

/// Which verbs own a flag. A flag is never silently ignored by the verb
/// that does not have it: `build --cues` would produce a file the user
/// asked to have cues in and does not, and that is the one outcome a CLI
/// must never have.
fn owner(flag: []const u8) ?Group {
    if (eq(flag, "--spans") or eq(flag, "--patterns") or eq(flag, "--preserve-foreign") or
        eq(flag, "--preserve-history") or eq(flag, "--cues")) return .dump;
    if (eq(flag, "--kind") or eq(flag, "--format") or eq(flag, "--ppq") or eq(flag, "--round") or
        eq(flag, "--no-running-status") or eq(flag, "--loose") or eq(flag, "--in-place") or
        eq(flag, "--no-residue") or eq(flag, "--force-residue") or eq(flag, "--cc") or
        eq(flag, "--compress")) return .build;
    if (eq(flag, "--json")) return .timeline;
    if (eq(flag, "--section-markers")) return .markers;
    if (eq(flag, "--velocity") or eq(flag, "--ease") or eq(flag, "--eps") or
        eq(flag, "--no-hints") or eq(flag, "--tempo-eps") or
        eq(flag, "--max-keys-per-track")) return .score;
    if (eq(flag, "--seconds") or eq(flag, "--pos")) return .at;
    if (eq(flag, "--anchor")) return .anchor;
    if (eq(flag, "--op") or eq(flag, "--select") or eq(flag, "--dry-run")) return .edit;
    return null;
}

/// Whether a verb's product is an ARTIFACT, which `-o` may name a file
/// for. Plan 10's table gives `-o` to the rows that make a thing you
/// keep: `dump`, `build`, `timeline`, `export-score`, `export`, `inline`
/// and `edit`. `validate`'s product is its diagnostics, which go to
/// stderr by the same table's rule; `inspect`'s annotated map, `at`'s one
/// answer and `check-residue`'s verdict table are reports you read or
/// pipe — a shell redirect is the whole of what `-o` would add.
fn takesOutput(verb: Verb) bool {
    return switch (verb) {
        .dump, .build, .timeline, .export_score, .@"export", .@"inline", .edit => true,
        .validate, .inspect, .at, .check_residue => false,
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

    const verb = verbFromName(argv[1]) orelse
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
            if (!who.covers(verb)) return .{ .usage = say(
                a,
                "`{s}` is only valid for {s}",
                .{ name, who.says() },
                "flag belongs to another verb",
            ) };
        }

        // A flag that takes a value: the glued half, or the next argv.
        var value: ?[]const u8 = glued;
        const wants_value = eq(name, "-o") or eq(name, "--patterns") or
            eq(name, "--kind") or eq(name, "--format") or eq(name, "--ppq") or
            eq(name, "--cc") or eq(name, "--ease") or eq(name, "--eps") or
            eq(name, "--tempo-eps") or eq(name, "--max-keys-per-track") or
            eq(name, "--seconds") or eq(name, "--pos") or eq(name, "--anchor") or
            eq(name, "--op") or eq(name, "--select");
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
        } else if (eq(name, "--force-residue")) {
            // `export` writes no residue at all, so insisting on one is
            // a contradiction and not a stronger ask.
            if (verb == .@"export") return .{ .usage = "`--force-residue` asks for a residue and " ++
                "`export` is `build --no-residue` (plan 10); use `build --force-residue`" };
            out.build.force_residue = true;
        } else if (eq(name, "--cc")) {
            out.build.cc = std.fmt.parseInt(u7, value.?, 10) catch return .{ .usage = say(
                a,
                "`--cc` takes a controller 0..127, got `{s}`",
                .{value.?},
                "--cc takes a controller 0..127",
            ) };
        } else if (eq(name, "--velocity")) {
            out.score.velocity = true;
        } else if (eq(name, "--ease")) {
            // pacer's easing vocabulary is a lane's, not a document-wide
            // switch; `linear` is the one answer plan 10's row spells.
            if (!eq(value.?, "linear")) return .{ .usage = say(
                a,
                "`--ease` takes `linear` (the only whole-document easing plan 10 gives it), got `{s}`",
                .{value.?},
                "--ease takes linear",
            ) };
            out.score.ease_linear = true;
        } else if (eq(name, "--eps")) {
            out.score.eps = parseFloat(f32, value.?) orelse return .{ .usage = say(
                a,
                "`--eps` takes a positive tolerance, got `{s}`",
                .{value.?},
                "--eps takes a positive tolerance",
            ) };
        } else if (eq(name, "--no-hints")) {
            out.score.no_hints = true;
        } else if (eq(name, "--tempo-eps")) {
            out.score.tempo_eps = parseFloat(f64, value.?) orelse return .{ .usage = say(
                a,
                "`--tempo-eps` takes a positive tolerance in pacer bpm, got `{s}`",
                .{value.?},
                "--tempo-eps takes a positive tolerance",
            ) };
        } else if (eq(name, "--max-keys-per-track")) {
            const n = std.fmt.parseInt(u32, value.?, 10) catch 0;
            if (n == 0) return .{ .usage = say(
                a,
                "`--max-keys-per-track` takes a positive count, got `{s}`",
                .{value.?},
                "--max-keys-per-track takes a positive count",
            ) };
            out.score.max_keys_per_track = n;
        } else if (eq(name, "--section-markers")) {
            out.score.section_markers = true;
        } else if (eq(name, "--seconds")) {
            // A finite second, because the two host guards belong to the
            // playhead and a NaN on the command line is a typo.
            const secs = parseFloat(f64, value.?) orelse return .{ .usage = say(
                a,
                "`--seconds` takes a finite number of seconds, got `{s}`",
                .{value.?},
                "--seconds takes a finite number of seconds",
            ) };
            out.at.seconds = secs;
        } else if (eq(name, "--pos")) {
            out.at.pos = value.?;
        } else if (eq(name, "--anchor")) {
            out.inl.anchor = value.?;
        } else if (eq(name, "--op")) {
            out.edit.op = value.?;
        } else if (eq(name, "--select")) {
            out.edit.select = value.?;
        } else if (eq(name, "--dry-run")) {
            out.edit.dry_run = true;
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
        .{verbName(verb)},
        "missing path",
    ) };

    // The two verbs whose whole question rides on a flag. A missing one
    // is answered here rather than in the verb, so the message is a
    // usage message and the exit code is a usage code.
    switch (verb) {
        .at => {
            if (out.at.seconds == null and out.at.pos == null)
                return .{ .usage = "at asks one question: `--seconds 12.5` or `--pos 17bar`" };
            if (out.at.seconds != null and out.at.pos != null)
                return .{ .usage = "`--seconds` and `--pos` are two questions; ask one" };
        },
        .edit => {
            if (out.edit.op == null)
                return .{ .usage = "edit needs an operation: `--op '<json>'` (the spelling is in `edit/edit.zig`'s header)" };
        },
        // Plan 10: `export` IS `build --no-residue`, "for a file that
        // will only ever be played". One verb, one behaviour, decided
        // here so nothing downstream has to ask which verb it is.
        .@"export" => out.build.no_residue = true,
        else => {},
    }
    return .{ .command = out };
}

/// A finite, non-negative float, or null. `--eps`, `--tempo-eps` and
/// `--seconds` all mean a magnitude, and a NaN or a negative one is a
/// typo rather than a question.
fn parseFloat(comptime T: type, text: []const u8) ?T {
    const x = std.fmt.parseFloat(T, text) catch return null;
    if (!std.math.isFinite(x) or x < 0) return null;
    return x;
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
    // `timing` is the one row of plan 10 this CLI does not have, and it
    // is an unknown verb rather than a silent no-op.
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "timing", "x" }), "timing") != null);
}

test "parse: every verb of plan 10's table answers to its own name" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The dashed spellings are the point: `std.meta.stringToEnum` would
    // miss both, and a verb with two spellings is a verb with none.
    try t.expectEqual(@as(?Verb, .export_score), verbFromName("export-score"));
    try t.expectEqual(@as(?Verb, .check_residue), verbFromName("check-residue"));
    try t.expectEqual(@as(?Verb, null), verbFromName("export_score"));
    try t.expectEqual(@as(?Verb, null), verbFromName("timing"));

    inline for (@typeInfo(Verb).@"enum".fields) |f| {
        const verb: Verb = @enumFromInt(f.value);
        try t.expectEqual(@as(?Verb, verb), verbFromName(verbName(verb)));
    }

    // …and each of them parses a path, with the one flag it cannot do
    // without.
    try t.expectEqual(Verb.export_score, (try parseOk(a, &.{ "tempura", "export-score", "d.sjon" })).verb);
    try t.expectEqual(Verb.@"export", (try parseOk(a, &.{ "tempura", "export", "d.sjon", "--kind", "mid" })).verb);
    try t.expectEqual(Verb.@"inline", (try parseOk(a, &.{ "tempura", "inline", "d.sjon" })).verb);
    try t.expectEqual(Verb.check_residue, (try parseOk(a, &.{ "tempura", "check-residue", "s.it" })).verb);
    try t.expectEqual(Verb.at, (try parseOk(a, &.{ "tempura", "at", "d.sjon", "--seconds", "1.5" })).verb);
    try t.expectEqual(Verb.edit, (try parseOk(a, &.{ "tempura", "edit", "d.sjon", "--op", "{}" })).verb);
}

test "parse: export-score's seven switches" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = try parseOk(a, &.{
        "tempura",    "export-score",      "d.sjon", "--velocity",
        "--ease",     "linear",            "--eps",  "0.01",
        "--no-hints", "--tempo-eps",       "0.5",    "--max-keys-per-track",
        "128",        "--section-markers",
    });
    try t.expectEqual(ScoreOpts{
        .velocity = true,
        .ease_linear = true,
        .eps = 0.01,
        .no_hints = true,
        .tempo_eps = 0.5,
        .max_keys_per_track = 128,
        .section_markers = true,
    }, cmd.score);
    // `--ease` is the one whose value is closed, and `--eps` the one
    // whose value is a magnitude.
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "export-score", "d.sjon", "--ease", "in-cubic" }), "linear") != null);
    for ([_][:0]const u8{ "-1", "nan", "x", "" }) |bad| {
        _ = usageMessage(a, &.{ "tempura", "export-score", "d.sjon", "--eps", bad }) catch |e| {
            std.debug.print("expected a usage error for --eps {s}\n", .{bad});
            return e;
        };
    }
}

test "parse: at takes exactly one question, and edit needs its operation" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try t.expectEqual(@as(?f64, 12.5), (try parseOk(a, &.{ "tempura", "at", "d.sjon", "--seconds", "12.5" })).at.seconds);
    try t.expectEqualStrings("17bar", (try parseOk(a, &.{ "tempura", "at", "d.sjon", "--pos=17bar" })).at.pos.?);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "at", "d.sjon" }), "--seconds") != null);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{
        "tempura", "at", "d.sjon", "--seconds", "1", "--pos", "1bar",
    }), "two questions") != null);

    const e = try parseOk(a, &.{
        "tempura", "edit", "d.sjon", "--op", "{\"op\":\"remove\"}", "--select", "{\"lanes\":[\"a\"]}", "--dry-run",
    });
    try t.expectEqualStrings("{\"op\":\"remove\"}", e.edit.op.?);
    try t.expectEqualStrings("{\"lanes\":[\"a\"]}", e.edit.select.?);
    try t.expect(e.edit.dry_run);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "edit", "d.sjon" }), "--op") != null);
}

test "parse: export is build --no-residue, and refuses the contradiction" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The verb IS the switch (plan 10), so nothing downstream asks which
    // verb it was.
    const cmd = try parseOk(a, &.{ "tempura", "export", "d.sjon", "--kind", "it", "--loose" });
    try t.expect(cmd.build.no_residue);
    try t.expect(cmd.build.loose);
    try t.expectEqual(@as(?Kind, .it), cmd.build.kind);

    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{
        "tempura", "export", "d.sjon", "--kind", "mid", "--force-residue",
    }), "--no-residue") != null);

    // …and `build` takes both halves of plan 04's rule 3, plus plan 08's
    // controller.
    const b = try parseOk(a, &.{ "tempura", "build", "d.sjon", "--force-residue", "--cc", "74" });
    try t.expect(b.build.force_residue);
    try t.expectEqual(@as(?u7, 74), b.build.cc);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "tempura", "build", "d.sjon", "--cc", "128" }), "0..127") != null);
}

test "parse: inline takes an anchor by id, and the report verbs take no -o" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("song", (try parseOk(a, &.{ "tempura", "inline", "d.sjon", "--anchor", "song" })).inl.anchor.?);
    // `at` and `check-residue` are reports, like `validate` and
    // `inspect`: a shell redirect is the whole of what `-o` would add.
    _ = try usageMessage(a, &.{ "tempura", "at", "d.sjon", "--seconds", "1", "-o", "x" });
    _ = try usageMessage(a, &.{ "tempura", "check-residue", "s.it", "-o", "x" });
    // …and the four artifact verbs of this phase do take one.
    inline for (.{
        [_][:0]const u8{ "export-score", "d.sjon" },
        [_][:0]const u8{ "inline", "d.sjon" },
    }) |argv| {
        const cmd = try parseOk(a, &.{ "tempura", argv[0], argv[1], "-o", "out" });
        try t.expectEqualStrings("out", cmd.out.?);
    }
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
