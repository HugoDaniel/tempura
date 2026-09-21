//! What an operation acts on (plan 07, "Selection").
//!
//! A `Select` is a QUESTION — which lanes, which ticks, which kinds,
//! which keys — and `resolve` answers it against a `Doc` with an ordered
//! list of targets. The order is the plan's determinism rule: lanes in
//! document order, then tick, then kind, so the same document and the
//! same question give the same actions in the same order on every host.
//!
//! What resolves here is NATIVE content: the notes, keyframes and clips a
//! lane carries itself, and the sections and cues of the document's own
//! roots. A lane the selection NAMES whose content lives in an anchor's
//! file resolves to nothing editable and hands its span back as `bound` —
//! the caller turns that into `edit_target_bound`, which is where the
//! span belongs. A selection over EVERY lane skips a bound one in
//! silence: "quantise the song" is not a question about the file.
//!
//! A phrase's own lanes are not reachable from here. A phrase is placed
//! by a clip and edited as a phrase; `rename` is the one operation that
//! looks inside one, and it does so by name rather than by selection.

const std = @import("std");

const Diag = @import("../Diag.zig");
const Grid = @import("../time/Grid.zig");
const doc = @import("../doc/doc.zig");

const testing = std.testing;

pub const Error = error{OutOfMemory};

/// What a target is. The five editable shapes of plan 07's selection.
pub const Kind = enum { note, keyframe, clip, section, cue };

/// Which kinds a selection takes. A set rather than one kind because an
/// editor's rubber band takes whatever it covers.
pub const Kinds = struct {
    note: bool = false,
    keyframe: bool = false,
    clip: bool = false,
    section: bool = false,
    cue: bool = false,

    /// Everything a lane or a root can hold.
    pub const all: Kinds = .{ .note = true, .keyframe = true, .clip = true, .section = true, .cue = true };
    /// The lane children alone — what a quantize or a nudge means.
    pub const children: Kinds = .{ .note = true, .keyframe = true, .clip = true };
    pub const notes: Kinds = .{ .note = true };
    pub const keyframes: Kinds = .{ .keyframe = true };
    pub const clips: Kinds = .{ .clip = true };

    pub fn has(self: Kinds, kind: Kind) bool {
        return switch (kind) {
            .note => self.note,
            .keyframe => self.keyframe,
            .clip => self.clip,
            .section => self.section,
            .cue => self.cue,
        };
    }

    pub fn any(self: Kinds) bool {
        return self.note or self.keyframe or self.clip or self.section or self.cue;
    }
};

/// The selection.
///
/// `lanes` and `keys` are `const` slices where the brief spells them
/// mutable: nothing here writes through them, and a caller building one
/// from a literal (`&.{"flash"}`) would otherwise have to allocate to
/// ask a question.
pub const Select = struct {
    /// The lanes by name, or null for every lane in the document.
    lanes: ?[]const []const u8 = null,
    /// `[from, to)` in ticks, or null for the whole timeline. A target is
    /// in range when its ONSET is: an operation moves onsets, and a note
    /// that merely sounds through a window was not selected by it.
    range: ?[2]i64 = null,
    kinds: Kinds = .all,
    /// Note keys to keep, or null for every key. Only notes carry one, so
    /// nothing else is narrowed by it.
    keys: ?[]const u7 = null,

    /// Whether `tick` is inside the range.
    pub fn covers(self: Select, tick: i64) bool {
        const r = self.range orelse return true;
        return tick >= r[0] and tick < r[1];
    }
};

/// One thing to edit.
pub const Target = struct {
    kind: Kind,
    /// Which lane holds it, indexing `doc.lanes`; null for a root.
    lane: ?u32,
    /// Which item of that lane's `notes` / `keyframes` / `clips`, or of
    /// the document's `sections` / `cues`.
    item: u32,
    at: i64,
    /// How long it lasts: a note's or a section's `:dur`, a clip's
    /// window, and 0 for the two that are points.
    dur: i64,
    key: ?u7,
    /// The form's own span — the address this resolves to, once a
    /// `locate.Map` is asked.
    span: Diag.Span,
};

/// What `resolve` answers.
pub const Resolved = struct {
    targets: []const Target,
    /// The span of the first lane the selection NAMED whose content is
    /// bound to an anchor. The caller reports `edit_target_bound` on it.
    bound: ?Diag.Span,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Resolved) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Resolve `sel` against `d`.
