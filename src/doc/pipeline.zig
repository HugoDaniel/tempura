//! The `dump` pipeline: a `.mid` or a `.it` in, a document out.
//!
//! Plan 10's `dump` row and `check-residue` row, over plan 04's five
//! reconciliation rules. One function per verb and nothing else — the
//! rules are `residue/reconcile.zig`'s, the reading is the format
//! cores', the printing is `toSjon.zig`'s; what lives here is the
//! ASSEMBLY, which is the one step that needs all of them at once.
//!
//! ```
//! bytes
//!   → smf.read / itf.read.read                      the file as a value
//!   → residue.smf.detach / residue.it.choose         what the carrier held
//!   → bridge_smf.sequenceToForms / bridge_it.moduleToForms   the file tier
//!   → reconcile.reconcile                           the timeline tier
//!   → splice the two                                one document source
//!   → doc.fromSource                                every host check runs
//! ```
//!
//! # Why it lives in `doc/`
//!
//! Everywhere else in this part the arrow points one way: `doc/` owns
//! the value and `residue/`, `time/`, `edit/` and `export/` consume it
//! (plan 01, "Layering rule"). This file is the exception the brief
//! names, and it is deliberate: a dump is not a residue operation with a
//! document on the side, it is a DOCUMENT being assembled out of three
//! sources, and the assembly belongs where documents are made. Nothing
//! else in `doc/` imports it, so the dependency is one file deep.
//!
//! # The text is the author's, not a re-derivation
//!
//! `dump` returns the ASSEMBLED source, not a re-print of the document it
//! loaded. That is the whole point of the essence: it is packed in
//! SJON's lossless mode so that "what comes back out is the document a
//! human wrote and not a re-derivation of it" (`residue/essence.zig`),
//! and canonicalising it here would throw away every comment, blank line
//! and authored spelling the carrier went to the trouble of keeping.
//! The canonical printer is still in the chain — it is what
//! `reconcile.derive` uses for the three rules that have no authored
//! text to restore (no residue, a newer version, a corrupt payload) —
//! but a restored document is handed back as it was written.
//!
//! The source is loaded through `fromSource` all the same, and its
//! diagnostics are in the returned list: a dump that does not read back
//! as a document fails HERE, on the way out, rather than in an editor.
//! That load is also what resolves an `it/` dump's `(bin :at :len)`
//! regions, which is why the resolver is an in-memory table holding the
//! very bytes that were read (the anchor's `:size` and `:sha256` were
//! computed from them a moment earlier, so it verifies by construction).
//!
//! # The tier text is the CALLER's
//!
//! `toSjon.print` re-renders an inline dump with the bridge's DEFAULT
//! switches, which would undo `--patterns=bin`, `--preserve-foreign` and
//! `--preserve-history`. So the file tier is produced once, here, with
//! the caller's own options, and spliced into the gap `reconcile` leaves
//! for it — straight after the `(anchor …)` it pairs with, because that
//! pairing is positional (plan 02).
//!
//! ```zig
//! var dumped = try pipeline.dump(gpa, &schema, bytes, .smf, .{});
//! defer dumped.deinit();
//! // dumped.text, dumped.doc, dumped.map, dumped.diags, dumped.verdicts
//! ```

const std = @import("std");

const Diag = @import("../Diag.zig");
const Schema = @import("../Schema.zig");
const TimeMap = @import("../time/TimeMap.zig");
const smf = @import("../smf/smf.zig");
const itf = @import("../itf/itf.zig");
const residue_smf = @import("../residue/smf.zig");
const residue_it = @import("../residue/it.zig");
const records = @import("../residue/records.zig");
const reconcile = @import("../residue/reconcile.zig");

