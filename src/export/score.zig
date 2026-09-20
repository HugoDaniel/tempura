//! `exportScore` — the one door from tempura to pacer (plan 08, "What is
//! emitted").
//!
//! A `Doc` and its `Derived` in, a pacer score a person then edits out,
//! in exactly the order plan 08 prints it:
//!
//! ```
//! ; exported from impulsos.sjon (conductor: impulse-04.it, 12 lanes, 4 sections) by tempura 0.1.0
//! ; positions: 3 rounded (max 0.0000027b); onsets: 2 aggregated
//! ; warning: meter changes to [3 4] at bar 32; pacer keeps [4 4] …
//! (transport :bpm 125 :meter [4 4] :dur 128bar :end loop)
//! (tempo :at 64bar :bpm 150)
//! ; cue "bar 41" — bar 40
//! (scene :name intro :at 0bar :dur 16bar)
//! (trigger :target kick :at [0bar 1b 2b 3b])
//! (track :target glow (key …) …)
//! (track :target hats :pattern (euclid 3 8 1))
//! (track :target pulse :expr (sin (* beat 6.2832)))
//! (control …)   ; every pacer root, verbatim, comments included
//! ```
//!
//! **One meter, one transport.** pacer's `(transport …)` carries a
//! single `:meter`, so the score takes the document's FIRST one. A meter
//! pacer cannot spell at all (a component past `meter-component`'s 1..16,
//! or a denominator with no exact bar) and a meter that CHANGES are the
//! same warning, `export_meter_unsupported`: positions stay exact —
//! under the `[4 4]` fallback a pacer beat is a quarter — and only the
//! bar and phase lanes drift. `:bpm` is `qpm · d / 4`, because pacer's
//! beat is a `4 / d` note and tempura's tempo is per quarter; pacer's
//! `bpm-value` 1..1000 is checked before anything is emitted
//! (`export_bpm_out_of_range`, an error).
//!
//! **The 512 fallback.** pacer holds `MAX_TEMPO_SEGMENTS = 512` tempo
//! segments. Adjacent equal tempi coalesce always; past the cap,
//! segments within `--tempo-eps` coalesce too; and if even that is not
//! enough — a per-tick `T0x` slide over a song — the table is dropped
//! and every position prints in SECONDS off the real tempo map, with
//! `export_tempo_budget`. The piece still sounds right; its beat lanes
//! run on the transport's one tempo.
//!
//! **Lanes in document order.** Plan 08 lists the emissions by KIND;
//! this prints them in the order the document wrote its lanes, which is
//! the same list for the plan's own example and keeps a person's score
//! looking like their document. A `notes` lane is a `(trigger …)`, a
//! `curve` lane a `(track …)` with keys, a `query` lane a `:pattern` and
//! a `formula` lane an `:expr`, the last two verbatim — tempura carries
//! those two vocabularies, it does not re-spell them.
//!
//! **Pass-through, minus what would collide.** Every pacer root is
//! printed after tempura's own emissions, verbatim, with the comments
//! that rode above it. The two exceptions are the two that would make
//! the emitted text REFUSE to load: a `(transport …)` or `(tempo …)`
//! (`passthrough_conducts`) and a `(scene …)` under a section's name
//! (`scene_duplicate`). Both are errors, and skipping the root keeps the
//! text loadable so a person can see the rest of their score while they
//! fix the collision.

const std = @import("std");
const testing = std.testing;

const Diag = @import("../Diag.zig");
const doc = @import("../doc/doc.zig");
const time = @import("../time/time.zig");

