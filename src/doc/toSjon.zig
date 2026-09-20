//! `Doc` → the canonical `(timeline …)` text.
//!
//! One document, one spelling. The printer is what makes a dump
//! comparable, a corpus pinnable and an edit reviewable: the same value
//! prints to the same bytes on every host (plan 01's determinism rule),
//! and what it prints reads back as the same value (plan 02, phase 3).
//!
//! The order is plan 02's own reading order: the header, the files the
//! document is arranged around, the map that gives it time, the windows
//! and the points, the lanes, the phrases they place, and last the pacer
//! roots that pass through `export-score` untouched — verbatim, because
//! tempura never derives from one and never edits one.
//!
//! **Positions go through `map.spell`**, which is plan 03's frozen rule:
//! `Nbar` on a bar line, else `Nq` when the tick has an exact short
//! decimal in quarters, else `Nt`. Quantised material reads as music and
//! triplets read as ticks. A DURATION is spelled by the same rule — the
//! bridge resolves `:dur` and `:offset` from the origin, so the spelling
//! and the reading are inverse and the round trip is an identity.
//!
//! **A default is not printed.** `:end hold`, `:vel 100`, `:repeat 1`,
//! `:transpose 0`, `:ease linear`, `:offset 0` and a `:target` equal to
//! the lane's `:name` are all read back from the manifest (or, for the
//! last, from the sibling key), so writing them would be noise that says
//! nothing. `:kind` is the exception and is always written: it is the
//! discriminant that gates which keys exist, and the manifest asks for
//! it ahead of them.
//!
//! **Numbers are SJON's own spelling**, `Printer.formatNumberInto`'s
//! rule restated because that function is private: an integral value
//! under 2^53 prints as an integer and everything else takes `{d}`,
//! which is the shortest decimal that reads back as the same float. An
//! f32 slot formats AS f32, so `0.2` stays `0.2` rather than becoming
//! the f64 expansion of an f32.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const Grid = @import("../time/Grid.zig");
const Pos = @import("../time/Pos.zig");
const Schema = @import("../Schema.zig");
const TimeMap = @import("../time/TimeMap.zig");
const Doc = @import("Value.zig");
const fromSjon = @import("fromSjon.zig");

const testing = std.testing;

/// Printing can only fail the way any allocation fails.
pub const Error = error{OutOfMemory};

pub const Options = struct {
    /// Whether an inline dump's heads carry their tier's namespace
    /// (`(it/module …)` rather than `(module …)`). Qualified is the
    /// default because it is the spelling that survives composition with
    /// midivia's full manifest, whose `note` verb collides with
    /// tempura's (plan 02, "The `note` collision with midivia").
    ///
    /// It governs the two file tiers and nothing else, and both are
    /// EMPTY in this task — so it changes no byte yet, and is declared
    /// now so the anchored half does not change this signature.
    qualify: bool = true,
};

/// The canonical text of `doc`, owned by the caller.
///
/// `map` is the document's own `TimeMap` — the one `fromSource` returned
/// beside it — because a tick's spelling is a question only a bar table
/// can answer.
pub fn print(
    gpa: std.mem.Allocator,
    doc: *const Doc.Doc,
    map: *const TimeMap.TimeMap,
    opts: Options,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var p: Printer = .{ .gpa = gpa, .out = &out, .doc = doc, .map = map, .opts = opts };
    try p.document();
    return out.toOwnedSlice(gpa);
}

