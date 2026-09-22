//! What a host does with an operation's JSON — the one spelling of the
//! step every host that edits takes, and of the rule that gates it.
//!
//! Three hosts plan: `tempura edit --op`, `tpr_plan` / `tpr_apply`, and
//! the corpus runner's `(plan …)`. Each holds a loaded document, the text
//! it was loaded from and an ask as JSON, and each asks the same question
//! in the same three calls — `Op.fromJson`, a fresh `sjon.parse` of the
//! text (the addresses come from the tree), `planWith` over the map the
//! load derived. `planJson` is those three calls, written once.
//!
//! What the hosts DO with the answer differs, and stays theirs. An ask
//! that is not an operation at all is the INVOCATION's fault — the CLI's
//! usage exit and an `<--op>` report, the wasm's zero-length answer, the
//! runner's `(planned :read false …)` — while a plan, even a refused one,
//! is an answer about this document. So the result is a union of exactly
//! those two, `Planned`, and every message and exit code is still spelled
//! by the host that prints it. Whether a plan may reach the document is
//! `Plan.committable`, the plan's own question.
//!
//! ## Which load errors stop an edit
//!
//! `blocksEdit` is the CLI's gate: it will not plan over a document whose
//! load said certain things. It lives here so the rule has one spelling,
//! and it is NOT applied by the wasm — `tpr_plan` and `tpr_apply` plan
//! over whatever loaded, as they always have. Whether they should refuse
//! as the CLI does is a ruling filed for Hugo (plan 12, "Filed, not
//! fixed": "a host may build, plan and apply over a document that loaded
//! with errors where the CLI refuses"), and a refactor is not where that
//! ruling gets made. Same behaviour in every host, one spelling.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const doc = @import("../doc/doc.zig");
const TimeMap = @import("../time/TimeMap.zig");
const op_file = @import("Op.zig");
const plan_file = @import("Plan.zig");
const ops_bound = @import("ops_bound.zig");

const Allocator = std.mem.Allocator;
const Plan = plan_file.Plan;

/// Only resource exhaustion, the part-wide rule: an ask that is not an
/// operation and a plan that is refused are both answers.
pub const Error = error{OutOfMemory};

/// What `planJson` answers: a plan, or why the ask was not an operation.
pub const Planned = union(enum) {
    /// The ask was an operation and this is its plan — accepted or
    /// refused, which `Plan.committable` tells apart. Owned.
    plan: Plan,
    /// The ask was not an operation: not JSON, an unknown `"op"`, a
    /// payload the grammar has no place for. The reasons, their spans
    /// into the OPERATION's text and never the document's. Owned.
    not_an_op: Diag.List,

    /// Frees whichever of the two it holds; the value is spent.
    pub fn deinit(self: *Planned) void {
        switch (self.*) {
            .plan => |*p| p.deinit(),
            .not_an_op => |*reasons| reasons.deinit(),
        }
        self.* = undefined;
    }
};

/// Plan the operation `op_json` spells — the `--op` grammar,
/// `edit/edit.zig`'s header — over the document `d` loaded out of
/// `source`.
///
/// `source` must be the text `d` was loaded from: the plan's addresses
/// come from a fresh parse of it and its spans are `d`'s, and it is under
/// SJON's file ceiling because the load that produced `d` parsed it too.
/// `map` is the map that load derived (`doc.Result.map`,
/// `pipeline.Dumped.map`), handed in so the document's time is not
/// derived twice. Pure and total: every defect of the ask or of the
/// document is a diagnostic on the answer, and only an allocation fails.
/// The answer is backed by `gpa`, borrows nothing of the caller's, and
/// `Planned.deinit` frees it.
pub fn planJson(
    gpa: Allocator,
    d: *const doc.Doc,
    source: [:0]const u8,
    map: *const TimeMap.TimeMap,
    op_json: []const u8,
) Error!Planned {
    var parsed = try op_file.fromJson(gpa, op_json);
    defer parsed.deinit();
    const op = parsed.op orelse {
        // MOVED out: the reasons outlive the parse, whose `deinit` then
        // frees an empty list.
        const reasons = parsed.diags;
        parsed.diags = .init(gpa);
        return .{ .not_an_op = reasons };
    };

    // Parsing is total in SJON — a malformed document is a tree with
    // diagnostics, not an error — so only an allocation can fail here.
    var tree = try sjon.parse(gpa, source);
    defer tree.deinit();

    // The plan copies what it keeps out of the operation, so it outlives
    // `parsed` (`Op.Parsed`: "plan it before this").
    return .{ .plan = try ops_bound.planWith(gpa, d, &tree, map, op) };
}