const lanes = @import("lanes.zig");
const pos = @import("pos.zig");
const simplify = @import("simplify.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Grid = time.Grid;
const TimeMap = time.TimeMap;
const derive = time.derive;

/// Exporting can only fail the way any allocation fails. Every defect of
/// a DOCUMENT is a diagnostic on the returned result.
pub const Error = error{OutOfMemory};

/// "These steps were a named curve between these two ticks" — re-exported
/// so a caller needs one import.
pub const EaseHint = lanes.EaseHint;

/// pacer's per-score tempo cap (`pacer/src/TrackTable.zig`).
pub const MAX_TEMPO_SEGMENTS: usize = 512;

/// pacer's parked `:at`-list cap (plan 08, "The key budget", item 4).
pub const MAX_ONSETS: usize = 1000;

/// The exporter's switches — the CLI's flags, one struct.
pub const Options = struct {
    /// Emit a sibling `(track :target <name>-vel …)` of `vel / 127` for
    /// every notes lane.
    velocity: bool = false,
    /// Print a bound curve lane's steps as `linear` ramps rather than
    /// `hold` stairs — "the ramp the DAW's automation sampled, a better
    /// signal than the file carries" (plan 08). The plan spells this as
    /// the LANE's `:ease linear`; `schema/tempura.sjon`'s `(lane …)` has
    /// no `:ease` key (only a `(keyframe …)` does, and a bound lane has
    /// no keyframes), so the switch lives here, on the exporter, for the
    /// whole document. A per-lane key would be a manifest change, and
    /// the manifest is frozen.
    ease_linear: bool = false,
    /// The simplification tolerance for a bound curve lane. The CC
    /// quantum by default, and the header comment states it.
    eps: f32 = 1.0 / 127.0,
    /// Ignore every easing hint, verified or not.
    no_hints: bool = false,
    /// How close two tempo segments have to be, in pacer bpm, before
    /// they coalesce under the 512 cap.
    tempo_eps: f64 = 0.01,
    /// The per-track share of pacer's `MAX_KEYS`; past it, a warning.
    max_keys_per_track: u32 = 512,
    /// `renderSmf`'s flag (a `marker` per section start), carried here
    /// so the CLI has ONE options struct. `exportScore` never reads it:
    /// a pacer score gets `(scene …)` forms, which is the same
    /// information in pacer's own vocabulary.
    section_markers: bool = false,
    /// What the header comment calls the document.
    source_name: []const u8 = "",
    /// What the header comment calls tempura.
    version: []const u8 = "0.1.0",
};

/// One trigger the score emitted, and the pacer ticks its events land
/// on — what the node landing proof reads back through `pacer.wasm`.
///
/// The exporter is the only thing that knows these: the beat mode gets
/// them off the lattice and the seconds mode off the tempo map, and a
/// test that recomputed them would be checking its own arithmetic.
pub const Landing = struct {
    target: []const u8,
    ticks: []const i64,
};

/// The score, the report, and what the conversion cost.
pub const Result = struct {
    /// The emitted text. Owned by `arena`.
    text: []u8,
    diags: Diag.List,
    /// How many positions left pacer's lattice, and by how much.
    counter: pos.Counter,
    /// How many onsets merged onto a pacer tick another already held.
    aggregated: u32,
    /// The meter actually emitted — the document's, or `[4 4]`.
    meter: [2]u8,
    /// Whether the 512 fallback fired and every position is in seconds.
    seconds_mode: bool,
    /// Every `(trigger …)` emitted, with the ticks its events claim.
    landings: []const Landing,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        self.diags.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// A `Doc` and its `Derived` in, a pacer score out.
///
/// `hints` are the easing hints for this document's bound curve lanes
/// (the SMF bridge's `ease_hint` events today; task 15 wires the residue
/// source). Pass `&.{}` for none.
pub fn exportScore(
    gpa: Allocator,
    d: *const doc.Doc,
    derived: *const derive.Derived,
    hints: []const EaseHint,
    opts: Options,
) Error!Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();
    const a = arena.allocator();

    var e: Emitter = .{
        .a = a,
        .doc = d,
        .derived = derived,
        .map = &derived.map,
        .opts = opts,
        .diags = &diags,
        .hints = hints,
    };

    try e.chooseMeter();
    try e.planTempo();

    // The BODY is rendered first, because the header comment counts what
    // rendering it found (the roundings, the aggregations, the keys) and
    // the warning comments are the diagnostics it raised.
    var body: Io.Writer.Allocating = .init(a);
    try e.transport(&body.writer);
    try e.tempoForms(&body.writer);
    try e.cues(&body.writer);
    try e.scenes(&body.writer);
    try e.laneForms(&body.writer);
    try e.passthrough(&body.writer);

    // Both sinks allocate from the RESULT's arena and neither is
    // `deinit`ed: the arena moves into the `Result`, so the text it hands
    // back outlives this frame and one `Result.deinit()` frees the lot.
    var out: Io.Writer.Allocating = .init(a);
    try e.header(&out.writer);
    out.writer.writeAll(body.written()) catch return error.OutOfMemory;

    return .{
        .text = out.written(),
        .diags = diags,
        .counter = e.mapper.counter,
        .aggregated = e.aggregated,
        .meter = .{ e.n, e.d },
        .seconds_mode = e.seconds_mode,
        .landings = try e.landings.toOwnedSlice(a),
        .arena = arena,
    };
}

// ---- the emitter ----

/// One coalesced tempo segment, in pacer's units.
const TempoForm = struct { tick: i64, bpm: f64 };

const Emitter = struct {
    a: Allocator,
    doc: *const doc.Doc,
    derived: *const derive.Derived,
    map: *const TimeMap.TimeMap,
    opts: Options,
    diags: *Diag.List,
    hints: []const EaseHint,

    /// The meter actually emitted.
    n: u8 = 4,
    d: u8 = 4,

    /// The coalesced tempo table, segment 0 excluded.
    tempo: []TempoForm = &.{},
    /// Segment 0's bpm, in pacer's units.
    bpm: f64 = 120,
    seconds_mode: bool = false,

    /// The one converter-and-speller; `planTempo` swaps its mode when
    /// the 512 fallback fires, and nothing else in here knows the
    /// difference.
    mapper: pos.Mapper = .{ .mode = .{ .beats = .{ .n = 4, .d = 4 } } },
    landings: std.ArrayList(Landing) = .empty,
    aggregated: u32 = 0,
    keys_before: u32 = 0,
    keys_after: u32 = 0,
    budgeted: bool = false,

    // ---- planning ----

    /// pacer carries ONE meter. Take the document's first; say so when
    /// that is a lie, either because pacer cannot spell it or because
    /// the document changes it later.
    fn chooseMeter(self: *Emitter) Error!void {
        const first = self.map.meters[0];
        if (pos.supportedMeter(first.n, first.d)) {
            self.n = first.n;
            self.d = first.d;
        } else {
            try self.diags.add(
                .export_meter_unsupported,
                .warning,
                self.meterSpan(0),
                "pacer cannot carry [{d} {d}] (meter-component is 1..16 over an exact bar); the score gets [4 4] and positions in quarter notes, exact, with the bar and phase lanes wrong from the first bar",
                .{ first.n, first.d },
            );
        }
        self.mapper = .{ .mode = .{ .beats = .{ .n = self.n, .d = self.d } } };

        if (self.map.meters.len > 1) {
            const next = self.map.meters[1];
            try self.diags.add(
                .export_meter_unsupported,
                .warning,
                self.meterSpan(1),
                "meter changes to [{d} {d}] at bar {d}; pacer keeps [{d} {d}]; positions stay exact, bar/phase lanes drift from there",
                .{ next.n, next.d, next.first_bar, self.n, self.d },
            );
        }
    }

    /// The tempo table, coalesced to something pacer can hold — or the
    /// decision to print seconds instead.
    fn planTempo(self: *Emitter) Error!void {
        const segments = self.map.segments;
        self.bpm = self.pacerBpm(segments[0].us);
        try self.checkBpm(self.bpm, self.tempoSpan(0));

        // Adjacent EQUAL tempi always coalesce: a `T0x` slide's per-tick
        // segments collapse wherever the value repeats.
        var kept = try self.coalesce(segments, 0);
        // Still past the cap: coalesce anything within `--tempo-eps`.
        if (kept.len + 1 > MAX_TEMPO_SEGMENTS) {
            self.a.free(kept);
            kept = try self.coalesce(segments, self.opts.tempo_eps);
        }
        if (kept.len + 1 > MAX_TEMPO_SEGMENTS) {
            self.a.free(kept);
            self.tempo = &.{};
            self.seconds_mode = true;
            // pacer reads an `s` literal against `ticks_per_second`,
            // which a score with no `(tempo …)` form derives once from
            // the transport's own `:bpm` — so that is the rate every
            // position from here is spelled against.
            self.mapper = .{
                .mode = .{ .seconds = .{
                    .n = self.n,
                    .tps = pos.ticksPerSecond(self.bpm, self.n),
                    .map = self.map,
                } },
                .counter = self.mapper.counter,
            };
            try self.diags.add(
                .export_tempo_budget,
                .warning,
                self.tempoSpan(0),
                "{d} tempo segments is past pacer's {d} even within {d} bpm; the score drops its tempo table and prints every position in seconds",
                .{ segments.len, MAX_TEMPO_SEGMENTS, self.opts.tempo_eps },
            );
            return;
        }
        self.tempo = kept;
        for (kept, 0..) |form, i| try self.checkBpm(form.bpm, self.tempoSpan(i + 1));
    }

    /// Segments 1.. whose bpm differs from the last KEPT one by more
    /// than `eps`. `eps == 0` is the always-on adjacent-equal collapse.
    fn coalesce(self: *Emitter, segments: []const TimeMap.Segment, eps: f64) Error![]TempoForm {
        var out: std.ArrayList(TempoForm) = .empty;
        errdefer out.deinit(self.a);
        var last = self.bpm;
        for (segments[1..]) |seg| {
            const bpm = self.pacerBpm(seg.us);
            if (@abs(bpm - last) <= eps) continue;
            try out.append(self.a, .{ .tick = seg.tick, .bpm = bpm });
            last = bpm;
        }
        return out.toOwnedSlice(self.a);
    }

    fn pacerBpm(self: *const Emitter, us: f64) f64 {
        return pos.pacerBpm(60_000_000.0 / us, self.d);
    }

    fn checkBpm(self: *Emitter, bpm: f64, span: Diag.Span) Error!void {
        if (pos.inBpmRange(bpm)) return;
        try self.diags.add(
            .export_bpm_out_of_range,
            .err,
            span,
            "{d} beats per minute is outside pacer's bpm-value bound of 1..1000 — a pacer score has no spelling for this tempo under [{d} {d}]",
            .{ bpm, self.n, self.d },
        );
    }

    // ---- the header ----

    fn header(self: *Emitter, w: *Io.Writer) Error!void {
        const source = if (self.opts.source_name.len != 0) self.opts.source_name else "(unnamed)";
        const conductor = blk: {
            const id = self.doc.conductor orelse break :blk "none";
            const anchor = self.doc.anchorById(id) orelse break :blk id;
            break :blk anchor.file;
        };
        try pr(w, "; exported from {s} (conductor: {s}, {d} lanes, {d} sections) by tempura {s}\n", .{
            source,
            conductor,
            self.doc.lanes.len,
            self.doc.sections.len,
            self.opts.version,
        });
        const c = self.mapper.counter;
        try pr(w, "; positions: {d} rounded (max {d}b), durations: {d} rounded (max {d}b); onsets: {d} aggregated\n", .{
            c.rounded,
            c.max_err_beats,
            c.durations_rounded,
            c.max_dur_err_beats,
            self.aggregated,
        });
        if (self.budgeted) try pr(w, "; curve keys: {d} → {d} within eps {d}\n", .{
            self.keys_before,
            self.keys_after,
            self.opts.eps,
        });
        for (self.diags.items()) |diag| {
            const label = switch (diag.severity) {
                .err => "error",
                .warning => "warning",
                .info => "note",
            };
            try pr(w, "; {s}: {s}\n", .{ label, diag.message });
        }
    }

    // ---- the forms ----

    fn transport(self: *Emitter, w: *Io.Writer) Error!void {
        try pr(w, "(transport :bpm ", .{});
        try bpmText(w, self.bpm);
        try pr(w, " :meter [{d} {d}] :dur ", .{ self.n, self.d });
        try self.duration(w, 0, self.map.length);
        try pr(w, " :end {t})\n", .{self.map.end});
    }

    fn tempoForms(self: *Emitter, w: *Io.Writer) Error!void {
        for (self.tempo) |form| {
            try pr(w, "(tempo :at ", .{});
            try self.position(w, form.tick);
            try pr(w, " :bpm ", .{});
            try bpmText(w, form.bpm);
            try pr(w, ")\n", .{});
        }
    }

    /// A cue is a POINT, and pacer has no form for one — so it is a
    /// comment naming the bar it sits in (plan 08, "Sections → scenes").
    fn cues(self: *Emitter, w: *Io.Writer) Error!void {
        for (self.derived.cues) |c| {
            try pr(w, "; cue \"{s}\" — bar {d}\n", .{ c.name, self.map.barOf(c.at).bar });
        }
    }

    fn scenes(self: *Emitter, w: *Io.Writer) Error!void {
        var width: usize = 0;
        for (self.derived.sections) |s| width = @max(width, s.name.len);
        for (self.derived.sections) |s| {
            try pr(w, "(scene :name {s}", .{s.name});
            w.splatByteAll(' ', width - s.name.len) catch return error.OutOfMemory;
            try pr(w, " :at ", .{});
            try self.position(w, s.at);
            try pr(w, " :dur ", .{});
            try self.duration(w, s.at, s.dur);
            try pr(w, ")\n", .{});
        }
    }

    /// One lane at a time, in DOCUMENT order. `Derived.lanes` is one per
    /// `(lane …)` in that order, so the two walk together.
    fn laneForms(self: *Emitter, w: *Io.Writer) Error!void {
        for (self.doc.lanes, self.derived.lanes) |*lane, *index| switch (lane.kind) {
            .notes => try self.triggerForm(w, lane, index),
            .curve => try self.trackForm(w, lane, index),
            .query => {
                const src = lane.query_src orelse continue;
                try pr(w, "(track :target {s} :pattern {s})\n", .{ lane.target, src });
            },
            .formula => {
                const src = lane.expr_src orelse continue;
                try pr(w, "(track :target {s} :expr {s})\n", .{ lane.target, src });
            },
        };
    }

    fn triggerForm(self: *Emitter, w: *Io.Writer, lane: *const doc.Lane, index: *const derive.LaneIndex) Error!void {
        var t = try lanes.triggers(self.a, index.onsets, &self.mapper);
        defer t.deinit(self.a);
        // pacer refuses an empty `:at` list (`trigger_invalid`), so a
        // lane with nothing on it is a lane with no form.
        if (t.ticks.len == 0) return;
        self.aggregated +|= t.aggregated;
        // The proof's half of the emission: what the node suite reads
        // back through the real driver.
        try self.landings.append(self.a, .{
            .target = lane.target,
            .ticks = try self.a.dupe(i64, t.ticks),
        });

        if (t.ticks.len > MAX_ONSETS) try self.diags.add(
            .export_onset_budget,
            .warning,
            lane.span,
            "lane {s} carries {d} onsets, past pacer's parked :at-list cap of {d}; every one of them is emitted",
            .{ lane.name, t.ticks.len, MAX_ONSETS },
        );

        try pr(w, "(trigger :target {s} :at [", .{lane.target});
        for (t.ticks, 0..) |tick, i| {
            if (i != 0) w.writeByte(' ') catch return error.OutOfMemory;
            try self.pacerPosition(w, tick);
        }
        try pr(w, "])\n", .{});

        if (!self.opts.velocity) return;
        try pr(w, "(track :target {s}-vel\n", .{lane.target});
        for (t.ticks, t.vel, 0..) |tick, vel, i| {
            try pr(w, "  (key :at ", .{});
            try self.pacerPosition(w, tick);
            try pr(w, " :value {d} :ease hold)", .{@as(f32, @floatFromInt(vel)) / 127.0});
            try pr(w, "{s}\n", .{if (i + 1 == t.ticks.len) ")" else ""});
        }
    }

    fn trackForm(self: *Emitter, w: *Io.Writer, lane: *const doc.Lane, index: *const derive.LaneIndex) Error!void {
        var c = try lanes.curve(self.a, lane, index, self.hints, &self.mapper, .{
            .eps = self.opts.eps,
            .ease_linear = self.opts.ease_linear,
            .no_hints = self.opts.no_hints,
        }, self.diags);
        defer c.deinit(self.a);
        if (c.keys.len == 0) return;

        if (index.bound) {
            self.budgeted = true;
            self.keys_before +|= c.source_steps;
            self.keys_after +|= @intCast(c.keys.len);
        }
        if (c.keys.len > self.opts.max_keys_per_track) try self.diags.add(
            .export_key_budget,
            .warning,
            lane.span,
            "lane {s} prints {d} keys, past --max-keys-per-track {d} (pacer holds {d} across the score)",
            .{ lane.name, c.keys.len, self.opts.max_keys_per_track, 4096 },
        );

        try pr(w, "(track :target {s}\n", .{lane.target});
        for (c.keys, 0..) |key, i| {
            try pr(w, "  (key :at ", .{});
            try self.pacerPosition(w, key.tick);
            try pr(w, " :value ", .{});
            try value(w, key);
            try pr(w, " :ease {s}){s}\n", .{ key.ease, if (i + 1 == c.keys.len) ")" else "" });
        }
    }

    /// Every pacer root, verbatim, with the comments that rode above it
    /// — minus the two that would keep the emitted text from loading.
    fn passthrough(self: *Emitter, w: *Io.Writer) Error!void {
        for (self.doc.passthrough) |p| {
            if (std.mem.eql(u8, p.head, "transport") or std.mem.eql(u8, p.head, "tempo")) {
                try self.diags.add(
                    .passthrough_conducts,
                    .err,
                    p.span,
                    "tempura emits ({s} …) itself at export; this pass-through root is dropped so the score still loads",
                    .{p.head},
                );
                continue;
            }
            if (std.mem.eql(u8, p.head, "scene")) {
                if (sceneName(p.text)) |name| {
                    if (self.hasSection(name)) {
                        try self.diags.add(
                            .scene_duplicate,
                            .err,
                            p.span,
                            "a (section :name {s} …) already exports to a scene of that name; this pass-through scene is dropped so the score still loads",
                            .{name},
                        );
                        continue;
                    }
                }
            }
            for (p.comments) |c| try pr(w, "{s}\n", .{c});
            try pr(w, "{s}\n", .{p.text});
        }
    }

    // ---- positions ----

    /// A TEMPURA tick, printed: onto pacer's grid (counted), then
    /// spelled in this score's unit.
    fn position(self: *Emitter, w: *Io.Writer, tick: i64) Error!void {
        return self.pacerPosition(w, self.mapper.position(tick));
    }

    /// A DURATION, printed: the span of `[at, at + dur)` on pacer's
    /// grid, then spelled. Never the span of `[0, dur)` — under a tempo
    /// map those differ, and the seconds fallback exists precisely
    /// because the tempo is not constant.
    fn duration(self: *Emitter, w: *Io.Writer, at: i64, dur: i64) Error!void {
        return self.pacerPosition(w, self.mapper.durationTicks(at, dur));
    }

    /// A PACER tick, printed — beats and bars, or the fallback's
    /// seconds, whichever mode `mapper` is in.
    fn pacerPosition(self: *Emitter, w: *Io.Writer, tick: i64) Error!void {
        self.mapper.spell(w, tick) catch return error.OutOfMemory;
    }

    // ---- spans and small joins ----

    fn meterSpan(self: *const Emitter, i: usize) Diag.Span {
        if (i < self.doc.meter.len) return self.doc.meter[i].span;
        return .{ .start = 0, .end = 0 };
    }

    fn tempoSpan(self: *const Emitter, i: usize) Diag.Span {
        if (i < self.doc.tempo.len) return self.doc.tempo[i].span;
        return .{ .start = 0, .end = 0 };
    }

    fn hasSection(self: *const Emitter, name: []const u8) bool {
        for (self.derived.sections) |s| {
            if (std.mem.eql(u8, s.name, name)) return true;
        }
        return false;
    }
};

/// A tempo, printed as the shortest decimal that reads back as itself.
/// `spellBpm` takes the QUARTER rate and applies `d / 4`; the table
/// already holds pacer's own number, so `[n 4]` is what hands it
/// through untouched.
fn bpmText(w: *Io.Writer, bpm: f64) Error!void {
    pos.spellBpm(w, bpm, 4) catch return error.OutOfMemory;
}

/// A key's `:value`: a scalar, or a `[a b c]` vector of its live
/// components.
fn value(w: *Io.Writer, key: simplify.Key) Error!void {
    if (key.ncomp <= 1) return pr(w, "{d}", .{key.value[0]});
    w.writeByte('[') catch return error.OutOfMemory;
    var c: usize = 0;
    while (c < key.ncomp) : (c += 1) {
        if (c != 0) w.writeByte(' ') catch return error.OutOfMemory;
        try pr(w, "{d}", .{key.value[c]});
    }
    w.writeByte(']') catch return error.OutOfMemory;
}

/// A `(scene …)`'s `:name`, read out of its source text. The same reader
/// `doc/checks.zig` uses, restated here because the exporter is a
/// SECOND consumer of a `Doc` — one that may be handed a document the
/// bridge never saw (the edit engine builds them too).
fn sceneName(src: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, src, ":name") orelse return null;
    var i = at + ":name".len;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    if (i < src.len and src[i] == '"') {
        const start = i + 1;
        const close = std.mem.indexOfScalarPos(u8, src, start, '"') orelse return null;
        return if (close > start) src[start..close] else null;
    }
    const start = i;
    while (i < src.len and !std.ascii.isWhitespace(src[i]) and src[i] != ')') i += 1;
    return if (i > start) src[start..i] else null;
}

