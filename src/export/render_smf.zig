//! `renderSmf` — a native timeline as a Standard MIDI File (plan 08,
//! "Rendering to `.mid`").
//!
//! The DAW's view of a document. Track 0 is the conductor — `set-tempo`
//! from the tempo points (`:us` verbatim, `:qpm` → `round(60e6 / qpm)`),
//! `time-signature` from the meter points, a `marker` per cue and, with
//! `section_markers`, one per section start. Then one `MTrk` per native
//! lane, named by the lane, with a lane record describing what was
//! written there:
//!
//!   * `notes` → `note-on` / `note-off` pairs on the note's own `:ch`
//!     with its own `:off-vel`, at `k · PPQ / TPQ`, exact iff the
//!     division divides the tick and counted in `render_inexact`
//!     otherwise; clips already expanded by `time/derive.zig`;
//!   * `curve` → `control-change` on `opts.cc`, the value
//!     `round((v − lo) / (hi − lo) · 127)` under the lane's `:range`;
//!     one event per keyframe for `hold`, one event per `cc_rate` for a
//!     `linear` segment, and **every other easing as its keyframes
//!     only** — tempura never evaluates a named curve (plan 00's
//!     non-goal), so the DAW hears the steps and the essence restores
//!     the shape. Each such segment goes in the lane record;
//!   * `query`, `formula` → nothing at all, `residue_only`.
//!
//! **What the rendered events ARE.** A view (plan 04, "One home"): the
//! essence is the truth and these events are how a DAW hears it. The
//! lane record's hash is over exactly what this function wrote, at the
//! address it wrote it to, in tempura ticks — so a `dump` can tell
//! tempura's own rendering from a DAW's edit of it. This module therefore
//! never writes a record it did not also write the events for.
//!
//! A hash is over a `(track, ch)` PAIR (`residue/records.zig`,
//! `hashSmfLane`), and a lane's notes may name several channels. So a
//! lane writes **one record per channel it used**, all naming the same
//! track and the same lane: between them they cover every channel of the
//! track, which is every event this renderer put there, and
//! `reconcile`'s "any record of this lane is stale ⇒ the lane binds"
//! rule then means a DAW edit to any of the lane's channels is caught.
//! A lane that placed nothing still gets one record, at channel 0, so
//! that its emptiness is hashed too.
//!
//! **Into an anchor.** With `base`, the anchor's own tracks are kept and
//! the lanes' tracks are APPENDED, so `build` of a dumped `.mid` with an
//! added native lane is the original file plus tracks. A bound lane is
//! the anchor's own content and is not rendered again. A format 0 anchor
//! has one track by definition: appending promotes it to format 1 with
//! `render_format_promoted`, unless `opts.format0` puts everything on the
//! one track instead (plan 05's writer option, decided HERE so the lane
//! records' addresses describe the file that is written).
//!
//! **Onto the track a dump left empty.** A dump of a file this renderer
//! wrote CONSUMES each restored lane's events (plan 04, rule 2;
//! `residue/reconcile.zig`, "The consumption") and keeps the track, so
//! the tier's track numbers hold: what is left is a track holding
//! nothing but the lane's own `sequence-name`. Such a track is the
//! lane's, and the lane renders ONTO it rather than beside it — the
//! first unclaimed one of its name, in file order — so a document built,
//! dumped and built again has one track per lane and the same track
//! numbers each time, instead of gaining an empty named track per
//! rebuild. A base track that holds anything else is the anchor's own
//! and is never rendered onto.
//!
//! **Three things this layer cannot know.**
//!
//!   1. A native curve lane's controller number. `:cc` is a BOUND lane's
//!      key — `doc/fromSjon.zig` records it inside a `Binding` and a
//!      native lane has none — so the number comes from `opts.cc`
//!      (`--cc`) and a curve with neither is `render_cc_missing`, its
//!      content left to the essence.
//!   2. A note with no `:off-vel` has no release velocity to write, so
//!      it gets 64 — the value every sequencer writes for a note off
//!      with nothing to say. A note that HAS one keeps it.
//!
//! Both are LOSSES OF THE VIEW and none of the document: the essence
//! carries the lane verbatim and `dump` restores it.

const std = @import("std");