/// Which load errors an edit cannot be planned over — the CLI's gate
/// (`tempura edit`); the wasm does not apply it (the header says why).
///
/// **Every one but two.** A plan's addresses come from a fresh parse of
/// the document's own text and its targets from the `Doc` the walk built,
/// so anything that made either of those wrong makes the plan wrong: a
/// parse error, a duplicate `(timeline …)`, a lane that names itself
/// twice, an address the schema cannot read. Those stop the verb, for
/// `build`'s reason — the product is a document somebody keeps.
///
/// The two exceptions are the two that are about an anchor's FILE rather
/// than about the document: `anchor_unavailable` (no resolver could read
/// it) and `anchor_mismatch` (it was read and does not match the `:size`
/// or `:sha256` the anchor declares). Neither touches what an edit acts
/// on. A NATIVE operation never looks at an anchor at all, and a BOUND
/// one walks the inline dump's own `(midi/mtrk …)` events or
/// `(it/pattern …)` cells IN THE TREE — the file is where those bytes
/// came from, not where they are. The one thing the file does carry is an
/// `it/` tier's `(bin :at :len)` regions, and a selection over a tier
/// that kept its patterns by reference finds no `(ev …)` form to address,
/// so the plan comes back empty rather than wrong.
///
/// Refusing them was the CLI's own bug once: every `edit-bound-*`
/// document names a file that is not beside it, so no bound edit was
/// reachable through the CLI at all while the engine planned them
/// correctly.
pub fn blocksEdit(code: Diag.Code) bool {
    return switch (code) {
        .anchor_unavailable, .anchor_mismatch => false,
        else => true,
    };
}

/// Whether any ERROR among a load's diagnostics blocks an edit —
/// `blocksEdit` over a whole report. A warning never blocks, whatever its
/// code: it is said, and the edit goes through.
pub fn anyBlocksEdit(diags: []const Diag.Diagnostic) bool {
    for (diags) |d| {
        if (d.severity == .err and blocksEdit(d.code)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const support = @import("test_support.zig");

const retime_json = "{\"op\":\"retime\",\"sel\":{\"lanes\":[\"flash\"]},\"delta\":46126080}";

test "planJson: an operation plans exactly as the three calls it stands for" {
    const gpa = testing.allocator;
    var fx = try support.Fixture.init(gpa, support.native);
    defer fx.deinit();

    var got = try planJson(gpa, fx.doc_(), fx.source, &fx.loaded.map, retime_json);
    defer got.deinit();
    try testing.expect(got == .plan);
    try testing.expect(got.plan.committable());

    // …and the same plan, spelled out by hand the way each host used to.
    var parsed = try op_file.fromJson(gpa, retime_json);
    defer parsed.deinit();
    var direct = try ops_bound.planWith(gpa, fx.doc_(), &fx.tree, &fx.loaded.map, parsed.op.?);
    defer direct.deinit();

    const want = try direct.text(gpa);
    defer gpa.free(want);
    const have = try got.plan.text(gpa);
    defer gpa.free(have);
    try testing.expectEqualStrings(want, have);
    try testing.expect(got.plan.actions.len > 0);
}

test "planJson: an ask that is not an operation is not_an_op, with the reader's reasons" {
    const gpa = testing.allocator;
    var fx = try support.Fixture.init(gpa, support.native);
    defer fx.deinit();

    for ([_][]const u8{ "not json", "{\"op\":\"levitate\"}", "[1,2]" }) |ask| {
        var got = try planJson(gpa, fx.doc_(), fx.source, &fx.loaded.map, ask);
        defer got.deinit();
        try testing.expect(got == .not_an_op);
        try testing.expect(got.not_an_op.hasErrors());
        // The code a complaint from another vocabulary carries.
        try testing.expect(got.not_an_op.count(.sjon_diagnostic) > 0);
    }
}

test "planJson: a refused operation is still a plan, and not a committable one" {
    const gpa = testing.allocator;
    var fx = try support.Fixture.init(gpa, support.native);
    defer fx.deinit();

    // `flash` is native: there is no binding to take off it.
    const ask = "{\"op\":\"unbind\",\"lane\":\"flash\"}";
    var got = try planJson(gpa, fx.doc_(), fx.source, &fx.loaded.map, ask);
    defer got.deinit();
    try testing.expect(got == .plan);
    try testing.expect(got.plan.summary.refused);
    try testing.expect(!got.plan.committable());
    try testing.expectEqual(@as(usize, 0), got.plan.actions.len);
    try testing.expectEqual(@as(usize, 1), got.plan.diags.count(.edit_range_empty));
}

test "planJson: OutOfMemory at every allocation, both answers, and nothing leaks" {
    // The house sweep, over the two shapes the answer takes. Bounded by
    // the number of allocations each call makes, which the loop finds.
    const gpa = testing.allocator;
    var fx = try support.Fixture.init(gpa, support.native);
    defer fx.deinit();

    for ([_][]const u8{ retime_json, "{\"op\":\"levitate\"}" }) |ask| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            const result = planJson(failing.allocator(), fx.doc_(), fx.source, &fx.loaded.map, ask);
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

test "blocksEdit: an anchor's FILE never blocks an edit, and anything else does" {
    try testing.expect(!blocksEdit(.anchor_unavailable));
    try testing.expect(!blocksEdit(.anchor_mismatch));
    try testing.expect(blocksEdit(.sjon_diagnostic));
    try testing.expect(blocksEdit(.bound_lane_has_content));
}

test "anyBlocksEdit: only an error with a blocking code stops the edit" {
    const gpa = testing.allocator;
    var report: Diag.List = .init(gpa);
    defer report.deinit();
    const span: Diag.Span = .{ .start = 0, .end = 0 };

    // A file that is not here, and a warning with a code that would block
    // as an error: said, and the edit goes through.
    try report.add(.anchor_unavailable, .err, span, "the file is elsewhere", .{});
    try report.add(.sjon_diagnostic, .warning, span, "a remark", .{});
    try testing.expect(!anyBlocksEdit(report.items()));

    try report.add(.sjon_diagnostic, .err, span, "a parse error", .{});
    try testing.expect(anyBlocksEdit(report.items()));
}
