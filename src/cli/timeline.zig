//! `tempura timeline DOC [-o MAP] [--json]` — the `TimeMap` as data.
//!
//! Plan 10's row: "the `TimeMap` as data: tempo segments, meters, bars,
//! sections, cues, per-lane onsets, length, loop point; `--json` for the
//! studio's shape".
//!
//! Two renderings of ONE derivation, never two derivations: the text is
//! `Derived.echo`, the canonical form the corpus goldens already pin
//! (`(segment …)`, `(meter …)`, `(bars …)`, `(length …)`, then the
//! sections, the cues and one line per lane), and the JSON is the same
//! fields with the content the echo summarises spelled out.
//!
//! **Floats ride twice.** The echo prints `:tps` and `:start-sec` as the
//! 16 hex digits of their IEEE-754 bits, because the corpus's whole claim
//! is that two hosts compute the same f64 to the last bit and a decimal
//! rendering cannot say that. A studio wants a number. So the JSON
//! carries both: `tps` is the number and `tps_bits` is the pattern, and a
//! consumer that cares about exactness reads the one that can carry it.

const std = @import("std");
const tempura = @import("tempura");

const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;

/// The envelope's own version. Bumped only on a BREAKING change; an added
/// field never bumps it (pacer's rule, and for pacer's reason: this shape
/// has one producer and no second decoder, so it is versioned rather than
/// frozen).
pub const format_version: u32 = 1;

pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    var loaded = switch (try ctx.loadDoc()) {
        .failed => |code| return code,
        .ok => |l| l,
    };
    defer loaded.deinit();

    var derived = try tempura.time.derive.derive(ctx.gpa, &loaded.result.doc);
    defer derived.deinit();

    // One list for the report, in producer order: what the DOCUMENT got
    // wrong, then what deriving it found. Two lists would make a reader
    // ask which one to believe.
    var all: std.ArrayList(tempura.Diag.Diagnostic) = .empty;
    defer all.deinit(ctx.arena);
    try all.appendSlice(ctx.arena, loaded.result.diags.items());
    try all.appendSlice(ctx.arena, derived.diags.items());

    var art: Writer.Allocating = .init(ctx.gpa);
    defer art.deinit();
    if (ctx.cmd.json) {
        try writeJson(&art.writer, ctx, &loaded.index, loaded.source, all.items, &derived);
    } else {
        try derived.echo(&art.writer);
    }

    // The derivation is BEST-EFFORT — a defective document still has a
    // map, and showing it is how you see what the defect did to the time
    // — so the artifact is emitted either way and the exit code carries
    // the verdict.
    if (!try ctx.emit(art.written())) return Cli.Exit.usage;
    try Diags.render(ctx.err, ctx.cmd.path, loaded.space(), all.items, ctx.style);
    return Diags.exitCode(all.items);
}

/// The JSON envelope: the header, the verdict, the diagnostics and the
/// timeline, one helper per section, in the order the keys ride. The
/// helpers write into one `Stringify` so the nesting is checked by the
/// one writer that can check it.
fn writeJson(
    w: *Writer,
    ctx: *const Cli.Ctx,
    index: *const Diags.LineIndex,
    source: []const u8,
    diags: []const tempura.Diag.Diagnostic,
    d: *const tempura.time.derive.Derived,
) Cli.Error!void {
    var j: Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };

    try j.beginObject();
    try writeHeader(&j, ctx, source);
    try writeVerdict(&j, diags);
    try writeDiagnostics(&j, index, diags);

    try j.objectField("timeline");
    try j.beginObject();
    try j.objectField("integral");
    try j.write(d.map.integral);
    try writeSegments(&j, d.map.segments);
    try writeMeters(&j, d.map.meters);
    // The bar table is a long list of ticks and a consumer wants the
    // whole thing — it is the grid a timeline strip draws.
    try j.objectField("bars");
    try j.beginArray();
    for (d.map.bars) |b| try j.write(b);
    try j.endArray();
    try writeLength(&j, &d.map);
    try writeSections(&j, d.sections);
    try writeCues(&j, d.cues);
    try writeLanes(&j, d.lanes);
    try j.endObject();

    try j.endObject();
    try w.writeAll("\n");
}

