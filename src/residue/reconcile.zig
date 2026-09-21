//! Reconciliation: what a `dump` makes of what it found in the file.
//!
//! Plan 04, "Reconciliation (the one rule)", phase 5. The five rules are
//! the spec and this file is nothing but them, in their order:
//!
//!   1. **No residue** — derive the skeleton (`doc/skeleton.zig`): one
//!      bound lane per address the file uses, its markers as cues, the
//!      anchor conducting. The document opens with
//!      `; skeleton: derived, no residue found`.
//!   2. **Residue understood** — restore the essence as the timeline
//!      tier, then ask the hashes whether the file and the residue were
//!      written together. The conductor record first (match: the
//!      document conducts; mismatch: the FILE conducts, `:conductor` is
//!      set and the document's own points and cues are dropped with
//!      `residue_stale`), then one lane record at a time (match: the
//!      lane is restored native and its address is CONSUMED — the
//!      rendered events are never also imported as a bound lane;
//!      mismatch: the lane becomes BOUND, keeping its name, target,
//!      range and, for a curve, the easing hints the file's own steps
//!      confirm, and `residue_stale` names what the exact content
//!      cost). A lane may hold SEVERAL records — a `.mid` lane whose
//!      notes named more than one channel writes one per channel, since
//!      a hash is over a `(track, ch)` pair — and the lane is one thing:
//!      if ANY of its records is stale it binds, at the records' track
//!      and at the UNION of every channel they name (`:ch [1 2]`), so
//!      the channel nobody edited is read by the lane rather than left
//!      in the tier belonging to nothing; and every record of a lane
//!      that binds reports `became_bound` with its own `hash_ok`, so the
//!      table never says a lane was restored native when it was not,
//!      and the consumption (below) leaves every channel of a bound
//!      lane in the tier for it to read.
//!   3. **A newer envelope or wire version** — the payloads stay where
//!      they are, unparsed (plain `sequencer-specific` events in a
//!      `.mid`, the opaque `TMPU` region in a `.it`) and the skeleton is
//!      derived. A newer ENVELOPE arrives as `Found.newer`, already
//!      named `residue_version` by the carrier that stepped over it; a
//!      newer Binary IR WIRE version is this file's to name, because it
//!      is this file that asked `essence.unpack`.
//!   4. **Corrupt or truncated** — the skeleton, with `residue_corrupt`.
//!      Records that rode in with no essence to restore are the same
//!      damage under another name and take the same branch: a build
//!      writes the essence first and the records beside it, so one
//!      without the other is a torn residue and never a small one.
//!   5. **Both IT carriers** — `it.choose` has already picked (the chunk
//!      wins); a tail alone arrives here as `Found.tail`, is restored as
//!      the shape of the piece and nothing else, and every rendered lane
//!      stays bound. `residue_partial` is `choose`'s to raise, so it is
//!      raised once and not twice.
//!
//! The rule in one line, plan 04's own: **the file's native content is
//! the truth for what the file can say; the residue is the truth for
//! what it cannot; the hash says whether the two were written
//! together.**
//!
//! # Why this works over TEXT
//!
//! The essence is the document a human wrote — comments, blank lines,
//! authored spellings and all (`essence.zig`). Lowering it to a `Doc` and
//! printing it back would throw every one of those away, and plan 04's
//! "essence-exact" rung says `dump(build(doc))` reproduces the timeline
//! tier FORM FOR FORM. So reconciliation is a set of surgical edits over
//! the essence's own text, driven by its parse tree's spans: a root is
//! kept verbatim, dropped whole (its leading comments with it), or
//! re-emitted. Nothing else is touched.
//!
//! **The marker becomes an anchor again.** `essence.pack` replaced the
//! carrying `(anchor …)` with `(anchor :id X :kind K :file "self")`,
//! because a file cannot name its own path, size or digest. Here the
//! marker is rewritten back into a real anchor over the bytes being
//! dumped — `:file` the name the dump was asked for, `:size` and
//! `:sha256` computed from those very bytes, so the document that comes
//! out verifies against the file it came from by construction. That
//! rewrite is this file's, not `essence.zig`'s: only a dump knows what
//! the file is called and how long it is.
//!
//! # What comes out
//!
//! `doc_text` is the TIMELINE TIER alone, with `tier_at` saying where
//! the file's own `(midi/…)` or `(it/…)` dump belongs in it — straight
//! after the carrying anchor's line, because plan 02's anchor/dump
//! pairing is positional. `doc/pipeline.zig` splices the two and loads
//! the result through `fromSource`, so every host check runs over the
//! real thing before anyone is handed it.
//!
//! ```zig
//! var got = try reconcile.reconcile(gpa, &schema, .{
//!     .tier = .{ .smf = &seq },
//!     .text = tier_text,
//!     .bytes = file_bytes,
//!     .name = "song.mid",
//! }, .{ .payloads = detached.payloads }, .{});
//! defer got.deinit();
//! // got.doc_text, got.verdicts, got.conductor, got.diags
//! ```

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const Schema = @import("../Schema.zig");
const Doc = @import("../doc/Value.zig");
const Resolver = @import("../doc/Resolver.zig");
const fromSjon = @import("../doc/fromSjon.zig");
const toSjon = @import("../doc/toSjon.zig");
const skeleton = @import("../doc/skeleton.zig");
const bridge_smf = @import("../doc/bridge_smf.zig");
const bridge_it = @import("../doc/bridge_it.zig");
const Grid = @import("../time/Grid.zig");
const time_derive = @import("../time/derive.zig");
const Sequence = @import("../smf/Sequence.zig");
const itf = @import("../itf/itf.zig");
const walk = @import("../itf/walk.zig");

const essence = @import("essence.zig");
const records = @import("records.zig");

const Ast = sjon.Ast;
const NodeIndex = Ast.NodeIndex;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const testing = std.testing;

/// Only resource exhaustion is an error. Every defect of a payload and
/// every disagreement between the file and the residue is a diagnostic
/// or a verdict on the returned value.
pub const Error = error{OutOfMemory};

/// The line a document opens with when its timeline tier was INFERRED
/// and not restored. Four reasons, four lines, so a reader knows at a
/// glance which of plan 04's rules ran.
pub const header_skeleton = skeleton.header_comment;
pub const header_version = "; skeleton: derived, the residue is a newer version and was left in the file";
pub const header_corrupt = "; skeleton: derived, the residue would not decode";
pub const header_partial = "; partial: the IT message tail alone — the shape of the piece, none of its content";

/// How close a step has to sit to a hinted curve for the hint to be
/// honoured. `export/lanes.zig`'s own default: one MIDI step, which is
/// the finest a 7-bit controller can express.
pub const default_eps: f32 = 1.0 / 127.0;

// ---- what goes in -----------------------------------------------------

/// The file a dump is of, as its format core read it.
pub const Tier = union(enum) {
    smf: *const Sequence.Sequence,
    it: *const itf.Module,

    pub fn kind(self: Tier) Doc.AnchorKind {
        return switch (self) {
            .smf => .smf,
            .it => .it,
        };
    }
};

/// Everything reconciliation needs to know about the file: the value the
/// core read, the bridge's text for it, and the three facts an anchor is
/// made of.
///
/// The brief's signature names only the tier. The other three are here
/// because rule 2 cannot restore the marker without them: `(anchor …
/// :file "self")` becomes a real anchor over `name`, `bytes.len` and
/// `sha256(bytes)`, and the skeleton path needs the bridge's text to
/// lower the file back into a document it can walk. `text` is the
/// CALLER's — it was produced with the caller's own `--patterns=bin`,
/// `--preserve-foreign` and `--preserve-history`, and rendering a second
/// copy here with the defaults would silently disagree with it.
pub const File = struct {
    tier: Tier,
    /// The `(midi/…)` or `(it/…)` forms of `tier`, from the bridge.
    text: []const u8,
    /// The bytes being dumped — the anchor's `:size` and `:sha256`.
    bytes: []const u8,
    /// What the anchor's `:file` says.
    name: []const u8,
};

/// What the carrier handed over. `.payloads` is `smf.detach`'s or the
/// `TMPU` chunk's; `.tail` is `it.parseTail`'s SJON source.
pub const Found = union(enum) {
    /// No residue in this file at all — plan 04's rule 1.
    none,
    payloads: records.Payloads,
    tail: []const u8,
    /// Rule 3: the carrier holds a residue of an ENVELOPE version this
    /// build does not read, and the byte is that version. The payloads
    /// stayed where they were — plain `sequencer-specific` events in the
    /// `midi/` tier, the opaque `TMPU` region in the `it/` one — and the
    /// carrier has already raised `residue_version` over them, so this
    /// arm derives the skeleton and does not say it twice.
    newer: u8,
    /// Rule 4: the carrier held a residue and could not read it — a
    /// `TMPU` chunk whose framing does not hold, a split essence with a
    /// part missing. The carrier has already raised `residue_corrupt`,
    /// so this arm derives the skeleton under the CORRUPT header and
    /// does not say it twice.
    ///
    /// It exists because `.none` and this are not the same file: `.none`
    /// prints "no residue found", and printing that over a file that
    /// carried one — while the diagnostics say `residue_corrupt` — is
    /// two surfaces contradicting each other.
    corrupt,
};

pub const Options = struct {
    /// `--cues`: one cue per played IT order, for the skeleton path.
    cues: bool = false,
    /// The anchor id a DERIVED document takes. The restored paths use
    /// the id the author wrote, which the marker carries.
    anchor_id: []const u8 = "song",
    /// The tolerance an easing hint is verified within.
    eps: f32 = default_eps,
};

// ---- what comes out ---------------------------------------------------

/// Which of plan 04's five rules ran.
pub const Rule = enum {
    /// Rule 1: no residue at all.
    derived,
    /// Rule 2: the essence was restored.
    restored,
    /// Rule 3: a version this build does not read.
    version,
    /// Rule 4: the payload would not decode.
    corrupt,
    /// Rule 5: the IT message tail alone.
    partial,
};

/// What became of one lane.
pub const Action = enum {
    /// Rule 2, hash match: the lane is the essence's own, natively, and
    /// the file's events at its address are CONSUMED.
    restored_native,
    /// Rule 2, hash mismatch, or rule 5: the file's events win and the
    /// lane reads them.
    became_bound,
    /// Rules 1, 3 and 4: the lane was inferred from the file.
    skeleton,
};

/// "These steps were `ease` between `from` and `to`" — a lane record's
/// segment, verified against the file's own steps and kept.
///
/// The same shape `export/lanes.zig` consumes as an `EaseHint`, minus
/// the lane name, which the verdict already carries.
pub const Hint = struct {
    from: i64,
    to: i64,
    ease: []const u8,
};

pub const LaneVerdict = struct {
    lane: []const u8,
    address: Doc.Address,
    /// Whether the file's events at `address` are what the record says
    /// tempura wrote there. False for every lane with no record.
    hash_ok: bool,
    action: Action,
    /// A stale curve's easing hints that the file's steps confirm. The
    /// ones they contradict are gone, each with `ease_hint_mismatch`.
    hints: []const Hint = &.{},
};

pub const ConductorVerdict = struct {
    /// Whether the file's timing context is what the record recorded.
    hash_ok: bool,
    /// True when the hash differed and the FILE therefore conducts.
    file_conducts: bool,
};

/// The reconciled timeline tier and the report on it. One arena owns
/// `doc_text`, `verdicts` and every string in them.
pub const Result = struct {
    doc_text: []const u8,
    /// Where the file's own tier belongs inside `doc_text`: the byte
    /// just after the carrying anchor's line. `doc_text.len` when the
    /// document holds no anchor at all.
    tier_at: usize,
    verdicts: []const LaneVerdict,
    conductor: ?ConductorVerdict,
    rule: Rule,
    /// The IT patterns the walk played, ascending — the scope every
    /// lane hash was taken over (`playedPatterns`), kept so that
    /// `consumeIt` clears exactly the cells the record vouched for.
    /// Empty for a `.mid`.
    played: []const u16,
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        self.diags.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// The verdict for the lane named `name`, or null. The tests' join.
    pub fn verdictFor(self: *const Result, name: []const u8) ?LaneVerdict {
        for (self.verdicts) |v| {
            if (std.mem.eql(u8, v.lane, name)) return v;
        }
        return null;
    }
};

// ---- the entry point --------------------------------------------------

/// Plan 04's five rules over one file and what its carrier held.
pub fn reconcile(
    gpa: Allocator,
    schema: *const Schema,
    file: File,
    found: Found,
    opts: Options,
) Error!Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var run: Run = .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .schema = schema,
        .file = file,
        .opts = opts,
        .diags = &diags,
        .hasher = .init(gpa, file.tier),
    };
    defer run.deinit();

    switch (found) {
        .none => try run.derive(.derived),
        .newer => try run.derive(.version),
        .corrupt => try run.derive(.corrupt),
        .tail => |text| try run.partial(text),
        .payloads => |p| try run.fromPayloads(p),
    }

    // Into the result's arena, because the hasher that walked them goes
    // with the run.
    const played = try playedPatterns(arena.allocator(), try run.rowmap());

    return .{
        .doc_text = run.text,
        .tier_at = run.tier_at,
        .verdicts = run.verdicts.items,
        .conductor = run.conductor,
        .rule = run.rule,
        .played = played,
        .diags = diags,
        .arena = arena,
    };
}

// ---------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------

