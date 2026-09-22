//! `Doc` → `Derived`: the three conductors, the content in ticks (plan
//! 03, "Three conductors" and "Phases" item 3).
//!
//! `TimeMap.derive` builds the two tables from POINTS; this file decides
//! which points they are — the document's own, or the ones the
//! DOCUMENT LAYER reads off an anchor — and assembles everything else a
//! playhead reads: the sections and cues in ticks, one onset list per
//! lane with every clip expanded, the curve steps, the length and the
//! loop point.
//!
//! Where the rules live is the point. Plan 03 names the three conductors
//! and `doc/fromSjon.zig` implements rules 2 and 3 (`smfConductor`,
//! `itConductor`) because a document's own positions resolve against
//! them while it is being read; this file CALLS those, and calls
//! `fromSjon.contentEnd` for plan 02's `:length` default, so that the
//! map a `Doc` gets here is the map `fromSource` gave it. Two readings
//! of one rule is one reading too many.

const std = @import("std");
const testing = std.testing;

const Diag = @import("../Diag.zig");
const Grid = @import("Grid.zig");
const tm = @import("TimeMap.zig");
const value = @import("../doc/Value.zig");
const bridge_smf = @import("../doc/bridge_smf.zig");
const bridge_it = @import("../doc/bridge_it.zig");
const fromSjon = @import("../doc/fromSjon.zig");
const walk = @import("../itf/walk.zig");
const Module = @import("../itf/Module.zig");
const Sequence = @import("../smf/Sequence.zig");
const test_support = @import("test_support.zig");

const Doc = value.Doc;
const TimeMap = tm.TimeMap;

/// Assembling a derivation can only fail the way any allocation fails.
/// Every defect of a DOCUMENT is a diagnostic on the returned value.
pub const Error = error{OutOfMemory};

/// A named window, in ticks.
pub const Section = struct { name: []const u8, at: i64, dur: i64 };

/// A named point, in ticks.
pub const Cue = struct { name: []const u8, at: i64 };

/// One note, placed: the document's own notes and every note a clip put
/// on the timeline, in one list.
///
/// `ch` and `off_vel` are the note's own — `(note :ch …)` and
/// `(note :off-vel …)` of plan 02, and for a BOUND lane the address's
/// channel and the release velocity the file spelled. A playhead reads
/// neither, but a renderer does: plan 08 writes note pairs "on `:ch`",
/// and a lane whose notes name two channels is two channels' worth of
/// music, not one. They carry defaults so the field set stays additive:
/// a producer with nothing to say about a MIDI channel (an IT-bound
/// lane, a synthetic onset in a test) says nothing.
pub const Onset = struct {
    tick: i64,
    dur: i64,
    key: u7,
    vel: u7,
    /// The MIDI channel, on the wire (`:ch 1` is 0).
    ch: u4 = 0,
    /// The release velocity, or null for "whatever the format's default
    /// is" — 64 for a `.mid`.
    off_vel: ?u7 = null,
};

/// One point on a curve lane — a keyframe of plan 02 with its tick
/// resolved, and what `curveAt` hands back.
pub const Step = struct {
    tick: i64,
    value: [4]f32,
    ncomp: u3,
    ease_src: []const u8,
};

/// One lane's content, placed.
pub const LaneIndex = struct {
    name: []const u8,
    kind: value.LaneKind,
    /// Whether the content came from an anchor rather than from the
    /// document.
    bound: bool,
    onsets: []Onset,
    steps: []Step,

    /// One lane's tables: onsets in `onsetBefore`'s total order, steps by
    /// tick, and every tick on the grid's magnitude, `|tick| ≤ MAX_TICK`.
    ///
    /// A lane's OWN content — the document's positions, which only ever
    /// come from `TimeMap.tickFromLiteral`, and a clip's placements, which
    /// `placedTick` bounds — also never sits before tick 0. A BOUND lane
    /// is held to less: its ticks are the anchor's, and `Grid.smfToTicks`
    /// bounds only their magnitude. (Its readers keep them at or after 0
    /// — a `.mid`'s deltas cannot step below it, and `bridge_smf` floors
    /// a negative inline `:at` the manifest has already refused — but
    /// that is theirs to promise, not the lane table's.)
    fn invariants(self: *const LaneIndex) void {
        const floor: i64 = if (self.bound) -Grid.MAX_TICK else 0;
        for (self.onsets, 0..) |o, i| {
            std.debug.assert(o.tick >= floor);
            std.debug.assert(o.tick <= Grid.MAX_TICK);
            if (i > 0) std.debug.assert(!onsetBefore({}, o, self.onsets[i - 1]));
        }
        for (self.steps, 0..) |s, i| {
            std.debug.assert(s.tick >= floor);
            std.debug.assert(s.tick <= Grid.MAX_TICK);
            if (i > 0) std.debug.assert(self.steps[i - 1].tick <= s.tick);
        }
    }
};