const Printer = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    doc: *const Doc.Doc,
    map: *const TimeMap.TimeMap,
    opts: Options,

    // ---- the document -------------------------------------------------

    fn document(self: *Printer) Error!void {
        const d = self.doc;

        try self.raw("(timeline");
        if (d.title) |t| {
            try self.raw(" :title ");
            try self.string(t);
        }
        if (d.length) |tick| {
            try self.raw(" :length ");
            try self.pos(tick);
        }
        if (d.end != .hold) try self.raw(" :end loop");
        if (d.conductor) |c| {
            try self.raw(" :conductor ");
            try self.raw(c);
        }
        try self.raw(")\n");

        try self.group(d.anchors.len > 0);
        for (d.anchors) |a| try self.anchor(a);

        try self.group(d.tempo.len > 0 or d.meter.len > 0);
        for (d.tempo) |t| try self.tempoPoint(t);
        for (d.meter) |m| try self.meterPoint(m);

        try self.group(d.sections.len > 0);
        for (d.sections) |s| try self.section(s);

        try self.group(d.cues.len > 0);
        for (d.cues) |c| try self.cue(c);

        try self.group(d.lanes.len > 0);
        for (d.lanes) |l| {
            try self.lane(l, 0);
            try self.raw("\n");
        }

        try self.group(d.phrases.len > 0);
        for (d.phrases) |ph| try self.phrase(ph);

        try self.group(d.passthrough.len > 0);
        for (d.passthrough) |pt| {
            for (pt.comments) |c| {
                try self.raw(c);
                try self.raw("\n");
            }
            try self.raw(pt.text);
            try self.raw("\n");
        }
    }

    /// A blank line before a non-empty group, so the reading order of
    /// plan 02's example survives the print.
    fn group(self: *Printer, nonempty: bool) Error!void {
        if (nonempty) try self.raw("\n");
    }

    // ---- the forms ----------------------------------------------------

    fn anchor(self: *Printer, a: Doc.Anchor) Error!void {
        try self.raw("(anchor :id ");
        try self.raw(a.id);
        try self.raw(" :kind ");
        try self.raw(@tagName(a.kind));
        try self.raw(" :file ");
        try self.string(a.file);
        if (a.size) |size| {
            try self.raw(" :size ");
            try self.int(size);
        }
        if (a.sha256_src) |hex| {
            try self.raw(" :sha256 ");
            try self.string(hex);
        }
        try self.raw(")\n");
    }

    fn tempoPoint(self: *Printer, t: Doc.TempoPoint) Error!void {
        try self.raw("(tempo-point :at ");
        try self.pos(t.tick);
        switch (t.tempo) {
            .us => |u| {
                try self.raw(" :us ");
                try self.int(u);
            },
            .qpm => |q| {
                try self.raw(" :qpm ");
                try self.double(q);
            },
        }
        try self.raw(")\n");
    }

    fn meterPoint(self: *Printer, m: Doc.MeterPoint) Error!void {
        try self.raw("(meter-point :at ");
        try self.pos(m.tick);
        try self.raw(" :sig [");
        try self.int(m.n);
        try self.raw(" ");
        try self.int(m.d);
        try self.raw("])\n");
    }

    fn section(self: *Printer, s: Doc.Section) Error!void {
        try self.raw("(section :name ");
        try self.raw(s.name);
        try self.raw(" :at ");
        try self.pos(s.at);
        try self.raw(" :dur ");
        try self.pos(s.dur);
        try self.raw(")\n");
    }

    fn cue(self: *Printer, c: Doc.Cue) Error!void {
        try self.raw("(cue :name ");
        try self.string(c.name);
        try self.raw(" :at ");
        try self.pos(c.at);
        try self.raw(")\n");
    }

    fn phrase(self: *Printer, ph: Doc.Phrase) Error!void {
        try self.raw("(phrase :name ");
        try self.raw(ph.name);
        try self.raw(" :length ");
        try self.pos(ph.length);
        for (ph.lanes) |l| {
            try self.raw("\n");
            try self.lane(l, 2);
        }
        try self.raw(")\n");
    }

    /// One `(lane …)`. Inside a phrase (`indent > 0`) the lane carries
    /// content only, so `:target` and the binding are not written: the
    /// placing lane's target applies and `:from` there would be
    /// `phrase_lane_bound`.
    fn lane(self: *Printer, l: Doc.Lane, indent: usize) Error!void {
        const in_phrase = indent > 0;
        try self.pad(indent);
        try self.raw("(lane :name ");
        try self.raw(l.name);
        // The discriminant is written BEFORE the keys it gates, which is
        // the manifest's own rule (a variant key ahead of its
        // discriminant is `unknown_key`).
        try self.raw(" :kind ");
        try self.raw(@tagName(l.kind));
        if (!in_phrase and !std.mem.eql(u8, l.target, l.name)) {
            try self.raw(" :target ");
            try self.raw(l.target);
        }
        if (l.binding) |b| try self.binding(b);
        if (l.range) |r| {
            try self.raw(" :range [");
            try self.single(r[0]);
            try self.raw(" ");
            try self.single(r[1]);
            try self.raw("]");
        }
        if (l.query_src) |q| {
            try self.raw(" :query ");
            try self.raw(q);
        }
        if (l.expr_src) |e| {
            try self.raw(" :expr ");
            try self.raw(e);
        }
        try self.children(l, indent);
        try self.raw(")");
    }

    fn binding(self: *Printer, b: Doc.Binding) Error!void {
        try self.raw(" :from ");
        try self.raw(b.anchor);
        switch (b.address) {
            .smf => |s| {
                try self.raw(" :track ");
                try self.int(s.track);
                try self.raw(" :ch ");
                try self.int(@as(u8, s.ch) + 1);
                if (s.key) |k| {
                    try self.raw(" :key ");
                    try self.int(k);
                }
                if (s.curve) |c| switch (c) {
                    .cc => |n| {
                        try self.raw(" :cc ");
                        try self.int(n);
                    },
                    .cc14 => |pair| {
                        try self.raw(" :cc [");
                        try self.int(pair[0]);
                        try self.raw(" ");
                        try self.int(pair[1]);
                        try self.raw("]");
                    },
                    .bend => try self.raw(" :bend true"),
                    .pressure => try self.raw(" :pressure true"),
                    .velocity => try self.raw(" :velocity true"),
                };
            },
            .it => |s| {
                try self.raw(" :channel ");
                try self.int(@as(u8, s.channel) + 1);
                if (s.column) |col| {
                    try self.raw(" :column ");
                    try self.raw(@tagName(col));
                }
                if (s.fx) |letter| {
                    try self.raw(" :fx ");
                    try self.string(&[_]u8{letter});
                }
            },
        }
    }

    /// A lane's children, on their own lines and SORTED BY `:at`.
    ///
    /// One interleaved stream, not three: a lane reads as the order it
    /// sounds in. Ties break by kind (note, keyframe, clip) and then by
    /// the order they were read, so the sort is total and the same value
    /// always prints the same bytes.
    fn children(self: *Printer, l: Doc.Lane, indent: usize) Error!void {
        const total = l.notes.len + l.keyframes.len + l.clips.len;
        if (total == 0) return;

        const order = try self.gpa.alloc(Child, total);
        defer self.gpa.free(order);
        var n: usize = 0;
        for (l.notes, 0..) |c, i| {
            order[n] = .{ .at = c.at, .kind = 0, .idx = @intCast(i) };
            n += 1;
        }
        for (l.keyframes, 0..) |c, i| {
            order[n] = .{ .at = c.at, .kind = 1, .idx = @intCast(i) };
            n += 1;
        }
        for (l.clips, 0..) |c, i| {
            order[n] = .{ .at = c.at, .kind = 2, .idx = @intCast(i) };
            n += 1;
        }
        std.mem.sort(Child, order, {}, Child.before);

        for (order) |c| {
            try self.raw("\n");
            try self.pad(indent + 2);
            switch (c.kind) {
                0 => try self.note(l.notes[c.idx]),
                1 => try self.keyframe(l.keyframes[c.idx]),
                else => try self.clip(l.clips[c.idx]),
            }
        }
    }

    const Child = struct {
        at: i64,
        kind: u2,
        idx: u32,

        fn before(_: void, a: Child, b: Child) bool {
            if (a.at != b.at) return a.at < b.at;
            if (a.kind != b.kind) return a.kind < b.kind;
            return a.idx < b.idx;
        }
    };

    fn note(self: *Printer, c: Doc.Note) Error!void {
        try self.raw("(note :at ");
        try self.pos(c.at);
        try self.raw(" :dur ");
        try self.pos(c.dur);
        try self.raw(" :key ");
        try self.int(c.key);
        if (c.vel != 100) {
            try self.raw(" :vel ");
            try self.int(c.vel);
        }
        if (c.ch != 0) {
            try self.raw(" :ch ");
            try self.int(@as(u8, c.ch) + 1);
        }
        if (c.off_vel) |v| {
            try self.raw(" :off-vel ");
            try self.int(v);
        }
        try self.raw(")");
    }

    fn keyframe(self: *Printer, c: Doc.Keyframe) Error!void {
        try self.raw("(keyframe :at ");
        try self.pos(c.at);
        try self.raw(" :value ");
        if (c.ncomp <= 1) {
            try self.single(c.value[0]);
        } else {
            try self.raw("[");
            for (c.value[0..c.ncomp], 0..) |v, i| {
                if (i > 0) try self.raw(" ");
                try self.single(v);
            }
            try self.raw("]");
        }
        if (!std.mem.eql(u8, c.ease_src, "linear")) {
            try self.raw(" :ease ");
            try self.raw(c.ease_src);
        }
        try self.raw(")");
    }

    fn clip(self: *Printer, c: Doc.Clip) Error!void {
        try self.raw("(clip :at ");
        try self.pos(c.at);
        try self.raw(" :phrase ");
        try self.raw(c.phrase);
        if (c.repeat != 1) {
            try self.raw(" :repeat ");
            try self.int(c.repeat);
        }
        if (c.offset != 0) {
            try self.raw(" :offset ");
            try self.pos(c.offset);
        }
        if (c.length) |len| {
            try self.raw(" :length ");
            try self.pos(len);
        }
        if (c.transpose != 0) {
            try self.raw(" :transpose ");
            try self.int(c.transpose);
        }
        try self.raw(")");
    }

    // ---- atoms ----------------------------------------------------------

    fn raw(self: *Printer, text: []const u8) Error!void {
        return self.out.appendSlice(self.gpa, text);
    }

    fn pad(self: *Printer, n: usize) Error!void {
        try self.out.appendNTimes(self.gpa, ' ', n);
    }

    fn string(self: *Printer, text: []const u8) Error!void {
        // SJON's own escaping, so a title with a quote or a newline in it
        // reads back as itself.
        return sjon.StringEscape.appendQuoted(self.out, self.gpa, text);
    }

    /// A tick, by plan 03's printer rule.
    fn pos(self: *Printer, tick: i64) Error!void {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        // `spell` writes at most a sign, 19 digits and a unit; the only
        // failure a fixed writer has is a full buffer, which this one
        // cannot reach.
        self.map.spell(&w, tick) catch unreachable;
        return self.raw(w.buffered());
    }

    fn int(self: *Printer, v: anytype) Error!void {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
        return self.raw(text);
    }

    fn double(self: *Printer, x: f64) Error!void {
        var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
        return self.raw(formatF64(&buf, x));
    }

    fn single(self: *Printer, x: f32) Error!void {
        var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
        return self.raw(formatF32(&buf, x));
    }
};

