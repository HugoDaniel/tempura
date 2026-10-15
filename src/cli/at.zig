//! `tempura at DOC --seconds 12.5 | --pos 17bar` — one `Playhead` answer,
//! decoded.
//!
//! Plan 10's row: "one `Playhead` answer, decoded: tick, bar, beat,
//! sections, cues, sounding notes, the tracker position under an IT
//! conductor".
//!
//! ## Two questions, one answer
//!
//! `--seconds` asks the CLOCK and `--pos` asks the GRID, and the two take
//! different routes on purpose. Seconds go through `Playhead.at`, which
//! applies the end behaviour first — a `loop` wraps in seconds, before
//! the conversion (plan 03) — so asking about second 400 of a 128-second
//! piece answers where the loop actually is. A position literal goes
//! through the document's own `TimeMap.tickFromLiteral`, the same
//! function that resolved every `:at` in the document, and then through
//! `Playhead.atTick`: `--pos 17bar` means bar 17 of this document and
//! never bar 17 of a wrapped replay of it.
//!
//! ## The shape
//!
//! `timeline`'s: SJON forms, one fact per line, because the two verbs are
//! read in the same terminal and piped into the same `grep`. The
//! playhead's own answer first, then the sections in force, the two
//! surrounding cues, the tracker position when an IT anchor conducts, and
//! one line per sounding note across every lane in document order.
//!
//! Seconds are printed as DECIMALS here and not as the corpus's bit
//! patterns: this verb's reader is a person, and the corpus is where the
//! last bit of an f64 is the claim.
//!
//! ## Which channel
//!
//! The answer rides stdout, like `inspect`'s map and `check-residue`'s
//! table: it is a report you read or pipe, not an artifact you keep, so
//! it takes no `-o`. The answer is produced even for a document with
//! diagnostics — a playhead over a defective document is how you see
//! what the defect did to the time — and the exit code carries the
//! verdict.

const std = @import("std");
const tempura = @import("tempura");

const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const Writer = std.Io.Writer;
const Playhead = tempura.time.Playhead;
const Pos = tempura.time.Pos;

/// The verb: load and derive the document, answer the one position
/// `--seconds` or `--pos` asks for on stdout, and every load and
/// derivation diagnostic on stderr. Exits with the document's verdict,
/// or `Exit.usage` when the question itself was refused. Every value it
/// builds is freed before it returns.
pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    var loaded = switch (try ctx.loadDoc()) {
        .failed => |code| return code,
        .ok => |l| l,
    };
    defer loaded.deinit();

    var derived = try tempura.time.derive.derive(ctx.gpa, &loaded.result.doc);
    defer derived.deinit();

    var all: std.ArrayList(tempura.Diag.Diagnostic) = .empty;
    defer all.deinit(ctx.arena);
    try all.appendSlice(ctx.arena, loaded.result.diags.items());
    try all.appendSlice(ctx.arena, derived.diags.items());

    // The question, answered — or refused, which is an answer about the
    // QUESTION and therefore a usage error rather than a verdict on the
    // document.
    var pos = switch (try ask(ctx, &derived)) {
        .ok => |p| p,
        .failed => |code| {
            try Diags.render(ctx.err, ctx.cmd.path, loaded.space(), all.items, ctx.style);
            return code;
        },
    };
    defer pos.deinit(ctx.gpa);

    var art: Writer.Allocating = .init(ctx.gpa);
    defer art.deinit();
    try render(ctx.gpa, &art.writer, &derived, pos);

    try ctx.out.writeAll(art.written());
    try Diags.render(ctx.err, ctx.cmd.path, loaded.space(), all.items, ctx.style);
    return Diags.exitCode(all.items);
}

const Answer = union(enum) { ok: Playhead.Position, failed: u8 };