/// The document as a playhead reads it.
///
/// Self-contained: `arena` owns every name, onset and step here, and
/// `map` and `rowmap` own theirs, so a `Derived` outlives the `Doc` it
/// was built from and `deinit()` frees the lot (pacer's convention).
pub const Derived = struct {
    map: TimeMap,
    sections: []Section,
    cues: []Cue,
    /// One per `(lane …)`, in document order.
    lanes: []LaneIndex,
    /// The conductor's timing walk, for a document an IT anchor conducts
    /// — what `Playhead.orderRowAt` reads, and where the module's own
    /// loop point is (`loop_row`). Null for every other document.
    rowmap: ?walk.RowMap,
    /// What the derivation found wrong, in the order it found it.
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    /// Frees the map, the walk, the report and every name, onset and step
    /// — a slice `Playhead.onsets` lent out included.
    pub fn deinit(self: *Derived) void {
        self.map.deinit();
        if (self.rowmap) |*r| r.deinit();
        self.diags.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// The derivation's contract: the map's own (`TimeMap.invariants`)
    /// and every lane's tables in the order `Playhead` searches them.
    /// Asserted at the end of `derive` and at the `Playhead` entry points
    /// that read the whole value (`at`, `atTick`); O(the content), a
    /// construction's cost and never a lookup's.
    pub fn invariants(self: *const Derived) void {
        self.map.invariants();
        for (self.lanes) |*l| l.invariants();
    }

    /// The lane named `name`, or null.
    pub fn laneByName(self: *const Derived, name: []const u8) ?*const LaneIndex {
        for (self.lanes) |*l| {
            if (std.mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }

    /// The canonical text: the map's echo, then the sections, the cues
    /// and one line per lane, in document order.
    pub fn echo(self: *const Derived, writer: anytype) !void {
        try self.map.echo(writer);
        for (self.sections) |s| {
            try writer.print("(section :name {s} :at {d} :dur {d})\n", .{ s.name, s.at, s.dur });
        }
        for (self.cues) |c| {
            // A cue's name is a string the author wrote, so the echo
            // spells it as one: a `"` or a `\\` inside it is escaped,
            // or the line would not read back as the form it prints.
            try writer.writeAll("(cue :name \"");
            for (c.name) |ch| {
                if (ch == '"' or ch == '\\') try writer.writeByte('\\');
                try writer.writeByte(ch);
            }
            try writer.print("\" :at {d})\n", .{c.at});
        }
        for (self.lanes) |l| {
            const first: i64 = if (l.onsets.len == 0) 0 else l.onsets[0].tick;
            const last: i64 = if (l.onsets.len == 0) 0 else l.onsets[l.onsets.len - 1].tick;
            try writer.print(
                "(lane :name {s} :kind {s} :onsets {d} :first {d} :last {d})\n",
                .{ l.name, @tagName(l.kind), l.onsets.len, first, last },
            );
        }
    }
};

/// The document, derived.
///
/// Best-effort, like every producer here: what a document gets wrong is
/// a diagnostic on the returned value and the derivation is still built,
/// because an editor has to show something.
pub fn derive(gpa: std.mem.Allocator, doc: *const Doc) Error!Derived {
    doc.invariants();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var diags: Diag.List = .init(gpa);
    var rowmap: ?walk.RowMap = null;
    errdefer {
        if (rowmap) |*r| r.deinit();
        arena_state.deinit();
        diags.deinit();
    }
    const arena = arena_state.allocator();

    const conducted = try conduct(gpa, arena, doc, &diags, &rowmap);

    const sections = try arena.alloc(Section, doc.sections.len);
    for (doc.sections, sections) |src, *dst| {
        dst.* = .{ .name = try arena.dupe(u8, src.name), .at = src.at, .dur = src.dur };
    }
    const cues = try arena.alloc(Cue, doc.cues.len);
    for (doc.cues, cues) |src, *dst| {
        dst.* = .{ .name = try arena.dupe(u8, src.name), .at = src.at };
    }
    const lanes = try laneTable(gpa, arena, doc, &diags, &rowmap);

    // Plan 02's `:length` default — "the end of the last event or clip,
    // rounded up to a bar" — in the document layer's own two terms and
    // through its own `defaultLength`: what the DOCUMENT placed
    // (`fromSjon.contentEnd`) and where the CONDUCTOR's material ends.
    // Not the derivation's own placed content: a clip's window already
    // bounds what it placed, and a bound lane's notes are the anchor's,
    // which the conductor's end already covers.
    const content_end = @max(fromSjon.contentEnd(doc), conducted.end);
    const length = doc.length orelse
        try fromSjon.defaultLength(gpa, conducted, content_end, doc.end);

    var res = try tm.derive(gpa, conducted.tempo, conducted.meter, length, doc.end);
    errdefer res.map.deinit();
    {
        defer res.diags.deinit();
        try diags.extend(res.diags.items());
    }

    const derived: Derived = .{
        .map = res.map,
        .sections = sections,
        .cues = cues,
        .lanes = lanes,
        .rowmap = rowmap,
        .diags = diags,
        .arena = arena_state,
    };
    derived.invariants();
    return derived;
}

// ---- the conductor ----

/// Plan 03's three conductors, as the DOCUMENT LAYER decides them: the
/// points the map is built from and where the conductor's material ends
/// are `fromSjon.timeTables` over `fromSjon.conductorOf`'s answer — the
/// one rule the load and `mapOf` apply too, so the map a derivation
/// builds for a `Doc` is the map `fromSource` gave it.
///
/// Rules 2 and 3 are `doc/fromSjon.zig`'s `smfConductor` and
/// `itConductor` — every merge, seed, diagnostic and conversion of them
/// — because an anchored document's own positions resolve against those
/// same tables while it is being read. This asks, says what this layer
/// has to say (the conflict, the placeholder), and copies the answer
/// into the derivation's arena; an IT walk comes back with it, and is
/// what `Playhead.orderRowAt` and a bound IT lane read.
fn conduct(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: *const Doc,
    diags: *Diag.List,
    rowmap: *?walk.RowMap,
) Error!fromSjon.TimeTables {
    const id = doc.conductor orelse return fromSjon.timeTables(doc, null);
    try refuseOwnTime(diags, doc);

    var built: fromSjon.Conductor = (try fromSjon.conductorOf(
        gpa,
        doc,
        id,
        doc.conductor_bytes,
    )) orelse {
        if (doc.anchorById(id)) |anchor| try sayPlaceholder(diags, anchor);
        return fromSjon.timeTables(doc, null);
    };
    defer built.deinit();

    // The walk moves out of the conductor and into the caller's slot,
    // whose errdefer owns it from here; `built.deinit` then frees only
    // what is left.
    rowmap.* = built.rowmap;
    built.rowmap = null;

    try diags.extend(built.diags.items());
    // Copied out: the conductor's arena dies with this call and the
    // tables outlive it.
    return fromSjon.timeTables(doc, .{
        .tempo = try arena.dupe(tm.TempoPoint, built.tempo),
        .meter = try arena.dupe(tm.MeterPoint, built.meter),
        .end = built.end,
    });
}

/// One owner of time per document (plan 03, "Three conductors"): with a
/// `:conductor`, every tempo and meter point the document wrote itself is
/// an error, each at its own span. The bridge says this too, over the
/// SOURCE; a `Doc` reaching here from the edit engine never passed
/// through it.
fn refuseOwnTime(diags: *Diag.List, doc: *const Doc) Error!void {
    const why = "this document names a :conductor, " ++
        "and a conducted document has one owner of time";
    for (doc.tempo) |p| try diags.add(.conductor_conflict, .err, p.span, why, .{});
    for (doc.meter) |p| try diags.add(.conductor_conflict, .err, p.span, why, .{});
}

/// The placeholder, SAID: neither an inline tier nor the anchor's own
/// verified bytes, so the tables are plan 03's placeholder, and a host
/// that derived straight off a value it built itself would otherwise be
/// timed at 120 quarter notes per minute with nothing to read about it.
///
/// The document layer says its own half while it loads
/// (`fromSjon.conductorTables`), so a CLI run that does both prints two
/// lines. That is this file's existing convention rather than a new one
/// — `conductor_conflict` is raised by both layers too — and the two are
/// worded for the layer that spoke, so a reader sees two facts and not a
/// stutter.
fn sayPlaceholder(diags: *Diag.List, anchor: *const value.Anchor) Error!void {
    try diags.add(
        .anchor_unavailable,
        .err,
        anchor.span,
        "the anchor '{s}' conducts this document and its file ({s}) is not here, " ++
            "so this derivation is the placeholder's 120 quarter notes per minute " ++
            "in [4 4] and not the file's time",
        .{ anchor.id, anchor.file },
    );
}

// ---- the lanes ----

/// One `LaneIndex` per lane, in document order.
fn laneTable(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: *const Doc,
    diags: *Diag.List,
    rowmap: *?walk.RowMap,
) Error![]LaneIndex {
    const out = try arena.alloc(LaneIndex, doc.lanes.len);
    for (doc.lanes, out) |*src, *dst| {
        var onsets: std.ArrayList(Onset) = .empty;
        var steps: std.ArrayList(Step) = .empty;

        if (src.binding) |binding| {
            try bound(gpa, arena, doc, src, binding, &onsets, &steps, diags, rowmap);
        } else {
            for (src.notes) |n| try onsets.append(arena, .{
                .tick = n.at,
                .dur = n.dur,
                .key = n.key,
                .vel = n.vel,
                .ch = n.ch,
                .off_vel = n.off_vel,
            });
            for (src.keyframes) |k| try steps.append(arena, .{
                .tick = k.at,
                .value = k.value,
                .ncomp = k.ncomp,
                .ease_src = try arena.dupe(u8, k.ease_src),
            });
            for (src.clips) |c| try place(arena, doc, src, c, &onsets, &steps, diags);
        }

        std.mem.sort(Onset, onsets.items, {}, onsetBefore);
        std.mem.sort(Step, steps.items, {}, stepBefore);
        dst.* = .{
            .name = try arena.dupe(u8, src.name),
            .kind = src.kind,
            .bound = src.binding != null,
            .onsets = try onsets.toOwnedSlice(arena),
            .steps = try steps.toOwnedSlice(arena),
        };
    }
    return out;
}

/// A bound lane's content: the anchor's, read through `doc/`'s bridges
/// and converted onto the grid (plan 02, "Binding"; plan 05 and plan 06,
/// "Bound lanes").
///
/// The two bridges answer in their FILE's unit — SMF pulses, IT ticks —
/// and this is where both become tempura ticks. A bound curve's value
/// stays normalised: `:range` scales it at export, not here.
fn bound(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: *const Doc,
    lane: *const value.Lane,
    binding: value.Binding,
    onsets: *std.ArrayList(Onset),
    steps: *std.ArrayList(Step),
    diags: *Diag.List,
    rowmap: *?walk.RowMap,
) Error!void {
    switch (binding.address) {
        .smf => |addr| {
            const tier = smfTier(doc, binding.anchor) orelse return;
            try boundSmf(gpa, arena, &tier.sequence, lane.kind, addr, onsets, steps, diags);
        },
        .it => |addr| {
            const tier = itTier(doc, binding.anchor) orelse return;
            // The conductor's walk when this lane is bound to the anchor
            // that conducts — the usual shape, and the whole of plan 04's
            // skeleton — and a walk of its own otherwise.
            var local: ?walk.RowMap = null;
            defer if (local) |*l| l.deinit();
            const map = conductorWalk(doc, binding.anchor, rowmap) orelse map: {
                local = try walk.derive(gpa, &tier.module, .{});
                break :map &local.?;
            };
            try boundIt(gpa, arena, &tier.module, map, lane.kind, addr, onsets, steps);
        },
    }
}

/// A lane's SMF address and its IT one, as `value.Address` spells them.
const SmfAddress = @FieldType(value.Address, "smf");
const ItAddress = @FieldType(value.Address, "it");

/// A lane bound to an SMF anchor: the notes its address pairs, or the
/// curve its address reads, each converted from pulses onto the grid.
fn boundSmf(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    seq: *const Sequence.Sequence,
    kind: value.LaneKind,
    addr: SmfAddress,
    onsets: *std.ArrayList(Onset),
    steps: *std.ArrayList(Step),
    diags: *Diag.List,
) Error!void {
    const ppq = seq.division.pulsesPerQuarter();
    switch (kind) {
        .notes => {
            var paired = try bridge_smf.pairNotes(gpa, seq, addr.track, addr.ch, addr.key);
            defer paired.deinit();
            try diags.extend(paired.diags.items());
            for (paired.notes) |n| try onsets.append(arena, smfOnset(n, ppq));
        },
        .curve => {
            const address = addr.curve orelse return;
            const read = try bridge_smf.curveSteps(gpa, seq, addr.track, addr.ch, address);
            defer gpa.free(read);
            for (read) |s| {
                const at = Grid.smfToTicks(s.at, ppq).tick;
                try steps.append(arena, normalised(at, s.value));
            }
        },
        // A `query` or a `formula` lane cannot bind
        // (`bound_kind_invalid`, the document's own check).
        .query, .formula => {},
    }
}

/// A lane bound to an IT anchor: the notes of its channel, or the column
/// it reads, through `map`, each converted from IT ticks onto the grid.
/// Content that starts past the ceiling is not placed.
fn boundIt(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    module: *const Module.Module,
    map: *const walk.RowMap,
    kind: value.LaneKind,
    addr: ItAddress,
    onsets: *std.ArrayList(Onset),
    steps: *std.ArrayList(Step),
) Error!void {
    switch (kind) {
        .notes => {
            const notes = try bridge_it.boundNotes(gpa, module, map, addr.channel);
            defer gpa.free(notes);
            for (notes) |n| {
                const onset = itOnset(n) orelse continue;
                try onsets.append(arena, onset);
            }
        },
        .curve => {
            const column = addr.column orelse return;
            const read = try bridge_it.curveSteps(gpa, module, map, addr.channel, column, addr.fx);
            defer gpa.free(read);
            for (read) |s| {
                const at = itToTicks(s.at) orelse continue;
                try steps.append(arena, normalised(at, s.value));
            }
        },
        .query, .formula => {},
    }
}

/// The conductor's own walk, when `anchor` is the anchor that conducts
/// this document and its walk came back with the conductor; null when a
/// lane bound to `anchor` needs a walk of its own.
fn conductorWalk(
    doc: *const Doc,
    anchor: value.AnchorId,
    rowmap: *const ?walk.RowMap,
) ?*const walk.RowMap {
    const id = doc.conductor orelse return null;
    if (!std.mem.eql(u8, id, anchor)) return null;
    if (rowmap.*) |*r| return r;
    return null;
}

/// One paired SMF note as an onset on the grid. BOTH ends are converted,
/// so the duration is the distance between two grid ticks rather than a
/// converted span, and a note carries its channel and release velocity.
fn smfOnset(n: bridge_smf.PairedNote, ppq: u15) Onset {
    const at = Grid.smfToTicks(n.at, ppq).tick;
    // Saturating: a `Sequence` carries any `i64` tick, and past the
    // ceiling `smfToTicks` answers `MAX_TICK` either way.
    const end = Grid.smfToTicks(n.at +| @max(n.dur, 0), ppq).tick;
    // The conversion is monotone, so a note never ends before it starts.
    std.debug.assert(end >= at);
    return .{
        .tick = at,
        .dur = end - at,
        .key = n.key,
        .vel = n.vel,
        .ch = n.ch,
        .off_vel = n.off_vel,
    };
}

/// One IT note as an onset on the grid, or null when it starts past the
/// ceiling; a note that ENDS past it is cut at the ceiling.
fn itOnset(n: bridge_smf.PairedNote) ?Onset {
    const at = itToTicks(n.at) orelse return null;
    const end = itToTicks(n.at +| @max(n.dur, 0)) orelse Grid.MAX_TICK;
    std.debug.assert(end >= at);
    return .{ .tick = at, .dur = end - at, .key = n.key, .vel = n.vel };
}

/// IT ticks to tempura ticks, or null past the grid ceiling. The product
/// is formed in `i128`, so the ceiling is a CHECK and never a wrap.
fn itToTicks(it_ticks: i64) ?i64 {
    const t = @as(i128, it_ticks) * Grid.IT_TICK;
    if (t < 0 or t > Grid.MAX_TICK) return null;
    return @intCast(t);
}

/// One step of a bound curve. A bound lane has no authored easing, so
/// the segment between two of its values is `linear` — the name pacer
/// gives a straight line.
fn normalised(tick: i64, v: f32) Step {
    return .{ .tick = tick, .value = .{ v, 0, 0, 0 }, .ncomp = 1, .ease_src = "linear" };
}

/// The inline dump paired with `id`, or null when the anchor is
/// by-reference and nothing has read it.
fn smfTier(doc: *const Doc, id: value.AnchorId) ?*const value.SmfTier {
    for (doc.midi) |*t| {
        if (std.mem.eql(u8, t.anchor, id)) return t;
    }
    return null;
}

fn itTier(doc: *const Doc, id: value.AnchorId) ?*const value.ItTier {
    for (doc.it) |*t| {
        if (std.mem.eql(u8, t.anchor, id)) return t;
    }
    return null;
}

/// A clip's content, placed (plan 02, "(clip …)").
///
/// The phrase's own timeline runs `:repeat` times end to end; the window
/// is `[:offset, :offset + :length)` into it, `:length` defaulting to
/// what is left of the repeats; and a source tick `s` inside the window
/// lands at `:at + (s − :offset)`. Content past the window is NOT placed
/// — what a split clip's left half needs — and the measure is the
/// event's own onset, so a note that starts inside keeps its whole
/// duration.
///
/// Every term here is USER arithmetic: `:repeat` has no maximum in the
/// manifest and a phrase's `:length` reaches to the grid ceiling, so
/// `length · repeat` does not fit an `i64` in general. The window is
/// therefore formed with saturating operators, and the repeat count is
/// bounded BEFORE the loop by the last source tick that can still land
/// — the window's end, or the ceiling, whichever comes first — so the
/// loop runs once per repeat that places something and never once per
/// repeat the document asked for.
fn place(
    arena: std.mem.Allocator,
    doc: *const Doc,
    lane: *const value.Lane,
    clip: value.Clip,
    onsets: *std.ArrayList(Onset),
    steps: *std.ArrayList(Step),
    diags: *Diag.List,
) Error!void {
    // A clip naming no phrase, or a phrase with no lane of this name, is
    // `clip_lane_missing` — the document's own check (plan 02), raised
    // where the span lives. Here it simply places nothing.
    const phrase = doc.phraseByName(clip.phrase) orelse return;
    const from = laneOf(phrase, lane.name) orelse return;
    if (phrase.length <= 0 or clip.offset < 0 or clip.at < 0) return;

    const repeat = clip.plays();
    const window = clip.window(phrase);
    if (window <= 0) return;
    // The window in SOURCE ticks, half-open.
    const window_end = clip.offset +| window;
    // The furthest source tick whose placement still lands on the grid.
    const reach: i64 = if (clip.at >= Grid.MAX_TICK)
        clip.offset
    else
        clip.offset +| (Grid.MAX_TICK - clip.at);
    const last = @min(window_end, reach);

    // A repeat whose body starts past `last` places nothing, so the loop
    // stops there — and `length · r` stays under `last + length`, which
    // is the bound that makes the multiply safe.
    const repeats = @min(repeat, @divFloor(last, phrase.length) + 1);
    if (repeats < repeat and window_end > reach) try diags.add(
        .tick_overflow,
        .err,
        clip.span,
        "this clip's repeats reach past the grid ceiling {d}; the ones past it are not placed",
        .{Grid.MAX_TICK},
    );

    var r: i64 = 0;
    while (r < repeats) : (r += 1) {
        const base = phrase.length * r;
        for (from.notes) |n| {
            const at = placedTick(base + n.at, clip, window_end) orelse continue;
            try onsets.append(arena, .{
                .tick = at,
                .dur = n.dur,
                .key = transposed(n.key, clip.transpose),
                .vel = n.vel,
                .ch = n.ch,
                .off_vel = n.off_vel,
            });
        }
        for (from.keyframes) |k| {
            const at = placedTick(base + k.at, clip, window_end) orelse continue;
            try steps.append(arena, .{
                .tick = at,
                .value = k.value,
                .ncomp = k.ncomp,
                .ease_src = try arena.dupe(u8, k.ease_src),
            });
        }
    }
}

/// Where a source tick lands, or null when the window or the grid
/// ceiling refuses it. `window_end` is the window's exclusive end in
/// source ticks, already saturated by `place`.
///
/// The ceiling is checked in `i128` and reported by `place`, once for
/// the clip, rather than here once per event: a clip that reaches past
/// the ceiling does so for every note it holds, and one diagnostic is
/// the news.
fn placedTick(source: i64, clip: value.Clip, window_end: i64) ?i64 {
    if (source < clip.offset or source >= window_end) return null;
    const at = @as(i128, clip.at) + (source - clip.offset);
    if (at > Grid.MAX_TICK) return null;
    return @intCast(at);
}

/// The phrase's lane of the same name — "a clip places the phrase's lane
/// of the same `:name` as this lane" (plan 02).
fn laneOf(phrase: *const value.Phrase, name: []const u8) ?*const value.Lane {
    for (phrase.lanes) |*l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

/// `:transpose` semitones, clamped to the key domain: a transposition
/// that would leave 0..127 has no key to name and holds at the edge.
fn transposed(key: u7, semitones: i8) u7 {
    return @intCast(std.math.clamp(@as(i16, key) + semitones, 0, 127));
}

/// Onsets sort by tick, then by key, velocity and duration — a total
/// order, so the list is the same on every host.
fn onsetBefore(_: void, x: Onset, y: Onset) bool {
    if (x.tick != y.tick) return x.tick < y.tick;
    if (x.key != y.key) return x.key < y.key;
    if (x.vel != y.vel) return x.vel < y.vel;
    return x.dur < y.dur;
}

/// Steps sort by tick alone, and the sort is stable, so two keyframes at
/// one tick keep document order.
fn stepBefore(_: void, x: Step, y: Step) bool {
    return x.tick < y.tick;
}

// ---- tests ----

const TPQ = Grid.TPQ;
const bar44 = 4 * TPQ;

test "derive: sections and cues come over in ticks, in document order" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    var sections = [_]value.Section{
        .{ .name = "intro", .at = 0, .dur = bar44, .span = .{ .start = 0, .end = 1 } },
        .{ .name = "drop", .at = bar44 / 2, .dur = bar44, .span = .{ .start = 0, .end = 1 } },
    };
    var cues = [_]value.Cue{
        .{ .name = "one", .at = 0, .span = .{ .start = 0, .end = 1 } },
        .{ .name = "two", .at = 3 * TPQ, .span = .{ .start = 0, .end = 1 } },
    };
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.sections = &sections;
    doc.cues = &cues;
    doc.length = 2 * bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    // The names are COPIED into the derivation's own arena, so they are
    // compared as text and not as pointers.
    try testing.expectEqual(@as(usize, 2), d.sections.len);
    try testing.expectEqualStrings("intro", d.sections[0].name);
    try testing.expectEqual(@as(i64, 0), d.sections[0].at);
    try testing.expectEqual(@as(i64, 184_504_320), d.sections[0].dur);
    try testing.expectEqualStrings("drop", d.sections[1].name);
    try testing.expectEqual(@as(i64, 92_252_160), d.sections[1].at);
    try testing.expectEqual(@as(i64, 184_504_320), d.sections[1].dur);

    try testing.expectEqual(@as(usize, 2), d.cues.len);
    try testing.expectEqualStrings("one", d.cues[0].name);
    try testing.expectEqual(@as(i64, 0), d.cues[0].at);
    try testing.expectEqualStrings("two", d.cues[1].name);
    try testing.expectEqual(@as(i64, 138_378_240), d.cues[1].at);
    try testing.expectEqual(@as(i64, 369_008_640), d.map.length);
    try testing.expectEqual(@as(usize, 0), d.diags.items().len);
}

test "derive: a native notes lane, its clip expanded by :repeat and :transpose" {
    // Hand computation. TPQ = 46 126 080, so a quarter is 46 126 080
    // ticks, a bar of [4 4] is 184 504 320 and a 16th is 11 531 520.
    //
    // The phrase `fill` is one quarter long and holds two notes, at 0
    // and at 0.5q = 23 063 040. The clip sits at 1bar = 184 504 320 with
    // `:repeat 2` and `:transpose 12`, so the phrase's own timeline is
    // two quarters long and every note lands twelve semitones up:
    //
    //   r0 note 0    → 184 504 320 + 0          = 184 504 320  key 50
    //   r0 note 0.5q → 184 504 320 + 23 063 040 = 207 567 360  key 50
    //   r1 note 0    → 184 504 320 + 46 126 080 = 230 630 400  key 50
    //   r1 note 0.5q → 184 504 320 + 69 189 120 = 253 693 440  key 50
    //
    // The lane's own two notes come first: 0 and 1q.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };

    var phrase_notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 4, .key = 38, .vel = 100, .ch = 0, .off_vel = null, .span = span },
        .{
            .at = TPQ / 2,
            .dur = TPQ / 4,
            .key = 38,
            .vel = 80,
            .ch = 0,
            .off_vel = null,
            .span = span,
        },
    };
    var phrase_lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    var phrases = [_]value.Phrase{.{
        .name = "fill",
        .length = TPQ,
        .lanes = &phrase_lanes,
        .span = span,
    }};

    var notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 2, .key = 36, .vel = 110, .ch = 0, .off_vel = null, .span = span },
        .{
            .at = TPQ,
            .dur = TPQ / 2,
            .key = 38,
            .vel = 90,
            .ch = 0,
            .off_vel = null,
            .span = span,
        },
    };
    var clips = [_]value.Clip{.{
        .at = bar44,
        .phrase = "fill",
        .repeat = 2,
        .offset = 0,
        .length = null,
        .transpose = 12,
        .span = span,
    }};
    var lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &notes,
        .keyframes = &.{},
        .clips = &clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};

    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.phrases = &phrases;
    doc.lanes = &lanes;
    doc.length = 2 * bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lane = d.laneByName("flash").?;
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = 23_063_040, .key = 36, .vel = 110 },
        .{ .tick = 46_126_080, .dur = 23_063_040, .key = 38, .vel = 90 },
        .{ .tick = 184_504_320, .dur = 11_531_520, .key = 50, .vel = 100 },
        .{ .tick = 207_567_360, .dur = 11_531_520, .key = 50, .vel = 80 },
        .{ .tick = 230_630_400, .dur = 11_531_520, .key = 50, .vel = 100 },
        .{ .tick = 253_693_440, .dur = 11_531_520, .key = 50, .vel = 80 },
    }, lane.onsets);
}