const Diag = @import("../Diag.zig");
const Doc = @import("../doc/Value.zig");
const Grid = @import("../time/Grid.zig");
const derive = @import("../time/derive.zig");
const Sequence = @import("../smf/Sequence.zig");
const records = @import("../residue/records.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Rendering can only fail the way any allocation fails. Everything a
/// DOCUMENT cannot say in a `.mid` is a diagnostic on the returned value.
pub const Error = error{OutOfMemory};

/// A 32nd note in tempura ticks — the default `--cc-rate`.
pub const default_cc_rate: i64 = @divExact(Grid.TPQ, 8);

/// The default division, plan 08's `--ppq`.
pub const default_ppq: u15 = 960;

/// The release velocity every rendered note off carries (see the header).
pub const off_velocity: u7 = 64;

pub const Options = struct {
    /// `--ppq`. Ignored when `base` is given: an anchor's events are
    /// already on its own division and rescaling them is the writer's
    /// `--ppq`, not the renderer's.
    ppq: u15 = default_ppq,
    /// `--cc`: which controller a native curve lane renders onto.
    cc: ?u7 = null,
    /// `--cc-rate`: how often a `linear` segment is sampled.
    cc_rate: i64 = default_cc_rate,
    /// `--section-markers`: one `marker` per section start as well.
    section_markers: bool = false,
    /// `--format 0`: everything on the one track, rather than a track
    /// per lane.
    format0: bool = false,
};

/// A rendered sequence, the records that describe it, and the report.
///
/// `arena` owns every record's name and segments; `seq` owns its own
/// pool, as every `Sequence` does.
pub const Result = struct {
    seq: Sequence.Sequence,
    /// One per rendered native lane, in document order.
    lanes: []const records.LaneRecord,
    /// The file's whole timing context, hashed — present exactly when
    /// the DOCUMENT conducts (plan 04: a conducted document's conductor
    /// is the anchor's own and there is nothing to record).
    conductor: ?records.ConductorRecord,
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        self.diags.deinit();
        self.seq.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Render `doc` into a `Sequence`, into `base` when there is one.
pub fn renderSmf(
    gpa: Allocator,
    doc: *const Doc.Doc,
    derived: *const derive.Derived,
    base: ?*const Sequence.Sequence,
    opts: Options,
) Error!Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var r: Render = .{
        .gpa = gpa,
        .a = arena.allocator(),
        .doc = doc,
        .derived = derived,
        .base = base,
        .opts = opts,
        .diags = &diags,
        .ppq = if (base) |b| b.division.pulsesPerQuarter() else opts.ppq,
    };

    var seq = try r.run();
    errdefer seq.deinit();

    // The hashes come LAST and from the sequence itself: a record says
    // "these are the events tempura wrote at this address", and the only
    // way to mean it is to hash what was written.
    for (r.lanes.items) |*rec| {
        const address = rec.address.smf;
        rec.hash = records.hashSmfLane(&seq, address.track - 1, address.ch.first(), r.ppq);
    }
    const conductor: ?records.ConductorRecord = if (doc.conductor == null)
        .{ .hash = records.hashSmfConductor(&seq) }
    else
        null;

    return .{
        .seq = seq,
        .lanes = r.lanes.items,
        .conductor = conductor,
        .diags = diags,
        .arena = arena,
    };
}

// ---------------------------------------------------------------------
// The render
// ---------------------------------------------------------------------

const Render = struct {
    gpa: Allocator,
    /// The result's arena: every record's name and segments.
    a: Allocator,
    doc: *const Doc.Doc,
    derived: *const derive.Derived,
    base: ?*const Sequence.Sequence,
    opts: Options,
    diags: *Diag.List,
    ppq: u15,
    lanes: std.ArrayList(records.LaneRecord) = .empty,

    fn run(self: *Render) Error!Sequence.Sequence {
        var b: Sequence.Builder = .init(self.gpa);
        errdefer b.deinit();
        b.division = .{ .ppq = self.ppq };

        // Which lanes get a track of their own, decided before any track
        // exists: the format 0 promotion depends on the answer. A lane
        // whose track a dump left empty for it (the header, "Onto the
        // track a dump left empty") is not a new track.
        var renderable: std.ArrayList(usize) = .empty;
        defer renderable.deinit(self.gpa);
        var ghosts: std.ArrayList(?u32) = .empty;
        defer ghosts.deinit(self.gpa);
        for (self.doc.lanes, 0..) |*lane, i| {
            if (!try self.renders(lane)) continue;
            try renderable.append(self.gpa, i);
            try ghosts.append(self.gpa, self.ghostTrack(lane.name, ghosts.items));
        }
        var new_tracks: usize = 0;
        for (ghosts.items) |g| {
            if (g == null) new_tracks += 1;
        }

        b.format = try self.formatFor(new_tracks);

        // Track 0 — the conductor track, and in a format 0 file the only
        // one. A base's tracks come across verbatim; the events this
        // function adds to track 0 go BEFORE them, which is where a
        // stable sort by tick leaves them and where the residue's own
        // payloads will sit (plan 04, "The SMF carrier"). A track a lane
        // is about to render onto loses its `end-of-track` on the way:
        // the writer places one after the last event, and the one the
        // dump left would sit in the middle (`end_of_track_early`).
        const track0 = try b.addTrack();
        try self.conductorTrack(&b, track0);
        if (self.base) |src| {
            if (src.tracks.len > 0) {
                for (src.tracks[0].events) |e| try copyEvent(&b, src, e, track0);
            }
            var ti: usize = 1;
            while (ti < src.tracks.len) : (ti += 1) {
                const track = try b.addTrack();
                const claimed = std.mem.indexOfScalar(?u32, ghosts.items, track) != null;
                for (src.tracks[ti].events) |e| {
                    if (claimed and e.kind == .end_of_track) continue;
                    try copyEvent(&b, src, e, track);
                }
            }
            for (src.foreign) |chunk| {
                try b.addForeign(chunk.tag, try b.addBytes(src.bytesOf(chunk.bytes)));
            }
        }

        for (renderable.items, ghosts.items) |i, ghost| {
            const lane = &self.doc.lanes[i];
            const track: u32 = if (self.opts.format0) track0 else ghost orelse blk: {
                const t = try b.addTrack();
                try b.addEvent(t, 0, .sequence_name, .{ .bytes = try b.addBytes(lane.name) });
                break :blk t;
            };
            switch (lane.kind) {
                .notes => try self.notesLane(&b, track, lane, &self.derived.lanes[i]),
                .curve => try self.curveLane(&b, track, lane, &self.derived.lanes[i]),
                .query, .formula => unreachable,
            }
        }

        return b.finish();
    }

    /// The base track a dump left empty for `name` — one whose every
    /// event is either the one `sequence-name` spelling `name` or an
    /// `end-of-track` — as the BUILDER will number it (a base's track
    /// `ti` becomes track `ti`, because track 0 is merged and the rest
    /// are added in order). The first such track in file order that no
    /// earlier lane has claimed, or null.
    fn ghostTrack(self: *Render, name: []const u8, claimed: []const ?u32) ?u32 {
        const src = self.base orelse return null;
        var ti: usize = 1;
        while (ti < src.tracks.len) : (ti += 1) {
            const t: u32 = @intCast(ti);
            if (std.mem.indexOfScalar(?u32, claimed, t) != null) continue;
            var named = false;
            var other = false;
            for (src.tracks[ti].events) |e| switch (e.kind) {
                .sequence_name => {
                    if (named or !std.mem.eql(u8, src.bytesOf(e.payload.bytes), name)) {
                        other = true;
                    } else named = true;
                },
                .end_of_track => {},
                else => other = true,
            };
            if (named and !other) return t;
        }
        return null;
    }

    /// Whether this lane becomes native events, and the diagnostic for
    /// every lane that does not.
    fn renders(self: *Render, lane: *const Doc.Lane) Error!bool {
        // Bound content has one home and it is the anchor's own tracks
        // (plan 04, "One home"): rendering it again would write the
        // file's music twice.
        if (lane.binding != null) return false;
        switch (lane.kind) {
            .notes => return true,
            .curve => {
                if (self.opts.cc != null) return true;
                try self.diags.add(
                    .render_cc_missing,
                    .warning,
                    lane.span,
                    "the curve lane '{s}' has no controller to render onto (--cc), so its keyframes ride in the residue alone and no DAW will hear them",
                    .{lane.name},
                );
                return false;
            },
            .query, .formula => {
                try self.diags.add(
                    .residue_only,
                    .warning,
                    lane.span,
                    "the {t} lane '{s}' is computed, and a .mid holds no query or formula: it rides in the residue alone",
                    .{ lane.kind, lane.name },
                );
                return false;
            },
        }
    }

    /// The header's `format`, and the promotion a format 0 anchor needs.
    fn formatFor(self: *Render, new_tracks: usize) Error!u8 {
        const src = self.base orelse return if (self.opts.format0) 0 else 1;
        if (src.format != 0 or new_tracks == 0 or self.opts.format0) return src.format;
        try self.diags.add(
            .render_format_promoted,
            .warning,
            .{ .start = 0, .end = 0 },
            "this anchor is a format 0 file and a format 0 file has one track; the {d} lane track(s) rendered into it promote it to format 1",
            .{new_tracks},
        );
        return 1;
    }

    // ---- the conductor ----

    /// `set-tempo`, `time-signature` and the markers — but only for a
    /// document that conducts ITSELF. A `:conductor` names the anchor as
    /// the owner of time (plan 03), and its tempo, meter and markers are
    /// already in the file this renders into; writing them again would
    /// be the same map, said twice, in a file that has one.
    fn conductorTrack(self: *Render, b: *Sequence.Builder, track: u32) Error!void {
        if (self.doc.conductor != null) return;

        var off_grid: usize = 0;
        for (self.doc.meter) |m| {
            if (m.d == 0 or !std.math.isPowerOfTwo(m.d)) continue;
            const at = self.pulse(m.tick, &off_grid);
            try b.addEvent(track, at, .time_signature, .{ .time_sig = .{
                .nn = m.n,
                .dd = @intCast(std.math.log2_int(u8, m.d)),
                .cc = 24,
                .bb = 8,
            } });
        }
        for (self.doc.tempo) |t| {
            const at = self.pulse(t.tick, &off_grid);
            try b.addEvent(track, at, .set_tempo, .{ .tempo = microseconds(t) });
        }
        if (self.opts.section_markers) {
            for (self.derived.sections) |s| {
                const at = self.pulse(s.at, &off_grid);
                try b.addEvent(track, at, .marker, .{ .bytes = try b.addBytes(s.name) });
            }
        }
        for (self.derived.cues) |c| {
            const at = self.pulse(c.at, &off_grid);
            try b.addEvent(track, at, .marker, .{ .bytes = try b.addBytes(c.name) });
        }
        if (off_grid > 0) try self.rounded("the conductor track", off_grid);
    }

    // ---- a notes lane ----

    fn notesLane(
        self: *Render,
        b: *Sequence.Builder,
        track: u32,
        lane: *const Doc.Lane,
        index: *const derive.LaneIndex,
    ) Error!void {
        var pairs: std.ArrayList(NoteEvent) = .empty;
        defer pairs.deinit(self.gpa);
        var off_grid: usize = 0;
        // Which channels this lane wrote to — one lane record each, so
        // that every event on the track is inside some hash.
        var used: [16]bool = @splat(false);

        for (index.onsets, 0..) |o, i| {
            const on = self.pulse(o.tick, &off_grid);
            const off = self.pulse(o.tick +| @max(o.dur, 0), &off_grid);
            used[o.ch] = true;
            try pairs.append(self.gpa, .{
                .at = on,
                .off = false,
                .ch = o.ch,
                .key = o.key,
                .vel = o.vel,
                .seq = @intCast(i),
            });
            // A zero-length note still ends: one pulse later would move
            // it, so the off sits on the on's own tick and the writer's
            // stable sort puts it after — which is the only reading a
            // sequencer has for a note that starts and stops at once.
            try pairs.append(self.gpa, .{
                .at = @max(off, on),
                .off = true,
                .ch = o.ch,
                .key = o.key,
                .vel = o.off_vel orelse off_velocity,
                .seq = @intCast(i),
            });
        }
        std.mem.sort(NoteEvent, pairs.items, {}, noteBefore);
        for (pairs.items) |e| try b.addEvent(
            track,
            e.at,
            if (e.off) .note_off else .note_on,
            .{ .note = .{ .ch = e.ch, .key = e.key, .vel = e.vel } },
        );
        if (off_grid > 0) try self.rounded(lane.name, off_grid);

        var any = false;
        for (used, 0..) |touched, ch| {
            if (!touched) continue;
            any = true;
            try self.noteRecord(lane, track, @intCast(ch));
        }
        // A lane that placed nothing is still a lane, and its emptiness
        // is worth hashing: one record, at channel 0.
        if (!any) try self.noteRecord(lane, track, 0);
    }

    fn noteRecord(self: *Render, lane: *const Doc.Lane, track: u32, ch: u4) Error!void {
        try self.lanes.append(self.a, .{
            .lane = try self.a.dupe(u8, lane.name),
            .address = .{ .smf = .{
                .track = @intCast(track + 1),
                .ch = .single(ch),
                .key = null,
                .curve = null,
            } },
            .hash = @splat(0),
        });
    }

    // ---- a curve lane ----

    fn curveLane(
        self: *Render,
        b: *Sequence.Builder,
        track: u32,
        lane: *const Doc.Lane,
        index: *const derive.LaneIndex,
    ) Error!void {
        const num = self.opts.cc.?;
        const range = lane.range orelse [2]f32{ 0, 1 };
        const rate = @max(self.opts.cc_rate, 1);

        var steps_only: std.ArrayList(records.Segment) = .empty;
        var off_grid: usize = 0;

        for (index.steps, 0..) |step, i| {
            if (i > 0) {
                const prev = index.steps[i - 1];
                // pacer's semantics: a keyframe's `:ease` shapes the
                // segment ENDING at it (plan 02). `hold` is exactly the
                // stair two events make, `linear` is sampled, and every
                // other easing is the two endpoints and a note in the
                // record — tempura does not evaluate a named curve.
                if (std.mem.eql(u8, step.ease_src, "linear")) {
                    try self.ramp(b, track, num, range, prev, step, rate, &off_grid);
                } else if (!std.mem.eql(u8, step.ease_src, "hold")) {
                    try steps_only.append(self.a, .{
                        .at = step.tick,
                        .ease = try self.a.dupe(u8, step.ease_src),
                    });
                }
            }
            try b.addEvent(track, self.pulse(step.tick, &off_grid), .control_change, .{
                .control = .{ .ch = 0, .num = num, .val = value7(step.value[0], range) },
            });
        }
        if (off_grid > 0) try self.rounded(lane.name, off_grid);

        try self.lanes.append(self.a, .{
            .lane = try self.a.dupe(u8, lane.name),
            .address = .{ .smf = .{
                .track = @intCast(track + 1),
                .ch = .single(0),
                .key = null,
                .curve = .{ .cc = num },
            } },
            .hash = @splat(0),
            .steps_only = steps_only.items,
        });
    }

    /// One `linear` segment, sampled every `rate` ticks strictly between
    /// its endpoints. The line is computed in ticks (exact integers) and
    /// f64, and rounded ONCE, at the controller byte.
    fn ramp(
        self: *Render,
        b: *Sequence.Builder,
        track: u32,
        num: u7,
        range: [2]f32,
        from: derive.Step,
        to: derive.Step,
        rate: i64,
        off_grid: *usize,
    ) Error!void {
        const span = to.tick - from.tick;
        if (span <= 0) return;
        const v0: f64 = from.value[0];
        const v1: f64 = to.value[0];

        var at = from.tick + rate;
        while (at < to.tick) : (at += rate) {
            const u = @as(f64, @floatFromInt(at - from.tick)) / @as(f64, @floatFromInt(span));
            const v = v0 + (v1 - v0) * u;
            try b.addEvent(track, self.pulse(at, off_grid), .control_change, .{
                .control = .{ .ch = 0, .num = num, .val = value7f(v, range) },
            });
        }
    }

    // ---- shared ----

    /// A tempura tick as an SMF pulse, counting the ones that do not
    /// land.
    fn pulse(self: *Render, tick: i64, off_grid: *usize) i64 {
        const p = toPulse(tick, self.ppq);
        if (!p.exact) off_grid.* += 1;
        return p.at;
    }

    fn rounded(self: *Render, what: []const u8, n: usize) Error!void {
        try self.diags.add(
            .render_inexact,
            .warning,
            .{ .start = 0, .end = 0 },
            "{d} position(s) of '{s}' do not land on division {d} and were written to the nearest pulse",
            .{ n, what, self.ppq },
        );
    }
};

/// One end of a rendered note, before the pairs are ordered.
const NoteEvent = struct { at: i64, off: bool, ch: u4, key: u7, vel: u7, seq: u32 };

/// Offs before ons at one pulse, then the onset's own order — so a
/// re-struck key is released before it sounds again, which is what keeps
/// a rendering free of the `note_retrigger` a reader would otherwise
/// report about it.
fn noteBefore(_: void, x: NoteEvent, y: NoteEvent) bool {
    if (x.at != y.at) return x.at < y.at;
    if (x.off != y.off) return x.off;
    return x.seq < y.seq;
}

/// One tempura tick on an SMF division: `k · PPQ / TPQ`, exact when the
/// division divides it and the NEAREST pulse otherwise, ties to the even
/// one — `Grid.smfToTicks`'s rule, read the other way round.
///
/// The product runs in `i128`: a tick at the grid ceiling times a 15-bit
/// division is past `i64`, and a renderer must answer rather than wrap.
fn toPulse(tick: i64, ppq: u15) struct { at: i64, exact: bool } {
    if (ppq == 0) return .{ .at = 0, .exact = false };
    const num: i128 = @as(i128, tick) * @as(i128, ppq);
    const den: i128 = Grid.TPQ;

    const whole = @divFloor(num, den);
    const rem = num - whole * den;
    if (rem == 0) return .{ .at = @intCast(whole), .exact = true };

    const twice = 2 * rem;
    const up = if (twice > den)
        true
    else if (twice < den)
        false
    else
        @rem(whole, 2) != 0;
    return .{ .at = @intCast(if (up) whole + 1 else whole), .exact = false };
}

/// A tempo point as microseconds per quarter note: `:us` verbatim, and
/// `:qpm` as `round(60e6 / qpm)` (plan 08).
fn microseconds(point: Doc.TempoPoint) u32 {
    return switch (point.tempo) {
        .us => |us| us,
        .qpm => |qpm| blk: {
            if (!(qpm > 0)) break :blk 500_000;
            const us = @round(60_000_000.0 / qpm);
            if (!(us >= 1)) break :blk 1;
            if (us > @as(f64, std.math.maxInt(u32))) break :blk std.math.maxInt(u32);
            break :blk @intFromFloat(us);
        },
    };
}

/// `round((v − lo) / (hi − lo) · 127)`, clamped to the controller's
/// domain. A degenerate `:range` (`hi == lo`) has no scale and answers 0.
fn value7(v: f32, range: [2]f32) u7 {
    return value7f(v, range);
}

fn value7f(v: f64, range: [2]f32) u7 {
    const lo: f64 = range[0];
    const hi: f64 = range[1];
    if (hi == lo or !std.math.isFinite(lo) or !std.math.isFinite(hi)) return 0;
    if (!std.math.isFinite(v)) return 0;
    const scaled = @round((v - lo) / (hi - lo) * 127.0);
    if (!(scaled > 0)) return 0;
    if (scaled >= 127) return 127;
    return @intFromFloat(scaled);
}

/// One event from `src` into `b`, pool bytes and all — the same copy
/// `residue/smf.zig` makes, for the same reason: a `Bytes` is an offset
/// into the sequence that owns it.
fn copyEvent(
    b: *Sequence.Builder,
    src: *const Sequence.Sequence,
    e: Sequence.Event,
    track: u32,
) Error!void {
    var payload = e.payload;
    if (e.payload.poolBytes(e.kind)) |run| {
        const copied = try b.addBytes(src.bytesOf(run));
        switch (e.kind.payloadField()) {
            .bytes => payload.bytes = copied,
            .meta => payload.meta.bytes = copied,
            .residue => payload.residue.body = copied,
            else => {},
        }
    }
    try b.addEvent(track, e.at, e.kind, payload);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const Schema = @import("../Schema.zig");
const fromSjon = @import("../doc/fromSjon.zig");
const smf = @import("../smf/smf.zig");
const test_support = @import("test_support.zig");

const q: i64 = Grid.TPQ;

/// A document and its derivation, from source.
const Fixture = struct {
    doc: Doc.Doc,
    derived: derive.Derived,

    fn deinit(self: *Fixture) void {
        self.derived.deinit();
        self.doc.deinit();
    }
};

fn load(gpa: Allocator, source: [:0]const u8) !Fixture {
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var loaded = try fromSjon.fromSource(gpa, &schema, source, null);
    errdefer loaded.doc.deinit();
    defer {
        loaded.map.deinit();
        loaded.diags.deinit();
    }
    if (loaded.diags.hasErrors()) {
        for (loaded.diags.items()) |d| std.debug.print("fixture: {t}: {s}\n", .{ d.code, d.message });
        return error.FixtureDoesNotLoad;
    }
    var d = loaded.doc;
    errdefer d.deinit();
    const derived = try derive.derive(gpa, &d);
    return .{ .doc = d, .derived = derived };
}

/// The events of one track, by kind.
fn countKind(seq: *const Sequence.Sequence, track: usize, kind: Sequence.Kind) usize {
    var n: usize = 0;
    for (seq.tracks[track].events) |e| {
        if (e.kind == kind) n += 1;
    }
    return n;
}

test "toPulse: exact when the division divides the tick, nearest otherwise" {
    // 46 126 080 / 960 = 48 048 tempura ticks to the pulse.
    try testing.expectEqual(@as(i64, 960), toPulse(q, 960).at);
    try testing.expect(toPulse(q, 960).exact);
    try testing.expectEqual(@as(i64, 0), toPulse(1, 960).at);
    try testing.expect(!toPulse(1, 960).exact);
    // Half a pulse: the tie goes to the even neighbour, which is 0.
    try testing.expectEqual(@as(i64, 0), toPulse(24_024, 960).at);
    try testing.expect(!toPulse(24_024, 960).exact);
    // And the next half-pulse up rounds to 2, the even one again.
    try testing.expectEqual(@as(i64, 2), toPulse(48_048 + 24_024, 960).at);
}

test "microseconds: :us verbatim, :qpm rounded" {
    try testing.expectEqual(@as(u32, 400_000), microseconds(.{ .tick = 0, .tempo = .{ .us = 400_000 } }));
    try testing.expectEqual(@as(u32, 480_000), microseconds(.{ .tick = 0, .tempo = .{ .qpm = 125 } }));
    // 60e6 / 130 = 461538.46…, which rounds up.
    try testing.expectEqual(@as(u32, 461_538), microseconds(.{ .tick = 0, .tempo = .{ .qpm = 130 } }));
}

test "renderSmf: the conductor track carries the tempo, the meter and a marker per cue" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 2bar)
        \\(tempo-point :at 0q :qpm 125)
        \\(meter-point :at 0bar :sig [4 4])
        \\(section :name intro :at 0bar :dur 1bar)
        \\(cue :name "the drop" :at 1bar)
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 36 :vel 100))
    );
    defer fx.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    try testing.expectEqual(@as(u8, 1), out.seq.format);
    try testing.expectEqual(@as(u15, 960), out.seq.division.pulsesPerQuarter());
    try testing.expectEqual(@as(usize, 2), out.seq.tracks.len);
    try testing.expectEqual(@as(usize, 1), countKind(&out.seq, 0, .set_tempo));
    try testing.expectEqual(@as(usize, 1), countKind(&out.seq, 0, .time_signature));
    // The cue, and no section marker without the flag.
    try testing.expectEqual(@as(usize, 1), countKind(&out.seq, 0, .marker));
    try testing.expectEqual(@as(u32, 480_000), out.seq.tracks[0].events[1].payload.tempo);
    try testing.expect(out.conductor != null);

    var with_sections = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{ .section_markers = true });
    defer with_sections.deinit();
    try testing.expectEqual(@as(usize, 2), countKind(&with_sections.seq, 0, .marker));
}