/// One reconciliation, with the two allocators it uses kept apart:
/// `arena` is the result's and owns everything that comes out — nothing
/// allocated from it is ever freed on its own — and `gpa` is for the
/// scratch the intermediate loads and walks need, freed as it goes.
const Run = struct {
    gpa: Allocator,
    arena: Allocator,
    schema: *const Schema,
    file: File,
    opts: Options,
    diags: *Diag.List,

    text: []const u8 = &.{},
    tier_at: usize = 0,
    verdicts: std.ArrayList(LaneVerdict) = .empty,
    conductor: ?ConductorVerdict = null,
    rule: Rule = .derived,

    /// The four hashes over the file as it reads NOW, with the IT
    /// walk done once.
    hasher: Hasher,

    fn deinit(self: *Run) void {
        self.hasher.deinit();
    }

    fn rowmap(self: *Run) Error!*const walk.RowMap {
        return self.hasher.rowmap();
    }

    // ---- rule 2's entry: what the payloads turned out to be ----

    fn fromPayloads(self: *Run, p: records.Payloads) Error!void {
        // An essence OFFERED and empty is `pack` reporting that the tier
        // was past SJON's wire limits — the carrier said so at build
        // time, and there is nothing here to restore.
        const body = blk: {
            const b = p.essence orelse &.{};
            break :blk if (b.len == 0) null else b;
        } orelse {
            // Records and no essence is a TORN residue, not a small one:
            // a build writes the essence first and the records beside
            // it, so one without the other is damage (a split body with
            // a missing part is exactly what `reassemble` reports this
            // way). Rule 4, not rule 1 — the difference matters, because
            // rule 1's document says "no residue found" and this file
            // had one.
            if (p.conductor != null or p.lanes.len > 0) {
                try self.diags.add(
                    .residue_corrupt,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "{d} lane record(s) and {s} conductor record rode in this file with no essence to restore; the timeline tier is derived instead",
                    .{ p.lanes.len, if (p.conductor != null) "a" else "no" },
                );
                return self.derive(.corrupt);
            }
            return self.derive(.derived);
        };

        var unpacked = try essence.unpack(self.gpa, body);
        defer unpacked.deinit(self.gpa);
        switch (unpacked) {
            .ok => |e| try self.restore(e.text, p),
            .version => |v| {
                try self.diags.add(
                    .residue_version,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "the essence is SJON Binary IR of wire version {d}, which this substrate does not decode; the payload stays in the file and the timeline tier is derived instead",
                    .{v},
                );
                try self.derive(.version);
            },
            .corrupt => |code| {
                try self.diags.add(
                    code,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "the essence ({d} bytes) is not decodable Binary IR; the timeline tier is derived instead",
                    .{body.len},
                );
                try self.derive(.corrupt);
            },
        }
    }

    // ---- rule 1, 3 and 4: the skeleton ----

    /// Plan 04's rule 1, and the fallback rules 3 and 4 take: the file
    /// lowered back into the smallest document that can hold it, and
    /// then the tier `doc/skeleton.zig` derives from what it uses.
    fn derive(self: *Run, rule: Rule) Error!void {
        self.rule = rule;

        const source = try self.wrapper();
        const table: Resolver.Memory = .{
            .entries = &.{.{ .path = self.file.name, .bytes = self.file.bytes }},
        };

        // Its diagnostics are DISCARDED, and only here: this document is
        // tempura's own wrapper, three lines it just wrote from the
        // bridge's text, and anything it complained of would be a defect
        // in this function rather than anything a caller could act on.
        // The wrapper is thrown away too — what survives is the skeleton
        // derived from it. `doc/pipeline.zig` loads the text that
        // actually comes out, with a resolver and with every diagnostic
        // kept, which is where a real fault surfaces.
        var res = try fromSjon.fromSource(self.gpa, self.schema, source, Resolver.memory(&table));
        defer res.deinit();

        var sk = try skeleton.derive(self.gpa, &res.doc, .{ .cues = self.opts.cues });
        defer sk.deinit();
        // Borrowed from `sk`'s arena, which outlives every read below;
        // the document's own arena never sees them and `Doc.deinit`
        // frees an arena rather than these slices.
        res.doc.lanes = sk.lanes;
        res.doc.cues = sk.cues;
        if (sk.conductor) |c| res.doc.conductor = c;

        var derived = try time_derive.derive(self.gpa, &res.doc);
        defer derived.deinit();

        // The printer would re-render the inline tier with the bridge's
        // DEFAULT switches, undoing `--patterns=bin` and its siblings.
        // So the tier is lifted out for the print and `tier_at` says
        // where the caller's own text goes back in.
        const head = blk: {
            const saved_midi = res.doc.midi;
            const saved_it = res.doc.it;
            res.doc.midi = &.{};
            res.doc.it = &.{};
            defer {
                res.doc.midi = saved_midi;
                res.doc.it = saved_it;
            }
            break :blk try toSjon.print(self.gpa, &res.doc, &derived.map, .{});
        };
        defer self.gpa.free(head);

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.arena, headerFor(rule));
        try out.append(self.arena, '\n');
        try out.appendSlice(self.arena, head);
        self.text = out.items;
        self.tier_at = anchorLineEnd(self.text) orelse self.text.len;

        for (sk.lanes) |l| {
            const b = l.binding orelse continue;
            try self.verdicts.append(self.arena, .{
                .lane = try self.arena.dupe(u8, l.name),
                .address = b.address,
                .hash_ok = false,
                .action = .skeleton,
            });
        }
    }

    /// The smallest document that can hold the file: the anchor with the
    /// bytes' own `:size` and `:sha256`, `:conductor` naming it, and the
    /// bridge's dump after it.
    fn wrapper(self: *Run) Error![:0]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.arena, "(timeline :conductor ");
        try out.appendSlice(self.arena, self.opts.anchor_id);
        try out.appendSlice(self.arena, ")\n\n");
        try self.anchorForm(&out, self.opts.anchor_id, @tagName(self.file.tier.kind()));
        try out.append(self.arena, '\n');
        try out.appendSlice(self.arena, self.file.text);
        return out.toOwnedSliceSentinel(self.arena, 0);
    }

    /// `(anchor :id X :kind K :file "…" :size N :sha256 "…")` over the
    /// bytes being dumped — the marker, made real.
    fn anchorForm(
        self: *Run,
        out: *std.ArrayList(u8),
        id: []const u8,
        kind_name: []const u8,
    ) Error!void {
        try out.appendSlice(self.arena, "(anchor :id ");
        try out.appendSlice(self.arena, id);
        try out.appendSlice(self.arena, " :kind ");
        try out.appendSlice(self.arena, kind_name);
        try out.appendSlice(self.arena, " :file ");
        try self.string(out, self.file.name);
        try out.print(self.arena, " :size {d} :sha256 \"", .{self.file.bytes.len});
        try out.appendSlice(self.arena, &hexDigest(self.file.bytes));
        try out.appendSlice(self.arena, "\")");
    }

    fn string(self: *Run, out: *std.ArrayList(u8), text: []const u8) Error!void {
        try out.append(self.arena, '"');
        for (text) |c| {
            switch (c) {
                '"', '\\' => try out.append(self.arena, '\\'),
                else => {},
            }
            try out.append(self.arena, c);
        }
        try out.append(self.arena, '"');
    }

    // ---- rule 2: the essence restored ----

    /// Plan 04's rule 2, in its own order: restore the essence, ask the
    /// conductor record, then ask one lane record at a time.
    fn restore(self: *Run, text: [:0]const u8, p: records.Payloads) Error!void {
        // A record that will not decode is rule 4, not rule 2: a hash
        // field of the wrong length is exactly what "corrupt" names, and
        // half a verdict is worse than an honest skeleton.
        var recs: std.ArrayList(Record) = .empty;
        for (p.lanes) |body| {
            const rec = (try self.laneRecord(body)) orelse return self.derive(.corrupt);
            try recs.append(self.arena, rec);
        }
        const conductor_rec: ?records.ConductorRecord = if (p.conductor) |body|
            (try self.conductorRecord(body)) orelse return self.derive(.corrupt)
        else
            null;

        var tree = try sjon.parse(self.gpa, text);
        defer tree.deinit();
        if (tree.hasErrors()) return self.corruptEssence();

        self.rule = .restored;

        // The conductor, first: it decides whether the document keeps its
        // own points at all, and the emit loop below needs that answer.
        var file_conducts = false;
        if (conductor_rec) |rec| {
            const now = self.conductorHash();
            const ok = std.mem.eql(u8, &rec.hash, &now);
            self.conductor = .{ .hash_ok = ok, .file_conducts = !ok };
            file_conducts = !ok;
        }

        // Then every lane record, against the events at its address as
        // they read NOW.
        for (recs.items) |*rec| {
            const now = try self.laneHash(rec.address);
            rec.hash_ok = std.mem.eql(u8, &rec.hash, &now);
        }

        try self.emit(&tree, text, recs.items, if (file_conducts) .file_wins else .document);
    }

    /// One lane record's body, decoded into the result's arena with its
    /// `hash_ok` still to be asked — or null, `residue_corrupt` raised,
    /// for a body that does not decode.
    fn laneRecord(self: *Run, body: []const u8) Error!?Record {
        var decoded = try records.decodeLane(self.gpa, body);
        defer decoded.deinit(self.gpa);
        switch (decoded) {
            .ok => |r| {
                const segments = try self.arena.alloc(records.Segment, r.steps_only.len);
                for (r.steps_only, segments) |src, *dst| dst.* = .{
                    .at = src.at,
                    .ease = try self.arena.dupe(u8, src.ease),
                };
                return .{
                    .lane = try self.arena.dupe(u8, r.lane),
                    .address = r.address,
                    .hash = r.hash,
                    .hash_ok = false,
                    .segments = segments,
                };
            },
            .corrupt => |code| {
                try self.diags.add(
                    code,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "a lane record's body ({d} bytes) does not decode; the timeline tier is derived instead",
                    .{body.len},
                );
                return null;
            },
        }
    }

    /// The conductor record decoded — or null, `residue_corrupt` raised,
    /// for a body that is not one SHA-256.
    fn conductorRecord(self: *Run, body: []const u8) Error!?records.ConductorRecord {
        return records.decodeConductor(body) orelse {
            try self.diags.add(
                .residue_corrupt,
                .warning,
                .{ .start = 0, .end = 0 },
                "the conductor record is {d} bytes and a SHA-256 is 32; the timeline tier is derived instead",
                .{body.len},
            );
            return null;
        };
    }

    /// The essence decoded but does not parse — which can only mean the
    /// body was damaged in a way Binary IR's own framing survived.
    fn corruptEssence(self: *Run) Error!void {
        try self.diags.add(
            .residue_corrupt,
            .warning,
            .{ .start = 0, .end = 0 },
            "the essence decoded but does not read back as SJON; the timeline tier is derived instead",
            .{},
        );
        return self.derive(.corrupt);
    }

    // ---- rule 5: the message tail alone ----

    /// The tail carries the SHAPE of the piece — the timeline's keys,
    /// sections, cues, lane declarations, pass-through controls — and no
    /// native content and no records. So there is no hash to check, every
    /// lane it names stays bound, and the only edit the text needs is the
    /// marker's.
    ///
    /// `residue_partial` belongs to `it.choose`, which is what decided
    /// the tail was all there was; raising it again here would say the
    /// same thing twice.
    fn partial(self: *Run, text: []const u8) Error!void {
        self.rule = .partial;

        const src = try self.arena.dupeZ(u8, text);
        var tree = try sjon.parse(self.gpa, src);
        defer tree.deinit();
        if (tree.hasErrors()) return self.corruptEssence();

        try self.emit(&tree, src, &.{}, .file_only);

        // A verdict per lane the tail could ADDRESS, and no more. The
        // tail carries a native lane's declaration without a `:from`,
        // because the address a native lane was rendered to lives in
        // its record and the tail has no records — so such a lane comes
        // back as a declaration with nothing in it, and claiming a
        // binding for it would be inventing one. Plan 04's "every
        // rendered lane stays bound" is about the lanes the tail can
        // still place.
        for (tree.root) |idx| {
            if (!isForm(&tree, idx, "lane")) continue;
            if (keyValue(&tree, idx, "from") == null) continue;
            const name = atomText(&tree, keyValue(&tree, idx, "name") orelse continue) orelse continue;
            const address = addressOf(&tree, idx, self.file.tier.kind()) orelse continue;
            try self.verdicts.append(self.arena, .{
                .lane = try self.arena.dupe(u8, name),
                .address = address,
                .hash_ok = false,
                .action = .became_bound,
            });
        }
    }

    // ---- the emit loop: keep, drop, re-emit ----

    /// The restored text, root by root. Every root is kept verbatim
    /// unless one of rule 2's two verdicts says otherwise, and the
    /// leading trivia of a dropped root — its comments and the blank
    /// line above it — goes with it.
    fn emit(
        self: *Run,
        tree: *const Ast.Tree,
        source: []const u8,
        recs: []const Record,
        conducting: Conducting,
    ) Error!void {
        var out: std.ArrayList(u8) = .empty;
        if (self.rule == .partial) {
            try out.appendSlice(self.arena, header_partial);
            try out.append(self.arena, '\n');
        }

        // The carrying anchor's own spelling, for the marker rewrite and
        // for the `:conductor` and `:from` a stale lane needs.
        const marker = markerOf(tree);
        const anchor_id = if (marker.id) |t| try self.arena.dupe(u8, t) else self.opts.anchor_id;
        const anchor_kind = if (marker.kind) |t|
            try self.arena.dupe(u8, t)
        else
            @tagName(self.file.tier.kind());

        var dropped: std.ArrayList([]const u8) = .empty;
        var placed = false;
        var cursor: Cursor = .{ .source = source };

        for (tree.root) |idx| {
            const span = tree.spanOf(idx);
            const root = cursor.next(span);
            switch (rootAction(tree, idx, marker.idx, conducting, recs)) {
                // The marker, made real — and the place the file's own
                // tier goes back into, straight after it.
                .marker => {
                    try out.appendSlice(self.arena, root.lead);
                    try self.anchorForm(&out, anchor_id, anchor_kind);
                    try out.append(self.arena, '\n');
                    self.tier_at = out.items.len;
                    placed = true;
                    cursor.eat_newline = true;
                },
                // Dropped whole, its lead with it, and named as a loss.
                .drop => |what| try dropped.append(self.arena, try self.dropLabel(tree, source, idx, what)),
                .conduct => {
                    try out.appendSlice(self.arena, root.lead);
                    try self.conductorKey(&out, source, span, anchor_id);
                },
                .bind => |name| {
                    try out.appendSlice(self.arena, root.lead);
                    try self.bindLane(&out, tree, source, idx, recs, name, anchor_id);
                },
                .keep => {
                    try out.appendSlice(self.arena, root.lead);
                    try out.appendSlice(self.arena, root.body);
                },
            }
        }

        try out.appendSlice(self.arena, cursor.rest());
        if (!placed) try self.appendAnchor(&out, anchor_id, anchor_kind);
        self.text = out.items;

        if (conducting == .file_wins) try self.batonTaken(dropped.items);
        try self.recordVerdicts(tree, recs);
    }

    /// `source` handed out root by root: each root's LEAD — the trivia
    /// since the previous root, its comments and the blank line above
    /// it — and its BODY, and after the last root whatever remains. The
    /// newline that ended a rewritten marker's line is eaten from the
    /// next lead, because the rewrite wrote its own.
    const Cursor = struct {
        source: []const u8,
        cut: usize = 0,
        eat_newline: bool = false,

        const Root = struct { lead: []const u8, body: []const u8 };

        fn next(self: *Cursor, span: Ast.Span) Root {
            const src = self.source;
            var lead = src[self.cut..@min(span.start, src.len)];
            const body = src[@min(span.start, src.len)..@min(span.end, src.len)];
            self.cut = @min(span.end, src.len);
            if (self.eat_newline) {
                if (std.mem.startsWith(u8, lead, "\n")) lead = lead[1..];
                self.eat_newline = false;
            }
            return .{ .lead = lead, .body = body };
        }

        fn rest(self: *const Cursor) []const u8 {
            var tail_text = self.source[@min(self.cut, self.source.len)..];
            if (self.eat_newline and std.mem.startsWith(u8, tail_text, "\n")) tail_text = tail_text[1..];
            return tail_text;
        }
    };

    /// What `emit` does with one root of the restored text.
    const RootAction = union(enum) {
        /// The carrying anchor's marker: rewritten over the bytes dumped.
        marker,
        /// The file won the conductor, and this point or cue goes.
        drop: Dropped,
        /// The `(timeline …)` head, which gains `:conductor`.
        conduct,
        /// A lane any of whose records is stale: rewritten bound.
        bind: []const u8,
        /// Verbatim.
        keep,
    };

    /// The three forms a file that took the baton drops.
    const Dropped = enum { tempo_point, meter_point, cue };

    /// Which of the five things `emit` does to the root at `idx`. Pure
    /// over the tree: the marker's own index, who conducts and the
    /// records are the whole decision.
    ///
    /// `.file_only` sets the `:conductor` and drops nothing — there was
    /// never anything to drop — and both ways the file conducts say so
    /// on the header.
    fn rootAction(
        tree: *const Ast.Tree,
        idx: NodeIndex,
        marker: ?NodeIndex,
        conducting: Conducting,
        recs: []const Record,
    ) RootAction {
        if (marker != null and idx == marker.?) return .marker;
        if (conducting == .file_wins) {
            if (isForm(tree, idx, "tempo-point")) return .{ .drop = .tempo_point };
            if (isForm(tree, idx, "meter-point")) return .{ .drop = .meter_point };
            if (isForm(tree, idx, "cue")) return .{ .drop = .cue };
        }
        if (conducting != .document) {
            if (isForm(tree, idx, "timeline") and keyValue(tree, idx, "conductor") == null) {
                return .conduct;
            }
        }
        if (isForm(tree, idx, "lane")) {
            if (keyValue(tree, idx, "name")) |v| {
                if (atomText(tree, v)) |name| {
                    if (laneIsStale(recs, name)) return .{ .bind = name };
                }
            }
        }
        return .keep;
    }

    /// The carrying anchor's marker in `tree` — the root `essence.pack`
    /// spelled `(anchor … :file "self")` — with the `:id` and `:kind`
    /// it carries, borrowed from the tree. All null when the essence
    /// carried no anchor at all.
    const Marker = struct {
        idx: ?NodeIndex = null,
        id: ?[]const u8 = null,
        kind: ?[]const u8 = null,
    };

    fn markerOf(tree: *const Ast.Tree) Marker {
        for (tree.root) |idx| {
            if (!isForm(tree, idx, "anchor")) continue;
            const f = keyValue(tree, idx, "file") orelse continue;
            const name = atomText(tree, f) orelse continue;
            if (!std.mem.eql(u8, name, essence.self_file)) continue;
            var found: Marker = .{ .idx = idx };
            if (keyValue(tree, idx, "id")) |v| found.id = atomText(tree, v);
            if (keyValue(tree, idx, "kind")) |v| found.kind = atomText(tree, v);
            return found;
        }
        return .{};
    }

    /// A dropped root as `residue_stale`'s list names it.
    fn dropLabel(
        self: *Run,
        tree: *const Ast.Tree,
        source: []const u8,
        idx: NodeIndex,
        what: Dropped,
    ) Error![]const u8 {
        return switch (what) {
            .tempo_point => self.labelTempo(tree, source, idx),
            .meter_point => self.label(tree, source, idx, "meter-point", "sig"),
            .cue => self.label(tree, source, idx, "cue", "name"),
        };
    }

    /// The `(timeline …)` head at `span`, re-emitted with `:conductor`
    /// last, just inside the closing paren: `:conductor` is the
    /// canonical printer's final key, so a document that gains one here
    /// reads like one that was printed with it. The head's own span
    /// would put it first, which is valid and ugly.
    fn conductorKey(
        self: *Run,
        out: *std.ArrayList(u8),
        source: []const u8,
        span: Ast.Span,
        anchor_id: []const u8,
    ) Error!void {
        const close = if (span.end > span.start and source[span.end - 1] == ')')
            span.end - 1
        else
            span.end;
        try out.appendSlice(self.arena, source[span.start..close]);
        try out.appendSlice(self.arena, " :conductor ");
        try out.appendSlice(self.arena, anchor_id);
        try out.appendSlice(self.arena, source[close..span.end]);
    }

    /// A document whose essence carried no anchor at all still has to
    /// pair with the file it was dumped from, so one is appended, on a
    /// line of its own, and `tier_at` points after it.
    fn appendAnchor(
        self: *Run,
        out: *std.ArrayList(u8),
        anchor_id: []const u8,
        anchor_kind: []const u8,
    ) Error!void {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(self.arena, '\n');
        }
        try self.anchorForm(out, anchor_id, anchor_kind);
        try out.append(self.arena, '\n');
        self.tier_at = out.items.len;
    }

    /// `residue_stale` for a file that took the baton FROM a document
    /// that had its own time, dropped list or no: a document that
    /// conducted itself and now says `:conductor` is timed by other
    /// numbers than it was, and that is the loss being reported even
    /// when there was no point to drop.
    fn batonTaken(self: *Run, dropped: []const []const u8) Error!void {
        try self.diags.add(
            .residue_stale,
            .warning,
            .{ .start = 0, .end = 0 },
            "the file's tempo, meter or markers were edited after this residue was written, so the file conducts: dropped {s}",
            .{if (dropped.len == 0)
                "nothing — the document had no points or cues of its own, and now takes its time from the file"
            else
                try std.mem.join(self.arena, ", ", dropped)},
        );
    }

    /// The verdicts, in the order the records rode in the file, so the
    /// same bytes always report the same table — one line PER RECORD,
    /// so a lane rendered on two channels shows two.
    ///
    /// A record whose lane the essence does not declare gets NO
    /// verdict: a verdict is a statement about a lane in the document
    /// that came out, and `became_bound` over a lane nobody can find
    /// in the text would be one more contradiction between two
    /// surfaces. The record is still a loss, so it is named.
    ///
    /// The ACTION is the lane's, not the record's: a lane binds when
    /// any of its records is stale, and then every record of it says
    /// `became_bound` — with its own `hash_ok`, which is the fact the
    /// table exists to show. A record that still matched inside a
    /// lane that bound is exactly the untouched channel, and calling
    /// it `restored_native` would have `consumeSmf` take its events
    /// out of the tier the bound lane is about to read.
    fn recordVerdicts(self: *Run, tree: *const Ast.Tree, recs: []const Record) Error!void {
        for (recs) |rec| {
            if (!hasLane(tree, rec.lane)) {
                try self.diags.add(
                    .residue_stale,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "a lane record names {s} at {s}, which the restored essence does not declare; the record is orphaned and was dropped",
                    .{ rec.lane, try self.addressText(rec.address) },
                );
                continue;
            }
            const bound = laneIsStale(recs, rec.lane);
            var hints: []const Hint = &.{};
            if (bound) hints = try self.verifiedHints(rec);
            try self.verdicts.append(self.arena, .{
                .lane = rec.lane,
                .address = rec.address,
                .hash_ok = rec.hash_ok,
                .action = if (bound) .became_bound else .restored_native,
                .hints = hints,
            });
        }
    }

    fn labelTempo(self: *Run, tree: *const Ast.Tree, source: []const u8, idx: NodeIndex) Error![]const u8 {
        // The AUTHORED spelling is among the losses: `:qpm 120` and
        // `:us 500000` are the same tempo and not the same document.
        for ([_][]const u8{ "qpm", "us" }) |key| {
            if (keyLiteral(tree, source, idx, key)) |lit| {
                return std.fmt.allocPrint(self.arena, "tempo-point :{s} {s}", .{ key, lit });
            }
        }
        return self.arena.dupe(u8, "tempo-point");
    }

    fn label(
        self: *Run,
        tree: *const Ast.Tree,
        source: []const u8,
        idx: NodeIndex,
        head: []const u8,
        key: []const u8,
    ) Error![]const u8 {
        const lit = keyLiteral(tree, source, idx, key) orelse return self.arena.dupe(u8, head);
        return std.fmt.allocPrint(self.arena, "{s} :{s} {s}", .{ head, key, lit });
    }

    /// A native lane, rewritten as a BOUND one at its records' address:
    /// its name, kind, target and range kept, its content dropped, and
    /// `residue_stale` naming what that cost.
    ///
    /// `recs` is every record in the file and `name` picks the lane's;
    /// the address written is `laneAddress`'s union of them, so a lane
    /// rendered on two channels and edited on one binds at both. The
    /// caller has already established that at least one is stale.
    fn bindLane(
        self: *Run,
        out: *std.ArrayList(u8),
        tree: *const Ast.Tree,
        source: []const u8,
        idx: NodeIndex,
        recs: []const Record,
        name: []const u8,
        anchor_id: []const u8,
    ) Error!void {
        const address = laneAddress(recs, name) orelse return;
        try self.boundForm(out, tree, source, idx, name, address, anchor_id);
        const loss = lossOf(tree, idx);
        try self.diags.add(
            .residue_stale,
            .warning,
            .{ .start = 0, .end = 0 },
            "lane {s} at {s}: the file's events are not the ones this residue recorded, so the file wins and the lane is bound there; dropped {s}",
            .{ name, try self.addressText(address), try self.lossProse(loss) },
        );
    }

    /// The bound declaration itself — `(lane :name N :kind K [:target T]
    /// :from A <address keys> [:range R])` — onto `out`. The kind, target
    /// and range are the author's own spellings out of `source`; the
    /// address keys are the canonical printer's.
    fn boundForm(
        self: *Run,
        out: *std.ArrayList(u8),
        tree: *const Ast.Tree,
        source: []const u8,
        idx: NodeIndex,
        name: []const u8,
        address: Doc.Address,
        anchor_id: []const u8,
    ) Error!void {
        const kind_text = blk: {
            const v = keyValue(tree, idx, "kind") orelse break :blk "notes";
            break :blk atomText(tree, v) orelse "notes";
        };
        try out.appendSlice(self.arena, "(lane :name ");
        try out.appendSlice(self.arena, name);
        try out.appendSlice(self.arena, " :kind ");
        try out.appendSlice(self.arena, kind_text);
        if (keyLiteral(tree, source, idx, "target")) |t| {
            try out.appendSlice(self.arena, " :target ");
            try out.appendSlice(self.arena, t);
        }
        try out.appendSlice(self.arena, " :from ");
        try out.appendSlice(self.arena, anchor_id);
        try self.addressKeys(out, address);
        if (std.mem.eql(u8, kind_text, "curve")) {
            if (keyLiteral(tree, source, idx, "range")) |r| {
                try out.appendSlice(self.arena, " :range ");
                try out.appendSlice(self.arena, r);
            }
        }
        try out.append(self.arena, ')');
    }

    /// What the lane at `idx` holds that a bound one cannot: its notes,
    /// keyframes and clips counted, and the clips that carried a
    /// `:transpose`. Pure over the tree.
    fn lossOf(tree: *const Ast.Tree, idx: NodeIndex) Loss {
        var loss: Loss = .{};
        for (tree.formHeader(idx).children) |child| {
            if (tree.tagOf(child) != .form) continue;
            const h = tree.formHeader(child);
            if (std.mem.eql(u8, h.head, "note")) loss.notes += 1;
            if (std.mem.eql(u8, h.head, "keyframe")) loss.keyframes += 1;
            if (std.mem.eql(u8, h.head, "clip")) {
                loss.clips += 1;
                if (keyValue(tree, child, "transpose") != null) loss.transposed += 1;
            }
        }
        return loss;
    }

    /// `loss` in the words `residue_stale` prints — `3 notes, 2 clips
    /// and their structure` — or the line for a lane that held nothing.
    /// Into the result's arena.
    fn lossProse(self: *Run, loss: Loss) Error![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        if (loss.notes > 0) {
            try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} notes", .{loss.notes}));
        }
        if (loss.keyframes > 0) try parts.append(self.arena, try std.fmt.allocPrint(
            self.arena,
            "{d} keyframes and their exact values",
            .{loss.keyframes},
        ));
        if (loss.clips > 0) try parts.append(self.arena, try std.fmt.allocPrint(
            self.arena,
            "{d} clips and their structure",
            .{loss.clips},
        ));
        if (loss.transposed > 0) try parts.append(self.arena, try std.fmt.allocPrint(
            self.arena,
            "{d} :transpose",
            .{loss.transposed},
        ));
        if (parts.items.len == 0) return "nothing but the lane's own nativeness";
        return std.mem.join(self.arena, ", ", parts.items);
    }

    fn addressKeys(self: *Run, out: *std.ArrayList(u8), address: Doc.Address) Error!void {
        return addressKeysInto(self.arena, out, address);
    }

    fn addressText(self: *Run, address: Doc.Address) Error![]const u8 {
        return addressProse(self.arena, address);
    }

    fn conductorHash(self: *Run) [32]u8 {
        return self.hasher.conductor();
    }

    fn laneHash(self: *Run, address: Doc.Address) Error![32]u8 {
        return self.hasher.lane(address);
    }

    // ---- a stale curve's easing hints ----

    /// The record's segments that the file's own steps confirm. Each one
    /// they contradict is dropped here with `ease_hint_mismatch`, which
    /// is midi 05's rule and plan 08's: a hint tempura cannot check is a
    /// hint tempura does not apply.
    fn verifiedHints(self: *Run, rec: Record) Error![]const Hint {
        if (rec.segments.len < 2) return &.{};

        const steps = try self.stepTicks(rec.address);
        defer self.gpa.free(steps);

        var kept: std.ArrayList(Hint) = .empty;
        var i: usize = 1;
        while (i < rec.segments.len) : (i += 1) {
            const from = rec.segments[i - 1].at;
            const to = rec.segments[i].at;
            const ease = rec.segments[i].ease;
            if (to <= from) continue;
            if (verifySegment(steps, from, to, ease, self.opts.eps)) {
                try kept.append(self.arena, .{ .from = from, .to = to, .ease = ease });
            } else {
                try self.diags.add(
                    .ease_hint_mismatch,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "lane {s}: the file's steps between ticks {d} and {d} are not {s} within {d} — the hint is dropped and the steps win",
                    .{ rec.lane, from, to, ease, self.opts.eps },
                );
            }
        }
        return kept.items;
    }

    /// The file's own steps at a curve address, in TEMPURA ticks. The
    /// caller frees.
    fn stepTicks(self: *Run, address: Doc.Address) Error![]Step {
        switch (self.file.tier) {
            .smf => |seq| {
                const s = switch (address) {
                    .smf => |x| x,
                    .it => return self.gpa.alloc(Step, 0),
                };
                const curve = s.curve orelse return self.gpa.alloc(Step, 0);
                const raw = try bridge_smf.curveSteps(self.gpa, seq, s.track, s.ch, curve);
                defer self.gpa.free(raw);
                const ppq = seq.division.pulsesPerQuarter();
                const out = try self.gpa.alloc(Step, raw.len);
                for (raw, out) |src, *dst| dst.* = .{
                    .at = Grid.smfToTicks(src.at, ppq).tick,
                    .value = src.value,
                };
                return out;
            },
            .it => |m| {
                const s = switch (address) {
                    .it => |x| x,
                    .smf => return self.gpa.alloc(Step, 0),
                };
                const column = s.column orelse return self.gpa.alloc(Step, 0);
                const rows = try self.rowmap();
                const raw = try bridge_it.curveSteps(self.gpa, m, rows, s.channel, column, s.fx);
                defer self.gpa.free(raw);
                const out = try self.gpa.alloc(Step, raw.len);
                for (raw, out) |src, *dst| dst.* = .{
                    .at = src.at *| Grid.IT_TICK,
                    .value = src.value,
                };
                return out;
            },
        }
    }
};