/// `Io.Writer.print` against an allocating sink: the only way it fails
/// is the allocator's way, and this module's error set says so.
fn pr(w: *Io.Writer, comptime fmt: []const u8, args: anytype) Error!void {
    w.print(fmt, args) catch return error.OutOfMemory;
}

// ---- tests ----
//
// `test_support` is imported HERE and not beside the other imports: the
// exporter consumes a `Doc` and a `Derived`, and the fixtures that build
// those out of a `Sequence` / a `Module` are the tests' business alone.

const support = @import("test_support.zig");

const q = Grid.TPQ;
const bar = 4 * Grid.TPQ;

test "score.exportScore: the native golden — plan 08's shape, line for line" {
    const gpa = testing.allocator;
    var fx = try support.native(gpa);
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{ .source_name = "native.sjon" });
    defer out.deinit();

    try testing.expectEqualStrings(
        \\; exported from native.sjon (conductor: none, 4 lanes, 2 sections) by tempura 0.1.0
        \\; positions: 0 rounded (max 0b), durations: 0 rounded (max 0b); onsets: 1 aggregated
        \\(transport :bpm 125 :meter [4 4] :dur 4bar :end loop)
        \\; cue "the drop" — bar 2
        \\(scene :name intro :at 0bar :dur 2bar)
        \\(scene :name drop  :at 2bar :dur 2bar)
        \\(trigger :target kick :at [0bar 1b 2bar 8.5b 3bar 12.5b])
        \\(track :target glow
        \\  (key :at 0bar :value 0.2 :ease hold)
        \\  (key :at 1bar :value 0.9 :ease in-cubic)
        \\  (key :at 2bar :value 0.1 :ease (spring :damping 0.5)))
        \\(track :target hats :pattern (euclid 3 8 1))
        \\(track :target pulse :expr (* beat 2))
        \\(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)
        \\(target :name kick :arity 4)
        \\(target :name kick-vel :arity 1)
        \\(target :name glow :arity 1)
        \\(target :name hats :arity 1)
        \\(target :name pulse :arity 1)
        \\(target :name glow-amt :arity 1)
        \\
    , out.text);
    try testing.expectEqual(@as(usize, 0), out.diags.items().len);
    try testing.expectEqual(@as(u32, 1), out.aggregated);
    try testing.expectEqual(@as(u32, 0), out.counter.rounded);
}