const Doc = @import("Value.zig");
const Resolver = @import("Resolver.zig");
const bridge_it = @import("bridge_it.zig");
const bridge_smf = @import("bridge_smf.zig");
const fromSjon = @import("fromSjon.zig");
const time_derive = @import("../time/derive.zig");
const render_smf = @import("../export/render_smf.zig");
const render_it = @import("../export/render_it.zig");
const residue_essence = @import("../residue/essence.zig");
const walk = @import("../itf/walk.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const testing = std.testing;

/// Only resource exhaustion is an error. A defective file, a defective
/// residue and a document that will not re-read are all diagnostics on
/// the returned value.
pub const Error = error{OutOfMemory};

/// The anchor id a dumped document uses when the caller names none. One
/// file per dump, so one name, and it is the one every fixture spells.
pub const anchor_id = "song";

pub const Options = struct {
    /// What the anchor's `:file` says. Null takes `song.mid` or
    /// `song.it` from the kind — a dump of bytes with no name still has
    /// to produce an anchor, and the name is the caller's to override.
    file: ?[]const u8 = null,
    /// The anchor's `:id`, for a DERIVED document. A restored one keeps
    /// the id the author wrote, which the marker carries.
    anchor_id: []const u8 = anchor_id,
    /// `--cues`: one cue per played IT order, on the skeleton path.
    cues: bool = false,
    /// Whether an inline dump's heads carry their tier's namespace.
    qualify: bool = true,
    /// it 03's three switches, which only the `it/` bridge reads.
    patterns_bin: bool = false,
    preserve_foreign: bool = false,
    preserve_history: bool = false,
};

/// A file, dumped.
///
/// `doc` BORROWS the bytes it was dumped from: an `it/` tier's `:raw`
/// and `data` regions are offsets into them and are never copied (plan
/// 06, "bytes are sacred"). The bytes must outlive this value.
pub const Dumped = struct {
    /// The document as SJON text, NUL-terminated so it can be handed
    /// straight back to `fromSource`.
    text: [:0]u8,
    doc: Doc.Doc,
    /// The document's own `TimeMap`, as `fromSource` derived it.
    map: TimeMap.TimeMap,
    /// Everything the read, the carrier, the reconciliation and the
    /// re-load had to say, in that order.
    diags: Diag.List,
    verdicts: []const reconcile.LaneVerdict,
    conductor: ?reconcile.ConductorVerdict,
    /// Which of plan 04's five rules produced the timeline tier.
    rule: reconcile.Rule,

    gpa: Allocator,
    /// `reconcile`'s arena — it owns `verdicts` and every string in
    /// them.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Dumped) void {
        self.gpa.free(self.text);
        self.map.deinit();
        self.doc.deinit();
        self.diags.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// The verdict for the lane named `name`, or null.
    pub fn verdictFor(self: *const Dumped, name: []const u8) ?reconcile.LaneVerdict {
        for (self.verdicts) |v| {
            if (std.mem.eql(u8, v.lane, name)) return v;
        }
        return null;
    }
};

/// A `.mid` or a `.it` as a document — plan 10's `dump` row, whole.
pub fn dump(
    gpa: Allocator,
    schema: *const Schema,
    bytes: []const u8,
    kind: Doc.AnchorKind,
    opts: Options,
) Error!Dumped {
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    const name = opts.file orelse defaultFile(kind);

    return switch (kind) {
        .smf => dumpSmf(gpa, schema, bytes, name, opts, &diags),
        .it => dumpIt(gpa, schema, bytes, name, opts, &diags),
    };
}

/// The name an anchor takes when the caller gives none.
pub fn defaultFile(kind: Doc.AnchorKind) []const u8 {
    return switch (kind) {
        .smf => "song.mid",
        .it => "song.it",
    };
}

fn dumpSmf(
    gpa: Allocator,
    schema: *const Schema,
    bytes: []const u8,
    name: []const u8,
    opts: Options,
    diags: *Diag.List,
) Error!Dumped {
    var read = try smf.read(gpa, bytes);
    defer read.deinit();
    try copyDiags(diags, &read.diags);

    // The version is read BEFORE the detach, because detach's whole
    // answer to a newer envelope is to leave it alone: it takes nothing
    // out and reports `residue_version`, and rule 3 needs the byte.
    const newer = newerSmf(&read.sequence);

    var detached = try residue_smf.detach(gpa, &read.sequence);
    defer detached.deinit();
    try copyDiags(diags, &detached.diags);

    const tier = try bridge_smf.sequenceToForms(gpa, &detached.sequence, null, .{
        .qualify = opts.qualify,
    });
    defer gpa.free(tier);

    // A residue the CARRIER could not read is rule 4, never rule 1: a
    // split essence with a part missing comes back as no essence at all,
    // and handing that on as `.payloads` would head the document "no
    // residue found" while `detach` has already said `residue_corrupt`.
    // The carrier names the loss; this only routes it.
    const found: reconcile.Found = if (newer) |v|
        .{ .newer = v }
    else if (detached.diags.count(.residue_corrupt) > 0)
        .corrupt
    else
        .{ .payloads = detached.payloads };

    return assemble(gpa, schema, bytes, name, opts, diags, .{
        .tier = .{ .smf = &detached.sequence },
        .text = tier,
        .bytes = bytes,
        .name = name,
    }, found);
}

fn dumpIt(
    gpa: Allocator,
    schema: *const Schema,
    bytes: []const u8,
    name: []const u8,
    opts: Options,
    diags: *Diag.List,
) Error!Dumped {
    var read = try itf.read.read(gpa, bytes);
    defer read.deinit();
    try copyDiags(diags, &read.diags);

    const chunk_bytes = if (read.module.tmpu) |r| r.slice(bytes) else null;
    const newer = newerIt(chunk_bytes);

    // `choose`'s own report goes into a list of its own first: whether
    // it found the chunk UNREADABLE is the difference between rule 4 and
    // rule 1, and the merged list cannot be asked that question.
    var carrier: Diag.List = .init(gpa);
    defer carrier.deinit();
    var chosen = try residue_it.choose(gpa, chunk_bytes, read.module.message, &carrier);
    defer chosen.deinit();
    try copyDiags(diags, &carrier);

    // The tail is TEXT in IT's own encoding — CR newlines, `%XX` escapes
    // — and rule 5 reads it as SJON, so it is undone here rather than
    // inside the rule.
    const tail_src: ?[:0]u8 = switch (chosen) {
        .tail => |text| try residue_it.parseTail(gpa, text),
        else => null,
    };
    defer if (tail_src) |t| gpa.free(t);

    const tier = try bridge_it.moduleToForms(gpa, &read.module, .{
        .qualify = opts.qualify,
        .patterns_bin = opts.patterns_bin,
        .preserve_foreign = opts.preserve_foreign,
        .preserve_history = opts.preserve_history,
        .source_map = &read.source_map,
        .diags = diags,
    });
    defer gpa.free(tier);

    // Plan 04's rule 5 decides the order, and `choose` has already
    // applied it: the chunk wins when it is readable, and the TAIL wins
    // over a chunk that is absent, corrupt or truncated — with
    // `residue_partial` naming what the tail cannot carry. So a corrupt
    // chunk beside a tail is rule 5, not rule 4, and only a corrupt
    // chunk with NO tail falls through to the skeleton.
    const found: reconcile.Found = switch (chosen) {
        .chunk => |p| .{ .payloads = p.payloads },
        .tail => .{ .tail = tail_src.? },
        // A chunk of a version this build does not read, with no tail to
        // fall back on, is rule 3 and not rule 1: the payload is still
        // in the file, as the opaque region the writer re-emits. One
        // whose framing does not hold is rule 4, for the same reason —
        // the file carried a residue, and saying "no residue found" over
        // a `residue_corrupt` would be two surfaces disagreeing.
        .none => if (newer) |v|
            .{ .newer = v }
        else if (carrier.count(.residue_corrupt) > 0)
            .corrupt
        else
            .none,
    };

    return assemble(gpa, schema, bytes, name, opts, diags, .{
        .tier = .{ .it = &read.module },
        .text = tier,
        .bytes = bytes,
        .name = name,
    }, found);
}

/// Reconcile, splice, load — the half both kinds share.
fn assemble(
    gpa: Allocator,
    schema: *const Schema,
    bytes: []const u8,
    name: []const u8,
    opts: Options,
    diags: *Diag.List,
    file: reconcile.File,
    found: reconcile.Found,
) Error!Dumped {
    var rec = try reconcile.reconcile(gpa, schema, file, found, .{
        .cues = opts.cues,
        .anchor_id = opts.anchor_id,
    });
    // The arena is handed on and the diagnostics are merged, so neither
    // is released by `rec.deinit()` — which is why this is not a
    // `defer`.
    errdefer rec.deinit();
    try copyDiags(diags, &rec.diags);

    const at = @min(rec.tier_at, rec.doc_text.len);
    const text = try std.mem.concatWithSentinel(gpa, u8, &.{
        rec.doc_text[0..at],
        file.text,
        rec.doc_text[at..],
    }, 0);
    errdefer gpa.free(text);

    // The reader's OWN bytes, handed back by name: the anchor's `:size`
    // and `:sha256` were computed from them, so it verifies without a
    // second read of anything, and every `(bin :at :len)` resolves.
    const store: Resolver.Memory = .{ .entries = &.{.{ .path = name, .bytes = bytes }} };
    var loaded = try fromSjon.fromSource(gpa, schema, text, Resolver.memory(&store));
    errdefer loaded.deinit();
    try copyDiags(diags, &loaded.diags);
    loaded.diags.deinit();

    rec.diags.deinit();
    return .{
        .text = text,
        .doc = loaded.doc,
        .map = loaded.map,
        .diags = diags.*,
        .verdicts = rec.verdicts,
        .conductor = rec.conductor,
        .rule = rec.rule,
        .gpa = gpa,
        .arena = rec.arena,
    };
}

/// Append every diagnostic of `from` to `into`, message and span kept.
fn copyDiags(into: *Diag.List, from: *const Diag.List) Error!void {
    for (from.items()) |d| try into.add(d.code, d.severity, d.span, "{s}", .{d.message});
}

/// The envelope version of the first residue payload this build does not
/// read, or null when every payload is its own.
fn newerSmf(seq: *const smf.Sequence) ?u8 {
    for (seq.tracks) |t| {
        for (t.events) |e| {
            if (e.kind != .tempura_residue) continue;
            if (e.payload.residue.ver != records.version) return e.payload.residue.ver;
        }
    }
    return null;
}

/// The same question of a `TMPU` chunk, asked of its first record's
/// head alone: a chunk this build cannot read is one it will not step
/// through.
fn newerIt(chunk_bytes: ?[]const u8) ?u8 {
    const bytes = chunk_bytes orelse return null;
    const head = records.readHead(bytes) orelse return null;
    return if (head.ver != records.version) head.ver else null;
}

// ---------------------------------------------------------------------
// check-residue
// ---------------------------------------------------------------------

/// What `checkResidue` reports.
pub const Report = struct {
    /// The verdict table, one fact per line, NO trailing blank line.
    text: []u8,
    diags: Diag.List,
    gpa: Allocator,

    pub fn deinit(self: *Report) void {
        self.gpa.free(self.text);
        self.diags.deinit();
        self.* = undefined;
    }
};

/// What a file carries, and whether the file still agrees with it —
/// plan 10's `check-residue` row.
///
/// The same hashes `reconcile` asks (`reconcile.Hasher`), shown rather
/// than applied: nothing is restored, no schema is needed, and a file
/// with no residue reports that in one line.
pub fn checkResidue(gpa: Allocator, bytes: []const u8, kind: Doc.AnchorKind) Error!Report {
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    switch (kind) {
        .smf => {
            var read = try smf.read(gpa, bytes);
            defer read.deinit();
            try copyDiags(&diags, &read.diags);

            if (newerSmf(&read.sequence)) |v| {
                try out.print(gpa, "residue: envelope version {d}, which this build does not read\n", .{v});
                return .{ .text = try out.toOwnedSlice(gpa), .diags = diags, .gpa = gpa };
            }

            var detached = try residue_smf.detach(gpa, &read.sequence);
            defer detached.deinit();
            try copyDiags(&diags, &detached.diags);

            try table(gpa, &out, .{ .smf = &detached.sequence }, detached.payloads, null);
        },
        .it => {
            var read = try itf.read.read(gpa, bytes);
            defer read.deinit();
            try copyDiags(&diags, &read.diags);

            const chunk_bytes = if (read.module.tmpu) |r| r.slice(bytes) else null;
            if (newerIt(chunk_bytes)) |v| {
                try out.print(gpa, "residue: envelope version {d}, which this build does not read\n", .{v});
                return .{ .text = try out.toOwnedSlice(gpa), .diags = diags, .gpa = gpa };
            }

            var quiet: Diag.List = .init(gpa);
            defer quiet.deinit();
            var chosen = try residue_it.choose(gpa, chunk_bytes, read.module.message, &quiet);
            defer chosen.deinit();
            try copyDiags(&diags, &quiet);

            const split = residue_it.splitMessage(read.module.message);
            try out.print(gpa, "chunk: {s}\ntail: {s}\n", .{
                if (chunk_bytes == null)
                    "absent"
                else if (chosen == .chunk)
                    "present, read"
                else
                    "present, not readable",
                if (split.tail == null) "absent" else "present",
            });

            const payloads: records.Payloads = switch (chosen) {
                .chunk => |p| p.payloads,
                else => .{},
            };
            try table(gpa, &out, .{ .it = &read.module }, payloads, split.tail);
        },
    }

    return .{ .text = try out.toOwnedSlice(gpa), .diags = diags, .gpa = gpa };
}

/// The essence line, the conductor line and one line per lane record.
fn table(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tier: reconcile.Tier,
    payloads: records.Payloads,
    tail: ?[]const u8,
) Error!void {
    const essence = payloads.essence orelse &.{};
    if (essence.len == 0) {
        if (tail != null) {
            try out.appendSlice(gpa, "essence: none; the message tail alone\n");
        } else {
            try out.appendSlice(gpa, "essence: none\n");
        }
    } else {
        try out.print(gpa, "essence: {d} bytes, envelope version {d}\n", .{ essence.len, records.version });
    }

    var hasher: reconcile.Hasher = .init(gpa, tier);
    defer hasher.deinit();

    if (payloads.conductor) |body| {
        const rec = records.decodeConductor(body);
        const ok = if (rec) |r| std.mem.eql(u8, &r.hash, &hasher.conductor()) else false;
        try out.print(gpa, "conductor: {s}\n", .{verdictWord(rec != null, ok)});
    } else {
        try out.appendSlice(gpa, "conductor: no record\n");
    }

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    for (payloads.lanes) |body| {
        var decoded = try records.decodeLane(gpa, body);
        defer decoded.deinit(gpa);
        switch (decoded) {
            .ok => |r| {
                const now = try hasher.lane(r.address);
                try out.print(gpa, "lane {s}: {s}, {s}\n", .{
                    r.lane,
                    try reconcile.addressProse(scratch.allocator(), r.address),
                    verdictWord(true, std.mem.eql(u8, &r.hash, &now)),
                });
            },
            .corrupt => try out.appendSlice(gpa, "lane: record does not decode\n"),
        }
    }
}

fn verdictWord(decoded: bool, ok: bool) []const u8 {
    if (!decoded) return "record does not decode";
    return if (ok) "hash matches" else "hash differs";
}

// ---------------------------------------------------------------------
// build
// ---------------------------------------------------------------------

/// `build`'s switches — plan 10's `build` row, and plan 08's renderers
/// under it.
///
/// `in_place` is the HOST's: this function produces bytes and never
/// touches a path. It rides here so a CLI can carry one options value.
pub const BuildOptions = struct {
    /// Write a file that carries nothing the format cannot say itself.
    no_residue: bool = false,
    /// Write tempura's own residue even over one a NEWER tempura left in
    /// the anchor (plan 04, rule 3).
    force_residue: bool = false,

    // ---- the `.mid` side ----
    ppq: u15 = render_smf.default_ppq,
    /// `--cc`: which controller a native curve lane renders onto.
    cc: ?u7 = null,
    cc_rate: i64 = render_smf.default_cc_rate,
    section_markers: bool = false,
    format0: bool = false,
    running_status: bool = true,

    // ---- the `.it` side ----
    speed: u8 = 6,
    rows: u16 = 64,
    voices: u8 = 4,
    /// `--fx "Z"`: render curves as this effect letter's parameter byte.
    fx: ?u8 = null,
    loose: bool = false,

    /// The anchor's own bytes, where an `it/` tier's opaque regions are
    /// copied from. Null for a native document, which has none.
    anchor_bytes: ?[]const u8 = null,
    /// The host's, kept here so one options value crosses the CLI.
    in_place: bool = false,
};

/// A document, built.
pub const Built = struct {
    bytes: []const u8,
    /// One per rendered native lane — what rode in the file, with the
    /// hash of what was written at each address.
    lanes: []const records.LaneRecord,
    conductor: ?records.ConductorRecord,
    /// How many bytes of essence rode in the file; zero when none did.
    essence_bytes: usize,
    diags: Diag.List,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Built) void {
        self.gpa.free(self.bytes);
        self.diags.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// A document as a `.mid` or a `.it` — plan 10's `build` row, whole.
///
/// ```
/// doc
///   → render_smf.renderSmf / render_it.renderIt    the native view
///   → residue.essence.pack + the lane records      what the format cannot say
///   → residue.smf.attach / residue.it.chunk + tail the carriers
///   → smf.write / itf.write.write                  the canonical bytes
/// ```
///
/// **The records are hashed over the FILE.** The renderers hash what they
/// wrote, which is the same thing whenever the writer's layout is the
/// renderer's; `--format 0` is the case where it is not, because the
/// writer merges tracks the renderer kept apart. So this function writes
/// once WITHOUT the residue, reads that back, and hashes the addresses
/// exactly as a `dump` of the finished bytes will — then attaches and
/// writes for real. A residue payload is a meta event or a trailing
/// chunk, so it never moves a hash, and the two writes agree by
/// construction.
///
/// Cross-kind is refused (plan 08, "Cross-kind builds"): v1 builds a
/// document into its own anchor's kind, or, for a native document, into
/// either.
pub fn build(
    gpa: Allocator,
    schema: *const Schema,
    doc_source: [:0]const u8,
    doc: *const Doc.Doc,
    derived: *const time_derive.Derived,
    kind: Doc.AnchorKind,
    opts: BuildOptions,
) Error!Built {
    // Nothing here validates: the document was handed over BY
    // `fromSource`, which is where every host check runs, and a second
    // reading of the schema would be a second opinion about a document
    // that already has one. The parameter is in the signature because
    // plan 10's verb holds a schema and every other entry point here
    // takes it.
    _ = schema;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    const pieces: Pieces = if (try refuseCrossKind(&diags, doc, kind))
        .{ .bytes = try gpa.alloc(u8, 0), .lanes = &.{}, .conductor = null, .essence_bytes = 0 }
    else switch (kind) {
        .smf => try buildSmf(gpa, arena.allocator(), doc_source, doc, derived, opts, &diags),
        .it => try buildIt(gpa, arena.allocator(), doc_source, doc, derived, opts, &diags),
    };

    return .{
        .bytes = pieces.bytes,
        .lanes = pieces.lanes,
        .conductor = pieces.conductor,
        .essence_bytes = pieces.essence_bytes,
        .diags = diags,
        .gpa = gpa,
        .arena = arena,
    };
}

/// What one kind's build produced, before it is wrapped.
const Pieces = struct {
    bytes: []const u8,
    lanes: []const records.LaneRecord,
    conductor: ?records.ConductorRecord,
    essence_bytes: usize,
};

/// Plan 08's "Cross-kind builds": true when this document may not be
/// built into `kind` at all.
fn refuseCrossKind(diags: *Diag.List, doc: *const Doc.Doc, kind: Doc.AnchorKind) Error!bool {
    if (doc.anchors.len == 0) return false;
    for (doc.anchors) |a| {
        if (a.kind == kind) return false;
    }
    try diags.add(
        .build_cross_kind,
        .err,
        doc.anchors[0].span,
        "this document is arranged around a {t} anchor and a {t} file was asked for; v1 builds a document into its own anchor's kind, or a native document into either (plan 08)",
        .{ doc.anchors[0].kind, kind },
    );
    return true;
}

/// Whether this build writes a residue of its own. A newer tempura's
/// payloads are kept where they are unless the caller insists (plan 04,
/// rule 3).
fn wantsResidue(diags: *Diag.List, opts: BuildOptions, newer: ?u8) Error!bool {
    if (opts.no_residue) return false;
    const v = newer orelse return true;
    if (opts.force_residue) return true;
    try diags.add(
        .residue_newer_kept,
        .warning,
        .{ .start = 0, .end = 0 },
        "this anchor carries a residue of envelope version {d}, which this build does not read; it was kept and no residue of this build's own was written (--force-residue overrides)",
        .{v},
    );
    return false;
}

/// The lane records as carrier bodies. Caller frees each.
fn encodeLanes(gpa: Allocator, lanes: []const records.LaneRecord) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |b| gpa.free(b);
        out.deinit(gpa);
    }
    for (lanes) |rec| try out.append(gpa, try records.encodeLane(gpa, rec));
    return out.toOwnedSlice(gpa);
}

