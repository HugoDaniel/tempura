//! `tempura inspect FILE` — the annotated offset map.
//!
//! Plan 10's row: "the annotated offset map (chunks or regions, events or
//! patterns, running status, SMPTE conversion, the residue's location)".
//! Plan 05's phase 4 asks for it over SMF, plan 06's region table over
//! `.it`.
//!
//! This is the one verb whose whole content is the `SourceMap` — the
//! record of what the reader SAW that the value itself does not say. A
//! `Sequence` knows it has four events; only the map knows the third one
//! was read on running status and started at byte 0x1d. Everything here
//! is read off that map, and nothing is recomputed: a second walk over
//! the bytes would be a second answer to a question that already has one.
//!
//! The text goes to STDOUT — it is the product, the thing you pipe into
//! `grep` — while the reader's diagnostics go to stderr like every other
//! verb's. Offsets are hex and lengths are decimal, which is the it set's
//! convention (`:at 0x8728`) and the one a person reading a hex editor
//! beside this actually wants.

const std = @import("std");
const tempura = @import("tempura");

const Cli = @import("Cli.zig");
const Diags = @import("Diags.zig");

const Writer = std.Io.Writer;

/// The verb: read a `.mid` or a `.it` and print its annotated byte map on
/// stdout, the reader's diagnostics on stderr beside it. Always prints
/// the map; exits with the reader's verdict, or `Exit.usage` when the
/// bytes are neither format. Every value it builds is freed before it
/// returns.
pub fn run(ctx: *const Cli.Ctx) Cli.Error!u8 {
    const bytes = Cli.load(ctx.arena, ctx.io, ctx.cmd.path) catch |e|
        return Cli.reportLoadFailure(ctx, e);

    const kind = try ctx.sniffKind(bytes) orelse return Cli.Exit.usage;

    var art: Writer.Allocating = .init(ctx.gpa);
    defer art.deinit();
    const w = &art.writer;

    try w.print("file: {s}\nbytes: {d}\nkind: {s}\n", .{
        Diags.label(ctx.cmd.path), bytes.len, @tagName(kind),
    });

    // Every diagnostic here is the READER's, so its span counts bytes of
    // the file — the same coordinate the map itself prints, which is what
    // lets a reported offset be looked up in the dump above it.
    const code = switch (kind) {
        .mid => try smfMap(ctx, w, bytes),
        .it => try itMap(ctx, w, bytes),
    };
    try ctx.out.writeAll(art.written());
    return code;
}

// ---------------------------------------------------------------------
// SMF
// ---------------------------------------------------------------------

fn smfMap(ctx: *const Cli.Ctx, w: *Writer, bytes: []const u8) Cli.Error!u8 {
    var res = try tempura.smf.read(ctx.gpa, bytes);
    defer res.deinit();
    const seq = &res.sequence;
    const map = &res.source_map;

    try w.print("format: {d}\ntracks: {d}\n", .{ seq.format, seq.tracks.len });
    switch (seq.division) {
        .ppq => |p| try w.print("division: {d} ppq\n", .{p}),
        .smpte => |s| try w.print("division: smpte {d} fps x {d} tpf\n", .{ s.fps, s.tpf }),
    }
    if (map.smpte) |c| try w.print(
        "smpte: {d} fps x {d} tpf converted to {d} ppq (tempo events are ignored for timing)\n",
        .{ c.fps, c.tpf, c.ppq },
    );
    if (map.riff) |r| try w.print(
        "riff: the SMF sits at 0x{X:0>8}, {d} bytes\n",
        .{ r.offset, r.len },
    );

    try w.writeAll("\n");
    // `SourceMap.tracks[i].chunk` indexes `chunks`, so the join goes the
    // other way: for each chunk, which track (if any) came out of it.
    for (map.chunks, 0..) |c, ci| {
        try w.print("chunk {d: >3}  {s}  at 0x{X:0>8}  header 8  body {d}", .{
            ci, Cli.printableTag(&c.tag), c.offset, c.len,
        });
        if (c.clamped_len != c.len) try w.print("  (only {d} present)", .{c.clamped_len});

        const track = trackOfChunk(map, @intCast(ci));
        if (track) |ti| try w.print("  track {d}", .{ti + 1});
        if (isForeign(map, @intCast(ci))) try w.writeAll("  foreign");
        try w.writeAll("\n");

        const ti = track orelse continue;
        for (map.tracks[ti].events, seq.tracks[ti].events, 0..) |site, ev, ei| {
            try w.print("  event {d: >4}  at 0x{X:0>8}  tick {d}  {s}", .{
                ei, site.offset, ev.at, @tagName(ev.kind),
            });
            if (site.running_status) try w.writeAll("  running-status");
            if (ev.kind == .tempura_residue) try w.writeAll("  <- residue");
            try w.writeAll("\n");
        }
    }

    try w.writeAll("\n");
    var residue = false;
    for (seq.tracks, 0..) |tr, ti| {
        for (tr.events, 0..) |ev, ei| {
            if (ev.kind != .tempura_residue) continue;
            residue = true;
            try w.print("residue: track {d} event {d} at 0x{X:0>8}\n", .{
                ti + 1, ei, map.tracks[ti].events[ei].offset,
            });
        }
    }
    if (!residue) try w.writeAll("residue: none\n");

    try Diags.render(ctx.err, ctx.cmd.path, .bytes, res.diags.items(), ctx.style);
    return Diags.exitCode(res.diags.items());
}