test "derive: an onset carries its note's :ch and :off-vel, through a clip too" {
    // A playhead reads neither, and a RENDERER reads both (plan 08:
    // "note-on / note-off pairs on `:ch`"). They are the note's own,
    // and a clip carries them across with the key it transposes.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };

    var phrase_notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 4, .key = 38, .vel = 100, .ch = 9, .off_vel = 7, .span = span },
    };
    var phrase_lanes = [_]value.Lane{.{
        .name = "kit",
        .kind = .notes,
        .target = "kit",
        .range = null,
        .binding = null,
        .notes = &phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    var phrases = [_]value.Phrase{.{
        .name = "fill",
        .length = TPQ,
        .lanes = &phrase_lanes,
        .span = span,
    }};

    var notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 2, .key = 36, .vel = 110, .ch = 3, .off_vel = 20, .span = span },
        .{
            .at = TPQ,
            .dur = TPQ / 2,
            .key = 60,
            .vel = 90,
            .ch = 0,
            .off_vel = null,
            .span = span,
        },
    };
    var clips = [_]value.Clip{.{
        .at = 2 * TPQ,
        .phrase = "fill",
        .repeat = 1,
        .offset = 0,
        .length = null,
        .transpose = 0,
        .span = span,
    }};
    var lanes = [_]value.Lane{.{
        .name = "kit",
        .kind = .notes,
        .target = "kit",
        .range = null,
        .binding = null,
        .notes = &notes,
        .keyframes = &.{},
        .clips = &clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.phrases = &phrases;
    doc.lanes = &lanes;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lane = d.laneByName("kit").?;
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = TPQ / 2, .key = 36, .vel = 110, .ch = 3, .off_vel = 20 },
        .{ .tick = TPQ, .dur = TPQ / 2, .key = 60, .vel = 90, .ch = 0, .off_vel = null },
        .{ .tick = 2 * TPQ, .dur = TPQ / 4, .key = 38, .vel = 100, .ch = 9, .off_vel = 7 },
    }, lane.onsets);
}

