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

    /// Frees the actions with their text and paths, and the report.
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

    /// Whether this plan may reach the document: the planner did not
    /// refuse it, AND it carries no error from anywhere else on the way —
    /// a host's action list that did not read back is one. Both halves,
    /// because they are different facts: `refused` is the planner saying
    /// "this cannot be done", an error diagnostic is anything else that
    /// went wrong. A plan failing either is an empty action list, and
    /// `apply` over an empty list hands the source straight back — which
    /// would read as a clean no-op edit if nobody asked this first.
    ///
    /// The one spelling of the rule every host commits by: `tempura edit`,
    /// `tpr_plan` (which holds only a committable plan) and `tpr_apply`.
    pub fn committable(self: *const Plan) bool {
        return !self.summary.refused and !self.diags.hasErrors();
    }

    /// What every plan this part hands out satisfies, however it was
    /// made — asserted by `Builder.finish` on the way out (the write
    /// side) and by `apply` on the way in (the read side). Never asked
    /// of a byte no reader has diagnosed: `fromActionsJson` refuses
    /// what is not an action before it keeps one.
    ///
    ///   * A refusal is an empty action list and an error diagnostic;
    ///     an accepted plan carries none (`Builder.note` warns).
    ///   * The summary counts the actions: each is in exactly one of
    ///     `set`, `inserted`, `removed`, `replaced`.
    ///   * A positional or forest action names its slot and the four
    ///     that name a node outright do not — `insert_root`'s append
    ///     spelling is the one optional slot — and a forest action
    ///     carries the root list's own empty address.
    ///   * Every action's text is one JSON object.
    pub fn invariants(self: *const Plan) void {
        std.debug.assert(self.summary.refused == self.diags.hasErrors());
        if (self.summary.refused) std.debug.assert(self.actions.len == 0);
        const s = self.summary;
        const counted = @as(usize, s.set) + s.inserted + s.removed + s.replaced;
        std.debug.assert(counted == self.actions.len);
        for (self.actions) |action| {
            std.debug.assert(action.json.len >= 2);
            std.debug.assert(action.json[0] == '{');
            std.debug.assert(action.json[action.json.len - 1] == '}');
            switch (action.kind) {
                .set_keyword, .remove_keyword, .replace, .wrap => {
                    std.debug.assert(action.slot == null);
                },
                .insert_positional, .remove_positional => {
                    std.debug.assert(action.slot != null);
                },
                .remove_root => {
                    std.debug.assert(action.slot != null);
                    std.debug.assert(action.site.path.len == 0);
                },
                .insert_root => std.debug.assert(action.site.path.len == 0),
            }
        }
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

    /// An empty builder. Its arena and report are allocated from `gpa`
    /// and handed to the `Plan` by `finish`, or freed by `deinit`; `gpa`
    /// itself also carries each action's scratch text, freed per call.
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

    /// `set_keyword` on the form at `site`: `:key` becomes `value_json`,
    /// which must be one JSON value (the value writers' output). `key`
    /// is spelled raw — every caller passes a vocabulary constant. The
    /// text and the path are copied into the plan's arena. A no-op once
    /// refused, like every append here.
    pub fn setKeyword(
        self: *Builder,
        site: Site,
        key: []const u8,
        value_json: []const u8,
    ) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.set_keyword, site);
        defer out.deinit(self.gpa);
        try out.print(self.gpa, ",\"key\":\"{s}\",\"value\":{s}}}", .{ key, value_json });
        try self.push(.set_keyword, site, null, out.items);
        self.summary.set += 1;
    }

    /// `remove_keyword`: `:key` taken off the form at `site`.
    pub fn removeKeyword(self: *Builder, site: Site, key: []const u8) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.remove_keyword, site);
        defer out.deinit(self.gpa);
        try out.print(self.gpa, ",\"key\":\"{s}\"}}", .{key});
        try self.push(.remove_keyword, site, null, out.items);
        self.summary.set += 1;
    }

    /// `replace`: the node at `site` becomes `value_json`, one JSON value.
    pub fn replace(self: *Builder, site: Site, value_json: []const u8) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.replace, site);
        defer out.deinit(self.gpa);
        try out.print(self.gpa, ",\"value\":{s}}}", .{value_json});
        try self.push(.replace, site, null, out.items);
        self.summary.replaced += 1;
    }

    /// Insert a positional child into the form at `parent`, at the slot
    /// the child occupies in the document this plan produces (see
    /// `apply`'s sequencing).
    pub fn insertPositional(
        self: *Builder,
        parent: Site,
        index: u32,
        value_json: []const u8,
    ) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.insert_positional, parent);
        defer out.deinit(self.gpa);
        try out.print(self.gpa, ",\"index\":{d},\"value\":{s}}}", .{ index, value_json });
        try self.push(.insert_positional, parent, index, out.items);
        self.summary.inserted += 1;
    }

    /// `remove_positional`: positional child `index` of the form at
    /// `parent`, counted in the document as it stands (`apply` runs the
    /// removals right to left).
    pub fn removePositional(self: *Builder, parent: Site, index: u32) Error!void {
        if (self.summary.refused) return;
        var out = try self.head(.remove_positional, parent);
        defer out.deinit(self.gpa);
        try out.print(self.gpa, ",\"index\":{d}}}", .{index});
        try self.push(.remove_positional, parent, index, out.items);
        self.summary.removed += 1;
    }

    /// Insert a root before root `index` of the document this plan
    /// produces; `null` appends.
    pub fn insertRoot(self: *Builder, index: ?u32, value_json: []const u8) Error!void {
        if (self.summary.refused) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, "{\"op\":\"insert_root\"");
        if (index) |i| try out.print(self.gpa, ",\"index\":{d}", .{i});
        try out.print(self.gpa, ",\"value\":{s}}}", .{value_json});
        try self.push(.insert_root, .{ .root = 0, .path = &.{} }, index, out.items);
        self.summary.inserted += 1;
    }

    /// `remove_root`: root `index` of the document as it stands.
    pub fn removeRoot(self: *Builder, index: u32) Error!void {
        if (self.summary.refused) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        try out.print(self.gpa, "{{\"op\":\"remove_root\",\"index\":{d}}}", .{index});
        try self.push(.remove_root, .{ .root = 0, .path = &.{} }, index, out.items);
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
        // Every span this part reports is one it read off a `Doc` node,
        // a tree node or its own scan of the text: `start ≤ end`.
        std.debug.assert(span.start <= span.end);
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
        std.debug.assert(span.start <= span.end);
        try self.diags.add(code, severity, span, fmt, args);
    }

    /// The plan: the arena and the report MOVE into it, so the builder
    /// owns nothing afterwards and its `deinit` is a no-op. The plan's
    /// own `deinit` frees them; it keeps `gpa` only through them.
    pub fn finish(self: *Builder) Error!Plan {
        const actions = try self.actions.toOwnedSlice(self.allocator());
        self.finished = true;
        const plan: Plan = .{
            .actions = actions,
            .diags = self.diags,
            .summary = self.summary,
            .arena = self.arena,
        };
        plan.invariants();
        return plan;
    }

    /// `{"op":"<kind>","root":N,"path":[…]` — everything every pathed
    /// action starts with, in one key order so two runs spell one plan.
    fn head(self: *Builder, kind: Kind, site: Site) Error!std.ArrayList(u8) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.print(
            self.gpa,
            "{{\"op\":\"{s}\",\"root\":{d},\"path\":",
            .{ kind.text(), site.root },
        );
        try site.writePath(self.gpa, &out);
        return out;
    }

    /// Copy the finished text into the arena and record the action. The
    /// scratch buffer the text lives in stays the CALLER's, freed by its
    /// own `defer` on every path: one owner, so no path leaks it and no
    /// path frees it twice.
    fn push(self: *Builder, kind: Kind, site: Site, slot: ?u32, text: []const u8) Error!void {
        const arena = self.allocator();
        try self.actions.append(arena, .{
            .json = try arena.dupe(u8, text),
            .kind = kind,
            .site = .{ .root = site.root, .path = try arena.dupe(u32, site.path) },
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
    try testing.expectEqual(
        Diag.Span{ .start = 4, .end = 9 },
        p.findDiag(.edit_range_empty).?.span,
    );

    const text = try p.text(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings("[]\n", text);
}

test "Plan.committable: an accepted plan is, a refused one and an unread list are not" {
    const gpa = testing.allocator;

    var accepted: Builder = .init(gpa);
    errdefer accepted.deinit();
    try accepted.setKeyword(.{ .root = 0, .path = &.{} }, "at", "0");
    var yes = try accepted.finish();
    defer yes.deinit();
    try testing.expect(yes.committable());

    // The empty list a host struck every line out of: nothing to do, and
    // nothing wrong with doing it.
    var none = try fromActionsJson(gpa, "[]\n");
    defer none.deinit();
    try testing.expect(none.committable());

    var refused: Builder = .init(gpa);
    errdefer refused.deinit();
    try refused.refuse(.edit_range_empty, .{ .start = 0, .end = 0 }, "nothing to do", .{});
    var no = try refused.finish();
    defer no.deinit();
    try testing.expect(!no.committable());

    // A host's list that did not read back: its empty action list would
    // splice as a clean no-op, which is exactly what this rule is for.
    var unread = try fromActionsJson(gpa, "not json at all");
    defer unread.deinit();
    try testing.expect(!unread.committable());
}

// ---------------------------------------------------------------------------
// `text()`'s inverse
// ---------------------------------------------------------------------------

/// Read an action list back into a `Plan` — what `text()` wrote, and what
/// a host hands back after looking at it (plan 10's `tpr_apply` row takes
/// "actions as JSON").
///
/// Each element is kept VERBATIM: the bytes a host handed over are the
/// bytes `apply` splices, so nothing is re-rendered and
/// `fromActionsJson(p.text())` gives `p.text()` again. What is parsed out
/// of each element is only the three facts `apply` SEQUENCES by — the
/// operation, the address (`"root"` + `"path"`) and the slot (`"index"`)
/// — which every pathed action in §11.1's grammar carries.
///
/// Total, like every reader in this part: an array that is not one, an
/// element that is not an object, an `"op"` naming no structural
/// operation, a missing `"root"`/`"path"`/`"index"` — each is a REFUSAL
/// (no actions, `refused`, a `sjon_diagnostic` spanning the offending
/// bytes), never a Zig error. `sjon_diagnostic` for the same reason
/// `Op.fromJson` uses it: the complaint belongs to JSON's vocabulary and
/// to this grammar, neither of which has a tempura code of its own.
///
/// The summary is rebuilt by COUNTING what arrived. `targets` and
/// `inexact` are facts about the operation that produced the plan, and a
/// list read back from text has no memory of them, so they stay 0; the
/// rest count the actions.
pub fn fromActionsJson(gpa: std.mem.Allocator, text_json: []const u8) Error!Plan {
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    var reader: ActionReader = .{ .gpa = gpa, .b = &b, .src = text_json };
    reader.run() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The refusal is already on the builder, which is poisoned: the
        // actions read so far are gone and nothing more will be added.
        error.Refused => {},
    };
    return b.finish();
}

/// `fromActionsJson`'s one-pass reader. Two jobs kept apart: a
/// STRUCTURAL scan that finds each element's byte range (so its text
/// survives verbatim), and a per-element `std.json` parse that reads the
/// three facts `apply` sequences by out of it.
const ActionReader = struct {
    gpa: std.mem.Allocator,
    b: *Builder,
    src: []const u8,

    /// `Refused` is not a failure of this module — it is the refusal
    /// already recorded on the builder, unwound to the top.
    const ReadError = error{ OutOfMemory, Refused };

    fn run(self: *ActionReader) ReadError!void {
        var i = self.skipWs(0);
        if (i >= self.src.len or self.src[i] != '[') {
            return self.fail(
                .{ .start = 0, .end = @intCast(self.src.len) },
                "an action list is a JSON array of actions (SJON §11.1)",
                .{},
            );
        }
        i = self.skipWs(i + 1);
        if (i < self.src.len and self.src[i] == ']') {
            i += 1;
        } else while (true) {
            // Bounded by the source's length: an iteration either
            // returns (a refusal, or the closing `]`) or moves `i` past
            // one NON-EMPTY element and its `,` — an empty one is not
            // JSON and `readAction` refuses it — so there are at most
            // `src.len` of them.
            const end = self.elementEnd(i) orelse
                return self.fail(
                    self.spanFrom(i),
                    "the action list ends in the middle of an action",
                    .{},
                );
            try self.readAction(
                std.mem.trimEnd(u8, self.src[i..end], &std.ascii.whitespace),
                @intCast(i),
            );
            // `readAction` refused an empty element, so this one was not.
            std.debug.assert(end > i);
            i = end;
            if (i >= self.src.len) return self.fail(
                self.spanFrom(i),
                "the action list is not closed",
                .{},
            );
            if (self.src[i] == ',') {
                i = self.skipWs(i + 1);
                continue;
            }
            if (self.src[i] == ']') {
                i += 1;
                break;
            }
            return self.fail(
                self.spanFrom(i),
                "an action is followed by `,` or `]`, not by `{c}`",
                .{self.src[i]},
            );
        }
        if (self.skipWs(i) != self.src.len) {
            return self.fail(self.spanFrom(i), "there are bytes after the action list", .{});
        }
    }

    /// One element: kept verbatim, with its operation, address and slot
    /// read out of it. `at` is where it starts in `src`, so a complaint
    /// spans the action a host can actually see.
    fn readAction(self: *ActionReader, text: []const u8, at: u32) ReadError!void {
        const span: Diag.Span = .{ .start = at, .end = at + @as(u32, @intCast(text.len)) };
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.gpa,
            text,
            .{},
        ) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail(span, "this action is not JSON: {s}", .{@errorName(e)}),
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self.fail(span, "an action is a JSON object", .{}),
        };

        const op_name = switch (obj.get("op") orelse
            return self.fail(span, "an action names its operation with \"op\"", .{})) {
            .string => |s| s,
            else => return self.fail(span, "an action's \"op\" is a string", .{}),
        };
        const kind = std.meta.stringToEnum(Kind, op_name) orelse
            return self.fail(
                span,
                "\"{s}\" is not one of SJON's eight structural operations",
                .{op_name},
            );

        // The two FOREST operations name no node, so they carry the root
        // list's own empty address and say everything in their slot.
        const site: Site = switch (kind) {
            .insert_root, .remove_root => .{ .root = 0, .path = &.{} },
            else => .{
                .root = try self.intOf(obj, "root", span),
                .path = try self.pathOf(obj, span),
            },
        };
        const slot: ?u32 = switch (kind) {
            .set_keyword, .remove_keyword, .replace, .wrap => null,
            .insert_positional, .remove_positional, .remove_root => try self.intOf(
                obj,
                "index",
                span,
            ),
            // §11.3: an omitted index is the append spelling.
            .insert_root => if (obj.get(
                "index",
            ) == null) null else try self.intOf(obj, "index", span),
        };

        const arena = self.b.allocator();
        try self.b.actions.append(arena, .{
            .json = try arena.dupe(u8, text),
            .kind = kind,
            .site = site,
            .slot = slot,
        });
        switch (kind) {
            .set_keyword, .remove_keyword => self.b.summary.set += 1,
            .replace, .wrap => self.b.summary.replaced += 1,
            .insert_positional, .insert_root => self.b.summary.inserted += 1,
            .remove_positional, .remove_root => self.b.summary.removed += 1,
        }
    }

    /// A required whole-number key, in `u32`'s range — every `"root"`,
    /// `"path"` step and `"index"` the grammar has is one.
    fn intOf(
        self: *ActionReader,
        obj: std.json.ObjectMap,
        key: []const u8,
        span: Diag.Span,
    ) ReadError!u32 {
        const value = obj.get(key) orelse
            return self.fail(span, "this action needs a \"{s}\"", .{key});
        return self.u32Of(value, key, span);
    }

    fn u32Of(
        self: *ActionReader,
        value: std.json.Value,
        key: []const u8,
        span: Diag.Span,
    ) ReadError!u32 {
        const n = switch (value) {
            .integer => |x| x,
            else => return self.fail(span, "\"{s}\" is a whole number", .{key}),
        };
        if (n < 0 or n > std.math.maxInt(u32)) {
            return self.fail(
                span,
                "\"{s}\" is {d}, which is not a slot in any document",
                .{ key, n },
            );
        }
        return @intCast(n);
    }

    fn pathOf(self: *ActionReader, obj: std.json.ObjectMap, span: Diag.Span) ReadError![]const u32 {
        const value = obj.get("path") orelse
            return self.fail(span, "this action needs a \"path\"", .{});
        const items = switch (value) {
            .array => |arr| arr.items,
            else => return self.fail(span, "\"path\" is an array of positional steps", .{}),
        };
        const path = try self.b.allocator().alloc(u32, items.len);
        for (items, path) |step, *out| out.* = try self.u32Of(step, "path", span);
        return path;
    }

    /// Record the refusal and unwind. `sjon_diagnostic` for the reason
    /// `Op.fromJson` uses it: the complaint belongs to JSON's vocabulary
    /// and to §11.1's grammar, neither of which has a tempura code.
    fn fail(
        self: *ActionReader,
        span: Diag.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) ReadError {
        try self.b.refuse(.sjon_diagnostic, span, fmt, args);
        return error.Refused;
    }

    fn spanFrom(self: *ActionReader, at: usize) Diag.Span {
        return .{ .start = @intCast(@min(at, self.src.len)), .end = @intCast(self.src.len) };
    }

    fn skipWs(self: *ActionReader, from: usize) usize {
        var i = from;
        while (i < self.src.len and std.ascii.isWhitespace(self.src[i])) i += 1;
        return i;
    }

    /// Where the element starting at `from` ends: the index of the `,`
    /// or `]` that closes it. A STRUCTURAL scan — brace depth, with
    /// strings skipped whole — because the element's own bytes are what
    /// gets spliced and a re-render would not be them.
    fn elementEnd(self: *ActionReader, from: usize) ?usize {
        var depth: usize = 0;
        var i = from;
        while (i < self.src.len) {
            switch (self.src[i]) {
                '"' => {
                    i = self.stringEnd(i) orelse return null;
                    continue;
                },
                '{', '[' => depth += 1,
                '}', ']' => {
                    if (depth == 0) return i;
                    depth -= 1;
                },
                ',' => if (depth == 0) return i,
                else => {},
            }
            i += 1;
        }
        return null;
    }

    /// Just past the string starting at `from`, escapes honoured.
    fn stringEnd(self: *ActionReader, from: usize) ?usize {
        var i = from + 1;
        while (i < self.src.len) : (i += 1) {
            if (self.src[i] == '\\') {
                i += 1;
                continue;
            }
            if (self.src[i] == '"') return i + 1;
        }
        return null;
    }
};

