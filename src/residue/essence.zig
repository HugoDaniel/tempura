//! The essence: the document's TIMELINE TIER as SJON Binary IR.
//!
//! Plan 04, "What the residue is", item 1: every root that is not part of
//! the `midi/` or `it/` dump of the carrying file, encoded with SJON's
//! wire-stable Binary IR in its LOSSLESS mode — every span, every comment
//! site — so what comes back out is the document a human wrote and not a
//! re-derivation of it.
//!
//! **From the TREE, not from the `Doc`.** A `Doc` is a value: it has no
//! comments, no blank lines, no authored layout. The essence is what the
//! author typed, so `pack` re-parses the source, selects the roots and
//! clones them into a sub-tree (`Ast.TreeBuilder.cloneNode`, which carries
//! the leading and trailing comment ranges with each node). The `Doc` is
//! read for one thing only: WHICH anchor is the carrying file's.
//!
//! **The carrying anchor becomes a marker.** The file the residue rides
//! in cannot name itself by path, size or digest: the path is wherever
//! the file was copied to, and the size and the digest both change the
//! moment the residue is written into it. So the carrying `(anchor :id X
//! :kind K :file "…" :size … :sha256 …)` is replaced by
//! `(anchor :id X :kind K :file "self")` — `:id` and `:kind` cloned from
//! the source so their spelling survives, `:file` the marker
//! `self_file`, and nothing else. A reader substitutes the file it just
//! read. (Plan 04 spells the marker `:file self`; `:file` is a `string`
//! slot in `schema/tempura.sjon`, so the marker is the quoted `"self"` —
//! the essence has to re-validate as a document.)
//!
//! **Two versions, two owners.** `ver = 1` in the eight-byte envelope
//! (`records.zig`) versions the ENVELOPE and is the carrier's to check.
//! The IR's own wire version rides in the body's header (`SJ1\n` then one
//! byte, `SJON/docs/LANGUAGE.md` §10.1) and is this file's: a body from a
//! newer substrate comes back as `.version`, opaque and intact, so an
//! older tempura never re-prints what it could not fully read (plan 04,
//! rule 3 and "Binary IR versions").
//!
//! **A tier this wire cannot hold is said out loud.** SJON's Binary IR
//! has limits (`MAX_NODES`, `MAX_COMMENTS_PER_NODE = 256`,
//! `MAX_STRING_LENGTH`, the depth cap — §10.6), and a document past one
//! of them has NO essence. `pack` returns that as an empty body beside a
//! `residue_unencodable` diagnostic rather than as a quiet nothing,
//! because a carrier with no essence writes a file that says only what
//! its own format can say — which a build has to be told.
//!
//! ```zig
//! var packed_tier = try essence.pack(gpa, &doc, source);
//! defer packed_tier.deinit(gpa);
//! if (packed_tier.diags.hasErrors()) { /* residue_unencodable */ }
//!
//! var got = try essence.unpack(gpa, packed_tier.bytes);
//! defer got.deinit(gpa);
//! switch (got) {
//!     .ok => |e| { /* e.text is SJON, NUL-terminated, ready for fromSource */ },
//!     .version => |v| { /* keep the bytes, derive a skeleton */ },
//!     .corrupt => |code| { /* code is residue_corrupt */ },
//! }
//! ```

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const Doc = @import("../doc/Value.zig");

const Ast = sjon.Ast;
const Allocator = std.mem.Allocator;
const NodeIndex = Ast.NodeIndex;
const testing = std.testing;

/// Packing and unpacking can only fail the way any allocation fails: a
/// defective body is a returned variant, never an error.
pub const Error = error{OutOfMemory};

/// The `:file` of the carrying anchor's marker — the file the residue is
/// riding in, whatever it is called where it was found.
pub const self_file = "self";

/// The timeline tier, recovered.
///
/// `text` is the essence re-printed as SJON in the printer's `full` mode
/// (comments kept), NUL-terminated so it can be handed straight to
/// `doc.fromSource`. `roots` is how many top-level forms it holds.
pub const Essence = struct {
    text: [:0]u8,
    roots: u32,
};