test "derive: a clip's :offset and :length window, content past it not placed" {
    // Hand computation. The same one-quarter phrase, `:repeat 2` so its
    // own timeline is [0, 2q) holding notes at 0, 0.5q, 1q and 1.5q. The
    // clip takes `:offset 0.5q :length 1q`, so the window is
    // [0.5q, 1.5q) and the note at 0 is BEFORE it while the note at
    // 1.5q is past it — both dropped. The two inside land at
    //
    //   0.5q → 0 + (23 063 040 − 23 063 040) = 0
    //   1q   → 0 + (46 126 080 − 23 063 040) = 23 063 040
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };

    var phrase_notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 4, .key = 38, .vel = 100, .ch = 0, .off_vel = null, .span = span },
        .{
            .at = TPQ / 2,
            .dur = TPQ / 4,
            .key = 38,
            .vel = 80,
            .ch = 0,
            .off_vel = null,
            .span = span,
        },
    };
    var phrase_lanes = [_]value.Lane{.{
        .name = "spark",
        .kind = .notes,
        .target = "spark",
        .range = null,
        .binding = null,
        .notes = &phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    var phrases = [_]value.Phrase{.{
        .name = "fill",
        .length = TPQ,
        .lanes = &phrase_lanes,
        .span = span,
    }};

    var clips = [_]value.Clip{.{
        .at = 0,
        .phrase = "fill",
        .repeat = 2,
        .offset = TPQ / 2,
        .length = TPQ,
        .transpose = 0,
        .span = span,
    }};
    var lanes = [_]value.Lane{.{
        .name = "spark",
        .kind = .notes,
        .target = "spark",
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &.{},
        .clips = &clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};

    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.phrases = &phrases;
    doc.lanes = &lanes;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lane = d.laneByName("spark").?;
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = 11_531_520, .key = 38, .vel = 80 },
        .{ .tick = 23_063_040, .dur = 11_531_520, .key = 38, .vel = 100 },
    }, lane.onsets);
}

test "derive: a curve lane's keyframes become steps in tick order" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };

    var keyframes = [_]value.Keyframe{
        .{ .at = 0, .value = .{ 0.2, 0, 0, 0 }, .ncomp = 1, .ease_src = "hold", .span = span },
        .{
            .at = 4 * TPQ,
            .value = .{ 0.9, 0, 0, 0 },
            .ncomp = 1,
            .ease_src = "in-cubic",
            .span = span,
        },
    };
    var lanes = [_]value.Lane{.{
        .name = "glow",
        .kind = .curve,
        .target = "glow",
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &keyframes,
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.lanes = &lanes;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lane = d.laneByName("glow").?;
    try testing.expectEqual(@as(usize, 2), lane.steps.len);
    try testing.expectEqual(@as(i64, 0), lane.steps[0].tick);
    try testing.expectEqual(@as(f32, 0.2), lane.steps[0].value[0]);
    try testing.expectEqualStrings("hold", lane.steps[0].ease_src);
    try testing.expectEqual(@as(i64, 184_504_320), lane.steps[1].tick);
    try testing.expectEqualStrings("in-cubic", lane.steps[1].ease_src);
    try testing.expectEqual(@as(usize, 0), lane.onsets.len);
}

test "derive: the default :length is the last content rounded up to a bar" {
    // Hand computation: the last note ends at 1q + 0.5q = 1.5q =
    // 69 189 120, and the first bar line at or after that is bar 1,
    // 184 504 320.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    var notes = [_]value.Note{
        .{
            .at = TPQ,
            .dur = TPQ / 2,
            .key = 36,
            .vel = 100,
            .ch = 0,
            .off_vel = null,
            .span = span,
        },
    };
    var lanes = [_]value.Lane{.{
        .name = "kick",
        .kind = .notes,
        .target = "kick",
        .range = null,
        .binding = null,
        .notes = &notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.lanes = &lanes;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(i64, 184_504_320), d.map.length);
}

test "derive: the default :length counts a clip's whole window" {
    // Hand computation. The phrase is FOUR bars long and its only note
    // sits at its start; the clip places it at 1bar, so the window runs
    // to 1bar + 4bar = 5bar = 922 521 600 while the last note it places
    // ends a quarter of a quarter into bar 1. Plan 02 counts "the end of
    // the last event OR CLIP", so the length is the window's end.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    var phrase_notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 4, .key = 38, .vel = 100, .ch = 0, .off_vel = null, .span = span },
    };
    var phrase_lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    var phrases = [_]value.Phrase{.{
        .name = "fill",
        .length = 4 * bar44,
        .lanes = &phrase_lanes,
        .span = span,
    }};
    var clips = [_]value.Clip{.{
        .at = bar44,
        .phrase = "fill",
        .repeat = 1,
        .offset = 0,
        .length = null,
        .transpose = 0,
        .span = span,
    }};
    var lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &.{},
        .clips = &clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.phrases = &phrases;
    doc.lanes = &lanes;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(i64, 922_521_600), d.map.length);
}

test "derive.echo: the map, then the sections, the cues and the lanes" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var tempo = [_]tm.TempoPoint{.{ .tick = 0, .tempo = .{ .us = 500_000 } }};
    var meter = [_]tm.MeterPoint{.{ .tick = 0, .n = 4, .d = 4 }};
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    var sections = [_]value.Section{
        .{ .name = "intro", .at = 0, .dur = bar44, .span = span },
    };
    var cues = [_]value.Cue{
        .{ .name = "bar 2", .at = bar44, .span = span },
    };
    var notes = [_]value.Note{
        .{ .at = 0, .dur = TPQ / 2, .key = 36, .vel = 110, .ch = 0, .off_vel = null, .span = span },
        .{
            .at = TPQ,
            .dur = TPQ / 2,
            .key = 38,
            .vel = 90,
            .ch = 0,
            .off_vel = null,
            .span = span,
        },
    };
    var lanes = [_]value.Lane{.{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    }};
    doc.tempo = &tempo;
    doc.meter = &meter;
    doc.sections = &sections;
    doc.cues = &cues;
    doc.lanes = &lanes;
    doc.length = 2 * bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    // The map's own four lines are `TimeMap.echo`'s, pinned by its own
    // test: 500 000 microseconds per quarter is 92 252 160 ticks per
    // second (0x4195FEA000000000) and two bars of [4 4] at that tempo
    // are four seconds (0x4010000000000000).
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try d.echo(&w);
    try testing.expectEqualStrings(
        \\(segment :tick 0 :us 500000 :tps "4195FEA000000000" :start-sec "0000000000000000")
        \\(meter :tick 0 :sig [4 4] :first-bar 0)
        \\(bars :count 3 :last-start 369008640)
        \\(length :tick 369008640 :end hold :loop-secs "4010000000000000")
        \\(section :name intro :at 0 :dur 184504320)
        \\(cue :name "bar 2" :at 184504320)
        \\(lane :name flash :kind notes :onsets 2 :first 0 :last 46126080)
        \\
    , w.buffered());
}

// ---- tests: the three conductors ----

/// The three-segment map of plan 03, phase 3, authored natively: 125,
/// 150 and 200 quarter notes per minute at ticks 0, 1q and 2q, one bar
/// of [4 4] long.
///
/// 60 000 000 / 125 = 480 000 microseconds per quarter note, / 150 =
/// 400 000 and / 200 = 300 000 — all three integers, so the map takes
/// the integer path whichever conductor built it.
fn nativeThreeSegments(gpa: std.mem.Allocator) !Doc {
    var doc: Doc = .empty(gpa);
    errdefer doc.deinit();
    const arena = doc.arena.allocator();
    const tempo = try arena.alloc(tm.TempoPoint, 3);
    tempo[0] = .{ .tick = 0, .tempo = .{ .us = 480_000 } };
    tempo[1] = .{ .tick = TPQ, .tempo = .{ .us = 400_000 } };
    tempo[2] = .{ .tick = 2 * TPQ, .tempo = .{ .us = 300_000 } };
    const meter = try arena.alloc(tm.MeterPoint, 1);
    meter[0] = .{ .tick = 0, .n = 4, .d = 4 };
    doc.tempo = tempo;
    doc.meter = meter;
    doc.length = bar44;
    return doc;
}