/// SJON's `Printer.formatNumberInto`, restated: an integral value under
/// the f64 exact-integer ceiling prints as an integer, and everything
/// else takes `{d}` — the shortest decimal that reads back as the same
/// float. Restated rather than called because that function is private
/// to SJON's printer; the test below pins the two against each other
/// through SJON's own parser.
fn formatF64(buf: []u8, x: f64) []const u8 {
    if (std.math.isNan(x)) return "nan";
    if (std.math.isInf(x)) return if (x > 0) "inf" else "-inf";
    const safe_int_max: f64 = @floatFromInt(@as(i64, 1) << 53);
    if (@floor(x) == x and @abs(x) < safe_int_max) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(x))}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d}", .{x}) catch unreachable;
}

/// The same rule for an f32 slot (`:value`, `:range`), formatted AS f32.
///
/// The width matters: `0.2` held as an f32 is not `0.2` held as an f64,
/// so `{d}` on the promoted double would print `0.20000000298023224`.
/// The shortest decimal that reads back as the same f32 is `0.2`, and
/// `repr f32` is what the slot declares — so the f32 is what is spelled.
fn formatF32(buf: []u8, x: f32) []const u8 {
    if (std.math.isNan(x)) return "nan";
    if (std.math.isInf(x)) return if (x > 0) "inf" else "-inf";
    const safe_int_max: f32 = @floatFromInt(@as(i32, 1) << 24);
    if (@floor(x) == x and @abs(x) < safe_int_max) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i32, @intFromFloat(x))}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d}", .{x}) catch unreachable;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// A loaded document and its print — the one fixture shape every test
