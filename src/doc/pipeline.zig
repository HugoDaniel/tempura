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
//!   → reconcile.consumeSmf / consumeIt              the restored lanes' view
//!       (and the tier printed again without it)      out of the file tier
//!   → splice the two                                one document source
//!   → doc.fromSource                                every host check runs
//! ```
//!
//! # One home, literally
//!
//! Rule 2's "consumed" is enforced HERE, on the tier value, between the
//! reconciliation and the print: a lane the essence restored native has
//! its rendered events taken out of the `midi/` or `it/` tier, and a
//! document that conducts has the file's tempo, meter and marker events
//! taken out with them (`residue/reconcile.zig`, "The consumption").
//! The dumped document then holds each thing once, and `build` renders
//! every native lane into a tier that no longer carries its previous
//! rendering — which is what makes `build → dump → build` a fixed point
//! rather than a file that gains a copy of every note per rebuild. The
//! tier is printed twice when something was consumed (the reconciliation
//! needs the full tier for the skeleton rules, which consume nothing),
//! and `Dumped.consumed` says what went.
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
    /// What rule 2 took out of the file tier (nothing under any other
    /// rule).
    consumed: reconcile.Consumed,

    /// `reconcile`'s arena, handed on — it owns `text`, `verdicts` and
    /// every string in them, so the struct keeps no allocator of the
    /// caller's.
    arena: std.heap.ArenaAllocator,

    /// Frees the text, the document, its map, the report and the
    /// verdicts; the bytes it was dumped from stay the caller's.
    pub fn deinit(self: *Dumped) void {
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
    try diags.extend(read.diags.items());

    // The version is read BEFORE the detach, because detach's whole
    // answer to a newer envelope is to leave it alone: it takes nothing
    // out and reports `residue_version`, and rule 3 needs the byte.
    const newer = newerSmf(&read.sequence);

    var detached = try residue_smf.detach(gpa, &read.sequence);
    defer detached.deinit();
    try diags.extend(detached.diags.items());

    // Rule 3's "the payloads stay where they are" is literal in a
    // `.mid`: they stay in the TIER, as the plain `sequencer-specific`
    // events RP-001 tells every reader to skip. `detach` leaves a newer
    // ENVELOPE's events in place by itself; a newer WIRE version is only
    // known once the essence has been reassembled, which is why the
    // tier is then printed from the sequence as it was read, with every
    // carrier event still in it — the essence `reconcile` will refuse to
    // decode is exactly what a later build has to carry through.
    const tier_seq: *smf.Sequence = if (newer != null and newer.? == .wire)
        &read.sequence
    else
        &detached.sequence;

    var tier = try smfTier(gpa, tier_seq, opts);
    defer gpa.free(tier);

    var rec = try reconcile.reconcile(gpa, schema, .{
        .tier = .{ .smf = tier_seq },
        .text = tier,
        .bytes = bytes,
        .name = name,
    }, smfFound(newer, &detached), .{ .cues = opts.cues, .anchor_id = opts.anchor_id });
    errdefer rec.deinit();

    // The restored lanes' view, out of the tier — and the tier printed
    // again without it (the header, "One home, literally").
    const consumed = reconcile.consumeSmf(tier_seq, &rec);
    if (consumed.any()) {
        // Printed BEFORE the old text is freed: a print that fails must
        // leave `tier` naming live memory, or its `defer` frees it twice.
        const reprinted = try smfTier(gpa, tier_seq, opts);
        gpa.free(tier);
        tier = reprinted;
    }

    return assemble(gpa, schema, bytes, name, diags, &rec, tier, consumed);
}

/// Which of plan 04's rules the carrier's findings on a `.mid` route
/// to. A residue the CARRIER could not read is rule 4, never rule 1: a
/// split essence with a part missing comes back as no essence at all,
/// and handing that on as `.payloads` would head the document "no
/// residue found" while `detach` has already said `residue_corrupt`.
/// The carrier names the loss; this only routes it. A newer wire
/// version rides through as `.payloads`: `reconcile` is the one that
/// asks the decoder, and it names the version when the decoder refuses.
fn smfFound(newer: ?Newer, detached: *const residue_smf.Detached) reconcile.Found {
    if (newer != null and newer.? == .envelope) return .{ .newer = newer.?.version() };
    if (detached.diags.count(.residue_corrupt) > 0) return .corrupt;
    return .{ .payloads = detached.payloads };
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
    try diags.extend(read.diags.items());

    const chunk_bytes = if (read.module.tmpu) |r| r.slice(bytes) else null;
    const newer = newerIt(chunk_bytes);

    // `choose`'s own report goes into a list of its own first: whether
    // it found the chunk UNREADABLE is the difference between rule 4 and
    // rule 1, and the merged list cannot be asked that question.
    var carrier: Diag.List = .init(gpa);
    defer carrier.deinit();
    var chosen = try residue_it.choose(gpa, chunk_bytes, read.module.message, &carrier);
    defer chosen.deinit();
    try diags.extend(carrier.items());

    // The tail is TEXT in IT's own encoding — CR newlines, `%XX` escapes
    // — and rule 5 reads it as SJON, so it is undone here rather than
    // inside the rule.
    const tail_src: ?[:0]u8 = switch (chosen) {
        .tail => |text| try residue_it.parseTail(gpa, text),
        else => null,
    };
    defer if (tail_src) |t| gpa.free(t);

    // The printer's own diagnostics are collected on the first print and
    // not asked for again: fewer cells cannot add one.
    var tier = try itTier(gpa, &read, opts, diags, &.{});
    defer gpa.free(tier);

    var rec = try reconcile.reconcile(gpa, schema, .{
        .tier = .{ .it = &read.module },
        .text = tier,
        .bytes = bytes,
        .name = name,
    }, itFound(&chosen, newer, &carrier, tail_src), .{
        .cues = opts.cues,
        .anchor_id = opts.anchor_id,
    });
    errdefer rec.deinit();

    // The restored lanes' cells and the conductor's `Txx`, out of the
    // module — and the tier printed again without them. A pattern that
    // lost a cell is printed as rows even under `--patterns=bin`, since
    // the file's own bytes no longer describe it.
    const consumed = try reconcile.consumeIt(rec.arena.allocator(), &read.module, &rec);
    if (consumed.any()) {
        // Printed before the old text is freed, as in `dumpSmf`.
        const reprinted = try itTier(gpa, &read, opts, null, consumed.patterns);
        gpa.free(tier);
        tier = reprinted;
    }

    return assemble(gpa, schema, bytes, name, diags, &rec, tier, consumed);
}

/// A file's bytes as its tier's SJON text: the format core's reader, then
/// the bridge, under `opts`' tier switches (`qualify` and it 03's three —
/// the anchor's name and id are not read). The reader's diagnostics go
/// into `diags` first, then the `it/` bridge's own, all in the FILE's
/// byte coordinates. Caller frees the text.
///
/// The step `tempura inline` takes (`edit/inline_anchor.zig`), through the
/// same two bridge calls `dump` prints its tier with — `smfTier` and
/// `itTier` — so a tier inlined and a tier dumped are spelled by one
/// function per kind and cannot drift apart. `dump` cannot take this step
/// whole: it prints the tier from the read AFTER the carrier has taken
/// the residue out and the reconciliation has consumed what the essence
/// restored, so it holds the read value itself. Nothing here detaches
/// anything: an inline's tier is the file as it is.
pub fn tierText(
    gpa: Allocator,
    bytes: []const u8,
    kind: Doc.AnchorKind,
    opts: Options,
    diags: *Diag.List,
) Error![]u8 {
    switch (kind) {
        .smf => {
            var read = try smf.read(gpa, bytes);
            defer read.deinit();
            try diags.extend(read.diags.items());
            return smfTier(gpa, &read.sequence, opts);
        },
        .it => {
            var read = try itf.read.read(gpa, bytes);
            defer read.deinit();
            try diags.extend(read.diags.items());
            return itTier(gpa, &read, opts, diags, &.{});
        },
    }
}