test "Plan.fromActionsJson: a plan's own text reads back as the same plan" {
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

    var back = try fromActionsJson(gpa, text);
    defer back.deinit();

    try testing.expect(!back.summary.refused);
    try testing.expect(!back.diags.hasErrors());
    try testing.expectEqual(p.actions.len, back.actions.len);
    for (p.actions, back.actions) |want, got| {
        try testing.expectEqualStrings(want.json, got.json);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.site.root, got.site.root);
        try testing.expectEqualSlices(u32, want.site.path, got.site.path);
        try testing.expectEqual(want.slot, got.slot);
    }
    // Byte-for-byte, which is what makes the round trip a real inverse.
    const again = try back.text(gpa);
    defer gpa.free(again);
    try testing.expectEqualStrings(text, again);

    // Counted, not carried: `targets` is the operation's fact and is gone.
    try testing.expectEqual(@as(u32, 2), back.summary.set);
    try testing.expectEqual(@as(u32, 2), back.summary.inserted);
    try testing.expectEqual(@as(u32, 2), back.summary.removed);
    try testing.expectEqual(@as(u32, 0), back.summary.targets);
}

test "Plan.fromActionsJson: a host that dropped an action gets the rest" {
    const gpa = testing.allocator;
    var back = try fromActionsJson(gpa,
        \\[
        \\{"op":"remove_positional","root":3,"path":[],"index":2},
        \\{"op":"remove_positional","root":3,"path":[],"index":0}
        \\]
    );
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.actions.len);
    try testing.expectEqual(@as(u32, 2), back.actions[0].slot.?);
    try testing.expectEqual(@as(u32, 0), back.actions[1].slot.?);

    // …and the empty list is a plan that does nothing, not a refusal.
    var none = try fromActionsJson(gpa, "[]\n");
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.actions.len);
    try testing.expect(!none.summary.refused);
}