/// The binding keys of `address`, spelled exactly as the canonical
/// printer spells them (`doc/toSjon.zig`'s `binding`).
///
/// The two spellings MUST agree: a bound lane this writes is read back
/// and re-printed by `toSjon`, and a disagreement would make a dump
/// non-idempotent — dump, print, dump again and the text moves. A test
/// at the bottom of this file loads what this produces and compares the
/// printer's own output with it, address shape by address shape.
pub fn addressKeysInto(gpa: Allocator, out: *std.ArrayList(u8), address: Doc.Address) Error!void {
    switch (address) {
        .smf => |s| {
            try out.print(gpa, " :track {d} :ch ", .{s.track});
            try channelsInto(gpa, out, s.ch, "[", " ", "]");
            if (s.key) |k| try out.print(gpa, " :key {d}", .{k});
            if (s.curve) |c| switch (c) {
                .cc => |n| try out.print(gpa, " :cc {d}", .{n}),
                .cc14 => |pair| try out.print(gpa, " :cc [{d} {d}]", .{ pair[0], pair[1] }),
                .bend => try out.appendSlice(gpa, " :bend true"),
                .pressure => try out.appendSlice(gpa, " :pressure true"),
                .velocity => try out.appendSlice(gpa, " :velocity true"),
            };
        },
        .it => |s| {
            try out.print(gpa, " :channel {d}", .{@as(u8, s.channel) + 1});
            if (s.column) |col| {
                try out.appendSlice(gpa, " :column ");
                try out.appendSlice(gpa, @tagName(col));
            }
            if (s.fx) |letter| try out.print(gpa, " :fx \"{c}\"", .{letter});
        },
    }
}

/// The address as a diagnostic says it — the same facts `addressKeys`
/// spells as document keys, in prose, because a warning is read by a
/// person and `:track 2 :ch 1` in the middle of a sentence is not.
/// `check-residue`'s table reads it too.
///
/// The slice is `arena`'s and is never freed on its own: pass an ARENA
/// (the result's, or a scratch one the caller drops whole). It is an
/// `ArrayList`'s `items`, so `free` on it is wrong whenever the list
/// over-allocated.
pub fn addressProse(arena: Allocator, address: Doc.Address) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    switch (address) {
        .smf => |s| {
            // A set reads `ch 1,2` — the channels, and nothing that could
            // be taken for arithmetic between them.
            try out.print(arena, "track {d} ch ", .{s.track});
            try channelsInto(arena, &out, s.ch, "", ",", "");
            if (s.key) |k| try out.print(arena, " key {d}", .{k});
            if (s.curve) |c| switch (c) {
                .cc => |n| try out.print(arena, " cc {d}", .{n}),
                .cc14 => |pair| try out.print(arena, " cc {d}+{d}", .{ pair[0], pair[1] }),
                .bend => try out.appendSlice(arena, " bend"),
                .pressure => try out.appendSlice(arena, " pressure"),
                .velocity => try out.appendSlice(arena, " velocity"),
            };
        },
        .it => |s| {
            try out.print(arena, "channel {d}", .{@as(u8, s.channel) + 1});
            if (s.column) |col| try out.print(arena, " column {s}", .{@tagName(col)});
            if (s.fx) |letter| try out.print(arena, " fx {c}", .{letter});
        },
    }
    return out.items;
}