test "score.exportScore: --velocity writes a sibling -vel track with the loudest velocity" {
    const gpa = testing.allocator;
    var fx = try support.native(gpa);
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{
        .source_name = "native.sjon",
        .velocity = true,
    });
    defer out.deinit();

    // The chord's loudest onset is 110; `110 / 127` is the first key.
    try testing.expect(std.mem.indexOf(u8, out.text, "(track :target kick-vel\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "(key :at 0bar :value 0.86614174 :ease hold)") != null);
    // …and the quieter 96 of that same chord never appears.
    try testing.expect(std.mem.indexOf(u8, out.text, "0.7559055") == null);
    try testing.expect(std.mem.indexOf(u8, out.text, "(key :at 1b :value 0.503937 :ease hold)") != null);
}

test "score.exportScore: an SMF-conducted document names its conductor and takes its tempo" {
    const gpa = testing.allocator;
    var fx = try support.smfConducted(gpa);
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{ .source_name = "smf.sjon" });
    defer out.deinit();

    try testing.expectEqualStrings(
        \\; exported from smf.sjon (conductor: impulse.mid, 2 lanes, 0 sections) by tempura 0.1.0
        \\; positions: 0 rounded (max 0b), durations: 0 rounded (max 0b); onsets: 0 aggregated
        \\; curve keys: 5 → 5 within eps 0.007874016
        \\(transport :bpm 125 :meter [4 4] :dur 2bar :end hold)
        \\(tempo :at 1b :bpm 150)
        \\(trigger :target kick :at [0bar 0.5b])
        \\(track :target filter
        \\  (key :at 0bar :value 0 :ease hold)
        \\  (key :at 0.25b :value 0.2519685 :ease hold)
        \\  (key :at 0.5b :value 0.503937 :ease hold)
        \\  (key :at 0.75b :value 0.7559055 :ease hold)
        \\  (key :at 1b :value 1 :ease hold))
        \\(target :name kick :arity 4)
        \\(target :name kick-vel :arity 1)
        \\(target :name filter :arity 1)
        \\
    , out.text);
}

