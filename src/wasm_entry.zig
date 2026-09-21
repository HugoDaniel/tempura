//! `tempura.wasm` entry — static zones + the `tpr_*` export surface.
//!
//! The artifact is a pure function of its linear memory: no clock, no
//! loop, no filesystem. A host writes a document's text or a file's bytes
//! into a static zone, calls a `tpr_*` verb, and reads text or a packed
//! blob back (pacer's `drv_*` shape; the table is plan 10, "Wasm
//! exports"). One import rides in transitively —
//! `env.sjon_host_invoke_plugin`, SJON's executable-plugin dispatch —
//! and tempura documents never declare executable plugins, so a host
//! stubs it with `() => 0`, which SJON maps to a clean diagnostic rather
//! than a trap.
//!
//! Blob formats live in `TprAbi.zig`, natively tested; this file is zone
//! plumbing and lifecycle only.
//!
//! ## Memory zones
//!
//! ```
//! doc        1 MiB  ← host writes document text   (tpr_docPtr/tpr_docCap)
//! file       4 MiB  ← host writes .mid/.it bytes   (tpr_filePtr/tpr_fileCap)
//! op        64 KiB  ← host writes operation JSON   (tpr_opPtr/tpr_opCap)
//! text       4 MiB  → module writes the document   (tpr_textPtr/tpr_text)
//! out        4 MiB  → module writes actions, a     (tpr_outPtr/tpr_outCap)
//!                     score, or a built file
//! timeline 256 KiB  → module writes 'TPTL'         (tpr_timelinePtr/tpr_timeline)
//! playhead   4 KiB  → module writes 'TPPH'         (tpr_playheadPtr/tpr_at, tpr_atTick)
//! diags     64 KiB  → module writes 'TPDG'         (tpr_diagPtr/tpr_diagLen)
//! heap              ← the schema, the document, the derivation, the
//!                     format cores' values (std.heap.wasm_allocator)
//! ```
//!
//! The zones are `.bss`, so they cost the module file nothing and the
//! instance about thirteen megabytes of linear memory — which is the
//! right order for a tool that holds a whole `.it` and its document at
//! once. Every cap is readable (`tpr_docCap`, `tpr_fileCap`,
//! `tpr_opCap`, `tpr_outCap`), and a host that writes past one is
//! refused rather than truncated. RAISING a cap is a minor release;
//! lowering one, or re-typing a zone, is breaking.
//!
//! A `tpr_*` call that returns a LENGTH writes into exactly one zone and
//! the length is that zone's fill. Zero means "nothing to read" — not
//! loaded, refused, or over the zone's cap — and the `'TPDG'` blob says
//! which.
//!
//! ## Lifecycle
//!
//! `tpr_load(len)`, `tpr_loadFile(kind, len)` and `tpr_attachAnchor(len)`
//! return a status:
//!
//!   0 ok — the document is live and nothing is wrong with it;
//!   1 diagnostics — read the `'TPDG'` blob;
//!   2 bad call — a length over its cap, an unknown kind, or a verb that
//!       needs a document with none loaded (a host bug). The arguments
//!       are validated FIRST, so nothing changed: any previously loaded
//!       document, derivation and diagnostics stay live (pacer's
//!       `drv_load` rule);
//!   3 out of memory.
//!
//! **Status 1 still leaves the document LOADED.** That is where this
//! surface parts from pacer's, and it is tempura's discipline rather
//! than an accident: a defective score voids pacer's table because there
//! is nothing to evaluate, while `fromSource` and `derive` are total —
//! "the value is still built, because an editor has to show something"
//! (`time/derive.zig`). It is also what makes the browser round trip
//! work: a document whose `it/` dump needs its anchor's bytes loads with
//! `anchor_unavailable`, and the host then calls `tpr_attachAnchor` on
//! the live document and gets a clean reload. Only statuses 2 and 3
//! leave nothing behind, and 2 leaves what was there before.
//!
//! ## Anchors in the browser
//!
//! There is no filesystem here, so the resolver handed to every load is
//! an in-memory table holding at most one file: whatever
//! `tpr_attachAnchor` last verified. A resolver that is PRESENT and
//! cannot produce an anchor's bytes is `anchor_unavailable` (plan 02's
//! rule, `doc/Resolver.zig`) — so a by-reference anchor, and an inline
//! `it/` dump whose `(bin :at :len)` regions name a file, both say so
//! out loud in wasm until the host attaches the bytes. That is the
//! contract plan 10 states: a browser host inlines first, or attaches.
//!
//! `tpr_attachAnchor` verifies the bytes against the loaded document's
//! own `(anchor …)` declarations — `:size` and `:sha256`, `Resolver.verify`
//! — and reloads from the SAME source with them in hand. Bytes that
//! match no anchor are `anchor_mismatch` in the blob and the document is
//! left exactly as it was.
//!
//! ## Append-only
//!
//! The export set freezes at E3 together with `Diag.Code` and the three
//! blobs: never remove or re-type an export — bump `tpr_abiVersion` if
//! the contract itself must change.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("Diag.zig");
const Schema = @import("Schema.zig");
const TprAbi = @import("TprAbi.zig");
const doc = @import("doc/doc.zig");
const time = @import("time/time.zig");
const edit = @import("edit/edit.zig");
const exporter = @import("export/export.zig");