/// below needs. The `Schema` stays the caller's, since it is the one
/// thing here that outlives everything built against it.
const Loaded = struct {
    res: fromSjon.Result,
    text: []u8,

    fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        self.res.deinit();
    }
};

/// Load `source`, require silence, and print it.
fn loaded(gpa: std.mem.Allocator, schema: *const Schema, source: [:0]const u8) !Loaded {
    var res = try fromSjon.fromSource(gpa, schema, source, null);
    errdefer res.deinit();
    if (res.diags.items().len != 0) {
        for (res.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
        return error.UnexpectedDiagnostics;
    }
    const text = try print(gpa, &res.doc, &res.map, .{});
    return .{ .res = res, .text = text };
}

/// The plan's own example, as `examples/native.sjon` ships it.
fn readExample(gpa: std.mem.Allocator) ![:0]u8 {
    const repo_root = @import("build_options").repo_root;
    const path = try std.fs.path.join(gpa, &.{ repo_root, "examples", "native.sjon" });
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);
    return gpa.dupeZ(u8, bytes);
}

test "toSjon: examples/native.sjon loads clean and prints every form it holds" {
    const gpa = testing.allocator;
    const source = try readExample(gpa);
    defer gpa.free(source);

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try loaded(gpa, &schema, source);
    defer fx.deinit(gpa);

    for ([_][]const u8{
        "(timeline ",
        "(anchor ",
        "(tempo-point ",
        "(meter-point ",
        "(section ",
        "(cue ",
        "(lane ",
        "(note ",
        "(keyframe ",
        "(clip ",
        "(phrase ",
        "(control ",
        "(target ",
    }) |form| {
        if (std.mem.indexOf(u8, fx.text, form) == null) {
            std.debug.print("\nthe print is missing {s}:\n{s}\n", .{ form, fx.text });
            return error.FormNotPrinted;
        }
    }
}