///
/// A lane filter is a question about LANE CONTENT, so the two root kinds
/// answer only when there is none: `lanes = null` reaches the sections
/// and cues, `lanes = &.{"flash"}` does not.
///
/// Complexity: O(n log n) over the content the filters kept — one pass to
/// collect, one stable sort into the plan's order.
pub fn resolve(gpa: std.mem.Allocator, d: *const doc.Doc, sel: Select) Error!Resolved {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    var list: std.ArrayList(Target) = .empty;
    var bound: ?Diag.Span = null;

    for (d.lanes, 0..) |lane, li| {
        if (!wanted(sel.lanes, lane.name)) continue;
        if (lane.binding != null) {
            // Named, and its content is the anchor's. Unnamed — a
            // selection over every lane — it is simply not this
            // operation's business.
            if (sel.lanes != null and bound == null) bound = lane.span;
            continue;
        }
        try laneTargets(arena.allocator(), &list, d, lane, @intCast(li), sel);
    }
    if (sel.lanes == null) try rootTargets(arena.allocator(), &list, d, sel);

    const targets = try list.toOwnedSlice(arena.allocator());
    // Stable, so two targets the key cannot separate keep the order they
    // were read in — which is document order.
    std.sort.insertion(Target, targets, @as(usize, d.lanes.len), lessThan);
    return .{ .targets = targets, .bound = bound, .arena = arena };
}

/// The notes, keyframes and clips of one native lane that the range,
/// the kinds and the keys keep, appended to `list` in the order the
/// lane holds them. `idx` is the lane's index in `d.lanes`.
fn laneTargets(
    arena: std.mem.Allocator,
    list: *std.ArrayList(Target),
    d: *const doc.Doc,
    lane: doc.Lane,
    idx: u32,
    sel: Select,
) Error!void {
    if (sel.kinds.note) for (lane.notes, 0..) |n, i| {
        if (!sel.covers(n.at)) continue;
        if (!keyWanted(sel.keys, n.key)) continue;
        try list.append(arena, .{
            .kind = .note,
            .lane = idx,
            .item = @intCast(i),
            .at = n.at,
            .dur = n.dur,
            .key = n.key,
            .span = n.span,
        });
    };
    if (sel.kinds.keyframe) for (lane.keyframes, 0..) |k, i| {
        if (!sel.covers(k.at)) continue;
        try list.append(arena, .{
            .kind = .keyframe,
            .lane = idx,
            .item = @intCast(i),
            .at = k.at,
            .dur = 0,
            .key = null,
            .span = k.span,
        });
    };
    if (sel.kinds.clip) for (lane.clips, 0..) |c, i| {
        if (!sel.covers(c.at)) continue;
        try list.append(arena, .{
            .kind = .clip,
            .lane = idx,
            .item = @intCast(i),
            .at = c.at,
            .dur = clipWindow(d, c),
            .key = null,
            .span = c.span,
        });
    };
}

/// The sections and cues the range and the kinds keep, appended to
/// `list` in document order. Only reached by a selection that names no
/// lane: a lane filter is a question about LANE CONTENT, and the two
/// root kinds answer only when there is none.
fn rootTargets(
    arena: std.mem.Allocator,
    list: *std.ArrayList(Target),
    d: *const doc.Doc,
    sel: Select,
) Error!void {
    if (sel.kinds.section) for (d.sections, 0..) |s, i| {
        if (!sel.covers(s.at)) continue;
        try list.append(arena, .{
            .kind = .section,
            .lane = null,
            .item = @intCast(i),
            .at = s.at,
            .dur = s.dur,
            .key = null,
            .span = s.span,
        });
    };
    if (sel.kinds.cue) for (d.cues, 0..) |c, i| {
        if (!sel.covers(c.at)) continue;
        try list.append(arena, .{
            .kind = .cue,
            .lane = null,
            .item = @intCast(i),
            .at = c.at,
            .dur = 0,
            .key = null,
            .span = c.span,
        });
    };
}

/// The plan's determinism rule: lanes in document order (the roots after
/// them, since they belong to no lane), then tick, then kind, then the
/// item's own place in the document.
fn lessThan(lane_count: usize, x: Target, y: Target) bool {
    const gx = x.lane orelse @as(u32, @intCast(lane_count));
    const gy = y.lane orelse @as(u32, @intCast(lane_count));
    if (gx != gy) return gx < gy;
    if (x.at != y.at) return x.at < y.at;
    if (x.kind != y.kind) return @intFromEnum(x.kind) < @intFromEnum(y.kind);
    return x.item < y.item;
}