test "renderSmf: a notes lane becomes a named track of pairs, with a lane record" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 0.5q :key 36 :vel 110 :ch 3)
        \\  (note :at 1q :dur 0.5q :key 38 :vel 64 :ch 3))
    );
    defer fx.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 2), out.seq.tracks.len);
    const track = out.seq.tracks[1];
    try testing.expectEqual(Sequence.Kind.sequence_name, track.events[0].kind);
    try testing.expectEqualStrings("kick", out.seq.bytesOf(track.events[0].payload.bytes));
    try testing.expectEqual(@as(usize, 2), countKind(&out.seq, 1, .note_on));
    try testing.expectEqual(@as(usize, 2), countKind(&out.seq, 1, .note_off));
    try testing.expectEqual(@as(i64, 0), track.events[1].at);
    try testing.expectEqual(@as(u8, 2), track.events[1].payload.note.ch);
    try testing.expectEqual(@as(i64, 480), track.events[2].at);
    try testing.expectEqual(Sequence.Kind.note_off, track.events[2].kind);
    try testing.expectEqual(@as(u8, off_velocity), track.events[2].payload.note.vel);

    try testing.expectEqual(@as(usize, 1), out.lanes.len);
    try testing.expectEqualStrings("kick", out.lanes[0].lane);
    try testing.expectEqual(@as(u16, 2), out.lanes[0].address.smf.track);
    try testing.expect(out.lanes[0].address.smf.ch.eql(.single(2)));
}