fn freeBodies(gpa: Allocator, bodies: []const []const u8) void {
    for (bodies) |b| gpa.free(b);
    gpa.free(bodies);
}

/// A rendered record into the caller's arena, with the hash the file
/// itself answers.
fn keepRecord(a: Allocator, src: records.LaneRecord, hash: [32]u8) Error!records.LaneRecord {
    const segments = try a.alloc(records.Segment, src.steps_only.len);
    for (src.steps_only, segments) |from, *to| to.* = .{
        .at = from.at,
        .ease = try a.dupe(u8, from.ease),
    };
    return .{
        .lane = try a.dupe(u8, src.lane),
        .address = src.address,
        .hash = hash,
        .steps_only = segments,
    };
}

fn buildSmf(
    gpa: Allocator,
    a: Allocator,
    doc_source: [:0]const u8,
    doc: *const Doc.Doc,
    derived: *const time_derive.Derived,
    opts: BuildOptions,
    diags: *Diag.List,
) Error!Pieces {
    // The anchor's own `Sequence`, when the document carries one: the
    // lanes render INTO it and its tracks come out unchanged.
    const base: ?*const smf.Sequence = blk: {
        for (doc.midi) |*tier| {
            const anchor = doc.anchorById(tier.anchor) orelse continue;
            if (anchor.kind == .smf) break :blk &tier.sequence;
        }
        break :blk null;
    };

    var rendered = try render_smf.renderSmf(gpa, doc, derived, base, .{
        .ppq = opts.ppq,
        .cc = opts.cc,
        .cc_rate = opts.cc_rate,
        .section_markers = opts.section_markers,
        .format0 = opts.format0,
    });
    defer rendered.deinit();
    try copyDiags(diags, &rendered.diags);

    const wopts: smf.Options = .{
        .running_status = opts.running_status,
        .format0 = opts.format0,
    };

    const lanes = try a.alloc(records.LaneRecord, rendered.lanes.len);
    var conductor: ?records.ConductorRecord = null;
    {
        var pass1 = try smf.write(gpa, &rendered.seq, wopts);
        defer pass1.deinit();
        var back = try smf.read(gpa, pass1.bytes);
        defer back.deinit();

        const ppq = back.sequence.division.pulsesPerQuarter();
        for (rendered.lanes, lanes) |src, *dst| {
            const address = src.address.smf;
            dst.* = try keepRecord(a, src, records.hashSmfLane(
                &back.sequence,
                address.track - 1,
                address.ch,
                ppq,
            ));
        }
        if (rendered.conductor != null) {
            conductor = .{ .hash = records.hashSmfConductor(&back.sequence) };
        }
    }

    if (!try wantsResidue(diags, opts, if (base) |s| newerSmf(s) else null)) {
        var plain = try smf.write(gpa, &rendered.seq, wopts);
        defer plain.deinit();
        try copyDiags(diags, &plain.diags);
        return .{
            .bytes = try gpa.dupe(u8, plain.bytes),
            .lanes = lanes,
            .conductor = conductor,
            .essence_bytes = 0,
        };
    }

    var packed_tier = try residue_essence.pack(gpa, doc, doc_source);
    defer packed_tier.deinit(gpa);
    try copyDiags(diags, &packed_tier.diags);

    const bodies = try encodeLanes(gpa, lanes);
    defer freeBodies(gpa, bodies);

    var cond_body: [32]u8 = undefined;
    const cond_slice: ?[]const u8 = if (conductor) |c| blk: {
        cond_body = records.encodeConductor(c);
        break :blk &cond_body;
    } else null;

    var carried = try residue_smf.attach(gpa, &rendered.seq, .{
        .essence = packed_tier.bytes,
        .conductor = cond_slice,
        .lanes = bodies,
    }, .{});
    defer carried.deinit();
    try copyDiags(diags, &carried.diags);

    var file = try smf.write(gpa, &carried.sequence, wopts);
    defer file.deinit();
    try copyDiags(diags, &file.diags);

    return .{
        .bytes = try gpa.dupe(u8, file.bytes),
        .lanes = lanes,
        .conductor = conductor,
        .essence_bytes = packed_tier.bytes.len,
    };
}