fn trackOfChunk(map: *const tempura.smf.SourceMap, chunk: u32) ?usize {
    for (map.tracks, 0..) |tm, i| {
        if (tm.chunk == chunk) return i;
    }
    return null;
}

fn isForeign(map: *const tempura.smf.SourceMap, chunk: u32) bool {
    for (map.foreign) |f| {
        if (f.offset == map.chunks[chunk].offset) return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// IT
// ---------------------------------------------------------------------

fn itMap(ctx: *const Cli.Ctx, w: *Writer, bytes: []const u8) Cli.Error!u8 {
    var res = try tempura.itf.read.read(ctx.gpa, bytes);
    defer res.deinit();
    const m = &res.module;

    try w.print("title: \"{s}\"\n", .{std.mem.sliceTo(&m.header.title, 0)});
    try w.print(
        "orders: {d}\npatterns: {d}\ninstruments: {d}\nsamples: {d}\n",
        .{ m.orders.len, m.patterns.len, m.instruments.len, m.samples.len },
    );
    try w.print(
        "speed: {d}\ntempo: {d}\nmessage: {d} bytes\n",
        .{ m.header.initial_speed, m.header.initial_tempo, m.message.len },
    );

    try w.writeAll("\n");
    for (res.source_map.entries, 0..) |e, i| {
        try w.print("region {d: >3}  {s: <14}  at 0x{X:0>8}  len {d}", .{
            i, @tagName(e.kind), e.region.off, e.region.len,
        });
        // A kind with more than one record says WHICH: `sample_header 3`
        // is a different question from `sample_header 0`.
        switch (e.kind) {
            .instrument, .sample_header, .sample_data, .pattern, .foreign => try w.print(
                "  #{d}",
                .{e.index},
            ),
            else => {},
        }
        if (e.kind == .pattern and e.index < m.patterns.len)
            try w.print("  rows {d}", .{m.patterns[e.index].rows});
        if (e.kind == .foreign and e.index < m.foreign.len)
            try w.print("  tag \"{s}\"", .{Cli.printableTag(&m.foreign[e.index].tag)});
        try w.writeAll("\n");
    }

    try w.writeAll("\n");
    var any = false;
    if (m.tmpu) |r| {
        any = true;
        try w.print("residue: TMPU chunk at 0x{X:0>8}, {d} bytes\n", .{ r.off, r.len });
    }
    const split = tempura.residue.it.splitMessage(m.message);
    if (split.tail) |tail| {
        any = true;
        try w.print("residue: message tail, {d} bytes after {d} of song text\n", .{
            tail.len, split.human.len,
        });
    }
    if (!any) try w.writeAll("residue: none\n");

    try Diags.render(ctx.err, ctx.cmd.path, .bytes, res.diags.items(), ctx.style);
    return Diags.exitCode(res.diags.items());
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "inspect: an SMF's chunks, its events, and the running status they reused" {
    // `corpus/smf-running-status/song.mid` exists to carry a run of
    // events with the status byte elided; the map is the only place that
    // fact is recorded, so this is the assertion the fixture was for.
    const path = try Cli.repoPath(t.allocator, "corpus/smf-running-status/song.mid");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "inspect", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());

    const text = c.out.written();
    try t.expect(std.mem.indexOf(u8, text, "kind: mid\n") != null);
    try t.expect(
        std.mem.indexOf(u8, text, "chunk   0  MThd  at 0x00000000  header 8  body 6\n") != null,
    );
    try t.expect(std.mem.indexOf(u8, text, "chunk   1  MTrk  at 0x0000000E") != null);
    try t.expect(std.mem.indexOf(u8, text, "running-status") != null);
    try t.expect(std.mem.indexOf(u8, text, "residue: none\n") != null);
}

test "inspect: a SMPTE division reports the conversion it was given" {
    const path = try Cli.repoPath(t.allocator, "corpus/smf-smpte/song.mid");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "inspect", path });
    defer c.deinit();
    const text = c.out.written();
    try t.expect(std.mem.indexOf(u8, text, "division: smpte ") != null);
    try t.expect(std.mem.indexOf(u8, text, "converted to ") != null);
    try t.expect(std.mem.indexOf(u8, text, "ignored for timing") != null);
}