test "score.exportScore: an IT-conducted document's Txx rows become (tempo …) forms" {
    const gpa = testing.allocator;
    var fx = try support.itConducted(gpa);
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{ .source_name = "it.sjon" });
    defer out.deinit();

    // The module's three segments — 125, 150 and 200 quarter notes per
    // minute at ticks 0, 1q and 2q — are pacer's bpm under `[4 4]`.
    try testing.expect(std.mem.indexOf(u8, out.text, "(conductor: impulse-04.it,") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, ":bpm 125 :meter [4 4]") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "(tempo :at 1b :bpm 150)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "(tempo :at 2b :bpm 200)\n") != null);
    // …and the walk's own onsets are the bound lane's trigger: rows 0, 4,
    // 8 and 12 of a 16-row pattern at speed 6 are the four quarters.
    try testing.expect(std.mem.indexOf(u8, out.text, "(trigger :target bass :at [0bar 1b 2b 3b])\n") != null);
}

test "score.exportScore: adjacent equal tempi coalesce into one segment" {
    const gpa = testing.allocator;
    var fx = try synthetic(gpa, &.{
        .{ .tick = 0, .tempo = .{ .qpm = 120 } },
        .{ .tick = q, .tempo = .{ .qpm = 120 } },
        .{ .tick = 2 * q, .tempo = .{ .qpm = 140 } },
        .{ .tick = 3 * q, .tempo = .{ .qpm = 140 } },
    }, &.{.{ .tick = 0, .n = 4, .d = 4 }}, bar);
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.text, "(tempo :at"));
    try testing.expect(std.mem.indexOf(u8, out.text, "(tempo :at 2b :bpm 140)") != null);
}