/// The `midi/` tier printed from a sequence. Caller frees the text.
fn smfTier(gpa: Allocator, seq: *const smf.Sequence, opts: Options) Error![]u8 {
    return bridge_smf.sequenceToForms(gpa, seq, null, .{ .qualify = opts.qualify });
}

/// The `it/` tier printed from the module as read. `diags` is where the
/// printer reports what it could not spell, or null to drop that
/// report; `rows_for` names the patterns printed as rows even under
/// `--patterns=bin`. Caller frees the text.
fn itTier(
    gpa: Allocator,
    read: *const itf.read.Result,
    opts: Options,
    diags: ?*Diag.List,
    rows_for: []const u16,
) Error![]u8 {
    return bridge_it.moduleToForms(gpa, &read.module, .{
        .qualify = opts.qualify,
        .patterns_bin = opts.patterns_bin,
        .preserve_foreign = opts.preserve_foreign,
        .preserve_history = opts.preserve_history,
        .source_map = &read.source_map,
        .rows_for = rows_for,
        .diags = diags,
    });
}

/// Which of plan 04's rules the carriers' findings on a `.it` route to.
/// Rule 5 decides the order, and `choose` has already applied it: the
/// chunk wins when it is readable, and the TAIL wins over a chunk that
/// is absent, corrupt or truncated — with `residue_partial` naming what
/// the tail cannot carry. So a corrupt chunk beside a tail is rule 5,
/// not rule 4, and only a corrupt chunk with NO tail falls through to
/// the skeleton.
///
/// A chunk of a version this build does not read, with no tail to fall
/// back on, is rule 3 and not rule 1: the payload is still in the file,
/// as the opaque region the writer re-emits. One whose framing does not
/// hold is rule 4, for the same reason — the file carried a residue,
/// and saying "no residue found" over a `residue_corrupt` would be two
/// surfaces disagreeing.
fn itFound(
    chosen: *const residue_it.Chosen,
    newer: ?Newer,
    carrier: *const Diag.List,
    tail_src: ?[:0]u8,
) reconcile.Found {
    return switch (chosen.*) {
        .chunk => |p| .{ .payloads = p.payloads },
        .tail => .{ .tail = tail_src.? },
        .none => if (newer) |v|
            .{ .newer = v.version() }
        else if (carrier.count(.residue_corrupt) > 0)
            .corrupt
        else
            .none,
    };
}

/// Splice and load — the half both kinds share once the tier is final.
///
/// `rec` is TAKEN: its arena is handed on to the `Dumped` and its
/// diagnostics are merged, so the caller's `errdefer rec.deinit()` is the
/// only release it gets.
fn assemble(
    gpa: Allocator,
    schema: *const Schema,
    bytes: []const u8,
    name: []const u8,
    diags: *Diag.List,
    rec: *reconcile.Result,
    tier_text: []const u8,
    consumed: reconcile.Consumed,
) Error!Dumped {
    try diags.extend(rec.diags.items());

    // Into `rec`'s arena, which becomes the `Dumped`'s own: the text
    // dies with the value, and a failure below leaves it to the caller's
    // `errdefer rec.deinit()`.
    const at = @min(rec.tier_at, rec.doc_text.len);
    const text = try std.mem.concatWithSentinel(rec.arena.allocator(), u8, &.{
        rec.doc_text[0..at],
        tier_text,
        rec.doc_text[at..],
    }, 0);

    // The reader's OWN bytes, handed back by name: the anchor's `:size`
    // and `:sha256` were computed from them, so it verifies without a
    // second read of anything, and every `(bin :at :len)` resolves.
    const store: Resolver.Memory = .{ .entries = &.{.{ .path = name, .bytes = bytes }} };
    var loaded = try fromSjon.fromSource(gpa, schema, text, Resolver.memory(&store));
    errdefer loaded.deinit();
    try diags.extend(loaded.diags.items());
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
        .consumed = consumed,
        .arena = rec.arena,
    };
}

/// A residue this build must leave where it is (plan 04, rule 3): one
/// whose ENVELOPE version it does not read, or one whose essence is
/// Binary IR of a WIRE version it does not decode. The two are found at
/// different depths — the envelope is the carrier's eight bytes, the wire
/// version is the fifth byte of the essence body — and answered by the
/// same word, because a build treats them the same way: it writes no
/// residue of its own over either, and a dump leaves the payloads in
/// the tier.
const Newer = union(enum) {
    envelope: u8,
    wire: u8,

    fn version(self: Newer) u8 {
        return switch (self) {
            .envelope, .wire => |v| v,
        };
    }
};

/// What a sequence carries that this build must not re-print, or null
/// when every payload is its own. The essence's header rides in the
/// part numbered 0, which is where the wire version is read.
fn newerSmf(seq: *const smf.Sequence) ?Newer {
    for (seq.tracks) |t| {
        for (t.events) |e| {
            if (e.kind != .tempura_residue) continue;
            const r = e.payload.residue;
            if (r.ver != records.version) return .{ .envelope = r.ver };
            if (r.kind == @intFromEnum(records.Kind.essence) and r.seq == 0) {
                if (residue_essence.newerWire(seq.bytesOf(r.body))) |v| return .{ .wire = v };
            }
        }
    }
    return null;
}

/// The `TMPU` payload an anchor's own bytes still carry, borrowed from
/// them — null when the file has none, or when there is no file.
///
/// The read is a full one, through the same core every other reader of
/// these bytes uses: the chunk sits after the samples and the foreign
/// chunks, and finding it means walking the same framing `itf/read.zig`
/// already walks. A build of an anchored document reads and writes this
/// module several times over anyway, and a second opinion about where a
/// chunk begins is the one thing this could not afford.
/// The slice BORROWS the caller's bytes and outlives the read that found
/// it, because a region is an offset into those bytes and never a copy
/// (plan 06, "bytes are sacred").
fn anchorTmpu(gpa: Allocator, bytes: ?[]const u8) Error!?[]const u8 {
    const source = bytes orelse return null;
    var read = try itf.read.read(gpa, source);
    // Its diagnostics are deliberately dropped: the anchor was already
    // read, verified and reported on by whoever built the document, and
    // a second copy of that report here would be one file complained
    // about twice.
    defer read.deinit();
    const region = read.module.tmpu orelse return null;
    return region.slice(source);
}

/// The same question of a `TMPU` chunk, walked record by record the way
/// `residue/it.zig`'s `parseChunk` walks it — by each record's own
/// length — and answered by the first record that is not this build's:
/// an envelope of another version, or the essence's part 0 whose body
/// is Binary IR of another wire version. A chunk whose framing does not
/// hold is nobody's newer residue and answers null; `parseChunk` is
/// where that becomes `residue_corrupt`.
fn newerIt(chunk_bytes: ?[]const u8) ?Newer {
    const bytes = chunk_bytes orelse return null;
    var at: usize = 0;
    while (at < bytes.len) {
        const head = records.readHead(bytes[at..]) orelse return null;
        at += records.head_len;
        if (bytes.len - at < 4) return null;
        const len = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        if (bytes.len - at < len) return null;
        const body = bytes[at..][0..len];
        at += len;
        if (head.ver != records.version) return .{ .envelope = head.ver };
        if (head.kind == @intFromEnum(records.Kind.essence) and head.seq == 0) {
            if (residue_essence.newerWire(body)) |v| return .{ .wire = v };
        }
    }
    return null;
}