/// One anchor, by id, of the kind the tier that follows it carries.
fn anchorsOf(doc: *Doc, kind: value.AnchorKind) ![]value.Anchor {
    const arena = doc.arena.allocator();
    const out = try arena.alloc(value.Anchor, 1);
    out[0] = .{
        .id = "song",
        .kind = kind,
        .file = "song",
        .size = null,
        .sha256 = null,
        .sha256_src = null,
        .inline_dump = true,
        .resolved = true,
        .span = .{ .start = 0, .end = 1 },
    };
    return out;
}

test "derive: an SMF conductor — set-tempo on track 2, merged by tick" {
    // Hand computation. Division 960 pulses per quarter divides TPQ
    // exactly (46 126 080 / 960 = 48 048), so SMF tick 960 is 1q =
    // 46 126 080 and 1920 is 2q = 92 252 160. The tempo events sit on
    // track 2 (index 1) and the midi set's rule that tempo on ANY track
    // is honoured is what makes them the conductor's.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    _ = try b.addTrack();
    try b.addEvent(1, 0, .set_tempo, .{ .tempo = 480_000 });
    try b.addEvent(1, 960, .set_tempo, .{ .tempo = 400_000 });
    try b.addEvent(1, 1920, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(0, 1920, .end_of_track, .empty);
    try b.addEvent(1, 1920, .end_of_track, .empty);
    const seq = try b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = try anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    var native = try nativeThreeSegments(gpa);
    defer native.deinit();
    var n = try derive(gpa, &native);
    defer n.deinit();

    var smf_buf: [1024]u8 = undefined;
    var native_buf: [1024]u8 = undefined;
    var wa = std.Io.Writer.fixed(&smf_buf);
    var wb = std.Io.Writer.fixed(&native_buf);
    try d.echo(&wa);
    try n.echo(&wb);
    try testing.expectEqualStrings(wb.buffered(), wa.buffered());

    try testing.expectEqual(@as(usize, 3), d.map.segments.len);
    try testing.expectEqual(@as(i64, 46_126_080), d.map.segments[1].tick);
    try testing.expectEqual(@as(f64, 400_000), d.map.segments[1].us);
    try testing.expect(d.map.integral);
    try testing.expectEqual(@as(usize, 0), d.diags.items().len);
}

test "derive: an IT conductor — Txx rows through the timing walk" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    const module = try test_support.threeSegmentModule(gpa);
    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    doc.anchors = try anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.it = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    var native = try nativeThreeSegments(gpa);
    defer native.deinit();
    var n = try derive(gpa, &native);
    defer n.deinit();

    var it_buf: [1024]u8 = undefined;
    var native_buf: [1024]u8 = undefined;
    var wa = std.Io.Writer.fixed(&it_buf);
    var wb = std.Io.Writer.fixed(&native_buf);
    try d.echo(&wa);
    try n.echo(&wb);
    try testing.expectEqualStrings(wb.buffered(), wa.buffered());

    // The walk's own map comes back with the derivation, so a studio
    // reads the tracker position from it (`Playhead.orderRowAt`).
    try testing.expect(d.rowmap != null);
    try testing.expectEqual(@as(i64, 102), d.rowmap.?.total_ticks);
    try testing.expectEqual(@as(usize, 0), d.diags.items().len);
}

test "derive: an IT T0x slide yields one tempo segment per tick" {
    // Hand computation. Speed 6, tempo 125; `T01` on row 0 slides the
    // tempo DOWN by one on every non-row tick, so IT ticks 1..5 carry
    // 124, 123, 122, 121 and 120 — five changes plus the initial
    // segment. One IT tick is 1 921 920 tempura ticks.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    try b.addOrder(0);
    try b.addOrder(1);
    const song = try b.addPattern(1);
    song.at(0, 0).* = .{ .fx = 'T' - '@', .param = 0x01 };
    const tail = try b.addPattern(1);
    tail.at(0, 0).* = .{ .fx = 'B' - '@', .param = 1 };
    const module = b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    doc.anchors = try anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.it = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 6), d.map.segments.len);
    for (d.map.segments, 0..) |s, i| {
        try testing.expectEqual(@as(i64, @intCast(i)) * Grid.IT_TICK, s.tick);
    }
    // 60 000 000 / 124 is not an integer, so the whole table takes the
    // f64 path (plan 03, "The segment table").
    try testing.expect(!d.map.integral);
}

test "derive: conductor_conflict — one owner of time per document" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    const arena = doc.arena.allocator();
    const tempo = try arena.alloc(tm.TempoPoint, 1);
    tempo[0] = .{ .tick = 0, .tempo = .{ .us = 500_000 }, .span = .{ .start = 12, .end = 40 } };
    const meter = try arena.alloc(tm.MeterPoint, 1);
    meter[0] = .{ .tick = 0, .n = 3, .d = 4, .span = .{ .start = 41, .end = 70 } };
    doc.tempo = tempo;
    doc.meter = meter;
    doc.anchors = try anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 2), d.diags.count(.conductor_conflict));
    try testing.expectEqual(@as(u32, 12), d.diags.items()[0].span.start);
    // The anchor has no dump to conduct with, so the tables fall back to
    // 120 quarter notes per minute in [4 4] — the document's own points
    // are refused, never silently honoured.
    try testing.expectEqual(@as(usize, 1), d.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), d.map.segments[0].us);
    try testing.expectEqual(@as(u8, 4), d.map.meters[0].n);
}

test "derive: an SMF conductor with SMPTE division is one 120 qpm segment" {
    // Plan 03, rule 2: SMPTE ticks are wall-clock by definition, so the
    // file's `set-tempo` events are ignored for timing and said so.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .smpte = .{ .fps = 25, .tpf = 40 } };
    _ = try b.addTrack();
    try b.addEvent(0, 0, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(0, 500, .end_of_track, .empty);
    const seq = try b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = try anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), d.map.segments[0].us);
    try testing.expectEqual(@as(usize, 1), d.diags.count(.smpte_tempo_ignored));
}

test "derive: an SMF division that does not divide TPQ says division_inexact once" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    // 500 does not divide 46 126 080 (plan 03, "The grid").
    b.division = .{ .ppq = 500 };
    _ = try b.addTrack();
    try b.addEvent(0, 1, .set_tempo, .{ .tempo = 400_000 });
    try b.addEvent(0, 3, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(0, 3, .end_of_track, .empty);
    const seq = try b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = try anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.diags.count(.division_inexact));
    // A file whose first tempo comes late plays at 120 until it: the
    // table opens with the SMF default at tick 0.
    try testing.expectEqual(@as(usize, 3), d.map.segments.len);
    try testing.expectEqual(@as(i64, 0), d.map.segments[0].tick);
    try testing.expectEqual(@as(f64, 500_000), d.map.segments[0].us);
}

test "derive: equal SMF ticks keep file order and the last set-tempo wins" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    _ = try b.addTrack();
    // Track 1 and track 2 both name tick 0; the LAST in file order wins.
    try b.addEvent(0, 0, .set_tempo, .{ .tempo = 480_000 });
    try b.addEvent(1, 0, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(0, 0, .end_of_track, .empty);
    try b.addEvent(1, 0, .end_of_track, .empty);
    const seq = try b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = try anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.map.segments.len);
    try testing.expectEqual(@as(f64, 300_000), d.map.segments[0].us);
}

test "derive: an SMF time-signature is the meter map" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    // `nn` 3 over `dd` 2, which is 2^2 = 4: three quarter notes to a bar.
    try b.addEvent(
        0,
        0,
        .time_signature,
        .{ .time_sig = .{ .nn = 3, .dd = 2, .cc = 24, .bb = 8 } },
    );
    try b.addEvent(0, 2880, .end_of_track, .empty);
    const seq = try b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    doc.anchors = try anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.map.meters.len);
    try testing.expectEqual(@as(u8, 3), d.map.meters[0].n);
    try testing.expectEqual(@as(u8, 4), d.map.meters[0].d);
    // Three tracks' worth of nothing: the SMF's own end is 2880 pulses =
    // 3q = 138 378 240 ticks, which is exactly one [3 4] bar, so the
    // default `:length` is that bar line.
    try testing.expectEqual(@as(i64, 138_378_240), d.map.length);
}

test "derive: an IT highlight becomes the meter, [major/minor 4]" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    // 12 rows to the measure, 4 to the beat — three beats a bar.
    b.module.header.highlight_minor = 4;
    b.module.header.highlight_major = 12;
    try b.addOrder(0);
    _ = try b.addPattern(4);
    const module = b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    doc.anchors = try anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.it = tiers;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(u8, 3), d.map.meters[0].n);
    try testing.expectEqual(@as(u8, 4), d.map.meters[0].d);
}

test "derive: a highlight that does not divide truncates, as the document layer does" {
    // 14 rows to the measure over 4 to the beat is three and a half
    // beats, and plan 03 says `[major / minor, 4]` — an integer
    // division. `fromSjon.itConductor` is the one reading of that rule
    // and this layer inherits it: `[3 4]`, not `[4 4]`.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    b.module.header.highlight_minor = 4;
    b.module.header.highlight_major = 14;
    try b.addOrder(0);
    _ = try b.addPattern(4);
    const module = b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    doc.anchors = try anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.it = tiers;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(u8, 3), d.map.meters[0].n);
    try testing.expectEqual(@as(u8, 4), d.map.meters[0].d);
}

// ---- tests: bound lanes ----