/// `--seconds` through the clock, `--pos` through the grid. `Args` has
/// already refused an invocation that asks neither or both.
fn ask(ctx: *const Cli.Ctx, derived: *const tempura.time.derive.Derived) Cli.Error!Answer {
    if (ctx.cmd.at.seconds) |secs| {
        return .{
            .ok = Playhead.at(ctx.gpa, derived, secs) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                // Both guards are about the NUMBER the user typed, so both
                // are usage errors: the document is fine and the question
                // is not answerable.
                error.TickOverflow => return try refuse(
                    ctx,
                    "--seconds {d} is past the grid's ceiling",
                    .{secs},
                ),
                error.NonFiniteTime => return try refuse(
                    ctx,
                    "--seconds {d} is not a time",
                    .{secs},
                ),
            },
        };
    }

    const text = ctx.cmd.at.pos.?;
    const lit = switch (Pos.parse(text)) {
        .ok => |l| l,
        .err => |code| return try refuse(
            ctx,
            "`--pos {s}` is not a position ({t}); a position carries a unit — 17bar, 2.5q, 1t, " ++
                "0.5b, 12.5s",
            .{ text, code },
        ),
    };
    const resolved = derived.map.tickFromLiteral(lit) catch
        return try refuse(ctx, "`--pos {s}` is not a time", .{text});
    const tick = switch (resolved) {
        .tick => |x| x,
        // The floored tick stands, and the person asking is told what the
        // frame they named could not land on.
        .inexact => |x| blk: {
            try ctx.err.print(
                "tempura: --pos {s} lands between ticks at this document's frame rate; " ++
                    "answering the tick beneath it\n",
                .{text},
            );
            break :blk x;
        },
        .err => |code| return try refuse(
            ctx,
            "`--pos {s}` does not resolve ({t})",
            .{ text, code },
        ),
    };
    return .{ .ok = try Playhead.atTick(ctx.gpa, derived, tick) };
}

fn refuse(ctx: *const Cli.Ctx, comptime fmt: []const u8, args: anytype) Cli.Error!Answer {
    try ctx.err.print("tempura: " ++ fmt ++ "\n", args);
    return .{ .failed = Cli.Exit.usage };
}

/// The answer, as forms.
fn render(
    gpa: std.mem.Allocator,
    w: *Writer,
    derived: *const tempura.time.derive.Derived,
    pos: Playhead.Position,
) Cli.Error!void {
    try w.print("(at :tick {d} :bar {d} :beat {d} :sub {d} :seconds {d} :into-bar {d})\n", .{
        pos.tick,
        pos.bar,
        pos.beat,
        pos.sub_ticks,
        Playhead.secondsOf(derived, pos.tick),
        pos.seconds_into_bar,
    });

    // Sections OVERLAP (plan 02), so this is a set and not one answer;
    // the ids index the derivation's own list, in document order.
    for (pos.section_ids) |id| {
        const s = derived.sections[id];
        try w.print("(section :name {s} :at {d} :dur {d})\n", .{ s.name, s.at, s.dur });
    }
    try cue(w, derived, "prev-cue", pos.prev_cue);
    try cue(w, derived, "next-cue", pos.next_cue);

    // The tracker position, for a document an IT anchor conducts (plan
    // 03: the studio shows it with no renderer readback).
    if (pos.order_row) |orow| try w.print(
        "(tracker :order {d} :row {d} :tick-in-row {d})\n",
        .{ orow.order, orow.row, orow.tick_in_row },
    );

    // What is SOUNDING, lane by lane in document order — the one part of
    // this answer that is about content rather than about time.
    for (derived.lanes) |lane| {
        const notes = try Playhead.sounding(gpa, derived, lane.name, pos.tick);
        defer gpa.free(notes);
        for (notes) |n| try w.print(
            "(sounding :lane {s} :at {d} :dur {d} :key {d} :vel {d})\n",
            .{ lane.name, n.tick, n.dur, n.key, n.vel },
        );
    }
}