test "inspect: an IT module's regions, in reading order, with the pattern rows" {
    const path = try Cli.repoPath(t.allocator, "corpus/it-minimal/song.it");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "inspect", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.ok, c.code);

    const text = c.out.written();
    try t.expect(std.mem.indexOf(u8, text, "kind: it\n") != null);
    try t.expect(
        std.mem.indexOf(u8, text, "region   0  header          at 0x00000000  len 192\n") != null,
    );
    try t.expect(std.mem.indexOf(u8, text, "orders") != null);
    try t.expect(std.mem.indexOf(u8, text, "  rows ") != null);
    try t.expect(std.mem.indexOf(u8, text, "residue: none\n") != null);
}

test "inspect: a file that is neither, and has no name to go on, is a usage error" {
    const path = try Cli.repoPath(t.allocator, "corpus/it-minimal/times.sjon");
    defer t.allocator.free(path);
    var c = try Cli.invoke(&.{ "tempura", "inspect", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "MThd") != null);
}

test "inspect: a truncated file still maps what it has, and says what is wrong" {
    // The map is how you find out; refusing to print it would make the
    // one verb whose job is "what is in these bytes" useless on exactly
    // the bytes you needed it for.
    const a = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "broken.mid",
        // `MThd` with a body length of 6 and only four bytes of it.
        .data = "MThd\x00\x00\x00\x06\x00\x01\x00\x01",
    });
    const path = try std.fmt.allocPrintSentinel(
        a,
        ".zig-cache/tmp/{s}/broken.mid",
        .{tmp.sub_path},
        0,
    );
    defer a.free(path);

    var c = try Cli.invoke(&.{ "tempura", "inspect", path });
    defer c.deinit();
    try t.expectEqual(Cli.Exit.errors, c.code);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "chunk   0  MThd") != null);
    try t.expect(std.mem.indexOf(u8, c.err.written(), ": error ") != null);
}

/// Write `bytes` into a fresh temp directory and inspect them.
///
/// The two residue branches below have no corpus fixture to stand on —
/// nothing committed carries a `7D 'tem'` event or a `;; tempura` message
/// tail — so each builds its own file through the residue carriers
/// themselves, which is also the only way the test can be sure what it is
/// looking for is really there.
fn inspectBytes(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !Cli.Captured {
    const gpa = t.allocator;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    const path = try std.fmt.allocPrintSentinel(
        gpa,
        ".zig-cache/tmp/{s}/{s}",
        .{ tmp.sub_path, name },
        0,
    );
    defer gpa.free(path);
    return Cli.invoke(&.{ "tempura", "inspect", path });
}

test "inspect: an SMF carrying a 7D 'tem' event reports where the residue sits" {
    const a = t.allocator;

    var b: tempura.smf.Builder = .init(a);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const track = try b.addTrack();
    try b.addEvent(track, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(track, 96, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    var seq = try b.finish();
    defer seq.deinit();

    // The carrier's own `attach`, so what lands in the file is exactly
    // what a real residue is — envelope bytes and all.
    var attached = try tempura.residue.smf.attach(a, &seq, .{ .essence = "tempura-essence" }, .{});
    defer attached.deinit();
    try t.expect(!attached.diags.hasErrors());

    var file = try tempura.smf.write(a, &attached.sequence, .{});
    defer file.deinit();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var c = try inspectBytes(&tmp, "residue.mid", file.bytes);
    defer c.deinit();

    try t.expectEqual(Cli.Exit.ok, c.code);
    const text = c.out.written();
    try t.expect(std.mem.indexOf(u8, text, "tempura_residue  <- residue") != null);
    try t.expect(std.mem.indexOf(u8, text, "residue: track 1 event ") != null);
    try t.expect(std.mem.indexOf(u8, text, "residue: none") == null);
}

test "inspect: an IT whose song message carries a tail reports the split" {
    const a = t.allocator;

    const message = try tempura.residue.it.appendTail(
        a,
        "written by hand",
        tempura.residue.it.marker ++ "\r(timeline)",
    );
    defer a.free(message);

    var b: tempura.itf.Builder = .init(a);
    errdefer b.deinit();
    b.setTitle("tail");
    try b.addOrder(0);
    _ = try b.addPattern(32);
    try b.setMessage(message);
    var module = b.finish();
    defer module.deinit();

    var file = try tempura.itf.write.write(a, &module, null, .{});
    defer file.deinit();
    try t.expect(!file.diags.hasErrors());

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var c = try inspectBytes(&tmp, "tail.it", file.bytes);
    defer c.deinit();

    try t.expectEqual(Cli.Exit.ok, c.code);
    const text = c.out.written();
    try t.expect(std.mem.indexOf(u8, text, "residue: message tail") != null);
    // The human half is measured too: 15 bytes of "written by hand".
    try t.expect(std.mem.indexOf(u8, text, "15 of song text") != null);
    try t.expect(std.mem.indexOf(u8, text, "residue: none") == null);
}
