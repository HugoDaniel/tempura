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
//! The grammar is ONE TABLE, `flags`: a row per flag names it, says which
//! verbs own it and carries the setter that reads it into the `Command`.
//! `parse` walks argv, applies the positional rules and looks every flag
//! up there, so adding a switch is adding a row and its setter.
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
    /// `--map`: write the position map beside the score — as `<score>.map`
    /// for `-o`'s file, or on stderr when the score goes to stdout.
    map: bool = false,
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

/// How a flag reads its argument into the `Command`: a switch takes
/// nothing and a valued flag takes the glued half or the next argv, which
/// `parse` has in hand before it calls. Either returns the usage message
/// that refuses the ask, or null once the field is set.
const Setter = union(enum) {
    flag: *const fn (out: *Command) ?[]const u8,
    valued: *const fn (arena: Allocator, out: *Command, value: []const u8) ?[]const u8,
};

/// One row of the grammar: what the flag is called, which verbs own it,
/// and its setter — whose shape says whether it takes a value.
///
/// A flag is never silently ignored by the verb that does not have it:
/// `build --cues` would produce a file the user asked to have cues in and
/// does not, and that is the one outcome a CLI must never have. `group`
/// is null for the one flag every verb may spell (`-o`), whose setter
/// then says which verbs produce an artifact to put there.
const Flag = struct {
    name: []const u8,
    group: ?Group,
    set: Setter,
};

/// The grammar, one row per flag, in the order `usage_text` lists them.
/// `parse` walks argv and applies the positional rules; it never spells
/// a flag's name itself.
const flags = [_]Flag{
    .{ .name = "-o", .group = null, .set = .{ .valued = setOut } },
    // dump
    .{ .name = "--spans", .group = .dump, .set = .{ .flag = setSpans } },
    .{ .name = "--patterns", .group = .dump, .set = .{ .valued = setPatterns } },
    .{ .name = "--preserve-foreign", .group = .dump, .set = .{ .flag = setPreserveForeign } },
    .{ .name = "--preserve-history", .group = .dump, .set = .{ .flag = setPreserveHistory } },
    .{ .name = "--cues", .group = .dump, .set = .{ .flag = setCues } },
    // build and export
    .{ .name = "--kind", .group = .build, .set = .{ .valued = setKind } },
    .{ .name = "--format", .group = .build, .set = .{ .valued = setFormat } },
    .{ .name = "--ppq", .group = .build, .set = .{ .valued = setPpq } },
    .{ .name = "--round", .group = .build, .set = .{ .flag = setRound } },
    .{ .name = "--no-running-status", .group = .build, .set = .{ .flag = setNoRunningStatus } },
    .{ .name = "--cc", .group = .build, .set = .{ .valued = setCc } },
    .{ .name = "--loose", .group = .build, .set = .{ .flag = setLoose } },
    .{ .name = "--in-place", .group = .build, .set = .{ .flag = setInPlace } },
    .{ .name = "--no-residue", .group = .build, .set = .{ .flag = setNoResidue } },
    .{ .name = "--force-residue", .group = .build, .set = .{ .flag = setForceResidue } },
    .{ .name = "--compress", .group = .build, .set = .{ .flag = refuseCompress } },
    .{ .name = "--section-markers", .group = .markers, .set = .{ .flag = setSectionMarkers } },
    // timeline
    .{ .name = "--json", .group = .timeline, .set = .{ .flag = setJson } },
    // export-score
    .{ .name = "--velocity", .group = .score, .set = .{ .flag = setVelocity } },
    .{ .name = "--ease", .group = .score, .set = .{ .valued = setEase } },
    .{ .name = "--eps", .group = .score, .set = .{ .valued = setEps } },
    .{ .name = "--no-hints", .group = .score, .set = .{ .flag = setNoHints } },
    .{ .name = "--tempo-eps", .group = .score, .set = .{ .valued = setTempoEps } },
    .{ .name = "--max-keys-per-track", .group = .score, .set = .{ .valued = setMaxKeysPerTrack } },
    .{ .name = "--map", .group = .score, .set = .{ .flag = setMap } },
    // at
    .{ .name = "--seconds", .group = .at, .set = .{ .valued = setSeconds } },
    .{ .name = "--pos", .group = .at, .set = .{ .valued = setPos } },
    // inline
    .{ .name = "--anchor", .group = .anchor, .set = .{ .valued = setAnchor } },
    // edit
    .{ .name = "--op", .group = .edit, .set = .{ .valued = setOp } },
    .{ .name = "--select", .group = .edit, .set = .{ .valued = setSelect } },
    .{ .name = "--dry-run", .group = .edit, .set = .{ .flag = setDryRun } },
};

