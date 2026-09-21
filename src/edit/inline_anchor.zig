//! Inlining an anchor: its file's bytes in, the `insert_root` plan out.
//!
//! Plan 10's `inline` row — "dumps a by-reference anchor's tiers into the
//! document so its content becomes editable (07, "Bound content"); writes
//! the document back with layout preserved" — as one pure function, so
//! every host can do what the CLI does. `tempura inline` is a verb over
//! it and keeps what is a CLI's: which anchor, where its bytes come from,
//! what is printed and the exit code. A wasm host is told to "inline
//! first" (`wasm_entry.zig`'s header); this is what it inlines WITH.
//!
//! ## Why a plan and not a document
//!
//! Layout. A document is a person's text — comments, blank lines, the
//! spelling of every number — and re-printing it to add one root would
//! rewrite all of it. So the tier is added the way every other change to
//! a document is made: as SJON edit actions, which `apply` splices with
//! layout `.preserve`, leaving every other byte as the author wrote it
//! (plan 07, "The contract"; `SJON/docs/LANGUAGE.md` §11.5). One
//! `insert_root` per root of the tier.
//!
//! ## Where the tier lands
//!
//! Directly after the `(anchor …)` it pairs with, because that pairing is
//! POSITIONAL (plan 02): an `(it/module …)` belongs to the anchor above
//! it, and a tier that landed anywhere else would read back as belonging
//! to a different anchor or to none. The anchor's root index is found by
//! matching the span the document layer recorded for it against the
//! roots of a fresh parse of the same text — the span-to-address join
//! `locate.zig` makes, minus the paths, because a root needs none.
//!
//! ## The tier's own layout is SJON's, not the bridge's
//!
//! The forms are the bridge's and the LAYOUT is SJON's printer's: an
//! action carries a JSON value, and SJON's canonical encoding of a form
//! puts its keywords before its positional children, so a tier `tempura
//! dump` would write as `(it/pattern 0 :rows 64 …)` lands here as
//! `(it/pattern :rows 64 0 …)`. The same form, the same value — and the
//! author's own bytes, the ones this promises to leave alone, are
//! untouched either way. The bridges run with their default switches:
//! inlining is about making content EDITABLE, and it 03's three
//! compaction switches all take content away.
//!
//! ## Why this file reads bytes
//!
//! The layering rule has `edit/` consume a `Doc` and never bytes, and
//! this file is the one exception, as `doc/pipeline.zig` is `doc/`'s: an
//! inline IS an anchor's bytes becoming document text. It reads them
//! through the format cores' own readers and prints through `doc/`'s
//! bridges — the calls `tempura dump` makes — and nothing else in `edit/`
//! imports it.
//!
//! ## What it does NOT do
//!
//! Inlining does not free a document from its file (plan 10's own risk
//! note): an `it/` tier keeps its `:raw` and `data` regions as `(bin :at
//! :len)` references into the anchor's bytes, because bytes are sacred
//! (plan 06). What becomes editable is the MUSIC — the patterns, the
//! orders, the events — which is what plan 07's bound operations act on.
//!
//! ```zig
//! var inlined = try edit.inlineAnchor(gpa, source, anchor, bytes);
//! defer inlined.deinit();
//! switch (inlined.outcome) {
//!     .plan => |*p| { var applied = try edit.apply(gpa, source, p); … },
//!     else => …, // why there is no plan
//! }
//! // inlined.file_diags: what the reader said about the FILE
//! ```

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const Schema = @import("../Schema.zig");
const doc = @import("../doc/doc.zig");
const smf = @import("../smf/smf.zig");
const itf = @import("../itf/itf.zig");
const plan_file = @import("Plan.zig");
const apply_file = @import("apply.zig");

const Allocator = std.mem.Allocator;
const Plan = plan_file.Plan;

/// Only resource exhaustion, the part-wide rule: a file the reader
/// complains of is `file_diags`, and a tier that has no plan says why in
/// `outcome`.
pub const Error = error{OutOfMemory};

/// The plan, or why there is none. The first three answers are about the
/// caller's inputs; the last three are tempura DEFECTS — a tier the
/// bridge printed that does not survive its own round trip — and a host
/// reports them as its own failure, never the user's.
pub const Outcome = union(enum) {
    /// One `insert_root` per root of the tier, the first straight after
    /// the anchor. Owned: `Inlined.deinit` frees it.
    plan: Plan,
    /// The anchor's span is no root of `source`: the anchor was not
    /// taken from a `Doc` loaded out of this text.
    not_a_root,
    /// The document or the tier is past SJON's file ceiling
    /// (`Binary.MAX_FILE_SIZE`, 256 MiB), so it cannot be parsed to be
    /// spliced. The payload is the size that is over.
    too_large: usize,
    /// The bridge's tier did not parse back as SJON. A defect.
    unparsed,
    /// SJON's JSON bridge refused the tier; the payload is its error's
    /// name, static. A defect.
    unencoded: []const u8,
    /// The engine's own reader did not take the action list back as one
    /// action per root. The refused plan rides for its diagnostics and is
    /// freed by `Inlined.deinit`. A defect.
    unread: Plan,
};