fn wanted(names: ?[]const []const u8, name: []const u8) bool {
    const list = names orelse return true;
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Whether `key` survives a selection's key filter — null is every key.
/// Public because `edit/ops_bound.zig` asks the same question of a
/// bound lane's notes, which resolve outside this file, and two copies
/// of one filter are two answers waiting to differ.
pub fn keyWanted(keys: ?[]const u7, key: u7) bool {
    const list = keys orelse return true;
    for (list) |k| {
        if (k == key) return true;
    }
    return false;
}

/// A clip's window: its own `:length`, or the phrase's length times
/// `:repeat` less `:offset` — the schema's own default, spelled out
/// because a split needs the number and the document need not carry it.
///
/// The default is USER arithmetic, as `time/derive.place` says of the
/// same product: `:repeat` has no maximum in the manifest and a phrase's
/// `:length` reaches to the grid ceiling, so `length · repeat` does not
/// fit an `i64` in general. The window is formed with the derivation's
/// own saturating operators and then pinned at `Grid.MAX_TICK`: the
/// derivation places nothing past the ceiling (plan 03), so no clip's
/// editable window is longer than that, and a target whose `at` and
/// `dur` are both on the grid keeps every consumer's `at + dur` inside
/// the domain it was written for.
fn clipWindow(d: *const doc.Doc, c: doc.Clip) i64 {
    if (c.length) |l| return l;
    const phrase = d.phraseByName(c.phrase) orelse return 0;
    const repeat: i64 = @max(1, c.repeat);
    const window = (phrase.length *| repeat) -| c.offset;
    return std.math.clamp(window, 0, Grid.MAX_TICK);
}

// ---------------------------------------------------------------------------

const test_support = @import("test_support.zig");

test "Select: every kind, in lane order then tick then kind" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    var r = try resolve(gpa, fx.doc_(), .{});
    defer r.deinit();

    try testing.expect(r.bound == null);
    // flash: three notes and a clip; glow: two keyframes; then the two
    // roots. The bound lane contributes nothing.
    try testing.expectEqual(@as(usize, 8), r.targets.len);

    const want = [_]struct { Kind, ?u32, u32 }{
        .{ .note, 0, 0 },
        .{ .note, 0, 1 },
        .{ .note, 0, 2 },
        .{ .clip, 0, 0 },
        .{ .keyframe, 1, 0 },
        .{ .keyframe, 1, 1 },
        .{ .section, null, 0 },
        .{ .cue, null, 0 },
    };
    for (want, r.targets) |w, got| {
        try testing.expectEqual(w[0], got.kind);
        try testing.expectEqual(w[1], got.lane);
        try testing.expectEqual(w[2], got.item);
    }
}

test "Select: lanes, a half-open range and a key filter each narrow it" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    const q = Grid.TPQ;

    // One lane, the first two quarter notes, notes only.
    {
        var r = try resolve(gpa, fx.doc_(), .{
            .lanes = &.{"flash"},
            .range = .{ 0, 2 * q },
            .kinds = .notes,
        });
        defer r.deinit();
        try testing.expectEqual(@as(usize, 2), r.targets.len);
        try testing.expectEqual(@as(i64, 0), r.targets[0].at);
        try testing.expectEqual(@as(i64, q), r.targets[1].at);
    }

    // The range is half-open: the note at 2q is out of `[0, 2q)`.
    {
        var r = try resolve(gpa, fx.doc_(), .{ .lanes = &.{"flash"}, .range = .{ 2 * q, 3 * q } });
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.targets.len);
        try testing.expectEqual(@as(i64, 2 * q), r.targets[0].at);
    }

    // Keys narrow notes and nothing else.
    {
        var r = try resolve(gpa, fx.doc_(), .{ .lanes = &.{"flash"}, .keys = &.{36} });
        defer r.deinit();
        try testing.expectEqual(@as(usize, 3), r.targets.len);
        try testing.expectEqual(Kind.note, r.targets[0].kind);
        try testing.expectEqual(@as(u7, 36), r.targets[0].key.?);
        try testing.expectEqual(@as(u7, 36), r.targets[1].key.?);
        try testing.expectEqual(Kind.clip, r.targets[2].kind);
    }
}

test "Select: a named bound lane hands back its span, and an unnamed one is skipped" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    var named = try resolve(gpa, fx.doc_(), .{ .lanes = &.{"kick"} });
    defer named.deinit();
    try testing.expectEqual(@as(usize, 0), named.targets.len);
    const lane = fx.doc_().lanes[2];
    try testing.expectEqual(lane.span, named.bound.?);

    var every = try resolve(gpa, fx.doc_(), .{});
    defer every.deinit();
    try testing.expect(every.bound == null);
}

test "Select: a lane no document declares selects nothing" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    var r = try resolve(gpa, fx.doc_(), .{ .lanes = &.{"nope"} });
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.targets.len);
    try testing.expect(r.bound == null);
}

test "Select: a clip whose repeats do not fit an i64 resolves to a window on the grid, not a panic" {
    // `:length 9007199254740990t` is two ticks under the ceiling and
    // `:repeat 2000` is a number the manifest allows, so the product is
    // user arithmetic no `i64` holds — and `resolve` is what every
    // selection-taking operation runs first, so the overflow used to
    // abort a `remove` of the clip before a single action was planned.
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.wide_clip);
    defer fx.deinit();

    var r = try resolve(gpa, fx.doc_(), .{ .lanes = &.{"flash"}, .kinds = .clips });
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.targets.len);
    try testing.expectEqual(Kind.clip, r.targets[0].kind);
    // The derivation's own window, pinned at the ceiling: saturated and
    // then bounded, never wrapped.
    try testing.expectEqual(Grid.MAX_TICK, r.targets[0].dur);
    try testing.expect(r.targets[0].at +| r.targets[0].dur > r.targets[0].at);
}