test "score.exportScore: past 512 segments, tempo_eps coalesces — and failing that, seconds" {
    const gpa = testing.allocator;

    // 600 segments a thousandth of a bpm apart: under `tempo_eps` they
    // are one tempo, and the score keeps its beat positions.
    var near = try ramped(gpa, 600, 0.001);
    defer near.deinit();
    var coalesced = try exportScore(gpa, &near.doc, &near.derived, &.{}, .{});
    defer coalesced.deinit();
    try testing.expect(!coalesced.seconds_mode);
    try testing.expect(std.mem.count(u8, coalesced.text, "(tempo :at") <= 511);
    try testing.expectEqual(@as(usize, 0), coalesced.diags.count(.export_tempo_budget));

    // 600 segments a whole bpm apart: nothing coalesces, pacer's 512 is
    // out of reach, and the score falls back to `s` positions with a
    // warning (it 09's fallback).
    var wide = try ramped(gpa, 600, 1);
    defer wide.deinit();
    var seconds = try exportScore(gpa, &wide.doc, &wide.derived, &.{}, .{});
    defer seconds.deinit();
    try testing.expect(seconds.seconds_mode);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, seconds.text, "(tempo :at"));
    try testing.expectEqual(@as(usize, 1), seconds.diags.count(.export_tempo_budget));
    try testing.expect(std.mem.indexOf(u8, seconds.text, "(trigger :target hit :at [0s ") != null);

    // Every `s` position floors back onto the tick the exporter claims,
    // through pacer's degenerate seconds path — the same property the
    // beat positions have, checked here in pacer's op order and through
    // the real `pacer.wasm` by the node landing proof.
    const tps = pos.ticksPerSecond(pos.pacerBpm(100, 4), 4);
    try testing.expectEqual(@as(usize, 1), seconds.landings.len);
    for (seconds.landings[0].ticks, 0..) |tick, i| {
        const text = try nthPosition(seconds.text, "(trigger :target hit :at [", i);
        try testing.expect(std.mem.endsWith(u8, text, "s"));
        const secs = try std.fmt.parseFloat(f64, text[0 .. text.len - 1]);
        try testing.expectEqual(tick, pos.pacerFloor(secs, tps));
    }
    // …and they are strictly ascending, which is what keeps pacer from
    // refusing the list (`trigger_invalid`).
    for (seconds.landings[0].ticks[1..], seconds.landings[0].ticks[0 .. seconds.landings[0].ticks.len - 1]) |next, prev|
        try testing.expect(next > prev);
}

test "score.exportScore: in seconds mode a scene's :dur is its OWN span, not the seconds from zero" {
    const gpa = testing.allocator;
    // The 512 fallback over a tempo that doubles at bar 1: a scene on
    // the second bar lasts half as long in seconds as one on the first,
    // and a `:dur` measured from tick 0 would print the first's.
    var fx = try support.slideConducted(gpa);
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{});
    defer out.deinit();
    try testing.expect(out.seconds_mode);

    const one = try nthValue(out.text, "(scene :name one :at ", 1);
    const two = try nthValue(out.text, "(scene :name two :at ", 1);
    try testing.expect(!std.mem.eql(u8, one, two));
    // The second window is the shorter one: the piece is accelerating.
    const one_secs = try std.fmt.parseFloat(f64, one[0 .. one.len - 1]);
    const two_secs = try std.fmt.parseFloat(f64, two[0 .. two.len - 1]);
    try testing.expect(two_secs < one_secs);
    // And `:at` of the second scene is where the first one ends.
    const two_at = try nthValue(out.text, "(scene :name two :at ", 0);
    try testing.expectEqualStrings(one, two_at[0..two_at.len]);
}