fn cue(
    w: *Writer,
    derived: *const tempura.time.derive.Derived,
    head: []const u8,
    index: ?u32,
) Cli.Error!void {
    const i = index orelse {
        try w.print("({s} none)\n", .{head});
        return;
    };
    const c = derived.cues[i];
    // A cue's name is a string the author wrote, so it is spelled as
    // one; the escape is the echo's, for the echo's reason.
    try w.print("({s} :name \"", .{head});
    for (c.name) |ch| {
        if (ch == '"' or ch == '\\') try w.writeByte('\\');
        try w.writeByte(ch);
    }
    try w.print("\" :at {d})\n", .{c.at});
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "at --seconds: the tick, the bar and the beat of one clock reading" {
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-three-conductors-native/doc.sjon");
    defer t.allocator.free(path);

    // 125 qpm for the first quarter: 0.48 s is exactly 1q = 46 126 080
    // ticks, which is beat 1 of bar 0 under [4 4].
    var c = try Cli.invoke(&.{ "tempura", "at", path, "--seconds", "0.48" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());
    try t.expect(
        std.mem.startsWith(u8, c.out.written(), "(at :tick 46126080 :bar 0 :beat 1 :sub 0"),
    );
}

test "at --pos: a position literal is resolved by the document's own map" {
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-three-conductors-native/doc.sjon");
    defer t.allocator.free(path);

    var c = try Cli.invoke(&.{ "tempura", "at", path, "--pos", "1q" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expect(
        std.mem.startsWith(u8, c.out.written(), "(at :tick 46126080 :bar 0 :beat 1 :sub 0"),
    );

    // …and the two spellings of one instant agree.
    var secs = try Cli.invoke(&.{ "tempura", "at", path, "--seconds", "0.48" });
    defer secs.deinit();
    try t.expectEqualStrings(secs.out.written(), c.out.written());
}

test "at: the sections in force, the two cues and the sounding notes" {
    const path = try Cli.repoPath(t.allocator, "corpus/playhead-sections-cues/doc.sjon");
    defer t.allocator.free(path);

    var c = try Cli.invoke(&.{ "tempura", "at", path, "--pos", "0bar" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    const text = c.out.written();
    try t.expect(std.mem.indexOf(u8, text, "(section :name ") != null);
    try t.expect(std.mem.indexOf(u8, text, "(prev-cue ") != null);
    try t.expect(std.mem.indexOf(u8, text, "(next-cue ") != null);
}

test "at: an IT conductor adds the tracker position, and a native document does not" {
    const a = t.allocator;
    const it_path = try Cli.repoPath(a, "corpus/tempo-three-conductors-it/doc.sjon");
    defer a.free(it_path);
    const native_path = try Cli.repoPath(a, "corpus/tempo-three-conductors-native/doc.sjon");
    defer a.free(native_path);

    var it = try Cli.invoke(&.{ "tempura", "at", it_path, "--pos", "1q" });
    defer it.deinit();
    try t.expectEqual(Cli.Exit.ok, it.code);
    // Speed 6 and 24 ticks to the quarter make a row a 16th, so 1q is
    // row 4 of order 0.
    try t.expect(
        std.mem.indexOf(u8, it.out.written(), "(tracker :order 0 :row 4 :tick-in-row 0)") != null,
    );

    var native = try Cli.invoke(&.{ "tempura", "at", native_path, "--pos", "1q" });
    defer native.deinit();
    try t.expect(std.mem.indexOf(u8, native.out.written(), "(tracker ") == null);
}

test "at: a position that is not one is a usage error, and stdout stays empty" {
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-three-conductors-native/doc.sjon");
    defer t.allocator.free(path);

    for ([_][:0]const u8{ "17", "bar", "-1bar", "1x" }) |bad| {
        var c = try Cli.invoke(&.{ "tempura", "at", path, "--pos", bad });
        defer c.deinit();
        try t.expectEqual(Cli.Exit.usage, c.code);
        try t.expectEqualStrings("", c.out.written());
        try t.expect(std.mem.indexOf(u8, c.err.written(), bad) != null);
    }
}