/// `tempura`, `command` and `source`: who wrote this and over what.
fn writeHeader(j: *Stringify, ctx: *const Cli.Ctx, source: []const u8) Cli.Error!void {
    try j.objectField("tempura");
    try j.beginObject();
    try j.objectField("version");
    try j.write(tempura.version);
    try j.objectField("format");
    try j.write(format_version);
    try j.endObject();

    try j.objectField("command");
    try j.write("timeline");

    try j.objectField("source");
    try j.beginObject();
    try j.objectField("path");
    try j.write(Diags.label(ctx.cmd.path));
    try j.objectField("bytes");
    try j.write(source.len);
    try j.endObject();
}

/// `ok` and `counts`: the verdict a consumer reads before anything else.
fn writeVerdict(j: *Stringify, diags: []const tempura.Diag.Diagnostic) Cli.Error!void {
    const counts = Diags.count(diags);
    try j.objectField("ok");
    try j.write(counts.errors == 0);
    try j.objectField("counts");
    try j.beginObject();
    try j.objectField("errors");
    try j.write(counts.errors);
    try j.objectField("warnings");
    try j.write(counts.warnings);
    try j.objectField("infos");
    try j.write(counts.infos);
    try j.endObject();
}

/// `diagnostics`: one object per entry, in producer order, with the raw
/// byte offsets AND the 1-based line/column — the offsets are what every
/// other tempura surface speaks, the line and column are what a person
/// reads.
fn writeDiagnostics(
    j: *Stringify,
    index: *const Diags.LineIndex,
    diags: []const tempura.Diag.Diagnostic,
) Cli.Error!void {
    try j.objectField("diagnostics");
    try j.beginArray();
    for (diags) |x| {
        try j.beginObject();
        try j.objectField("code");
        try j.write(@tagName(x.code));
        try j.objectField("code_id");
        try j.write(@intFromEnum(x.code));
        try j.objectField("severity");
        try j.write(Diags.severityWord(x.severity));
        try j.objectField("message");
        try j.write(x.message);
        try j.objectField("span");
        const start = index.at(x.span.start);
        const end = index.at(x.span.end);
        try j.beginObject();
        try j.objectField("start");
        try j.write(x.span.start);
        try j.objectField("end");
        try j.write(x.span.end);
        try j.objectField("line");
        try j.write(start.line);
        try j.objectField("col");
        try j.write(start.col);
        try j.objectField("end_line");
        try j.write(end.line);
        try j.objectField("end_col");
        try j.write(end.col);
        try j.endObject();
        try j.endObject();
    }
    try j.endArray();
}

/// `segments`: each tempo segment with its two floats spelled twice (the
/// number, and the bits — see the header).
fn writeSegments(j: *Stringify, segments: []const tempura.time.TimeMap.Segment) Cli.Error!void {
    try j.objectField("segments");
    try j.beginArray();
    for (segments) |s| {
        try j.beginObject();
        try j.objectField("tick");
        try j.write(s.tick);
        try j.objectField("us");
        try j.write(s.us);
        try j.objectField("tps");
        try j.write(s.tps);
        try j.objectField("tps_bits");
        try writeBits(j, s.tps);
        try j.objectField("start_sec");
        try j.write(s.start_sec);
        try j.objectField("start_sec_bits");
        try writeBits(j, s.start_sec);
        try j.endObject();
    }
    try j.endArray();
}

/// `meters`: each meter segment with its signature as a pair.
fn writeMeters(j: *Stringify, meters: []const tempura.time.TimeMap.MeterSeg) Cli.Error!void {
    try j.objectField("meters");
    try j.beginArray();
    for (meters) |m| {
        try j.beginObject();
        try j.objectField("tick");
        try j.write(m.tick);
        try j.objectField("sig");
        try j.beginArray();
        try j.write(m.n);
        try j.write(m.d);
        try j.endArray();
        try j.objectField("first_bar");
        try j.write(m.first_bar);
        try j.objectField("beats_before");
        try j.write(m.beats_before);
        try j.endObject();
    }
    try j.endArray();
}

/// `length`: the end tick, the end behaviour and the loop point.
fn writeLength(j: *Stringify, map: *const tempura.time.TimeMap.TimeMap) Cli.Error!void {
    try j.objectField("length");
    try j.beginObject();
    try j.objectField("tick");
    try j.write(map.length);
    try j.objectField("end");
    try j.write(@tagName(map.end));
    try j.objectField("loop_secs");
    try j.write(map.loop_secs);
    try j.objectField("loop_secs_bits");
    try writeBits(j, map.loop_secs);
    try j.endObject();
}