test "derive: a bound SMF notes lane, paired and converted to the grid" {
    // Hand computation. Division 960 divides TPQ (46 126 080 / 960 =
    // 48 048), so SMF tick 480 is 480 · 48 048 = 23 063 040 = half a
    // quarter. The note-on at 0 is closed by the note-off at 480.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    try b.addEvent(0, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(0, 480, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
    try b.addEvent(0, 0, .control_change, .{ .control = .{ .ch = 0, .num = 74, .val = 0 } });
    try b.addEvent(0, 480, .control_change, .{ .control = .{ .ch = 0, .num = 74, .val = 127 } });
    try b.addEvent(0, 960, .end_of_track, .empty);
    const seq = try b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.SmfTier, 1);
    tiers[0] = .{ .anchor = "song", .sequence = seq };
    const lanes = try arena.alloc(value.Lane, 2);
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    lanes[0] = .{
        .name = "lead",
        .kind = .notes,
        .target = "lead",
        .range = null,
        .binding = .{
            .anchor = "song",
            .address = .{ .smf = .{ .track = 1, .ch = .single(0), .key = null, .curve = null } },
        },
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    lanes[1] = .{
        .name = "cutoff",
        .kind = .curve,
        .target = "cutoff",
        .range = null,
        .binding = .{
            .anchor = "song",
            .address = .{
                .smf = .{ .track = 1, .ch = .single(0), .key = null, .curve = .{ .cc = 74 } },
            },
        },
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    doc.anchors = try anchorsOf(&doc, .smf);
    doc.conductor = "song";
    doc.midi = tiers;
    doc.lanes = lanes;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lead = d.laneByName("lead").?;
    try testing.expect(lead.bound);
    // The address's channel and the file's own release velocity ride
    // on the onset: a renderer writes the pair back on `:ch`, and the
    // playhead simply ignores both.
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = 23_063_040, .key = 60, .vel = 100, .ch = 0, .off_vel = 64 },
    }, lead.onsets);

    // A bound curve's value stays NORMALISED; `:range` scales it at
    // export (plan 02), so nothing here knows what it drives.
    const cutoff = d.laneByName("cutoff").?;
    try testing.expectEqual(@as(usize, 2), cutoff.steps.len);
    try testing.expectEqual(@as(i64, 0), cutoff.steps[0].tick);
    try testing.expectEqual(@as(f32, 0), cutoff.steps[0].value[0]);
    try testing.expectEqual(@as(i64, 23_063_040), cutoff.steps[1].tick);
    try testing.expectEqual(@as(f32, 1), cutoff.steps[1].value[0]);
}

test "derive: a bound SMF lane over ticks at i64's ends derives, and its onsets hold" {
    // `:at -1e30` saturated to `minInt(i64)` and the pairing's
    // `track_end - at` overflowed on every derive of this document; a
    // note-on at `1e30` is `maxInt(i64)`, where `at + dur` has no room.
    // The reader floors a negative tick at 0 (the manifest has refused
    // it already), the pairing saturates, and the conversion caps at the
    // grid's ceiling.
    const gpa = testing.allocator;
    var loaded = try test_support.load(gpa,
        \\(timeline :title "edges")
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(anchor :id song :kind smf :file "x.mid")
        \\(midi/smf :format 0 :division 480)
        \\(midi/mtrk
        \\  (note-on      :at -1e30 :ch 1 :key 36 :vel 100)
        \\  (note-on      :at 1e30  :ch 1 :key 38 :vel 100)
        \\  (note-off     :at 1e30  :ch 1 :key 38 :vel 64)
        \\  (end-of-track :at 1e30))
        \\(lane :name kick :kind notes :from song :track 1 :ch 1)
    );
    defer loaded.deinit();
    try testing.expect(loaded.diags.hasErrors());

    var d = try derive(gpa, &loaded.doc);
    defer d.deinit();
    const kick = d.laneByName("kick").?;
    try testing.expectEqual(@as(usize, 2), kick.onsets.len);
    try testing.expectEqual(@as(i64, 0), kick.onsets[0].tick);
    try testing.expectEqual(Grid.MAX_TICK, kick.onsets[0].dur);
    try testing.expectEqual(Grid.MAX_TICK, kick.onsets[1].tick);
    try testing.expectEqual(@as(i64, 0), kick.onsets[1].dur);
}

test "derive: a bound IT notes lane reads the module through the walk" {
    // Hand computation. Speed 6, so a row is six IT ticks: the note on
    // row 0 of channel 1 sounds at IT tick 0 and the `===` on row 2 ends
    // it at IT tick 12. One IT tick is 1 921 920 tempura ticks, so the
    // note is 23 063 040 long — half a quarter.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    try b.addOrder(0);
    const pat = try b.addPattern(4);
    pat.at(0, 1).* = .{ .note = 60, .ins = 1 };
    pat.at(2, 1).* = .{ .note = Module.note_off, .ins = 0 };
    const module = b.finish();

    const arena = doc.arena.allocator();
    const tiers = try arena.alloc(value.ItTier, 1);
    tiers[0] = .{ .anchor = "song", .module = module };
    const lanes = try arena.alloc(value.Lane, 1);
    lanes[0] = .{
        .name = "bass",
        .kind = .notes,
        .target = "bass",
        .range = null,
        .binding = .{
            .anchor = "song",
            .address = .{ .it = .{ .channel = 1, .column = null, .fx = null } },
        },
        .notes = &.{},
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = .{ .start = 0, .end = 1 },
    };
    doc.anchors = try anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.it = tiers;
    doc.lanes = lanes;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const bass = d.laneByName("bass").?;
    try testing.expect(bass.bound);
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = 23_063_040, .key = 60, .vel = 127 },
    }, bass.onsets);
}

test "derive: a clip whose repeats overflow the grid places its window and stops" {
    // `:repeat` has no schema maximum, so `phrase.length · repeat` is
    // user arithmetic over the whole i64 range: four thousand million
    // repeats of a phrase 2^40 ticks long is 4.8 · 10^21, which no i64
    // holds. The window is one quarter, so only the first repeat places
    // anything and the loop stops at the first repeat past it.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    const arena = doc.arena.allocator();
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    const tempo = try arena.alloc(tm.TempoPoint, 1);
    tempo[0] = .{ .tick = 0, .tempo = .{ .us = 500_000 } };
    const meter = try arena.alloc(tm.MeterPoint, 1);
    meter[0] = .{ .tick = 0, .n = 4, .d = 4 };

    const phrase_notes = try arena.alloc(value.Note, 1);
    phrase_notes[0] = .{
        .at = 0,
        .dur = TPQ / 4,
        .key = 38,
        .vel = 100,
        .ch = 0,
        .off_vel = null,
        .span = span,
    };
    const phrase_lanes = try arena.alloc(value.Lane, 1);
    phrase_lanes[0] = .{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    const phrases = try arena.alloc(value.Phrase, 1);
    phrases[0] = .{ .name = "fill", .length = 1 << 40, .lanes = phrase_lanes, .span = span };

    const clips = try arena.alloc(value.Clip, 1);
    clips[0] = .{
        .at = 0,
        .phrase = "fill",
        .repeat = 4_000_000_000,
        .offset = 0,
        .length = TPQ,
        .transpose = 0,
        .span = span,
    };
    const lanes = try arena.alloc(value.Lane, 1);
    lanes[0] = .{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &.{},
        .clips = clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    doc.tempo = tempo;
    doc.meter = meter;
    doc.phrases = phrases;
    doc.lanes = lanes;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    // One note placed — the phrase's own, at the clip's `:at` — and the
    // repeats past the window never formed a tick.
    const lane = d.laneByName("flash").?;
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 0, .dur = 11_531_520, .key = 38, .vel = 100 },
    }, lane.onsets);
}

test "derive: a clip that would place content past the grid ceiling says so" {
    // The phrase is one bar long and the clip sits one bar below the
    // ceiling with an unbounded window, so the second repeat has nowhere
    // to land: `tick_overflow`, and the derivation keeps what fits.
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    const arena = doc.arena.allocator();
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    const tempo = try arena.alloc(tm.TempoPoint, 1);
    tempo[0] = .{ .tick = 0, .tempo = .{ .us = 500_000 } };
    const meter = try arena.alloc(tm.MeterPoint, 1);
    meter[0] = .{ .tick = 0, .n = 4, .d = 4 };

    const phrase_notes = try arena.alloc(value.Note, 1);
    phrase_notes[0] = .{
        .at = 0,
        .dur = TPQ / 4,
        .key = 38,
        .vel = 100,
        .ch = 0,
        .off_vel = null,
        .span = span,
    };
    const phrase_lanes = try arena.alloc(value.Lane, 1);
    phrase_lanes[0] = .{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    const phrases = try arena.alloc(value.Phrase, 1);
    phrases[0] = .{ .name = "fill", .length = bar44, .lanes = phrase_lanes, .span = span };

    const clips = try arena.alloc(value.Clip, 1);
    clips[0] = .{
        .at = Grid.MAX_TICK - bar44,
        .phrase = "fill",
        .repeat = 4_000_000_000,
        .offset = 0,
        .length = null,
        .transpose = 0,
        .span = span,
    };
    const lanes = try arena.alloc(value.Lane, 1);
    lanes[0] = .{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &.{},
        .clips = clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    doc.tempo = tempo;
    doc.meter = meter;
    doc.phrases = phrases;
    doc.lanes = lanes;
    doc.length = bar44;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.diags.count(.tick_overflow));
    const lane = d.laneByName("flash").?;
    try testing.expectEqual(@as(usize, 2), lane.onsets.len);
    try testing.expectEqual(@as(i64, Grid.MAX_TICK - bar44), lane.onsets[0].tick);
    try testing.expectEqual(@as(i64, Grid.MAX_TICK), lane.onsets[1].tick);
}

test "derive.echo: a cue name's quotes and backslashes are escaped" {
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    const arena = doc.arena.allocator();
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    const tempo = try arena.alloc(tm.TempoPoint, 1);
    tempo[0] = .{ .tick = 0, .tempo = .{ .us = 500_000 } };
    const meter = try arena.alloc(tm.MeterPoint, 1);
    meter[0] = .{ .tick = 0, .n = 4, .d = 4 };
    const cues = try arena.alloc(value.Cue, 1);
    cues[0] = .{ .name = "say \"hi\" \\ bye", .at = 0, .span = span };
    doc.tempo = tempo;
    doc.meter = meter;
    doc.cues = cues;
    doc.length = 0;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try d.echo(&w);
    try testing.expect(
        std.mem.indexOf(u8, w.buffered(), "(cue :name \"say \\\"hi\\\" \\\\ bye\" :at 0)") != null,
    );
}

test "derive: one clip with :repeat, :offset, :length and :transpose at once" {
    // Hand computation. The phrase is one quarter long and holds notes
    // at 0 and 0.5q; `:repeat 3` makes its own timeline
    //
    //   0    0.5q   1q   1.5q   2q   2.5q      (source ticks)
    //
    // `:offset 0.5q` and `:length 1.5q` take the window
    // [0.5q, 2q) — so the note at 0 is before it and the note at 2q is
    // past it, four of the six remain, and each lands at
    // `3bar + (s − 0.5q)` with `:transpose −2` on its key:
    //
    //   0.5q → 553 512 960          key 36
    //   1q   → 576 576 000          key 36
    //   1.5q → 599 639 040          key 36
    //   2q   → dropped (the window ends there)
    const gpa = testing.allocator;
    var doc: Doc = .empty(gpa);
    defer doc.deinit();

    const arena = doc.arena.allocator();
    const span: Diag.Span = .{ .start = 0, .end = 1 };
    const tempo = try arena.alloc(tm.TempoPoint, 1);
    tempo[0] = .{ .tick = 0, .tempo = .{ .us = 500_000 } };
    const meter = try arena.alloc(tm.MeterPoint, 1);
    meter[0] = .{ .tick = 0, .n = 4, .d = 4 };

    const phrase_notes = try arena.alloc(value.Note, 2);
    phrase_notes[0] = .{
        .at = 0,
        .dur = TPQ / 4,
        .key = 38,
        .vel = 100,
        .ch = 0,
        .off_vel = null,
        .span = span,
    };
    phrase_notes[1] = .{
        .at = TPQ / 2,
        .dur = TPQ / 4,
        .key = 38,
        .vel = 80,
        .ch = 0,
        .off_vel = null,
        .span = span,
    };
    const phrase_lanes = try arena.alloc(value.Lane, 1);
    phrase_lanes[0] = .{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = phrase_notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    const phrases = try arena.alloc(value.Phrase, 1);
    phrases[0] = .{ .name = "fill", .length = TPQ, .lanes = phrase_lanes, .span = span };

    const clips = try arena.alloc(value.Clip, 1);
    clips[0] = .{
        .at = 3 * bar44,
        .phrase = "fill",
        .repeat = 3,
        .offset = TPQ / 2,
        .length = 3 * TPQ / 2,
        .transpose = -2,
        .span = span,
    };
    const lanes = try arena.alloc(value.Lane, 1);
    lanes[0] = .{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = &.{},
        .keyframes = &.{},
        .clips = clips,
        .query_src = null,
        .expr_src = null,
        .span = span,
    };
    doc.tempo = tempo;
    doc.meter = meter;
    doc.phrases = phrases;
    doc.lanes = lanes;

    var d = try derive(gpa, &doc);
    defer d.deinit();

    const lane = d.laneByName("flash").?;
    try testing.expectEqualSlices(Onset, &.{
        .{ .tick = 553_512_960, .dur = 11_531_520, .key = 36, .vel = 80 },
        .{ .tick = 576_576_000, .dur = 11_531_520, .key = 36, .vel = 100 },
        .{ .tick = 599_639_040, .dur = 11_531_520, .key = 36, .vel = 80 },
    }, lane.onsets);
    // The window's end is the `:length` default's input too: 3bar + 1.5q
    // rounded up to a bar is bar 4.
    try testing.expectEqual(@as(i64, 4 * bar44), d.map.length);
}

// ---- tests: allocation failure ----

/// The OOM sweep over `derive` for one document: at EVERY allocation
/// index the call fails with `error.OutOfMemory` and `testing.allocator`
/// sees no leak, and past the last one the derivation is whole. Bounded
/// by the number of allocations the call makes, which the loop discovers
/// and hands back.
fn expectDeriveOomClean(doc: *const Doc) !usize {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = derive(failing.allocator(), doc);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var derived = try result;
            derived.deinit();
            return fail_index;
        }
    }
}