/// What `unpack` made of a body.
pub const Unpacked = union(enum) {
    /// The essence, re-printed.
    ok: Essence,
    /// The body is Binary IR of a wire version this substrate does not
    /// decode; the byte is that version. The caller keeps the bytes as
    /// they are (plan 04, rule 3).
    version: u8,
    /// The body is not decodable Binary IR at all — `residue_corrupt`.
    corrupt: Diag.Code,

    pub fn deinit(self: *Unpacked, gpa: Allocator) void {
        switch (self.*) {
            .ok => |e| gpa.free(e.text),
            .version, .corrupt => {},
        }
    }
};

/// The anchor the document is arranged around, when one can be named
/// without asking: the `:conductor`'s, else the only anchor there is.
///
/// A document with several anchors and no conductor cannot say which
/// file a residue is riding in — the builder knows and `packFor` takes
/// it.
pub fn carrierOf(doc: *const Doc.Doc) ?Doc.AnchorId {
    if (doc.conductor) |id| {
        if (doc.anchorById(id) != null) return id;
    }
    if (doc.anchors.len == 1) return doc.anchors[0].id;
    return null;
}

/// A packed essence and what it cost.
///
/// `bytes` is empty exactly when the tier could not be encoded, and
/// `diags` then carries `residue_unencodable` naming the SJON limit that
/// stopped it. A carrier handed an empty body writes no essence, so the
/// diagnostic is the only thing standing between a too-wide document and
/// a file that silently holds no timeline at all.
pub const Packed = struct {
    bytes: []u8,
    diags: Diag.List,

    pub fn deinit(self: *Packed, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.diags.deinit();
    }
};

/// The timeline tier of `source`, as Binary IR.
///
/// The carrying anchor is `carrierOf(doc)`; `packFor` takes it when the
/// caller knows better.
pub fn pack(gpa: Allocator, doc: *const Doc.Doc, source: [:0]const u8) Error!Packed {
    return packFor(gpa, source, carrierOf(doc));
}

/// `pack` with the carrying anchor named — the builder knows which file
/// it is writing, where `carrierOf` can only guess. `null` rewrites
/// nothing, which is right for a document with no anchor at all.
pub fn packFor(
    gpa: Allocator,
    source: [:0]const u8,
    carrier: ?Doc.AnchorId,
) Error!Packed {
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var tree = try sjon.parse(gpa, source);
    defer tree.deinit();

    // The sub-tree is built into its own arena, which `finalize` moves
    // into the `Tree` — so the arena is deinited through `sub`, once.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var b: Ast.TreeBuilder = .{ .a = arena.allocator() };
    var roots: std.ArrayList(NodeIndex) = .empty;

    for (tree.root) |idx| {
        if (isDump(&tree, idx)) continue;
        const cloned = if (carrier != null and isCarryingAnchor(&tree, idx, carrier.?))
            try marker(&b, &tree, idx)
        else
            try b.cloneNode(&tree, idx);
        try roots.append(arena.allocator(), cloned);
    }

    // The comments after the last root are the document's, not any
    // node's, and they are a channel of their own on the wire
    // (`with_tree_trailing_comments`, §10.2) — so they are cloned
    // explicitly, exactly as SJON's own `Edit` pass clones them.
    var sub = try b.finalizeWith(&arena, source, roots.items, .{
        .tree_trailing_comments = try b.cloneCommentRange(&tree, tree.tree_trailing_comments),
    });
    defer sub.deinit();

    var bytes = sjon.toBinary(gpa, sub, .forMode(.full)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Every other `Binary.Error` is a LIMIT: `MAX_NODES` (2^20),
        // `MAX_COMMENTS_PER_NODE` (256 — a 257-line comment block ahead
        // of one form reaches it), `MAX_STRING_LENGTH`, the depth cap
        // (§10.6). There is then NO essence, and a file that carries no
        // essence says nothing the format cannot — which a build has to
        // be told, or the loss is silent.
        else => {
            try diags.add(
                .residue_unencodable,
                .err,
                .{ .start = 0, .end = 0 },
                "the timeline tier is past SJON's Binary IR limits ({t}; see LANGUAGE.md §10.6), so no essence was packed and this file would carry nothing the format cannot say itself",
                .{err},
            );
            return .{ .bytes = try gpa.alloc(u8, 0), .diags = diags };
        },
    };
    defer bytes.deinit();
    return .{ .bytes = try gpa.dupe(u8, bytes.data), .diags = diags };
}

