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

    const found: reconcile.Found = if (newer) |v|
        .{ .newer = v }
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

    var chosen = try residue_it.choose(gpa, chunk_bytes, read.module.message, diags);
    defer chosen.deinit();

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

    const found: reconcile.Found = switch (chosen) {
        .chunk => |p| .{ .payloads = p.payloads },
        .tail => .{ .tail = tail_src.? },
        // A chunk of a version this build does not read, with no tail to
        // fall back on, is rule 3 and not rule 1: the payload is still
        // in the file, as the opaque region the writer re-emits.
        .none => if (newer) |v| .{ .newer = v } else .none,
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
// Tests
// ---------------------------------------------------------------------

const residue_essence = @import("../residue/essence.zig");
const walk = @import("../itf/walk.zig");

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
