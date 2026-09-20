//! The plan: what an operation would do to a document, as SJON edit
//! actions, and nothing done yet.
//!
//! `plan` is a pure function from a document and an operation to this
//! value (plan 07, "The contract"). It never mutates, it is TOTAL — an
//! operation that cannot be done yields an empty action list and a
//! diagnostic with the span of the node it refused on — and it is
//! deterministic: the same document and the same operation give the same
//! actions in the same order, which is what lets the corpus pin a plan
//! as text.
//!
//! An `Action` is one of SJON's eight structural operations
//! (`SJON/docs/LANGUAGE.md` §11.1) in its JSON action grammar, carried
//! HERE AS TEXT. Text and not `std.json.Value` because the plan is a
//! value a host reads, prints, diffs and pins: the corpus golden for an
//! `edit-*` case is exactly `Plan.text()`, and a tree of `ObjectMap`s
//! would have to be rendered to be compared anyway. `apply` parses each
//! action back on its way into SJON, which costs one small parse per
//! action and buys a plan that is readable wherever it travels.
//!
//! Beside the text each action carries the three facts `apply` sequences
//! by — which of the eight operations it is, the address it acts on, and
//! the slot it names — so the sequencing never re-parses to find out.

const std = @import("std");

const Diag = @import("../Diag.zig");
const locate = @import("locate.zig");

const Site = locate.Site;
const testing = std.testing;

/// Only resource exhaustion, the part-wide rule: every defect of a
/// document or an operation is a diagnostic on the returned plan.
pub const Error = error{OutOfMemory};

/// Which of SJON's eight structural operations an action is (§11.1).
pub const Kind = enum {
    set_keyword,
    remove_keyword,
    replace,
    wrap,
    insert_positional,
    remove_positional,
    insert_root,
    remove_root,

    /// The action's name in the grammar.
    pub fn text(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// One SJON edit action.
pub const Action = struct {
    /// The action in §11.1's JSON grammar, one line, arena-owned.
    json: []const u8,
    kind: Kind,
    /// For the six pathed operations: the address the action acts on —
    /// the target for `set_keyword` / `remove_keyword` / `replace` /
    /// `wrap`, the CONTAINER for the two positional ones. The two forest
    /// operations carry the root list's own empty address and say
    /// everything in `slot`.
    site: Site,
    /// The child slot a positional operation names, or the root slot a
    /// forest one does. Null for the four that name a node outright.
    slot: ?u32,
};

/// What the plan does, in counts — enough for a host to say "moved 4
/// notes" without reading a single action.
pub const Summary = struct {
    /// How many targets the operation resolved.
    targets: u32 = 0,
    /// `set_keyword` and `remove_keyword` actions.
    set: u32 = 0,
    /// `insert_positional` and `insert_root` actions.
    inserted: u32 = 0,
    /// `remove_positional` and `remove_root` actions.
    removed: u32 = 0,
    /// `replace` and `wrap` actions.
    replaced: u32 = 0,
    /// Positions that had to be rounded onto the grid — the count
    /// `edit_inexact` carries.
    inexact: u32 = 0,
    /// The plan is a refusal: no actions, and a diagnostic says why.
    refused: bool = false,
};

/// The plan itself. Arena-backed like every value in this repo: one
/// `deinit` frees the actions, their text and their paths.
pub const Plan = struct {
    actions: []const Action,
    diags: Diag.List,
    summary: Summary,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.diags.deinit();
        self.* = undefined;
    }

    /// The actions as one JSON array, one action per line — what the CLI
    /// prints, what a corpus case pins, and what SJON's
    /// `applyEditsFromJsonString` would take whole. Caller frees.
    pub fn text(self: *const Plan, gpa: std.mem.Allocator) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (self.actions.len == 0) {
            try out.appendSlice(gpa, "[]\n");
            return out.toOwnedSlice(gpa);
        }
        try out.appendSlice(gpa, "[\n");
        for (self.actions, 0..) |action, i| {
            try out.appendSlice(gpa, action.json);
            if (i + 1 < self.actions.len) try out.append(gpa, ',');
            try out.append(gpa, '\n');
        }
        try out.appendSlice(gpa, "]\n");
        return out.toOwnedSlice(gpa);
    }

    /// The first diagnostic carrying `code`, or null. The test helper;
    /// hosts walk `diags.items()`.
    pub fn findDiag(self: *const Plan, code: Diag.Code) ?Diag.Diagnostic {
        for (self.diags.items()) |d| {
            if (d.code == code) return d;
        }
        return null;
    }
};

