//! `zig build landing` — the fixtures the pacer landing proof reads.
//!
//! Plan 08's determinism seam runs through TWO implementations of one
//! expression: tempura's `export/pos.zig` reproduces pacer's
//! `mul + floor` in Zig to CHOOSE a decimal, and `pacer.wasm` performs
//! it for real to READ that decimal back. Nothing in tempura's own test
//! suite can catch the two drifting apart, so this tool writes what the
//! node suite needs to compare them:
//!
//!   - `landing.json` — `{ pos, tick, n, d }` per position: the text
//!     tempura prints and the pacer tick it claims that text lands on.
//!     `node --test` compiles a probe score per batch and asserts the
//!     trigger gate fires exactly at `tick`.
//!   - `scores/*.pacer` — every golden score `exportScore` produces, so
//!     the node suite also proves each one LOADS clean through the real
//!     driver (plan 08: "Every emitted score is compiled through the
//!     real `pacer.wasm` in `node --test` … with zero error
//!     diagnostics").
//!
//! The sample. Two bars of `[4 4]` and of `[7 8]` hold 1 441 440 pacer
//! ticks EACH (a bar is `PPC = 720 720` ticks whatever the meter), and a
//! fixture naming every one of them is some forty megabytes of JSON and
//! minutes of wasm per `verify`. The exhaustive sweep therefore runs
//! where it is cheap and exact — `export/pos.zig`'s own unit test walks
//! every tick of both bars natively — and the fixture carries a dense
//! deterministic SAMPLE of the same two bars: every tick of the first
//! and last `window` of each bar pair, a prime-stride sweep across the
//! rest (so the residues modulo `tpb` keep moving), and the named cases
//! plan 08 spells out. `zig build landing -- --full` writes the
//! exhaustive fixture for anyone who wants the whole forty megabytes.

const std = @import("std");
const exporter = @import("tempura_export").exporter;

const pos = exporter.pos;
const support = exporter.test_support;

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// pacer ticks per bar (`sjon.Pattern.PPC`).
const PPC: i64 = 720_720;

/// Two bars, the sweep plan 08 phase 1 names.
const sweep_ticks: i64 = 2 * PPC;

/// How many consecutive ticks are taken at each end of a sweep.
const window: i64 = 2048;

/// The stride across the middle. Prime, and coprime to every
/// `tpb = PPC / n`, so consecutive samples land on different residues.
const stride: i64 = 1009;

/// The meters swept, `[n d]`.
const meters = [_][2]u8{ .{ 4, 4 }, .{ 7, 8 } };

/// One fixture row.
const Entry = struct { tick: i64, n: u8, d: u8, label: []const u8 = "" };

/// The cases plan 08 names by hand, so they are pinned whatever the
/// sampling does. Every one is a pacer tick under `[4 4]`.
const named = [_]Entry{
    .{ .tick = 0, .n = 4, .d = 4, .label = "bar line 0" },
    .{ .tick = PPC, .n = 4, .d = 4, .label = "bar line 1" },
    .{ .tick = 2 * PPC, .n = 4, .d = 4, .label = "bar line 2" },
    .{ .tick = 45_045, .n = 4, .d = 4, .label = "16th" },
    .{ .tick = 22_522, .n = 4, .d = 4, .label = "32nd, rounded onto the lattice" },
    .{ .tick = 60_060, .n = 4, .d = 4, .label = "eighth triplet" },
    .{ .tick = 120_120, .n = 4, .d = 4, .label = "eighth triplet, second" },
    .{ .tick = 252_252, .n = 4, .d = 4, .label = "quintuplet 1.4b" },
    .{ .tick = 36_036, .n = 4, .d = 4, .label = "quintuplet 0.2b" },
    .{ .tick = 720_719, .n = 4, .d = 4, .label = "one tick under a bar line" },
    .{ .tick = 51_480, .n = 7, .d = 8, .label = "[7 8] half beat" },
    .{ .tick = 34_320, .n = 7, .d = 8, .label = "[7 8] third of a beat" },
};

