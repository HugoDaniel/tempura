//! The values an action carries, in SJON's JSON encoding (§9).
//!
//! An edit action's `value` is a SJON value written as JSON: a united
//! number is `{"$num":[4,"bar"]}`, a symbol `{"$sym":"flash"}`, a form
//! `{"$form":"note","at":…}`. SJON decodes it through the JSON bridge and
//! PRINTS it, so what these writers spell is what lands in the document —
//! which is why a position goes through the same two functions the
//! canonical printer uses (`TimeMap.spell` for a position,
//! `TimeMap.spellDuration` for a duration measured from its form's own
//! `:at`, plan 03's frozen rule). An edit writes what the printer would
//! have written.
//!
//! Numbers are spelled by `Pos`'s own printer and copied VERBATIM into
//! the JSON — the text `Pos.spell` produces is a valid JSON number
//! followed by the unit — so nothing here re-rounds a position on its way
//! to the document.

const std = @import("std");
const sjon = @import("sjon");

const Pos = @import("../time/Pos.zig");
const TimeMap = @import("../time/TimeMap.zig");

const testing = std.testing;

/// This module, so `Form`'s methods can name the free writers whose
/// names they reuse.
const vals = @This();

pub const Error = error{OutOfMemory};

/// The scratch buffer every writer appends to.
pub const Buf = std.ArrayList(u8);

/// A POSITION: `{"$num":[n,"unit"]}`, spelled by the map's rule — a bar
/// line as `Nbar`, else `Nq`, else `Nt`.
pub fn position(gpa: std.mem.Allocator, out: *Buf, map: *const TimeMap.TimeMap, tick: i64) Error!void {
    var text: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    // `spell` writes at most a sign, nineteen digits and a unit; the only
    // failure a fixed writer has is a full buffer, which this one cannot
    // reach (the canonical printer sizes its own the same way).
    map.spell(&w, tick) catch unreachable;
    try literal(gpa, out, w.buffered());
}

/// A DURATION measured from `at`: `Nbar` when both ends sit on bar
/// lines, else the delta's own `Nq` / `Nt`.
pub fn duration(gpa: std.mem.Allocator, out: *Buf, map: *const TimeMap.TimeMap, ticks: i64, at: i64) Error!void {
    var text: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    map.spellDuration(&w, ticks, at) catch unreachable;
    try literal(gpa, out, w.buffered());
}

/// A spelled literal — `2.5q`, `16bar`, `40960t` — as `{"$num":[…]}`.
/// The number part is copied verbatim: it is already the decimal that
/// reads back as this tick, and re-printing an f64 could only lose it.
pub fn literal(gpa: std.mem.Allocator, out: *Buf, text: []const u8) Error!void {
    var split = text.len;
    while (split > 0 and std.ascii.isAlphabetic(text[split - 1])) split -= 1;
    try out.print(gpa, "{{\"$num\":[{s},\"{s}\"]}}", .{ text[0..split], text[split..] });
}

/// A symbol: a lane's name, a phrase's name, an anchor's id — every
/// identifier in the timeline vocabulary.
pub fn symbol(gpa: std.mem.Allocator, out: *Buf, text: []const u8) Error!void {
    try out.appendSlice(gpa, "{\"$sym\":");
    try string(gpa, out, text);
    try out.append(gpa, '}');
}