test "renderSmf: a pair is on its own note's :ch with its own :off-vel" {
    // Plan 08: "note-on / note-off pairs on `:ch`". A lane whose notes
    // name two channels is two channels' worth of music, and it gets one
    // lane record each — together they cover every event on the track,
    // which is what a hash per `(track, ch)` pair needs.
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kit :kind notes
        \\  (note :at 0q :dur 1q :key 36 :vel 110 :ch 10 :off-vel 20)
        \\  (note :at 1q :dur 1q :key 60 :vel 90 :ch 1))
    );
    defer fx.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    const evs = out.seq.tracks[1].events;
    // `:ch 10` is 9 on the wire, `:ch 1` is 0.
    try testing.expectEqual(@as(u8, 9), evs[1].payload.note.ch);
    try testing.expectEqual(Sequence.Kind.note_off, evs[2].kind);
    try testing.expectEqual(@as(u8, 9), evs[2].payload.note.ch);
    try testing.expectEqual(@as(u8, 20), evs[2].payload.note.vel);
    try testing.expectEqual(@as(u8, 0), evs[3].payload.note.ch);
    // No `:off-vel` on the second note, so the note off is the 64 every
    // sequencer writes.
    try testing.expectEqual(@as(u8, 64), evs[4].payload.note.vel);

    // Two channels, two records, one track, one lane name.
    try testing.expectEqual(@as(usize, 2), out.lanes.len);
    try testing.expectEqualStrings("kit", out.lanes[0].lane);
    try testing.expectEqualStrings("kit", out.lanes[1].lane);
    try testing.expect(out.lanes[0].address.smf.ch.eql(.single(0)));
    try testing.expect(out.lanes[1].address.smf.ch.eql(.single(9)));
    try testing.expectEqual(@as(u16, 2), out.lanes[0].address.smf.track);
    try testing.expectEqual(@as(u16, 2), out.lanes[1].address.smf.track);
}