/// A body back into SJON text.
///
/// Total on arbitrary bytes: every malformed input is `.corrupt`, every
/// unknown wire version is `.version`, and neither is a Zig error.
pub fn unpack(gpa: Allocator, bytes: []const u8) Error!Unpacked {
    var tree = sjon.fromBinary(gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The one recoverable refusal: a body this substrate's decoder
        // has no tables for. The version byte is the header's fifth
        // (§10.1), and `parseHeader` checked the magic before it.
        error.InvalidVersion => return .{ .version = if (bytes.len > 4) bytes[4] else 0 },
        else => return .{ .corrupt = .residue_corrupt },
    };
    defer tree.deinit();

    var text = try sjon.print(gpa, tree, .forMode(.full));
    defer text.deinit();

    return .{ .ok = .{
        .text = try gpa.dupeZ(u8, text.data),
        .roots = @intCast(tree.root.len),
    } };
}

// ---- selecting the roots ---------------------------------------------

/// Whether a root belongs to the carrying file's dump: a `midi/…` or
/// `it/…` form. The hosted tiers are the file's own content, which the
/// file already holds — the residue never duplicates a home (plan 04,
/// "One home").
fn isDump(tree: *const Ast.Tree, idx: NodeIndex) bool {
    if (tree.tagOf(idx) != .form) return false;
    const ns = tree.formHeader(idx).namespace orelse return false;
    return std.mem.eql(u8, ns, "midi") or std.mem.eql(u8, ns, "it");
}

/// Whether this root is `(anchor :id <carrier> …)`.
fn isCarryingAnchor(tree: *const Ast.Tree, idx: NodeIndex, carrier: Doc.AnchorId) bool {
    if (tree.tagOf(idx) != .form) return false;
    const h = tree.formHeader(idx);
    if (!std.mem.eql(u8, h.head, "anchor")) return false;
    if (h.namespace) |ns| {
        if (!std.mem.eql(u8, ns, "tempura")) return false;
    }
    const id = keyValue(tree, idx, "id") orelse return false;
    const text = atomText(tree, id) orelse return false;
    return std.mem.eql(u8, text, carrier);
}