fn buildIt(
    gpa: Allocator,
    a: Allocator,
    doc_source: [:0]const u8,
    doc: *const Doc.Doc,
    derived: *const time_derive.Derived,
    opts: BuildOptions,
    diags: *Diag.List,
) Error!Pieces {
    const base: ?*const itf.Module = blk: {
        for (doc.it) |*tier| {
            const anchor = doc.anchorById(tier.anchor) orelse continue;
            if (anchor.kind == .it) break :blk &tier.module;
        }
        break :blk null;
    };

    var rendered = try render_it.renderIt(gpa, doc, derived, base, .{
        .speed = opts.speed,
        .rows = opts.rows,
        .voices = opts.voices,
        .fx = opts.fx,
    });
    defer rendered.deinit();
    try copyDiags(diags, &rendered.diags);

    // The HUMAN half of the song message alone: a rebuild of a document
    // that was dumped from a `.it` would otherwise stack one tail on the
    // one the file already carried.
    const human = residue_it.splitMessage(rendered.module.message).human;
    rendered.module.message = human;

    const source = opts.anchor_bytes;
    const wopts: itf.write.Options = .{
        .loose = opts.loose,
        // Not a build switch: the block is in the document only because
        // `dump --preserve-history` put it there.
        .preserve_history = rendered.module.edit_history != null,
    };

    const lanes = try a.alloc(records.LaneRecord, rendered.lanes.len);
    var conductor: ?records.ConductorRecord = null;
    {
        var pass1 = try itf.write.write(gpa, &rendered.module, source, wopts);
        defer pass1.deinit();
        var back = try itf.read.read(gpa, pass1.bytes);
        defer back.deinit();

        var rows = try walk.derive(gpa, &back.module, .{});
        defer rows.deinit();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const pats = try reconcile.playedPatterns(scratch.allocator(), &rows);

        for (rendered.lanes, lanes) |src, *dst| {
            dst.* = try keepRecord(a, src, records.hashItLane(
                &back.module,
                &rows,
                &[_]u8{src.address.it.channel},
                pats,
            ));
        }
        if (rendered.conductor != null) {
            conductor = .{ .hash = records.hashItConductor(&back.module) };
        }
    }

    const newer = if (base) |m| blk: {
        const region = m.tmpu orelse break :blk null;
        const bytes = source orelse break :blk null;
        break :blk newerIt(region.slice(bytes));
    } else null;

    if (!try wantsResidue(diags, opts, newer)) {
        var plain = try itf.write.write(gpa, &rendered.module, source, wopts);
        defer plain.deinit();
        try copyDiags(diags, &plain.diags);
        return .{
            .bytes = try gpa.dupe(u8, plain.bytes),
            .lanes = lanes,
            .conductor = conductor,
            .essence_bytes = 0,
        };
    }

    var packed_tier = try residue_essence.pack(gpa, doc, doc_source);
    defer packed_tier.deinit(gpa);
    try copyDiags(diags, &packed_tier.diags);

    const bodies = try encodeLanes(gpa, lanes);
    defer freeBodies(gpa, bodies);

    var cond_body: [32]u8 = undefined;
    const cond_slice: ?[]const u8 = if (conductor) |c| blk: {
        cond_body = records.encodeConductor(c);
        break :blk &cond_body;
    } else null;

    const payload = try residue_it.chunk(gpa, .{
        .essence = packed_tier.bytes,
        .conductor = cond_slice,
        .lanes = bodies,
    });
    defer gpa.free(payload);

    var tail = try residue_it.tail(gpa, doc, &derived.map);
    defer tail.deinit(gpa);
    try copyDiags(diags, &tail.diags);
    const whole = try residue_it.appendTail(gpa, human, tail.bytes);
    defer gpa.free(whole);

    var file = try itf.write.write(gpa, &rendered.module, source, .{
        .loose = wopts.loose,
        .preserve_history = wopts.preserve_history,
        .tmpu = payload,
        .message_tail = whole[human.len..],
    });
    defer file.deinit();
    try copyDiags(diags, &file.diags);

    return .{
        .bytes = try gpa.dupe(u8, file.bytes),
        .lanes = lanes,
        .conductor = conductor,
        .essence_bytes = packed_tier.bytes.len,
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// A small document with one native lane, so the file it builds into has
/// exactly one lane record and one conductor record.
const smf_doc: [:0]const u8 =
    \\; a small piece
    \\(timeline :title "small")
    \\
    \\(anchor :id song :kind smf :file "song.mid" :size 1 :sha256 "9f2a")
    \\
    \\(tempo-point :at 0bar :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(lane :name kick :kind notes
    \\  (note :at 0bar :dur 1q :key 36))
    \\
;

const it_doc: [:0]const u8 =
    \\; a small module
    \\(timeline :title "smaller")
    \\
    \\(anchor :id song :kind it :file "song.it" :size 1 :sha256 "9f2a")
    \\
    \\(tempo-point :at 0bar :qpm 125)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(lane :name kick :kind notes
    \\  (note :at 0bar :dur 1q :key 60))
    \\
;

/// The music `smf_doc`'s lane renders to.
fn smfSequence(gpa: Allocator, vel: u7) !smf.Sequence {
    var b: smf.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = 96 };

    const t0 = try b.addTrack();
    try b.addEvent(t0, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(t0, 0, .time_signature, .{ .time_sig = .{ .nn = 4, .dd = 2, .cc = 24, .bb = 8 } });
    try b.addEvent(t0, 192, .end_of_track, .empty);

    const t1 = try b.addTrack();
    try b.addEvent(t1, 0, .note_on, .{ .note = .{ .ch = 0, .key = 36, .vel = vel } });
    try b.addEvent(t1, 96, .note_off, .{ .note = .{ .ch = 0, .key = 36, .vel = 64 } });
    try b.addEvent(t1, 192, .end_of_track, .empty);
    return b.finish();
}

/// A `.mid` with the residue in it, as `build` would write one. `ver`
/// re-stamps the envelope, which is the only way to make a file a newer
/// tempura's without a newer tempura.
fn smfBytes(gpa: Allocator, ver: u8, residue: bool) ![]u8 {
    var seq = try smfSequence(gpa, 100);
    defer seq.deinit();

    if (!residue) {
        var plain = try smf.write(gpa, &seq, .{});
        defer plain.deinit();
        return gpa.dupe(u8, plain.bytes);
    }

    const lane = try records.encodeLane(gpa, .{
        .lane = "kick",
        .address = .{ .smf = .{ .track = 2, .ch = 0, .key = 36, .curve = null } },
        .hash = records.hashSmfLane(&seq, 1, 0, 96),
    });
    defer gpa.free(lane);
    const conductor = records.encodeConductor(.{ .hash = records.hashSmfConductor(&seq) });

    var packed_tier = try residue_essence.packFor(gpa, smf_doc, "song");
    defer packed_tier.deinit(gpa);

    var carried = try residue_smf.attach(gpa, &seq, .{
        .essence = packed_tier.bytes,
        .conductor = &conductor,
        .lanes = &.{lane},
    }, .{});
    defer carried.deinit();
    if (ver != records.version) {
        for (carried.sequence.tracks) |t| {
            for (t.events) |*e| {
                if (e.kind == .tempura_residue) e.payload.residue.ver = ver;
            }
        }
    }

    var file = try smf.write(gpa, &carried.sequence, .{});
    defer file.deinit();
    return gpa.dupe(u8, file.bytes);
}

fn itModule(gpa: Allocator) !itf.Module {
    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();
    const p0 = try b.addPattern(64);
    p0.at(0, 0).* = .{ .note = 60, .ins = 1, .vol = 64 };
    p0.at(16, 0).* = .{ .note = 60, .ins = 1, .vol = 64 };
    try b.addOrder(0);
    try b.setMessage("a song about the sea");
    return b.finish();
}

/// A `.it` with both carriers in it.
fn itBytes(gpa: Allocator, schema: *const Schema, residue: bool) ![]u8 {
    var module = try itModule(gpa);
    defer module.deinit();

    if (!residue) {
        var plain = try itf.write.write(gpa, &module, null, .{});
        defer plain.deinit();
        return gpa.dupe(u8, plain.bytes);
    }

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var rows = try walk.derive(gpa, &module, .{});
    defer rows.deinit();
    const pats = try reconcile.playedPatterns(scratch.allocator(), &rows);

    const lane = try records.encodeLane(gpa, .{
        .lane = "kick",
        .address = .{ .it = .{ .channel = 0, .column = null, .fx = null } },
        .hash = records.hashItLane(&module, &rows, &[_]u8{0}, pats),
    });
    defer gpa.free(lane);
    const conductor = records.encodeConductor(.{ .hash = records.hashItConductor(&module) });

    var packed_tier = try residue_essence.packFor(gpa, it_doc, "song");
    defer packed_tier.deinit(gpa);
    const payload = try residue_it.chunk(gpa, .{
        .essence = packed_tier.bytes,
        .conductor = &conductor,
        .lanes = &.{lane},
    });
    defer gpa.free(payload);

    var loaded = try fromSjon.fromSource(gpa, schema, it_doc, null);
    defer loaded.deinit();
    var t = try residue_it.tail(gpa, &loaded.doc, &loaded.map);
    defer t.deinit(gpa);
    const whole = try residue_it.appendTail(gpa, module.message, t.bytes);
    defer gpa.free(whole);

    var file = try itf.write.write(gpa, &module, null, .{
        .tmpu = payload,
        .message_tail = whole[module.message.len..],
    });
    defer file.deinit();
    return gpa.dupe(u8, file.bytes);
}

test "pipeline: a .mid with no residue dumps to the skeleton, and it reads back" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const bytes = try smfBytes(gpa, records.version, false);
    defer gpa.free(bytes);

    var got = try dump(gpa, &schema, bytes, .smf, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.derived, got.rule);
    // The assembled text READ BACK as a document: that is what the
    // `fromSource` in the middle is for, and an error here is tempura's
    // and never the file's.
    try testing.expect(!got.diags.hasErrors());
    try testing.expect(std.mem.startsWith(u8, got.text, "; skeleton: derived, no residue found"));
    // Both tiers, in the one order that reads back the same: the anchor,
    // then the dump it pairs with.
    const anchor_at = std.mem.indexOf(u8, got.text, "(anchor :id song").?;
    const tier_at = std.mem.indexOf(u8, got.text, "(midi/").?;
    try testing.expect(anchor_at < tier_at);
    // The skeleton's bound lane is in the document that came back.
    try testing.expectEqual(@as(usize, 1), got.doc.lanes.len);
    try testing.expect(got.doc.lanes[0].binding != null);
    try testing.expectEqual(@as(usize, 1), got.verdicts.len);
    try testing.expectEqual(reconcile.Action.skeleton, got.verdicts[0].action);
}

test "pipeline: a .mid with its residue dumps to the document that built it" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const bytes = try smfBytes(gpa, records.version, true);
    defer gpa.free(bytes);

    var got = try dump(gpa, &schema, bytes, .smf, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.restored, got.rule);
    try testing.expect(!got.diags.hasErrors());
    try testing.expect(got.conductor.?.hash_ok);
    try testing.expectEqual(@as(usize, 1), got.verdicts.len);
    try testing.expectEqual(reconcile.Action.restored_native, got.verdicts[0].action);

    // The author's own text, comment and all — not a re-derivation.
    try testing.expect(std.mem.indexOf(u8, got.text, "; a small piece") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "(note :at 0bar :dur 1q :key 36)") != null);
    // The lane is NATIVE: the address it was rendered to was consumed,
    // so it is not also a bound lane.
    try testing.expectEqual(@as(usize, 1), got.doc.lanes.len);
    try testing.expectEqual(@as(?Doc.Binding, null), got.doc.lanes[0].binding);
    try testing.expectEqual(@as(usize, 1), got.doc.lanes[0].notes.len);
    // The file tier is there and the residue is not: the dump consumes
    // the payloads.
    try testing.expect(std.mem.indexOf(u8, got.text, "(midi/") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "sequencer-specific") == null);
    // …and the anchor over the bytes really verifies, which is what
    // makes a dump a document that can be rebuilt.
    try testing.expectEqual(@as(usize, 1), got.doc.anchors.len);
    try testing.expectEqual(bytes.len, got.doc.anchors[0].size.?);
}