// ---------------------------------------------------------------------
// check-residue
// ---------------------------------------------------------------------

/// What `checkResidue` reports. `arena` owns the text; the struct keeps
/// no allocator of the caller's.
pub const Report = struct {
    /// The verdict table, one fact per line, NO trailing blank line.
    text: []u8,
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    /// Frees the text and the report; neither outlives the `Report`.
    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.diags.deinit();
        self.* = undefined;
    }

    /// The report `checkResidue` hands out: `out`'s text moved into a
    /// report arena of its own, and `out` released. On a failure `out`
    /// and `diags` are still the caller's to free.
    fn of(gpa: Allocator, out: *std.ArrayList(u8), diags: Diag.List) Error!Report {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const text = try arena.allocator().dupe(u8, out.items);
        out.deinit(gpa);
        return .{ .text = text, .diags = diags, .arena = arena };
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
            try diags.extend(read.diags.items());

            if (newerSmf(&read.sequence)) |n| {
                try newerLine(gpa, &out, n);
                return Report.of(gpa, &out, diags);
            }

            var detached = try residue_smf.detach(gpa, &read.sequence);
            defer detached.deinit();
            try diags.extend(detached.diags.items());

            try table(gpa, &out, .{ .smf = &detached.sequence }, detached.payloads, null);
        },
        .it => {
            var read = try itf.read.read(gpa, bytes);
            defer read.deinit();
            try diags.extend(read.diags.items());

            const chunk_bytes = if (read.module.tmpu) |r| r.slice(bytes) else null;
            if (newerIt(chunk_bytes)) |n| {
                try newerLine(gpa, &out, n);
                return Report.of(gpa, &out, diags);
            }

            var quiet: Diag.List = .init(gpa);
            defer quiet.deinit();
            var chosen = try residue_it.choose(gpa, chunk_bytes, read.module.message, &quiet);
            defer chosen.deinit();
            try diags.extend(quiet.items());

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

    return Report.of(gpa, &out, diags);
}

/// `check-residue`'s one line for a residue this build leaves alone.
fn newerLine(gpa: Allocator, out: *std.ArrayList(u8), n: Newer) Error!void {
    switch (n) {
        .envelope => |v| try out.print(
            gpa,
            "residue: envelope version {d}, which this build does not read\n",
            .{v},
        ),
        .wire => |v| try out.print(
            gpa,
            "residue: essence of Binary IR wire version {d}, which this substrate does not " ++
                "decode\n",
            .{v},
        ),
    }
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
        try out.print(
            gpa,
            "essence: {d} bytes, envelope version {d}\n",
            .{ essence.len, records.version },
        );
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
    /// `--ppq N`. For a NATIVE document it is the division the renderer
    /// lays the file out on; for an ANCHORED one the anchor's own
    /// division rules the render and this becomes the writer's rescale
    /// (plan 05's `--ppq`, plan 10's `build --ppq N [--round]`). Null
    /// takes 960 for a fresh file and leaves an anchor's own alone.
    ppq: ?u15 = null,
    /// `--round`: accept a rescaled tick that does not land exactly.
    round: bool = false,
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

/// A document, built. `arena` owns the file's bytes and every record;
/// the struct keeps no allocator of the caller's.
pub const Built = struct {
    bytes: []const u8,
    /// One per rendered native lane — what rode in the file, with the
    /// hash of what was written at each address.
    lanes: []const records.LaneRecord,
    conductor: ?records.ConductorRecord,
    /// How many bytes of essence rode in the file; zero when none did.
    essence_bytes: usize,
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    /// Frees the bytes, the records and the report: nothing read out of
    /// a `Built` outlives it.
    pub fn deinit(self: *Built) void {
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
    doc.invariants();
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
        .{ .bytes = &.{}, .lanes = &.{}, .conductor = null, .essence_bytes = 0 }
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
        .arena = arena,
    };
}

/// What one kind's build produced, before it is wrapped. Every slice is
/// in the build's arena, the `Built`'s own.
const Pieces = struct {
    bytes: []const u8,
    lanes: []const records.LaneRecord,
    conductor: ?records.ConductorRecord,
    essence_bytes: usize,
};

/// An anchor of this kind that carries no inline dump is one nothing has
/// read: the build renders the document's own lanes and the FILE's own
/// content — its tracks or its patterns, its samples, its opaque regions
/// — is simply not there to render into.
///
/// That is not a refusal (the document's own music still becomes a file)
/// but it is not what the author asked for either, so it is said out
/// loud at the seam where it is first true. `anchor_unavailable` is the
/// resolver's code for exactly this condition, and a build is the second
/// place it can be met.
fn missingTier(
    diags: *Diag.List,
    doc: *const Doc.Doc,
    kind: Doc.AnchorKind,
    have_tier: bool,
) Error!void {
    if (have_tier) return;
    for (doc.anchors) |anchor| {
        if (anchor.kind != kind) continue;
        try diags.add(
            .anchor_unavailable,
            .warning,
            anchor.span,
            "the anchor '{s}' ({s}) carries no inline dump, so this build renders the " ++
                "document's own lanes into a FRESH file and the anchor's own content is not in it",
            .{ anchor.id, anchor.file },
        );
        return;
    }
}

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
        "this document is arranged around a {t} anchor and a {t} file was asked for; v1 builds " ++
            "a document into its own anchor's kind, or a native document into either (plan 08)",
        .{ doc.anchors[0].kind, kind },
    );
    return true;
}

/// Whether this build writes a residue of its own. A newer tempura's
/// payloads are kept where they are unless the caller insists (plan 04,
/// rule 3).
fn wantsResidue(diags: *Diag.List, opts: BuildOptions, newer: ?Newer) Error!bool {
    if (opts.no_residue) return false;
    const n = newer orelse return true;
    if (opts.force_residue) return true;
    switch (n) {
        .envelope => |v| try diags.add(
            .residue_newer_kept,
            .warning,
            .{ .start = 0, .end = 0 },
            "this anchor carries a residue of envelope version {d}, which this build does not " ++
                "read; it was kept and no residue of this build's own was written " ++
                "(--force-residue overrides)",
            .{v},
        ),
        .wire => |v| try diags.add(
            .residue_newer_kept,
            .warning,
            .{ .start = 0, .end = 0 },
            "this anchor carries an essence of SJON Binary IR wire version {d}, which this " ++
                "substrate does not decode; it was kept and no residue of this build's own was " ++
                "written (--force-residue overrides)",
            .{v},
        ),
    }
    return false;
}

/// The lane records as carrier bodies. Caller frees each.
fn encodeLanes(gpa: Allocator, lanes: []const records.LaneRecord) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |b| gpa.free(b);
        out.deinit(gpa);
    }
    // Room first, so a body once encoded always lands in `out` and the
    // `errdefer` above is the one that frees it.
    try out.ensureTotalCapacityPrecise(gpa, lanes.len);
    for (lanes) |rec| out.appendAssumeCapacity(try records.encodeLane(gpa, rec));
    return out.toOwnedSlice(gpa);
}

fn freeBodies(gpa: Allocator, bodies: []const []const u8) void {
    for (bodies) |b| gpa.free(b);
    gpa.free(bodies);
}

/// A rendered record into the caller's arena, with the hash the file
/// itself answers.
fn keepRecord(arena: Allocator, src: records.LaneRecord, hash: [32]u8) Error!records.LaneRecord {
    const segments = try arena.alloc(records.Segment, src.steps_only.len);
    for (src.steps_only, segments) |from, *to| to.* = .{
        .at = from.at,
        .ease = try arena.dupe(u8, from.ease),
    };
    return .{
        .lane = try arena.dupe(u8, src.lane),
        .address = src.address,
        .hash = hash,
        .steps_only = segments,
    };
}