test "renderSmf: the lane record's hash is the hash of the file that comes back" {
    const gpa = testing.allocator;
    var fx = try load(gpa, test_support.native_source);
    defer fx.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{ .cc = 74 });
    defer out.deinit();

    var file = try smf.write(gpa, &out.seq, .{});
    defer file.deinit();
    var back = try smf.read(gpa, file.bytes);
    defer back.deinit();

    try testing.expect(out.lanes.len > 0);
    for (out.lanes) |rec| {
        const address = rec.address.smf;
        const now = records.hashSmfLane(
            &back.sequence,
            address.track - 1,
            address.ch.first(),
            back.sequence.division.pulsesPerQuarter(),
        );
        try testing.expectEqualSlices(u8, &rec.hash, &now);
    }
    const cond = records.hashSmfConductor(&back.sequence);
    try testing.expectEqualSlices(u8, &out.conductor.?.hash, &cond);
}

test "renderSmf: a linear segment is sampled at the cc rate, hold is its keyframes" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name glow :kind curve
        \\  (keyframe :at 0q :value 0)
        \\  (keyframe :at 4q :value 1 :ease linear))
    );
    defer fx.deinit();

    // One sample a quarter: the two endpoints and the three between.
    var out = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{ .cc = 74, .cc_rate = q });
    defer out.deinit();
    try testing.expectEqual(@as(usize, 5), countKind(&out.seq, 1, .control_change));
    const evs = out.seq.tracks[1].events;
    try testing.expectEqual(@as(u8, 0), evs[1].payload.control.val);
    try testing.expectEqual(@as(u8, 32), evs[2].payload.control.val);
    try testing.expectEqual(@as(u8, 64), evs[3].payload.control.val);
    try testing.expectEqual(@as(u8, 95), evs[4].payload.control.val);
    try testing.expectEqual(@as(u8, 127), evs[5].payload.control.val);
    try testing.expectEqual(@as(usize, 0), out.lanes[0].steps_only.len);

    var hold = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name glow :kind curve
        \\  (keyframe :at 0q :value 0)
        \\  (keyframe :at 4q :value 1 :ease hold))
    );
    defer hold.deinit();
    var held = try renderSmf(gpa, &hold.doc, &hold.derived, null, .{ .cc = 74, .cc_rate = q });
    defer held.deinit();
    try testing.expectEqual(@as(usize, 2), countKind(&held.seq, 1, .control_change));
    try testing.expectEqual(@as(usize, 0), held.lanes[0].steps_only.len);
}