/// The row `name` names, or null for a flag this CLI does not have.
fn flagNamed(name: []const u8) ?Flag {
    for (flags) |f| {
        if (eq(f.name, name)) return f;
    }
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

// ---- the setters, one per row of `flags` ----

fn setOut(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    if (!takesOutput(out.verb)) return say(
        arena,
        "{s} produces a report, not an artifact, and takes no `-o` (redirect it)",
        .{verbName(out.verb)},
        "this verb takes no -o",
    );
    out.out = value;
    return null;
}

fn setSpans(out: *Command) ?[]const u8 {
    out.dump.spans = true;
    return null;
}

fn setPatterns(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    if (!eq(value, "bin")) return say(
        arena,
        "`--patterns` takes `bin` (the only view there is), got `{s}`",
        .{value},
        "--patterns takes bin",
    );
    out.dump.patterns_bin = true;
    return null;
}

fn setPreserveForeign(out: *Command) ?[]const u8 {
    out.dump.preserve_foreign = true;
    return null;
}

fn setPreserveHistory(out: *Command) ?[]const u8 {
    out.dump.preserve_history = true;
    return null;
}

fn setCues(out: *Command) ?[]const u8 {
    out.dump.cues = true;
    return null;
}

fn setKind(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    out.build.kind = std.meta.stringToEnum(Kind, value) orelse return say(
        arena,
        "`--kind` takes `mid` or `it`, got `{s}`",
        .{value},
        "--kind takes mid or it",
    );
    return null;
}

/// Format 1 is what the writer produces unasked and format 2 is
/// `smf_format2`, refused by the core. So `0` is the only number this
/// flag has ever had a meaning for.
fn setFormat(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    if (!eq(value, "0")) return say(
        arena,
        "`--format` takes `0` (format 1 is the default, format 2 is refused), got `{s}`",
        .{value},
        "--format takes 0",
    );
    out.build.format0 = true;
    return null;
}

fn setPpq(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    const n = std.fmt.parseInt(u15, value, 10) catch return say(
        arena,
        "`--ppq` takes a division 1..32767, got `{s}`",
        .{value},
        "--ppq takes a division 1..32767",
    );
    if (n == 0) return "`--ppq` takes a division 1..32767, got `0`";
    out.build.ppq = n;
    return null;
}

fn setRound(out: *Command) ?[]const u8 {
    out.build.round = true;
    return null;
}

fn setNoRunningStatus(out: *Command) ?[]const u8 {
    out.build.running_status = false;
    return null;
}

fn setCc(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    out.build.cc = std.fmt.parseInt(u7, value, 10) catch return say(
        arena,
        "`--cc` takes a controller 0..127, got `{s}`",
        .{value},
        "--cc takes a controller 0..127",
    );
    return null;
}

fn setLoose(out: *Command) ?[]const u8 {
    out.build.loose = true;
    return null;
}

fn setInPlace(out: *Command) ?[]const u8 {
    out.build.in_place = true;
    return null;
}

fn setNoResidue(out: *Command) ?[]const u8 {
    out.build.no_residue = true;
    return null;
}

/// `export` writes no residue at all, so insisting on one is a
/// contradiction and not a stronger ask.
fn setForceResidue(out: *Command) ?[]const u8 {
    if (out.verb == .@"export") return "`--force-residue` asks for a residue and " ++
        "`export` is `build --no-residue` (plan 10); use `build --force-residue`";
    out.build.force_residue = true;
    return null;
}

/// Plan 10: refused, with the reason. tempura has no sample codec and
/// never will — bulk bytes are copied from the anchor, so a compressed
/// sample stays compressed and an uncompressed one cannot be made into
/// one.
fn refuseCompress(out: *Command) ?[]const u8 {
    _ = out;
    return "`--compress` is refused: tempura has no sample codec, " ++
        "and sample data is pass-through only (plan 06, \"The binary model\")";
}

fn setSectionMarkers(out: *Command) ?[]const u8 {
    out.score.section_markers = true;
    return null;
}

fn setJson(out: *Command) ?[]const u8 {
    out.json = true;
    return null;
}

fn setVelocity(out: *Command) ?[]const u8 {
    out.score.velocity = true;
    return null;
}

/// pacer's easing vocabulary is a lane's, not a document-wide switch;
/// `linear` is the one answer plan 10's row spells.
fn setEase(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    if (!eq(value, "linear")) return say(
        arena,
        "`--ease` takes `linear` (the only whole-document easing plan 10 gives it), got `{s}`",
        .{value},
        "--ease takes linear",
    );
    out.score.ease_linear = true;
    return null;
}

fn setEps(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    out.score.eps = parseFloat(f32, value) orelse return say(
        arena,
        "`--eps` takes a positive tolerance, got `{s}`",
        .{value},
        "--eps takes a positive tolerance",
    );
    return null;
}

fn setNoHints(out: *Command) ?[]const u8 {
    out.score.no_hints = true;
    return null;
}

fn setTempoEps(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    out.score.tempo_eps = parseFloat(f64, value) orelse return say(
        arena,
        "`--tempo-eps` takes a positive tolerance in pacer bpm, got `{s}`",
        .{value},
        "--tempo-eps takes a positive tolerance",
    );
    return null;
}

fn setMaxKeysPerTrack(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    const n = std.fmt.parseInt(u32, value, 10) catch 0;
    if (n == 0) return say(
        arena,
        "`--max-keys-per-track` takes a positive count, got `{s}`",
        .{value},
        "--max-keys-per-track takes a positive count",
    );
    out.score.max_keys_per_track = n;
    return null;
}

fn setMap(out: *Command) ?[]const u8 {
    out.score.map = true;
    return null;
}

/// A finite second, because the two host guards belong to the playhead
/// and a NaN on the command line is a typo.
fn setSeconds(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    out.at.seconds = parseFloat(f64, value) orelse return say(
        arena,
        "`--seconds` takes a finite number of seconds, got `{s}`",
        .{value},
        "--seconds takes a finite number of seconds",
    );
    return null;
}

fn setPos(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    _ = arena;
    out.at.pos = value;
    return null;
}

fn setAnchor(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    _ = arena;
    out.inl.anchor = value;
    return null;
}

fn setOp(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    _ = arena;
    out.edit.op = value;
    return null;
}

fn setSelect(arena: Allocator, out: *Command, value: []const u8) ?[]const u8 {
    _ = arena;
    out.edit.select = value;
    return null;
}

fn setDryRun(out: *Command) ?[]const u8 {
    out.edit.dry_run = true;
    return null;
}

/// The two verbs whose whole question rides on a flag. A missing one is
/// answered here rather than in the verb, so the message is a usage
/// message and the exit code is a usage code. Null when the verb has
/// what it needs.
fn missingAsk(cmd: *const Command) ?[]const u8 {
    return switch (cmd.verb) {
        .at => if (cmd.at.seconds == null and cmd.at.pos == null)
            "at asks one question: `--seconds 12.5` or `--pos 17bar`"
        else if (cmd.at.seconds != null and cmd.at.pos != null)
            "`--seconds` and `--pos` are two questions; ask one"
        else
            null,
        .edit => if (cmd.edit.op == null)
            "edit needs an operation: `--op '<json>'` " ++
                "(the spelling is in `edit/edit.zig`'s header)"
        else
            null,
        else => null,
    };
}

/// One splitter for both spellings: `--ppq=96` and `--ppq 96` reach the
/// same setter with the same value, and a flag that takes none refuses
/// an `=` rather than dropping it. The name, then the glued half.
fn splitFlag(arg: []const u8) struct { []const u8, ?[]const u8 } {
    const at = std.mem.indexOfScalar(u8, arg, '=') orelse return .{ arg, null };
    return .{ arg[0..at], arg[at + 1 ..] };
}

/// `.help` or `.version` when either is asked for ANYWHERE after the
/// program name, else null. Scanned before anything else so it answers
/// even when a required positional is missing (`tempura dump --help`
/// must print help, not "dump requires a path").
fn helpOrVersion(argv: []const [:0]const u8) ?Action {
    for (argv[@min(1, argv.len)..]) |arg| {
        if (eq(arg, "--help") or eq(arg, "-h")) return .help;
        if (eq(arg, "--version") or eq(arg, "-V")) return .version;
    }
    return null;
}

/// The refusal for a flag spelled on a verb that does not own it, or
/// null when the verb may carry it — an unknown flag and `-o` included,
/// which are answered later (by name, and by `setOut`).
fn misplaced(arena: Allocator, flag: ?Flag, name: []const u8, verb: Verb) ?[]const u8 {
    const who = (flag orelse return null).group orelse return null;
    if (who.covers(verb)) return null;
    return say(
        arena,
        "`{s}` is only valid for {s}",
        .{ name, who.says() },
        "flag belongs to another verb",
    );
}

/// The one reader of argv. Pure: the answer is a value, and every usage
/// message it formats lives on `arena` (the invocation's, never freed
/// by this module) or is a static string when the arena is exhausted.
/// Everything a `Command` borrows aliases `argv`, which outlives it.
pub fn parse(arena: Allocator, argv: []const [:0]const u8) Action {
    if (helpOrVersion(argv)) |answer| return answer;
    if (argv.len < 2) return .{ .usage = "expected a verb" };

    const verb = verbFromName(argv[1]) orelse
        return .{ .usage = say(arena, "unknown verb `{s}`", .{argv[1]}, "unknown verb") };

    var out: Command = .{ .verb = verb, .path = undefined };
    var path: ?[]const u8 = null;

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!isFlag(arg)) {
            if (path != null) return .{ .usage = say(
                arena,
                "unexpected extra argument `{s}`",
                .{arg},
                "unexpected extra argument",
            ) };
            path = arg;
            continue;
        }

        const name, const glued = splitFlag(arg);
        const flag = flagNamed(name);
        if (misplaced(arena, flag, name, verb)) |message| return .{ .usage = message };

        // A flag that takes a value: the glued half, or the next argv.
        const wants_value = if (flag) |f| f.set == .valued else false;
        var value: ?[]const u8 = glued;
        if (wants_value and value == null) {
            i += 1;
            if (i >= argv.len) return .{ .usage = say(
                arena,
                "`{s}` requires a value",
                .{name},
                "flag requires a value",
            ) };
            value = argv[i];
        }
        if (!wants_value and glued != null)
            return .{ .usage = say(arena, "`{s}` takes no value", .{name}, "flag takes no value") };

        const f = flag orelse
            return .{ .usage = say(arena, "unknown option `{s}`", .{name}, "unknown option") };
        const refused = switch (f.set) {
            .flag => |set| set(&out),
            .valued => |set| set(arena, &out, value.?),
        };
        if (refused) |message| return .{ .usage = message };
    }

    out.path = path orelse return .{ .usage = say(
        arena,
        "{s} requires a path (use `-` for stdin)",
        .{verbName(verb)},
        "missing path",
    ) };
    if (missingAsk(&out)) |message| return .{ .usage = message };
    // Plan 10: `export` IS `build --no-residue`, "for a file that will
    // only ever be played". One verb, one behaviour, decided here so
    // nothing downstream has to ask which verb it is.
    if (verb == .@"export") out.build.no_residue = true;
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
fn say(
    arena: Allocator,
    comptime fmt: []const u8,
    args: anytype,
    comptime fallback: []const u8,
) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch fallback;
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn parseOk(arena: Allocator, argv: []const [:0]const u8) !Command {
    return switch (parse(arena, argv)) {
        .command => |c| c,
        else => error.TestExpectedCommand,
    };
}

