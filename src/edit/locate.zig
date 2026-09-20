//! Where a `Doc` node's bytes are, in SJON's address vocabulary.
//!
//! Every node of a `Doc` carries the SPAN of the form it was read from
//! (`doc/Value.zig`), and every SJON edit action names its target as a
//! ROOT plus a PATH (`SJON/docs/LANGUAGE.md` §11.2, §11.3). This module
//! is the one join between the two: re-parse the document's source, walk
//! the tree once into SJON's own `Edit.NodeTable`, and answer "which
//! address holds the form whose span is this?".
//!
//! The join is a span match and not an identity: an address is where a
//! node is, not which node it is (§11.2), so a `Map` is only as current
//! as the tree it was built from. `apply` re-parses between actions, and
//! `plan` re-derives every address from the document it was handed —
//! nothing here survives an edit, and nothing is asked to.

const std = @import("std");
const sjon = @import("sjon");
const Diag = @import("../Diag.zig");

const testing = std.testing;

/// Only resource exhaustion. A span that names no node is `null`, not an
/// error: a stale span is a question with an answer.
pub const Error = error{OutOfMemory};

/// A node's address: the root its path starts at, and the positional
/// steps from that root down to it (§11.2).
///
/// Every step is an INDEX. tempura's editable forms — a lane, a note, a
/// keyframe, a clip, a phrase's lane — are positional children all the
/// way down; a form that is a keyword's value (a `:ease (spring …)`) is
/// reached through a string step and is not a site, because no operation
/// here addresses one.
pub const Site = struct {
    root: u32,
    path: []const u32,

    /// The `path` as the action grammar spells it — `[]`, `[2]`,
    /// `[1,0]`. Appends; the caller owns `out`.
    pub fn writePath(self: Site, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
        try out.append(gpa, '[');
        for (self.path, 0..) |step, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.print(gpa, "{d}", .{step});
        }
        try out.append(gpa, ']');
    }

    /// Document order between two addresses: root, then path, a prefix
    /// before what extends it. The one total order every sequencing
    /// question here is asked in.
    pub fn order(a: Site, b: Site) std.math.Order {
        if (a.root != b.root) return std.math.order(a.root, b.root);
        const n = @min(a.path.len, b.path.len);
        for (a.path[0..n], b.path[0..n]) |x, y| {
            if (x != y) return std.math.order(x, y);
        }
        return std.math.order(a.path.len, b.path.len);
    }
};

/// A node, its address, and the slot it occupies in whatever holds it.
pub const Where = struct {
    /// The node's own address.
    site: Site,
    /// The form that holds it, or null when the node IS a root — the
    /// root list is a container too, and its ops take an index alone
    /// (§11.3).
    parent: ?Site,
    /// The positional slot in `parent`, or the index in the document's
    /// root list when `parent` is null.
    slot: u32,
};

/// Span → address, over one parse of one document.
///
/// Holds SJON's `Edit.NodeTable` — the pre-order table of every
/// addressable node with its parent link — and borrows the tree it was
/// built from.
pub const Map = struct {
    gpa: std.mem.Allocator,
    table: sjon.Edit.NodeTable,

    pub fn init(gpa: std.mem.Allocator, tree: *const sjon.Ast.Tree) Error!Map {
        // `nodeTable` fails only on allocation: it walks a tree that is
        // already bounded and refuses nothing.
        const table = sjon.Edit.nodeTable(gpa, tree) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        return .{ .gpa = gpa, .table = table };
    }

    pub fn deinit(self: *const Map) void {
        self.table.deinit();
    }

    /// The address of the node whose span is EXACTLY `span`, allocated in
    /// `a`. Null when no node has that span (a stale span, or a span of
    /// another document), or when the node is reached through a keyword
    /// step.
    ///
    /// Complexity: O(n · d) — one scan of the table, one walk up the
    /// parent links. Documents are a few hundred nodes and a plan asks a
    /// handful of times; a caller resolving thousands should index the
    /// table by span itself.
    pub fn at(self: *const Map, a: std.mem.Allocator, span: Diag.Span) Error!?Where {
        const row = self.rowOfSpan(span) orelse return null;
        return try self.whereOfRow(a, row);
    }

    /// The row whose span is exactly `span`. The first match in row
    /// order, which is pre-order: an outer node before an inner one.
    fn rowOfSpan(self: *const Map, span: Diag.Span) ?u32 {
        for (self.table.rows, 0..) |row, i| {
            if (row.span.start == span.start and row.span.end == span.end) return @intCast(i);
        }
        return null;
    }

    fn whereOfRow(self: *const Map, a: std.mem.Allocator, row_idx: u32) Error!?Where {
        var steps: std.ArrayList(u32) = .empty;
        errdefer steps.deinit(a);

        const root = self.table.rows[row_idx].root;
        var cur: ?u32 = row_idx;
        while (cur) |at_row| {
            const row = self.table.rows[at_row];
            if (row.seg) |seg| switch (seg) {
                .index => |i| try steps.append(a, i),
                // A form under a keyword is not a site: no operation
                // here addresses one, and answering half an address
                // would be worse than answering none.
                .key => return null,
            };
            cur = row.parent;
        }
        std.mem.reverse(u32, steps.items);

        const path = try steps.toOwnedSlice(a);
        const parent: ?Site = if (path.len == 0) null else .{ .root = root, .path = path[0 .. path.len - 1] };
        const slot: u32 = if (path.len == 0) root else path[path.len - 1];
        return .{ .site = .{ .root = root, .path = path }, .parent = parent, .slot = slot };
    }

    /// How many roots the document has — the append index for
    /// `insert_root`.
    pub fn rootCount(self: *const Map) u32 {
        var n: u32 = 0;
        for (self.table.rows) |row| {
            if (row.parent == null) n = @max(n, row.root + 1);
        }
        return n;
    }
};