/// One kind's records, hashed over the FILE (see `build`): the lanes,
/// into the caller's arena, and the conductor's when the render placed
/// one.
const Records = struct {
    lanes: []const records.LaneRecord,
    conductor: ?records.ConductorRecord,
};

/// The conductor record as its carrier body, or null when there is
/// none.
fn conductorBody(conductor: ?records.ConductorRecord) ?[32]u8 {
    const c = conductor orelse return null;
    return records.encodeConductor(c);
}

fn buildSmf(
    gpa: Allocator,
    arena: Allocator,
    doc_source: [:0]const u8,
    doc: *const Doc.Doc,
    derived: *const time_derive.Derived,
    opts: BuildOptions,
    diags: *Diag.List,
) Error!Pieces {
    const base = smfBase(doc);
    try missingTier(diags, doc, .smf, base != null);

    var rendered = try render_smf.renderSmf(gpa, doc, derived, base, .{
        .ppq = opts.ppq orelse render_smf.default_ppq,
        .cc = opts.cc,
        .cc_rate = opts.cc_rate,
        .section_markers = opts.section_markers,
        .format0 = opts.format0,
    });
    defer rendered.deinit();
    try diags.extend(rendered.diags.items());

    const wopts: smf.Options = .{
        .running_status = opts.running_status,
        .format0 = opts.format0,
        // A fresh file was RENDERED on `--ppq`, so there is nothing to
        // rescale; an anchor's events are on the anchor's division, and
        // moving them onto another one is the writer's job and the
        // writer's diagnostic (`ppq_rescale_inexact`).
        .ppq = if (base != null) opts.ppq else null,
        .round = opts.round,
    };
    const recs = try smfRecords(gpa, arena, &rendered, wopts);

    if (!try wantsResidue(diags, opts, if (base) |s| newerSmf(s) else null)) {
        var plain = try smf.write(gpa, &rendered.seq, wopts);
        defer plain.deinit();
        try diags.extend(plain.diags.items());
        return .{
            .bytes = try arena.dupe(u8, plain.bytes),
            .lanes = recs.lanes,
            .conductor = recs.conductor,
            .essence_bytes = 0,
        };
    }
    return smfWithResidue(gpa, arena, doc, doc_source, &rendered.seq, wopts, recs, diags);
}

/// The anchor's own `Sequence`, when the document carries one: the
/// lanes render INTO it and its tracks come out unchanged.
fn smfBase(doc: *const Doc.Doc) ?*const smf.Sequence {
    for (doc.midi) |*tier| {
        const anchor = doc.anchorById(tier.anchor) orelse continue;
        if (anchor.kind == .smf) return &tier.sequence;
    }
    return null;
}

/// Write `rendered` once WITHOUT its residue, read that back, and hash
/// every lane's address and the conductor exactly as a `dump` of the
/// finished bytes will (`build`'s header says why the file, not the
/// render, is what is hashed).
fn smfRecords(
    gpa: Allocator,
    arena: Allocator,
    rendered: *const render_smf.Result,
    wopts: smf.Options,
) Error!Records {
    const lanes = try arena.alloc(records.LaneRecord, rendered.lanes.len);
    var pass1 = try smf.write(gpa, &rendered.seq, wopts);
    defer pass1.deinit();
    var back = try smf.read(gpa, pass1.bytes);
    defer back.deinit();

    const ppq = back.sequence.division.pulsesPerQuarter();
    for (rendered.lanes, lanes) |src, *dst| {
        const address = src.address.smf;
        dst.* = try keepRecord(arena, src, records.hashSmfLane(
            &back.sequence,
            address.track - 1,
            address.ch.first(),
            ppq,
        ));
    }
    return .{
        .lanes = lanes,
        .conductor = if (rendered.conductor != null)
            .{ .hash = records.hashSmfConductor(&back.sequence) }
        else
            null,
    };
}

/// The `.mid` with tempura's own residue in it: the essence packed from
/// the document and the records as carrier bodies, attached to the
/// rendered sequence and written.
fn smfWithResidue(
    gpa: Allocator,
    arena: Allocator,
    doc: *const Doc.Doc,
    doc_source: [:0]const u8,
    seq: *const smf.Sequence,
    wopts: smf.Options,
    recs: Records,
    diags: *Diag.List,
) Error!Pieces {
    var packed_tier = try residue_essence.pack(gpa, doc, doc_source);
    defer packed_tier.deinit(gpa);
    try diags.extend(packed_tier.diags.items());

    const bodies = try encodeLanes(gpa, recs.lanes);
    defer freeBodies(gpa, bodies);
    const cond_body = conductorBody(recs.conductor);

    var carried = try residue_smf.attach(gpa, seq, .{
        .essence = packed_tier.bytes,
        .conductor = if (cond_body) |*b| b else null,
        .lanes = bodies,
    }, .{});
    defer carried.deinit();
    try diags.extend(carried.diags.items());

    var file = try smf.write(gpa, &carried.sequence, wopts);
    defer file.deinit();
    try diags.extend(file.diags.items());

    return .{
        .bytes = try arena.dupe(u8, file.bytes),
        .lanes = recs.lanes,
        .conductor = recs.conductor,
        .essence_bytes = packed_tier.bytes.len,
    };
}

fn buildIt(
    gpa: Allocator,
    arena: Allocator,
    doc_source: [:0]const u8,
    doc: *const Doc.Doc,
    derived: *const time_derive.Derived,
    opts: BuildOptions,
    diags: *Diag.List,
) Error!Pieces {
    const base = itBase(doc);
    try missingTier(diags, doc, .it, base != null);

    var rendered = try render_it.renderIt(gpa, doc, derived, base, .{
        .speed = opts.speed,
        .rows = opts.rows,
        .voices = opts.voices,
        .fx = opts.fx,
    });
    defer rendered.deinit();
    try diags.extend(rendered.diags.items());

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
    const recs = try itRecords(gpa, arena, &rendered, source, wopts);

    // What the ANCHOR's own bytes still carry. The reader keeps a `TMPU`
    // chunk OUT of `Module.foreign` (it is tempura's, not another
    // tracker's) and hands it back as `module.tmpu`; the `it/` bridge
    // does not write it into the document, because a dump CONSUMES the
    // residue (plan 04, "The IT carriers"). So the anchor's file is the
    // only place a payload this build did not write still exists, and
    // rule 3 — "the payloads stay where they are" — has to read it from
    // there rather than from the tier.
    const carried = try anchorTmpu(gpa, source);
    const newer = newerIt(carried);

    if (!try wantsResidue(diags, opts, newer)) {
        // Rule 3 again: a newer tempura's payload is COPIED THROUGH, so
        // this build shadows nothing. `--no-residue` asked for a file
        // that carries nothing and gets exactly that.
        const kept = if (opts.no_residue) null else carried;
        return itPlain(gpa, arena, &rendered.module, source, wopts, kept, recs, diags);
    }
    return itWithResidue(
        gpa,
        arena,
        doc,
        doc_source,
        derived,
        &rendered.module,
        source,
        wopts,
        human,
        recs,
        diags,
    );
}

/// The anchor's own `Module`, when the document carries one.
fn itBase(doc: *const Doc.Doc) ?*const itf.Module {
    for (doc.it) |*tier| {
        const anchor = doc.anchorById(tier.anchor) orelse continue;
        if (anchor.kind == .it) return &tier.module;
    }
    return null;
}