/// What `inlineAnchor` returns. Owns everything in it; nothing borrows
/// the caller's `source` or `bytes` once the call is back.
pub const Inlined = struct {
    /// What the file's reader and the bridge said about the FILE, in its
    /// own byte coordinates — never the document's. Filled whatever the
    /// outcome, because a reader's complaint is worth saying either way.
    file_diags: Diag.List,
    /// The plan, or why there is none.
    outcome: Outcome,

    /// Free the report and whichever plan the outcome holds.
    pub fn deinit(self: *Inlined) void {
        switch (self.outcome) {
            .plan, .unread => |*p| p.deinit(),
            .not_a_root, .too_large, .unparsed, .unencoded => {},
        }
        self.file_diags.deinit();
        self.* = undefined;
    }
};

/// Inline `anchor`: its file, `bytes`, read and printed as its tier, and
/// the tier as `insert_root` actions landing straight after the anchor in
/// `source`.
///
/// `anchor` must come from a `Doc` loaded out of `source` — its span is
/// how the landing root is found, and a span from any other text is
/// `.not_a_root` rather than a guess. `bytes` is the anchor's file; the
/// caller verified it (`doc.fromSource` does, against `:size` and
/// `:sha256`) and it is only read. Pure and total: whatever the inputs,
/// the answer is an `Inlined`, and only an allocation can fail. `gpa`
/// backs the returned value, freed by its `deinit`; scratch is freed
/// before the call returns.
pub fn inlineAnchor(
    gpa: Allocator,
    source: [:0]const u8,
    anchor: *const doc.Anchor,
    bytes: []const u8,
) Error!Inlined {
    var file_diags: Diag.List = .init(gpa);
    errdefer file_diags.deinit();
    const tier = try tierText(gpa, anchor.kind, bytes, &file_diags);
    defer gpa.free(tier);
    const outcome = try planFor(gpa, source, anchor.span, tier);
    return .{ .file_diags = file_diags, .outcome = outcome };
}

/// The anchor's file as the tier forms `tempura dump` prints for it,
/// with the bridges' default switches (the header says why). The
/// reader's diagnostics go into `diags` first, then the bridge's own.
/// Caller frees the text.
fn tierText(
    gpa: Allocator,
    kind: doc.AnchorKind,
    bytes: []const u8,
    diags: *Diag.List,
) Error![]u8 {
    switch (kind) {
        .smf => {
            var res = try smf.read(gpa, bytes);
            defer res.deinit();
            try diags.extend(res.diags.items());
            return doc.bridge_smf.sequenceToForms(gpa, &res.sequence, null, .{ .qualify = true });
        },
        .it => {
            var res = try itf.read.read(gpa, bytes);
            defer res.deinit();
            try diags.extend(res.diags.items());
            return doc.bridge_it.moduleToForms(gpa, &res.module, .{
                .qualify = true,
                .source_map = &res.source_map,
                .diags = diags,
            });
        },
    }
}

/// The plan for `tier`, landing after the root of `source` spanned by
/// `span` — or why there is none.
///
/// Both texts are parsed here, and SJON's parser holds a text to its
/// file ceiling as a PRECONDITION (an assertion, which in ReleaseSmall
/// is undefined behaviour), so the ceiling is checked first and a text
/// past it is an answer, not a trap.
fn planFor(gpa: Allocator, source: [:0]const u8, span: Diag.Span, tier: []const u8) Error!Outcome {
    const ceiling = sjon.Binary.MAX_FILE_SIZE;
    if (source.len > ceiling) return .{ .too_large = source.len };
    if (tier.len > ceiling) return .{ .too_large = tier.len };
    const at = try rootIndexOf(gpa, source, span) orelse return .not_a_root;
    return planInsert(gpa, tier, at + 1);
}

/// Which root of `source` has exactly this span.
///
/// The document layer recorded the anchor's span when it walked the
/// tree; a fresh parse of the same bytes gives the same spans, so the
/// match is a lookup and not a search for something like it.
fn rootIndexOf(gpa: Allocator, source: [:0]const u8, span: Diag.Span) Error!?usize {
    var tree = try sjon.parse(gpa, source);
    defer tree.deinit();
    for (tree.root, 0..) |node, i| {
        const s = tree.spanOf(node);
        if (s.start == span.start and s.end == span.end) return i;
    }
    return null;
}