/// A channel set, 1-based, into `out`: the number alone for a single,
/// or `open`, the channels ascending with `sep` between them, and
/// `close` for several — `[1 2]` as a document key, `1,2` in prose.
fn channelsInto(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    chs: Doc.Channels,
    open: []const u8,
    sep: []const u8,
    close: []const u8,
) Error!void {
    if (chs.count() == 1) return out.print(gpa, "{d}", .{@as(u8, chs.first()) + 1});
    try out.appendSlice(gpa, open);
    var it = chs.iterator();
    var first = true;
    while (it.next()) |c| {
        if (!first) try out.appendSlice(gpa, sep);
        first = false;
        try out.print(gpa, "{d}", .{@as(u8, c) + 1});
    }
    try out.appendSlice(gpa, close);
}

// ---------------------------------------------------------------------
// The consumption
// ---------------------------------------------------------------------

/// What a dump takes OUT of the file's tier once rule 2 has run.
///
/// Plan 04, "One home": a native lane's rendered events are a VIEW and
/// the essence is the truth, and rule 2 says that when a lane record's
/// hash matches, "the lane is restored as native from the essence, and
/// its address is consumed", and that when the conductor record matches,
/// "the file's tempo events are marked consumed". Until now "consumed"
/// meant only "not imported as a bound lane": the events stayed in the
/// `midi/` or `it/` tier, and a `build` of the dumped document rendered
/// the lane INTO a base that still held its previous rendering — every
/// note twice, and again on the next rebuild. So the two functions below
/// take the view out of the tier value the pipeline is about to print,
/// leaving the document with one home for everything: the anchor's own
/// content in the tier, the native lanes in the timeline, and nothing in
/// both. A rebuild then renders each lane once, into the track or the
/// channel a dump left empty for it (`export/render_smf.zig`, "Into an
/// anchor"; `export/render_it.zig`, the channel above the highest used).
///
/// The scope is exactly the hash's: a lane's address is its channel's
/// events on its track (`records.hashSmfLane`) or its channel's cells in
/// the played patterns (`records.hashItLane`); the conductor's is what
/// `render_smf`'s `conductorTrack` writes — `set-tempo`, `time-signature`
/// and `marker` — and, in a module, the `Txx` cells `render_it`'s
/// `conductorCells` placed. A `cue-point` stays: tempura never writes one
/// and a rebuild would not put it back. A track that loses its events
/// keeps its `sequence-name`, so the tier's track numbers — which every
/// stale lane's `:track` names — do not move; the renderer reads that
/// empty named track as the lane's own and renders onto it.
///
/// Nothing is taken under any other rule: a skeleton's lanes are bound
/// and READ the tier, and a tail restores no content to duplicate.
pub const Consumed = struct {
    /// SMF channel events removed at restored lanes' addresses.
    events: usize = 0,
    /// IT cells cleared on restored lanes' channels.
    cells: usize = 0,
    /// Conductor events removed (`.mid`) or `Txx` effects cleared (`.it`).
    conductor: usize = 0,
    /// The IT patterns a cell changed in, ascending — what a
    /// `--patterns=bin` dump has to print as rows after all, because a
    /// `(bin :at :len)` region of the file cannot lose a cell.
    patterns: []const u16 = &.{},

    pub fn any(self: Consumed) bool {
        return self.events + self.cells + self.conductor > 0;
    }
};

/// Rule 2's consumption over a `.mid`, in place: `seq` is the sequence
/// the tier will be printed from, with the residue already detached.
pub fn consumeSmf(seq: *Sequence.Sequence, result: *const Result) Consumed {
    var out: Consumed = .{};
    if (result.rule != .restored) return out;

    for (result.verdicts) |v| {
        // `became_bound` is the LANE's verdict, so a record whose own
        // hash still matched inside a lane that bound is skipped here
        // with the rest of its lane: the bound lane reads that channel.
        if (v.action != .restored_native) continue;
        const s = switch (v.address) {
            .smf => |x| x,
            .it => continue,
        };
        const ti: usize = if (s.track == 0) 0 else s.track - 1;
        if (ti >= seq.tracks.len) continue;
        // A verdict's address is a record's, which names one channel;
        // the walk is over the set all the same, so a verdict that ever
        // carried several would consume them all.
        var chs = s.ch.iterator();
        while (chs.next()) |ch| out.events += dropChannel(&seq.tracks[ti], ch);
    }

    if (result.conductor) |c| {
        if (c.hash_ok) for (seq.tracks) |*t| {
            out.conductor += dropConductor(t);
        };
    }
    return out;
}

/// Every event on `ch`, out of the track — the lane hash's own scope.
fn dropChannel(track: *Sequence.Track, ch: u4) usize {
    var n: usize = 0;
    for (track.events) |e| {
        if (records.channelOf(e) == ch) continue;
        track.events[n] = e;
        n += 1;
    }
    const dropped = track.events.len - n;
    track.events = track.events[0..n];
    return dropped;
}

/// The events `render_smf`'s conductor track writes, out of the track.
fn dropConductor(track: *Sequence.Track) usize {
    var n: usize = 0;
    for (track.events) |e| {
        switch (e.kind) {
            .set_tempo, .time_signature, .marker => continue,
            else => {},
        }
        track.events[n] = e;
        n += 1;
    }
    const dropped = track.events.len - n;
    track.events = track.events[0..n];
    return dropped;
}

/// ITTECH's `Txx`, the one conductor effect `render_it` writes.
const fx_t: u8 = 'T' - '@';

/// Rule 2's consumption over a `.it`, in place: `module` is the one the
/// tier will be printed from. `arena` owns the returned pattern list,
/// an `ArrayList`'s `items` that is never freed on its own.
pub fn consumeIt(arena: Allocator, module: *itf.Module, result: *const Result) Error!Consumed {
    var out: Consumed = .{};
    if (result.rule != .restored) return out;
    var touched: std.ArrayList(u16) = .empty;

    for (result.verdicts) |v| {
        if (v.action != .restored_native) continue;
        const s = switch (v.address) {
            .it => |x| x,
            .smf => continue,
        };
        for (result.played) |pi| {
            if (pi >= module.patterns.len) continue;
            const p = module.patterns[pi];
            if (p.cells.len < @as(usize, p.rows) * itf.model.channels) continue;
            var cleared: usize = 0;
            var row: usize = 0;
            while (row < p.rows) : (row += 1) {
                const cell = &p.cells[row * itf.model.channels + s.channel];
                if (cell.isEmpty()) continue;
                cell.* = .empty;
                cleared += 1;
            }
            if (cleared > 0) {
                out.cells += cleared;
                try touch(arena, &touched, pi);
            }
        }
    }

    if (result.conductor) |c| {
        if (c.hash_ok) for (module.patterns, 0..) |p, pi| {
            if (p.cells.len < @as(usize, p.rows) * itf.model.channels) continue;
            var cleared: usize = 0;
            for (p.cells) |*cell| {
                if (cell.fx != fx_t) continue;
                cell.fx = 0;
                cell.param = 0;
                cleared += 1;
            }
            if (cleared > 0) {
                out.conductor += cleared;
                try touch(arena, &touched, @intCast(pi));
            }
        };
    }

    out.patterns = touched.items;
    return out;
}

/// `pi` into the ascending, deduplicated list. `gpa` is the list's own.
fn touch(gpa: Allocator, list: *std.ArrayList(u16), pi: u16) Error!void {
    var i: usize = 0;
    while (i < list.items.len and list.items[i] < pi) : (i += 1) {}
    if (i < list.items.len and list.items[i] == pi) return;
    try list.insert(gpa, i, pi);
}

/// The four hashes over one file, as it reads NOW.
///
/// Its own type because `check-residue` asks exactly the same question
/// as `reconcile` and must answer it the same way (plan 10's verdict
/// table is the reconciliation's, shown rather than applied), and
/// because the IT walk behind `hashItLane` is worth doing once per file
/// rather than once per lane.
///
/// The address convention is the one a BUILD has to share: for a `.mid`
/// the whole `(track, ch)` pair, for a `.it` the record's channel over
/// every pattern the walk played, ascending and deduplicated
/// (`playedPatterns`).
pub const Hasher = struct {
    gpa: Allocator,
    tier: Tier,
    /// The IT timing walk, derived on first ask. A `.mid` gets an empty
    /// map rather than a null, so every caller stays total.
    rows: ?walk.RowMap = null,
    /// Scratch for the pattern list a lane hash needs, freed whole.
    scratch: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, tier: Tier) Hasher {
        return .{ .gpa = gpa, .tier = tier, .scratch = .init(gpa) };
    }

    pub fn deinit(self: *Hasher) void {
        if (self.rows) |*r| r.deinit();
        self.scratch.deinit();
        self.* = undefined;
    }

    pub fn rowmap(self: *Hasher) Error!*const walk.RowMap {
        if (self.rows == null) {
            self.rows = switch (self.tier) {
                .it => |m| try walk.derive(self.gpa, m, .{}),
                .smf => .{ .arena = .init(self.gpa), .diags = .init(self.gpa) },
            };
        }
        return &self.rows.?;
    }

    /// The file's whole timing context.
    pub fn conductor(self: *Hasher) [32]u8 {
        return switch (self.tier) {
            .smf => |seq| records.hashSmfConductor(seq),
            .it => |m| records.hashItConductor(m),
        };
    }

    /// The file's events at `address`. An address of the other kind
    /// hashes to zero — it can never match a record, which is the right
    /// verdict for a record that names a `.it` channel in a `.mid`.
    pub fn lane(self: *Hasher, address: Doc.Address) Error![32]u8 {
        switch (self.tier) {
            .smf => |seq| {
                const s = switch (address) {
                    .smf => |x| x,
                    .it => return @splat(0),
                };
                const track: u32 = if (s.track == 0) 0 else s.track - 1;
                return records.hashSmfLane(seq, track, s.ch.first(), seq.division.pulsesPerQuarter());
            },
            .it => |m| {
                const s = switch (address) {
                    .it => |x| x,
                    .smf => return @splat(0),
                };
                const rows = try self.rowmap();
                const patterns = try playedPatterns(self.scratch.allocator(), rows);
                return records.hashItLane(m, rows, &[_]u8{s.channel}, patterns);
            },
        }
    }
};

/// The comment a derived document opens with, by the rule that derived it.
fn headerFor(rule: Rule) []const u8 {
    return switch (rule) {
        // `.restored` cannot reach here — only `derive` asks for a
        // header, and `derive` never sets it — but the switch is total
        // rather than `unreachable`, and rule 1's line is the honest
        // fallback if a later rule ever does derive after restoring.
        .derived, .restored => header_skeleton,
        .version => header_version,
        .corrupt => header_corrupt,
        .partial => header_partial,
    };
}

/// One byte past the newline that ends the first `(anchor …)` line, or
/// null when the text holds no anchor at all.
///
/// The canonical printer emits an anchor on ONE line and leaves the
/// inline dump's place directly after it, because plan 02's anchor/dump
/// pairing is positional.
fn anchorLineEnd(text: []const u8) ?usize {
    var at: usize = 0;
    while (at < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        if (std.mem.startsWith(u8, text[at..], "(anchor ")) {
            return @min(nl + 1, text.len);
        }
        at = nl + 1;
    }
    return null;
}