/// `smfRecords`' twin: write `rendered` once without its residue, read
/// it back, walk it, and hash every lane's channel and the conductor
/// exactly as a `dump` of the finished bytes will.
fn itRecords(
    gpa: Allocator,
    arena: Allocator,
    rendered: *const render_it.Result,
    source: ?[]const u8,
    wopts: itf.write.Options,
) Error!Records {
    const lanes = try arena.alloc(records.LaneRecord, rendered.lanes.len);
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
        dst.* = try keepRecord(arena, src, records.hashItLane(
            &back.module,
            &rows,
            &[_]u8{src.address.it.channel},
            pats,
        ));
    }
    return .{
        .lanes = lanes,
        .conductor = if (rendered.conductor != null)
            .{ .hash = records.hashItConductor(&back.module) }
        else
            null,
    };
}

/// The `.it` with no residue of this build's own: `tmpu` is the anchor's
/// chunk copied through (rule 3), or null for a file that carries
/// nothing.
fn itPlain(
    gpa: Allocator,
    arena: Allocator,
    module: *const itf.Module,
    source: ?[]const u8,
    wopts: itf.write.Options,
    tmpu: ?[]const u8,
    recs: Records,
    diags: *Diag.List,
) Error!Pieces {
    var plain = try itf.write.write(gpa, module, source, .{
        .loose = wopts.loose,
        .preserve_history = wopts.preserve_history,
        .tmpu = tmpu,
    });
    defer plain.deinit();
    try diags.extend(plain.diags.items());
    return .{
        .bytes = try arena.dupe(u8, plain.bytes),
        .lanes = recs.lanes,
        .conductor = recs.conductor,
        .essence_bytes = 0,
    };
}

/// The `.it` with tempura's own residue in it: the essence and the
/// records as the `TMPU` chunk, the document's tail after the human
/// half of the message, and the module written with both.
fn itWithResidue(
    gpa: Allocator,
    arena: Allocator,
    doc: *const Doc.Doc,
    doc_source: [:0]const u8,
    derived: *const time_derive.Derived,
    module: *const itf.Module,
    source: ?[]const u8,
    wopts: itf.write.Options,
    human: []const u8,
    recs: Records,
    diags: *Diag.List,
) Error!Pieces {
    var packed_tier = try residue_essence.pack(gpa, doc, doc_source);
    defer packed_tier.deinit(gpa);
    try diags.extend(packed_tier.diags.items());

    const bodies = try encodeLanes(gpa, recs.lanes);
    defer freeBodies(gpa, bodies);
    const cond_body = conductorBody(recs.conductor);

    const payload = try residue_it.chunk(gpa, .{
        .essence = packed_tier.bytes,
        .conductor = if (cond_body) |*b| b else null,
        .lanes = bodies,
    });
    defer gpa.free(payload);

    var tail = try residue_it.tail(gpa, doc, &derived.map);
    defer tail.deinit(gpa);
    try diags.extend(tail.diags.items());
    const whole = try residue_it.appendTail(gpa, human, tail.bytes);
    defer gpa.free(whole);

    var file = try itf.write.write(gpa, module, source, .{
        .loose = wopts.loose,
        .preserve_history = wopts.preserve_history,
        .tmpu = payload,
        .message_tail = whole[human.len..],
    });
    defer file.deinit();
    try diags.extend(file.diags.items());

    return .{
        .bytes = try arena.dupe(u8, file.bytes),
        .lanes = recs.lanes,
        .conductor = recs.conductor,
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
    try b.addEvent(
        t0,
        0,
        .time_signature,
        .{ .time_sig = .{ .nn = 4, .dd = 2, .cc = 24, .bb = 8 } },
    );
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
    return smfBytesWith(gpa, ver, residue, false);
}

/// The same, with the ESSENCE's Binary IR header re-stamped instead —
/// what a newer SJON substrate's residue looks like under this build's
/// own envelope.
fn smfBytesWith(gpa: Allocator, ver: u8, residue: bool, bump_wire: bool) ![]u8 {
    var seq = try smfSequence(gpa, 100);
    defer seq.deinit();

    if (!residue) {
        var plain = try smf.write(gpa, &seq, .{});
        defer plain.deinit();
        return gpa.dupe(u8, plain.bytes);
    }

    const lane = try records.encodeLane(gpa, .{
        .lane = "kick",
        .address = .{ .smf = .{ .track = 2, .ch = .single(0), .key = 36, .curve = null } },
        .hash = records.hashSmfLane(&seq, 1, 0, 96),
    });
    defer gpa.free(lane);
    const conductor = records.encodeConductor(.{ .hash = records.hashSmfConductor(&seq) });

    var packed_tier = try residue_essence.packFor(gpa, smf_doc, "song");
    defer packed_tier.deinit(gpa);
    if (bump_wire) packed_tier.bytes[4] = 0xFE;

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
    try testing.expect(
        std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue is a newer version"),
    );
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
            .address = .{ .smf = .{ .track = 2, .ch = .single(0), .key = 36, .curve = null } },
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
        for (res.diags.items()) |d| std.debug.print(
            "build fixture: {t}: {s}\n",
            .{ d.code, d.message },
        );
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

test "pipeline.build: a by-reference anchor's own content is absent, and the build says so" {
    // The anchor names a file and carries no inline dump, so nothing has
    // read it: the document's lanes still become a `.mid`, and the
    // anchor's own tracks are not in it. Said once, at the seam.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const source: [:0]const u8 =
        \\(timeline :title "by reference" :length 1bar)
        \\(anchor :id song :kind smf :file "elsewhere.mid")
        \\(tempo-point :at 0bar :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0bar :dur 1q :key 36 :vel 100))
        \\
    ;
    var fx = try ready(gpa, &schema, source);
    defer fx.deinit();

    var built = try build(gpa, &schema, source, &fx.res.doc, &fx.derived, .smf, .{});
    defer built.deinit();

    try testing.expectEqual(@as(usize, 1), built.diags.count(.anchor_unavailable));
    try testing.expect(!built.diags.hasErrors());
    try testing.expect(built.bytes.len > 0);
}

test "pipeline.build: --ppq rescales an ANCHORED build and is the renderer's grid otherwise" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // Native: `--ppq` is what the renderer lays the file out on.
    var fx = try ready(gpa, &schema, native_doc);
    defer fx.deinit();
    var fine = try build(gpa, &schema, native_doc, &fx.res.doc, &fx.derived, .smf, .{
        .cc = 74,
        .ppq = 96,
    });
    defer fine.deinit();
    var read_back = try smf.read(gpa, fine.bytes);
    defer read_back.deinit();
    try testing.expectEqual(@as(u15, 96), read_back.sequence.division.pulsesPerQuarter());

    // Anchored: the anchor's own division rules the render, and `--ppq`
    // is the writer's rescale. 96 → 192 doubles every tick exactly.
    const bytes = try smfBytes(gpa, records.version, false);
    defer gpa.free(bytes);
    var dumped = try dump(gpa, &schema, bytes, .smf, .{});
    defer dumped.deinit();
    var derived = try time_derive.derive(gpa, &dumped.doc);
    defer derived.deinit();

    var wide = try build(gpa, &schema, dumped.text, &dumped.doc, &derived, .smf, .{ .ppq = 192 });
    defer wide.deinit();
    try testing.expect(!wide.diags.hasErrors());
    var again = try smf.read(gpa, wide.bytes);
    defer again.deinit();
    try testing.expectEqual(@as(u15, 192), again.sequence.division.pulsesPerQuarter());
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
    /// Re-stamp the essence's own Binary IR header instead — a newer
    /// SJON substrate's body under this build's envelope.
    bump_wire: bool = false,
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
    if (carry.bump_wire) packed_tier.bytes[4] = 0xFE;
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
    try testing.expect(
        std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue would not decode"),
    );
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
    try testing.expect(
        std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue would not decode"),
    );
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
    try testing.expect(
        std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue is a newer version"),
    );
    try testing.expect(!got.diags.hasErrors());

    // The file was not touched: the chunk is still under its 4CC, and
    // `check-residue` reads the version off it rather than the records.
    try testing.expect(std.mem.indexOf(u8, bytes, residue_it.tag) != null);
    var rep = try checkResidue(gpa, bytes, .it);
    defer rep.deinit();
    try testing.expect(std.mem.indexOf(u8, rep.text, "envelope version 2") != null);
    try testing.expect(std.mem.indexOf(u8, rep.text, "does not read") != null);
}