/// The tier's roots as `insert_root` actions, starting at root `at`.
///
/// The bridge produces SJON TEXT and an action carries a JSON VALUE, so
/// the text is parsed and encoded through SJON's own JSON bridge (§9) —
/// the encoding SJON decodes and prints on the way back in, which is why
/// the tier lands as the forms it was rather than as a string.
///
/// There is no OPERATION here, because inlining is not one of plan 07's:
/// it changes what the document HOLDS rather than what it says about the
/// music, and no selection resolves against a file that is not in the
/// document yet. So the actions are written as a list and handed to
/// `fromActionsJson`, the engine's own reader for exactly this — which
/// decides each action's kind, site and slot, and refuses anything that
/// is not an action list, so this file is not a second author of the
/// action grammar (`Plan.zig`: "`fromActionsJson(p.text())` gives
/// `p.text()` again").
fn planInsert(gpa: Allocator, tier: []const u8, at: usize) Error!Outcome {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const text = try arena.dupeZ(u8, tier);
    var tree = try sjon.parse(gpa, text);
    defer tree.deinit();
    if (tree.hasErrors()) return .unparsed;

    var encoded = sjon.toJsonRoots(gpa, tree, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .unencoded = @errorName(e) },
    };
    defer encoded.deinit();

    const roots = rootsOf(encoded.value);
    const list = try actionList(arena, roots, at);
    const plan = try plan_file.fromActionsJson(gpa, list);
    if (plan.summary.refused or plan.actions.len != roots.len) return .{ .unread = plan };
    return .{ .plan = plan };
}

/// The `$roots` array SJON's JSON bridge wraps a multi-root tree in, or
/// nothing when the encoding has none. Borrowed from `value`.
fn rootsOf(value: std.json.Value) []const std.json.Value {
    return switch (value) {
        .object => |o| switch (o.get("$roots") orelse .null) {
            .array => |xs| xs.items,
            else => &.{},
        },
        else => &.{},
    };
}

/// The action LIST as text, one `insert_root` per root, in `arena`.
/// `Plan.text` spells an empty plan `[]`, and so does this: a tier with
/// no roots is not one a bridge prints, and the reader should not have
/// to take a list that is only whitespace.
fn actionList(arena: Allocator, roots: []const std.json.Value, at: usize) Error![]const u8 {
    var list: std.Io.Writer.Allocating = .init(arena);
    // An allocating writer fails one way only — its allocator — so a
    // failed write IS an exhausted arena.
    writeActions(&list.writer, roots, at) catch return error.OutOfMemory;
    return list.written();
}