/// `sections`: the named windows.
fn writeSections(j: *Stringify, sections: []const tempura.time.derive.Section) Cli.Error!void {
    try j.objectField("sections");
    try j.beginArray();
    for (sections) |s| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(s.name);
        try j.objectField("at");
        try j.write(s.at);
        try j.objectField("dur");
        try j.write(s.dur);
        try j.endObject();
    }
    try j.endArray();
}

/// `cues`: the named points.
fn writeCues(j: *Stringify, cues: []const tempura.time.derive.Cue) Cli.Error!void {
    try j.objectField("cues");
    try j.beginArray();
    for (cues) |c| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(c.name);
        try j.objectField("at");
        try j.write(c.at);
        try j.endObject();
    }
    try j.endArray();
}

/// `lanes`: one object per lane with the content the echo only counts —
/// every onset and every step, spelled out.
fn writeLanes(j: *Stringify, lanes: []const tempura.time.derive.LaneIndex) Cli.Error!void {
    try j.objectField("lanes");
    try j.beginArray();
    for (lanes) |l| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(l.name);
        try j.objectField("kind");
        try j.write(@tagName(l.kind));
        try j.objectField("bound");
        try j.write(l.bound);
        try writeOnsets(j, l.onsets);
        try writeSteps(j, l.steps);
        try j.endObject();
    }
    try j.endArray();
}

/// A lane's `onsets`.
fn writeOnsets(j: *Stringify, onsets: []const tempura.time.derive.Onset) Cli.Error!void {
    try j.objectField("onsets");
    try j.beginArray();
    for (onsets) |o| {
        try j.beginObject();
        try j.objectField("tick");
        try j.write(o.tick);
        try j.objectField("dur");
        try j.write(o.dur);
        try j.objectField("key");
        try j.write(o.key);
        try j.objectField("vel");
        try j.write(o.vel);
        try j.endObject();
    }
    try j.endArray();
}

/// A lane's `steps`: the value's live components and the easing source.
fn writeSteps(j: *Stringify, steps: []const tempura.time.derive.Step) Cli.Error!void {
    try j.objectField("steps");
    try j.beginArray();
    for (steps) |s| {
        try j.beginObject();
        try j.objectField("tick");
        try j.write(s.tick);
        try j.objectField("value");
        try j.beginArray();
        for (s.value[0..s.ncomp]) |v| try j.write(v);
        try j.endArray();
        try j.objectField("ease");
        try j.write(s.ease_src);
        try j.endObject();
    }
    try j.endArray();
}

/// One f64's bits, spelled exactly as `TimeMap.echo` spells them, so the
/// two renderings of one map are comparable digit for digit.
fn writeBits(j: *Stringify, x: f64) Cli.Error!void {
    var buf: [16]u8 = undefined;
    // A u64 has at most 16 hex digits and `{X:0>16}` pads to exactly 16,
    // so the 16-byte buffer is never short.
    const text = std.fmt.bufPrint(&buf, "{X:0>16}", .{@as(u64, @bitCast(x))}) catch unreachable;
    try j.write(text);
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "timeline: the text is Derived.echo, on stdout, with nothing on stderr" {
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-three-conductors-native/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "timeline", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());
    // The three segments of plan 03's fixture, in the echo's shape.
    try t.expectEqualStrings(
        \\(segment :tick 0 :us 480000 :tps "4196E93C00000000" :start-sec "0000000000000000")
        \\(segment :tick 46126080 :us 400000 :tps "419B7E4800000000" :start-sec "3FDEB851EB851EB8")
        \\(segment :tick 92252160 :us 300000 :tps "41A2543000000000" :start-sec "3FEC28F5C28F5C29")
        \\(meter :tick 0 :sig [4 4] :first-bar 0)
        \\(bars :count 2 :last-start 184504320)
        \\(length :tick 184504320 :end hold :loop-secs "3FF7AE147AE147AE")
        \\
    , c.out.written());
}