// ---- rule 2's consumption, and the fixed point it makes true ----

/// The `midi/…` or `it/…` half of a dumped text, from its first root on.
/// The anchor line above it names the bytes dumped and moves with every
/// rebuild; the tier is the claim.
fn tierHalf(text: []const u8, kind: Doc.AnchorKind) []const u8 {
    const head: []const u8 = switch (kind) {
        .smf => "(midi/smf",
        .it => "(it/module",
    };
    const at = std.mem.indexOf(u8, text, head) orelse return "";
    return text[at..];
}

/// Everything before the `(anchor …)` line — the timeline tier as the
/// essence gave it back.
fn beforeAnchor(text: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, "(anchor ") orelse return text;
    return text[0..at];
}

fn countIn(text: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, text, needle);
}

/// `text` with its `(it/message …)` line taken out. The message is the
/// tail carrier, and the tail is the DOCUMENT's shape — which gains an
/// anchor the moment the document has been dumped once — so it is the
/// one line of an `it/` tier a rebuild is allowed to move.
fn withoutMessage(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "(it/message")) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// How many `note-on`s of `key` a sequence holds, over every track.
fn noteOns(seq: *const smf.Sequence, key: u8) usize {
    var n: usize = 0;
    for (seq.tracks) |t| {
        for (t.events) |e| {
            if (e.kind == .note_on and e.payload.note.key == key and e.payload.note.vel > 0) n += 1;
        }
    }
    return n;
}

test "pipeline: rule 2 consumes the restored lanes' view and the conductor's out of the tier" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // The `.mid`: the lane's note pair and the conductor's two events
    // go; the track stays, so no `:track` in the document moves.
    const mid = try smfBytes(gpa, records.version, true);
    defer gpa.free(mid);
    var d = try dump(gpa, &schema, mid, .smf, .{});
    defer d.deinit();
    try testing.expectEqual(reconcile.Rule.restored, d.rule);
    try testing.expectEqual(@as(usize, 2), d.consumed.events);
    try testing.expectEqual(@as(usize, 2), d.consumed.conductor);
    try testing.expectEqual(@as(usize, 2), countIn(d.text, "(midi/mtrk"));
    try testing.expectEqual(@as(usize, 0), countIn(d.text, "note-on"));
    try testing.expectEqual(@as(usize, 0), countIn(d.text, "set-tempo"));
    // …and the document still holds the note — once, natively.
    try testing.expectEqual(@as(usize, 1), countIn(d.text, "(note :at 0bar :dur 1q :key 36)"));
    try testing.expect(d.doc.lanes[0].binding == null);

    // The `.it`: the lane's two cells go, and the module had no `Txx`.
    const it = try itBytes(gpa, &schema, true);
    defer gpa.free(it);
    var e = try dump(gpa, &schema, it, .it, .{});
    defer e.deinit();
    try testing.expectEqual(reconcile.Rule.restored, e.rule);
    try testing.expectEqual(@as(usize, 2), e.consumed.cells);
    try testing.expectEqual(@as(usize, 0), e.consumed.conductor);
    try testing.expectEqual(@as(usize, 0), countIn(e.text, "(ev "));

    // A file with no residue is rule 1, and a skeleton READS the tier:
    // nothing is taken.
    const plain = try smfBytes(gpa, records.version, false);
    defer gpa.free(plain);
    var s = try dump(gpa, &schema, plain, .smf, .{});
    defer s.deinit();
    try testing.expect(!s.consumed.any());
    try testing.expectEqual(@as(usize, 1), countIn(s.text, "note-on"));
}

test "pipeline.build: build → dump → build → dump is a fixed point for a .mid" {
    // The final review's first defect: a rebuild of a dumped document
    // rendered every native lane into a base that still held its
    // previous rendering, so the file gained a copy of each note per
    // round. The claim now: the second dump's tier is the first's, byte
    // for byte, and every lane record names the same track.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try ready(gpa, &schema, native_doc);
    defer fx.deinit();

    var b1 = try build(gpa, &schema, native_doc, &fx.res.doc, &fx.derived, .smf, .{ .cc = 74 });
    defer b1.deinit();
    var d1 = try dump(gpa, &schema, b1.bytes, .smf, .{});
    defer d1.deinit();
    try testing.expect(!d1.diags.hasErrors());
    try testing.expect(d1.consumed.any());

    var derived1 = try time_derive.derive(gpa, &d1.doc);
    defer derived1.deinit();
    var b2 = try build(gpa, &schema, d1.text, &d1.doc, &derived1, .smf, .{ .cc = 74 });
    defer b2.deinit();
    try testing.expect(!b2.diags.hasErrors());
    var d2 = try dump(gpa, &schema, b2.bytes, .smf, .{});
    defer d2.deinit();
    try testing.expect(!d2.diags.hasErrors());

    try testing.expectEqualStrings(beforeAnchor(d1.text), beforeAnchor(d2.text));
    try testing.expectEqualStrings(tierHalf(d1.text, .smf), tierHalf(d2.text, .smf));
    try testing.expectEqual(b1.lanes.len, b2.lanes.len);
    for (b1.lanes, b2.lanes) |x, y| {
        try testing.expectEqualStrings(x.lane, y.lane);
        try testing.expectEqual(x.address.smf.track, y.address.smf.track);
        try testing.expect(x.address.smf.ch.eql(y.address.smf.ch));
    }

    // The music in the two files is the same music: one track per lane,
    // each note once.
    var r1 = try smf.read(gpa, b1.bytes);
    defer r1.deinit();
    var r2 = try smf.read(gpa, b2.bytes);
    defer r2.deinit();
    try testing.expectEqual(r1.sequence.tracks.len, r2.sequence.tracks.len);
    try testing.expectEqual(@as(usize, 1), noteOns(&r2.sequence, 36));
    try testing.expectEqual(@as(usize, 1), noteOns(&r2.sequence, 38));

    try testing.expectEqual(reconcile.Rule.restored, d2.rule);
    for (d2.verdicts) |v| try testing.expectEqual(reconcile.Action.restored_native, v.action);
    var tier_free = d2.doc;
    tier_free.anchors = &.{};
    tier_free.midi = &.{};
    tier_free.it = &.{};
    try testing.expect(tier_free.eql(&fx.res.doc));
}