test "renderSmf: in-cubic renders as its keyframes only, and the record says so" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name glow :kind curve :range [0 2]
        \\  (keyframe :at 0q :value 0)
        \\  (keyframe :at 4q :value 2 :ease in-cubic))
    );
    defer fx.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{ .cc = 74, .cc_rate = q });
    defer out.deinit();

    // Two events, not five: tempura never evaluates a named curve.
    try testing.expectEqual(@as(usize, 2), countKind(&out.seq, 1, .control_change));
    // `:range [0 2]` scales the endpoint back onto the full 7 bits.
    try testing.expectEqual(@as(u8, 127), out.seq.tracks[1].events[2].payload.control.val);
    try testing.expectEqual(@as(usize, 1), out.lanes[0].steps_only.len);
    try testing.expectEqual(@as(i64, 4 * q), out.lanes[0].steps_only[0].at);
    try testing.expectEqualStrings("in-cubic", out.lanes[0].steps_only[0].ease);
    try testing.expectEqual(Doc.SmfCurve{ .cc = 74 }, out.lanes[0].address.smf.curve.?);
}

test "renderSmf: a curve with no controller is render_cc_missing and rides in the residue" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name glow :kind curve
        \\  (keyframe :at 0q :value 0.5))
    );
    defer fx.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.diags.count(.render_cc_missing));
    try testing.expectEqual(@as(usize, 1), out.seq.tracks.len);
    try testing.expectEqual(@as(usize, 0), out.lanes.len);
}

