//! Applying a plan: the actions, in an order that makes every address
//! valid when it is reached, spliced into the document's own bytes.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const Plan = @import("Plan.zig");
const locate = @import("locate.zig");

const testing = std.testing;

pub const Error = error{OutOfMemory};

/// What `apply` returns: the document the plan produced, and the report.
///
/// `text` is sentinel-terminated because the next question asked of it is
/// always "parse this again" — a host re-plans against the document it
/// just got back, and SJON's parser takes a `[:0]const u8`.
pub const Applied = struct {
    text: [:0]u8,
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Applied) void {
        self.arena.deinit();
        self.diags.deinit();
        self.* = undefined;
    }
};

/// Apply `p` to `text` and return the edited document.
///
/// The actions are SEQUENCED first, so that each address is valid when it
/// is reached (plan 07, "The contract"):
///
///   1. the four that change a node in place (`set_keyword`,
///      `remove_keyword`, `replace`, `wrap`), in the plan's own order —
///      they move bytes and never structure, so no address depends on
///      them;
///   2. `remove_positional`, right to left: within one container the
///      higher slot first, and a container inside another before the
///      container itself;
///   3. `insert_positional`, left to right within a container (an index
///      is the slot the child occupies in the document the plan
///      produces, so the lower one goes in first) and again innermost
///      container first;
///   4. `remove_root`, right to left;
///   5. `insert_root`, left to right, the append last.
///
/// Roots go last for the reason §11.3 gives them their own container:
/// a root inserted or removed renumbers every root after it, and every
/// other action names its root by that number.
///
/// Between actions the document is re-parsed — SJON's own `.preserve`
/// fold does it (`Edit.applyEdits`), because a spliced span moves every
/// byte coordinate after it — so a plan never relies on an address
/// surviving a prior action. Layout is `.preserve`: every byte outside a
/// touched span is the author's, comments included (§11.5, §11.6).
///
/// A batch is all-or-nothing. An action SJON refuses aborts the whole
/// apply, the document comes back untouched, and the refusal rides out
/// as a `sjon_diagnostic` — SJON's complaint in SJON's words, which is
/// how every other part of this repo carries one.
pub fn apply(gpa: std.mem.Allocator, text: [:0]const u8, p: *const Plan.Plan) Error!Applied {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();
    const a = arena.allocator();

    if (p.actions.len == 0) {
        return .{ .text = try a.dupeZ(u8, text), .diags = diags, .arena = arena };
    }

    const ordered = try gpa.dupe(Plan.Action, p.actions);
    defer gpa.free(ordered);
    // Insertion sort: stable, which is what keeps two actions the
    // sequencing does not separate in the order the plan put them.
    std.sort.insertion(Plan.Action, ordered, {}, before);

    var parsed: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
    defer {
        for (parsed.items) |*one| one.deinit();
        parsed.deinit(gpa);
    }
    var values: std.ArrayList(std.json.Value) = .empty;
    defer values.deinit(gpa);

    for (ordered) |action| {
        const one = std.json.parseFromSlice(std.json.Value, gpa, action.json, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // Only this module writes an action, and it writes JSON.
            else => unreachable,
        };
        try parsed.append(gpa, one);
        try values.append(gpa, one.value);
    }

    const edited = sjon.Edit.applyEdits(gpa, text, values.items, .{ .layout = .preserve }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.add(
                .sjon_diagnostic,
                .err,
                .{ .start = 0, .end = @intCast(text.len) },
                "SJON refused the edit: {s}",
                .{@errorName(e)},
            );
            return .{ .text = try a.dupeZ(u8, text), .diags = diags, .arena = arena };
        },
    };
    defer edited.deinit();

    return .{ .text = try a.dupeZ(u8, edited.data), .diags = diags, .arena = arena };
}

/// Which pass an action belongs to. The order is the contract above.
fn pass(kind: Plan.Kind) u8 {
    return switch (kind) {
        .set_keyword, .remove_keyword, .replace, .wrap => 0,
        .remove_positional => 1,
        .insert_positional => 2,
        .remove_root => 3,
        .insert_root => 4,
    };
}