test "pipeline.build: the same round is a fixed point for a .it" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try ready(gpa, &schema, native_doc);
    defer fx.deinit();

    var b1 = try build(gpa, &schema, native_doc, &fx.res.doc, &fx.derived, .it, .{});
    defer b1.deinit();
    var d1 = try dump(gpa, &schema, b1.bytes, .it, .{});
    defer d1.deinit();
    try testing.expect(!d1.diags.hasErrors());
    try testing.expect(d1.consumed.cells > 0);

    var derived1 = try time_derive.derive(gpa, &d1.doc);
    defer derived1.deinit();
    var b2 = try build(gpa, &schema, d1.text, &d1.doc, &derived1, .it, .{});
    defer b2.deinit();
    try testing.expect(!b2.diags.hasErrors());
    var d2 = try dump(gpa, &schema, b2.bytes, .it, .{});
    defer d2.deinit();
    try testing.expect(!d2.diags.hasErrors());

    try testing.expectEqualStrings(beforeAnchor(d1.text), beforeAnchor(d2.text));
    const t1 = try withoutMessage(gpa, tierHalf(d1.text, .it));
    defer gpa.free(t1);
    const t2 = try withoutMessage(gpa, tierHalf(d2.text, .it));
    defer gpa.free(t2);
    try testing.expectEqualStrings(t1, t2);
    // The message's tail is the one thing that moved: the second
    // document has an anchor, and the tail says so.
    try testing.expectEqual(
        @as(usize, 0),
        countIn(tierHalf(d1.text, .it), "(anchor :id song :kind it :file"),
    );
    try testing.expectEqual(
        @as(usize, 1),
        countIn(tierHalf(d2.text, .it), "(anchor :id song :kind it :file"),
    );
    // The lanes land on the channels the dump emptied, not above them.
    try testing.expectEqual(b1.lanes.len, b2.lanes.len);
    for (b1.lanes, b2.lanes) |x, y| {
        try testing.expectEqualStrings(x.lane, y.lane);
        try testing.expectEqual(x.address.it.channel, y.address.it.channel);
    }
    try testing.expectEqual(reconcile.Rule.restored, d2.rule);
    for (d2.verdicts) |v| try testing.expectEqual(reconcile.Action.restored_native, v.action);
}

test "pipeline.build: a note edited after restoration renders once, onto the track the dump left" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try ready(gpa, &schema, native_doc);
    defer fx.deinit();

    var b1 = try build(gpa, &schema, native_doc, &fx.res.doc, &fx.derived, .smf, .{ .cc = 74 });
    defer b1.deinit();
    var d1 = try dump(gpa, &schema, b1.bytes, .smf, .{});
    defer d1.deinit();

    // The author moves the kick's first note up a fourth in the dumped
    // document, and builds again.
    const edited = try std.mem.replaceOwned(u8, gpa, d1.text, ":key 36", ":key 41");
    defer gpa.free(edited);
    const edited_z = try gpa.dupeZ(u8, edited);
    defer gpa.free(edited_z);
    var fx2 = try ready(gpa, &schema, edited_z);
    defer fx2.deinit();
    var b2 = try build(gpa, &schema, edited_z, &fx2.res.doc, &fx2.derived, .smf, .{ .cc = 74 });
    defer b2.deinit();
    try testing.expect(!b2.diags.hasErrors());

    var r2 = try smf.read(gpa, b2.bytes);
    defer r2.deinit();
    try testing.expectEqual(@as(usize, 1), noteOns(&r2.sequence, 41));
    try testing.expectEqual(@as(usize, 0), noteOns(&r2.sequence, 36));
    try testing.expectEqual(@as(usize, 1), noteOns(&r2.sequence, 38));
    try testing.expectEqual(b1.lanes[0].address.smf.track, b2.lanes[0].address.smf.track);

    var d2 = try dump(gpa, &schema, b2.bytes, .smf, .{});
    defer d2.deinit();
    try testing.expectEqual(reconcile.Rule.restored, d2.rule);
    try testing.expectEqual(@as(usize, 1), countIn(d2.text, ":key 41"));
    try testing.expectEqual(@as(usize, 0), countIn(d2.text, ":key 36"));
}

test "pipeline: a lane rendered on two channels and edited on one dumps bound at both, and derive reads both" {
    // The reviewer's defect: a lane whose notes name two channels is one
    // track and two records; a DAW edit to channel 2 made the lane bind
    // at channel 2 alone, and channel 1's notes were in the tier and in
    // no lane. Now the lane binds at `:ch [1 2]`, nothing of it is
    // consumed, and `derive` reads both channels back.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const two: [:0]const u8 =
        \\(timeline :title "kit" :length 1bar)
        \\
        \\(tempo-point :at 0bar :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\
        \\(lane :name kit :kind notes
        \\  (note :at 0bar :dur 1q :key 36 :vel 100 :ch 1)
        \\  (note :at 1q :dur 1q :key 38 :vel 80 :ch 2))
        \\
    ;
    var fx = try ready(gpa, &schema, two);
    defer fx.deinit();
    var built = try build(gpa, &schema, two, &fx.res.doc, &fx.derived, .smf, .{});
    defer built.deinit();
    try testing.expect(!built.diags.hasErrors());
    // One track, one record per channel.
    try testing.expectEqual(@as(usize, 2), built.lanes.len);
    try testing.expect(built.lanes[0].address.smf.ch.eql(.single(0)));
    try testing.expect(built.lanes[1].address.smf.ch.eql(.single(1)));
    try testing.expectEqual(built.lanes[0].address.smf.track, built.lanes[1].address.smf.track);

    // The DAW's edit: the channel-2 note, one velocity lighter. The
    // residue rides through a read and a write untouched.
    var r = try smf.read(gpa, built.bytes);
    defer r.deinit();
    var touched = false;
    for (r.sequence.tracks) |t| {
        for (t.events) |*e| {
            if (e.kind == .note_on and e.payload.note.ch == 1 and e.payload.note.vel == 80) {
                e.payload.note.vel = 64;
                touched = true;
            }
        }
    }
    try testing.expect(touched);
    var edited = try smf.write(gpa, &r.sequence, .{});
    defer edited.deinit();

    var d = try dump(gpa, &schema, edited.bytes, .smf, .{});
    defer d.deinit();
    try testing.expectEqual(reconcile.Rule.restored, d.rule);
    try testing.expect(!d.diags.hasErrors());
    try testing.expectEqual(@as(usize, 2), d.verdicts.len);
    try testing.expect(d.verdicts[0].hash_ok);
    try testing.expect(!d.verdicts[1].hash_ok);
    for (d.verdicts) |v| try testing.expectEqual(reconcile.Action.became_bound, v.action);
    // Bound at BOTH channels, and nothing of the lane consumed: the tier
    // keeps every note event for the bound lane to read.
    try testing.expectEqual(@as(usize, 1), countIn(d.text, ":from song :track 2 :ch [1 2])"));
    try testing.expectEqual(@as(usize, 0), d.consumed.events);
    try testing.expectEqual(@as(usize, 2), d.consumed.conductor);
    try testing.expectEqual(@as(usize, 2), countIn(d.text, "note-on"));
    try testing.expect(d.doc.lanes[0].binding.?.address.smf.ch.eql(Doc.Channels.single(0).with(1)));

    // …and the lane reads both channels, each onset on its own, with the
    // DAW's velocity where the DAW put it.
    var derived = try time_derive.derive(gpa, &d.doc);
    defer derived.deinit();
    const onsets = derived.lanes[0].onsets;
    try testing.expectEqual(@as(usize, 2), onsets.len);
    try testing.expectEqual(@as(u7, 36), onsets[0].key);
    try testing.expectEqual(@as(u4, 0), onsets[0].ch);
    try testing.expectEqual(@as(u7, 100), onsets[0].vel);
    try testing.expectEqual(@as(u7, 38), onsets[1].key);
    try testing.expectEqual(@as(u4, 1), onsets[1].ch);
    try testing.expectEqual(@as(u7, 64), onsets[1].vel);
}

test "pipeline: a newer Binary IR wire version keeps its payloads in the tier, and a build keeps them" {
    // The final review's fourth defect: a residue under this build's
    // own envelope whose ESSENCE is a wire version this substrate does
    // not decode was detached from the tier before anyone looked inside
    // it, so the dump said "left in the file" over a tier that no longer
    // held it, and a rebuild wrote its own residue over the newer one
    // without `--force-residue`.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const bytes = try smfBytesWith(gpa, records.version, true, true);
    defer gpa.free(bytes);

    var got = try dump(gpa, &schema, bytes, .smf, .{});
    defer got.deinit();
    try testing.expectEqual(reconcile.Rule.version, got.rule);
    try testing.expect(got.diags.count(.residue_version) > 0);
    try testing.expect(!got.diags.hasErrors());
    try testing.expect(
        std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue is a newer version"),
    );
    // The carrier events are in the tier — all three of them.
    try testing.expectEqual(@as(usize, 3), countIn(got.text, "sequencer-specific"));
    try testing.expect(!got.consumed.any());

    // A build of that document carries them through and writes none of
    // its own…
    var derived = try time_derive.derive(gpa, &got.doc);
    defer derived.deinit();
    var kept = try build(gpa, &schema, got.text, &got.doc, &derived, .smf, .{});
    defer kept.deinit();
    try testing.expect(!kept.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), kept.diags.count(.residue_newer_kept));
    try testing.expectEqual(@as(usize, 0), kept.essence_bytes);
    var back = try smf.read(gpa, kept.bytes);
    defer back.deinit();
    try testing.expectEqual(Newer{ .wire = 0xFE }, newerSmf(&back.sequence).?);

    // …unless told to.
    var forced = try build(
        gpa,
        &schema,
        got.text,
        &got.doc,
        &derived,
        .smf,
        .{ .force_residue = true },
    );
    defer forced.deinit();
    try testing.expect(forced.essence_bytes > 0);
    var again = try smf.read(gpa, forced.bytes);
    defer again.deinit();
    try testing.expectEqual(@as(?Newer, null), newerSmf(&again.sequence));

    // `check-residue` says which version it is leaving alone.
    var report = try checkResidue(gpa, bytes, .smf);
    defer report.deinit();
    try testing.expect(std.mem.indexOf(u8, report.text, "wire version 254") != null);
}