test "score.exportScore: a meter pacer cannot carry falls back to [4 4] over quarters" {
    const gpa = testing.allocator;
    // `d = 32` is tempura's grid and past pacer's `meter-component` 16.
    var fx = try synthetic(
        gpa,
        &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }},
        &.{.{ .tick = 0, .n = 5, .d = 32 }},
        4 * q,
    );
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.export_meter_unsupported));
    try testing.expectEqual(Diag.Severity.warning, out.diags.items()[0].severity);
    try testing.expectEqual([2]u8{ 4, 4 }, out.meter);
    try testing.expect(std.mem.indexOf(u8, out.text, ":meter [4 4]") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "; warning: ") != null);
    // A quarter is one pacer beat under the fallback, so the positions
    // stay exact whatever the document's own meter was.
    try testing.expect(std.mem.indexOf(u8, out.text, "(trigger :target hit :at [0bar 1b 2b 3b])") != null);
}

test "score.exportScore: a meter CHANGE keeps pacer's first meter and says so" {
    const gpa = testing.allocator;
    var fx = try synthetic(gpa, &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }}, &.{
        .{ .tick = 0, .n = 4, .d = 4 },
        .{ .tick = bar, .n = 3, .d = 4 },
    }, 2 * bar);
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.export_meter_unsupported));
    try testing.expect(std.mem.indexOf(u8, out.text, "; warning: meter changes to [3 4] at bar 1") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, ":meter [4 4]") != null);
}

test "score.exportScore: export_bpm_out_of_range — :qpm 600 in [12 8] is 1200 pacer bpm" {
    const gpa = testing.allocator;
    var fx = try synthetic(
        gpa,
        &.{.{ .tick = 0, .tempo = .{ .qpm = 600 } }},
        &.{.{ .tick = 0, .n = 12, .d = 8 }},
        6 * q,
    );
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.export_bpm_out_of_range));
    try testing.expect(out.diags.hasErrors());
    try testing.expect(std.mem.indexOf(u8, out.text, "; error: ") != null);
}

test "score.exportScore: qpm · d / 4 — a [6 8] document's eighth is pacer's beat" {
    const gpa = testing.allocator;
    var fx = try synthetic(
        gpa,
        &.{.{ .tick = 0, .tempo = .{ .qpm = 125 } }},
        &.{.{ .tick = 0, .n = 6, .d = 8 }},
        3 * q,
    );
    defer fx.deinit();

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{});
    defer out.deinit();
    // Twice the quarter rate, never half it: midi 05 wrote the factor
    // inverted and plan 08 pins the direction.
    try testing.expect(std.mem.indexOf(u8, out.text, "(transport :bpm 250 :meter [6 8]") != null);
    try testing.expectEqual(@as(usize, 0), out.diags.count(.export_bpm_out_of_range));
}

test "score.exportScore: scene_duplicate and passthrough_conducts are the door's own guard" {
    const gpa = testing.allocator;
    var fx = try synthetic(gpa, &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }}, &.{.{ .tick = 0, .n = 4, .d = 4 }}, bar);
    defer fx.deinit();

    const a = fx.doc.arena.allocator();
    const sections = try a.alloc(doc.Section, 1);
    sections[0] = .{ .name = "intro", .at = 0, .dur = bar, .span = .{ .start = 0, .end = 1 } };
    fx.doc.sections = sections;

    const through = try a.alloc(doc.Passthrough, 3);
    through[0] = .{ .head = "scene", .text = "(scene :name intro :at 0b :dur 4b)", .comments = &.{}, .span = .{ .start = 0, .end = 1 } };
    through[1] = .{ .head = "transport", .text = "(transport :bpm 90 :meter [4 4])", .comments = &.{}, .span = .{ .start = 0, .end = 1 } };
    through[2] = .{ .head = "target", .text = "(target :name hit :arity 4)", .comments = &.{}, .span = .{ .start = 0, .end = 1 } };
    fx.doc.passthrough = through;
    try reDerive(&fx);

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.scene_duplicate));
    try testing.expectEqual(@as(usize, 1), out.diags.count(.passthrough_conducts));
    // Neither colliding root is printed: a score with two transports, or
    // two scenes of one name, is one pacer refuses outright.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.text, "(scene :name intro"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.text, "(transport :bpm"));
    // Everything else passes through, verbatim.
    try testing.expect(std.mem.indexOf(u8, out.text, "(target :name hit :arity 4)") != null);
}

test "score.exportScore: a pass-through root keeps its comments, above it, in order" {
    const gpa = testing.allocator;
    var fx = try synthetic(gpa, &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }}, &.{.{ .tick = 0, .n = 4, .d = 4 }}, bar);
    defer fx.deinit();

    const a = fx.doc.arena.allocator();
    const comments = try a.alloc([]const u8, 2);
    comments[0] = "; the knob the piece is played with";
    comments[1] = "; pinned, so it is text";
    const through = try a.alloc(doc.Passthrough, 1);
    through[0] = .{
        .head = "control",
        .text = "(control :id amt :type slider :min 0 :max 1 :value 0.5)",
        .comments = comments,
        .span = .{ .start = 0, .end = 1 },
    };
    fx.doc.passthrough = through;

    var out = try exportScore(gpa, &fx.doc, &fx.derived, &.{}, .{});
    defer out.deinit();
    try testing.expect(std.mem.indexOf(u8, out.text,
        \\; the knob the piece is played with
        \\; pinned, so it is text
        \\(control :id amt :type slider :min 0 :max 1 :value 0.5)
    ) != null);
}