/// A JSON string, escaped.
pub fn string(gpa: std.mem.Allocator, out: *Buf, text: []const u8) Error!void {
    try out.append(gpa, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (c < 0x20)
            try out.print(gpa, "\\u{X:0>4}", .{c})
        else
            try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

/// An integer.
pub fn integer(gpa: std.mem.Allocator, out: *Buf, v: i64) Error!void {
    try out.print(gpa, "{d}", .{v});
}

/// One f32 component, in the shortest decimal that reads back as itself.
/// f32 and not f64 deliberately: the document's values ARE f32 (pacer's
/// determinism seam), and widening one to print it would spell
/// `0.20000000298023224` where the author wrote `0.2`.
pub fn float(gpa: std.mem.Allocator, out: *Buf, v: f32) Error!void {
    try out.print(gpa, "{d}", .{v});
}

/// A keyframe's value: a scalar, or a vector of `ncomp` components.
pub fn components(gpa: std.mem.Allocator, out: *Buf, v: [4]f32, ncomp: u3) Error!void {
    if (ncomp <= 1) return float(gpa, out, v[0]);
    try out.append(gpa, '[');
    for (v[0..@min(ncomp, 4)], 0..) |c, i| {
        if (i > 0) try out.append(gpa, ',');
        try float(gpa, out, c);
    }
    try out.append(gpa, ']');
}

/// One key an existing form is re-spelled with: the JSON to put under
/// `key`, or null to leave the key out.
pub const Override = struct { key: []const u8, json: ?[]const u8 };

/// A node of a parsed document, as JSON (§9).
///
/// This is how an operation COPIES a form it is moving: the node goes out
/// through the JSON bridge with every key the author wrote and none this
/// engine invented, which is as faithful as an insert can be. What JSON
/// has no channel for is trivia — the comments on a moved node are lost,
/// plan 07's own risk, which is why every operation that can prefers
/// `set_keyword` to a remove and an insert.
pub fn node(gpa: std.mem.Allocator, out: *Buf, tree: *const sjon.Ast.Tree, idx: sjon.Ast.NodeIndex) Error!void {
    switch (tree.tagOf(idx)) {
        .nil => try out.appendSlice(gpa, "null"),
        .boolean_true => try out.appendSlice(gpa, "true"),
        .boolean_false => try out.appendSlice(gpa, "false"),
        .number => try out.print(gpa, "{d}", .{tree.numberOf(idx)}),
        .number_i64 => try out.print(gpa, "{d}", .{tree.numberI64Of(idx)}),
        .number_u64 => try out.print(gpa, "{d}", .{tree.numberU64Of(idx)}),
        .number_with_unit => {
            const nu = tree.numberWithUnitOf(idx);
            try out.print(gpa, "{{\"$num\":[{d},", .{nu.value});
            try string(gpa, out, nu.unit);
            try out.append(gpa, ']');
            try out.append(gpa, '}');
        },
        .string => try string(gpa, out, tree.stringText(idx)),
        .symbol => try symbol(gpa, out, tree.symbolText(idx)),
        .keyword => {
            try out.appendSlice(gpa, "{\"$kw\":");
            try string(gpa, out, tree.keywordText(idx));
            try out.append(gpa, '}');
        },
        .vector => {
            try out.append(gpa, '[');
            for (tree.vectorElements(idx), 0..) |e, i| {
                if (i > 0) try out.append(gpa, ',');
                try node(gpa, out, tree, e);
            }
            try out.append(gpa, ']');
        },
        .form => try form(gpa, out, tree, idx, &.{}),
        // A kvpair has no JSON value of its own — it is a member of its
        // form's object (§9) — and the date and time kinds this
        // vocabulary never spells go out as their own source bytes.
        .kvpair => unreachable,
        else => {
            const span = tree.spanOf(idx);
            try string(gpa, out, tree.source[span.start..span.end]);
        },
    }
}

/// A form of a parsed document, as JSON, with `overrides` applied.
///
/// An override whose key the form already carries replaces that value in
/// PLACE, so the key order the author chose survives the round trip; one
/// it does not carry is appended. A null override drops the key.
pub fn form(
    gpa: std.mem.Allocator,
    out: *Buf,
    tree: *const sjon.Ast.Tree,
    idx: sjon.Ast.NodeIndex,
    overrides: []const Override,
) Error!void {
    const hdr = tree.formHeader(idx);
    try out.appendSlice(gpa, "{\"$form\":");
    try string(gpa, out, hdr.head);
    if (hdr.namespace) |ns| {
        try out.appendSlice(gpa, ",\"$ns\":");
        try string(gpa, out, ns);
    }

    var written = try std.DynamicBitSet.initEmpty(gpa, overrides.len);
    defer written.deinit();

    for (hdr.children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        var json: ?[]const u8 = null;
        var overridden = false;
        for (overrides, 0..) |o, i| {
            if (!std.mem.eql(u8, o.key, kv.key)) continue;
            overridden = true;
            written.set(i);
            json = o.json;
        }
        if (overridden and json == null) continue;
        try out.append(gpa, ',');
        try string(gpa, out, kv.key);
        try out.append(gpa, ':');
        if (json) |text| try out.appendSlice(gpa, text) else try node(gpa, out, tree, kv.value);
    }
    for (overrides, 0..) |o, i| {
        if (written.isSet(i)) continue;
        const text = o.json orelse continue;
        try out.append(gpa, ',');
        try string(gpa, out, o.key);
        try out.append(gpa, ':');
        try out.appendSlice(gpa, text);
    }

    var kids: usize = 0;
    for (hdr.children) |child| {
        if (tree.tagOf(child) == .kvpair) continue;
        if (kids == 0) try out.appendSlice(gpa, ",\"$children\":[") else try out.append(gpa, ',');
        try node(gpa, out, tree, child);
        kids += 1;
    }
    if (kids > 0) try out.append(gpa, ']');
    try out.append(gpa, '}');
}

/// A fragment of SJON SOURCE — a pacer `ease-spec`, `in-cubic` or
/// `(spring :damping 0.5)` — as JSON. False when the text is not one
/// value; the caller refuses with the span it came from.
pub fn source(gpa: std.mem.Allocator, out: *Buf, text: []const u8) Error!bool {
    const owned = try gpa.dupeZ(u8, text);
    defer gpa.free(owned);
    var tree = try sjon.parse(gpa, owned);
    defer tree.deinit();
    if (tree.hasErrors() or tree.root.len != 1) return false;
    try node(gpa, out, &tree, tree.root[0]);
    return true;
}

/// A form, built key by key in the order the schema declares them.
///
/// `(note :at 0bar :dur 0.5q :key 36 :vel 110)` is
/// `{"$form":"note","at":{"$num":[0,"bar"]},…}` — kvpairs become object
/// keys and positional children gather into `$children` (§9), which is
/// exactly the shape every form this engine inserts has.
pub const Form = struct {
    gpa: std.mem.Allocator,
    buf: Buf = .empty,
    keys: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, head: []const u8) Error!Form {
        var self: Form = .{ .gpa = gpa };
        errdefer self.deinit();
        try self.buf.appendSlice(gpa, "{\"$form\":");
        try vals.string(gpa, &self.buf, head);
        return self;
    }

    pub fn deinit(self: *Form) void {
        self.buf.deinit(self.gpa);
        self.* = undefined;
    }

    /// The finished JSON. Borrowed from this form until `deinit`.
    pub fn done(self: *Form) Error![]const u8 {
        try self.buf.append(self.gpa, '}');
        return self.buf.items;
    }

    fn key(self: *Form, name: []const u8) Error!void {
        try self.buf.append(self.gpa, ',');
        try vals.string(self.gpa, &self.buf, name);
        try self.buf.append(self.gpa, ':');
        self.keys += 1;
    }

    pub fn position(self: *Form, name: []const u8, map: *const TimeMap.TimeMap, tick: i64) Error!void {
        try self.key(name);
        try vals.position(self.gpa, &self.buf, map, tick);
    }

    pub fn duration(self: *Form, name: []const u8, map: *const TimeMap.TimeMap, ticks: i64, at: i64) Error!void {
        try self.key(name);
        try vals.duration(self.gpa, &self.buf, map, ticks, at);
    }

    pub fn symbol(self: *Form, name: []const u8, text: []const u8) Error!void {
        try self.key(name);
        try vals.symbol(self.gpa, &self.buf, text);
    }

    pub fn string(self: *Form, name: []const u8, text: []const u8) Error!void {
        try self.key(name);
        try vals.string(self.gpa, &self.buf, text);
    }

    pub fn integer(self: *Form, name: []const u8, v: i64) Error!void {
        try self.key(name);
        try vals.integer(self.gpa, &self.buf, v);
    }

    pub fn float(self: *Form, name: []const u8, v: f32) Error!void {
        try self.key(name);
        try vals.float(self.gpa, &self.buf, v);
    }

    pub fn components(self: *Form, name: []const u8, v: [4]f32, ncomp: u3) Error!void {
        try self.key(name);
        try vals.components(self.gpa, &self.buf, v, ncomp);
    }

    /// A value already spelled as JSON — a pacer `ease-spec`, a vector.
    pub fn raw(self: *Form, name: []const u8, json: []const u8) Error!void {
        try self.key(name);
        try self.buf.appendSlice(self.gpa, json);
    }

    /// The form's positional children, as `$children`.
    pub fn children(self: *Form, json_values: []const []const u8) Error!void {
        try self.key("$children");
        try self.buf.append(self.gpa, '[');
        for (json_values, 0..) |v, i| {
            if (i > 0) try self.buf.append(self.gpa, ',');
            try self.buf.appendSlice(self.gpa, v);
        }
        try self.buf.append(self.gpa, ']');
    }
};

// ---------------------------------------------------------------------------

fn fourFour(gpa: std.mem.Allocator) !TimeMap.Result {
    return TimeMap.derive(
        gpa,
        &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }},
        &.{.{ .tick = 0, .n = 4, .d = 4 }},
        32 * @import("../time/Grid.zig").TPQ,
        .hold,
    );
}