test "timeline: the three conductors echo the same map, through the CLI" {
    // Plan 03, phase 3's red, re-asked at the CLI seam: the native
    // document, the SMF-conducted one and the IT-conducted one are one
    // map spelled three ways, and `timeline` must not be where they
    // diverge.
    //
    // Each anchored fixture ships its `song.mid` / `song.it` beside it,
    // with the `:size` and `:sha256` that `fromSource` verifies before
    // any offset is honoured — so this also exercises the CLI's
    // filesystem resolver pointed at the DOCUMENT's own directory.
    const a = t.allocator;
    var native = blk: {
        const p = try Cli.repoPath(a, "corpus/tempo-three-conductors-native/doc.sjon");
        defer a.free(p);
        break :blk try Cli.invoke(&.{ "tempura", "timeline", p });
    };
    defer native.deinit();
    try t.expectEqual(Cli.Exit.ok, native.code);

    inline for (.{ "smf", "it" }) |kind| {
        const p = try Cli.repoPath(a, "corpus/tempo-three-conductors-" ++ kind ++ "/doc.sjon");
        defer a.free(p);
        var c = try Cli.invoke(&.{ "tempura", "timeline", p });
        defer c.deinit();
        try t.expectEqualStrings(native.out.written(), c.out.written());
        try t.expectEqual(Cli.Exit.ok, c.code);
        try t.expectEqualStrings("", c.err.written());
    }
}

test "timeline --json: a parseable envelope whose numbers match the echo's bits" {
    const path = try Cli.repoPath(t.allocator, "corpus/tempo-three-conductors-native/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "timeline", path, "--json" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);

    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, c.out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try t.expectEqual(true, root.get("ok").?.bool);
    try t.expectEqualStrings("timeline", root.get("command").?.string);
    try t.expectEqualStrings(tempura.version, root.get("tempura").?.object.get("version").?.string);

    const tl = root.get("timeline").?.object;
    const segs = tl.get("segments").?.array.items;
    try t.expectEqual(@as(usize, 3), segs.len);
    try t.expectEqualStrings("4196E93C00000000", segs[0].object.get("tps_bits").?.string);
    try t.expectEqual(@as(i64, 46126080), segs[1].object.get("tick").?.integer);
    try t.expectEqual(@as(i64, 184504320), tl.get("length").?.object.get("tick").?.integer);
    try t.expectEqualStrings("hold", tl.get("length").?.object.get("end").?.string);
}

test "timeline --json: sections, cues and per-lane onsets are all there" {
    const path = try Cli.repoPath(t.allocator, "corpus/playhead-sections-cues/doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "timeline", path, "--json" });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);

    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, c.out.written(), .{});
    defer parsed.deinit();
    const tl = parsed.value.object.get("timeline").?.object;
    try t.expectEqual(@as(usize, 3), tl.get("sections").?.array.items.len);
    try t.expectEqual(@as(usize, 2), tl.get("cues").?.array.items.len);

    const lanes = tl.get("lanes").?.array.items;
    try t.expectEqual(@as(usize, 2), lanes.len);
    try t.expectEqualStrings("flash", lanes[0].object.get("name").?.string);
    try t.expectEqual(@as(usize, 3), lanes[0].object.get("onsets").?.array.items.len);
    try t.expectEqualStrings("curve", lanes[1].object.get("kind").?.string);
    try t.expectEqual(@as(usize, 3), lanes[1].object.get("steps").?.array.items.len);
}

test "timeline -o: the artifact goes to the file and stdout stays empty" {
    const a = t.allocator;
    const path = try Cli.repoPath(a, "corpus/tempo-three-conductors-native/doc.sjon");
    defer a.free(path);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // `tmpDir` creates under the cwd's `.zig-cache/tmp`, and a build
    // Run step's cwd is the build root — the same cwd `Ctx.emit` writes
    // through, which is the whole point of naming it relatively here.
    const dest = try std.fmt.allocPrintSentinel(
        a,
        ".zig-cache/tmp/{s}/map.sjon",
        .{tmp.sub_path},
        0,
    );
    defer a.free(dest);

    var c = try Cli.invoke(&.{ "tempura", "timeline", path, "-o", dest });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.out.written());

    const written = try tmp.dir.readFileAlloc(std.testing.io, "map.sjon", a, .limited(1 << 20));
    defer a.free(written);
    try t.expect(std.mem.startsWith(u8, written, "(segment :tick 0 :us 480000"));
}

test "timeline: a defective document still echoes a map, and exits 1" {
    const path = try Cli.repoPath(t.allocator, "src/cli/testdata/bad-doc.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "timeline", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expect(c.out.written().len > 0);
    try t.expect(std.mem.indexOf(u8, c.err.written(), "lane_duplicate") != null);
}