test "pipeline: an IT chunk whose essence is a newer wire version is rule 5, or rule 3 with no tail" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // With the tail beside it, the tail is read (rule 5) and the chunk
    // stays in the file.
    {
        const bytes = try itCarrierBytes(gpa, &schema, .{ .bump_wire = true });
        defer gpa.free(bytes);
        var got = try dump(gpa, &schema, bytes, .it, .{});
        defer got.deinit();
        try testing.expectEqual(reconcile.Rule.partial, got.rule);
        try testing.expect(got.diags.count(.residue_version) > 0);
        try testing.expect(got.diags.count(.residue_partial) > 0);
        try testing.expect(!got.diags.hasErrors());

        var report = try checkResidue(gpa, bytes, .it);
        defer report.deinit();
        try testing.expect(std.mem.indexOf(u8, report.text, "wire version 254") != null);

        // A build over the anchor's bytes keeps the chunk.
        var derived = try time_derive.derive(gpa, &got.doc);
        defer derived.deinit();
        var kept = try build(
            gpa,
            &schema,
            got.text,
            &got.doc,
            &derived,
            .it,
            .{ .anchor_bytes = bytes },
        );
        defer kept.deinit();
        try testing.expectEqual(@as(usize, 1), kept.diags.count(.residue_newer_kept));
        try testing.expectEqual(@as(usize, 0), kept.essence_bytes);
        var back = try itf.read.read(gpa, kept.bytes);
        defer back.deinit();
        const region = back.module.tmpu.?;
        try testing.expectEqual(Newer{ .wire = 0xFE }, newerIt(region.slice(kept.bytes)).?);
    }

    // With no tail, the skeleton is derived under rule 3's header.
    {
        const bytes = try itCarrierBytes(gpa, &schema, .{ .bump_wire = true, .tail = false });
        defer gpa.free(bytes);
        var got = try dump(gpa, &schema, bytes, .it, .{});
        defer got.deinit();
        try testing.expectEqual(reconcile.Rule.version, got.rule);
        try testing.expect(
            std.mem.startsWith(u8, got.text, "; skeleton: derived, the residue is a newer version"),
        );
        try testing.expect(!got.diags.hasErrors());
    }
}

test "pipeline.dump: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails
    // with error.OutOfMemory and testing.allocator sees no leak; past
    // the last index it succeeds. Bounded by the number of allocations
    // the call makes, which the loop discovers. Both kinds, each with a
    // residue, so both carriers and the reconciliation are swept.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const mid = try smfBytes(gpa, records.version, true);
    defer gpa.free(mid);
    const it = try itBytes(gpa, &schema, true);
    defer gpa.free(it);

    for ([_]struct { []const u8, Doc.AnchorKind }{ .{ mid, .smf }, .{ it, .it } }) |case| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            const result = dump(failing.allocator(), &schema, case[0], case[1], .{});
            if (failing.has_induced_failure) {
                try testing.expectError(error.OutOfMemory, result);
            } else {
                var got = try result;
                got.deinit();
                break;
            }
        }
    }
}

test "pipeline.build: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails
    // with error.OutOfMemory and testing.allocator sees no leak; past
    // the last index it succeeds. Bounded by the number of allocations
    // the call makes, which the loop discovers. Both kinds, each with its
    // residue, so the records and both carriers — the SMF events, the
    // `TMPU` chunk and the message tail — are swept.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var fx = try ready(gpa, &schema, native_doc);
    defer fx.deinit();

    for ([_]Doc.AnchorKind{ .smf, .it }) |kind| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            const result = build(
                failing.allocator(),
                &schema,
                native_doc,
                &fx.res.doc,
                &fx.derived,
                kind,
                .{},
            );
            if (failing.has_induced_failure) {
                try testing.expectError(error.OutOfMemory, result);
            } else {
                var got = try result;
                got.deinit();
                break;
            }
        }
    }
}

// ---- the tier text, one spelling for inline and dump ----

/// One file of each kind with no residue in it: nothing for a dump to
/// detach or consume, so its tier is the file's as printed.
const Bare = struct { bytes: []const u8, kind: Doc.AnchorKind };

test "pipeline.tierText: the tier a file prints as is the one dump splices" {
    // …for both kinds — which is the claim that `tempura inline` and
    // `tempura dump` spell a file's tier with one call.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const smf_bytes = try smfBytes(gpa, records.version, false);
    defer gpa.free(smf_bytes);
    const it_bytes = try itBytes(gpa, &schema, false);
    defer gpa.free(it_bytes);

    const bare = [_]Bare{
        .{ .bytes = smf_bytes, .kind = .smf },
        .{ .bytes = it_bytes, .kind = .it },
    };
    for (bare) |file| {
        var diags: Diag.List = .init(gpa);
        defer diags.deinit();
        const tier = try tierText(gpa, file.bytes, file.kind, .{}, &diags);
        defer gpa.free(tier);
        try testing.expect(!diags.hasErrors());

        var got = try dump(gpa, &schema, file.bytes, file.kind, .{});
        defer got.deinit();
        try testing.expect(tier.len > 0);
        try testing.expect(std.mem.indexOf(u8, got.text, tier) != null);
    }
}

test "pipeline.tierText: OutOfMemory at every allocation, and nothing leaks" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const smf_bytes = try smfBytes(gpa, records.version, false);
    defer gpa.free(smf_bytes);
    const it_bytes = try itBytes(gpa, &schema, false);
    defer gpa.free(it_bytes);

    const bare = [_]Bare{
        .{ .bytes = smf_bytes, .kind = .smf },
        .{ .bytes = it_bytes, .kind = .it },
    };
    for (bare) |file| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            var diags: Diag.List = .init(failing.allocator());
            defer diags.deinit();
            const result = tierText(failing.allocator(), file.bytes, file.kind, .{}, &diags);
            if (failing.has_induced_failure) {
                try testing.expectError(error.OutOfMemory, result);
            } else {
                gpa.free(try result);
                break;
            }
        }
    }
}