test "value: a position is the printer's own spelling, verbatim" {
    const gpa = testing.allocator;
    const q = @import("../time/Grid.zig").TPQ;
    var res = try fourFour(gpa);
    defer res.deinit();

    var out: Buf = .empty;
    defer out.deinit(gpa);

    try position(gpa, &out, &res.map, 0);
    try testing.expectEqualStrings("{\"$num\":[0,\"bar\"]}", out.items);

    out.clearRetainingCapacity();
    try position(gpa, &out, &res.map, @divExact(q, 2));
    try testing.expectEqualStrings("{\"$num\":[0.5,\"q\"]}", out.items);

    out.clearRetainingCapacity();
    try position(gpa, &out, &res.map, 4 * q);
    try testing.expectEqualStrings("{\"$num\":[1,\"bar\"]}", out.items);

    out.clearRetainingCapacity();
    try position(gpa, &out, &res.map, 1);
    try testing.expectEqualStrings("{\"$num\":[1,\"t\"]}", out.items);

    // A duration is anchored at its own form's `:at`: one bar from a bar
    // line is `1bar`, and the same count from inside a bar is quarters.
    out.clearRetainingCapacity();
    try duration(gpa, &out, &res.map, 4 * q, 0);
    try testing.expectEqualStrings("{\"$num\":[1,\"bar\"]}", out.items);

    out.clearRetainingCapacity();
    try duration(gpa, &out, &res.map, 4 * q, q);
    try testing.expectEqualStrings("{\"$num\":[4,\"q\"]}", out.items);
}