test "score.exportScore: the two budget warnings, past 1 000 onsets and past max-keys-per-track" {
    const gpa = testing.allocator;

    var many = try synthetic(gpa, &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }}, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 1024 * q);
    defer many.deinit();
    try addNotes(&many, 1001);
    var onsets = try exportScore(gpa, &many.doc, &many.derived, &.{}, .{});
    defer onsets.deinit();
    try testing.expectEqual(@as(usize, 1), onsets.diags.count(.export_onset_budget));

    var keys = try synthetic(gpa, &.{.{ .tick = 0, .tempo = .{ .qpm = 120 } }}, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 1024 * q);
    defer keys.deinit();
    try addKeyframes(&keys, 600);
    var curve = try exportScore(gpa, &keys.doc, &keys.derived, &.{}, .{});
    defer curve.deinit();
    try testing.expectEqual(@as(usize, 1), curve.diags.count(.export_key_budget));
    // A native lane is never simplified, so every one of them is printed
    // and the warning is the only thing the budget does about it.
    try testing.expectEqual(@as(usize, 600), std.mem.count(u8, curve.text, "(key :at "));
}

// ---- test fixtures ----

/// A document whose time is its own, with one `hit` notes lane on the
/// quarters of its first bar — enough for every position in the score to
/// come from somewhere.
fn synthetic(
    gpa: std.mem.Allocator,
    tempo: []const TimeMap.TempoPoint,
    meter: []const TimeMap.MeterPoint,
    length: i64,
) !support.Fixture {
    var d: doc.Doc = .empty(gpa);
    errdefer d.deinit();
    const a = d.arena.allocator();

    d.tempo = try a.dupe(TimeMap.TempoPoint, tempo);
    d.meter = try a.dupe(TimeMap.MeterPoint, meter);
    d.length = length;

    const notes = try a.alloc(doc.Note, 4);
    for (notes, 0..) |*n, i| n.* = .{
        .at = @as(i64, @intCast(i)) * q,
        .dur = @divExact(q, 2),
        .key = 36,
        .vel = 100,
        .ch = 0,
        .off_vel = null,
        .span = .{ .start = 0, .end = 1 },
    };
    const lane_list = try a.alloc(doc.Lane, 1);
    lane_list[0] = .{
        .name = "hit",
        .kind = .notes,
        .target = "hit",
        .range = null,
        .binding = null,
        .notes = notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = .{ .start = 0, .end = 1 },
    };
    d.lanes = lane_list;

    const derived = try derive.derive(gpa, &d);
    return .{ .doc = d, .derived = derived };
}

/// The `i`-th whitespace-separated token of the list that follows
/// `prefix` in `text`.
fn nthPosition(text: []const u8, prefix: []const u8, i: usize) ![]const u8 {
    const at = std.mem.indexOf(u8, text, prefix) orelse return error.PrefixNotFound;
    var rest = text[at + prefix.len ..];
    rest = rest[0 .. std.mem.indexOfScalar(u8, rest, ']') orelse rest.len];
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    var seen: usize = 0;
    while (it.next()) |tok| : (seen += 1) {
        if (seen == i) return tok;
    }
    return error.PositionNotFound;
}

/// The `i`-th whitespace-separated token after `prefix` on its line —
/// `nthValue(text, "(scene :name two :at ", 1)` is that scene's `:dur`
/// value, two tokens on (`:dur` itself is token 1... hence the `:dur `
/// skip below).
fn nthValue(text: []const u8, prefix: []const u8, i: usize) ![]const u8 {
    const at = std.mem.indexOf(u8, text, prefix) orelse return error.PrefixNotFound;
    var rest = text[at + prefix.len ..];
    rest = rest[0 .. std.mem.indexOfScalar(u8, rest, ')') orelse rest.len];
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    var seen: usize = 0;
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, ":dur")) continue;
        if (seen == i) return tok;
        seen += 1;
    }
    return error.ValueNotFound;
}

/// `count` tempo segments, `step` bpm apart — the per-tick slide plan 08
/// names as the case the 512 budget exists for.
fn ramped(gpa: std.mem.Allocator, count: usize, step: f64) !support.Fixture {
    var points = std.ArrayList(TimeMap.TempoPoint).empty;
    defer points.deinit(gpa);
    for (0..count) |i| try points.append(gpa, .{
        .tick = @as(i64, @intCast(i)) * @divExact(q, 16),
        .tempo = .{ .qpm = 100 + @as(f64, @floatFromInt(i)) * step },
    });
    return synthetic(gpa, points.items, &.{.{ .tick = 0, .n = 4, .d = 4 }}, 1024 * q);
}

/// Replace the fixture's lane with `n` onsets, one per 32nd, and
/// re-derive.
fn addNotes(fx: *support.Fixture, n: usize) !void {
    const a = fx.doc.arena.allocator();
    const notes = try a.alloc(doc.Note, n);
    for (notes, 0..) |*note, i| note.* = .{
        .at = @as(i64, @intCast(i)) * @divExact(q, 4),
        .dur = @divExact(q, 8),
        .key = 36,
        .vel = 100,
        .ch = 0,
        .off_vel = null,
        .span = .{ .start = 0, .end = 1 },
    };
    fx.doc.lanes[0].notes = notes;
    try reDerive(fx);
}

/// Replace the fixture's lane with a native curve of `n` keyframes.
fn addKeyframes(fx: *support.Fixture, n: usize) !void {
    const a = fx.doc.arena.allocator();
    const keys = try a.alloc(doc.Keyframe, n);
    for (keys, 0..) |*key, i| key.* = .{
        .at = @as(i64, @intCast(i)) * @divExact(q, 4),
        .value = .{ @as(f32, @floatFromInt(i % 97)) / 97.0, 0, 0, 0 },
        .ncomp = 1,
        .ease_src = "linear",
        .span = .{ .start = 0, .end = 1 },
    };
    fx.doc.lanes[0].kind = .curve;
    fx.doc.lanes[0].notes = &.{};
    fx.doc.lanes[0].keyframes = keys;
    try reDerive(fx);
}

fn reDerive(fx: *support.Fixture) !void {
    const gpa = fx.derived.arena.child_allocator;
    fx.derived.deinit();
    fx.derived = try derive.derive(gpa, &fx.doc);
}