/// The value node of `(… :key value …)`, or null.
fn keyValue(tree: *const Ast.Tree, form: NodeIndex, key: []const u8) ?NodeIndex {
    for (tree.formHeader(form).children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

/// The text of a symbol or a string node — the two spellings an `:id` or
/// a `:kind` can take.
fn atomText(tree: *const Ast.Tree, idx: NodeIndex) ?[]const u8 {
    return switch (tree.tagOf(idx)) {
        .symbol => tree.symbolText(idx),
        .string => tree.stringText(idx),
        else => null,
    };
}

/// `(anchor :id X :kind K :file "self")`, with `:id` and `:kind` cloned
/// from the source so their spelling is the author's, and the leading
/// comments of the anchor kept.
fn marker(
    b: *Ast.TreeBuilder,
    tree: *const Ast.Tree,
    idx: NodeIndex,
) Error!NodeIndex {
    const h = tree.formHeader(idx);
    const span = tree.spanOf(idx);

    var children: [3]NodeIndex = undefined;
    var n: usize = 0;

    for ([_][]const u8{ "id", "kind" }) |key| {
        const value = keyValue(tree, idx, key) orelse continue;
        const cloned = try b.cloneNode(tree, value);
        children[n] = try b.addKvpair(try b.addString(key), cloned, span, span);
        n += 1;
    }

    const file = try b.appendString(self_file, span);
    children[n] = try b.addKvpair(try b.addString("file"), file, span, span);
    n += 1;

    const head = try b.addString(h.head);
    const ns: ?Ast.StringIndex = if (h.namespace) |s| try b.addString(s) else null;
    const form = try b.addForm(head, ns, h.head_span, children[0..n], span);

    b.setLeading(form, try b.cloneCommentRange(tree, tree.leading_comments_index[idx.raw()]));
    b.setTrailing(form, try b.cloneCommentRange(tree, tree.trailing_comments_index[idx.raw()]));
    return form;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const Schema = @import("../Schema.zig");
const fromSjon = @import("../doc/fromSjon.zig");

/// The plan's own example, as `examples/native.sjon` ships it.
fn readExample(gpa: Allocator) ![:0]u8 {
    const repo_root = @import("build_options").repo_root;
    const path = try std.fs.path.join(gpa, &.{ repo_root, "examples", "native.sjon" });
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);
    return gpa.dupeZ(u8, bytes);
}

/// Every root of `source`, printed one by one in the printer's lossless
/// mode — the shape a form has, independent of this file's packer.
fn formsOf(gpa: Allocator, source: [:0]const u8) !std.ArrayList([]u8) {
    var tree = try sjon.parse(gpa, source);
    defer tree.deinit();

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (tree.root) |idx| {
        var text = try sjon.Printer.printNode(gpa, tree, idx, .forMode(.full), 0);
        defer text.deinit();
        try out.append(gpa, try gpa.dupe(u8, text.data));
    }
    return out;
}

fn freeForms(gpa: Allocator, forms: *std.ArrayList([]u8)) void {
    for (forms.items) |s| gpa.free(s);
    forms.deinit(gpa);
}

test "essence: the 02 example packs and unpacks form-identical, comments and all" {
    const gpa = testing.allocator;
    const source = try readExample(gpa);
    defer gpa.free(source);

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var loaded = try fromSjon.fromSource(gpa, &schema, source, null);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 0), loaded.diags.items().len);

    var packed_essence = try pack(gpa, &loaded.doc, source);
    defer packed_essence.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), packed_essence.diags.items().len);

    var got = try unpack(gpa, packed_essence.bytes);
    defer got.deinit(gpa);
    try testing.expect(got == .ok);

    // Form for form against the SOURCE's own roots, printed by SJON
    // rather than by anything here — the anchor is the one that differs,
    // and it differs into the marker.
    var want = try formsOf(gpa, source);
    defer freeForms(gpa, &want);
    var have = try formsOf(gpa, got.ok.text);
    defer freeForms(gpa, &have);

    try testing.expectEqual(want.items.len, have.items.len);
    try testing.expectEqual(@as(u32, @intCast(want.items.len)), got.ok.roots);
    for (want.items, have.items) |w, h| {
        if (std.mem.startsWith(u8, w, "(anchor")) {
            try testing.expectEqualStrings("(anchor :id song :kind it :file \"self\")", h);
        } else {
            try testing.expectEqualStrings(w, h);
        }
    }

    // Comments survive: the trivia channels the `full` mode keeps.
    for ([_][]const u8{
        "; A native timeline document",
        "; the document conducts itself",
        "; windows may overlap",
        "; bound: content is the module's",
        "; pacer's form, pass-through",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, got.ok.text, needle) != null);
    }
}