test "renderSmf: a query and a formula lane are residue_only" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name hats  :kind query   :query (euclid 3 8 1))
        \\(lane :name pulse :kind formula :expr (* beat 2))
    );
    defer fx.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 2), out.diags.count(.residue_only));
    try testing.expectEqual(@as(usize, 1), out.seq.tracks.len);
    try testing.expectEqual(@as(usize, 0), out.lanes.len);
}

test "renderSmf: a position off the division is render_inexact and lands on the nearest pulse" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 500000t :dur 480480t :key 36 :vel 100))
    );
    defer fx.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, null, .{ .ppq = 96 });
    defer out.deinit();

    // 46 126 080 / 96 = 480 480 ticks to the pulse, so 500 000 is 1.04
    // pulses and its end 2.04: both land on the nearest, and the lane
    // says how many did.
    try testing.expectEqual(@as(usize, 1), out.diags.count(.render_inexact));
    try testing.expectEqual(@as(i64, 1), out.seq.tracks[1].events[1].at);
    try testing.expectEqual(@as(i64, 2), out.seq.tracks[1].events[2].at);
}

test "renderSmf: a format 0 anchor is promoted, and --format 0 keeps the one track" {
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :us 500000)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0q :dur 1q :key 36 :vel 100))
    );
    defer fx.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 480 };
    const t = try b.addTrack();
    try b.addEvent(t, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 9, .key = 42, .vel = 90 } });
    try b.addEvent(t, 240, .note_off, .{ .note = .{ .ch = 9, .key = 42, .vel = 0 } });
    var base = try b.finish();
    defer base.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, &base, .{});
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.diags.count(.render_format_promoted));
    try testing.expectEqual(@as(u8, 1), out.seq.format);
    try testing.expectEqual(@as(usize, 2), out.seq.tracks.len);
    // The anchor's division rules; `--ppq` is the writer's switch.
    try testing.expectEqual(@as(u15, 480), out.seq.division.pulsesPerQuarter());
    // The anchor's own events came across untouched.
    try testing.expectEqual(@as(usize, 1), countKind(&out.seq, 0, .note_on));

    var merged = try renderSmf(gpa, &fx.doc, &fx.derived, &base, .{ .format0 = true });
    defer merged.deinit();
    try testing.expectEqual(@as(usize, 0), merged.diags.count(.render_format_promoted));
    try testing.expectEqual(@as(u8, 0), merged.seq.format);
    try testing.expectEqual(@as(usize, 1), merged.seq.tracks.len);
    try testing.expectEqual(@as(u16, 1), merged.lanes[0].address.smf.track);
}