/// Collects actions into a plan.
///
/// Every append is a no-op once the builder has REFUSED: a planner reads
/// its targets in one pass and refuses in the middle of it, and a refusal
/// is an empty action list by definition (plan 07, "The contract"), so
/// poisoning the builder is what keeps a planner free of early returns.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    diags: Diag.List,
    actions: std.ArrayList(Action) = .empty,
    summary: Summary = .{},
    /// Whether `finish` has handed the arena and the diagnostics to a
    /// `Plan`. A finished builder owns nothing, so `deinit` is a no-op —
    /// which is what makes the `errdefer b.deinit()` a planner opens with
    /// safe beside the `defer p.deinit()` its caller closes with.
    finished: bool = false,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa, .arena = .init(gpa), .diags = .init(gpa) };
    }

    /// Release a builder that will never be finished (an error path).
    pub fn deinit(self: *Builder) void {
        if (self.finished) return;
        self.arena.deinit();
        self.diags.deinit();
        self.finished = true;
    }

    /// The arena every action's text and path live in.
    pub fn allocator(self: *Builder) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn setKeyword(self: *Builder, site: Site, key: []const u8, value_json: []const u8) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.set_keyword, site);
        try out.print(self.gpa, ",\"key\":\"{s}\",\"value\":{s}}}", .{ key, value_json });
        try self.push(.set_keyword, site, null, &out);
        self.summary.set += 1;
    }

    pub fn removeKeyword(self: *Builder, site: Site, key: []const u8) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.remove_keyword, site);
        try out.print(self.gpa, ",\"key\":\"{s}\"}}", .{key});
        try self.push(.remove_keyword, site, null, &out);
        self.summary.set += 1;
    }

    pub fn replace(self: *Builder, site: Site, value_json: []const u8) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.replace, site);
        try out.print(self.gpa, ",\"value\":{s}}}", .{value_json});
        try self.push(.replace, site, null, &out);
        self.summary.replaced += 1;
    }

    /// Insert a positional child into the form at `parent`, at the slot
    /// the child occupies in the document this plan produces (see
    /// `apply`'s sequencing).
    pub fn insertPositional(self: *Builder, parent: Site, index: u32, value_json: []const u8) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.insert_positional, parent);
        try out.print(self.gpa, ",\"index\":{d},\"value\":{s}}}", .{ index, value_json });
        try self.push(.insert_positional, parent, index, &out);
        self.summary.inserted += 1;
    }

    pub fn removePositional(self: *Builder, parent: Site, index: u32) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.remove_positional, parent);
        try out.print(self.gpa, ",\"index\":{d}}}", .{index});
        try self.push(.remove_positional, parent, index, &out);
        self.summary.removed += 1;
    }

    /// Insert a root before root `index` of the document this plan
    /// produces; `null` appends.
    pub fn insertRoot(self: *Builder, index: ?u32, value_json: []const u8) Error!void {
        if (self.summary.refused) return;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, "{\"op\":\"insert_root\"");
        if (index) |i| try out.print(self.gpa, ",\"index\":{d}", .{i});
        try out.print(self.gpa, ",\"value\":{s}}}", .{value_json});
        try self.push(.insert_root, .{ .root = 0, .path = &.{} }, index, &out);
        self.summary.inserted += 1;
    }

    pub fn removeRoot(self: *Builder, index: u32) Error!void {
        if (self.summary.refused) return;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.print(self.gpa, "{{\"op\":\"remove_root\",\"index\":{d}}}", .{index});
        try self.push(.remove_root, .{ .root = 0, .path = &.{} }, index, &out);
        self.summary.removed += 1;
    }

    /// Refuse: drop every action planned so far, record why, and ignore
    /// everything the planner still had to say.
    pub fn refuse(
        self: *Builder,
        code: Diag.Code,
        span: Diag.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        self.actions.clearRetainingCapacity();
        self.summary = .{ .targets = self.summary.targets, .refused = true };
        try self.diags.add(code, .err, span, fmt, args);
    }

    /// Say something about the plan without refusing it — a rounding, a
    /// clamp, a count.
    pub fn note(
        self: *Builder,
        code: Diag.Code,
        severity: Diag.Severity,
        span: Diag.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        try self.diags.add(code, severity, span, fmt, args);
    }

    pub fn finish(self: *Builder) Error!Plan {
        const actions = try self.actions.toOwnedSlice(self.allocator());
        self.finished = true;
        return .{
            .actions = actions,
            .diags = self.diags,
            .summary = self.summary,
            .arena = self.arena,
        };
    }

    /// `{"op":"<kind>","root":N,"path":[…]` — everything every pathed
    /// action starts with, in one key order so two runs spell one plan.
    fn head(self: *Builder, kind: Kind, site: Site) Error!std.ArrayList(u8) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.print(self.gpa, "{{\"op\":\"{s}\",\"root\":{d},\"path\":", .{ kind.text(), site.root });
        try site.writePath(self.gpa, &out);
        return out;
    }

    /// Move the finished text into the arena and record the action. Frees
    /// the scratch buffer either way.
    fn push(self: *Builder, kind: Kind, site: Site, slot: ?u32, out: *std.ArrayList(u8)) Error!void {
        defer out.deinit(self.gpa);
        const a = self.allocator();
        try self.actions.append(a, .{
            .json = try a.dupe(u8, out.items),
            .kind = kind,
            .site = .{ .root = site.root, .path = try a.dupe(u32, site.path) },
            .slot = slot,
        });
    }
};