test "value: a form is spelled in the order its keys were added" {
    const gpa = testing.allocator;
    const q = @import("../time/Grid.zig").TPQ;
    var res = try fourFour(gpa);
    defer res.deinit();

    var f = try Form.init(gpa, "note");
    defer f.deinit();
    try f.position("at", &res.map, q);
    try f.duration("dur", &res.map, @divExact(q, 2), q);
    try f.integer("key", 36);
    try f.integer("vel", 110);

    try testing.expectEqualStrings(
        \\{"$form":"note","at":{"$num":[1,"q"]},"dur":{"$num":[0.5,"q"]},"key":36,"vel":110}
    , try f.done());
}

test "value: strings escape, symbols carry, f32 keeps the author's decimal" {
    const gpa = testing.allocator;
    var out: Buf = .empty;
    defer out.deinit(gpa);

    try string(gpa, &out, "a \"quoted\" name\n");
    try testing.expectEqualStrings("\"a \\\"quoted\\\" name\\n\"", out.items);

    out.clearRetainingCapacity();
    try symbol(gpa, &out, "flash");
    try testing.expectEqualStrings("{\"$sym\":\"flash\"}", out.items);

    out.clearRetainingCapacity();
    try components(gpa, &out, .{ 0.2, 0, 0, 0 }, 1);
    try testing.expectEqualStrings("0.2", out.items);

    out.clearRetainingCapacity();
    try components(gpa, &out, .{ 0.1, 0.2, 0.3, 0 }, 3);
    try testing.expectEqualStrings("[0.1,0.2,0.3]", out.items);
}