/// A native document with every kind of content a derivation copies: two
/// tempo segments, a meter change, a section, a cue, a notes lane with a
/// clip to expand, a curve lane, and no `:length`, so the default is
/// worked out through a probe map of its own.
const sweep_native =
    \\(timeline)
    \\(tempo-point :at 0q :qpm 120)
    \\(tempo-point :at 1bar :qpm 97.3)
    \\(meter-point :at 0bar :sig [4 4])
    \\(meter-point :at 2bar :sig [3 4])
    \\(section :name intro :at 0bar :dur 2bar)
    \\(cue :name "drop" :at 1bar)
    \\(phrase :name fill :length 1bar
    \\  (lane :name flash
    \\    (note :at 0q :dur 0.25q :key 38 :vel 100)))
    \\(lane :name flash :kind notes :target flash
    \\  (note :at 0q :dur 0.5q :key 36 :vel 110)
    \\  (clip :at 2bar :phrase fill :repeat 2 :offset 0.5q :length 1q :transpose 12))
    \\(lane :name glow :kind curve :target glow
    \\  (keyframe :at 0q :value 0.2 :ease hold)
    \\  (keyframe :at 1bar :value 0.9 :ease in-cubic))
;

/// An inline `.mid` that conducts, with a notes lane and a curve lane
/// bound to it: the conductor's copy-out and relay, and both SMF bridges.
const sweep_smf =
    \\(timeline :conductor song)
    \\(anchor :id song :kind smf :file "x.mid")
    \\(midi/smf :format 0 :division 480)
    \\(midi/mtrk
    \\  (set-tempo      :at 0    :us 500000)
    \\  (control-change :at 0    :ch 1 :num 74 :val 10)
    \\  (note-on        :at 0    :ch 1 :key 36 :vel 100)
    \\  (note-off       :at 240  :ch 1 :key 36 :vel 64)
    \\  (control-change :at 960  :ch 1 :num 74 :val 100)
    \\  (note-on        :at 960  :ch 1 :key 41 :vel 80)
    \\  (note-off       :at 1200 :ch 1 :key 41 :vel 64)
    \\  (end-of-track   :at 1920))
    \\(lane :name kick :kind notes :from song :track 1 :ch 1)
    \\(lane :name filter :kind curve :from song :track 1 :ch 1 :cc 74)
;

/// An inline `.it` with a notes lane and a curve lane bound to it, under
/// a head (`{s}`) that says who keeps time. Conducted by the module, the
/// lanes read the conductor's own walk; timed by the document, each walks
/// the module for itself.
const sweep_it =
    \\{s}
    \\(anchor :id mod :kind it :file "x.it")
    \\(it/module :title "bound"
    \\  (it/timing :speed 24 :tempo 125)
    \\  (it/orders 0 1 2 2 end)
    \\  (it/pattern 0 :rows 4
    \\    (row 0 (ev 1 "C-5" :ins 1 :vol 64 :fx "G01"))
    \\    (row 2 (ev 1 "E-5" :ins 1)))
    \\  (it/pattern 1 :rows 4
    \\    (row 0 (ev 1 "G-5" :ins 1)))
    \\  (it/pattern 2 :rows 4))
    \\(lane :name lead :kind notes :from mod :channel 1)
    \\(lane :name loud :kind curve :from mod :channel 1 :column vol)
;

test "derive: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit" — the derivation's arena, its report, the
    // conductor's walk moved into it, and every bridge's scratch — over
    // five documents that between them reach every allocating path here:
    // native content and clips, both conductors, both bound bridges, the
    // IT lane's walk of its own, and the placeholder said out loud.
    const gpa = testing.allocator;

    const conducted_head = "(timeline :conductor mod)";
    const it_conducted = try std.fmt.allocPrintSentinel(gpa, sweep_it, .{conducted_head}, 0);
    defer gpa.free(it_conducted);
    const native_head = "(timeline)\n(tempo-point :at 0q :qpm 125)\n" ++
        "(meter-point :at 0bar :sig [4 4])";
    const it_native = try std.fmt.allocPrintSentinel(gpa, sweep_it, .{native_head}, 0);
    defer gpa.free(it_native);

    for ([_][:0]const u8{ sweep_native, sweep_smf, it_conducted, it_native }) |source| {
        var res = try test_support.load(gpa, source);
        defer res.deinit();
        if (res.diags.hasErrors()) {
            for (res.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
            return error.TestSweepFixtureDoesNotLoad;
        }
        // A sweep that fails nothing proves nothing: the derivation's
        // arena and its map's are each asked for memory, at the least.
        try testing.expect(try expectDeriveOomClean(&res.doc) >= 2);
    }

    // The placeholder, with the document's own points refused: a `Doc`
    // built the way a host might, since a load says the conflict first.
    var doc: Doc = .empty(gpa);
    defer doc.deinit();
    const arena = doc.arena.allocator();
    const tempo = try arena.alloc(tm.TempoPoint, 1);
    tempo[0] = .{ .tick = 0, .tempo = .{ .us = 500_000 } };
    const meter = try arena.alloc(tm.MeterPoint, 1);
    meter[0] = .{ .tick = 0, .n = 3, .d = 4 };
    doc.tempo = tempo;
    doc.meter = meter;
    doc.anchors = try anchorsOf(&doc, .it);
    doc.conductor = "song";
    doc.length = bar44;
    try testing.expect(try expectDeriveOomClean(&doc) >= 2);
}

// ---- tests: the two layers derive one map ----

test "derive: an SMF-anchored document's map is the one fromSource built" {
    // The pin for "one owner of the conductor rules": the document layer
    // reads the tier (`fromSjon.smfConductor`) and resolves the
    // document's positions against it; this layer asks that same
    // function and adds the same `:length` default. Two maps, one text.
    const gpa = testing.allocator;

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    _ = try b.addTrack();
    try b.addEvent(1, 0, .set_tempo, .{ .tempo = 480_000 });
    try b.addEvent(1, 960, .set_tempo, .{ .tempo = 400_000 });
    try b.addEvent(1, 1920, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(
        0,
        0,
        .time_signature,
        .{ .time_sig = .{ .nn = 4, .dd = 2, .cc = 24, .bb = 8 } },
    );
    try b.addEvent(0, 3840, .end_of_track, .empty);
    try b.addEvent(1, 3840, .end_of_track, .empty);
    var seq = try b.finish();
    defer seq.deinit();

    const dump = try bridge_smf.sequenceToForms(gpa, &seq, null, .{});
    defer gpa.free(dump);
    const source = try std.fmt.allocPrintSentinel(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind smf :file "x.mid")
        \\{s}
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash
        \\    (note :at 0q :dur 0.25q :key 38 :vel 100)))
        \\(lane :name flash :kind notes :target flash
        \\  (note :at 0q :dur 0.5q :key 36 :vel 110)
        \\  (clip :at 2bar :phrase fill :repeat 2 :offset 0.5q :length 1q :transpose 12))
    , .{dump}, 0);
    defer gpa.free(source);

    var res = try test_support.load(gpa, source);
    defer res.deinit();
    try testing.expect(!res.diags.hasErrors());

    var d = try derive(gpa, &res.doc);
    defer d.deinit();

    var mine: [1024]u8 = undefined;
    var theirs: [1024]u8 = undefined;
    var wa = std.Io.Writer.fixed(&mine);
    var wb = std.Io.Writer.fixed(&theirs);
    try d.map.echo(&wa);
    try res.map.echo(&wb);
    try testing.expectEqualStrings(wb.buffered(), wa.buffered());
    try testing.expectEqual(@as(usize, 3), d.map.segments.len);
}