test "toSjon: the print reads back as the same document, field for field" {
    const gpa = testing.allocator;
    const source = try readExample(gpa);
    defer gpa.free(source);

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try loaded(gpa, &schema, source);
    defer fx.deinit(gpa);

    const reread = try gpa.dupeZ(u8, fx.text);
    defer gpa.free(reread);

    var again = try fromSjon.fromSource(gpa, &schema, reread, null);
    defer again.deinit();
    if (again.diags.items().len != 0) {
        for (again.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
        std.debug.print("text:\n{s}\n", .{fx.text});
        return error.PrintDoesNotReload;
    }

    if (!fx.res.doc.eql(&again.doc)) {
        std.debug.print("\nthe print does not read back as the same document:\n{s}\n", .{fx.text});
        return error.RoundTripDrifted;
    }
    try testing.expectEqual(fx.res.map.length, again.map.length);

    // …and printing it again is the same bytes: the canonical text is a
    // fixed point, not merely equivalent.
    const twice = try print(gpa, &again.doc, &again.map, .{});
    defer gpa.free(twice);
    try testing.expectEqualStrings(fx.text, twice);
}

test "toSjon: positions print by the rule — Nbar on a bar line, Nq when it terminates, else Nt" {
    const gpa = testing.allocator;

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try loaded(gpa, &schema,
        \\(timeline :length 16bar :end hold)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(cue :name "bar" :at 16bar)
        \\(cue :name "quarter" :at 2.5q)
        \\(cue :name "triplet" :at 15375360t)
    );
    defer fx.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, fx.text, ":at 16bar") != null);
    try testing.expect(std.mem.indexOf(u8, fx.text, ":at 2.5q") != null);
    try testing.expect(std.mem.indexOf(u8, fx.text, ":at 15375360t") != null);
    try testing.expect(std.mem.indexOf(u8, fx.text, ":length 16bar") != null);
}

test "toSjon: a tempo point keeps the spelling it was authored in" {
    const gpa = testing.allocator;

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try loaded(gpa, &schema,
        \\(timeline)
        \\(tempo-point :at 0q :qpm 125)
        \\(tempo-point :at 64bar :us 400000)
        \\(meter-point :at 0bar :sig [4 4])
    );
    defer fx.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, fx.text, "(tempo-point :at 0bar :qpm 125)") != null);
    try testing.expect(std.mem.indexOf(u8, fx.text, "(tempo-point :at 64bar :us 400000)") != null);
}

test "toSjon: a lane's children print sorted by :at" {
    const gpa = testing.allocator;

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try loaded(gpa, &schema,
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name glow :kind curve
        \\  (keyframe :at 8q :value 0.9)
        \\  (keyframe :at 0q :value 0.2))
    );
    defer fx.deinit(gpa);

    const first = std.mem.indexOf(u8, fx.text, ":at 0bar :value 0.2").?;
    const second = std.mem.indexOf(u8, fx.text, ":at 2bar :value 0.9").?;
    try testing.expect(first < second);
}