/// SHA-256 as 64 lower-case hex digits — the `:sha256` spelling
/// `doc/Resolver.zig` parses back.
fn hexDigest(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

// ---------------------------------------------------------------------
// Rule 2: the essence restored, hash by hash
// ---------------------------------------------------------------------

/// Who keeps time in the document that comes out.
const Conducting = enum {
    /// The document does, as it did when it was built: its own
    /// `tempo-point`s, `meter-point`s and `cue`s are restored and it
    /// gains no `:conductor` (rule 2 with the conductor hash matching,
    /// or with no conductor record at all).
    document,
    /// The FILE does, and it TOOK the baton: someone edited the tempo,
    /// the meter or a marker after the residue was written, so
    /// `:conductor` is set, the document's own points and cues are
    /// dropped and `residue_stale` names them (rule 2, mismatch).
    file_wins,
    /// The file does, and there was never a contest: the message tail
    /// carries no `tempo-point`s by construction (plan 04, "The IT
    /// carriers": the addressed summary, no native content), so the
    /// restored shape has no time of its own and `:conductor` is the
    /// only honest answer. Nothing is dropped and nothing is named —
    /// `residue_partial` has already said what the tail lacks, and a
    /// document with neither points nor a conductor would not even
    /// re-read (`tempo_map_invalid`).
    file_only,
};

/// One lane record, decoded into the result's arena and answered.
const Record = struct {
    lane: []const u8,
    address: Doc.Address,
    /// What the record says the file held when it was written.
    hash: [32]u8,
    /// Whether the file's events at `address` still hash to it.
    hash_ok: bool,
    segments: []const records.Segment,
};

/// What a stale lane's exact content cost, in the words `residue_stale`
/// prints.
const Loss = struct {
    notes: usize = 0,
    keyframes: usize = 0,
    clips: usize = 0,
    transposed: usize = 0,
};

fn isForm(tree: *const Ast.Tree, idx: NodeIndex, head: []const u8) bool {
    if (tree.tagOf(idx) != .form) return false;
    const h = tree.formHeader(idx);
    if (!std.mem.eql(u8, h.head, head)) return false;
    if (h.namespace) |ns| return std.mem.eql(u8, ns, "tempura");
    return true;
}

/// The value node of `(… :key value …)`, or null.
fn keyValue(tree: *const Ast.Tree, form: NodeIndex, key: []const u8) ?NodeIndex {
    if (tree.tagOf(form) != .form) return null;
    for (tree.formHeader(form).children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

/// The text of a symbol or a string node — the two spellings a name can
/// take.
fn atomText(tree: *const Ast.Tree, idx: NodeIndex) ?[]const u8 {
    return switch (tree.tagOf(idx)) {
        .symbol => tree.symbolText(idx),
        .string => tree.stringText(idx),
        else => null,
    };
}

/// A key's value exactly as the author spelled it — the source slice, so
/// `:qpm 120.5` and `:us 400000` come back as themselves.
fn keyLiteral(tree: *const Ast.Tree, source: []const u8, form: NodeIndex, key: []const u8) ?[]const u8 {
    const v = keyValue(tree, form, key) orelse return null;
    const span = tree.spanOf(v);
    if (span.end > source.len or span.start > span.end) return null;
    return source[span.start..span.end];
}

// ---------------------------------------------------------------------
// The pieces the rules are made of
// ---------------------------------------------------------------------

/// One value a file's controller surface reached, at its TEMPURA tick.
const Step = struct {
    at: i64,
    value: f32,
};

/// Does the restored text declare a lane called `name`?
fn hasLane(tree: *const Ast.Tree, name: []const u8) bool {
    for (tree.root) |idx| {
        if (!isForm(tree, idx, "lane")) continue;
        const v = keyValue(tree, idx, "name") orelse continue;
        const text = atomText(tree, v) orelse continue;
        if (std.mem.eql(u8, text, name)) return true;
    }
    return false;
}

/// Whether ANY record of the lane called `name` no longer matches — the
/// one verdict that rewrites a lane. A `.mid` lane whose notes named
/// several channels has several records, one per channel, and it is one
/// lane: a DAW edit to any of its channels binds the whole of it.
fn laneIsStale(recs: []const Record, name: []const u8) bool {
    for (recs) |r| {
        if (!r.hash_ok and std.mem.eql(u8, r.lane, name)) return true;
    }
    return false;
}

/// The address the lane called `name` binds at: the first record's
/// track, key and curve, with the UNION of every channel the lane's
/// records name — `:ch [1 2]` for a lane rendered on two channels —
/// so that the channel nobody edited is read by the lane rather than
/// left in the tier belonging to nothing. Null for a name no record
/// carries.
///
/// A lane's records all name one track and one shape by construction
/// (`export/render_smf.zig` writes them from one `notesLane` call), so
/// the first record's track and shape are the lane's; a record that
/// disagreed would be a torn residue, and its channel still joins the
/// set rather than being lost.
fn laneAddress(recs: []const Record, name: []const u8) ?Doc.Address {
    var found: ?Doc.Address = null;
    for (recs) |r| {
        if (!std.mem.eql(u8, r.lane, name)) continue;
        if (found) |*have| {
            switch (have.*) {
                .smf => |*s| switch (r.address) {
                    .smf => |o| s.ch = s.ch.merge(o.ch),
                    .it => {},
                },
                .it => {},
            }
        } else found = r.address;
    }
    return found;
}

/// Every pattern the walk played, ascending and deduplicated.
///
/// A lane record's encoded address carries a channel and no pattern set,
/// so a reader has to reproduce the writer's choice from the module
/// itself, and this is that choice: the patterns that SOUND, in the one
/// order two implementations can agree on (plan 04's open question,
/// "Hash scope for IT rendered lanes", answered here and restated in
/// `docs/residue.md` at E3).
///
/// The slice is `arena`'s and is never freed on its own: pass an ARENA.
/// It is an `ArrayList`'s `items` and its capacity may exceed its
/// length, so `free` on it is wrong.
pub fn playedPatterns(arena: Allocator, rows: *const walk.RowMap) Error![]u16 {
    var seen: std.ArrayList(u16) = .empty;
    for (rows.rows) |row| {
        if (std.mem.indexOfScalar(u16, seen.items, row.pattern) != null) continue;
        try seen.append(arena, row.pattern);
    }
    std.mem.sort(u16, seen.items, {}, std.sort.asc(u16));
    return seen.items;
}

/// A bound lane's address as the tail (or any document) spells it.
fn addressOf(tree: *const Ast.Tree, form: NodeIndex, kind: Doc.AnchorKind) ?Doc.Address {
    switch (kind) {
        .smf => {
            const track: u16 = @intCast(@max(1, intValue(tree, form, "track") orelse 1));
            // `:ch 2`, or `:ch [1 2]` — the set the tail (which prints
            // through `residue/it.zig`'s `Tailer`, the printer's own
            // spelling) wrote for a lane bound at several channels.
            var ch: Doc.Channels = .none;
            if (keyValue(tree, form, "ch")) |v| {
                if (tree.tagOf(v) == .vector) {
                    for (tree.vectorElements(v)) |e| {
                        const c_1 = numberOf(tree, e) orelse continue;
                        ch = ch.with(@intCast(@min(15, @max(0, c_1 - 1))));
                    }
                } else if (numberOf(tree, v)) |c_1| {
                    ch = .single(@intCast(@min(15, @max(0, c_1 - 1))));
                }
            }
            if (ch.isEmpty()) ch = .single(0);
            const key: ?u7 = if (intValue(tree, form, "key")) |k|
                @intCast(@min(127, @max(0, k)))
            else
                null;
            var curve: ?Doc.SmfCurve = null;
            if (intValue(tree, form, "cc")) |n| {
                curve = .{ .cc = @intCast(@min(127, @max(0, n))) };
            } else if (keyValue(tree, form, "cc")) |v| {
                if (tree.tagOf(v) == .vector) {
                    const els = tree.vectorElements(v);
                    if (els.len == 2) {
                        const msb = numberOf(tree, els[0]) orelse 0;
                        const lsb = numberOf(tree, els[1]) orelse 0;
                        curve = .{ .cc14 = .{
                            @intCast(@min(127, @max(0, msb))),
                            @intCast(@min(127, @max(0, lsb))),
                        } };
                    }
                }
            } else if (boolValue(tree, form, "bend")) {
                curve = .bend;
            } else if (boolValue(tree, form, "pressure")) {
                curve = .pressure;
            } else if (boolValue(tree, form, "velocity")) {
                curve = .velocity;
            }
            return .{ .smf = .{ .track = track, .ch = ch, .key = key, .curve = curve } };
        },
        .it => {
            const ch_1 = intValue(tree, form, "channel") orelse 1;
            const channel: u6 = @intCast(@min(63, @max(0, ch_1 - 1)));
            var column: ?Doc.ItColumn = null;
            if (keyValue(tree, form, "column")) |v| {
                if (atomText(tree, v)) |t| {
                    column = std.meta.stringToEnum(Doc.ItColumn, t);
                }
            }
            var fx: ?u8 = null;
            if (keyValue(tree, form, "fx")) |v| {
                if (atomText(tree, v)) |t| {
                    if (t.len == 1) fx = t[0];
                }
            }
            return .{ .it = .{ .channel = channel, .column = column, .fx = fx } };
        },
    }
}

fn numberOf(tree: *const Ast.Tree, idx: NodeIndex) ?i64 {
    return switch (tree.tagOf(idx)) {
        .number_i64 => tree.numberI64Of(idx),
        .number, .number_u64 => intFrom(tree.numberOf(idx)),
        else => null,
    };
}

/// An `f64` back to a tick, saturating — an address key that is not a
/// whole small number is not an address, and `@intFromFloat` on one
/// would be undefined behaviour rather than a refusal.
fn intFrom(x: f64) ?i64 {
    if (!(x >= -9.2e18 and x <= 9.2e18)) return null;
    return @intFromFloat(x);
}

fn intValue(tree: *const Ast.Tree, form: NodeIndex, key: []const u8) ?i64 {
    return numberOf(tree, keyValue(tree, form, key) orelse return null);
}

fn boolValue(tree: *const Ast.Tree, form: NodeIndex, key: []const u8) bool {
    const v = keyValue(tree, form, key) orelse return false;
    return tree.tagOf(v) == .boolean_true;
}

/// Whether every step strictly inside `[from, to]` lies within `eps` of
/// `ease` drawn between the two endpoints' values.
///
/// A segment with fewer than three steps in it has nothing that could
/// contradict a named curve — two points are on every curve through
/// them — so its hint is kept. The rest is `export/lanes.zig`'s `verify`
/// over a single component; the two want one home once `src/export/`
/// settles, and the report records the ask.
fn verifySegment(steps: []const Step, from: i64, to: i64, ease: []const u8, eps: f32) bool {
    var first: ?usize = null;
    var last: usize = 0;
    for (steps, 0..) |s, i| {
        if (s.at < from) continue;
        if (s.at > to) break;
        if (first == null) first = i;
        last = i;
    }
    const start = first orelse return true;
    if (last < start + 2) return true;

    // An unevaluable easing never verifies: a hint tempura cannot check
    // is a hint tempura does not apply (plan 08).
    if (easeAt(ease, 0.5) == null) return false;

    const span: f64 = @floatFromInt(steps[last].at - steps[start].at);
    if (span <= 0) return false;
    const lo: f64 = steps[start].value;
    const hi: f64 = steps[last].value;

    var i = start + 1;
    while (i < last) : (i += 1) {
        const u = @as(f64, @floatFromInt(steps[i].at - steps[start].at)) / span;
        const shaped = easeAt(ease, u) orelse return false;
        const want = lo + (hi - lo) * shaped;
        if (@abs(want - @as(f64, steps[i].value)) > @as(f64, eps)) return false;
    }
    return true;
}

/// pacer's twelve POLYNOMIAL easing primitives, reproduced from
/// `pacer/src/Easing.zig`'s `evalOp` expression for expression — null
/// for every easing this cannot evaluate exactly (the sine and expo
/// primitives, which need a transcendental plan 00 forbids in a value
/// path, and every combinator form, which needs pacer's own compiler).
///
/// A second copy of `export/lanes.zig`'s `easeAt`, and it has to stay
/// one: `export/lanes.zig` imports `doc/doc.zig`, `doc/doc.zig` exports
/// `doc/pipeline.zig`, and `doc/pipeline.zig` imports THIS file — so an
/// import here would close a four-file cycle. The two are
/// expression-identical; a shared home below both (a `src/Easing.zig`
/// beside `src/Diag.zig`) is the ask recorded with this task.
fn easeAt(ease: []const u8, u: f64) ?f64 {
    const p1 = 1.0 - u;
    if (std.mem.eql(u8, ease, "linear")) return u;
    if (std.mem.eql(u8, ease, "hold")) return if (u >= 1) 1.0 else 0.0;
    if (std.mem.eql(u8, ease, "smoothstep")) return u * u * (3.0 - 2.0 * u);
    if (std.mem.eql(u8, ease, "in-quad")) return u * u;
    if (std.mem.eql(u8, ease, "out-quad")) return 1.0 - p1 * p1;
    if (std.mem.eql(u8, ease, "in-out-quad"))
        return if (u < 0.5) 2.0 * u * u else 1.0 - (2.0 * p1) * (2.0 * p1) / 2.0;
    if (std.mem.eql(u8, ease, "in-cubic")) return u * u * u;
    if (std.mem.eql(u8, ease, "out-cubic")) return 1.0 - p1 * p1 * p1;
    if (std.mem.eql(u8, ease, "in-out-cubic"))
        return if (u < 0.5) 4.0 * u * u * u else 1.0 - (2.0 * p1) * (2.0 * p1) * (2.0 * p1) / 2.0;
    if (std.mem.eql(u8, ease, "in-quart")) return u * u * u * u;
    if (std.mem.eql(u8, ease, "out-quart")) return 1.0 - p1 * p1 * p1 * p1;
    if (std.mem.eql(u8, ease, "in-out-quart"))
        return if (u < 0.5)
            8.0 * u * u * u * u
        else
            1.0 - (2.0 * p1) * (2.0 * p1) * (2.0 * p1) * (2.0 * p1) / 2.0;
    return null;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const smf_read = @import("../smf/read.zig");
const smf_write = @import("../smf/write.zig");
const itf_read = @import("../itf/read.zig");
const itf_write = @import("../itf/write.zig");
const carrier_smf = @import("smf.zig");
const carrier_it = @import("it.zig");

const q = Grid.TPQ;

/// The document the author wrote, comments and all. Two NATIVE lanes —
/// no `:from` — so both are rendered into the file and both get a lane
/// record; one `tempo-point`, one `meter-point` and one `cue`, so the
/// conductor's verdict has something to drop.
const smf_source: [:0]const u8 =
    \\; the author's own note, which the essence keeps
    \\(timeline :title "residue" :length 2bar)
    \\
    \\(anchor :id song :kind smf :file "song.mid" :size 1 :sha256 "9f2a")
    \\
    \\; the tempo the author set, which goes with the point it annotates
    \\(tempo-point :at 0bar :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(cue :name "intro" :at 0bar)
    \\
    \\; the kick, as the author wrote it
    \\(lane :name kick :kind notes :target drums
    \\  (note :at 0bar :dur 1q :key 36 :vel 100)
    \\  (note :at 1q :dur 1q :key 36 :vel 90))
    \\
    \\(lane :name cutoff :kind curve :range [0 1]
    \\  (keyframe :at 0bar :value 0)
    \\  (keyframe :at 1q :value 0.5 :ease in-cubic)
    \\  (keyframe :at 2q :value 1))
    \\
;

/// The same piece with no points and no cues of its own — the second
/// shape of a conductor mismatch, where there is nothing to drop and
/// the handover is the whole loss.
const smf_bare: [:0]const u8 =
    \\; bare
    \\(timeline :title "bare")
    \\
    \\(anchor :id song :kind smf :file "song.mid" :size 1 :sha256 "9f2a")
    \\
    \\(lane :name kick :kind notes
    \\  (note :at 0bar :dur 1q :key 36 :vel 100))
    \\
    \\(lane :name cutoff :kind curve :range [0 1]
    \\  (keyframe :at 0bar :value 0))
    \\
;

/// What a DAW may have done to the file after tempura wrote it. Every
/// field is one of plan 04 phase 2's reds.
const Edit = struct {
    /// The kick's first velocity — a lane edit on channel 1.
    vel: u7 = 100,
    /// The conductor's tempo.
    tempo: u32 = 500_000,
    /// The conductor's marker text.
    marker: []const u8 = "intro",
    /// The header's division, under UNCHANGED ticks: every event moves.
    ppq: u15 = 96,
    /// The cutoff's value at tick 48 — the one that makes the first
    /// segment stop being `in-cubic`.
    cc48: u8 = 8,
};

/// The music tempura rendered `smf_source` into: a conductor track, and
/// one track carrying the kick on channel 1 and the cutoff's CC steps on
/// channel 2.
///
/// The cutoff's steps are EXACTLY `in-cubic` from 0 to 64 over the first
/// quarter (`64·u³` is 1, 8 and 27 at the quarter points) and linear from
/// 64 to 127 over the second, so a hint over either verifies and an edit
/// to one leaves the other alone.
fn smfFile(gpa: Allocator, e: Edit) !Sequence.Sequence {
    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = e.ppq };

    const t0 = try b.addTrack();
    try b.addEvent(t0, 0, .set_tempo, .{ .tempo = e.tempo });
    try b.addEvent(t0, 0, .time_signature, .{ .time_sig = .{ .nn = 4, .dd = 2, .cc = 24, .bb = 8 } });
    try b.addEvent(t0, 0, .marker, .{ .bytes = try b.addBytes(e.marker) });
    // Off the origin, and deliberately: tick 0 maps to tempura tick 0
    // under EVERY division, so a conductor whose events all sit there
    // hashes the same after a `division` change under unchanged ticks
    // (`records.zig`'s stated blind spot). One event past the origin is
    // what makes the division part of the question.
    try b.addEvent(t0, 192, .cue_point, .{ .bytes = try b.addBytes("bar 2") });
    try b.addEvent(t0, 384, .end_of_track, .empty);

    const t1 = try b.addTrack();
    try b.addEvent(t1, 0, .note_on, .{ .note = .{ .ch = 0, .key = 36, .vel = e.vel } });
    try b.addEvent(t1, 96, .note_off, .{ .note = .{ .ch = 0, .key = 36, .vel = 64 } });
    try b.addEvent(t1, 96, .note_on, .{ .note = .{ .ch = 0, .key = 36, .vel = 90 } });
    try b.addEvent(t1, 192, .note_off, .{ .note = .{ .ch = 0, .key = 36, .vel = 64 } });

    const steps = [_][2]u16{
        .{ 0, 0 },    .{ 24, 1 },   .{ 48, e.cc48 }, .{ 72, 27 },   .{ 96, 64 },
        .{ 120, 80 }, .{ 144, 96 }, .{ 168, 112 },   .{ 192, 127 },
    };
    for (steps) |s| try b.addEvent(t1, s[0], .control_change, .{
        .control = .{ .ch = 1, .num = 74, .val = @intCast(s[1]) },
    });
    try b.addEvent(t1, 384, .end_of_track, .empty);

    return b.finish();
}

/// One built-and-read `.mid`: the bytes, the sequence the residue came
/// out of, the tier text for it, and what the carrier held.
const SmfCase = struct {
    gpa: Allocator,
    bytes: []u8,
    file: smf_read.Result,
    detached: carrier_smf.Detached,
    text: []u8,

    fn deinit(self: *SmfCase) void {
        self.gpa.free(self.text);
        self.detached.deinit();
        self.file.deinit();
        self.gpa.free(self.bytes);
    }

    fn found(self: *const SmfCase) Found {
        return .{ .payloads = self.detached.payloads };
    }

    fn input(self: *const SmfCase) File {
        return .{
            .tier = .{ .smf = &self.detached.sequence },
            .text = self.text,
            .bytes = self.bytes,
            .name = "song.mid",
        };
    }
};

/// What goes into the carrier. `null` for a record means "do not write
/// one", which is how the no-residue and partial cases are built.
const SmfCarry = struct {
    /// The document the essence is packed from.
    source: [:0]const u8 = smf_source,
    /// The name the kick's RECORD carries. A name the essence does not
    /// declare makes that record an orphan.
    kick_name: []const u8 = "kick",
    /// The edit the file carries when the RECORDS were computed. The
    /// default is no edit at all: the residue and the music agree.
    written: Edit = .{},
    /// The edit the file carries when it is read back — a DAW's.
    read_as: Edit = .{},
    essence: bool = true,
    conductor: bool = true,
    lanes: bool = true,
    /// Damage the essence body after it is packed (rule 4).
    corrupt_essence: bool = false,
    /// Write the payloads under an envelope version this build does not
    /// read (rule 3).
    ver: u8 = records.version,
};

/// Build a `.mid` the way `build` would, then read it back the way `dump`
/// does: attach → write → read → detach → the bridge's tier text.
fn smfCase(gpa: Allocator, carry: SmfCarry) !SmfCase {
    var written = try smfFile(gpa, carry.written);
    defer written.deinit();

    const kick = try records.encodeLane(gpa, .{
        .lane = carry.kick_name,
        .address = .{ .smf = .{ .track = 2, .ch = .single(0), .key = 36, .curve = null } },
        .hash = records.hashSmfLane(&written, 1, 0, carry.written.ppq),
    });
    defer gpa.free(kick);

    var segments = [_]records.Segment{
        .{ .at = 0, .ease = "linear" },
        .{ .at = q, .ease = "in-cubic" },
        .{ .at = 2 * q, .ease = "linear" },
    };
    const cutoff = try records.encodeLane(gpa, .{
        .lane = "cutoff",
        .address = .{ .smf = .{ .track = 2, .ch = .single(1), .key = null, .curve = .{ .cc = 74 } } },
        .hash = records.hashSmfLane(&written, 1, 1, carry.written.ppq),
        .steps_only = &segments,
    });
    defer gpa.free(cutoff);

    const conductor = records.encodeConductor(.{ .hash = records.hashSmfConductor(&written) });

    var packed_tier = try essence.packFor(gpa, carry.source, "song");
    defer packed_tier.deinit(gpa);
    try testing.expect(!packed_tier.diags.hasErrors());
    if (carry.corrupt_essence) {
        // The IR's own header survives; its body does not. That is rule
        // 4's "bad Binary IR", and it is what a truncating DAW leaves.
        for (packed_tier.bytes[8..]) |*byte| byte.* = 0xFF;
    }

    var read_as = try smfFile(gpa, carry.read_as);
    defer read_as.deinit();

    var carried = try carrier_smf.attach(gpa, &read_as, .{
        .essence = if (carry.essence) packed_tier.bytes else null,
        .conductor = if (carry.conductor) &conductor else null,
        .lanes = if (carry.lanes) &.{ kick, cutoff } else &.{},
    }, .{});
    defer carried.deinit();
    try testing.expect(!carried.diags.hasErrors());
    if (carry.ver != records.version) setVersion(&carried.sequence, carry.ver);

    var file = try smf_write.write(gpa, &carried.sequence, .{});
    defer file.deinit();
    try testing.expect(!file.diags.hasErrors());
    const bytes = try gpa.dupe(u8, file.bytes);
    errdefer gpa.free(bytes);

    var read_back = try smf_read.read(gpa, bytes);
    errdefer read_back.deinit();
    try testing.expect(!read_back.diags.hasErrors());

    var detached = try carrier_smf.detach(gpa, &read_back.sequence);
    errdefer detached.deinit();

    const text = try bridge_smf.sequenceToForms(gpa, &detached.sequence, null, .{});
    return .{
        .gpa = gpa,
        .bytes = bytes,
        .file = read_back,
        .detached = detached,
        .text = text,
    };
}

/// Re-stamp every residue event's envelope version — the one thing a
/// carrier cannot be asked to write, because writing a version it does
/// not know is exactly what it refuses to do.
fn setVersion(seq: *Sequence.Sequence, ver: u8) void {
    for (seq.tracks) |t| {
        for (t.events) |*e| {
            if (e.kind == .tempura_residue) e.payload.residue.ver = ver;
        }
    }
}

test "reconcile: rule 1 — a .mid with no residue derives the skeleton and says so" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try smfCase(gpa, .{ .essence = false, .conductor = false, .lanes = false });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), .none, .{});
    defer got.deinit();

    try testing.expectEqual(Rule.derived, got.rule);
    try testing.expect(std.mem.startsWith(u8, got.doc_text, header_skeleton));
    // Rule 1 is silent: no diagnostics at all.
    try testing.expectEqual(@as(usize, 0), got.diags.items().len);
    try testing.expectEqual(@as(?ConductorVerdict, null), got.conductor);

    // Every derived lane is bound at an address the file uses, and the
    // verdict says it was inferred.
    try testing.expect(got.verdicts.len > 0);
    for (got.verdicts) |v| try testing.expectEqual(Action.skeleton, v.action);
    // The kick's channel and the cutoff's controller both became lanes.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":from song :track 2 :ch 1") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":cc 74") != null);
    // The file conducts, because nothing else can.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":conductor song") != null);
}

test "reconcile: rule 2 — both hashes match, the essence is the document again" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try smfCase(gpa, .{});
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(Rule.restored, got.rule);
    try testing.expectEqual(@as(usize, 0), got.diags.items().len);
    try testing.expect(got.conductor.?.hash_ok);
    try testing.expect(!got.conductor.?.file_conducts);

    // The author's own text came back: the comment, the title, the
    // authored `:qpm` spelling, the cue and both lanes' native content.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "; the author's own note") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "; the kick, as the author wrote it") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(tempo-point :at 0bar :qpm 120)") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(cue :name \"intro\" :at 0bar)") != null);
    // The DOCUMENT conducts, as it did when it was built: no
    // `:conductor`, which is also what keeps its own points from being
    // `conductor_conflict` when the assembled text is read back.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":conductor") == null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(note :at 0bar :dur 1q :key 36 :vel 100)") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":ease in-cubic") != null);

    // The marker is an anchor again, over the bytes being dumped.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":file \"self\"") == null);
    const anchored = try std.fmt.allocPrint(
        gpa,
        "(anchor :id song :kind smf :file \"song.mid\" :size {d} :sha256 \"{s}\")",
        .{ case.bytes.len, hexDigest(case.bytes) },
    );
    defer gpa.free(anchored);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, anchored) != null);

    // Both addresses are CONSUMED: neither lane was also imported as a
    // bound lane, so nothing in the restored tier carries `:from`.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":from") == null);

    for (got.verdicts) |v| {
        try testing.expect(v.hash_ok);
        try testing.expectEqual(Action.restored_native, v.action);
    }
    try testing.expectEqual(@as(usize, 2), got.verdicts.len);
    try testing.expectEqualStrings("kick", got.verdicts[0].lane);
    try testing.expectEqualStrings("cutoff", got.verdicts[1].lane);
}