test "derive: an IT-anchored document's map is the one fromSource built" {
    const gpa = testing.allocator;

    var module = try test_support.threeSegmentModule(gpa);
    defer module.deinit();

    const dump = try bridge_it.moduleToForms(gpa, &module, .{});
    defer gpa.free(dump);
    const source = try std.fmt.allocPrintSentinel(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "x.it")
        \\{s}
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash
        \\    (note :at 0q :dur 0.25q :key 38 :vel 100)))
        \\(lane :name flash :kind notes :target flash
        \\  (note :at 0q :dur 0.5q :key 36 :vel 110)
        \\  (clip :at 2bar :phrase fill :repeat 2 :offset 0.5q :length 1q :transpose 12))
    , .{dump}, 0);
    defer gpa.free(source);

    var res = try test_support.load(gpa, source);
    defer res.deinit();
    try testing.expect(!res.diags.hasErrors());

    var d = try derive(gpa, &res.doc);
    defer d.deinit();

    var mine: [1024]u8 = undefined;
    var theirs: [1024]u8 = undefined;
    var wa = std.Io.Writer.fixed(&mine);
    var wb = std.Io.Writer.fixed(&theirs);
    try d.map.echo(&wa);
    try res.map.echo(&wb);
    try testing.expectEqualStrings(wb.buffered(), wa.buffered());
    try testing.expectEqual(@as(usize, 3), d.map.segments.len);
    // …and the walk came back with it, which is what the tracker
    // position and a bound IT lane read.
    try testing.expect(d.rowmap != null);
}

test "derive: a BY-REFERENCE SMF conductor gives the map its inline twin gives" {
    // The final review's C1, at this layer: `conduct` returned the
    // placeholder for "an anchor with no inline tier" whether or not the
    // file was in hand, so a document the resolver had already read and
    // verified was timed at 120 quarter notes per minute. Plan 03's
    // rules draw no such line, and `fromSjon.conductorOf` is now the one
    // owner both layers and both spellings go through.
    //
    // One sequence, two documents: the tier dumped INLINE, and an anchor
    // that only names the file those same bytes make. The maps are one
    // text, three times over — the load's, the derivation's, and the
    // inline twin's.
    const gpa = testing.allocator;

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 960 };
    _ = try b.addTrack();
    _ = try b.addTrack();
    try b.addEvent(1, 0, .set_tempo, .{ .tempo = 480_000 });
    try b.addEvent(1, 960, .set_tempo, .{ .tempo = 400_000 });
    try b.addEvent(
        0,
        0,
        .time_signature,
        .{ .time_sig = .{ .nn = 3, .dd = 2, .cc = 24, .bb = 8 } },
    );
    try b.addEvent(0, 2880, .end_of_track, .empty);
    try b.addEvent(1, 2880, .end_of_track, .empty);
    var seq = try b.finish();
    defer seq.deinit();

    // The inline spelling.
    const dump = try bridge_smf.sequenceToForms(gpa, &seq, null, .{});
    defer gpa.free(dump);
    const inline_source = try std.fmt.allocPrintSentinel(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind smf :file "x.mid")
        \\{s}
        \\(cue :name "two" :at 1bar)
    , .{dump}, 0);
    defer gpa.free(inline_source);

    var inline_res = try test_support.load(gpa, inline_source);
    defer inline_res.deinit();
    try testing.expect(!inline_res.diags.hasErrors());

    // …and the by-reference one, over the file the writer makes of it.
    var file = try test_support.smfBytes(gpa, &seq);
    defer file.deinit();
    const anchor_root = try test_support.anchorByReference(gpa, "song", "smf", "x.mid", file.bytes);
    defer gpa.free(anchor_root);
    const ref_source = try std.fmt.allocPrintSentinel(gpa,
        \\(timeline :conductor song)
        \\{s}
        \\(cue :name "two" :at 1bar)
    , .{anchor_root}, 0);
    defer gpa.free(ref_source);

    var ref_res = try test_support.loadWithFile(gpa, ref_source, "x.mid", file.bytes);
    defer ref_res.deinit();
    for (ref_res.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
    try testing.expect(!ref_res.diags.hasErrors());

    var d = try derive(gpa, &ref_res.doc);
    defer d.deinit();
    try testing.expect(!d.diags.hasErrors());

    var buf_a: [1024]u8 = undefined;
    var buf_b: [1024]u8 = undefined;
    var buf_c: [1024]u8 = undefined;
    var wa = std.Io.Writer.fixed(&buf_a);
    var wb = std.Io.Writer.fixed(&buf_b);
    var wc = std.Io.Writer.fixed(&buf_c);
    try d.map.echo(&wa);
    try ref_res.map.echo(&wb);
    try inline_res.map.echo(&wc);
    try testing.expectEqualStrings(wb.buffered(), wa.buffered());
    try testing.expectEqualStrings(wc.buffered(), wa.buffered());

    // The file's two segments and its `[3 4]`, not the placeholder's one
    // segment at 500 000 in `[4 4]`.
    try testing.expectEqual(@as(usize, 2), d.map.segments.len);
    try testing.expectEqual(@as(f64, 400_000), d.map.segments[1].us);
    try testing.expectEqual(@as(i64, 3 * Grid.TPQ), ref_res.doc.cues[0].at);
}

test "derive: a conducted document whose file nobody can read says anchor_unavailable" {
    // The placeholder STAYS — a document has to be answerable — and the
    // derivation says whose time it is not. Silence here was C1's other
    // half: `timeline` printed 500 000 microseconds with no diagnostic.
    const gpa = testing.allocator;
    var res = try test_support.load(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind smf :file "x.mid")
        \\(cue :name "two" :at 1bar)
    );
    defer res.deinit();

    var d = try derive(gpa, &res.doc);
    defer d.deinit();

    try testing.expectEqual(@as(usize, 1), d.diags.count(.anchor_unavailable));
    try testing.expect(d.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), d.map.segments.len);
    try testing.expectEqual(@as(f64, 500_000), d.map.segments[0].us);
    try testing.expect(fromSjon.conductedPlaceholder(&res.doc));
}

test "derive: a conductor nobody can produce times the document by the placeholder, in all three layers" {
    // The three derivations of the conductor tables disagreed here. The
    // load and `mapOf` fell back to the document's OWN points when it
    // had any, while `conduct` took the placeholder — so the edit engine
    // (planning against `Result.map`) and the playhead and the exporters
    // (reading `Derived.map`) read two maps of one document, and the
    // load's `anchor_unavailable` ("every position is the placeholder's
    // 120 quarter notes per minute") was false. Plans 02 and 03 decide
    // it: a conducted document's own points are `conductor_conflict`,
    // one owner of time, so they never time it — the conductor does, or
    // the placeholder stands in for it and says so.
    const gpa = testing.allocator;
    const sources = [_][:0]const u8{
        // The anchor is there and its file is not.
        \\(timeline :conductor song)
        \\(anchor :id song :kind smf :file "x.mid")
        \\(tempo-point :at 0q :qpm 90)
        \\(meter-point :at 0bar :sig [3 4])
        \\(cue :name "two" :at 2bar)
        ,
        // The conductor names no anchor at all.
        \\(timeline :conductor song)
        \\(tempo-point :at 0q :qpm 90)
        \\(meter-point :at 0bar :sig [3 4])
        \\(cue :name "two" :at 2bar)
        ,
    };
    for (sources) |source| {
        var res = try test_support.load(gpa, source);
        defer res.deinit();
        try testing.expect(res.diags.count(.conductor_conflict) == 2);

        var d = try derive(gpa, &res.doc);
        defer d.deinit();
        var mapped = try fromSjon.mapOf(gpa, &res.doc);
        defer mapped.deinit();

        for ([_]*const TimeMap{ &res.map, &mapped, &d.map }) |m| {
            try testing.expectEqual(@as(usize, 1), m.segments.len);
            try testing.expectEqual(@as(f64, 500_000), m.segments[0].us);
            try testing.expectEqual(@as(u8, 4), m.meters[0].n);
        }
        // `2bar` resolved on the placeholder's `[4 4]`, and the default
        // `:length` is that same bar line in every layer.
        try testing.expectEqual(@as(i64, 8 * Grid.TPQ), res.doc.cues[0].at);
        try testing.expectEqual(res.map.length, mapped.length);
        try testing.expectEqual(res.map.length, d.map.length);
    }
}

test "derive: a clip of :repeat 0 plays once, and the default :length counts its window" {
    // `repeat-count` is "at least once" (1..), and a `:repeat 0` the
    // manifest refused still lowers as 0. The window was computed four
    // times: `place` and `Select` played it once, `contentEnd` and
    // `checks` multiplied by the 0 — so the load's default `:length` was
    // 0 while the playhead placed the phrase's notes. One formula now,
    // `Clip.window`, and every layer plays it once.
    const gpa = testing.allocator;
    var res = try test_support.load(gpa,
        \\(timeline :title "zero")
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash
        \\    (note :at 1q :dur 1q :key 38)))
        \\(lane :name flash :kind notes
        \\  (clip :at 1bar :phrase fill :repeat 0))
    );
    defer res.deinit();

    var d = try derive(gpa, &res.doc);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 1), d.laneByName("flash").?.onsets.len);
    try testing.expectEqual(@as(i64, 8 * Grid.TPQ), res.map.length);
    try testing.expectEqual(res.map.length, d.map.length);
}

test "derive: a conducted document with no content of its own is as long as its file" {
    // Plan 02's `:length` default over an anchored document: the events
    // ARE the anchor's. The module plays 102 IT ticks — 196 035 840
    // tempura ticks — and the first bar line at or after that is bar 2,
    // 369 008 640. Both layers say so.
    const gpa = testing.allocator;

    var module = try test_support.threeSegmentModule(gpa);
    defer module.deinit();

    const dump = try bridge_it.moduleToForms(gpa, &module, .{});
    defer gpa.free(dump);
    const source = try std.fmt.allocPrintSentinel(gpa,
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "x.it")
        \\{s}
    , .{dump}, 0);
    defer gpa.free(source);

    var res = try test_support.load(gpa, source);
    defer res.deinit();
    try testing.expect(!res.diags.hasErrors());

    var d = try derive(gpa, &res.doc);
    defer d.deinit();

    try testing.expectEqual(@as(i64, 369_008_640), res.map.length);
    try testing.expectEqual(res.map.length, d.map.length);
}