test "pipeline: a newer envelope keeps its payloads in the tier and says residue_version" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const bytes = try smfBytes(gpa, records.version + 1, true);
    defer gpa.free(bytes);

    var got = try dump(gpa, &schema, bytes, .smf, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.version, got.rule);
    try testing.expect(got.diags.count(.residue_version) > 0);
    try testing.expect(!got.diags.hasErrors());
    try testing.expect(std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue is a newer version"));
    // The payloads are still in the document, as the plain events
    // RP-001 told every reader to skip — so a later build can put them
    // back untouched.
    try testing.expect(std.mem.indexOf(u8, got.text, "sequencer-specific") != null);
}

test "pipeline: a .it dumps through both carriers, regions resolved against its own bytes" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const bytes = try itBytes(gpa, &schema, true);
    defer gpa.free(bytes);

    var got = try dump(gpa, &schema, bytes, .it, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.restored, got.rule);
    // No `anchor_unavailable`, no `anchor_mismatch`: the resolver was
    // handed the very bytes the anchor was written from.
    try testing.expect(!got.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), got.diags.count(.anchor_unavailable));
    try testing.expectEqual(@as(usize, 0), got.diags.count(.residue_partial));
    try testing.expect(std.mem.indexOf(u8, got.text, "; a small module") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "(it/") != null);
    try testing.expectEqual(@as(usize, 1), got.doc.it.len);
    try testing.expectEqual(@as(usize, 1), got.verdicts.len);
    try testing.expectEqual(reconcile.Action.restored_native, got.verdicts[0].action);
}