test "renderSmf: a bound lane is the anchor's own content and is not rendered again" {
    const gpa = testing.allocator;
    var fx = try test_support.smfConducted(gpa);
    defer fx.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, &fx.doc.midi[0].sequence, .{ .cc = 74 });
    defer out.deinit();

    // The base's two tracks, and nothing appended.
    try testing.expectEqual(@as(usize, 2), out.seq.tracks.len);
    try testing.expectEqual(@as(usize, 0), out.lanes.len);
    // A conducted document's conductor is the anchor's: no record.
    try testing.expect(out.conductor == null);
    // And the conductor track was not written a second time.
    try testing.expectEqual(@as(usize, 2), countKind(&out.seq, 0, .set_tempo));
}

test "renderSmf: a lane renders onto the base track a dump left empty for it" {
    // A dump of a file this renderer wrote keeps each consumed lane's
    // track with nothing but its name in it (`residue/reconcile.zig`,
    // "The consumption"). Rendering into such a base: the snare takes
    // its own empty track back, the base's kick track is NOT empty (a
    // DAW put a note there) and is the anchor's own, so the kick gets a
    // fresh track after it — and the numbers stay put.
    const gpa = testing.allocator;
    var fx = try load(gpa,
        \\(timeline :title "ghost" :length 1bar)
        \\(tempo-point :at 0bar :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name kick :kind notes
        \\  (note :at 0bar :dur 1q :key 36))
        \\(lane :name snare :kind notes
        \\  (note :at 1q :dur 1q :key 38))
    );
    defer fx.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = 960 };
    const t0 = try b.addTrack();
    try b.addEvent(t0, 0, .end_of_track, .empty);
    const t1 = try b.addTrack();
    try b.addEvent(t1, 0, .sequence_name, .{ .bytes = try b.addBytes("snare") });
    try b.addEvent(t1, 1920, .end_of_track, .empty);
    const t2 = try b.addTrack();
    try b.addEvent(t2, 0, .sequence_name, .{ .bytes = try b.addBytes("kick") });
    try b.addEvent(t2, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(t2, 960, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
    try b.addEvent(t2, 960, .end_of_track, .empty);
    var base = try b.finish();
    defer base.deinit();

    var out = try renderSmf(gpa, &fx.doc, &fx.derived, &base, .{});
    defer out.deinit();

    // Conductor, the snare's own track, the DAW's kick track, the new
    // kick track.
    try testing.expectEqual(@as(usize, 4), out.seq.tracks.len);
    try testing.expectEqual(@as(usize, 2), out.lanes.len);
    try testing.expectEqualStrings("kick", out.lanes[0].lane);
    try testing.expectEqual(@as(u16, 4), out.lanes[0].address.smf.track);
    try testing.expectEqualStrings("snare", out.lanes[1].lane);
    try testing.expectEqual(@as(u16, 2), out.lanes[1].address.smf.track);

    // The snare's track: its name, its note pair, and the dump's
    // `end-of-track` gone (the writer places one after the last event).
    try testing.expectEqual(@as(usize, 1), countKind(&out.seq, 1, .sequence_name));
    try testing.expectEqual(@as(usize, 1), countKind(&out.seq, 1, .note_on));
    try testing.expectEqual(@as(usize, 0), countKind(&out.seq, 1, .end_of_track));
    // The DAW's kick track, untouched; the new one named.
    try testing.expectEqual(@as(usize, 4), out.seq.tracks[2].events.len);
    try testing.expectEqual(@as(usize, 1), countKind(&out.seq, 3, .sequence_name));
    try testing.expectEqual(@as(usize, 1), countKind(&out.seq, 3, .note_on));
    // No track was new to the base's format, so nothing was promoted.
    try testing.expectEqual(@as(usize, 0), out.diags.count(.render_format_promoted));
}