const Playhead = time.Playhead;
const Derived = time.derive.Derived;

const gpa = std.heap.wasm_allocator;

// ---------------------------------------------------------------------------
// Caps
// ---------------------------------------------------------------------------

/// A timeline document's text. Generous against the hand-written case
/// and the derived one alike: an `it/` dump with its patterns as rows is
/// the big document, and `--patterns=bin` is the switch that keeps it
/// small when only the timeline tier is being edited.
const DOC_CAP: usize = 1 << 20;
/// One `.mid` or `.it` file. Bytes are sacred, so the whole file is
/// held: this is the anchor's ceiling as much as the reader's.
const FILE_CAP: usize = 4 << 20;
/// One operation as JSON — an ask, never content.
const OP_CAP: usize = 64 << 10;
/// The document read back. Bigger than `DOC_CAP` would be pointless (a
/// document that came back is a document that can go in again), so they
/// are deliberately different numbers for different jobs: `tpr_loadFile`
/// can produce a document larger than any a host would type.
const TEXT_CAP: usize = 4 << 20;
/// The one general-purpose out zone: a plan's actions, a pacer score, or
/// a built file's bytes. One at a time, and each verb says how much it
/// wrote.
const OUT_CAP: usize = 4 << 20;
/// `'TPTL'`. The blob is a SUMMARY of the derivation (`TprAbi`'s header:
/// the bar table rides as its shape, not as its entries), so this is
/// roomy for a document with thousands of tempo segments and hundreds of
/// lanes.
const TIMELINE_CAP: usize = 256 << 10;
/// `'TPPH'` — one record plus its section-id tail.
const PLAYHEAD_CAP: usize = 4 << 10;
/// `'TPDG'`. A full zone still holds hundreds of diagnostics.
const DIAGS_CAP: usize = 64 << 10;

comptime {
    // The document text must stay parseable by SJON; the schema is
    // preloaded beside it, never prepended to it, so the whole budget is
    // the document's (pacer's assert, same reasoning).
    std.debug.assert(DOC_CAP <= sjon.Binary.MAX_FILE_SIZE);
    // A full diag zone still fits a useful report.
    std.debug.assert(DIAGS_CAP >= TprAbi.DIAGS_HEADER_LEN + 64 * (TprAbi.DIAG_RECORD_LEN + 256));
    // A position with a hundred overlapping sections still fits.
    std.debug.assert(PLAYHEAD_CAP >= TprAbi.PLAYHEAD_LEN + 100 * 4);
    // Every cap is reported through a u32 accessor.
    std.debug.assert(FILE_CAP <= std.math.maxInt(u32));
    std.debug.assert(OUT_CAP <= std.math.maxInt(u32));
}

/// The status every lifecycle verb returns. See the header.
const Status = enum(u32) { ok = 0, diagnostics = 1, bad_call = 2, oom = 3 };