// ---------------------------------------------------------------------------

const probe_source: [:0]const u8 =
    \\(timeline :title "impulsos")
    \\
    \\; the lane
    \\(lane :name flash :target flash
    \\  (note :at 0q :dur 0.5q :key 36)
    \\  (note :at 1q :dur 0.5q :key 60))
    \\(cue :name "bar 41" :at 40bar)
    \\
;

fn spanOfText(source: []const u8, needle: []const u8) Diag.Span {
    const at = std.mem.indexOf(u8, source, needle).?;
    return .{ .start = @intCast(at), .end = @intCast(at + needle.len) };
}

test "locate: a root's address is its index and an empty path" {
    const gpa = testing.allocator;
    var tree = try sjon.parse(gpa, probe_source);
    defer tree.deinit();
    var map: Map = try .init(gpa, &tree);
    defer map.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cue = (try map.at(a, spanOfText(probe_source, "(cue :name \"bar 41\" :at 40bar)"))).?;
    try testing.expectEqual(@as(u32, 2), cue.site.root);
    try testing.expectEqual(@as(usize, 0), cue.site.path.len);
    try testing.expect(cue.parent == null);
    try testing.expectEqual(@as(u32, 2), cue.slot);
    try testing.expectEqual(@as(u32, 3), map.rootCount());
}

test "locate: a lane's child is a positional slot under its root" {
    const gpa = testing.allocator;
    var tree = try sjon.parse(gpa, probe_source);
    defer tree.deinit();
    var map: Map = try .init(gpa, &tree);
    defer map.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const second = (try map.at(a, spanOfText(probe_source, "(note :at 1q :dur 0.5q :key 60)"))).?;
    try testing.expectEqual(@as(u32, 1), second.site.root);
    try testing.expectEqualSlices(u32, &.{1}, second.site.path);
    try testing.expectEqual(@as(u32, 1), second.parent.?.root);
    try testing.expectEqual(@as(usize, 0), second.parent.?.path.len);
    try testing.expectEqual(@as(u32, 1), second.slot);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try second.site.writePath(gpa, &out);
    try testing.expectEqualStrings("[1]", out.items);
}

test "locate: a span no node carries is null, not an error" {
    const gpa = testing.allocator;
    var tree = try sjon.parse(gpa, probe_source);
    defer tree.deinit();
    var map: Map = try .init(gpa, &tree);
    defer map.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    try testing.expect((try map.at(arena.allocator(), .{ .start = 3, .end = 7 })) == null);
}

test "locate: Site.order is document order, a prefix before what extends it" {
    const a: Site = .{ .root = 1, .path = &.{} };
    const b: Site = .{ .root = 1, .path = &.{0} };
    const c: Site = .{ .root = 1, .path = &.{ 0, 3 } };
    const d: Site = .{ .root = 2, .path = &.{} };

    try testing.expectEqual(std.math.Order.lt, Site.order(a, b));
    try testing.expectEqual(std.math.Order.lt, Site.order(b, c));
    try testing.expectEqual(std.math.Order.lt, Site.order(c, d));
    try testing.expectEqual(std.math.Order.eq, Site.order(a, a));
    try testing.expectEqual(std.math.Order.gt, Site.order(c, b));
}