fn usageMessage(arena: Allocator, argv: []const [:0]const u8) ![]const u8 {
    return switch (parse(arena, argv)) {
        .usage => |m| m,
        else => error.TestExpectedUsage,
    };
}

test "flags: every row is a distinct `-` spelling with a setter of the right shape" {
    // The table IS the grammar, so its shape is pinned: two rows with
    // one name would make the first the only one `flagNamed` can reach,
    // and a name without its dash could never be typed as a flag.
    for (flags, 0..) |f, i| {
        try t.expect(isFlag(f.name));
        for (flags[i + 1 ..]) |g| try t.expect(!eq(f.name, g.name));
        try t.expectEqual(@as(?Flag, f), flagNamed(f.name));
    }
    try t.expectEqual(@as(?Flag, null), flagNamed("--bogus"));
    // `-o` alone belongs to no group: its setter asks `takesOutput`.
    try t.expectEqual(@as(?Group, null), flagNamed("-o").?.group);
    try t.expect(flagNamed("-o").?.set == .valued);
    try t.expect(flagNamed("--spans").?.set == .flag);
}

test "parse: each of the five verbs takes one positional path" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    inline for (.{ "dump", "build", "validate", "inspect", "timeline" }) |name| {
        const cmd = try parseOk(arena, &.{ "tempura", name, "song.x" });
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
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqual(Action.help, parse(arena, &.{ "tempura", "--help" }));
    try t.expectEqual(Action.help, parse(arena, &.{ "tempura", "dump", "--help" }));
    try t.expectEqual(Action.help, parse(arena, &.{ "tempura", "-h" }));
    try t.expectEqual(Action.version, parse(arena, &.{ "tempura", "--version" }));
    try t.expectEqual(Action.version, parse(arena, &.{ "tempura", "-V" }));
}