test "reconcile: rule 2 — a velocity edit makes one lane bound and leaves the other native" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    // The file a DAW handed back: one velocity byte lighter on the
    // kick's channel, everything else as tempura wrote it.
    var case = try smfCase(gpa, .{ .read_as = .{ .vel = 99 } });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(Rule.restored, got.rule);
    // The conductor is untouched: an edit to a channel message is not a
    // timing edit.
    try testing.expect(got.conductor.?.hash_ok);

    const kick = got.verdictFor("kick").?;
    try testing.expect(!kick.hash_ok);
    try testing.expectEqual(Action.became_bound, kick.action);

    const cutoff = got.verdictFor("cutoff").?;
    try testing.expect(cutoff.hash_ok);
    try testing.expectEqual(Action.restored_native, cutoff.action);

    // The kick is a BOUND lane at the record's address now, with its
    // name, kind and target kept and its notes gone; the cutoff is
    // still the essence's own.
    try testing.expect(std.mem.indexOf(
        u8,
        got.doc_text,
        "(lane :name kick :kind notes :target drums :from song :track 2 :ch 1 :key 36)",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(note :at 0bar") == null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(keyframe :at 0bar :value 0)") != null);

    // Exactly one `residue_stale`, and it names the lane, the address
    // and the losses — the two notes and nothing else.
    try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_stale));
    const d = got.diags.items()[0];
    try testing.expectEqual(Diag.Code.residue_stale, d.code);
    try testing.expectEqual(Diag.Severity.warning, d.severity);
    try testing.expect(std.mem.indexOf(u8, d.message, "lane kick") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "track 2 ch 1 key 36") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "dropped 2 notes") != null);
    // A REWRITTEN root keeps its author's comment: the lane is still the
    // kick, it just reads the file now. Only a DROPPED root takes its
    // comment with it, which the conductor's test below pins.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "; the author's own note") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "; the kick, as the author") != null);
}

/// A `.mid` tempura built from a lane whose notes name TWO channels —
/// one track for the lane and one record PER CHANNEL, since a lane hash
/// is over a `(track, ch)` pair — plus a second lane on a track of its
/// own, read back the way `dump` reads it. With `edited`, the channel-2
/// note is one velocity lighter than the records were computed over: a
/// DAW's edit to one of the lane's two channels.
fn kitCase(gpa: Allocator, edited: bool) !SmfCase {
    const source: [:0]const u8 =
        \\(timeline :title "kit" :length 1bar)
        \\
        \\(anchor :id song :kind smf :file "song.mid" :size 1 :sha256 "9f2a")
        \\
        \\(tempo-point :at 0bar :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\
        \\(lane :name kit :kind notes :target drums
        \\  (note :at 0bar :dur 1q :key 36 :vel 100 :ch 1)
        \\  (note :at 1q :dur 1q :key 38 :vel 80 :ch 2))
        \\
        \\(lane :name hat :kind notes
        \\  (note :at 2q :dur 1q :key 42 :vel 70))
        \\
    ;

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = 96 };
    const t0 = try b.addTrack();
    try b.addEvent(t0, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(t0, 0, .time_signature, .{ .time_sig = .{ .nn = 4, .dd = 2, .cc = 24, .bb = 8 } });
    try b.addEvent(t0, 384, .end_of_track, .empty);
    const t1 = try b.addTrack();
    try b.addEvent(t1, 0, .sequence_name, .{ .bytes = try b.addBytes("kit") });
    try b.addEvent(t1, 0, .note_on, .{ .note = .{ .ch = 0, .key = 36, .vel = 100 } });
    try b.addEvent(t1, 96, .note_off, .{ .note = .{ .ch = 0, .key = 36, .vel = 64 } });
    try b.addEvent(t1, 96, .note_on, .{ .note = .{ .ch = 1, .key = 38, .vel = 80 } });
    try b.addEvent(t1, 192, .note_off, .{ .note = .{ .ch = 1, .key = 38, .vel = 64 } });
    try b.addEvent(t1, 384, .end_of_track, .empty);
    const t2 = try b.addTrack();
    try b.addEvent(t2, 0, .sequence_name, .{ .bytes = try b.addBytes("hat") });
    try b.addEvent(t2, 192, .note_on, .{ .note = .{ .ch = 0, .key = 42, .vel = 70 } });
    try b.addEvent(t2, 288, .note_off, .{ .note = .{ .ch = 0, .key = 42, .vel = 64 } });
    try b.addEvent(t2, 384, .end_of_track, .empty);
    var written = try b.finish();
    defer written.deinit();

    // The records, over the file as tempura wrote it.
    const kit_1 = try records.encodeLane(gpa, .{
        .lane = "kit",
        .address = .{ .smf = .{ .track = 2, .ch = .single(0), .key = null, .curve = null } },
        .hash = records.hashSmfLane(&written, 1, 0, 96),
    });
    defer gpa.free(kit_1);
    const kit_2 = try records.encodeLane(gpa, .{
        .lane = "kit",
        .address = .{ .smf = .{ .track = 2, .ch = .single(1), .key = null, .curve = null } },
        .hash = records.hashSmfLane(&written, 1, 1, 96),
    });
    defer gpa.free(kit_2);
    const hat = try records.encodeLane(gpa, .{
        .lane = "hat",
        .address = .{ .smf = .{ .track = 3, .ch = .single(0), .key = null, .curve = null } },
        .hash = records.hashSmfLane(&written, 2, 0, 96),
    });
    defer gpa.free(hat);
    const conductor = records.encodeConductor(.{ .hash = records.hashSmfConductor(&written) });

    var packed_tier = try essence.packFor(gpa, source, "song");
    defer packed_tier.deinit(gpa);
    try testing.expect(!packed_tier.diags.hasErrors());

    // The DAW's edit, AFTER the records were taken: channel 2's note.
    if (edited) {
        for (written.tracks[1].events) |*e| {
            if (e.kind == .note_on and e.payload.note.ch == 1) e.payload.note.vel = 79;
        }
    }

    var carried = try carrier_smf.attach(gpa, &written, .{
        .essence = packed_tier.bytes,
        .conductor = &conductor,
        .lanes = &.{ kit_1, kit_2, hat },
    }, .{});
    defer carried.deinit();
    try testing.expect(!carried.diags.hasErrors());

    var file = try smf_write.write(gpa, &carried.sequence, .{});
    defer file.deinit();
    try testing.expect(!file.diags.hasErrors());
    const bytes = try gpa.dupe(u8, file.bytes);
    errdefer gpa.free(bytes);

    var read_back = try smf_read.read(gpa, bytes);
    errdefer read_back.deinit();
    try testing.expect(!read_back.diags.hasErrors());

    var detached = try carrier_smf.detach(gpa, &read_back.sequence);
    errdefer detached.deinit();

    const text = try bridge_smf.sequenceToForms(gpa, &detached.sequence, null, .{});
    return .{
        .gpa = gpa,
        .bytes = bytes,
        .file = read_back,
        .detached = detached,
        .text = text,
    };
}

test "reconcile: rule 2 — a lane rendered on two channels and edited on one binds at both" {
    // The reviewer's sentence: "Reconciliation must preserve every
    // address belonging to the lane." The kit's channel-1 notes were
    // untouched, and a lane bound at channel 2 alone would leave them
    // in the tier belonging to no lane — gone from every query and
    // from the score.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try kitCase(gpa, true);
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(Rule.restored, got.rule);
    try testing.expect(got.conductor.?.hash_ok);

    // One verdict PER RECORD, in record order: the kit's two both say
    // `became_bound` — the LANE's verdict — each with its own hash's
    // answer; the hat is the essence's own.
    try testing.expectEqual(@as(usize, 3), got.verdicts.len);
    try testing.expectEqualStrings("kit", got.verdicts[0].lane);
    try testing.expect(got.verdicts[0].hash_ok);
    try testing.expectEqual(Action.became_bound, got.verdicts[0].action);
    try testing.expect(got.verdicts[0].address.smf.ch.eql(.single(0)));
    try testing.expectEqualStrings("kit", got.verdicts[1].lane);
    try testing.expect(!got.verdicts[1].hash_ok);
    try testing.expectEqual(Action.became_bound, got.verdicts[1].action);
    try testing.expect(got.verdicts[1].address.smf.ch.eql(.single(1)));
    const hat = got.verdictFor("hat").?;
    try testing.expect(hat.hash_ok);
    try testing.expectEqual(Action.restored_native, hat.action);

    // The kit binds at its track and at BOTH channels, keeping its
    // target; the hat is untouched and still native.
    try testing.expect(std.mem.indexOf(
        u8,
        got.doc_text,
        "(lane :name kit :kind notes :target drums :from song :track 2 :ch [1 2])",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":key 36") == null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(note :at 2q :dur 1q :key 42 :vel 70)") != null);

    // `residue_stale` names the SET, and the two notes it cost.
    try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_stale));
    const d = got.diags.items()[0];
    try testing.expectEqual(Diag.Code.residue_stale, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, "lane kit at track 2 ch 1,2:") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "dropped 2 notes") != null);

    // The consumption takes the hat's pair and the conductor's events,
    // and leaves EVERY channel of the kit in the tier — the untouched
    // one included — for the bound lane to read.
    const c = consumeSmf(&case.detached.sequence, &got);
    try testing.expectEqual(@as(usize, 2), c.events);
    try testing.expectEqual(@as(usize, 2), c.conductor);
    const kit_track = case.detached.sequence.tracks[1];
    try testing.expectEqual(@as(usize, 2), countKind(kit_track, .note_on));
    try testing.expectEqual(@as(usize, 0), countKind(case.detached.sequence.tracks[2], .note_on));

    // …and the same file untouched restores every lane native, three
    // matching verdicts and nothing bound.
    var exact = try kitCase(gpa, false);
    defer exact.deinit();
    var again = try reconcile(gpa, &schema, exact.input(), exact.found(), .{});
    defer again.deinit();
    try testing.expectEqual(@as(usize, 3), again.verdicts.len);
    for (again.verdicts) |v| {
        try testing.expect(v.hash_ok);
        try testing.expectEqual(Action.restored_native, v.action);
    }
    try testing.expectEqual(@as(usize, 0), again.diags.count(.residue_stale));
    try testing.expect(std.mem.indexOf(u8, again.doc_text, ":from song") == null);
}

fn countKind(track: Sequence.Track, kind: Sequence.Kind) usize {
    var n: usize = 0;
    for (track.events) |e| {
        if (e.kind == kind) n += 1;
    }
    return n;
}