fn before(_: void, x: Plan.Action, y: Plan.Action) bool {
    const px = pass(x.kind);
    const py = pass(y.kind);
    if (px != py) return px < py;
    return switch (px) {
        // In place: nothing to order, and the sort is stable.
        0 => false,
        1, 2 => blk: {
            // A container nested inside another is edited first, so the
            // outer edit cannot move it; `Site.order` puts a prefix
            // before what extends it, so "innermost first" is `.gt`.
            switch (locate.Site.order(x.site, y.site)) {
                .lt => break :blk false,
                .gt => break :blk true,
                .eq => {},
            }
            const sx = x.slot.?;
            const sy = y.slot.?;
            break :blk if (px == 1) sx > sy else sx < sy;
        },
        3 => x.slot.? > y.slot.?,
        // An omitted index is the append spelling (§11.3) and so names
        // the far end of the root list.
        4 => (x.slot orelse std.math.maxInt(u32)) < (y.slot orelse std.math.maxInt(u32)),
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------

const fixture: [:0]const u8 =
    \\(timeline :title "impulsos" :length 8bar)
    \\
    \\; the lane the editor is pointed at
    \\(lane :name flash :target flash
    \\  ; the downbeat
    \\  (note :at 0q :dur 0.5q :key 36 :vel 110)
    \\  (note :at 1q :dur 0.5q :key 60 :vel 90)
    \\  (note :at 2q :dur 0.5q :key 62 :vel 90))
    \\(cue :name "bar 41" :at 40bar)
    \\
;

test "apply: a hand-written plan reaches the document byte for byte, comments intact" {
    const gpa = testing.allocator;
    var b: Plan.Builder = .init(gpa);
    errdefer b.deinit();

    const lane: locate.Site = .{ .root = 1, .path = &.{} };
    const first: locate.Site = .{ .root = 1, .path = &.{0} };
    const cue: locate.Site = .{ .root = 2, .path = &.{} };

    try b.setKeyword(first, "vel", "120");
    try b.setKeyword(cue, "at", "{\"$num\":[41,\"bar\"]}");
    try b.setKeyword(lane, "target", "{\"$sym\":\"strobe\"}");

    var p = try b.finish();
    defer p.deinit();

    var applied = try apply(gpa, fixture, &p);
    defer applied.deinit();

    try testing.expect(!applied.diags.hasErrors());
    try testing.expectEqualStrings(
        \\(timeline :title "impulsos" :length 8bar)
        \\
        \\; the lane the editor is pointed at
        \\(lane :name flash :target strobe
        \\  ; the downbeat
        \\  (note :at 0q :dur 0.5q :key 36 :vel 120)
        \\  (note :at 1q :dur 0.5q :key 60 :vel 90)
        \\  (note :at 2q :dur 0.5q :key 62 :vel 90))
        \\(cue :name "bar 41" :at 41bar)
        \\
    , applied.text);
}

test "apply: removals run right to left and inserts land after them" {
    const gpa = testing.allocator;
    var b: Plan.Builder = .init(gpa);
    errdefer b.deinit();

    const lane: locate.Site = .{ .root = 1, .path = &.{} };

    // Planned in document order, applied in the order that keeps each
    // address valid: the insert first in the list, the two removals
    // right to left before it.
    try b.insertPositional(lane, 1, "{\"$form\":\"note\",\"at\":{\"$num\":[4,\"q\"]},\"dur\":{\"$num\":[0.5,\"q\"]},\"key\":64}");
    try b.removePositional(lane, 0);
    try b.removePositional(lane, 1);

    var p = try b.finish();
    defer p.deinit();

    var applied = try apply(gpa, fixture, &p);
    defer applied.deinit();

    try testing.expect(!applied.diags.hasErrors());
    try testing.expectEqualStrings(
        \\(timeline :title "impulsos" :length 8bar)
        \\
        \\; the lane the editor is pointed at
        \\(lane :name flash :target flash
        \\  (note :at 2q :dur 0.5q :key 62 :vel 90)
        \\  (note :at 4q :dur 0.5q :key 64))
        \\(cue :name "bar 41" :at 40bar)
        \\
    , applied.text);
}

test "apply: roots go last, so a root insert never renumbers a pending path" {
    const gpa = testing.allocator;
    var b: Plan.Builder = .init(gpa);
    errdefer b.deinit();

    // The root insert is planned FIRST and must still run last: it
    // renumbers every root after it, and the `set_keyword` below names
    // root 2 as the document stands now.
    //
    // It lands AFTER the comment that leads root 1, because a root's own
    // span starts past its leading comments and that is where §11.6
    // splices "before the index-th root" — the comment is about the lane,
    // and an insert never copies a comment. Planning a root insert as an
    // APPEND after the last root of the same head (plan 07's rule) is
    // what keeps that out of the way in practice.
    try b.insertRoot(1, "{\"$form\":\"meter-point\",\"at\":{\"$num\":[0,\"bar\"]},\"sig\":[3,4]}");
    try b.setKeyword(.{ .root = 2, .path = &.{} }, "at", "{\"$num\":[41,\"bar\"]}");

    var p = try b.finish();
    defer p.deinit();

    var applied = try apply(gpa, fixture, &p);
    defer applied.deinit();

    try testing.expect(!applied.diags.hasErrors());
    try testing.expectEqualStrings(
        \\(timeline :title "impulsos" :length 8bar)
        \\
        \\; the lane the editor is pointed at
        \\(meter-point :at 0bar :sig [3 4])
        \\(lane :name flash :target flash
        \\  ; the downbeat
        \\  (note :at 0q :dur 0.5q :key 36 :vel 110)
        \\  (note :at 1q :dur 0.5q :key 60 :vel 90)
        \\  (note :at 2q :dur 0.5q :key 62 :vel 90))
        \\(cue :name "bar 41" :at 41bar)
        \\
    , applied.text);
}

test "apply: an empty plan returns the document unchanged" {
    const gpa = testing.allocator;
    var b: Plan.Builder = .init(gpa);
    errdefer b.deinit();
    var p = try b.finish();
    defer p.deinit();

    var applied = try apply(gpa, fixture, &p);
    defer applied.deinit();

    try testing.expect(!applied.diags.hasErrors());
    try testing.expectEqualStrings(fixture, applied.text);
}

test "apply: an action SJON refuses leaves the document alone and says so" {
    const gpa = testing.allocator;
    var b: Plan.Builder = .init(gpa);
    errdefer b.deinit();

    // Root 9 does not exist. Nothing in this repo plans one; a host that
    // hands `apply` a stale plan gets its document back untouched.
    try b.setKeyword(.{ .root = 9, .path = &.{} }, "at", "0");

    var p = try b.finish();
    defer p.deinit();

    var applied = try apply(gpa, fixture, &p);
    defer applied.deinit();

    try testing.expect(applied.diags.hasErrors());
    try testing.expectEqual(Diag.Code.sjon_diagnostic, applied.diags.items()[0].code);
    try testing.expectEqualStrings(fixture, applied.text);
}