test "parse: no arguments, an unknown verb and a missing path are usage errors" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try usageMessage(arena, &.{"tempura"});
    try t.expect(
        std.mem.indexOf(u8, try usageMessage(arena, &.{ "tempura", "wat", "x" }), "wat") != null,
    );
    try t.expect(
        std.mem.indexOf(u8, try usageMessage(arena, &.{ "tempura", "dump" }), "dump") != null,
    );
    // `timing` is the one row of plan 10 this CLI does not have, and it
    // is an unknown verb rather than a silent no-op.
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "timing", "x" }),
            "timing",
        ) != null,
    );
}

test "parse: every verb of plan 10's table answers to its own name" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
    try t.expectEqual(
        Verb.export_score,
        (try parseOk(arena, &.{ "tempura", "export-score", "d.sjon" })).verb,
    );
    try t.expectEqual(
        Verb.@"export",
        (try parseOk(arena, &.{ "tempura", "export", "d.sjon", "--kind", "mid" })).verb,
    );
    try t.expectEqual(
        Verb.@"inline",
        (try parseOk(arena, &.{ "tempura", "inline", "d.sjon" })).verb,
    );
    try t.expectEqual(
        Verb.check_residue,
        (try parseOk(arena, &.{ "tempura", "check-residue", "s.it" })).verb,
    );
    try t.expectEqual(
        Verb.at,
        (try parseOk(arena, &.{ "tempura", "at", "d.sjon", "--seconds", "1.5" })).verb,
    );
    try t.expectEqual(
        Verb.edit,
        (try parseOk(arena, &.{ "tempura", "edit", "d.sjon", "--op", "{}" })).verb,
    );
}