/// `kind` as the two lifecycle verbs spell it on the wire: 0 is a `.mid`,
/// 1 is a `.it`. `Doc.AnchorKind`'s own ordinals, so the wire and the
/// value agree by construction.
fn kindOf(kind: u32) ?doc.AnchorKind {
    return switch (kind) {
        0 => .smf,
        1 => .it,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Static zones
// ---------------------------------------------------------------------------

/// +1 slot for the sentinel SJON's parser requires.
var doc_buffer: [DOC_CAP + 1]u8 = undefined;
var file_buffer: [FILE_CAP]u8 = undefined;
var op_buffer: [OP_CAP]u8 = undefined;
var text_buffer: [TEXT_CAP]u8 = undefined;
var out_buffer: [OUT_CAP]u8 = undefined;
var timeline_buffer: [TIMELINE_CAP]u8 = undefined;
var playhead_buffer: [PLAYHEAD_CAP]u8 = undefined;
var diags_buffer: [DIAGS_CAP]u8 = undefined;
var diags_len: u32 = 0;

/// The preloaded timeline vocabulary — parsed once, on the first load,
/// and held for the instance's lifetime (the wasm module is the host,
/// and a host owns exactly one `Schema`). It is the outermost ring of
/// the borrow nesting and is never torn down.
var schema: ?Schema = null;

/// Borrowed handle to `schema`, preloading on first use. Null only on
/// allocation failure, which a verb reports as `oom`.
fn liveSchema() ?*const Schema {
    if (schema == null) schema = Schema.load(gpa) catch return null;
    return &schema.?;
}

// ---------------------------------------------------------------------------
// The loaded document
// ---------------------------------------------------------------------------

/// Everything one loaded document owns.
///
/// Torn down in reverse of the borrow nesting: the derivation and the
/// result name strings in their own arenas, but an `it/` tier's `:raw`
/// and `data` regions are OFFSETS INTO `anchor_bytes`, so the attached
/// file outlives the document that reads it.
const State = struct {
    /// The document's own text, heap-owned — the thing `tpr_text`
    /// returns, the thing an edit is applied to, and the thing
    /// `pipeline.build` packs the essence out of (plan 04: what comes
    /// back is what a human wrote, not a re-derivation of it).
    source: [:0]u8,
    /// The attached anchor: the `:file` it answers to and its bytes.
    /// Both null until `tpr_attachAnchor` verifies a file.
    anchor_path: ?[]u8,
    anchor_bytes: ?[]u8,
    /// The report of the DUMP this document came out of, when one did.
    /// `pipeline.dump` already carries the re-load's own diagnostics —
    /// it loads the text it assembled, which is the very text this state
    /// was rebuilt from — so it REPLACES `result.diags` in the `'TPDG'`
    /// blob rather than joining it, and nothing is said twice.
    dump_report: ?Diag.List,
    result: doc.Result,
    derived: Derived,

    /// The document-stage report a host reads: the dump's when this
    /// document came out of a file, the load's otherwise.
    fn report(self: *const State) *const Diag.List {
        if (self.dump_report) |*d| return d;
        return &self.result.diags;
    }

    fn deinit(self: *State) void {
        self.derived.deinit();
        self.result.deinit();
        if (self.dump_report) |*d| d.deinit();
        if (self.anchor_path) |p| gpa.free(p);
        if (self.anchor_bytes) |b| gpa.free(b);
        gpa.free(self.source);
        self.* = undefined;
    }
};

var state: ?State = null;

/// The plan `tpr_plan` last produced and nobody has committed yet.
/// Dropped whenever the document changes underneath it, because an
/// address is where a node is and not which node it is (SJON §11.2) —
/// a plan made against one text is meaningless against another.
var pending: ?edit.Plan = null;

fn dropPending() void {
    if (pending) |*p| {
        p.deinit();
        pending = null;
    }
}

fn unload() void {
    dropPending();
    if (state) |*s| {
        s.deinit();
        state = null;
    }
}

/// The live document, or null.
fn live() ?*State {
    if (state) |*s| return s;
    return null;
}

/// Build a whole `State` from an owned source and an owned anchor pair,
/// WITHOUT touching the live one. Every lifecycle verb goes through
/// here, so "validated before unload" holds for all three: the caller
/// swaps only once this returns.
///
/// Takes ownership of all three slices on success AND on failure — a
/// half-owned allocation at a boundary is how a wasm module leaks.
fn buildState(
    source: [:0]u8,
    anchor_path: ?[]u8,
    anchor_bytes: ?[]u8,
    dump_report: ?Diag.List,
) error{OutOfMemory}!State {
    // A parameter is const, and the report has to be DEINITED on the
    // failure path — so it is rebound here rather than cast away.
    var report = dump_report;
    errdefer {
        gpa.free(source);
        if (anchor_path) |p| gpa.free(p);
        if (anchor_bytes) |b| gpa.free(b);
        if (report) |*d| d.deinit();
    }
    const live_schema = liveSchema() orelse return error.OutOfMemory;

    // One entry at most, and the resolver is always PRESENT: that is
    // what turns a file this instance cannot read into
    // `anchor_unavailable` rather than into silence (plan 10's row).
    var entries: [1]doc.Memory.Entry = undefined;
    var table: doc.Memory = .{ .entries = entries[0..0] };
    if (anchor_path) |p| {
        entries[0] = .{ .path = p, .bytes = anchor_bytes.? };
        table = .{ .entries = entries[0..1] };
    }

    var result = try doc.fromSource(gpa, live_schema, source, doc.memory(&table));
    errdefer result.deinit();
    const derived = try time.derive.derive(gpa, &result.doc);
    return .{
        .source = source,
        .anchor_path = anchor_path,
        .anchor_bytes = anchor_bytes,
        .dump_report = report,
        .result = result,
        .derived = derived,
    };
}

/// Swap a freshly built state in, encode its diagnostics, and answer.
fn install(next: State) u32 {
    unload();
    state = next;
    const s = &state.?;
    const sources = [_]TprAbi.DiagSource{
        .{ .stage = .document, .list = s.report() },
        .{ .stage = .derivation, .list = &s.derived.diags },
    };
    diags_len = @intCast(TprAbi.encodeDiags(&sources, &diags_buffer).len);
    const bad = s.report().hasErrors() or s.derived.diags.hasErrors();
    return @intFromEnum(if (bad) Status.diagnostics else Status.ok);
}

/// Write one list of diagnostics into the zone, replacing whatever a
/// load left there. The query verbs use this: a `tpr_plan` that refused
/// says why, and the load's report is stale the moment it does.
fn publishDiags(stage: TprAbi.Stage, list: *const Diag.List) void {
    const sources = [_]TprAbi.DiagSource{.{ .stage = stage, .list = list }};
    diags_len = @intCast(TprAbi.encodeDiags(&sources, &diags_buffer).len);
}

/// Copy `bytes` into `zone` and answer its length, or 0 when the zone
/// cannot hold it. A zone never silently truncates: a host reading a
/// short blob would read a wrong one.
fn fill(zone: []u8, bytes: []const u8) u32 {
    if (bytes.len > zone.len) return 0;
    @memcpy(zone[0..bytes.len], bytes);
    return @intCast(bytes.len);
}

// ---------------------------------------------------------------------------
// Exports — the handshake and the zones
// ---------------------------------------------------------------------------

/// The ABI generation this module implements. A host reads it first and
/// refuses a module it does not know.
export fn tpr_abiVersion() u32 {
    return 1;
}

export fn tpr_docPtr() [*]u8 {
    return &doc_buffer;
}

export fn tpr_docCap() u32 {
    return DOC_CAP;
}

export fn tpr_filePtr() [*]u8 {
    return &file_buffer;
}

export fn tpr_fileCap() u32 {
    return FILE_CAP;
}

export fn tpr_opPtr() [*]u8 {
    return &op_buffer;
}

export fn tpr_opCap() u32 {
    return OP_CAP;
}

export fn tpr_textPtr() [*]const u8 {
    return &text_buffer;
}

export fn tpr_outPtr() [*]const u8 {
    return &out_buffer;
}

export fn tpr_outCap() u32 {
    return OUT_CAP;
}

export fn tpr_timelinePtr() [*]const u8 {
    return &timeline_buffer;
}

export fn tpr_playheadPtr() [*]const u8 {
    return &playhead_buffer;
}

export fn tpr_diagPtr() [*]const u8 {
    return &diags_buffer;
}

export fn tpr_diagLen() u32 {
    return diags_len;
}

// ---------------------------------------------------------------------------
// Exports — lifecycle
// ---------------------------------------------------------------------------

/// A document's text at `tpr_docPtr`. See the header for the statuses
/// and for why status 1 still leaves the document loaded.
export fn tpr_load(len: u32) u32 {
    if (len > DOC_CAP) return @intFromEnum(Status.bad_call);
    doc_buffer[len] = 0;
    const source = gpa.dupeZ(u8, doc_buffer[0..len]) catch
        return @intFromEnum(Status.oom);
    const next = buildState(source, null, null, null) catch
        return @intFromEnum(Status.oom);
    return install(next);
}

/// `.mid` or `.it` bytes at `tpr_filePtr`. The dump happens HERE — plan
/// 10's row — so a browser host hands over a file and reads a document
/// back with `tpr_text`.
///
/// The bytes are kept as the attached anchor, because an `it/` dump's
/// `(bin :at :len)` regions are offsets into them: a `tpr_loadFile` is a
/// load with the anchor already attached, and the document it produces
/// reloads in a fresh instance through `tpr_load` + `tpr_attachAnchor`
/// with the same bytes.
export fn tpr_loadFile(kind: u32, len: u32) u32 {
    if (len > FILE_CAP) return @intFromEnum(Status.bad_call);
    const anchor_kind = kindOf(kind) orelse return @intFromEnum(Status.bad_call);
    const live_schema = liveSchema() orelse return @intFromEnum(Status.oom);

    const bytes = gpa.dupe(u8, file_buffer[0..len]) catch
        return @intFromEnum(Status.oom);
    var owned = true;
    defer if (owned) gpa.free(bytes);

    var dumped = doc.pipeline.dump(gpa, live_schema, bytes, anchor_kind, .{}) catch
        return @intFromEnum(Status.oom);
    // Only the TEXT survives the dump: the state is rebuilt from it the
    // way `tpr_load` rebuilds from a host's text, so one document shape
    // reaches every query and the dump→reload round trip is exercised on
    // every call rather than only in a test.
    const source = gpa.dupeZ(u8, dumped.text) catch {
        dumped.deinit();
        return @intFromEnum(Status.oom);
    };
    const path = gpa.dupe(u8, doc.pipeline.defaultFile(anchor_kind)) catch {
        gpa.free(source);
        dumped.deinit();
        return @intFromEnum(Status.oom);
    };
    // Move the dump's report out before the rest of it goes: it is the
    // whole story of the read, the carrier, the reconciliation and the
    // re-load, and dropping it would make a corrupt residue silent.
    const report = dumped.diags;
    dumped.diags = .init(gpa);
    dumped.deinit();

    owned = false;
    const next = buildState(source, path, bytes, report) catch
        return @intFromEnum(Status.oom);
    return install(next);
}

/// The bytes of the loaded document's `(anchor …)` at `tpr_filePtr`,
/// checked against its `:size` and `:sha256`.
///
/// Bytes that match no anchor are `anchor_mismatch` and the document is
/// left exactly as it was — the same "nothing changed" a bad call gets,
/// with a diagnostic instead of silence, because handing over the wrong
/// file is a thing a user does and not only a host bug.
export fn tpr_attachAnchor(len: u32) u32 {
    if (len > FILE_CAP) return @intFromEnum(Status.bad_call);
    const s = live() orelse return @intFromEnum(Status.bad_call);
    const bytes = file_buffer[0..len];

    const matched: ?[]const u8 = for (s.result.doc.anchors) |a| {
        const size = a.size orelse continue;
        const digest = a.sha256 orelse continue;
        if (doc.verify(bytes, size, digest)) break a.file;
    } else null;

    const file = matched orelse {
        var report: Diag.List = .init(gpa);
        defer report.deinit();
        report.add(
            .anchor_mismatch,
            .err,
            .{ .start = 0, .end = 0 },
            "these {d} bytes match no (anchor …) of the loaded document; the document was left as it was",
            .{len},
        ) catch return @intFromEnum(Status.oom);
        publishDiags(.document, &report);
        return @intFromEnum(Status.diagnostics);
    };

    // Reload from the SAME source with the bytes in hand — the anchor
    // is not a property of the document's text, so the text does not
    // change and every offset it carries now names something.
    const source = gpa.dupeZ(u8, s.source) catch return @intFromEnum(Status.oom);
    const path = gpa.dupe(u8, file) catch {
        gpa.free(source);
        return @intFromEnum(Status.oom);
    };
    const owned_bytes = gpa.dupe(u8, bytes) catch {
        gpa.free(source);
        gpa.free(path);
        return @intFromEnum(Status.oom);
    };
    const next = buildState(source, path, owned_bytes, null) catch
        return @intFromEnum(Status.oom);
    return install(next);
}

// ---------------------------------------------------------------------------
// Exports — reading the document back
// ---------------------------------------------------------------------------

/// The current document at `tpr_textPtr`, or 0 when nothing is loaded.
///
/// The document's own SOURCE — what was loaded, what a dump assembled,
/// or what an edit produced with its layout preserved — and never a
/// re-print of it: the essence exists so that "what comes back out is
/// the document a human wrote and not a re-derivation of it"
/// (`residue/essence.zig`), and canonicalising here would throw away
/// every comment the carrier went to the trouble of keeping.
export fn tpr_text() u32 {
    const s = live() orelse return 0;
    return fill(&text_buffer, s.source);
}

/// `'TPTL'` at `tpr_timelinePtr`: the derivation as a packed blob.
export fn tpr_timeline() u32 {
    const s = live() orelse return 0;
    const blob = TprAbi.encodeTimeline(&s.derived, &timeline_buffer) catch return 0;
    return @intCast(blob.len);
}

/// `'TPPH'` at `tpr_playheadPtr`: where `seconds` lands, after the end
/// behaviour. A clock no map can answer for — a NaN, an infinity, a
/// value past the tick ceiling — comes back as a REFUSAL record rather
/// than as a position nobody asked for.
export fn tpr_at(seconds: f64) u32 {
    const s = live() orelse return 0;
    var pos = Playhead.at(gpa, &s.derived, seconds) catch |err| switch (err) {
        error.OutOfMemory => return 0,
        else => {
            const blob = TprAbi.encodeRefusal(.of(err), &playhead_buffer) catch return 0;
            return @intCast(blob.len);
        },
    };
    defer pos.deinit(gpa);
    const blob = TprAbi.encodePlayhead(pos, &playhead_buffer) catch return 0;
    return @intCast(blob.len);
}

/// The same answer, asked by TICK — the query an editor makes when the
/// playhead was dragged on the grid rather than on the clock. A tick is
/// already on the grid, so neither host guard can fire and the record is
/// never a refusal.
export fn tpr_atTick(tick: i64) u32 {
    const s = live() orelse return 0;
    var pos = Playhead.atTick(gpa, &s.derived, tick) catch return 0;
    defer pos.deinit(gpa);
    const blob = TprAbi.encodePlayhead(pos, &playhead_buffer) catch return 0;
    return @intCast(blob.len);
}

/// The snapping helper. `grid` is `Playhead.SnapGrid`'s ordinal; an
/// ordinal this module does not know, or no document, answers with the
/// tick unchanged — a snap is a nudge, and refusing to move is the one
/// answer that cannot be wrong.
export fn tpr_snap(tick: i64, grid: u32, swing: f64) i64 {
    const s = live() orelse return tick;
    if (grid >= @typeInfo(Playhead.SnapGrid).@"enum".fields.len) return tick;
    return Playhead.snap(&s.derived, tick, @enumFromInt(grid), swing);
}

// ---------------------------------------------------------------------------
// Exports — the edit engine
// ---------------------------------------------------------------------------

/// One operation as JSON at `tpr_opPtr` (the `--op` grammar,
/// `edit/edit.zig`'s header) → the actions as JSON at `tpr_outPtr`,
/// exactly `Plan.text()`. Returns their length; 0 when nothing is
/// loaded, the ask is not an operation, or the plan refused — the
/// `'TPDG'` blob says which.
///
/// The plan is HELD: `tpr_apply(0)` commits the very actions this call
/// handed back, so an editor plans, shows the actions, and applies
/// without the document moving underneath them.
export fn tpr_plan(len: u32) u32 {
    if (len > OP_CAP) return 0;
    const s = live() orelse return 0;
    dropPending();

    var p = planOp(s, op_buffer[0..len]) catch return 0;
    if (p == null) return 0;
    const text = p.?.text(gpa) catch {
        p.?.deinit();
        return 0;
    };
    defer gpa.free(text);
    publishDiags(.operation, &p.?.diags);
    const written = fill(&out_buffer, text);
    pending = p.?;
    return written;
}

/// Plan `op_json` against the live document. Null = the ask was not an
/// operation and the reasons are already in the zone.
fn planOp(s: *State, op_json: []const u8) error{OutOfMemory}!?edit.Plan {
    var parsed = try edit.fromJson(gpa, op_json);
    defer parsed.deinit();
    const op = parsed.op orelse {
        publishDiags(.operation, &parsed.diags);
        return null;
    };

    // Parsing is total in SJON — a malformed document is a tree with
    // diagnostics, not an error — so only an allocation can fail here.
    var tree = try sjon.parse(gpa, s.source);
    defer tree.deinit();

    return try edit.planWith(gpa, &s.result.doc, &tree, &s.result.map, op);
}

/// Commit an edit and re-load the document; `tpr_text()` reads it back.
///
/// `len == 0` applies the plan `tpr_plan` last produced — the actions
/// the host is looking at. `len > 0` reads one operation as JSON at
/// `tpr_opPtr` and plans it first, which is the CLI's `edit --op` in one
/// call.
///
/// The ACTIONS are not the input spelling, deliberately: `Plan.Action`
/// carries the address and the slot `apply` sequences by, and §11.1's
/// JSON grammar does not repeat them — an action list read back from a
/// host would have to be re-addressed against a document it may no
/// longer describe. Planning from the operation, or committing a plan
/// this module still holds, are the two spellings that cannot
/// desynchronise.
export fn tpr_apply(len: u32) u32 {
    if (len > OP_CAP) return @intFromEnum(Status.bad_call);
    const s = live() orelse return @intFromEnum(Status.bad_call);

    var planned: ?edit.Plan = null;
    defer if (planned) |*p| p.deinit();
    const p: *const edit.Plan = if (len == 0) blk: {
        break :blk if (pending) |*held| held else return @intFromEnum(Status.bad_call);
    } else blk: {
        planned = planOp(s, op_buffer[0..len]) catch return @intFromEnum(Status.oom);
        break :blk if (planned) |*fresh| fresh else return @intFromEnum(Status.diagnostics);
    };

    var applied = edit.apply(gpa, s.source, p) catch return @intFromEnum(Status.oom);
    const source = gpa.dupeZ(u8, applied.text) catch {
        applied.deinit();
        return @intFromEnum(Status.oom);
    };
    const refused = applied.diags.hasErrors();
    applied.deinit();
    if (refused) {
        gpa.free(source);
        return @intFromEnum(Status.diagnostics);
    }

    // The anchor rides across: an edit changes the document's text, not
    // which file it is arranged around.
    const path = if (s.anchor_path) |old| gpa.dupe(u8, old) catch {
        gpa.free(source);
        return @intFromEnum(Status.oom);
    } else null;
    const bytes = if (s.anchor_bytes) |old| gpa.dupe(u8, old) catch {
        gpa.free(source);
        if (path) |x| gpa.free(x);
        return @intFromEnum(Status.oom);
    } else null;

    const next = buildState(source, path, bytes, null) catch return @intFromEnum(Status.oom);
    return install(next);
}

// ---------------------------------------------------------------------------
// Exports — the exporters
// ---------------------------------------------------------------------------

/// A pacer score at `tpr_outPtr`. `flags` is a bit set over plan 10's
/// switches: bit 0 `--velocity`, bit 1 `--ease linear`, bit 2
/// `--no-hints`, bit 3 `--section-markers`. Everything else keeps
/// `export/score.zig`'s defaults, which are the ones the CLI prints.
export fn tpr_exportScore(flags: u32) u32 {
    const s = live() orelse return 0;
    var result = exporter.exportScore(gpa, &s.result.doc, &s.derived, &.{}, .{
        .velocity = flags & 1 != 0,
        .ease_linear = flags & 2 != 0,
        .no_hints = flags & 4 != 0,
        .section_markers = flags & 8 != 0,
    }) catch return 0;
    defer result.deinit();
    publishDiags(.operation, &result.diags);
    return fill(&out_buffer, result.text);
}

/// The document as a file at `tpr_outPtr`, residue attached — plan 10's
/// `build` row. `kind` is 0 for `.mid` and 1 for `.it`. Returns the byte
/// count; 0 when nothing is loaded, the kind is unknown, the build was
/// refused (a cross-kind ask), or the bytes are over `tpr_outCap` — the
/// `'TPDG'` blob says which.
export fn tpr_build(kind: u32) u32 {
    const s = live() orelse return 0;
    const anchor_kind = kindOf(kind) orelse return 0;
    const live_schema = liveSchema() orelse return 0;

    var built = doc.pipeline.build(
        gpa,
        live_schema,
        s.source,
        &s.result.doc,
        &s.derived,
        anchor_kind,
        .{ .anchor_bytes = s.anchor_bytes },
    ) catch return 0;
    defer built.deinit();
    publishDiags(.operation, &built.diags);
    return fill(&out_buffer, built.bytes);
}