/// One golden score: which fixture builds it, with which options, and
/// where the node suite reads it back.
const Case = struct {
    file: []const u8,
    build: *const fn (Allocator) anyerror!support.Fixture,
    opts: exporter.Options,
};

/// The three conductors of plan 03, the `--velocity` variant, and the
/// 512-segment fallback — the five shapes `exportScore` emits.
const cases = [_]Case{
    .{ .file = "native.pacer", .build = support.native, .opts = .{ .source_name = "native.sjon" } },
    .{
        .file = "native-velocity.pacer",
        .build = support.native,
        .opts = .{ .source_name = "native.sjon", .velocity = true },
    },
    .{ .file = "smf-conducted.pacer", .build = support.smfConducted, .opts = .{ .source_name = "smf.sjon" } },
    .{ .file = "it-conducted.pacer", .build = support.itConducted, .opts = .{ .source_name = "it.sjon" } },
    // The one shape whose positions are SECONDS. It has to be here
    // rather than only in a Zig test: seconds ride pacer's degenerate
    // `ticks_per_second` path, and nothing on this side can prove the
    // two implementations of that expression agree.
    .{ .file = "slide-seconds.pacer", .build = support.slideConducted, .opts = .{ .source_name = "slide.sjon" } },
};

/// One rendered artifact, on its way to disk or to a comparison.
const Artifact = struct { path: []const u8, data: []const u8 };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    const out = &stderr_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try out.print("usage: gen-landing <fixtures-dir> [--full] [--check]\n", .{});
        return 2;
    }
    const dir_path = args[1];
    var full = false;
    var check = false;
    for (args[2..]) |a| {
        if (std.mem.eql(u8, a, "--full")) full = true;
        if (std.mem.eql(u8, a, "--check")) check = true;
    }

    // Render everything FIRST, then either write it or compare it. The
    // gate's leg must not touch the committed fixtures — a `verify` that
    // rewrote what it is about to read would pass on anything
    // (`tools/timeline_docs.sh`'s two legs over one render, the same
    // shape).
    var artifacts: std.ArrayList(Artifact) = .empty;
    defer artifacts.deinit(gpa);

    var scores: std.ArrayList(Score) = .empty;
    defer scores.deinit(gpa);
    const scores_dir = try std.fs.path.join(arena, &.{ dir_path, "scores" });
    for (cases) |c| {
        var fx = try c.build(gpa);
        defer fx.deinit();
        var res = try exporter.exportScore(gpa, &fx.doc, &fx.derived, &.{}, c.opts);
        defer res.deinit();
        if (res.diags.hasErrors()) {
            for (res.diags.items()) |d| try out.print("landing: {s}: {t}: {s}\n", .{ c.file, d.code, d.message });
            return error.GoldenScoreHasErrors;
        }
        try artifacts.append(gpa, .{
            .path = try std.fs.path.join(arena, &.{ scores_dir, c.file }),
            .data = try arena.dupe(u8, res.text),
        });
        try scores.append(gpa, try describe(arena, c.file, res.landings));
    }

    var ticks: std.ArrayList(Entry) = .empty;
    defer ticks.deinit(gpa);
    try collect(gpa, &ticks, full);

    var json: Io.Writer.Allocating = .init(arena);
    defer json.deinit();
    try render(&json.writer, ticks.items, scores.items, full);
    try artifacts.append(gpa, .{
        .path = try std.fs.path.join(arena, &.{ dir_path, "landing.json" }),
        .data = json.written(),
    });

    if (check) {
        var stale: usize = 0;
        for (artifacts.items) |art| {
            const on_disk = Io.Dir.cwd().readFileAlloc(io, art.path, gpa, .limited(64 * 1024 * 1024)) catch {
                try out.print("landing: {s} is missing\n", .{art.path});
                stale += 1;
                continue;
            };
            defer gpa.free(on_disk);
            if (!std.mem.eql(u8, on_disk, art.data)) {
                try out.print("landing: {s} is stale\n", .{art.path});
                stale += 1;
            }
        }
        if (stale != 0) {
            try out.print("landing: {d} fixture(s) do not match this tree — run `zig build landing`\n", .{stale});
            return 1;
        }
        try out.print("landing: {d} fixtures up to date\n", .{artifacts.items.len});
        return 0;
    }

    try Io.Dir.cwd().createDirPath(io, scores_dir);
    for (artifacts.items) |art| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = art.path, .data = art.data });
        try out.print("landing: {s} ({d} bytes)\n", .{ art.path, art.data.len });
    }
    try out.print(
        "landing: {d} positions{s}\n",
        .{ ticks.items.len, if (full) ", exhaustive" else "" },
    );
    return 0;
}