test "essence: the unpacked text is a document again, and packing it is stable" {
    const gpa = testing.allocator;
    const source = try readExample(gpa);
    defer gpa.free(source);

    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var first = try fromSjon.fromSource(gpa, &schema, source, null);
    defer first.deinit();

    var packed_essence = try pack(gpa, &first.doc, source);
    defer packed_essence.deinit(gpa);
    var got = try unpack(gpa, packed_essence.bytes);
    defer got.deinit(gpa);

    // It loads clean: the marker is a valid anchor, and a document that
    // names no file it cannot read raises nothing.
    var again = try fromSjon.fromSource(gpa, &schema, got.ok.text, null);
    defer again.deinit();
    if (again.diags.items().len != 0) {
        for (again.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
        return error.UnexpectedDiagnostics;
    }
    try testing.expectEqualStrings(self_file, again.doc.anchorById("song").?.file);
    try testing.expect(again.doc.anchorById("song").?.size == null);
    try testing.expectEqual(first.doc.lanes.len, again.doc.lanes.len);
    try testing.expectEqual(first.doc.sections.len, again.doc.sections.len);
    try testing.expectEqual(first.doc.passthrough.len, again.doc.passthrough.len);

    // And a second round changes nothing: the essence is a fixed point.
    var packed_again = try pack(gpa, &again.doc, got.ok.text);
    defer packed_again.deinit(gpa);
    var got2 = try unpack(gpa, packed_again.bytes);
    defer got2.deinit(gpa);
    try testing.expectEqualStrings(got.ok.text, got2.ok.text);
}

test "essence: the file tiers are not in it, and the anchor's dump goes with them" {
    const gpa = testing.allocator;
    const source =
        \\(timeline :title "anchored" :conductor song)
        \\(anchor :id song :kind it :file "impulse-04.it" :size 12 :sha256 "abc")
        \\(it/module :title "impulse-04")
        \\(midi/smf :format 1)
        \\(section :name intro :at 0bar :dur 4bar)
        \\
    ;
    var doc: Doc.Doc = .empty(gpa);
    defer doc.deinit();
    var anchors = [_]Doc.Anchor{.{
        .id = "song",
        .kind = .it,
        .file = "impulse-04.it",
        .size = 12,
        .sha256 = null,
        .sha256_src = "abc",
        .inline_dump = true,
        .resolved = false,
        .span = .{ .start = 0, .end = 1 },
    }};
    doc.anchors = &anchors;
    doc.conductor = "song";

    var packed_essence = try pack(gpa, &doc, source);
    defer packed_essence.deinit(gpa);
    var got = try unpack(gpa, packed_essence.bytes);
    defer got.deinit(gpa);

    try testing.expectEqual(@as(u32, 3), got.ok.roots);
    try testing.expect(std.mem.indexOf(u8, got.ok.text, "it/module") == null);
    try testing.expect(std.mem.indexOf(u8, got.ok.text, "midi/smf") == null);
    try testing.expect(std.mem.indexOf(u8, got.ok.text, "(section") != null);
    // The marker: `:id` and `:kind` as authored, `:file` the file itself,
    // and neither the path nor the size nor the digest of a file that is
    // about to change under both.
    try testing.expect(std.mem.indexOf(u8, got.ok.text, "(anchor :id song :kind it :file \"self\")") != null);
    try testing.expect(std.mem.indexOf(u8, got.ok.text, "impulse-04.it") == null);
    try testing.expect(std.mem.indexOf(u8, got.ok.text, ":size") == null);
}

test "essence: a document with no carrying anchor keeps every anchor as written" {
    const gpa = testing.allocator;
    const source =
        \\(timeline :title "two files")
        \\(anchor :id a :kind smf :file "one.mid")
        \\(anchor :id b :kind smf :file "two.mid")
        \\
    ;
    var doc: Doc.Doc = .empty(gpa);
    defer doc.deinit();
    var anchors = [_]Doc.Anchor{
        .{ .id = "a", .kind = .smf, .file = "one.mid", .size = null, .sha256 = null, .sha256_src = null, .inline_dump = false, .resolved = false, .span = .{ .start = 0, .end = 1 } },
        .{ .id = "b", .kind = .smf, .file = "two.mid", .size = null, .sha256 = null, .sha256_src = null, .inline_dump = false, .resolved = false, .span = .{ .start = 0, .end = 1 } },
    };
    doc.anchors = &anchors;

    try testing.expect(carrierOf(&doc) == null);

    var packed_essence = try pack(gpa, &doc, source);
    defer packed_essence.deinit(gpa);
    var got = try unpack(gpa, packed_essence.bytes);
    defer got.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, got.ok.text, "one.mid") != null);
    try testing.expect(std.mem.indexOf(u8, got.ok.text, "two.mid") != null);

    // Named explicitly, the second one becomes the marker and the first
    // stays a file by reference.
    var packed_b = try packFor(gpa, source, "b");
    defer packed_b.deinit(gpa);
    var got_b = try unpack(gpa, packed_b.bytes);
    defer got_b.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, got_b.ok.text, "one.mid") != null);
    try testing.expect(std.mem.indexOf(u8, got_b.ok.text, "two.mid") == null);
    try testing.expect(std.mem.indexOf(u8, got_b.ok.text, "(anchor :id b :kind smf :file \"self\")") != null);
}