test "reconcile: rule 2 — a tempo edit gives the file the baton and names every loss" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try smfCase(gpa, .{ .read_as = .{ .tempo = 400_000 } });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(Rule.restored, got.rule);
    try testing.expect(!got.conductor.?.hash_ok);
    try testing.expect(got.conductor.?.file_conducts);

    // Both lanes are still tempura's: a tempo edit moves no channel
    // message, so neither lane hash moved with it.
    for (got.verdicts) |v| try testing.expectEqual(Action.restored_native, v.action);

    // The document's own points and cues are gone and `:conductor` says
    // who keeps time now.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "tempo-point") == null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "meter-point") == null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(cue ") == null);
    // `:conductor` was not in the authored header and is now, on the
    // `(timeline …)` form itself.
    try testing.expect(std.mem.indexOf(
        u8,
        got.doc_text,
        "(timeline :title \"residue\" :length 2bar :conductor song)",
    ) != null);
    // The comment that annotated a dropped point went with it; the one
    // that annotates the document did not.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "; the tempo the author set") == null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "; the author's own note") != null);

    // One `residue_stale`, listing exactly what it dropped — with the
    // AUTHORED `:qpm` spelling among the losses.
    try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_stale));
    const d = got.diags.items()[0];
    try testing.expect(std.mem.indexOf(
        u8,
        d.message,
        "dropped tempo-point :qpm 120, meter-point :sig [4 4], cue :name \"intro\"",
    ) != null);
}

test "reconcile: rule 2 — a marker rename and a division change both conduct" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // A marker renamed in the DAW: same kind, same tick, other text.
    {
        var case = try smfCase(gpa, .{ .read_as = .{ .marker = "verse" } });
        defer case.deinit();
        var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
        defer got.deinit();
        try testing.expect(got.conductor.?.file_conducts);
        try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_stale));
    }

    // A `division` change under unchanged ticks: every event moved on
    // the grid, so the conductor hash moved and so did both lanes'.
    {
        var case = try smfCase(gpa, .{ .read_as = .{ .ppq = 480 } });
        defer case.deinit();
        var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
        defer got.deinit();
        try testing.expect(got.conductor.?.file_conducts);
        for (got.verdicts) |v| try testing.expectEqual(Action.became_bound, v.action);
    }
}

test "reconcile: rule 2 — a stale curve keeps the hint its steps confirm and loses the other" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    // One controller value inside the FIRST segment pulled far off the
    // cubic. The second segment is untouched and still linear.
    var case = try smfCase(gpa, .{ .read_as = .{ .cc48 = 100 } });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    const kick = got.verdictFor("kick").?;
    try testing.expectEqual(Action.restored_native, kick.action);

    const cutoff = got.verdictFor("cutoff").?;
    try testing.expect(!cutoff.hash_ok);
    try testing.expectEqual(Action.became_bound, cutoff.action);

    // One hint survived — the linear one over the second quarter — and
    // the `in-cubic` one is gone, once, by name.
    try testing.expectEqual(@as(usize, 1), cutoff.hints.len);
    try testing.expectEqualStrings("linear", cutoff.hints[0].ease);
    try testing.expectEqual(q, cutoff.hints[0].from);
    try testing.expectEqual(2 * q, cutoff.hints[0].to);
    try testing.expectEqual(@as(usize, 1), got.diags.count(.ease_hint_mismatch));
    const d = findDiag(&got, .ease_hint_mismatch).?;
    try testing.expectEqual(Diag.Severity.warning, d.severity);
    try testing.expect(std.mem.indexOf(u8, d.message, "lane cutoff") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "in-cubic") != null);

    // The lane reads the file now, and its `:range` and `:target` came
    // with it.
    try testing.expect(std.mem.indexOf(
        u8,
        got.doc_text,
        "(lane :name cutoff :kind curve :from song :track 2 :ch 2 :cc 74 :range [0 1])",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(keyframe ") == null);
}

test "reconcile: rule 2 — an untouched file keeps every hint and raises nothing" {
    // The other half of the hint rule: a hash that MATCHES asks no
    // questions of the steps at all, so a verified hint is not even
    // computed and `ease_hint_mismatch` is not raised for a lane nobody
    // edited.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try smfCase(gpa, .{});
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(@as(usize, 0), got.diags.count(.ease_hint_mismatch));
    try testing.expectEqual(@as(usize, 0), got.verdictFor("cutoff").?.hints.len);
}

test "reconcile: rule 4 — a corrupt essence takes the skeleton path and says so" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try smfCase(gpa, .{ .corrupt_essence = true });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(Rule.corrupt, got.rule);
    try testing.expect(std.mem.startsWith(u8, got.doc_text, header_corrupt));
    try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_corrupt));
    try testing.expectEqual(Diag.Code.residue_corrupt, got.diags.items()[0].code);
    // The skeleton is total: the file is a document again, bound lanes
    // and all, and no lane claims to be the essence's.
    try testing.expect(got.verdicts.len > 0);
    for (got.verdicts) |v| try testing.expectEqual(Action.skeleton, v.action);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":from song") != null);
}

test "reconcile: rule 4 — records without an essence are damage, not a residue" {
    // A `.mid` whose lane records survived and whose essence did not is
    // a TORN residue, and plan 04's rule 4 is what it takes: the
    // skeleton, named. Restoring the records alone would be a document
    // asserted from hashes nobody can check.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try smfCase(gpa, .{ .essence = false });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(Rule.corrupt, got.rule);
    try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_corrupt));
    try testing.expect(std.mem.indexOf(u8, got.diags.items()[0].message, "essence") != null);
}

test "reconcile: rule 3 — a newer envelope leaves the payloads in the file and derives" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try smfCase(gpa, .{ .ver = records.version + 1 });
    defer case.deinit();

    // `detach` did not take them: a version it does not write is a
    // version it does not consume, and it said so.
    try testing.expectEqual(@as(?[]const u8, null), case.detached.payloads.essence);
    try testing.expect(case.detached.diags.count(.residue_version) > 0);
    // They are still IN the tier, as the plain `sequencer-specific`
    // events RP-001 told every reader to skip.
    try testing.expect(std.mem.indexOf(u8, case.text, "sequencer-specific") != null);

    var got = try reconcile(gpa, &schema, case.input(), .{ .newer = records.version + 1 }, .{});
    defer got.deinit();

    try testing.expectEqual(Rule.version, got.rule);
    try testing.expect(std.mem.startsWith(u8, got.doc_text, header_version));
    for (got.verdicts) |v| try testing.expectEqual(Action.skeleton, v.action);
}

/// The first diagnostic carrying `code`, or null — the tests' join.
fn findDiag(got: *const Result, code: Diag.Code) ?Diag.Diagnostic {
    for (got.diags.items()) |d| {
        if (d.code == code) return d;
    }
    return null;
}

// ---- the IT half -----------------------------------------------------

/// The same document over a `.it`, with one BOUND lane beside the two
/// native ones: the bound one is what the message tail can still say
/// when the chunk is gone, and the native ones are what only the essence
/// can.
const it_source: [:0]const u8 =
    \\; impulsos, as the author wrote it
    \\(timeline :title "impulsos" :length 2bar)
    \\
    \\(anchor :id song :kind it :file "song.it" :size 1 :sha256 "9f2a")
    \\
    \\(tempo-point :at 0bar :qpm 125)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(cue :name "intro" :at 0bar)
    \\
    \\(lane :name kick :kind notes :target drums
    \\  (note :at 0bar :dur 1q :key 60))
    \\
    \\(lane :name bass-vol :kind curve :range [0 1]
    \\  (keyframe :at 0bar :value 0)
    \\  (keyframe :at 8q :value 1 :ease in-cubic))
    \\
    \\(lane :name hats :kind notes :from song :channel 4)
    \\
;

/// What a tracker may have done to the module after tempura wrote it.
const ItEdit = struct {
    /// The bass-vol lane's volume at row 16 — a cell edit on its
    /// channel.
    vol: u8 = 32,
    /// The `Txx` param on channel 3 — the conductor's own cell.
    tempo: u8 = 125,
    /// A note on the BOUND lane's channel, which no record covers.
    hat: u8 = 72,
    /// The note the bass-vol channel opens on. Editing it moves that
    /// lane's hash without touching its volume column — a stale curve
    /// whose steps still say exactly what they said.
    bass_note: u8 = 48,
};

/// What the bass-vol record's own easing hint claims. The module's
/// volume column ramps 0, 16, 32, 48, 64 over five played rows, which is
/// LINEAR — so `linear` verifies against those steps and `in-cubic` does
/// not.
const ItHint = struct {
    ease: []const u8 = "in-cubic",
};

/// The module tempura rendered `it_source` into: the kick on channel 1,
/// the bass-vol ramp on channel 2, the conductor's `Txx` on channel 3
/// and the bound hats on channel 4.
fn itFile(gpa: Allocator, e: ItEdit) !itf.Module {
    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();

    const p0 = try b.addPattern(64);
    p0.at(0, 0).* = .{ .note = 60, .ins = 1, .vol = 64 };
    p0.at(16, 0).* = .{ .note = 60, .ins = 1, .vol = 64 };

    p0.at(0, 1).* = .{ .note = e.bass_note, .ins = 2, .vol = 0 };
    p0.at(8, 1).* = .{ .vol = 16 };
    p0.at(16, 1).* = .{ .vol = e.vol };
    p0.at(24, 1).* = .{ .vol = 48 };
    p0.at(32, 1).* = .{ .vol = 64 };

    p0.at(0, 2).* = .{ .fx = 'T' - '@', .param = e.tempo };

    p0.at(0, 3).* = .{ .note = e.hat, .ins = 3 };
    p0.at(8, 3).* = .{ .note = 72, .ins = 3 };

    try b.addOrder(0);
    try b.setMessage("a song about the sea");
    return b.finish();
}

/// One built-and-read `.it`: the bytes, the module the residue came out
/// of, its tier text, and what the two carriers held.
const ItCase = struct {
    gpa: Allocator,
    bytes: []u8,
    file: itf_read.Result,
    chosen: carrier_it.Chosen,
    /// The tail's SJON source, when the tail is what was chosen.
    tail_text: ?[:0]u8,
    text: []u8,
    diags: Diag.List,

    fn deinit(self: *ItCase) void {
        if (self.tail_text) |t| self.gpa.free(t);
        self.diags.deinit();
        self.gpa.free(self.text);
        self.chosen.deinit();
        self.file.deinit();
        self.gpa.free(self.bytes);
    }

    fn found(self: *const ItCase) Found {
        return switch (self.chosen) {
            .chunk => |p| .{ .payloads = p.payloads },
            .tail => .{ .tail = self.tail_text.? },
            .none => .none,
        };
    }

    fn input(self: *const ItCase) File {
        return .{
            .tier = .{ .it = &self.file.module },
            .text = self.text,
            .bytes = self.bytes,
            .name = "song.it",
        };
    }
};

/// What goes into the `.it`'s two carriers.
const ItCarry = struct {
    written: ItEdit = .{},
    read_as: ItEdit = .{},
    /// The easing the bass-vol record hints at.
    hint: ItHint = .{},
    /// The `TMPU` chunk — off for the tail-only case.
    chunk: bool = true,
    /// The message tail.
    tail: bool = true,
};

/// Build a `.it` the way `build` would, then read it back the way `dump`
/// does: chunk and tail → write → read → `choose` → the bridge's text.
fn itCase(gpa: Allocator, schema: *const Schema, carry: ItCarry) !ItCase {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var written = try itFile(gpa, carry.written);
    defer written.deinit();
    var wrows = try walk.derive(gpa, &written, .{});
    defer wrows.deinit();
    const pats = try playedPatterns(arena, &wrows);

    const kick = try records.encodeLane(gpa, .{
        .lane = "kick",
        .address = .{ .it = .{ .channel = 0, .column = null, .fx = null } },
        .hash = records.hashItLane(&written, &wrows, &[_]u8{0}, pats),
    });
    defer gpa.free(kick);
    var segments = [_]records.Segment{
        .{ .at = 0, .ease = "linear" },
        .{ .at = 8 * q, .ease = carry.hint.ease },
    };
    const bass = try records.encodeLane(gpa, .{
        .lane = "bass-vol",
        .address = .{ .it = .{ .channel = 1, .column = .vol, .fx = null } },
        .hash = records.hashItLane(&written, &wrows, &[_]u8{1}, pats),
        .steps_only = &segments,
    });
    defer gpa.free(bass);
    const conductor = records.encodeConductor(.{ .hash = records.hashItConductor(&written) });

    var packed_tier = try essence.packFor(gpa, it_source, "song");
    defer packed_tier.deinit(gpa);
    try testing.expect(!packed_tier.diags.hasErrors());

    const payload = try carrier_it.chunk(gpa, .{
        .essence = packed_tier.bytes,
        .conductor = &conductor,
        .lanes = &.{ kick, bass },
    });
    defer gpa.free(payload);

    var doc_res = try fromSjon.fromSource(gpa, schema, it_source, null);
    defer doc_res.deinit();
    try testing.expect(!doc_res.diags.hasErrors());
    var t = try carrier_it.tail(gpa, &doc_res.doc, &doc_res.map);
    defer t.deinit(gpa);
    try testing.expect(!t.diags.hasErrors());

    var read_as = try itFile(gpa, carry.read_as);
    defer read_as.deinit();
    const whole = try carrier_it.appendTail(gpa, read_as.message, t.bytes);
    defer gpa.free(whole);

    var file = try itf_write.write(gpa, &read_as, null, .{
        .tmpu = if (carry.chunk) payload else null,
        .message_tail = if (carry.tail) whole[read_as.message.len..] else null,
    });
    defer file.deinit();
    try testing.expect(!file.diags.hasErrors());
    const bytes = try gpa.dupe(u8, file.bytes);
    errdefer gpa.free(bytes);

    var read_back = try itf_read.read(gpa, bytes);
    errdefer read_back.deinit();
    try testing.expect(!read_back.diags.hasErrors());

    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();
    const chunk_bytes = if (read_back.module.tmpu) |r| r.slice(bytes) else null;
    var chosen = try carrier_it.choose(gpa, chunk_bytes, read_back.module.message, &diags);
    errdefer chosen.deinit();

    const tail_text: ?[:0]u8 = switch (chosen) {
        .tail => |text| try carrier_it.parseTail(gpa, text),
        else => null,
    };
    errdefer if (tail_text) |x| gpa.free(x);

    const text = try bridge_it.moduleToForms(gpa, &read_back.module, .{});
    return .{
        .gpa = gpa,
        .bytes = bytes,
        .file = read_back,
        .chosen = chosen,
        .tail_text = tail_text,
        .text = text,
        .diags = diags,
    };
}

test "reconcile: rule 1 — a .it with no residue derives the skeleton" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try itCase(gpa, &schema, .{ .chunk = false, .tail = false });
    defer case.deinit();
    try testing.expect(std.meta.activeTag(case.found()) == .none);

    var got = try reconcile(gpa, &schema, case.input(), .none, .{});
    defer got.deinit();

    try testing.expectEqual(Rule.derived, got.rule);
    try testing.expect(std.mem.startsWith(u8, got.doc_text, header_skeleton));
    try testing.expectEqual(@as(usize, 0), got.diags.items().len);
    try testing.expect(got.verdicts.len > 0);
    for (got.verdicts) |v| try testing.expectEqual(Action.skeleton, v.action);
    // Every channel the module uses is a bound lane, and the module
    // conducts.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":from song :channel 1") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":conductor song") != null);
}

test "reconcile: rule 2 and rule 5 — the chunk wins, and the essence is the document again" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    // Both carriers present, both readable: the chunk is the one that
    // answers, and `residue_partial` is not raised.
    var case = try itCase(gpa, &schema, .{});
    defer case.deinit();
    try testing.expectEqual(@as(usize, 0), case.diags.count(.residue_partial));

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(Rule.restored, got.rule);
    try testing.expectEqual(@as(usize, 0), got.diags.items().len);
    try testing.expect(got.conductor.?.hash_ok);
    for (got.verdicts) |v| try testing.expectEqual(Action.restored_native, v.action);

    // The author's document, comments and native content and all — and
    // the bound lane exactly as it was written.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "; impulsos, as the author wrote it") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(note :at 0bar :dur 1q :key 60)") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(lane :name hats :kind notes :from song :channel 4)") != null);
    // The marker became an anchor over the bytes being dumped.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":file \"self\"") == null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":file \"song.it\" :size") != null);
}