test "pipeline: checkResidue reports what a file carries, and what it does not" {
    const gpa = testing.allocator;

    // A `.mid` tempura wrote: the essence, the conductor and one lane,
    // all still agreeing with the music.
    {
        const bytes = try smfBytes(gpa, records.version, true);
        defer gpa.free(bytes);
        var rep = try checkResidue(gpa, bytes, .smf);
        defer rep.deinit();
        try testing.expect(std.mem.indexOf(u8, rep.text, "essence: ") != null);
        try testing.expect(std.mem.indexOf(u8, rep.text, "envelope version 1") != null);
        try testing.expect(std.mem.indexOf(u8, rep.text, "conductor: hash matches") != null);
        try testing.expect(std.mem.indexOf(
            u8,
            rep.text,
            "lane kick: track 2 ch 1 key 36, hash matches",
        ) != null);
    }

    // The same file with the music edited under it.
    {
        var seq = try smfSequence(gpa, 100);
        defer seq.deinit();
        const lane = try records.encodeLane(gpa, .{
            .lane = "kick",
            .address = .{ .smf = .{ .track = 2, .ch = 0, .key = 36, .curve = null } },
            .hash = records.hashSmfLane(&seq, 1, 0, 96),
        });
        defer gpa.free(lane);
        var edited = try smfSequence(gpa, 99);
        defer edited.deinit();
        var carried = try residue_smf.attach(gpa, &edited, .{ .lanes = &.{lane} }, .{});
        defer carried.deinit();
        var file = try smf.write(gpa, &carried.sequence, .{});
        defer file.deinit();

        var rep = try checkResidue(gpa, file.bytes, .smf);
        defer rep.deinit();
        try testing.expect(std.mem.indexOf(u8, rep.text, "essence: none") != null);
        try testing.expect(std.mem.indexOf(u8, rep.text, "conductor: no record") != null);
        try testing.expect(std.mem.indexOf(u8, rep.text, "hash differs") != null);
    }

    // A `.mid` nobody wrote a residue into.
    {
        const bytes = try smfBytes(gpa, records.version, false);
        defer gpa.free(bytes);
        var rep = try checkResidue(gpa, bytes, .smf);
        defer rep.deinit();
        try testing.expectEqualStrings(
            "essence: none\nconductor: no record\n",
            rep.text,
        );
    }
}

test "pipeline: checkResidue names both IT carriers" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const with = try itBytes(gpa, &schema, true);
    defer gpa.free(with);
    var rep = try checkResidue(gpa, with, .it);
    defer rep.deinit();
    try testing.expect(std.mem.indexOf(u8, rep.text, "chunk: present, read") != null);
    try testing.expect(std.mem.indexOf(u8, rep.text, "tail: present") != null);
    try testing.expect(std.mem.indexOf(u8, rep.text, "lane kick: channel 1, hash matches") != null);

    const without = try itBytes(gpa, &schema, false);
    defer gpa.free(without);
    var bare = try checkResidue(gpa, without, .it);
    defer bare.deinit();
    try testing.expect(std.mem.indexOf(u8, bare.text, "chunk: absent") != null);
    try testing.expect(std.mem.indexOf(u8, bare.text, "tail: absent") != null);
}