test "parse: export-score's seven switches" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cmd = try parseOk(arena, &.{
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
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(
                arena,
                &.{ "tempura", "export-score", "d.sjon", "--ease", "in-cubic" },
            ),
            "linear",
        ) != null,
    );
    for ([_][:0]const u8{ "-1", "nan", "x", "" }) |bad| {
        _ = usageMessage(arena, &.{ "tempura", "export-score", "d.sjon", "--eps", bad }) catch |e| {
            std.debug.print("expected a usage error for --eps {s}\n", .{bad});
            return e;
        };
    }
}

test "parse: at takes exactly one question, and edit needs its operation" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try t.expectEqual(
        @as(?f64, 12.5),
        (try parseOk(arena, &.{ "tempura", "at", "d.sjon", "--seconds", "12.5" })).at.seconds,
    );
    try t.expectEqualStrings(
        "17bar",
        (try parseOk(arena, &.{ "tempura", "at", "d.sjon", "--pos=17bar" })).at.pos.?,
    );
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "at", "d.sjon" }),
            "--seconds",
        ) != null,
    );
    try t.expect(std.mem.indexOf(u8, try usageMessage(arena, &.{
        "tempura", "at", "d.sjon", "--seconds", "1", "--pos", "1bar",
    }), "two questions") != null);

    const e = try parseOk(arena, &.{
        "tempura",
        "edit",
        "d.sjon",
        "--op",
        "{\"op\":\"remove\"}",
        "--select",
        "{\"lanes\":[\"a\"]}",
        "--dry-run",
    });
    try t.expectEqualStrings("{\"op\":\"remove\"}", e.edit.op.?);
    try t.expectEqualStrings("{\"lanes\":[\"a\"]}", e.edit.select.?);
    try t.expect(e.edit.dry_run);
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "edit", "d.sjon" }),
            "--op",
        ) != null,
    );
}