test "Plan.fromActionsJson: the append spelling of insert_root keeps its null slot" {
    const gpa = testing.allocator;
    var back = try fromActionsJson(gpa,
        \\[{"op":"insert_root","value":{"$form":"cue"}},{"op":"insert_root","index":1,"value":{"$form":"cue"}}]
    );
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.actions.len);
    // §11.3: an omitted index names the far end of the root list.
    try testing.expectEqual(@as(?u32, null), back.actions[0].slot);
    try testing.expectEqual(@as(?u32, 1), back.actions[1].slot);
    try testing.expectEqual(@as(u32, 0), back.actions[0].site.root);
}

test "Plan.fromActionsJson: what is not an action list is a refusal, never an error" {
    const gpa = testing.allocator;
    const bad = [_][]const u8{
        "{}", // an object is one action, not a list
        "[1]", // an element that is not an object
        "not json at all",
        "[{\"op\":\"nope\",\"root\":0,\"path\":[]}]", // no such structural operation
        "[{\"op\":\"set_keyword\",\"path\":[]}]", // no :root
        "[{\"op\":\"set_keyword\",\"root\":0}]", // no :path
        "[{\"op\":\"remove_positional\",\"root\":0,\"path\":[]}]", // no :index
        "[{\"op\":\"set_keyword\",\"root\":0,\"path\":[-1]}]", // a path step is never negative
        "[{\"op\":\"remove_positional\",\"root\":0,\"path\":[]},", // truncated
    };
    for (bad) |text| {
        var back = try fromActionsJson(gpa, text);
        defer back.deinit();
        try testing.expect(back.summary.refused);
        try testing.expect(back.diags.hasErrors());
        try testing.expectEqual(@as(usize, 0), back.actions.len);
        try testing.expectEqual(@as(usize, 1), back.diags.count(.sjon_diagnostic));
    }
}

test "Plan.fromActionsJson: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails with
    // error.OutOfMemory and testing.allocator sees no leak; past the last
    // index it succeeds. Bounded by the number of allocations the call
    // makes, which the loop discovers. Two lists: one that reads back
    // whole and one refused in its second element, after an action has
    // already been kept.
    const texts = [_][]const u8{
        \\[{"op":"set_keyword","root":3,"path":[1],"key":"at","value":{"$num":[2,"q"]}},
        \\{"op":"remove_positional","root":3,"path":[],"index":0},
        \\{"op":"insert_root","value":{"$form":"cue","name":"end"}}]
        ,
        \\[{"op":"remove_root","index":4},{"op":"nope","root":0,"path":[]}]
        ,
    };
    for (texts) |text| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(testing.allocator, .{
                .fail_index = fail_index,
            });
            const result = fromActionsJson(failing.allocator(), text);
            if (failing.has_induced_failure) {
                try testing.expectError(error.OutOfMemory, result);
            } else {
                var value = try result;
                value.deinit();
                break;
            }
        }
    }
}