fn writeActions(
    w: *std.Io.Writer,
    roots: []const std.json.Value,
    at: usize,
) std.Io.Writer.Error!void {
    if (roots.len == 0) return w.writeAll("[]\n");
    try w.writeAll("[\n");
    for (roots, 0..) |value, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.print("{{\"op\":\"insert_root\",\"index\":{d},\"value\":", .{at + i});
        try std.json.Stringify.value(value, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("\n]\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A two-event `.mid` — a tempo and one note — through the canonical
/// writer, so the test holds real bytes without a file. Caller frees.
fn smfBytes(gpa: Allocator) ![]u8 {
    var b: smf.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const track = try b.addTrack();
    try b.addEvent(track, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(track, 96, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    var seq = try b.finish();
    defer seq.deinit();
    var written = try smf.write(gpa, &seq, .{});
    defer written.deinit();
    return gpa.dupe(u8, written.bytes);
}

/// A document arranged around `bytes` BY REFERENCE, with the file's own
/// `:size` and `:sha256` — the shape inlining exists for — and a comment
/// and a lane after the anchor, so the layout has something to keep.
fn byReference(gpa: Allocator, bytes: []const u8) ![:0]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrintSentinel(gpa,
        \\; a document arranged around a file it does not carry
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(anchor :id song :kind smf :file "song.mid" :size {d} :sha256 "{x}")
        \\
        \\(lane :name flash :target flash
        \\  ; the downbeat
        \\  (note :at 0q :dur 0.5q :key 36 :vel 110))
        \\
    , .{ bytes.len, &digest }, 0);
}

/// The anchor's bytes, the document around them, and the document
/// loaded with the bytes resolvable — what `tempura inline` holds by the
/// time it calls `inlineAnchor`, with no filesystem anywhere.
const Held = struct {
    bytes: []u8,
    source: [:0]u8,
    schema: Schema,
    loaded: doc.Result,

    fn init(gpa: Allocator) !Held {
        const bytes = try smfBytes(gpa);
        errdefer gpa.free(bytes);
        const source = try byReference(gpa, bytes);
        errdefer gpa.free(source);
        var schema = try Schema.load(gpa);
        errdefer schema.deinit();
        const table: doc.Memory = .{ .entries = &.{.{ .path = "song.mid", .bytes = bytes }} };
        var loaded = try doc.fromSource(gpa, &schema, source, doc.memory(&table));
        errdefer loaded.deinit();
        if (loaded.diags.hasErrors()) return error.FixtureDocumentHasErrors;
        return .{ .bytes = bytes, .source = source, .schema = schema, .loaded = loaded };
    }

    fn anchor(self: *const Held) *const doc.Anchor {
        return self.loaded.doc.anchorById("song").?;
    }

    fn deinit(self: *Held, gpa: Allocator) void {
        self.loaded.deinit();
        self.schema.deinit();
        gpa.free(self.source);
        gpa.free(self.bytes);
    }
};

test "inlineAnchor: an SMF anchor's tier lands after its anchor, with the layout kept" {
    const gpa = testing.allocator;
    var held = try Held.init(gpa);
    defer held.deinit(gpa);

    var inlined = try inlineAnchor(gpa, held.source, held.anchor(), held.bytes);
    defer inlined.deinit();
    try testing.expect(!inlined.file_diags.hasErrors());
    const plan = &inlined.outcome.plan;
    // Two roots — the `(midi/smf …)` header and the file's one `(midi/mtrk
    // …)` — inserted in order as the anchor's next siblings: the anchor is
    // root 3 of this text.
    try testing.expectEqual(@as(usize, 2), plan.actions.len);
    for (plan.actions, 0..) |action, i| {
        try testing.expectEqual(plan_file.Kind.insert_root, action.kind);
        try testing.expectEqual(@as(?u32, @intCast(4 + i)), action.slot);
    }

    var applied = try apply_file.apply(gpa, held.source, plan);
    defer applied.deinit();
    try testing.expect(!applied.diags.hasErrors());
    const text = applied.text;
    const anchor_at = std.mem.indexOf(u8, text, "(anchor :id song").?;
    const tier_at = std.mem.indexOf(u8, text, "(midi/smf ").?;
    const lane_at = std.mem.indexOf(u8, text, "(lane :name flash").?;
    try testing.expect(anchor_at < tier_at and tier_at < lane_at);
    // Every authored byte survived, comments included.
    try testing.expect(std.mem.startsWith(u8, text, "; a document arranged around"));
    try testing.expect(std.mem.indexOf(u8, text, "  ; the downbeat\n  (note :at 0q") != null);
}

test "inlineAnchor: an anchor from another text is not_a_root, never a guess" {
    const gpa = testing.allocator;
    var held = try Held.init(gpa);
    defer held.deinit(gpa);

    // The same document one byte later: every span moved, so the
    // anchor's recorded span names no root of this text.
    const shifted = try std.fmt.allocPrintSentinel(gpa, " {s}", .{held.source}, 0);
    defer gpa.free(shifted);

    var inlined = try inlineAnchor(gpa, shifted, held.anchor(), held.bytes);
    defer inlined.deinit();
    try testing.expect(inlined.outcome == .not_a_root);
}

test "inlineAnchor: the reader's complaints about the FILE ride out, and a plan still comes" {
    const gpa = testing.allocator;
    var held = try Held.init(gpa);
    defer held.deinit(gpa);

    // A truncated file: the reader keeps the prefix it parsed and says
    // so in the file's own coordinates. The anchor is only its span here,
    // so the tier of whatever was read still lands.
    const cut = held.bytes[0 .. held.bytes.len - 2];
    var inlined = try inlineAnchor(gpa, held.source, held.anchor(), cut);
    defer inlined.deinit();
    try testing.expect(inlined.file_diags.items().len > 0);
    try testing.expect(inlined.outcome == .plan);
}

test "inlineAnchor: OutOfMemory at every allocation, and nothing leaks" {
    // The house sweep: at EVERY allocation index the call fails with
    // error.OutOfMemory and testing.allocator sees no leak; past the last
    // index it succeeds. Bounded by the number of allocations the call
    // makes, which the loop discovers.
    const gpa = testing.allocator;
    var held = try Held.init(gpa);
    defer held.deinit(gpa);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const result = inlineAnchor(failing.allocator(), held.source, held.anchor(), held.bytes);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var value = try result;
            defer value.deinit();
            try testing.expect(value.outcome == .plan);
            break;
        }
    }
}