test "reconcile: rule 2 — a cell edit binds the lane it moved and leaves the rest" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    // A tracker nudged one volume cell on the bass-vol channel.
    var case = try itCase(gpa, &schema, .{ .read_as = .{ .vol = 33 } });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expect(got.conductor.?.hash_ok);
    try testing.expectEqual(Action.restored_native, got.verdictFor("kick").?.action);
    const bass = got.verdictFor("bass-vol").?;
    try testing.expect(!bass.hash_ok);
    try testing.expectEqual(Action.became_bound, bass.action);

    try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_stale));
    const d = findDiag(&got, .residue_stale).?;
    try testing.expect(std.mem.indexOf(u8, d.message, "lane bass-vol") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "channel 2 column vol") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "2 keyframes") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        got.doc_text,
        "(lane :name bass-vol :kind curve :from song :channel 2 :column vol :range [0 1])",
    ) != null);

    // The hint rule, over IT's own steps: the module's volume column
    // ramps linearly across the five rows it plays, so the record's
    // `in-cubic` claim is contradicted and dropped.
    try testing.expectEqual(@as(usize, 0), bass.hints.len);
    try testing.expectEqual(@as(usize, 1), got.diags.count(.ease_hint_mismatch));
    const h = findDiag(&got, .ease_hint_mismatch).?;
    try testing.expect(std.mem.indexOf(u8, h.message, "lane bass-vol") != null);
    try testing.expect(std.mem.indexOf(u8, h.message, "in-cubic") != null);
}

test "reconcile: rule 2 — an IT hint the volume column really follows is kept" {
    // The other half of the same rule on the same steps: a `linear`
    // claim over a linear ramp survives, and nothing is raised.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try itCase(gpa, &schema, .{
        .hint = .{ .ease = "linear" },
        .read_as = .{ .bass_note = 49 },
    });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    const bass = got.verdictFor("bass-vol").?;
    try testing.expectEqual(Action.became_bound, bass.action);
    try testing.expectEqual(@as(usize, 1), bass.hints.len);
    try testing.expectEqualStrings("linear", bass.hints[0].ease);
    try testing.expectEqual(@as(i64, 0), bass.hints[0].from);
    try testing.expectEqual(@as(i64, 8 * q), bass.hints[0].to);
    try testing.expectEqual(@as(usize, 0), got.diags.count(.ease_hint_mismatch));
}

test "reconcile: rule 2 — an edit to a bound lane's channel moves no verdict" {
    // The bound lane has no record: its content was always the file's,
    // so a tracker editing it is not a staleness at all.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try itCase(gpa, &schema, .{ .read_as = .{ .hat = 73 } });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(@as(usize, 0), got.diags.items().len);
    for (got.verdicts) |v| try testing.expectEqual(Action.restored_native, v.action);
}

test "reconcile: rule 2 — a Txx edit gives the module the baton" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try itCase(gpa, &schema, .{ .read_as = .{ .tempo = 140 } });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expect(!got.conductor.?.hash_ok);
    try testing.expect(got.conductor.?.file_conducts);
    try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_stale));
    const d = findDiag(&got, .residue_stale).?;
    try testing.expect(std.mem.indexOf(
        u8,
        d.message,
        "dropped tempo-point :qpm 125, meter-point :sig [4 4], cue :name \"intro\"",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":conductor song)") != null);
}

test "reconcile: rule 5 — the tail alone is the shape of the piece and says what it lacks" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    // What a tracker's re-save leaves: the message survived, the
    // trailing chunk did not.
    var case = try itCase(gpa, &schema, .{ .chunk = false });
    defer case.deinit();

    // `residue_partial` is the carrier's — raised once, where the
    // choice was made.
    try testing.expectEqual(@as(usize, 1), case.diags.count(.residue_partial));
    const p = case.diags.items()[0];
    try testing.expectEqual(Diag.Code.residue_partial, p.code);
    try testing.expect(std.mem.indexOf(u8, p.message, "no native content and no records") != null);

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(Rule.partial, got.rule);
    try testing.expect(std.mem.startsWith(u8, got.doc_text, header_partial));
    // No hash check ran, so there is no conductor verdict at all.
    try testing.expectEqual(@as(?ConductorVerdict, null), got.conductor);

    // The shape came back: the timeline's keys, the cue, and every
    // lane's declaration — with the MODULE conducting, because the tail
    // carries no `tempo-point`s by construction and a restored shape
    // with neither points nor a `:conductor` would not re-read at all.
    try testing.expect(std.mem.indexOf(
        u8,
        got.doc_text,
        "(timeline :title \"impulsos\" :length 2bar :conductor song)",
    ) != null);
    // Nothing was DROPPED, though: `residue_partial` has already said
    // what the tail lacks, and there was no point or cue to lose.
    try testing.expectEqual(@as(usize, 0), got.diags.count(.residue_stale));
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(cue :name \"intro\" :at 0bar)") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(cue :name \"intro\" :at 0bar)") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(lane :name kick :kind notes :target drums)") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(lane :name hats :kind notes :from song :channel 4)") != null);
    // …and none of the content, which only the essence could have said.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(note ") == null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(keyframe ") == null);
    // The marker is an anchor again here too.
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":file \"self\"") == null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":file \"song.it\" :size") != null);

    // The one lane the tail could address stays BOUND, and the lanes it
    // could not are declarations with nothing in them.
    try testing.expectEqual(@as(usize, 1), got.verdicts.len);
    try testing.expectEqualStrings("hats", got.verdicts[0].lane);
    try testing.expectEqual(Action.became_bound, got.verdicts[0].action);
    try testing.expect(!got.verdicts[0].hash_ok);
}

test "reconcile: rule 2 — a document with no points of its own still hears the handover" {
    // The other shape of the conductor mismatch: nothing to drop, and
    // the loss is real all the same — a document that timed itself at
    // the default now takes its time from the file, and a silent
    // `:conductor` would be exactly the silence plan 04 forbids.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try smfCase(gpa, .{
        .source = smf_bare,
        .read_as = .{ .tempo = 400_000 },
    });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expect(got.conductor.?.file_conducts);
    try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_stale));
    const d = findDiag(&got, .residue_stale).?;
    try testing.expect(std.mem.indexOf(u8, d.message, "dropped nothing") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        got.doc_text,
        "(timeline :title \"bare\" :conductor song)",
    ) != null);
}

test "reconcile: a carrier that could not read its residue is rule 4, never rule 1" {
    // `Found.corrupt`: the carrier held a residue and the framing did
    // not hold. The difference from `.none` is the HEADER — a document
    // that says "no residue found" over a file that carried one is two
    // surfaces contradicting each other, and the diagnostics say
    // `residue_corrupt`.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try smfCase(gpa, .{ .essence = false, .conductor = false, .lanes = false });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), .corrupt, .{});
    defer got.deinit();

    try testing.expectEqual(Rule.corrupt, got.rule);
    try testing.expect(std.mem.startsWith(u8, got.doc_text, header_corrupt));
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "no residue found") == null);
    // The carrier named the loss; this arm does not say it twice.
    try testing.expectEqual(@as(usize, 0), got.diags.items().len);
    try testing.expect(got.verdicts.len > 0);
    for (got.verdicts) |v| try testing.expectEqual(Action.skeleton, v.action);
}

test "reconcile: a lane record naming a lane the essence has not got is named and dropped" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    // The record says `ghost`; the essence declares `kick` and
    // `cutoff`. Nothing in the document can carry that verdict.
    var case = try smfCase(gpa, .{ .kick_name = "ghost" });
    defer case.deinit();

    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();

    try testing.expectEqual(Rule.restored, got.rule);
    // One verdict, not two: the orphan gets none.
    try testing.expectEqual(@as(usize, 1), got.verdicts.len);
    try testing.expectEqualStrings("cutoff", got.verdicts[0].lane);
    try testing.expectEqual(@as(?LaneVerdict, null), got.verdictFor("ghost"));

    // …and the loss is named rather than swallowed.
    try testing.expectEqual(@as(usize, 1), got.diags.count(.residue_stale));
    const d = findDiag(&got, .residue_stale).?;
    try testing.expect(std.mem.indexOf(u8, d.message, "names ghost at track 2 ch 1 key 36") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "orphaned") != null);
    // The real lanes came back untouched, content and all. (The
    // assertion is on the FORM's content rather than on its line: SJON's
    // full-mode printer reflows a multi-child form across lines, so what
    // the essence preserves is the comments, the spellings and the
    // content — not the author's exact whitespace.)
    try testing.expect(std.mem.indexOf(u8, got.doc_text, ":name kick") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "(note :at 0bar :dur 1q :key 36 :vel 100)") != null);
    try testing.expect(std.mem.indexOf(u8, got.doc_text, "; the kick, as the author wrote it") != null);
}

test "reconcile: the binding keys it writes are the ones the printer writes back" {
    // `addressKeysInto` and `toSjon`'s `binding` are two spellings of one
    // thing, and a disagreement would make a dump non-idempotent: the
    // bound lane a stale verdict writes is read back and re-printed, and
    // the text would move on the second pass. Every address shape, once.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const Case = struct { kind: []const u8, address: Doc.Address };
    const cases = [_]Case{
        .{ .kind = "notes", .address = .{ .smf = .{ .track = 2, .ch = .single(0), .key = 36, .curve = null } } },
        .{ .kind = "notes", .address = .{ .smf = .{ .track = 1, .ch = .single(15), .key = null, .curve = null } } },
        .{ .kind = "curve", .address = .{ .smf = .{ .track = 3, .ch = .single(4), .key = null, .curve = .{ .cc = 74 } } } },
        .{ .kind = "curve", .address = .{ .smf = .{ .track = 3, .ch = .single(4), .key = null, .curve = .{ .cc14 = .{ 74, 106 } } } } },
        .{ .kind = "curve", .address = .{ .smf = .{ .track = 2, .ch = .single(1), .key = null, .curve = .bend } } },
        .{ .kind = "curve", .address = .{ .smf = .{ .track = 2, .ch = .single(1), .key = null, .curve = .pressure } } },
        .{ .kind = "curve", .address = .{ .smf = .{ .track = 2, .ch = .single(1), .key = null, .curve = .velocity } } },
        .{ .kind = "notes", .address = .{ .it = .{ .channel = 3, .column = null, .fx = null } } },
        .{ .kind = "curve", .address = .{ .it = .{ .channel = 5, .column = .vol, .fx = null } } },
        .{ .kind = "curve", .address = .{ .it = .{ .channel = 5, .column = .fx, .fx = 'T' } } },
    };

    for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        var keys: std.ArrayList(u8) = .empty;
        try addressKeysInto(arena.allocator(), &keys, c.address);

        const kind_name = switch (c.address) {
            .smf => "smf",
            .it => "it",
        };
        const source = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "(timeline :title \"t\")\n" ++
                "(anchor :id song :kind {s} :file \"x\" :size 1 :sha256 \"9f2a\")\n" ++
                "(tempo-point :at 0bar :qpm 120)\n" ++
                "(meter-point :at 0bar :sig [4 4])\n" ++
                "(lane :name l :kind {s} :from song{s}{s})\n",
            .{
                kind_name,
                c.kind,
                keys.items,
                if (std.mem.eql(u8, c.kind, "curve")) " :range [0 1]" else "",
            },
            0,
        );

        var res = try fromSjon.fromSource(gpa, &schema, source, null);
        defer res.deinit();
        try testing.expect(!res.diags.hasErrors());

        const printed = try toSjon.print(gpa, &res.doc, &res.map, .{});
        defer gpa.free(printed);
        // The printer's own spelling of the very same binding.
        try testing.expect(std.mem.indexOf(u8, printed, keys.items) != null);
    }
}

test "reconcile: consumption takes the restored lanes' events and the conductor's out of the tier, and nothing else" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // Every hash matches: the kick's four note events on channel 1, the
    // cutoff's nine steps on channel 2, and the three conductor events
    // tempura writes all go; the `cue-point` and both tracks stay.
    {
        var case = try smfCase(gpa, .{});
        defer case.deinit();
        var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
        defer got.deinit();
        const c = consumeSmf(&case.detached.sequence, &got);
        try testing.expectEqual(@as(usize, 13), c.events);
        try testing.expectEqual(@as(usize, 3), c.conductor);
        try testing.expect(c.any());
        const seq = &case.detached.sequence;
        try testing.expectEqual(@as(usize, 2), seq.tracks.len);
        try testing.expectEqual(@as(usize, 2), seq.tracks[0].events.len);
        try testing.expectEqual(Sequence.Kind.cue_point, seq.tracks[0].events[0].kind);
        try testing.expectEqual(Sequence.Kind.end_of_track, seq.tracks[0].events[1].kind);
        try testing.expectEqual(@as(usize, 1), seq.tracks[1].events.len);
        try testing.expectEqual(Sequence.Kind.end_of_track, seq.tracks[1].events[0].kind);
    }

    // The kick is stale and BOUND: its events are what the lane reads
    // now, and stay; the cutoff's still go, and so does the conductor's.
    {
        var case = try smfCase(gpa, .{ .read_as = .{ .vel = 99 } });
        defer case.deinit();
        var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
        defer got.deinit();
        const c = consumeSmf(&case.detached.sequence, &got);
        try testing.expectEqual(@as(usize, 9), c.events);
        try testing.expectEqual(@as(usize, 3), c.conductor);
        // Four note events and the end of track.
        try testing.expectEqual(@as(usize, 5), case.detached.sequence.tracks[1].events.len);
    }

    // The file conducts (a tempo edit): the document's points were
    // dropped, and the file's own conductor events are what it reads.
    {
        var case = try smfCase(gpa, .{ .read_as = .{ .tempo = 400_000 } });
        defer case.deinit();
        var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
        defer got.deinit();
        try testing.expect(got.conductor.?.file_conducts);
        const c = consumeSmf(&case.detached.sequence, &got);
        try testing.expectEqual(@as(usize, 0), c.conductor);
        try testing.expectEqual(@as(usize, 13), c.events);
    }

    // Rule 1 restores nothing, so it consumes nothing.
    {
        var case = try smfCase(gpa, .{ .essence = false, .conductor = false, .lanes = false });
        defer case.deinit();
        var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
        defer got.deinit();
        try testing.expectEqual(Rule.derived, got.rule);
        const c = consumeSmf(&case.detached.sequence, &got);
        try testing.expect(!c.any());
    }
}

test "reconcile: consumption clears a restored lane's cells in the played patterns and the conductor's Txx" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var case = try itCase(gpa, &schema, .{});
    defer case.deinit();
    var got = try reconcile(gpa, &schema, case.input(), case.found(), .{});
    defer got.deinit();
    try testing.expectEqual(Rule.restored, got.rule);
    try testing.expect(got.played.len > 0);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const module = &case.file.module;
    var before: usize = 0;
    for (module.patterns) |p| {
        for (p.cells) |cell| {
            if (!cell.isEmpty()) before += 1;
        }
    }
    const c = try consumeIt(arena.allocator(), module, &got);
    try testing.expect(c.cells > 0);
    var after: usize = 0;
    for (module.patterns) |p| {
        for (p.cells) |cell| {
            if (!cell.isEmpty()) after += 1;
        }
    }
    // A lane's cell goes whole; a `Txx` clear empties a cell only when
    // the effect was all it held.
    try testing.expect(before - after >= c.cells);
    try testing.expect(before - after <= c.cells + c.conductor);
    // Every restored lane's channel is empty in every played pattern…
    for (got.verdicts) |v| {
        if (v.action != .restored_native) continue;
        for (got.played) |pi| {
            const p = module.patterns[pi];
            var row: usize = 0;
            while (row < p.rows) : (row += 1) {
                try testing.expect(p.at(row, v.address.it.channel).isEmpty());
            }
        }
    }
    // …no `Txx` is left anywhere, and the touched patterns are listed
    // ascending for the bin-mode printer.
    for (module.patterns) |p| {
        for (p.cells) |cell| try testing.expect(cell.fx != fx_t);
    }
    var last: i32 = -1;
    for (c.patterns) |pi| {
        try testing.expect(@as(i32, pi) > last);
        last = pi;
    }
}