/// A golden score's landing claims, copied into the arena — `Result`'s
/// own storage dies with it.
fn describe(arena: Allocator, file: []const u8, landings: []const exporter.score.Landing) !Score {
    const out = try arena.alloc(exporter.score.Landing, landings.len);
    for (landings, out) |src, *dst| dst.* = .{
        .target = try arena.dupe(u8, src.target),
        .ticks = try arena.dupe(i64, src.ticks),
    };
    return .{ .file = file, .landings = out };
}

/// A golden score and what it claims its triggers land on.
const Score = struct { file: []const u8, landings: []const exporter.score.Landing };

/// The sampled (or exhaustive) tick set, in emission order: the named
/// cases first, then one sweep per meter, each ascending and unique.
fn collect(gpa: Allocator, out: *std.ArrayList(Entry), full: bool) !void {
    for (named) |e| try out.append(gpa, e);

    for (meters) |m| {
        var taken: std.ArrayList(i64) = .empty;
        defer taken.deinit(gpa);
        if (full) {
            var t: i64 = 0;
            while (t <= sweep_ticks) : (t += 1) try taken.append(gpa, t);
        } else {
            var t: i64 = 0;
            while (t < window) : (t += 1) try taken.append(gpa, t);
            t = @max(sweep_ticks - window, window);
            while (t <= sweep_ticks) : (t += 1) try taken.append(gpa, t);
            t = window;
            while (t < sweep_ticks - window) : (t += stride) try taken.append(gpa, t);
        }
        std.mem.sort(i64, taken.items, {}, std.sort.asc(i64));
        var prev: ?i64 = null;
        for (taken.items) |t| {
            if (prev) |p| if (p == t) continue;
            prev = t;
            try out.append(gpa, .{ .tick = t, .n = m[0], .d = m[1] });
        }
    }
}

fn render(w: *Io.Writer, entries: []const Entry, scores: []const Score, full: bool) !void {
    try w.print(
        \\{{
        \\  "note": "generated by `zig build landing` — do not hand-edit",
        \\  "ppc": {d},
        \\  "full": {s},
        \\  "positions": [
        \\
    , .{ PPC, if (full) "true" else "false" });

    for (entries, 0..) |e, i| {
        try w.writeAll("    { \"pos\": \"");
        try pos.spellBeats(w, e.tick, e.n);
        try w.print("\", \"tick\": {d}, \"n\": {d}, \"d\": {d}", .{ e.tick, e.n, e.d });
        if (e.label.len != 0) try w.print(", \"label\": \"{s}\"", .{e.label});
        try w.print(" }}{s}\n", .{if (i + 1 == entries.len) "" else ","});
    }
    try w.writeAll("  ],\n  \"scores\": [\n");
    for (scores, 0..) |sc, i| {
        try w.print("    {{ \"file\": \"{s}\", \"landings\": [", .{sc.file});
        for (sc.landings, 0..) |l, j| {
            try w.print("{s}{{ \"target\": \"{s}\", \"ticks\": [", .{ if (j == 0) "" else ", ", l.target });
            for (l.ticks, 0..) |t, k| try w.print("{s}{d}", .{ if (k == 0) "" else ", ", t });
            try w.writeAll("] }");
        }
        try w.print("] }}{s}\n", .{if (i + 1 == scores.len) "" else ","});
    }
    try w.writeAll("  ]\n}\n");
}