// ---------------------------------------------------------------------------

test "Plan: the builder spells each action in one key order" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    errdefer b.deinit();

    const lane: Site = .{ .root = 3, .path = &.{} };
    const note: Site = .{ .root = 3, .path = &.{1} };

    try b.setKeyword(note, "at", "{\"$num\":[2,\"q\"]}");
    try b.removeKeyword(note, "off-vel");
    try b.removePositional(lane, 0);
    try b.insertPositional(lane, 2, "{\"$form\":\"note\",\"at\":{\"$num\":[3,\"q\"]}}");
    try b.insertRoot(null, "{\"$form\":\"cue\",\"name\":\"end\"}");
    try b.removeRoot(4);

    var p = try b.finish();
    defer p.deinit();

    const text = try p.text(gpa);
    defer gpa.free(text);

    try testing.expectEqualStrings(
        \\[
        \\{"op":"set_keyword","root":3,"path":[1],"key":"at","value":{"$num":[2,"q"]}},
        \\{"op":"remove_keyword","root":3,"path":[1],"key":"off-vel"},
        \\{"op":"remove_positional","root":3,"path":[],"index":0},
        \\{"op":"insert_positional","root":3,"path":[],"index":2,"value":{"$form":"note","at":{"$num":[3,"q"]}}},
        \\{"op":"insert_root","value":{"$form":"cue","name":"end"}},
        \\{"op":"remove_root","index":4}
        \\]
        \\
    , text);

    try testing.expectEqual(@as(u32, 2), p.summary.set);
    try testing.expectEqual(@as(u32, 2), p.summary.inserted);
    try testing.expectEqual(@as(u32, 2), p.summary.removed);
    try testing.expect(!p.summary.refused);
}

test "Plan: a refusal drops the actions and keeps the diagnostic" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    errdefer b.deinit();

    try b.setKeyword(.{ .root = 0, .path = &.{} }, "at", "0");
    try b.refuse(.edit_range_empty, .{ .start = 4, .end = 9 }, "nothing to do", .{});
    // Everything the planner still had to say is ignored.
    try b.setKeyword(.{ .root = 0, .path = &.{} }, "dur", "0");

    var p = try b.finish();
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    try testing.expect(p.summary.refused);
    try testing.expect(p.diags.hasErrors());
    try testing.expectEqual(Diag.Span{ .start = 4, .end = 9 }, p.findDiag(.edit_range_empty).?.span);

    const text = try p.text(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings("[]\n", text);
}