/// A NATIVE document — no anchor, so `build` has both kinds open to it
/// and the whole timeline has to ride in the residue.
const native_doc: [:0]const u8 =
    \\; a native piece — every root here has to come back out of the file
    \\(timeline :title "built" :length 2bar)
    \\
    \\(tempo-point :at 0bar :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(cue :name "drop" :at 1bar)
    \\
    \\(lane :name kick :kind notes
    \\  (note :at 0bar :dur 1q :key 36 :vel 100)
    \\  (note :at 1q :dur 1q :key 38 :vel 80))
    \\(lane :name glow :kind curve
    \\  (keyframe :at 0bar :value 0)
    \\  (keyframe :at 1bar :value 1 :ease linear))
    \\(lane :name hats :kind query :query (euclid 3 8 1))
    \\
;

/// One document, loaded and derived — what `build` takes.
const Ready = struct {
    res: fromSjon.Result,
    derived: time_derive.Derived,

    fn deinit(self: *Ready) void {
        self.derived.deinit();
        self.res.deinit();
    }
};

fn ready(gpa: Allocator, schema: *const Schema, source: [:0]const u8) !Ready {
    var res = try fromSjon.fromSource(gpa, schema, source, null);
    errdefer res.deinit();
    if (res.diags.hasErrors()) {
        for (res.diags.items()) |d| std.debug.print("build fixture: {t}: {s}\n", .{ d.code, d.message });
        return error.FixtureDoesNotLoad;
    }
    const derived = try time_derive.derive(gpa, &res.doc);
    return .{ .res = res, .derived = derived };
}

test "pipeline.build: a native document builds to a .mid that dumps back essence-exact" {
    // Plan 09's rung 3, and plan 08 phase 5's first red: the document
    // goes in, a `.mid` comes out, and the dump of that `.mid` is the
    // document again — form for form, comment for comment — with every
    // lane record's hash and the conductor record's hash matching.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var fx = try ready(gpa, &schema, native_doc);
    defer fx.deinit();

    var built = try build(gpa, &schema, native_doc, &fx.res.doc, &fx.derived, .smf, .{ .cc = 74 });
    defer built.deinit();
    try testing.expect(!built.diags.hasErrors());
    try testing.expect(built.essence_bytes > 0);
    // The two rendered lanes; the `query` lane is essence only.
    try testing.expectEqual(@as(usize, 2), built.lanes.len);
    try testing.expectEqual(@as(usize, 1), built.diags.count(.residue_only));
    try testing.expect(built.conductor != null);

    var got = try dump(gpa, &schema, built.bytes, .smf, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.restored, got.rule);
    try testing.expect(!got.diags.hasErrors());
    try testing.expect(got.conductor.?.hash_ok);
    try testing.expectEqual(@as(usize, 2), got.verdicts.len);
    for (got.verdicts) |v| {
        try testing.expect(v.hash_ok);
        try testing.expectEqual(reconcile.Action.restored_native, v.action);
    }
    // Essence-exact, plan 04's own words: the timeline tier comes back
    // FORM FOR FORM. The text is the essence re-printed by SJON, so the
    // claim is over the document it reads back as and not over its
    // layout — the tiers and the anchor the dump had to invent are
    // lifted off, and what is left has to be the document that went in.
    // (A shallow copy: the arena it names is the dumped document's.)
    var tier_free = got.doc;
    tier_free.anchors = &.{};
    tier_free.midi = &.{};
    tier_free.it = &.{};
    try testing.expect(tier_free.eql(&fx.res.doc));
    try testing.expectEqual(@as(usize, 3), got.doc.lanes.len);
    for (got.doc.lanes) |l| try testing.expect(l.binding == null);
    // Comments ride in the essence too (`pack` uses SJON's `full` mode).
    try testing.expect(std.mem.indexOf(u8, got.text, "; a native piece") != null);
    // And the easing the format cannot hold is back, verbatim.
    try testing.expect(std.mem.indexOf(u8, got.text, ":ease linear") != null);
}

test "pipeline.build: the same document builds to a .it that dumps back essence-exact" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var fx = try ready(gpa, &schema, native_doc);
    defer fx.deinit();

    var built = try build(gpa, &schema, native_doc, &fx.res.doc, &fx.derived, .it, .{});
    defer built.deinit();
    try testing.expect(!built.diags.hasErrors());
    // No instrument in a module tempura authored, and the cells say so.
    try testing.expectEqual(@as(usize, 1), built.diags.count(.it_no_instrument));

    var got = try dump(gpa, &schema, built.bytes, .it, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.restored, got.rule);
    try testing.expect(!got.diags.hasErrors());
    try testing.expect(got.conductor.?.hash_ok);
    try testing.expect(got.verdicts.len > 0);
    for (got.verdicts) |v| {
        try testing.expect(v.hash_ok);
        try testing.expectEqual(reconcile.Action.restored_native, v.action);
    }
    var tier_free = got.doc;
    tier_free.anchors = &.{};
    tier_free.midi = &.{};
    tier_free.it = &.{};
    try testing.expect(tier_free.eql(&fx.res.doc));
    try testing.expect(std.mem.indexOf(u8, got.text, "; a native piece") != null);
}

test "pipeline.build: --no-residue writes a file that carries nothing of its own" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var fx = try ready(gpa, &schema, native_doc);
    defer fx.deinit();

    var built = try build(gpa, &schema, native_doc, &fx.res.doc, &fx.derived, .smf, .{
        .cc = 74,
        .no_residue = true,
    });
    defer built.deinit();
    try testing.expectEqual(@as(usize, 0), built.essence_bytes);

    var got = try dump(gpa, &schema, built.bytes, .smf, .{});
    defer got.deinit();
    try testing.expectEqual(reconcile.Rule.derived, got.rule);
}

test "pipeline.build: an IT-anchored document refuses to build a .mid" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var fx = try ready(gpa, &schema, it_doc);
    defer fx.deinit();

    var built = try build(gpa, &schema, it_doc, &fx.res.doc, &fx.derived, .smf, .{});
    defer built.deinit();

    try testing.expectEqual(@as(usize, 1), built.diags.count(.build_cross_kind));
    try testing.expect(built.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), built.bytes.len);
}

test "pipeline.build: a newer residue in the anchor is kept, and --force-residue overrides" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // A `.mid` whose payloads a newer tempura wrote, dumped: the tier
    // keeps them as the plain `sequencer-specific` events they are.
    const bytes = try smfBytes(gpa, records.version + 1, true);
    defer gpa.free(bytes);
    var dumped = try dump(gpa, &schema, bytes, .smf, .{});
    defer dumped.deinit();
    try testing.expectEqual(reconcile.Rule.version, dumped.rule);

    var derived = try time_derive.derive(gpa, &dumped.doc);
    defer derived.deinit();

    var kept = try build(gpa, &schema, dumped.text, &dumped.doc, &derived, .smf, .{});
    defer kept.deinit();
    try testing.expectEqual(@as(usize, 1), kept.diags.count(.residue_newer_kept));
    try testing.expectEqual(@as(usize, 0), kept.essence_bytes);

    var forced = try build(gpa, &schema, dumped.text, &dumped.doc, &derived, .smf, .{
        .force_residue = true,
    });
    defer forced.deinit();
    try testing.expectEqual(@as(usize, 0), forced.diags.count(.residue_newer_kept));
    try testing.expect(forced.essence_bytes > 0);
}

// ---- rules 3 and 4 over the carriers themselves ----------------------