test "parse: export is build --no-residue, and refuses the contradiction" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The verb IS the switch (plan 10), so nothing downstream asks which
    // verb it was.
    const cmd = try parseOk(arena, &.{ "tempura", "export", "d.sjon", "--kind", "it", "--loose" });
    try t.expect(cmd.build.no_residue);
    try t.expect(cmd.build.loose);
    try t.expectEqual(@as(?Kind, .it), cmd.build.kind);

    try t.expect(std.mem.indexOf(u8, try usageMessage(arena, &.{
        "tempura", "export", "d.sjon", "--kind", "mid", "--force-residue",
    }), "--no-residue") != null);

    // …and `build` takes both halves of plan 04's rule 3, plus plan 08's
    // controller.
    const b = try parseOk(
        arena,
        &.{ "tempura", "build", "d.sjon", "--force-residue", "--cc", "74" },
    );
    try t.expect(b.build.force_residue);
    try t.expectEqual(@as(?u7, 74), b.build.cc);
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "build", "d.sjon", "--cc", "128" }),
            "0..127",
        ) != null,
    );
}

test "parse: inline takes an anchor by id, and the report verbs take no -o" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings(
        "song",
        (try parseOk(arena, &.{ "tempura", "inline", "d.sjon", "--anchor", "song" })).inl.anchor.?,
    );
    // `at` and `check-residue` are reports, like `validate` and
    // `inspect`: a shell redirect is the whole of what `-o` would add.
    _ = try usageMessage(arena, &.{ "tempura", "at", "d.sjon", "--seconds", "1", "-o", "x" });
    _ = try usageMessage(arena, &.{ "tempura", "check-residue", "s.it", "-o", "x" });
    // …and the four artifact verbs of this phase do take one.
    inline for (.{
        [_][:0]const u8{ "export-score", "d.sjon" },
        [_][:0]const u8{ "inline", "d.sjon" },
    }) |argv| {
        const cmd = try parseOk(arena, &.{ "tempura", argv[0], argv[1], "-o", "out" });
        try t.expectEqualStrings("out", cmd.out.?);
    }
}