test "essence: a newer wire version is kept opaque, and rubbish is residue_corrupt" {
    const gpa = testing.allocator;
    const source = "(timeline :title \"v\")\n";
    var doc: Doc.Doc = .empty(gpa);
    defer doc.deinit();

    var packed_essence = try pack(gpa, &doc, source);
    defer packed_essence.deinit(gpa);
    const body = packed_essence.bytes;

    // The header's fifth byte is the IR's wire version (§10.1). Bumped,
    // the body is a future tempura's and this one keeps it as bytes
    // rather than re-printing what it could not fully read.
    const newer = try gpa.dupe(u8, body);
    defer gpa.free(newer);
    newer[4] = sjon.Binary.wire_version + 1;
    var v = try unpack(gpa, newer);
    defer v.deinit(gpa);
    try testing.expectEqual(@as(u8, sjon.Binary.wire_version + 1), v.version);

    // Everything else is `residue_corrupt`: a truncated body, a wrong
    // magic, and no body at all.
    for ([_][]const u8{ body[0..8], "not a binary ir at all", "", "SJ1\n" }) |bad| {
        var c = try unpack(gpa, bad);
        defer c.deinit(gpa);
        try testing.expectEqual(Diag.Code.residue_corrupt, c.corrupt);
    }
}

test "essence: the comments after the last root ride too" {
    // `Tree.tree_trailing_comments` is its own channel on the wire
    // (§10.2) and belongs to the document rather than to any node, so a
    // clone that only walks the roots loses the end of the file.
    const gpa = testing.allocator;
    const source =
        \\(timeline :title "ends in prose")
        \\
        \\; the last word is a comment
        \\; and so is this one
        \\
    ;
    var doc: Doc.Doc = .empty(gpa);
    defer doc.deinit();

    var packed_essence = try pack(gpa, &doc, source);
    defer packed_essence.deinit(gpa);
    var got = try unpack(gpa, packed_essence.bytes);
    defer got.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, got.ok.text, "; the last word is a comment") != null);
    try testing.expect(std.mem.indexOf(u8, got.ok.text, "; and so is this one") != null);
}

test "essence: a tier past SJON's limits is residue_unencodable, never a silent nothing" {
    // `MAX_COMMENTS_PER_NODE` is 256 (§10.6), so a 257-line comment
    // block ahead of one form is a document this wire cannot carry. The
    // old behaviour was an empty body and no word about it, which would
    // have written a file holding nothing of the timeline.
    const gpa = testing.allocator;

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..257) |i| {
        var line: [32]u8 = undefined;
        try src.appendSlice(gpa, std.fmt.bufPrint(&line, "; comment {d}\n", .{i}) catch unreachable);
    }
    try src.appendSlice(gpa, "(timeline :title \"buried\")\n");
    const source = try src.toOwnedSliceSentinel(gpa, 0);
    defer gpa.free(source);

    var doc: Doc.Doc = .empty(gpa);
    defer doc.deinit();

    var packed_essence = try packFor(gpa, source, null);
    defer packed_essence.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), packed_essence.bytes.len);
    try testing.expectEqual(@as(usize, 1), packed_essence.diags.count(.residue_unencodable));
    try testing.expect(packed_essence.diags.hasErrors());
}