/// A `.mid` whose essence rides in several events with one of them gone
/// — plan 04's "a split body with a missing part". `reassemble` refuses
/// it whole, which is exactly why this is rule 4 and not "a shorter
/// essence".
fn smfSplitBytes(gpa: Allocator) ![]u8 {
    var seq = try smfSequence(gpa, 100);
    defer seq.deinit();

    var packed_tier = try residue_essence.packFor(gpa, smf_doc, "song");
    defer packed_tier.deinit(gpa);

    // Small events, so the essence really does split.
    var carried = try residue_smf.attach(gpa, &seq, .{
        .essence = packed_tier.bytes,
    }, .{ .max_event = 64 });
    defer carried.deinit();
    dropOneEssencePart(&carried.sequence);

    var file = try smf.write(gpa, &carried.sequence, .{});
    defer file.deinit();
    return gpa.dupe(u8, file.bytes);
}

/// Remove the second essence event — a DAW that dropped one payload and
/// kept the rest, which is the failure this carrier was split for.
fn dropOneEssencePart(seq: *smf.Sequence) void {
    var seen: usize = 0;
    for (seq.tracks) |*t| {
        var i: usize = 0;
        while (i < t.events.len) : (i += 1) {
            if (t.events[i].kind != .tempura_residue) continue;
            if (t.events[i].payload.residue.kind != @intFromEnum(records.Kind.essence)) continue;
            seen += 1;
            if (seen != 2) continue;
            std.mem.copyForwards(smf.Event, t.events[i..], t.events[i + 1 ..]);
            t.events = t.events[0 .. t.events.len - 1];
            return;
        }
    }
}

/// What a `.it` carries, for the two rules that are about the CARRIER
/// rather than about the music.
const ItCarrier = struct {
    /// The envelope version stamped on every record in the chunk.
    ver: u8 = records.version,
    /// Break the first record's length field, so the framing does not
    /// hold and `parseChunk` refuses the chunk whole.
    corrupt: bool = false,
    /// Whether the message tail is written beside the chunk.
    tail: bool = true,
};

fn itCarrierBytes(gpa: Allocator, schema: *const Schema, carry: ItCarrier) ![]u8 {
    var module = try itModule(gpa);
    defer module.deinit();

    var packed_tier = try residue_essence.packFor(gpa, it_doc, "song");
    defer packed_tier.deinit(gpa);
    const payload = try residue_it.chunk(gpa, .{ .essence = packed_tier.bytes });
    defer gpa.free(payload);

    if (carry.ver != records.version) stampChunkVersion(payload, carry.ver);
    if (carry.corrupt) breakChunkFraming(payload);

    var loaded = try fromSjon.fromSource(gpa, schema, it_doc, null);
    defer loaded.deinit();
    var t = try residue_it.tail(gpa, &loaded.doc, &loaded.map);
    defer t.deinit(gpa);
    const whole = try residue_it.appendTail(gpa, module.message, t.bytes);
    defer gpa.free(whole);

    var file = try itf.write.write(gpa, &module, null, .{
        .tmpu = payload,
        .message_tail = if (carry.tail) whole[module.message.len..] else null,
    });
    defer file.deinit();
    return gpa.dupe(u8, file.bytes);
}

/// Re-stamp every record's `ver` — what a newer tempura's chunk looks
/// like to this one. Each record carries its own length, which is what
/// lets a reader step over a version it does not know.
fn stampChunkVersion(payload: []u8, ver: u8) void {
    var at: usize = 0;
    while (at + records.head_len + 4 <= payload.len) {
        payload[at + 4] = ver;
        const len = std.mem.readInt(u32, payload[at + records.head_len ..][0..4], .little);
        at += records.head_len + 4 + len;
    }
}

/// The first record claims more bytes than the chunk holds.
fn breakChunkFraming(payload: []u8) void {
    if (payload.len < records.head_len + 4) return;
    std.mem.writeInt(u32, payload[records.head_len..][0..4], 0xFFFF_FFF0, .little);
}

test "pipeline: an SMF essence with a part missing is rule 4, not rule 1" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const bytes = try smfSplitBytes(gpa);
    defer gpa.free(bytes);

    var got = try dump(gpa, &schema, bytes, .smf, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.corrupt, got.rule);
    try testing.expect(got.diags.count(.residue_corrupt) > 0);
    // The two surfaces agree: the header does not say "no residue found"
    // over a file whose diagnostics say the residue would not decode.
    try testing.expect(std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue would not decode"));
    try testing.expect(std.mem.indexOf(u8, got.text, "no residue found") == null);
    try testing.expect(!got.diags.hasErrors());
}

test "pipeline: an IT chunk whose framing does not hold is rule 4 when nothing else survived" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const bytes = try itCarrierBytes(gpa, &schema, .{ .corrupt = true, .tail = false });
    defer gpa.free(bytes);

    var got = try dump(gpa, &schema, bytes, .it, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.corrupt, got.rule);
    try testing.expect(got.diags.count(.residue_corrupt) > 0);
    try testing.expect(std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue would not decode"));
    try testing.expect(std.mem.indexOf(u8, got.text, "no residue found") == null);
    try testing.expect(!got.diags.hasErrors());
    // The skeleton is total all the same: the module is a document
    // again, bound lanes and all.
    try testing.expect(got.verdicts.len > 0);
    for (got.verdicts) |v| try testing.expectEqual(reconcile.Action.skeleton, v.action);
}

test "pipeline: a corrupt IT chunk beside a tail is rule 5 — the tail wins" {
    // Plan 04, rule 5, in its own words: "the message tail is used when
    // the chunk is absent, corrupt or truncated, with `residue_partial`
    // naming what the tail lacks". So a chunk that will not frame does
    // not take the file to the skeleton while a readable tail is sitting
    // beside it — the shape of the piece is more than nothing.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const bytes = try itCarrierBytes(gpa, &schema, .{ .corrupt = true, .tail = true });
    defer gpa.free(bytes);

    var got = try dump(gpa, &schema, bytes, .it, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.partial, got.rule);
    // Both facts are on the record: the chunk was unreadable AND the
    // tail is all that could be used.
    try testing.expect(got.diags.count(.residue_corrupt) > 0);
    try testing.expect(got.diags.count(.residue_partial) > 0);
    try testing.expect(std.mem.startsWith(u8, got.text, "; partial:"));
    try testing.expect(!got.diags.hasErrors());
    // The shape came back and none of the content.
    try testing.expect(std.mem.indexOf(u8, got.text, "(timeline :title \"smaller\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "(note ") == null);
}

test "pipeline: an IT chunk of a newer envelope leaves it in the file and derives" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    // No tail: `it.choose` prefers a readable tail over a chunk it
    // cannot read, so rule 3's own branch is the one with nothing else
    // to fall back on.
    const bytes = try itCarrierBytes(gpa, &schema, .{
        .ver = records.version + 1,
        .tail = false,
    });
    defer gpa.free(bytes);

    var got = try dump(gpa, &schema, bytes, .it, .{});
    defer got.deinit();

    try testing.expectEqual(reconcile.Rule.version, got.rule);
    try testing.expect(got.diags.count(.residue_version) > 0);
    try testing.expectEqual(@as(usize, 0), got.diags.count(.residue_corrupt));
    try testing.expect(std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue is a newer version"));
    try testing.expect(!got.diags.hasErrors());

    // The file was not touched: the chunk is still under its 4CC, and
    // `check-residue` reads the version off it rather than the records.
    try testing.expect(std.mem.indexOf(u8, bytes, residue_it.tag) != null);
    var rep = try checkResidue(gpa, bytes, .it);
    defer rep.deinit();
    try testing.expect(std.mem.indexOf(u8, rep.text, "envelope version 2") != null);
    try testing.expect(std.mem.indexOf(u8, rep.text, "does not read") != null);
}