test "parse: -o takes the artifact's path, spelled either way" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings(
        "d.sjon",
        (try parseOk(arena, &.{ "tempura", "dump", "s.mid", "-o", "d.sjon" })).out.?,
    );
    try t.expectEqualStrings(
        "d.sjon",
        (try parseOk(arena, &.{ "tempura", "dump", "s.mid", "-o=d.sjon" })).out.?,
    );
    _ = try usageMessage(arena, &.{ "tempura", "dump", "s.mid", "-o" });
}

test "parse: a verb with no artifact refuses -o by the name it was typed as" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `check_residue` is the enum's spelling; the user typed the dash.
    const said = try usageMessage(arena, &.{ "tempura", "check-residue", "s.mid", "-o", "x" });
    try t.expect(std.mem.startsWith(u8, said, "check-residue produces a report"));
}

test "parse: dump's five switches, and --patterns takes bin and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cmd = try parseOk(arena, &.{
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
    try t.expect(
        (try parseOk(
            arena,
            &.{ "tempura", "dump", "s.it", "--patterns", "bin" },
        )).dump.patterns_bin,
    );
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "dump", "s.it", "--patterns=rows" }),
            "bin",
        ) != null,
    );
}

test "parse: build's writer switches" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cmd = try parseOk(arena, &.{
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
    const msg = try usageMessage(
        arena.allocator(),
        &.{ "tempura", "build", "d.sjon", "--compress" },
    );
    try t.expect(std.mem.indexOf(u8, msg, "--compress") != null);
    try t.expect(std.mem.indexOf(u8, msg, "pass-through") != null);
}

test "parse: --format takes 0 alone and --ppq a 1..32767 division" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][:0]const u8{ "1", "2", "-1", "x", "" }) |bad| {
        _ = usageMessage(arena, &.{ "tempura", "build", "d.sjon", "--format", bad }) catch |e| {
            std.debug.print("expected a usage error for --format {s}\n", .{bad});
            return e;
        };
    }
    for ([_][:0]const u8{ "0", "32768", "-1", "x", "" }) |bad| {
        _ = usageMessage(arena, &.{ "tempura", "build", "d.sjon", "--ppq", bad }) catch |e| {
            std.debug.print("expected a usage error for --ppq {s}\n", .{bad});
            return e;
        };
    }
    try t.expectEqual(
        @as(?u15, 32767),
        (try parseOk(arena, &.{ "tempura", "build", "d.sjon", "--ppq", "32767" })).build.ppq,
    );
}

test "parse: --kind takes mid or it, and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqual(
        @as(?Kind, .it),
        (try parseOk(arena, &.{ "tempura", "build", "d.sjon", "--kind=it" })).build.kind,
    );
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "build", "d.sjon", "--kind", "wav" }),
            "wav",
        ) != null,
    );
}

test "parse: a flag of another verb is a usage error that names the verb" {
    // `--cues` shapes a DUMP; on `build` it would silently do nothing,
    // which is the one outcome a CLI must never have.
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "build", "d.sjon", "--cues" }),
            "dump",
        ) != null,
    );
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "dump", "s.mid", "--loose" }),
            "build",
        ) != null,
    );
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "validate", "d.sjon", "--json" }),
            "timeline",
        ) != null,
    );
    // `validate` and `inspect` produce a report, not an artifact.
    _ = try usageMessage(arena, &.{ "tempura", "validate", "d.sjon", "-o", "x" });
    _ = try usageMessage(arena, &.{ "tempura", "inspect", "s.mid", "-o", "x" });
}

test "parse: an unknown flag and a second positional are usage errors" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expect(
        std.mem.indexOf(
            u8,
            try usageMessage(arena, &.{ "tempura", "dump", "--bogus", "s.mid" }),
            "--bogus",
        ) != null,
    );
    _ = try usageMessage(arena, &.{ "tempura", "dump", "a.mid", "b.mid" });
}

test "parse: timeline --json" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expect(
        (try parseOk(arena.allocator(), &.{ "tempura", "timeline", "d.sjon", "--json" })).json,
    );
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