test "toSjon: the defaults the manifest declares are not printed back" {
    const gpa = testing.allocator;

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try loaded(gpa, &schema,
        \\(timeline :end hold)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name flash :kind notes :target flash
        \\  (note :at 0q :dur 1q :key 36 :vel 100 :ch 1)
        \\  (clip :at 4q :phrase fill :repeat 1 :transpose 0))
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash
        \\    (note :at 0q :dur 1q :key 38)))
    );
    defer fx.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, fx.text, ":vel") == null);
    try testing.expect(std.mem.indexOf(u8, fx.text, ":ch") == null);
    try testing.expect(std.mem.indexOf(u8, fx.text, ":repeat") == null);
    try testing.expect(std.mem.indexOf(u8, fx.text, ":transpose") == null);
    try testing.expect(std.mem.indexOf(u8, fx.text, ":ease") == null);
    // `:target` defaults to `:name`, a default the manifest cannot spell.
    try testing.expect(std.mem.indexOf(u8, fx.text, ":target") == null);
}

test "toSjon: a pass-through root is written back verbatim, comments and all" {
    const gpa = testing.allocator;

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try loaded(gpa, &schema,
        \\(timeline)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\; pacer's form, pass-through
        \\(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)
    );
    defer fx.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, fx.text, "; pacer's form, pass-through\n(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)") != null);
}

test "toSjon: the golden — plan 02's own example, canonically spelled" {
    // What the printer freezes: the reading order of plan 02's example
    // (header, anchors, the map, windows, points, lanes, phrases, the
    // pacer roots), positions by plan 03's spelling rule, and no default
    // written back. `:at 0q` prints `0bar` because tick 0 IS bar 0, and
    // `"C4"` prints `60` because a key is a number once it is read.
    //
    // The pass-through comment sits above `(target …)` rather than
    // beside `(control …)`: SJON attaches a comment to the node that
    // FOLLOWS it, so a trailing comment on one line becomes the leading
    // comment of the next root. The printer writes it where it was
    // attached, which is why printing the print is the same bytes.
    const gpa = testing.allocator;
    const source = try readExample(gpa);
    defer gpa.free(source);

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try loaded(gpa, &schema, source);
    defer fx.deinit(gpa);

    const golden =
        \\(timeline :title "impulsos" :length 128bar :end loop)
        \\
        \\(anchor :id song :kind it :file "impulse-04.it" :size 1284403 :sha256 "9f2a…")
        \\
        \\(tempo-point :at 0bar :qpm 125)
        \\(meter-point :at 0bar :sig [4 4])
        \\
        \\(section :name intro :at 0bar :dur 16bar)
        \\(section :name drop :at 16bar :dur 32bar)
        \\
        \\(cue :name "bar 41" :at 40bar)
        \\
        \\(lane :name kick :kind notes :from song :channel 3)
        \\(lane :name bass-vol :kind curve :from song :channel 5 :column vol :range [0 1])
        \\(lane :name flash :kind notes
        \\  (note :at 0bar :dur 0.5q :key 36 :vel 110)
        \\  (note :at 1q :dur 0.5q :key 60 :vel 90)
        \\  (clip :at 8bar :phrase fill :repeat 2))
        \\(lane :name glow :kind curve
        \\  (keyframe :at 0bar :value 0.2 :ease hold)
        \\  (keyframe :at 1bar :value 0.9 :ease in-cubic)
        \\  (keyframe :at 2bar :value [0.1 0.2 0.3] :ease (spring :damping 0.5)))
        \\(lane :name hats :kind query :query (euclid 3 8 1))
        \\(lane :name pulse :kind formula :expr (sin (* beat 6.2832)))
        \\
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash :kind notes
        \\    (note :at 0bar :dur 0.25q :key 38)
        \\    (note :at 0.5q :dur 0.25q :key 38 :vel 80)))
        \\
        \\(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)
        \\; pacer's form, pass-through
        \\(target :name glow :arity 1)
    ++ "\n";
    try testing.expectEqualStrings(golden, fx.text);
}
