//! Bound content (plan 07, "Bound content, precisely").
//!
//! A bound lane's content is not in the document: it is in the anchor's
//! file, inline as a `(midi/mtrk …)` dump or an `(it/module …)` one, and
//! this file is where an operation reaches it. It is also the edit
//! engine's FRONT DOOR — `edit.plan` is `ops_bound.plan` — because the
//! routing question ("is this ask about an anchor's events?") is one
//! only a file that can answer both ways may ask: a selection that names
//! no bound lane goes straight on to `ops_native.zig`.
//!
//! What the two formats make of an operation is plan 07's paragraph,
//! kept here in one place:
//!
//!   * **SMF.** A note is the `(note-on, note-off)` pair the bridge
//!     paired. `retime` moves both, `resize` moves the off, `velocity`
//!     sets the on's `:vel`, `remove` removes both. The track's events
//!     stay non-decreasing in `:at`, so a move past a neighbour is a
//!     remove and an insert at the sorted index and equal ticks put the
//!     moved event after the ones already there. A controller step is a
//!     single event and moves like one.
//!   * **IT.** A note is a CELL, and its position is the `(order, row)`
//!     the walk reached it through. A `retime` onto a tick that is not a
//!     row start is an `SDx` delay in the cell's own effect column —
//!     `x ≤ 15`, and the column free — and `edit_inexact` otherwise. A
//!     `retime` across a pattern boundary moves the cell into the
//!     pattern the target order plays, which is `edit_pattern_shared`
//!     unless the ask carries `:allow-shared`. `velocity` writes the
//!     volume column, `resize` is `edit_inexact` (an IT note ends where
//!     the next cell starts; there is no `:dur` to write), and the
//!     effects on a moved cell travel with it.
//!     Every one of those edits is refused with `edit_pattern_shared`
//!     when the cell's pattern is played by more than one order —
//!     plan 07's diagnostics table is about the CELL and not about the
//!     operation that reached it, because a pattern is stored once and
//!     played many times, so a volume, a removal and a retime inside the
//!     pattern all change every occurrence. `:allow-shared` on the ask
//!     says that is what it means.
//!   * **`materialize`** copies an SMF lane's paired notes or controller
//!     steps into native children AND takes the source events out of the
//!     `(midi/mtrk …)`, because content has ONE home (plan 04). An IT
//!     lane is parked: a channel's cells serve every order that plays
//!     the pattern, so there is no removal that leaves one home.
//!
//! **The residue is untouched.** It is recomputed at build (plan 04),
//! and an edit that moved an event never rewrites it here.
//!
//! ## Three things a host should know about
//!
//! A move that has to be a remove and an insert loses the moved form's
//! comments — plan 07's own risk, since SJON's JSON bridge carries no
//! trivia — and this file takes the same way out as `ops_native.zig`:
//! the in-place `set_keyword` branch wherever the order allows.
//!
//! `moveEvents` here and `ops_native.moveInLane` run the SAME running model
//! over different rows — a `(slot, at, final)` triple, who keeps its slot,
//! then the removals and the inserts against what they left. The two pure
//! rules in that model are one function each (`ops_native.keptSlots`,
//! `ops_native.slotAmong`); the walks around them are not one function
//! because what each writes differs (one `:at` integer here, `writesFor`'s
//! whole override list there) and the extraction would need a callback per
//! difference.
//!
//! An `(ev …)` cell re-inserted somewhere else comes back spelled
//! `(ev :ins 1 1 "E-5")` rather than `(ev 1 "E-5" :ins 1)`: SJON's JSON
//! bridge emits a form's keyword pairs before its positional children
//! (`Json.zig`, `makeFormNode`), and the action grammar has no other way
//! to spell a form. The cell READS the same — `bridge_it`'s reader takes
//! the first number as the channel and a string as the note wherever
//! they sit — and the canonical printer puts the order back on the next
//! full print.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const doc = @import("../doc/doc.zig");
const Grid = @import("../time/Grid.zig");
const TimeMap = @import("../time/TimeMap.zig");
const model = @import("../itf/Module.zig");
const walk = @import("../itf/walk.zig");

const Op = @import("Op.zig");
const Plan = @import("Plan.zig");
const Select = @import("Select.zig");
const locate = @import("locate.zig");
const ops_native = @import("ops_native.zig");
const value = @import("value.zig");

const Ast = sjon.Ast;
const NodeIndex = Ast.NodeIndex;
const Site = locate.Site;
const testing = std.testing;

pub const Error = error{OutOfMemory};

/// Plan `op` over `d`, whose source `tree` is — the edit engine's entry
/// point for every operation, bound or not.
pub fn plan(
    gpa: std.mem.Allocator,
    d: *const doc.Doc,
    tree: *const sjon.Ast.Tree,
    op: Op.Op,
) Error!Plan.Plan {
    var map = try doc.fromSjon.mapOf(gpa, d);
    defer map.deinit();
    return planWith(gpa, d, tree, &map, op);
}

/// `plan`, for a caller that already has the document's map.
///
/// The ROUTER. An ask reaches an anchor's events only when it NAMES one
/// lane, that lane is bound, its anchor's dump is INLINE in this
/// document and the address is a shape this file can move. Everything
/// else goes on to `ops_native.zig` unchanged — a selection over every
/// lane, which "skips a bound one in silence" (plan 07, "Selection"); a
/// selection that mixes a bound lane with a native one, which is one
/// question with two answers; a lane whose anchor is by reference, which
/// `ops_native` refuses with `edit_target_bound`; and every operation
/// that has no meaning over a file's events.
pub fn planWith(
    gpa: std.mem.Allocator,
    d: *const doc.Doc,
    tree: *const sjon.Ast.Tree,
    map: *const TimeMap.TimeMap,
    op: Op.Op,
) Error!Plan.Plan {
    d.invariants();
    map.invariants();
    if (!routesHere(d, op)) return ops_native.planWith(gpa, d, tree, map, op);

    var b: Plan.Builder = .init(gpa);
    errdefer b.deinit();
    // Plan 03's ceiling over what the operation NAMES, before anything
    // is planned. `Op.offGrid` is the rule and `ops_native` raises it;
    // this is the second of the two plan entries, so it asks too — an
    // operation that reaches an anchor's content is user input like any
    // other.
    if (try ops_native.refuseOffGrid(&b, op)) return b.finish();

    var loc: locate.Map = try .init(gpa, tree);
    defer loc.deinit();

    var ctx: Ctx = .{
        .gpa = gpa,
        .arena = b.allocator(),
        .d = d,
        .tree = tree,
        .map = map,
        .loc = &loc,
        .b = &b,
    };
    try ctx.run(op);
    return b.finish();
}

/// The selection an operation carries, for the four this file plans over
/// bound content. Everything else answers null and is `ops_native`'s.
fn selectionOf(op: Op.Op) ?Select.Select {
    return switch (op) {
        .remove => |x| x.sel,
        .retime => |x| x.sel,
        .resize => |x| x.sel,
        .velocity => |x| x.sel,
        else => null,
    };
}

/// The positional step a pattern's first ROW sits at, and a row's first
/// CELL: step 0 is the form's own number — `(it/pattern 0 …)`,
/// `(row 2 …)` — which is a positional child like any other. Derived
/// once, because an off-by-one here addresses the wrong node rather than
/// failing.
const after_number: u32 = 1;

/// Whether the ask says it means EVERY occurrence of a shared Impulse
/// Tracker pattern's cell — plan 07's `:allow-shared`. An operation with
/// no such key never does; `resize` is the one that cannot carry it,
/// because it refuses whatever the pattern.
fn allowsShared(op: Op.Op) bool {
    return switch (op) {
        .remove => |x| x.allow_shared,
        .retime => |x| x.allow_shared,
        .velocity => |x| x.allow_shared,
        else => false,
    };
}

fn routesHere(d: *const doc.Doc, op: Op.Op) bool {
    if (op == .materialize) return true;
    const sel = selectionOf(op) orelse return false;
    const names = sel.lanes orelse return false;
    var bound: u32 = 0;
    for (d.lanes) |lane| {
        if (!named(names, lane.name)) continue;
        const binding = lane.binding orelse return false;
        if (!reachable(d, lane, binding)) return false;
        bound += 1;
    }
    return bound == 1;
}

/// Whether this file can reach `lane`'s content: the anchor's dump is in
/// this document, and the address is one of the shapes an operation here
/// knows how to move.
///
/// A 14-bit controller is two events per value and `:velocity` is not an
/// event stream at all (it is the notes' own velocities, plan 05), so
/// neither is a step this file can move; an IT `curve` lane's content is
/// a column of cells the notes also live in, which `retime` would have
/// to split. All three are left to `ops_native`'s refusal, which is the
/// honest answer: inline it first, or edit the file.
fn reachable(d: *const doc.Doc, lane: doc.Lane, binding: doc.Binding) bool {
    switch (binding.address) {
        .smf => |addr| {
            if (smfTier(d, binding.anchor) == null) return false;
            return switch (lane.kind) {
                .notes => true,
                .curve => if (addr.curve) |c| switch (c) {
                    .cc, .bend, .pressure => true,
                    .cc14, .velocity => false,
                } else false,
                .query, .formula => false,
            };
        },
        .it => {
            if (itTier(d, binding.anchor) == null) return false;
            return lane.kind == .notes;
        },
    }
}

// ---------------------------------------------------------------------------
// The context
// ---------------------------------------------------------------------------

/// What every bound operation plans against.
const Ctx = struct {
    gpa: std.mem.Allocator,
    /// The plan's arena (`b.allocator()`): what every action carries
    /// and every scratch table lives here until the plan's `deinit`,
    /// and nothing allocated from it is ever freed on its own.
    arena: std.mem.Allocator,
    d: *const doc.Doc,
    tree: *const Ast.Tree,
    map: *const TimeMap.TimeMap,
    loc: *const locate.Map,
    b: *Plan.Builder,

    fn run(self: *Ctx, op: Op.Op) Error!void {
        if (op == .materialize) return self.materialize(op.materialize);
        const sel = selectionOf(op).?;
        for (self.d.lanes, 0..) |lane, li| {
            if (!named(sel.lanes.?, lane.name)) continue;
            const binding = lane.binding orelse continue;
            switch (binding.address) {
                .smf => try self.smfLane(@intCast(li), op),
                .it => try self.itLane(@intCast(li), op),
            }
        }
    }

    // ---- the small writers ----

    fn intJson(self: *Ctx, v: i64) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{d}", .{v});
    }

    fn stringJson(self: *Ctx, text: []const u8) Error![]const u8 {
        var out: value.Buf = .empty;
        defer out.deinit(self.gpa);
        try value.string(self.gpa, &out, text);
        return self.arena.dupe(u8, out.items);
    }

    /// The address of positional child `slot` of root `root`.
    fn slotSite(self: *Ctx, root: u32, slot: u32) Error!Site {
        const site: Site = .{ .root = root, .path = &.{} };
        return site.child(self.arena, slot);
    }

    /// The root index of the form whose span is `span` — a lane's, which
    /// is the only `Doc` node this file addresses.
    fn rootOf(self: *Ctx, span: Diag.Span) Error!?u32 {
        const w = (try self.loc.at(self.arena, span)) orelse return null;
        if (w.site.path.len != 0) return null;
        return w.site.root;
    }

    // ---- where an anchor's dump sits in the root list ----

    /// The root index of the `track`-th `(midi/mtrk …)` of `anchor`'s
    /// inline dump, 1-based in file order the way `(lane :track …)`
    /// writes it.
    ///
    /// The partition is `doc/fromSjon.zig`'s, re-walked rather than
    /// carried: a dump belongs to the `(anchor …)` it FOLLOWS and a
    /// track to the `(midi/smf …)` before it, and the `Doc` keeps the
    /// sequence it read rather than the roots it read it from.
    fn mtrkRoot(self: *Ctx, anchor: doc.AnchorId, track: u16) ?u32 {
        if (track == 0) return null;
        var current: ?[]const u8 = null;
        var open = false;
        var seen: u16 = 0;
        for (self.tree.root, 0..) |node, i| {
            if (self.tree.tagOf(node) != .form) continue;
            const hdr = self.tree.formHeader(node);
            if (hdr.namespace == null and std.mem.eql(u8, hdr.head, "anchor")) {
                current = self.anchorId(node);
                open = false;
            } else if (nsIs(hdr.namespace, "midi") and std.mem.eql(u8, hdr.head, "smf")) {
                open = current != null and std.mem.eql(u8, current.?, anchor);
                seen = 0;
            } else if (nsIs(hdr.namespace, "midi") and std.mem.eql(u8, hdr.head, "mtrk")) {
                if (!open) continue;
                seen += 1;
                if (seen == track) return @intCast(i);
            } else if (nsIs(hdr.namespace, "it") and std.mem.eql(u8, hdr.head, "module")) {
                open = false;
            }
        }
        return null;
    }

    /// The root index of `anchor`'s inline `(it/module …)`.
    fn moduleRoot(self: *Ctx, anchor: doc.AnchorId) ?u32 {
        var current: ?[]const u8 = null;
        for (self.tree.root, 0..) |node, i| {
            if (self.tree.tagOf(node) != .form) continue;
            const hdr = self.tree.formHeader(node);
            if (hdr.namespace == null and std.mem.eql(u8, hdr.head, "anchor")) {
                current = self.anchorId(node);
            } else if (nsIs(hdr.namespace, "it") and std.mem.eql(u8, hdr.head, "module")) {
                if (current != null and std.mem.eql(u8, current.?, anchor)) return @intCast(i);
            }
        }
        return null;
    }

    fn anchorId(self: *Ctx, form: NodeIndex) ?[]const u8 {
        const node = kvNode(self.tree, form, "id") orelse return null;
        return if (self.tree.tagOf(node) == .symbol) self.tree.symbolText(node) else null;
    }

    // ---- SMF: the events, the pairs, the steps ----

    /// One `(midi/mtrk …)` event, as both readings see it: where its
    /// bytes are and which tick it carries.
    const Ev = struct {
        slot: u32,
        node: NodeIndex,
        head: []const u8,
        at: i64,
    };

    /// One sounding note, as the two events that spell it.
    const Pair = struct {
        on: u32,
        /// The `note-off` that closed it, or null when nothing did — a
        /// retrigger and an end-of-track end a note WITHOUT an event of
        /// their own (plan 05).
        off: ?u32,
        at: i64,
        end: i64,
        key: u7,
        vel: u7,
        off_vel: ?u7,
        /// The channel the pair sounded on, on the wire: an address may
        /// name several (`Doc.Channels`), and a materialised `(note …)`
        /// keeps each note's own.
        ch: u4,
    };

    /// One controller value, as the single event that carries it.
    const Step = struct {
        slot: u32,
        at: i64,
        /// Normalised 0..1 (a bend −1..1), the way a bound curve reads
        /// it: `:range` scales it at export and nothing here knows what
        /// it drives.
        v: f32,
    };

    /// Where an event goes, in the file's own ticks.
    const EvMove = struct { slot: u32, to: i64 };

    fn events(self: *Ctx, root: u32) Error![]const Ev {
        const arena = self.arena;
        const kids = try locate.positional(arena, self.tree, self.tree.root[root]);
        var out: std.ArrayList(Ev) = .empty;
        for (kids, 0..) |node, i| {
            if (self.tree.tagOf(node) != .form) continue;
            try out.append(arena, .{
                .slot = @intCast(i),
                .node = node,
                .head = self.tree.formHeader(node).head,
                .at = kvInt(self.tree, node, "at") orelse 0,
            });
        }
        return out.toOwnedSlice(arena);
    }

    /// `note-on` paired with `note-off` on one address, by plan 05's
    /// rules read off the TREE rather than off the `Sequence`: a plan
    /// needs the two events' addresses, and a `PairedNote` has values
    /// alone. `bridge_smf.pairNotes` is the same walk over the same
    /// events, and a test here holds the two to the same answer.
    fn pairs(self: *Ctx, evs: []const Ev, chs: doc.Channels, key: ?u7) Error![]const Pair {
        const arena = self.arena;
        var out: std.ArrayList(Pair) = .empty;
        // A key is held per (channel, key), as the bridge holds it: an
        // address may name several channels, and the same key on two of
        // them is two notes.
        const open = try arena.alloc(?usize, 16 * 128);
        @memset(open, null);
        var track_end: i64 = 0;

        for (evs) |e| {
            track_end = @max(track_end, e.at);
            const is_on = std.mem.eql(u8, e.head, "note-on");
            if (!is_on and !std.mem.eql(u8, e.head, "note-off")) continue;
            const on_ch = wireChannel(chs, kvInt(self.tree, e.node, "ch")) orelse continue;
            const on_key = kvInt(self.tree, e.node, "key") orelse continue;
            if (on_key < 0 or on_key > 127) continue;
            if (key) |want| {
                if (on_key != @as(i64, want)) continue;
            }
            const vel = kvInt(self.tree, e.node, "vel") orelse 0;
            const held = &open[@as(usize, on_ch) * 128 + @as(usize, @intCast(on_key))];

            // A `note-on` of velocity 0 is a note off on the wire (plan
            // 05, "Events"): the reader stored it as read, and the
            // pairing is what interprets it.
            if (is_on and vel > 0) {
                if (held.*) |i| out.items[i].end = e.at;
                held.* = out.items.len;
                try out.append(arena, .{
                    .on = e.slot,
                    .off = null,
                    .at = e.at,
                    .end = e.at,
                    .key = @intCast(on_key),
                    .vel = @intCast(std.math.clamp(vel, 0, 127)),
                    .off_vel = null,
                    .ch = on_ch,
                });
            } else if (held.*) |i| {
                out.items[i].end = e.at;
                out.items[i].off = e.slot;
                out.items[i].off_vel = @intCast(std.math.clamp(vel, 0, 127));
                held.* = null;
            }
        }
        for (open) |maybe| {
            if (maybe) |i| out.items[i].end = @max(out.items[i].at, track_end);
        }
        return out.toOwnedSlice(arena);
    }

    /// The single events a bound `curve` lane reads off one address.
    fn steps(
        self: *Ctx,
        evs: []const Ev,
        chs: doc.Channels,
        curve: doc.SmfCurve,
    ) Error![]const Step {
        const arena = self.arena;
        var out: std.ArrayList(Step) = .empty;
        for (evs) |e| {
            _ = wireChannel(chs, kvInt(self.tree, e.node, "ch")) orelse continue;
            const val = kvInt(self.tree, e.node, "val") orelse continue;
            var v: f32 = 0;
            switch (curve) {
                .cc => |num| {
                    if (!std.mem.eql(u8, e.head, "control-change")) continue;
                    if ((kvInt(self.tree, e.node, "num") orelse -1) != @as(i64, num)) continue;
                    v = norm7(val);
                },
                .pressure => {
                    if (!std.mem.eql(u8, e.head, "channel-pressure")) continue;
                    v = norm7(val);
                },
                .bend => {
                    if (!std.mem.eql(u8, e.head, "pitch-bend")) continue;
                    // Centre 8192 is zero; the two halves are 8192 and
                    // 8191 wide, so the top end reads exactly 1.
                    const centred: f32 = @floatFromInt(val - 8192);
                    const span: f32 = if (val >= 8192) 8191.0 else 8192.0;
                    v = centred / span;
                },
                // Neither is a single event: a 14-bit controller is
                // two per value and `:velocity` is the notes' own
                // velocities (plan 05, "Curve lanes"). `reachable` and
                // `materialize` both turn one away before it gets here;
                // answering nothing rather than trapping keeps this
                // total whichever caller arrives.
                .cc14, .velocity => continue,
            }
            try out.append(arena, .{ .slot = e.slot, .at = e.at, .v = v });
        }
        return out.toOwnedSlice(arena);
    }

    // ---- SMF: the operations ----

    /// What an SMF lane's selection comes to, before an action is
    /// written: the events that go, the events that move, the note-ons
    /// whose `:vel` is written, and the two counts. Every list lives in
    /// the plan's arena.
    const SmfEdits = struct {
        gone: std.ArrayList(u32) = .empty,
        moves: std.ArrayList(EvMove) = .empty,
        vel: std.ArrayList(u32) = .empty,
        targets: u32 = 0,
        inexact: u32 = 0,
    };

    fn smfLane(self: *Ctx, li: u32, op: Op.Op) Error!void {
        const lane = self.d.lanes[li];
        const binding = lane.binding.?;
        const addr = binding.address.smf;
        const tier = smfTier(self.d, binding.anchor).?;
        const ppq = tier.sequence.division.pulsesPerQuarter();
        const track = self.mtrkRoot(binding.anchor, addr.track) orelse {
            try self.b.refuse(
                .edit_range_empty,
                lane.span,
                "the inline dump of \"{s}\" has no track {d}",
                .{ binding.anchor, addr.track },
            );
            return;
        };
        const evs = try self.events(track);
        const sel = selectionOf(op).?;

        const edits: SmfEdits = if (lane.kind == .curve and sel.kinds.keyframe)
            try self.stepEdits(try self.steps(evs, addr.ch, addr.curve.?), ppq, sel, op)
        else if (lane.kind == .notes and sel.kinds.note)
            try self.pairEdits(try self.pairs(evs, addr.ch, addr.key), ppq, sel, op)
        else
            .{};

        if (edits.targets == 0) {
            try self.b.refuse(
                .edit_range_empty,
                lane.span,
                "the selection reached nothing in this lane's file",
                .{},
            );
            return;
        }
        self.b.summary.targets = edits.targets;

        if (op == .velocity) for (edits.vel.items) |on| {
            const site = try self.slotSite(track, on);
            try self.b.setKeyword(site, "vel", try self.intJson(op.velocity.vel));
        };
        std.sort.insertion(u32, edits.gone.items, {}, ascending);
        const track_site: Site = .{ .root = track, .path = &.{} };
        for (edits.gone.items) |slot| try self.b.removePositional(track_site, slot);
        try self.moveEvents(track, evs, edits.moves.items);

        if (edits.inexact > 0 and !self.b.summary.refused) {
            self.b.summary.inexact = edits.inexact;
            try self.b.note(
                .edit_inexact,
                .warning,
                lane.span,
                "{d} position(s) rounded onto the file's own {d}-PPQ grid",
                .{ edits.inexact, ppq },
            );
        }
    }

    /// A curve lane's edits: every step the selection covers. A
    /// controller value is a POINT — it has no end to resize and no
    /// velocity to write — so only `remove` and `retime` come to
    /// anything; the other two count their targets and write nothing.
    fn stepEdits(
        self: *Ctx,
        found: []const Step,
        ppq: u15,
        sel: Select.Select,
        op: Op.Op,
    ) Error!SmfEdits {
        var edits: SmfEdits = .{};
        for (found) |s| {
            const at = Grid.smfToTicks(s.at, ppq).tick;
            if (!sel.covers(at)) continue;
            edits.targets += 1;
            switch (op) {
                .remove => try edits.gone.append(self.arena, s.slot),
                .retime => |x| {
                    const to = smfTickOf(destination(x, at), ppq);
                    if (!to.exact) edits.inexact += 1;
                    try edits.moves.append(self.arena, .{ .slot = s.slot, .to = to.tick });
                },
                .resize, .velocity => {},
                else => unreachable,
            }
        }
        return edits;
    }

    /// A notes lane's edits: every pair the selection covers. `remove`
    /// takes both events, `velocity` names the note-on, `resize` moves
    /// the off alone (a note's onset is where it was; its end is what a
    /// resize asks about), and `retime` moves both by ONE delta so the
    /// file's own duration is kept exactly and neither event rounds
    /// twice.
    fn pairEdits(
        self: *Ctx,
        found: []const Pair,
        ppq: u15,
        sel: Select.Select,
        op: Op.Op,
    ) Error!SmfEdits {
        var edits: SmfEdits = .{};
        for (found) |pair| {
            const at = Grid.smfToTicks(pair.at, ppq).tick;
            if (!sel.covers(at)) continue;
            if (!Select.keyWanted(sel.keys, pair.key)) continue;
            edits.targets += 1;
            switch (op) {
                .remove => {
                    try edits.gone.append(self.arena, pair.on);
                    if (pair.off) |off| try edits.gone.append(self.arena, off);
                },
                .velocity => try edits.vel.append(self.arena, pair.on),
                .resize => |x| {
                    const dur = x.dur orelse continue;
                    const off = pair.off orelse continue;
                    const end = smfTickOf(at +| @max(0, dur), ppq);
                    if (!end.exact) edits.inexact += 1;
                    try edits.moves.append(self.arena, .{ .slot = off, .to = end.tick });
                },
                .retime => |x| {
                    const to = smfTickOf(destination(x, at), ppq);
                    if (!to.exact) edits.inexact += 1;
                    try edits.moves.append(self.arena, .{ .slot = pair.on, .to = to.tick });
                    if (pair.off) |off| try edits.moves.append(self.arena, .{
                        .slot = off,
                        .to = to.tick + (pair.end - pair.at),
                    });
                },
                else => unreachable,
            }
        }
        return edits;
    }

    /// Where every event of a track lands after a batch, and which of
    /// them the batch named. Arena-owned.
    const Landing = struct { at: []i64, moved: []bool };

    fn landingOf(self: *Ctx, evs: []const Ev, moves: []const EvMove) Error!Landing {
        const at = try self.arena.alloc(i64, evs.len);
        const moved = try self.arena.alloc(bool, evs.len);
        for (evs, at, moved) |e, *f, *m| {
            f.* = e.at;
            m.* = false;
        }
        for (moves) |m| {
            for (evs, 0..) |e, k| {
                if (e.slot != m.slot) continue;
                at[k] = m.to;
                moved[k] = true;
            }
        }
        return .{ .at = at, .moved = moved };
    }

    /// Move a batch of events, keeping the track non-decreasing in
    /// `:at`.
    ///
    /// The batch and not one event at a time, for `ops_native.moveAll`'s
    /// reason: `apply` runs EVERY removal before ANY insert, so an index
    /// computed against the untouched track names the wrong slot by the
    /// time the insert is reached. An event keeps its slot — and so its
    /// comments — whenever the order the document already has still
    /// holds (`ops_native.keptSlots`), and a move past a neighbour is a
    /// remove and an insert at the sorted index, ties AFTER what is
    /// already there.
    fn moveEvents(self: *Ctx, root: u32, evs: []const Ev, moves: []const EvMove) Error!void {
        if (moves.len == 0) return;
        const landed = try self.landingOf(evs, moves);
        const keep = try ops_native.keptSlots(self.arena, landed.at, landed.moved);

        for (0..evs.len) |k| {
            if (!landed.moved[k] or !keep[k] or landed.at[k] == evs[k].at) continue;
            const site = try self.slotSite(root, evs[k].slot);
            try self.b.setKeyword(site, "at", try self.intJson(landed.at[k]));
        }
        try self.relocateEvents(root, evs, landed, keep);
    }

    /// The events that change slot: every removal, then every insert
    /// against the list the removals leave behind, in ascending
    /// destination so every index is a slot in the list as it stands
    /// when that insert is reached.
    fn relocateEvents(
        self: *Ctx,
        root: u32,
        evs: []const Ev,
        landed: Landing,
        keep: []const bool,
    ) Error!void {
        const parent: Site = .{ .root = root, .path = &.{} };
        var rest: std.ArrayList(i64) = .empty;
        defer rest.deinit(self.gpa);
        var relocated: std.ArrayList(usize) = .empty;
        defer relocated.deinit(self.gpa);

        for (0..evs.len) |k| {
            if (!landed.moved[k] or keep[k]) {
                try rest.append(self.gpa, landed.at[k]);
                continue;
            }
            try self.b.removePositional(parent, evs[k].slot);
            try relocated.append(self.gpa, k);
        }
        if (relocated.items.len == 0) return;

        std.sort.insertion(usize, relocated.items, @as([]const i64, landed.at), byFinal);
        for (relocated.items) |k| {
            var out: value.Buf = .empty;
            defer out.deinit(self.gpa);
            try value.form(self.gpa, &out, self.tree, evs[k].node, &.{
                .{ .key = "at", .json = try self.intJson(landed.at[k]) },
            });
            const index = ops_native.slotAmong(rest.items, landed.at[k]);
            try rest.insert(self.gpa, index, landed.at[k]);
            try self.b.insertPositional(parent, index, out.items);
        }
    }

    // ---- IT: the cells ----

    /// One `(ev …)` cell, with the `(order, row)` the walk reached it
    /// through (plan 07, "Selection").
    const Cell = struct {
        site: Site,
        node: NodeIndex,
        order: u16,
        pattern: u16,
        row: u16,
        channel: u6,
        /// The three positional steps that reach the cell: the pattern
        /// under the module root, the row under the pattern, the cell
        /// under the row.
        pattern_slot: u32,
        row_slot: u32,
        ev_slot: u32,
        /// The row form the cell sits in, so a removal can ask how many
        /// other cells are on it.
        row_node: NodeIndex,
        at: i64,
        cell: model.Cell,
        span: Diag.Span,
    };

    /// A form found under another by its LEADING NUMBER — the pattern's
    /// index, the row's index, the cell's channel, each of which this
    /// vocabulary spells as a positional child rather than a keyword.
    const Numbered = struct { slot: u32, node: NodeIndex, number: i64 };

    fn numbered(self: *Ctx, parent: NodeIndex, head: []const u8, number: i64) Error!?Numbered {
        for (try self.children(parent)) |c| {
            const same_head = std.mem.eql(u8, self.tree.formHeader(c.node).head, head);
            if (c.number == number and same_head) return c;
        }
        return null;
    }

    /// Every positional child of `parent` that is a form, with its step
    /// and its leading number.
    fn children(self: *Ctx, parent: NodeIndex) Error![]const Numbered {
        const arena = self.arena;
        var out: std.ArrayList(Numbered) = .empty;
        for (try locate.positional(arena, self.tree, parent), 0..) |node, i| {
            if (self.tree.tagOf(node) != .form) continue;
            try out.append(arena, .{
                .slot = @intCast(i),
                .node = node,
                .number = (try self.leadingNumber(node)) orelse -1,
            });
        }
        return out.toOwnedSlice(arena);
    }

    fn leadingNumber(self: *Ctx, form: NodeIndex) Error!?i64 {
        for (try locate.positional(self.arena, self.tree, form)) |k| {
            if (intOf(self.tree, k)) |v| return v;
        }
        return null;
    }

    /// The cells the selection reaches, in walk order.
    fn cells(
        self: *Ctx,
        root: u32,
        rowmap: *const walk.RowMap,
        channel: u6,
        sel: Select.Select,
    ) Error![]const Cell {
        const arena = self.arena;
        const module = self.tree.root[root];
        var out: std.ArrayList(Cell) = .empty;

        for (rowmap.onsets) |onset| {
            if (onset.channel != @as(u8, channel)) continue;
            // A pitch starts a note; `off`, `cut` and `fade` end one and
            // are not notes to select (plan 06).
            if (onset.cell.note > model.note_max) continue;
            const played = rowmap.rows[onset.row_index];
            const at = itToTicks(onset.tick) orelse continue;
            if (!sel.covers(at)) continue;
            if (!Select.keyWanted(sel.keys, @intCast(onset.cell.note))) continue;

            const pat = (try self.numbered(module, "pattern", played.pattern)) orelse continue;
            const row = (try self.numbered(pat.node, "row", played.row)) orelse continue;
            const ev = (try self.numbered(row.node, "ev", @as(i64, channel) + 1)) orelse continue;

            // One address, one cell: a pattern two orders play reaches
            // the same `(ev …)` twice, and an edit of it is one edit.
            var seen = false;
            for (out.items) |c| {
                if (c.node == ev.node) seen = true;
            }
            if (seen) continue;

            const site = try (try (Site{ .root = root, .path = &.{} }).child(
                arena,
                pat.slot,
            )).child(arena, row.slot);
            try out.append(arena, .{
                .site = try site.child(arena, ev.slot),
                .node = ev.node,
                .order = played.order,
                .pattern = played.pattern,
                .row = played.row,
                .channel = channel,
                .pattern_slot = pat.slot,
                .row_slot = row.slot,
                .ev_slot = ev.slot,
                .row_node = row.node,
                .at = at,
                .cell = onset.cell,
                .span = spanOf(self.tree, ev.node),
            });
        }
        return out.toOwnedSlice(arena);
    }

    // ---- IT: the operations ----

    fn itLane(self: *Ctx, li: u32, op: Op.Op) Error!void {
        const lane = self.d.lanes[li];
        const binding = lane.binding.?;
        const addr = binding.address.it;
        const tier = itTier(self.d, binding.anchor).?;
        const root = self.moduleRoot(binding.anchor) orelse {
            try self.b.refuse(
                .edit_range_empty,
                lane.span,
                "the anchor \"{s}\" has no inline module",
                .{binding.anchor},
            );
            return;
        };

        // The walk's own report is not forwarded: the document already
        // read this module through the same walk and said whatever there
        // was to say about it (`doc/fromSjon.zig`), and a plan repeating
        // it would make one defect two complaints.
        var rowmap = try walk.derive(self.gpa, &tier.module, .{});
        defer rowmap.deinit();

        const sel = selectionOf(op).?;
        const found: []const Cell = if (sel.kinds.note) try self.cells(
            root,
            &rowmap,
            addr.channel,
            sel,
        ) else &.{};
        if (found.len == 0) {
            try self.b.refuse(
                .edit_range_empty,
                lane.span,
                "the selection reached no cell on this lane's channel",
                .{},
            );
            return;
        }
        self.b.summary.targets = @intCast(found.len);
        // `resize` refuses whatever the pattern — there is no `:dur` to
        // write — so the shared question never arises for it, and the
        // useful answer is the one about the missing length.
        if (op != .resize and try self.refuseShared(&rowmap, found, allowsShared(op))) return;

        switch (op) {
            // A cell's end is the next cell on the channel: there is no
            // length to write, and rounding one onto a row would move a
            // note the ask never named (plan 07's open question).
            .resize => try self.b.refuse(
                .edit_inexact,
                found[0].span,
                "an Impulse Tracker note ends where the next cell on its channel starts; there " ++
                    "is no :dur to write",
                .{},
            ),
            .velocity => |x| for (found) |c| try self.b.setKeyword(
                c.site,
                "vol",
                try self.intJson(volumeOf(x.vel)),
            ),
            .remove => try self.removeCells(root, found),
            .retime => |x| try self.moveCells(root, &rowmap, found, x),
            else => unreachable,
        }
    }

    /// Refuse an edit to a cell in a pattern more than one ORDER plays.
    ///
    /// Plan 07's diagnostics table governs, and it is about the CELL and
    /// not about which operation reached it: "an IT cell in a pattern
    /// played more than once, without `:allow-shared`". Every edit to
    /// such a cell — a retime inside the pattern, a volume, a removal —
    /// changes every occurrence, because a pattern is stored once and
    /// played many times. With `:allow-shared` that is what the ask
    /// means and the plan proceeds.
    ///
    /// Answers whether it refused.
    fn refuseShared(
        self: *Ctx,
        rowmap: *const walk.RowMap,
        cells_: []const Cell,
        allow: bool,
    ) Error!bool {
        if (allow) return false;
        for (cells_) |c| {
            const plays = playCount(rowmap, c.pattern);
            if (plays <= 1) continue;
            try self.b.refuse(
                .edit_pattern_shared,
                c.span,
                "this cell sits in a pattern {d} orders play; every occurrence would change, so " ++
                    "the ask wants :allow-shared",
                .{plays},
            );
            return true;
        }
        return false;
    }

    /// A cell's removal, and its row's when that was the last cell on it.
    fn removeCells(self: *Ctx, root: u32, cells_: []const Cell) Error!void {
        for (cells_, 0..) |c, i| {
            const site = try (Site{ .root = root, .path = &.{} }).child(self.arena, c.pattern_slot);
            if (try self.lastOnRow(c, cells_, i)) {
                try self.b.removePositional(site, c.row_slot);
            } else {
                try self.b.removePositional(try site.child(self.arena, c.row_slot), c.ev_slot);
            }
        }
    }

    /// Whether removing `c` empties its row — and, when several cells of
    /// one row go at once, whether `c` is the first of them, so the row
    /// is removed exactly once.
    fn lastOnRow(self: *Ctx, c: Cell, going: []const Cell, index: usize) Error!bool {
        var on_row: u32 = 0;
        for (try self.children(c.row_node)) |k| {
            if (std.mem.eql(u8, self.tree.formHeader(k.node).head, "ev")) on_row += 1;
        }
        var leaving: u32 = 0;
        var first = true;
        for (going, 0..) |o, i| {
            if (o.row_node != c.row_node) continue;
            leaving += 1;
            if (i < index) first = false;
        }
        return leaving >= on_row and first;
    }

    /// What one cell's retime comes to, once the refusals are past.
    const CellMove = struct {
        cell: Cell,
        pattern: u16,
        row: u16,
        pattern_slot: u32,
        pattern_node: NodeIndex,
        /// `:fx` as the move leaves it: JSON for a new value, or null to
        /// take the key off. `keep` means the cell's own effect stands.
        fx: ?[]const u8,
        keep: bool,
    };

    fn moveCells(
        self: *Ctx,
        root: u32,
        rowmap: *const walk.RowMap,
        cells_: []const Cell,
        x: Op.Retime,
    ) Error!void {
        const module = self.tree.root[root];
        var moves: std.ArrayList(CellMove) = .empty;
        for (cells_) |c| {
            const m = (try self.cellMove(module, rowmap, c, x)) orelse return;
            try moves.append(self.arena, m);
        }

        // The ones that stay on their row: only the effect column moves,
        // which keeps the cell's bytes and its comments where they are.
        for (moves.items) |m| {
            if (m.pattern != m.cell.pattern or m.row != m.cell.row) continue;
            if (m.keep) continue;
            if (m.fx) |json| {
                try self.b.setKeyword(m.cell.site, "fx", json);
            } else {
                try self.b.removeKeyword(m.cell.site, "fx");
            }
        }
        try self.relocateCells(root, moves.items);
    }

    /// What one cell's retime comes to — the row it lands on, the
    /// pattern that row is in, and the effect column as the move leaves
    /// it — or null after a refusal: a position between two of the
    /// module's ticks, past its last row, more than SDF away from a row
    /// start, or into a shared pattern the ask did not allow.
    fn cellMove(
        self: *Ctx,
        module: NodeIndex,
        rowmap: *const walk.RowMap,
        c: Cell,
        x: Op.Retime,
    ) Error!?CellMove {
        const to = destination(x, c.at);
        if (@rem(to, Grid.IT_TICK) != 0) {
            try self.b.refuse(
                .edit_inexact,
                c.span,
                "an Impulse Tracker cell sounds on a tick of the module's own clock, " ++
                    "and this position is between two",
                .{},
            );
            return null;
        }
        const ri = rowIndexAt(rowmap, @divExact(to, Grid.IT_TICK)) orelse {
            try self.b.refuse(
                .edit_range_empty,
                c.span,
                "that position is past the module's last row",
                .{},
            );
            return null;
        };
        const played = rowmap.rows[ri];
        const delay = @divExact(to, Grid.IT_TICK) - played.start_tick;
        if (delay > 15) {
            try self.b.refuse(
                .edit_inexact,
                c.span,
                "a cell can be held back by at most fifteen ticks (SDF), " ++
                    "and this one would need {d}",
                .{delay},
            );
            return null;
        }
        const fx = (try self.delayColumn(c, delay)) orelse return null;
        if (try self.refuseSharedLanding(rowmap, c, played.pattern, x.allow_shared)) return null;
        const dst = (try self.numbered(module, "pattern", played.pattern)) orelse {
            try self.b.refuse(
                .edit_range_empty,
                c.span,
                "the module has no (it/pattern {d} …) to move into",
                .{played.pattern},
            );
            return null;
        };
        return .{
            .cell = c,
            .pattern = played.pattern,
            .row = played.row,
            .pattern_slot = dst.slot,
            .pattern_node = dst.node,
            .fx = fx.json,
            .keep = fx.keep,
        };
    }

    /// Refuse a move INTO a pattern more than one order plays. The
    /// SOURCE pattern was asked about before any move was planned
    /// (`refuseShared`); what is left is the pattern the cell lands in,
    /// which the ask has not been shown yet. Answers whether it refused.
    fn refuseSharedLanding(
        self: *Ctx,
        rowmap: *const walk.RowMap,
        c: Cell,
        landing: u16,
        allow: bool,
    ) Error!bool {
        if (landing == c.pattern or allow) return false;
        const plays = playCount(rowmap, landing);
        if (plays <= 1) return false;
        try self.b.refuse(
            .edit_pattern_shared,
            c.span,
            "this move crosses into a pattern {d} orders play; every occurrence would " ++
                "change, so it wants :allow-shared",
            .{plays},
        );
        return true;
    }

    /// The effect column as a sub-row move leaves it: JSON for a new
    /// `:fx`, null to take the key off, and `keep` when the cell's own
    /// effect stands.
    const FxColumn = struct { json: ?[]const u8, keep: bool };

    /// `SDx` is the only way a cell sounds off a row start, and the plan
    /// refuses (null) rather than drop an effect that is already there
    /// (plan 07's open question). Back onto the row start, the delay the
    /// cell carried goes.
    fn delayColumn(self: *Ctx, c: Cell, delay: i64) Error!?FxColumn {
        const delayed = isDelay(c.cell);
        if (delay > 0) {
            if (c.cell.fx != 0 and !delayed) {
                try self.b.refuse(
                    .edit_inexact,
                    c.span,
                    "this cell's effect column already carries {c}{X:0>2}; " ++
                        "a sub-row move needs it for SDx",
                    .{ '@' + c.cell.fx, c.cell.param },
                );
                return null;
            }
            const spelled = try std.fmt.allocPrint(self.arena, "SD{X}", .{delay});
            return .{ .json = try self.stringJson(spelled), .keep = false };
        }
        if (delayed) return .{ .json = null, .keep = false };
        return .{ .json = null, .keep = true };
    }

    /// The cells that change row: every removal, then every insert
    /// against the rows the removals leave behind.
    fn relocateCells(self: *Ctx, root: u32, moves: []const CellMove) Error!void {
        const arena = self.arena;
        var going: std.ArrayList(Cell) = .empty;
        var which: std.ArrayList(usize) = .empty;
        for (moves, 0..) |m, i| {
            if (m.pattern == m.cell.pattern and m.row == m.cell.row) continue;
            try going.append(arena, m.cell);
            try which.append(arena, i);
        }
        if (going.items.len == 0) return;
        try self.removeCells(root, going.items);

        // Destination first, so the indices this computes are the slots
        // the inserts land on — `apply` runs them low index first.
        const order = try arena.dupe(usize, which.items);
        std.sort.insertion(usize, order, moves, byDestination);

        var patterns: std.ArrayList(PatternRows) = .empty;
        for (order) |i| {
            const m = moves[i];
            const rows = try self.rowsOf(&patterns, m.pattern_slot, m.pattern_node, going.items);
            const json = try self.cellJson(m);
            const pattern_site = try (Site{ .root = root, .path = &.{} }).child(
                arena,
                m.pattern_slot,
            );
            if (rows.find(m.row)) |at| {
                // The row is there and stays. Its slot is NOT the one the
                // document gave it: every `remove_positional` of this plan
                // runs before any insert, so a row this plan emptied lower
                // down the pattern has already taken its place with it —
                // the slot is the row's place among the rows that SURVIVE,
                // which `slotOf` counts.
                const index = try rows.placeOn(arena, at, m.cell.channel);
                const row_site = try pattern_site.child(arena, rows.slotOf(at));
                try self.b.insertPositional(row_site, after_number + index, json);
            } else {
                // No row: one is created, holding this cell.
                const index = try rows.placeNew(arena, m.row, m.cell.channel);
                const row_json = try self.rowJson(m.row, json);
                try self.b.insertPositional(pattern_site, after_number + index, row_json);
            }
        }
    }

    /// The cell as JSON, its `:fx` as the move leaves it. Arena-owned.
    fn cellJson(self: *Ctx, m: CellMove) Error![]const u8 {
        const overrides: [1]value.Override = .{.{ .key = "fx", .json = m.fx }};
        const applied: []const value.Override = if (m.keep) overrides[0..0] else overrides[0..1];
        var json: value.Buf = .empty;
        defer json.deinit(self.gpa);
        try value.form(self.gpa, &json, self.tree, m.cell.node, applied);
        return self.arena.dupe(u8, json.items);
    }

    /// `(row N …)` holding one relocated cell: the row a move creates
    /// where the pattern had none. Arena-owned.
    fn rowJson(self: *Ctx, number: u16, cell_json: []const u8) Error![]const u8 {
        var form = try value.Form.init(self.gpa, "row");
        defer form.deinit();
        var text: value.Buf = .empty;
        defer text.deinit(self.gpa);
        try value.integer(self.gpa, &text, number);
        try form.children(&.{ text.items, cell_json });
        return self.arena.dupe(u8, try form.done());
    }

    /// One pattern's rows as the plan leaves them: every row form the
    /// document holds that no removal takes, in positional order, with
    /// the channels each one carries.
    const PatternRows = struct {
        slot: u32,
        items: std.ArrayList(Row),

        const Row = struct {
            number: u16,
            /// The positional step the row form has in the document, or
            /// null for a row this plan creates.
            slot: ?u32,
            channels: std.ArrayList(u32),
        };

        /// Where in `items` the row form numbered `number` sits — one
        /// the DOCUMENT holds, never one this plan created.
        ///
        /// A cell cannot be inserted into a row the same plan inserts:
        /// `apply` runs the inner container's inserts before the outer
        /// one's, so the row would not be there yet. Two cells landing
        /// on one new row therefore come back as two `(row N …)` forms,
        /// which reads the same — `bridge_it`'s reader writes each one's
        /// cells into the pattern by channel — and which the canonical
        /// printer folds back into one on the next full print.
        fn find(self: *PatternRows, number: u16) ?usize {
            for (self.items.items, 0..) |r, i| {
                if (r.number == number and r.slot != null) return i;
            }
            return null;
        }

        /// The positional step entry `at` occupies when a cell insert
        /// reaches it: past the pattern's own number, counting only the
        /// rows the DOCUMENT holds that survive this plan.
        ///
        /// A row this plan creates is not counted, and it does not have
        /// to be: `apply` runs a row's own inserts before the pattern's,
        /// so no created row is in place yet when this slot is used.
        fn slotOf(self: *const PatternRows, at: usize) u32 {
            var slot: u32 = after_number;
            for (self.items.items[0..at]) |r| {
                if (r.slot != null) slot += 1;
            }
            return slot;
        }

        /// A cell landing on entry `at` — a row the document holds and
        /// this plan keeps: it goes in beside the ones already there, in
        /// channel order. Records the channel and answers the index
        /// among the row's cells, counted against the cells that SURVIVE
        /// this plan and not the document's: every `remove_positional`
        /// runs before any insert, so a cell this plan took off the row
        /// is not there when the insert is reached.
        fn placeOn(
            self: *PatternRows,
            arena: std.mem.Allocator,
            at: usize,
            channel: u32,
        ) Error!u32 {
            const r = &self.items.items[at];
            var index: u32 = @intCast(r.channels.items.len);
            for (r.channels.items, 0..) |c, n| {
                if (c > channel) {
                    index = @intCast(n);
                    break;
                }
            }
            try r.channels.insert(arena, index, channel);
            return index;
        }

        /// A cell landing on a row the pattern does not hold: one is
        /// created for it, at its number's place among the rows. Records
        /// the row and answers its index among them.
        fn placeNew(
            self: *PatternRows,
            arena: std.mem.Allocator,
            number: u16,
            channel: u32,
        ) Error!u32 {
            var index: u32 = @intCast(self.items.items.len);
            for (self.items.items, 0..) |r, n| {
                if (r.number > number) {
                    index = @intCast(n);
                    break;
                }
            }
            var channels: std.ArrayList(u32) = .empty;
            try channels.append(arena, channel);
            try self.items.insert(arena, index, .{
                .number = number,
                .slot = null,
                .channels = channels,
            });
            return index;
        }
    };

    fn rowsOf(
        self: *Ctx,
        patterns: *std.ArrayList(PatternRows),
        slot: u32,
        node: NodeIndex,
        going: []const Cell,
    ) Error!*PatternRows {
        for (patterns.items) |*p| {
            if (p.slot == slot) return p;
        }
        const arena = self.arena;
        var rows: std.ArrayList(PatternRows.Row) = .empty;
        for (try self.children(node)) |r| {
            if (!std.mem.eql(u8, self.tree.formHeader(r.node).head, "row")) continue;
            var channels: std.ArrayList(u32) = .empty;
            for (try self.children(r.node)) |ev| {
                if (!std.mem.eql(u8, self.tree.formHeader(ev.node).head, "ev")) continue;
                var leaving = false;
                for (going) |c| {
                    if (c.node == ev.node) leaving = true;
                }
                if (!leaving) try channels.append(arena, narrowed(u32, ev.number -| 1));
            }
            // A row every cell left is removed, so it is not a row an
            // insert may land in.
            if (channels.items.len == 0) continue;
            try rows.append(arena, .{
                .number = narrowed(u16, r.number),
                .slot = r.slot,
                .channels = channels,
            });
        }
        try patterns.append(arena, .{ .slot = slot, .items = rows });
        return &patterns.items[patterns.items.len - 1];
    }

    // ---- materialize ----

    /// What `materialize` reads from and writes to, once every refusal
    /// is past: the lane, its SMF address, the file's division, and the
    /// two roots — the lane's own and its track's.
    const Source = struct {
        li: u32,
        addr: @FieldType(doc.Address, "smf"),
        ppq: u15,
        lane_root: u32,
        track: u32,
    };

    /// Copy a bound lane's content into the document and take it out of
    /// the file: plan 07's `materialize`, and plan 04's "one home".
    fn materialize(self: *Ctx, x: Op.Materialize) Error!void {
        const src = (try self.materializeSource(x)) orelse return;
        const lane = self.d.lanes[src.li];
        const evs = try self.events(src.track);
        const lane_site: Site = .{ .root = src.lane_root, .path = &.{} };

        var gone: std.ArrayList(u32) = .empty;
        defer gone.deinit(self.gpa);
        var index: u32 = 0;
        var inexact: u32 = 0;

        if (lane.kind == .curve) {
            for (try self.steps(evs, src.addr.ch, src.addr.curve.?)) |s| {
                const at = Grid.smfToTicks(s.at, src.ppq);
                if (!at.exact) inexact += 1;
                try self.b.insertPositional(lane_site, index, try self.keyframeJson(at.tick, s.v));
                try gone.append(self.gpa, s.slot);
                index += 1;
            }
        } else {
            for (try self.pairs(evs, src.addr.ch, src.addr.key)) |pair| {
                const at = Grid.smfToTicks(pair.at, src.ppq);
                const end = Grid.smfToTicks(pair.end, src.ppq);
                if (!at.exact or !end.exact) inexact += 1;
                const json = try self.noteJson(pair, at.tick, end.tick);
                try self.b.insertPositional(lane_site, index, json);
                try gone.append(self.gpa, pair.on);
                if (pair.off) |off| try gone.append(self.gpa, off);
                index += 1;
            }
        }

        if (index == 0) {
            try self.b.refuse(
                .edit_range_empty,
                lane.span,
                "this lane's address carries nothing in the file",
                .{},
            );
            return;
        }
        self.b.summary.targets = index;

        std.sort.insertion(u32, gone.items, {}, ascending);
        const track_site: Site = .{ .root = src.track, .path = &.{} };
        for (gone.items) |slot| try self.b.removePositional(track_site, slot);
        try self.detachLane(lane_site, src.lane_root);

        if (inexact > 0) {
            self.b.summary.inexact = inexact;
            try self.b.note(
                .edit_inexact,
                .warning,
                lane.span,
                "{d} position(s) rounded off the file's own {d}-PPQ grid",
                .{ inexact, src.ppq },
            );
        }
    }

    /// The lane `materialize` was asked about and where its content is,
    /// with every refusal on the way: no such lane, the lane's own and
    /// its surface's (`materializable`, `smfSurface`), a lane the tree
    /// cannot address, a track the dump does not have. Null after one.
    fn materializeSource(self: *Ctx, x: Op.Materialize) Error!?Source {
        const li = laneByName(self.d, x.lane) orelse {
            try self.b.refuse(
                .edit_range_empty,
                .{ .start = 0, .end = 0 },
                "no lane is named {s}",
                .{x.lane},
            );
            return null;
        };
        const lane = self.d.lanes[li];
        const binding = (try self.materializable(lane)) orelse return null;
        const surface = (try self.smfSurface(lane, binding)) orelse return null;
        const lane_root = (try self.rootOf(lane.span)) orelse {
            try self.b.refuse(
                .sjon_diagnostic,
                lane.span,
                "the document and its source tree disagree about this lane",
                .{},
            );
            return null;
        };
        const track = self.mtrkRoot(binding.anchor, surface.addr.track) orelse {
            try self.b.refuse(
                .edit_range_empty,
                lane.span,
                "the inline dump of \"{s}\" has no track {d}",
                .{ binding.anchor, surface.addr.track },
            );
            return null;
        };
        return .{
            .li = li,
            .addr = surface.addr,
            .ppq = surface.ppq,
            .lane_root = lane_root,
            .track = track,
        };
    }

    /// The binding of a lane that may be materialized: one that carries
    /// no content of its own (one content, one home — plan 04) and
    /// reads an anchor. Null after a refusal.
    fn materializable(self: *Ctx, lane: doc.Lane) Error!?doc.Binding {
        if (lane.notes.len + lane.keyframes.len + lane.clips.len > 0) {
            try self.b.refuse(
                .edit_would_duplicate,
                lane.span,
                "this lane already carries content; materializing its anchor's would give " ++
                    "one content two homes",
                .{},
            );
            return null;
        }
        return lane.binding orelse {
            try self.b.refuse(
                .edit_range_empty,
                lane.span,
                "this lane is not bound; there is nothing to materialize",
                .{},
            );
            return null;
        };
    }

    /// An SMF address and the division of the file it reads — a surface
    /// this operation can take out of its file one event per value.
    const Surface = struct { addr: @FieldType(doc.Address, "smf"), ppq: u15 };

    /// `binding`'s surface, or null after a refusal. An Impulse Tracker
    /// binding is parked: a channel's cells serve every ORDER that plays
    /// the pattern, so there is no removal that leaves one home. An
    /// anchor whose dump is not inline has nothing here to move. And a
    /// 14-bit controller or `:velocity` is not one event per value
    /// (plan 05, "Curve lanes") — the velocities belong to the notes
    /// that carry them — so the operation says so rather than writing
    /// half of one.
    fn smfSurface(self: *Ctx, lane: doc.Lane, binding: doc.Binding) Error!?Surface {
        const addr = switch (binding.address) {
            .smf => |smf| smf,
            .it => {
                try self.b.refuse(
                    .edit_would_duplicate,
                    lane.span,
                    "an Impulse Tracker channel's cells serve every order that plays their " ++
                        "pattern; removing them would change more than this lane",
                    .{},
                );
                return null;
            },
        };
        const tier = smfTier(self.d, binding.anchor) orelse {
            try self.b.refuse(
                .edit_target_bound,
                lane.span,
                "this lane's content lives in its anchor's file; inline it first",
                .{},
            );
            return null;
        };
        if (lane.kind == .curve) switch (addr.curve orelse .bend) {
            .cc, .bend, .pressure => {},
            .cc14, .velocity => {
                try self.b.refuse(
                    .edit_target_bound,
                    lane.span,
                    "this lane reads a surface that is not one event per value; " ++
                        "its content stays in the file",
                    .{},
                );
                return null;
            },
        };
        return .{ .addr = addr, .ppq = tier.sequence.division.pulsesPerQuarter() };
    }

    /// A `(keyframe …)` for one controller step, at the document's own
    /// spelling of `at`. Arena-owned.
    fn keyframeJson(self: *Ctx, at: i64, v: f32) Error![]const u8 {
        var form = try value.Form.init(self.gpa, "keyframe");
        defer form.deinit();
        try form.position("at", self.map, at);
        try form.components("value", .{ v, 0, 0, 0 }, 1);
        return self.arena.dupe(u8, try form.done());
    }

    /// A `(note …)` for one paired note sounding from `at` to `end`.
    /// The lane's `:ch` goes with its binding and a note's own `:ch`
    /// defaults to channel 1, so the key is written only when the file
    /// says something else — and it is the NOTE's channel that is
    /// written, because an address may name several and each note
    /// keeps its own. Arena-owned.
    fn noteJson(self: *Ctx, pair: Pair, at: i64, end: i64) Error![]const u8 {
        var form = try value.Form.init(self.gpa, "note");
        defer form.deinit();
        try form.position("at", self.map, at);
        try form.duration("dur", self.map, @max(0, end - at), at);
        try form.integer("key", pair.key);
        try form.integer("vel", pair.vel);
        if (pair.ch != 0) try form.integer("ch", @as(i64, pair.ch) + 1);
        if (pair.off_vel) |v| try form.integer("off-vel", v);
        return self.arena.dupe(u8, try form.done());
    }

    /// One home: the lane stops reading the file the moment it holds
    /// the content itself — `:from` goes, and every address key with
    /// it. `:cc` stays: on a native curve lane it is the controller a
    /// build renders onto (plan 08), so the lane keeps the number its
    /// values came from; the other keys read an anchor and mean nothing
    /// without `:from`.
    fn detachLane(self: *Ctx, lane_site: Site, lane_root: u32) Error!void {
        try self.b.removeKeyword(lane_site, "from");
        for (ops_native.address_keys) |key| {
            if (std.mem.eql(u8, key, "cc")) continue;
            if (kvNode(self.tree, self.tree.root[lane_root], key) == null) continue;
            try self.b.removeKeyword(lane_site, key);
        }
    }
};

// ---------------------------------------------------------------------------
// The free functions
// ---------------------------------------------------------------------------

fn laneByName(d: *const doc.Doc, name: []const u8) ?u32 {
    for (d.lanes, 0..) |lane, i| {
        if (std.mem.eql(u8, lane.name, name)) return @intCast(i);
    }
    return null;
}

fn named(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn smfTier(d: *const doc.Doc, id: doc.AnchorId) ?*const doc.SmfTier {
    for (d.midi) |*t| {
        if (std.mem.eql(u8, t.anchor, id)) return t;
    }
    return null;
}

fn itTier(d: *const doc.Doc, id: doc.AnchorId) ?*const doc.ItTier {
    for (d.it) |*t| {
        if (std.mem.eql(u8, t.anchor, id)) return t;
    }
    return null;
}

/// Where a retime sends a target: by `delta`, or onto `to`. Never before
/// zero — a file's clock has no negative ticks.
fn destination(x: Op.Retime, at: i64) i64 {
    const to = if (x.delta) |delta| at +| delta else (x.to orelse at);
    return @max(0, to);
}

/// One tempura tick as an SMF tick of division `ppq`: `tick · ppq / TPQ`,
/// nearest with ties to even — `Grid.smfToTicks` read backwards, and the
/// same rounding, so a position that came off the file's grid goes back
/// onto the same line.
fn smfTickOf(tick: i64, ppq: u15) struct { tick: i64, exact: bool } {
    if (ppq == 0) return .{ .tick = 0, .exact = false };
    const num = @as(i128, tick) * @as(i128, ppq);
    const den: i128 = Grid.TPQ;
    const quo = @divFloor(num, den);
    const rem = num - quo * den;
    if (rem == 0) return .{ .tick = @intCast(quo), .exact = true };
    const twice = 2 * rem;
    const up = if (twice > den) true else if (twice < den) false else @rem(quo, 2) != 0;
    return .{ .tick = @intCast(if (up) quo + 1 else quo), .exact = false };
}

/// IT ticks to tempura ticks, or null past the grid ceiling. The product
/// is formed in `i128`, so the ceiling is a CHECK and never a wrap.
fn itToTicks(it_ticks: i64) ?i64 {
    const t = @as(i128, it_ticks) * Grid.IT_TICK;
    if (t < 0 or t > Grid.MAX_TICK) return null;
    return @intCast(t);
}

/// Which played row holds `it_tick` — `walk.orderRowAt`'s search,
/// answering the row's INDEX, because the pattern a move lands in is on
/// the `PlayedRow` and not on the `Position`.
fn rowIndexAt(rowmap: *const walk.RowMap, it_tick: i64) ?u32 {
    if (rowmap.rows.len == 0 or it_tick < 0 or it_tick >= rowmap.total_ticks) return null;
    var lo: usize = 0;
    var hi: usize = rowmap.rows.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (rowmap.rows[mid].start_tick <= it_tick) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

/// How many ORDERS play `pattern` — the question `edit_pattern_shared`
/// asks. Counted off the WALK and not off the order list, so a pattern
/// an order names but the walk never reaches is not counted as played.
fn playCount(rowmap: *const walk.RowMap, pattern: u16) u32 {
    var n: u32 = 0;
    var last: ?u16 = null;
    for (rowmap.rows) |r| {
        if (r.pattern != pattern) continue;
        if (last) |o| {
            if (o == r.order) continue;
        }
        last = r.order;
        n += 1;
    }
    return n;
}

/// `Sxy` with `y = D`: the note-delay command, and the only effect a
/// sub-row move may overwrite, because it is the one it wrote itself.
fn isDelay(cell: model.Cell) bool {
    return cell.fx == 'S' - '@' and (cell.param >> 4) == 0xD;
}

/// `round(vel · 64 / 127)` — plan 07's formula for the volume column,
/// and the inverse of `bridge_it`'s `velocityOf`. Half goes up, as it
/// does there.
fn volumeOf(vel: u7) i64 {
    return @divTrunc(2 * @as(i64, vel) * 64 + 127, 254);
}

fn norm7(v: i64) f32 {
    return @as(f32, @floatFromInt(std.math.clamp(v, 0, 127))) / 127.0;
}

/// An event's `:ch` as the tier spells it (1-based) to the wire channel
/// it names, when that channel is one of the address's; null for an
/// event on another channel, or with no channel, or with one no MIDI
/// file can carry.
fn wireChannel(chs: doc.Channels, ch_1: ?i64) ?u4 {
    const spelled = ch_1 orelse return null;
    if (spelled < 1 or spelled > 16) return null;
    const c: u4 = @intCast(spelled - 1);
    return if (chs.has(c)) c else null;
}

fn ascending(_: void, x: u32, y: u32) bool {
    return x < y;
}

/// Two events of one track by where they are GOING — the order a batch
/// of inserts has to land in.
fn byFinal(finals: []const i64, x: usize, y: usize) bool {
    return finals[x] < finals[y];
}

/// Two cell moves by the row they land on, so the inserts into one
/// pattern go in low index first.
fn byDestination(moves: []const Ctx.CellMove, x: usize, y: usize) bool {
    if (moves[x].pattern_slot != moves[y].pattern_slot) {
        return moves[x].pattern_slot < moves[y].pattern_slot;
    }
    return moves[x].row < moves[y].row;
}

fn nsIs(ns: ?[]const u8, want: []const u8) bool {
    return ns == null or std.mem.eql(u8, ns.?, want);
}

/// A form's keyword value by key, or null.
fn kvNode(tree: *const Ast.Tree, form: NodeIndex, key: []const u8) ?NodeIndex {
    if (tree.tagOf(form) != .form) return null;
    for (tree.formHeader(form).children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

/// A leading number off the DOCUMENT's own text, narrowed to the domain
/// the module keeps it in — a `(row N …)`'s `u16`, an `(ev N …)`'s
/// channel `u32` — by clamping to that domain's ends.
///
/// An `@intCast` here was a panic waiting for `(row 70000 …)` in an
/// inline IT tier: the schema's bounds are a diagnostic on the SOURCE
/// and this walk runs over a document that already collected it, so the
/// cast has to survive what the walk was handed. Clamping is right
/// rather than merely safe: the numbers name cells in a module whose
/// rows stop at 1023 and whose channels stop at 64, so a clamped one
/// matches nothing and the edit finds no target — which is the answer a
/// row that does not exist deserves.
fn narrowed(comptime T: type, n: i64) T {
    return @intCast(std.math.clamp(n, std.math.minInt(T), std.math.maxInt(T)));
}

fn kvInt(tree: *const Ast.Tree, form: NodeIndex, key: []const u8) ?i64 {
    return intOf(tree, kvNode(tree, form, key) orelse return null);
}

/// A number node as an integer, whichever of SJON's three numeric tags
/// it came back as.
fn intOf(tree: *const Ast.Tree, idx: NodeIndex) ?i64 {
    return switch (tree.tagOf(idx)) {
        .number => blk: {
            const v = tree.numberOf(idx);
            if (!std.math.isFinite(v) or v < -9.0e15 or v > 9.0e15) break :blk null;
            break :blk @as(i64, @intFromFloat(@round(v)));
        },
        .number_i64 => tree.numberI64Of(idx),
        .number_u64 => std.math.cast(i64, tree.numberU64Of(idx)),
        else => null,
    };
}

fn spanOf(tree: *const Ast.Tree, idx: NodeIndex) Diag.Span {
    const s = tree.spanOf(idx);
    return .{ .start = s.start, .end = s.end };
}

// ---------------------------------------------------------------------------

const test_support = @import("test_support.zig");
const apply = @import("apply.zig");

const TPQ = Grid.TPQ;

/// One region of a fixture, and what the edit makes of it.
const Region = struct { from: []const u8, to: []const u8 };

/// `source` with `regions` replaced — the expected document, spelled as
/// the edit rather than as a whole second copy. Each `from` must occur
/// exactly once, so a test cannot quietly pin the wrong one.
fn edited(gpa: std.mem.Allocator, source: []const u8, regions: []const Region) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, source);
    for (regions) |r| {
        const at = std.mem.indexOf(u8, out.items, r.from) orelse return error.NoSuchRegion;
        const rest = out.items[at + r.from.len ..];
        if (std.mem.indexOf(u8, rest, r.from) != null) return error.AmbiguousRegion;
        try out.replaceRange(gpa, at, r.from.len, r.to);
    }
    return out.toOwnedSlice(gpa);
}

/// Plan `op` over `source`, pin the actions as text, and pin the
/// document the plan produces, byte for byte.
fn expectPlan(
    source: [:0]const u8,
    op: Op.Op,
    want_actions: []const u8,
    want_text: []const u8,
) !void {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, source);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, op);
    defer p.deinit();

    const actions = try p.text(gpa);
    defer gpa.free(actions);
    try testing.expectEqualStrings(want_actions, actions);

    var applied = try apply.apply(gpa, fx.source, &p);
    defer applied.deinit();
    try testing.expect(!applied.diags.hasErrors());
    try testing.expectEqualStrings(want_text, applied.text);
}

/// `expectEdit`, plus the diagnostic the plan carries BESIDE its actions
/// and the count on its summary — a note is not a refusal, and a test
/// that only read the actions would not see it.
fn expectEditNoting(
    source: [:0]const u8,
    op: Op.Op,
    want_actions: []const u8,
    regions: []const Region,
    code: Diag.Code,
    inexact: u32,
) !void {
    const gpa = testing.allocator;
    const want = try edited(gpa, source, regions);
    defer gpa.free(want);

    var fx = try test_support.Fixture.init(gpa, source);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, op);
    defer p.deinit();

    const actions = try p.text(gpa);
    defer gpa.free(actions);
    try testing.expectEqualStrings(want_actions, actions);

    try testing.expect(!p.summary.refused);
    try testing.expectEqual(inexact, p.summary.inexact);
    try testing.expectEqual(Diag.Severity.warning, p.findDiag(code).?.severity);

    var applied = try apply.apply(gpa, fx.source, &p);
    defer applied.deinit();
    try testing.expect(!applied.diags.hasErrors());
    try testing.expectEqualStrings(want, applied.text);
}

fn expectEdit(
    source: [:0]const u8,
    op: Op.Op,
    want_actions: []const u8,
    regions: []const Region,
) !void {
    const gpa = testing.allocator;
    const want = try edited(gpa, source, regions);
    defer gpa.free(want);
    try expectPlan(source, op, want_actions, want);
}

/// Plan `op` and expect a refusal carrying `code`: no actions, and a
/// diagnostic that says why.
fn expectRefusal(source: [:0]const u8, op: Op.Op, code: Diag.Code) !void {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, source);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, op);
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    try testing.expect(p.summary.refused);
    try testing.expect(p.findDiag(code) != null);
}

// ---- SMF ----

test "bound SMF: a retime that keeps the track's order writes :at on both events" {
    try expectEdit(
        test_support.bound_smf,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"kick"}, .kinds = .notes, .range = .{ TPQ, TPQ + 1 } },
            .delta = @divExact(TPQ, 4),
        } },
        \\[
        \\{"op":"set_keyword","root":3,"path":[4],"key":"at","value":600},
        \\{"op":"set_keyword","root":3,"path":[5],"key":"at","value":840}
        \\]
        \\
    ,
        &.{
            .{
                .from = "(note-on        :at 480  :ch 1 :key 38 :vel 90)",
                .to = "(note-on        :at 600  :ch 1 :key 38 :vel 90)",
            },
            .{
                .from = "(note-off       :at 720  :ch 1 :key 38 :vel 64)",
                .to = "(note-off       :at 840  :ch 1 :key 38 :vel 64)",
            },
        },
    );
}

test "bound SMF: a retime past a neighbour is a remove and an insert at the sorted index" {
    // Two quarter notes on: the pair crosses the controller and the
    // third note, and both of its events land on a tick another event
    // already holds — where plan 07 puts the moved one AFTER what is
    // there.
    try expectEdit(
        test_support.bound_smf,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"kick"}, .kinds = .notes, .range = .{ 0, 1 } },
            .delta = 2 * TPQ,
        } },
        \\[
        \\{"op":"remove_positional","root":3,"path":[],"index":2},
        \\{"op":"remove_positional","root":3,"path":[],"index":3},
        \\{"op":"insert_positional","root":3,"path":[],"index":6,"value":{"$form":"note-on","at":960,"ch":1,"key":36,"vel":100}},
        \\{"op":"insert_positional","root":3,"path":[],"index":8,"value":{"$form":"note-off","at":1200,"ch":1,"key":36,"vel":64}}
        \\]
        \\
    ,
        &.{
            // The comment leaves with the note it led: the JSON bridge
            // carries no trivia (plan 07's risk note).
            .{
                .from = "  ; the downbeat\n  (note-on        :at 0    :ch 1 :key 36 :vel 100)\n " ++
                    " (note-off       :at 240  :ch 1 :key 36 :vel 64)\n",
                .to = "",
            },
            .{
                .from = "  (note-off       :at 1200 :ch 1 :key 41 :vel 64)\n",
                .to = "  (note-on :at 960 :ch 1 :key 36 :vel 100)\n  (note-off       :at 1200 " ++
                    ":ch 1 :key 41 :vel 64)\n  (note-off :at 1200 :ch 1 :key 36 :vel 64)\n",
            },
        },
    );
}

test "bound SMF: resize moves the note-off and leaves the note-on where it is" {
    try expectEdit(
        test_support.bound_smf,
        .{ .resize = .{
            .sel = .{ .lanes = &.{"kick"}, .kinds = .notes, .range = .{ 0, 1 } },
            .dur = TPQ,
        } },
        \\[
        \\{"op":"set_keyword","root":3,"path":[3],"key":"at","value":480}
        \\]
        \\
    ,
        &.{.{
            .from = "(note-off       :at 240  :ch 1 :key 36 :vel 64)",
            .to = "(note-off       :at 480  :ch 1 :key 36 :vel 64)",
        }},
    );
}

test "bound SMF: velocity writes the note-on's :vel and nothing else" {
    try expectEdit(
        test_support.bound_smf,
        .{ .velocity = .{
            .sel = .{ .lanes = &.{"kick"}, .kinds = .notes, .range = .{ 0, 1 } },
            .vel = 64,
        } },
        \\[
        \\{"op":"set_keyword","root":3,"path":[2],"key":"vel","value":64}
        \\]
        \\
    ,
        &.{.{
            .from = "(note-on        :at 0    :ch 1 :key 36 :vel 100)",
            .to = "(note-on        :at 0    :ch 1 :key 36 :vel 64)",
        }},
    );
}

test "bound SMF: remove takes both events of the pair" {
    try expectEdit(
        test_support.bound_smf,
        .{ .remove = .{ .sel = .{ .lanes = &.{"kick"}, .kinds = .notes, .range = .{ 0, 1 } } } },
        \\[
        \\{"op":"remove_positional","root":3,"path":[],"index":2},
        \\{"op":"remove_positional","root":3,"path":[],"index":3}
        \\]
        \\
    ,
        &.{.{
            .from = "  ; the downbeat\n  (note-on        :at 0    :ch 1 :key 36 :vel 100)\n  " ++
                "(note-off       :at 240  :ch 1 :key 36 :vel 64)\n",
            .to = "",
        }},
    );
}

test "bound SMF: a controller step is one event, and it moves like one" {
    try expectEdit(
        test_support.bound_smf,
        .{ .retime = .{
            .sel = .{
                .lanes = &.{"filter"},
                .kinds = .keyframes,
                .range = .{ 2 * TPQ, 2 * TPQ + 1 },
            },
            .delta = -TPQ,
        } },
        \\[
        \\{"op":"remove_positional","root":3,"path":[],"index":6},
        \\{"op":"insert_positional","root":3,"path":[],"index":5,"value":{"$form":"control-change","at":480,"ch":1,"num":74,"val":100}}
        \\]
        \\
    ,
        &.{
            .{
                .from = "  (control-change :at 960  :ch 1 :num 74 :val 100)\n",
                .to = "",
            },
            .{
                .from = "  (note-off       :at 720  :ch 1 :key 38 :vel 64)\n",
                .to = "  (control-change :at 480 :ch 1 :num 74 :val 100)\n  (note-off       :at " ++
                    "720  :ch 1 :key 38 :vel 64)\n",
            },
        },
    );
}

test "bound SMF: the pairing here is the bridge's pairing" {
    // This file pairs `note-on` with `note-off` over the TREE, because a
    // plan needs the two events' addresses and a `PairedNote` carries
    // values alone. The two walks are one rule, and this is where they
    // are held to it.
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.bound_smf);
    defer fx.deinit();

    var b: Plan.Builder = .init(gpa);
    defer b.deinit();
    var loc: locate.Map = try .init(gpa, &fx.tree);
    defer loc.deinit();
    var map = try doc.fromSjon.mapOf(gpa, fx.doc_());
    defer map.deinit();

    var ctx: Ctx = .{
        .gpa = gpa,
        .arena = b.allocator(),
        .d = fx.doc_(),
        .tree = &fx.tree,
        .map = &map,
        .loc = &loc,
        .b = &b,
    };
    const track = ctx.mtrkRoot("song", 1).?;
    const mine = try ctx.pairs(try ctx.events(track), .single(0), null);

    var theirs = try doc.bridge_smf.pairNotes(
        gpa,
        &fx.doc_().midi[0].sequence,
        1,
        .single(0),
        null,
    );
    defer theirs.deinit();

    try testing.expectEqual(theirs.notes.len, mine.len);
    for (theirs.notes, mine) |t, m| {
        try testing.expectEqual(t.at, m.at);
        try testing.expectEqual(t.dur, m.end - m.at);
        try testing.expectEqual(t.key, m.key);
        try testing.expectEqual(t.vel, m.vel);
        try testing.expectEqual(t.off_vel, m.off_vel);
        try testing.expectEqual(t.ch, m.ch);
    }
}

test "bound SMF: materialize copies the notes in and takes the events out" {
    try expectEdit(
        test_support.bound_smf,
        .{ .materialize = .{ .lane = "kick" } },
        \\[
        \\{"op":"insert_positional","root":4,"path":[],"index":0,"value":{"$form":"note","at":{"$num":[0,"bar"]},"dur":{"$num":[0.5,"q"]},"key":36,"vel":100,"off-vel":64}},
        \\{"op":"insert_positional","root":4,"path":[],"index":1,"value":{"$form":"note","at":{"$num":[1,"q"]},"dur":{"$num":[0.5,"q"]},"key":38,"vel":90,"off-vel":64}},
        \\{"op":"insert_positional","root":4,"path":[],"index":2,"value":{"$form":"note","at":{"$num":[2,"q"]},"dur":{"$num":[0.5,"q"]},"key":41,"vel":80,"off-vel":64}},
        \\{"op":"remove_positional","root":3,"path":[],"index":2},
        \\{"op":"remove_positional","root":3,"path":[],"index":3},
        \\{"op":"remove_positional","root":3,"path":[],"index":4},
        \\{"op":"remove_positional","root":3,"path":[],"index":5},
        \\{"op":"remove_positional","root":3,"path":[],"index":7},
        \\{"op":"remove_positional","root":3,"path":[],"index":8},
        \\{"op":"remove_keyword","root":4,"path":[],"key":"from"},
        \\{"op":"remove_keyword","root":4,"path":[],"key":"track"},
        \\{"op":"remove_keyword","root":4,"path":[],"key":"ch"}
        \\]
        \\
    ,
        &.{
            .{
                .from = "  ; the downbeat\n  (note-on        :at 0    :ch 1 :key 36 :vel 100)\n " ++
                    " (note-off       :at 240  :ch 1 :key 36 :vel 64)\n  (note-on        :at " ++
                    "480  :ch 1 :key 38 :vel 90)\n  (note-off       :at 720  :ch 1 :key 38 " ++
                    ":vel 64)\n",
                .to = "",
            },
            .{
                .from = "  (note-on        :at 960  :ch 1 :key 41 :vel 80)\n  (note-off       " ++
                    ":at 1200 :ch 1 :key 41 :vel 64)\n",
                .to = "",
            },
            .{
                .from = "(lane :name kick :kind notes :from song :track 1 :ch 1)",
                // The lane was one line and stays one line: SJON's
                // `.preserve` splices into the layout the author chose
                // rather than re-formatting the form around it.
                .to = "(lane :name kick :kind notes (note :at 0bar :dur 0.5q :key 36 :vel 100 " ++
                    ":off-vel 64) (note :at 1q :dur 0.5q :key 38 :vel 90 :off-vel 64) (note :at " ++
                    "2q :dur 0.5q :key 41 :vel 80 :off-vel 64))",
            },
        },
    );
}

test "bound SMF: materialize of a curve lane writes keyframes and keeps its :cc" {
    // A controller's values are normalised 0..1 the way a bound curve
    // reads them; `:range` scales them at export, and the easing between
    // two of them is the schema's own `linear`, so neither is written.
    // `:cc` STAYS: on a native curve lane it is the controller a build
    // renders onto (plan 08), so the lane keeps the number it came from
    // and a later `.mid` puts it back on the same controller.
    try expectEdit(
        test_support.bound_smf,
        .{ .materialize = .{ .lane = "filter" } },
        \\[
        \\{"op":"insert_positional","root":5,"path":[],"index":0,"value":{"$form":"keyframe","at":{"$num":[0,"bar"]},"value":0.07874016}},
        \\{"op":"insert_positional","root":5,"path":[],"index":1,"value":{"$form":"keyframe","at":{"$num":[2,"q"]},"value":0.78740156}},
        \\{"op":"remove_positional","root":3,"path":[],"index":1},
        \\{"op":"remove_positional","root":3,"path":[],"index":6},
        \\{"op":"remove_keyword","root":5,"path":[],"key":"from"},
        \\{"op":"remove_keyword","root":5,"path":[],"key":"track"},
        \\{"op":"remove_keyword","root":5,"path":[],"key":"ch"}
        \\]
        \\
    ,
        &.{
            .{ .from = "  (control-change :at 0    :ch 1 :num 74 :val 10)\n", .to = "" },
            .{ .from = "  (control-change :at 960  :ch 1 :num 74 :val 100)\n", .to = "" },
            .{
                .from = "(lane :name filter :kind curve :from song :track 1 :ch 1 :cc 74)",
                .to = "(lane :name filter :kind curve :cc 74 (keyframe :at 0bar :value " ++
                    "0.07874016) (keyframe :at 2q :value 0.78740156))",
            },
        },
    );
}

test "bound SMF: materialize refuses a lane that already carries content" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.initUnchecked(gpa, test_support.bound_smf_two_homes);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, .{ .materialize = .{ .lane = "kick" } });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    try testing.expect(p.findDiag(.edit_would_duplicate) != null);
}

test "bound: unbind of a lane that carries content is edit_would_duplicate too" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.initUnchecked(gpa, test_support.bound_smf_two_homes);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, .{ .unbind = .{ .lane = "kick" } });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    try testing.expect(p.findDiag(.edit_would_duplicate) != null);
}

test "bound: a lane bound to a by-reference anchor has nothing to edit — edit_target_bound" {
    // The native fixture's `kick` names an anchor with no inline dump:
    // its content is in a file nothing has read, so there is no event to
    // address and the plan says so on the lane.
    try expectRefusal(
        test_support.native,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"kick"}, .kinds = .notes },
            .delta = TPQ,
        } },
        .edit_target_bound,
    );
}

// ---- IT ----

test "bound IT: a retime inside a row is an SDx delay in the cell's own column" {
    // A sixteenth at speed 24 is six IT ticks: the cell stays where it
    // is and says it sounds six ticks late.
    try expectEdit(
        test_support.bound_it,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} },
            .delta = @divExact(TPQ, 4),
        } },
        \\[
        \\{"op":"set_keyword","root":2,"path":[2,2,1],"key":"fx","value":"SD6"}
        \\]
        \\
    ,
        &.{.{
            .from = "(row 2 (ev 1 \"E-5\" :ins 1))",
            .to = "(row 2 (ev 1 \"E-5\" :ins 1 :fx \"SD6\"))",
        }},
    );
}

test "bound IT: a delay past SDF is edit_inexact" {
    try expectRefusal(
        test_support.bound_it,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} },
            .delta = 16 * Grid.IT_TICK,
        } },
        .edit_inexact,
    );
}

test "bound IT: a cell whose effect column is taken cannot be delayed — edit_inexact" {
    // The first cell carries `G01`; the plan refuses rather than drop it.
    try expectRefusal(
        test_support.bound_it,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{60} },
            .delta = @divExact(TPQ, 4),
        } },
        .edit_inexact,
    );
}

test "bound IT: a cell that crosses into a pattern one order plays moves there" {
    // Three quarters on is order 1's row 1 — pattern 1, which only order
    // 1 plays. The source row is emptied, so it goes with the cell.
    try expectEdit(
        test_support.bound_it,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} },
            .delta = 3 * TPQ,
        } },
        \\[
        \\{"op":"remove_positional","root":2,"path":[2],"index":2},
        \\{"op":"insert_positional","root":2,"path":[3],"index":2,"value":{"$form":"row","$children":[1,{"$form":"ev","ins":1,"$children":[1,"E-5"]}]}}
        \\]
        \\
    ,
        &.{
            .{
                .from = "\n    (row 2 (ev 1 \"E-5\" :ins 1))",
                .to = "",
            },
            .{
                .from = "    (row 0 (ev 1 \"G-5\" :ins 1)))",
                .to = "    (row 0 (ev 1 \"G-5\" :ins 1))\n    (row 1 (ev :ins 1 1 \"E-5\")))",
            },
        },
    );
}

test "bound IT: a cell that crosses into a shared pattern is edit_pattern_shared" {
    try expectRefusal(
        test_support.bound_it,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} },
            .delta = 6 * TPQ,
        } },
        .edit_pattern_shared,
    );
}

test "bound IT: :allow-shared moves the cell, and every occurrence changes" {
    try expectEdit(
        test_support.bound_it,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} },
            .delta = 6 * TPQ,
            .allow_shared = true,
        } },
        \\[
        \\{"op":"remove_positional","root":2,"path":[2],"index":2},
        \\{"op":"insert_positional","root":2,"path":[4],"index":1,"value":{"$form":"row","$children":[0,{"$form":"ev","ins":1,"$children":[1,"E-5"]}]}}
        \\]
        \\
    ,
        &.{
            .{
                .from = "\n    (row 2 (ev 1 \"E-5\" :ins 1))",
                .to = "",
            },
            .{
                .from = "  (it/pattern 2 :rows 4))",
                .to = "  (it/pattern 2 :rows 4 (row 0 (ev :ins 1 1 \"E-5\"))))",
            },
        },
    );
}

test "bound IT: velocity writes the volume column" {
    // `round(100 · 64 / 127)` is 50.
    try expectEdit(
        test_support.bound_it,
        .{ .velocity = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} },
            .vel = 100,
        } },
        \\[
        \\{"op":"set_keyword","root":2,"path":[2,2,1],"key":"vol","value":50}
        \\]
        \\
    ,
        &.{.{
            .from = "(row 2 (ev 1 \"E-5\" :ins 1))",
            .to = "(row 2 (ev 1 \"E-5\" :ins 1 :vol 50))",
        }},
    );
}

test "bound IT: resize is edit_inexact — a cell ends where the next one starts" {
    try expectRefusal(
        test_support.bound_it,
        .{ .resize = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} },
            .dur = TPQ,
        } },
        .edit_inexact,
    );
}

test "bound IT: remove takes the cell, and the row it emptied with it" {
    try expectEdit(
        test_support.bound_it,
        .{ .remove = .{ .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} } } },
        \\[
        \\{"op":"remove_positional","root":2,"path":[2],"index":2}
        \\]
        \\
    ,
        &.{.{
            .from = "\n    (row 2 (ev 1 \"E-5\" :ins 1))",
            .to = "",
        }},
    );
}

test "bound IT: materialize is parked — a channel's cells serve every order" {
    try expectRefusal(
        test_support.bound_it,
        .{ .materialize = .{ .lane = "lead" } },
        .edit_would_duplicate,
    );
}

// ---- the fixes of review round 1 ----

test "bound SMF: a retime off the file's own grid is rounded and counted" {
    // A sixteenth at 480 PPQ is 120 pulses; half of one is not a pulse
    // at all, so the onset lands on the nearest and the plan says how
    // many positions it did that to.
    try expectEditNoting(
        test_support.bound_smf,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"kick"}, .kinds = .notes, .range = .{ TPQ, TPQ + 1 } },
            .delta = @divExact(TPQ, 320),
        } },
        \\[
        \\{"op":"set_keyword","root":3,"path":[4],"key":"at","value":482},
        \\{"op":"set_keyword","root":3,"path":[5],"key":"at","value":722}
        \\]
        \\
    ,
        &.{
            .{
                .from = "(note-on        :at 480  :ch 1 :key 38 :vel 90)",
                .to = "(note-on        :at 482  :ch 1 :key 38 :vel 90)",
            },
            .{
                .from = "(note-off       :at 720  :ch 1 :key 38 :vel 64)",
                .to = "(note-off       :at 722  :ch 1 :key 38 :vel 64)",
            },
        },
        .edit_inexact,
        1,
    );
}

test "bound SMF: materialize off the grid counts the positions it rounded" {
    // 500 does not divide the grid, so SMF tick 1 has no tick of its own
    // and the note lands on the nearest. The DURATION is exact — 250
    // pulses is half a quarter note whatever the division — which is
    // what makes the count about positions and not about lengths.
    try expectEditNoting(
        test_support.bound_smf_offgrid,
        .{ .materialize = .{ .lane = "kick" } },
        \\[
        \\{"op":"insert_positional","root":4,"path":[],"index":0,"value":{"$form":"note","at":{"$num":[92252,"t"]},"dur":{"$num":[0.5,"q"]},"key":36,"vel":100,"off-vel":64}},
        \\{"op":"remove_positional","root":3,"path":[],"index":1},
        \\{"op":"remove_positional","root":3,"path":[],"index":2},
        \\{"op":"remove_keyword","root":4,"path":[],"key":"from"},
        \\{"op":"remove_keyword","root":4,"path":[],"key":"track"},
        \\{"op":"remove_keyword","root":4,"path":[],"key":"ch"}
        \\]
        \\
    ,
        &.{
            .{
                .from = "  (note-on      :at 1   :ch 1 :key 36 :vel 100)\n  (note-off     :at " ++
                    "251 :ch 1 :key 36 :vel 64)\n",
                .to = "",
            },
            .{
                .from = "(lane :name kick :kind notes :from song :track 1 :ch 1)",
                .to = "(lane :name kick :kind notes (note :at 92252t :dur 0.5q :key 36 :vel 100 " ++
                    ":off-vel 64))",
            },
        },
        .edit_inexact,
        1,
    );
}

test "bound: a surface no operation here reaches refuses rather than goes quiet" {
    // A 14-bit controller is two events per value; `:velocity` is the
    // notes' own velocities and not a stream; an Impulse Tracker column
    // is part of the cells the notes live in. None of the three is
    // editable here, and none of them silently plans nothing.
    for ([_][]const u8{ "wide", "dynamics" }) |lane| {
        try expectRefusal(
            test_support.bound_smf,
            .{ .retime = .{ .sel = .{ .lanes = &.{lane} }, .delta = TPQ } },
            .edit_target_bound,
        );
        try expectRefusal(
            test_support.bound_smf,
            .{ .materialize = .{ .lane = lane } },
            .edit_target_bound,
        );
    }

    try expectRefusal(
        test_support.bound_it,
        .{ .retime = .{ .sel = .{ .lanes = &.{"loud"} }, .delta = TPQ } },
        .edit_target_bound,
    );
    // An IT lane's materialize is PARKED before its surface is looked
    // at, and the park is the truer answer: a channel's cells serve
    // every order that plays their pattern, column and notes alike.
    try expectRefusal(
        test_support.bound_it,
        .{ .materialize = .{ .lane = "loud" } },
        .edit_would_duplicate,
    );
}

test "bound IT: a cell moved into a surviving row takes the slot the removals left" {
    // The source row is emptied and goes, so every row after it in the
    // pattern moves up one — including the row the cell is landing in.
    // An insert against the slot the DOCUMENT gave that row would name
    // the wrong one.
    try expectEdit(
        test_support.bound_it_rows,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{60} },
            .delta = 4 * TPQ,
        } },
        \\[
        \\{"op":"remove_positional","root":2,"path":[2],"index":1},
        \\{"op":"insert_positional","root":2,"path":[2,2],"index":1,"value":{"$form":"ev","ins":1,"$children":[1,"C-5"]}}
        \\]
        \\
    ,
        &.{
            .{ .from = "\n    (row 0 (ev 1 \"C-5\" :ins 1))", .to = "" },
            .{
                .from = "(row 4 (ev 2 \"C-6\" :ins 1))",
                .to = "(row 4 (ev :ins 1 1 \"C-5\") (ev 2 \"C-6\" :ins 1))",
            },
        },
    );
}

test "bound IT: two rows removed beneath the target shift it twice" {
    // Both of the lane's cells move: one into a row that survives, one
    // into a row that has to be made, with two removals underneath them
    // both. The surviving row's slot counts only the rows that are left,
    // and the new row's index is counted the same way — the two branches
    // agree or the plan is nonsense.
    try expectEdit(
        test_support.bound_it_rows,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{ 60, 64 } },
            .delta = 4 * TPQ,
        } },
        \\[
        \\{"op":"remove_positional","root":2,"path":[2],"index":1},
        \\{"op":"remove_positional","root":2,"path":[2],"index":2},
        \\{"op":"insert_positional","root":2,"path":[2,1],"index":1,"value":{"$form":"ev","ins":1,"$children":[1,"C-5"]}},
        \\{"op":"insert_positional","root":2,"path":[2],"index":2,"value":{"$form":"row","$children":[5,{"$form":"ev","ins":1,"$children":[1,"E-5"]}]}}
        \\]
        \\
    ,
        &.{
            .{ .from = "\n    (row 0 (ev 1 \"C-5\" :ins 1))", .to = "" },
            .{ .from = "\n    (row 1 (ev 1 \"E-5\" :ins 1))", .to = "" },
            .{
                .from = "(row 4 (ev 2 \"C-6\" :ins 1))",
                .to = "(row 4 (ev :ins 1 1 \"C-5\") (ev 2 \"C-6\" :ins 1))\n    (row 5 (ev :ins " ++
                    "1 1 \"E-5\"))",
            },
        },
    );
}

test "bound IT: every edit to a cell in a shared pattern is edit_pattern_shared" {
    // Plan 07's diagnostics table is about the CELL: the pattern is
    // stored once and played twice, so a volume and a removal change
    // both occurrences exactly as a retime would.
    try expectRefusal(
        test_support.bound_it_shared,
        .{ .velocity = .{ .sel = .{ .lanes = &.{"lead"}, .kinds = .notes }, .vel = 100 } },
        .edit_pattern_shared,
    );
    try expectRefusal(
        test_support.bound_it_shared,
        .{ .remove = .{ .sel = .{ .lanes = &.{"lead"}, .kinds = .notes } } },
        .edit_pattern_shared,
    );
    try expectRefusal(
        test_support.bound_it_shared,
        .{ .retime = .{ .sel = .{ .lanes = &.{"lead"}, .kinds = .notes }, .delta = TPQ } },
        .edit_pattern_shared,
    );
}

test "bound IT: :allow-shared writes the volume, in both occurrences at once" {
    try expectEdit(
        test_support.bound_it_shared,
        .{ .velocity = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes },
            .vel = 100,
            .allow_shared = true,
        } },
        \\[
        \\{"op":"set_keyword","root":2,"path":[2,1,1],"key":"vol","value":50}
        \\]
        \\
    ,
        &.{.{
            .from = "(row 0 (ev 1 \"C-5\" :ins 1))",
            .to = "(row 0 (ev 1 \"C-5\" :ins 1 :vol 50))",
        }},
    );
}

test "bound IT: a (row N …) or an (ev N …) past the module's own domain cannot panic" {
    // The final review's I1, last row. `@intCast(@max(0, r.number))`
    // into a `u16` and `@intCast(@max(0, ev.number - 1))` into a `u32`
    // are casts over DOCUMENT TEXT: the schema bounds both numbers and
    // says so with a span, but this walk runs over the document that
    // COLLECTED that complaint (collection over abort), so the cast has
    // to survive whatever the walk was handed.
    //
    // Clamping to the domain's ends is also the right answer rather than
    // merely the safe one: the module has no row 70 000 and no channel
    // five billion, so a clamped number matches no cell and the edit
    // finds nothing — which is what a row that does not exist deserves.
    try testing.expectEqual(@as(u16, 0), narrowed(u16, -5));
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), narrowed(u16, 70_000));
    try testing.expectEqual(@as(u16, 12), narrowed(u16, 12));
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), narrowed(u32, 5_000_000_000));
    try testing.expectEqual(@as(u32, 0), narrowed(u32, std.math.minInt(i64)));

    // …and end to end, over a document that really does say so. The plan
    // is TOTAL — refused or not, it comes back — and nothing asserts.
    const gpa = testing.allocator;
    const source: [:0]const u8 =
        \\(timeline :title "wild" :conductor mod :length 2bar)
        \\
        \\(anchor :id mod :kind it :file "y.it")
        \\(it/module :title "wild"
        \\  (it/timing :speed 24 :tempo 125)
        \\  (it/orders 0 end)
        \\  (it/pattern 0 :rows 8
        \\    (row 0 (ev 1 "C-5" :ins 1))
        \\    (row 70000 (ev 5000000000 "E-5" :ins 1))))
        \\
        \\(lane :name lead :kind notes :from mod :channel 1)
        \\
    ;
    var fx = try test_support.Fixture.initUnchecked(gpa, source);
    defer fx.deinit();

    for ([_]Op.Op{
        .{ .retime = .{ .sel = .{ .lanes = &.{"lead"}, .kinds = .notes }, .delta = TPQ } },
        .{ .remove = .{ .sel = .{ .lanes = &.{"lead"}, .kinds = .notes } } },
        .{ .velocity = .{ .sel = .{ .lanes = &.{"lead"}, .kinds = .notes }, .vel = 64 } },
    }) |op| {
        var p = try plan(gpa, fx.doc_(), &fx.tree, op);
        p.deinit();
    }
}

test "planWith: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails with
    // error.OutOfMemory and testing.allocator sees no leak; past the last
    // index it succeeds. Bounded by the number of allocations each plan
    // makes, which the loop discovers.
    //
    // One row per path the planners take through an allocation: a native
    // move past a neighbour (the running model, a remove and an insert),
    // a copy, a stretch, a rename, an insert that builds nested forms and
    // one that parses an easing; a bound SMF pair and a controller step
    // moved, a materialize; a bound IT cell delayed in its row, one moved
    // into a pattern with no such row, one into a row that survives.
    const Case = struct { source: [:0]const u8, op: Op.Op };
    const cases = [_]Case{
        .{ .source = test_support.native, .op = .{ .retime = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .notes, .range = .{ 0, 1 } },
            .to = 3 * TPQ,
        } } },
        .{ .source = test_support.native, .op = .{ .duplicate = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .notes },
            .delta = 4 * TPQ,
        } } },
        .{ .source = test_support.native, .op = .{ .stretch = .{
            .from = 0,
            .to = 2 * TPQ,
            .p = 3,
            .q = 2,
        } } },
        .{ .source = test_support.native, .op = .{ .rename = .{
            .what = .lane,
            .from = "flash",
            .to = "strobe",
        } } },
        .{ .source = test_support.native, .op = .{ .insert = .{ .what = .{ .phrase = .{
            .name = "roll",
            .length = 4 * TPQ,
            .lanes = &.{ "flash", "glow" },
        } } } } },
        .{ .source = test_support.native, .op = .{ .insert = .{ .lane = "glow", .what = .{
            .keyframe = .{ .at = 2 * TPQ, .value = .{ 0.5, 0, 0, 0 }, .ease = "in-cubic" },
        } } } },
        .{ .source = test_support.bound_smf, .op = .{ .retime = .{
            .sel = .{ .lanes = &.{"kick"}, .kinds = .notes, .range = .{ 0, 1 } },
            .delta = 2 * TPQ,
        } } },
        .{ .source = test_support.bound_smf, .op = .{ .retime = .{
            .sel = .{
                .lanes = &.{"filter"},
                .kinds = .keyframes,
                .range = .{ 2 * TPQ, 2 * TPQ + 1 },
            },
            .delta = -TPQ,
        } } },
        .{ .source = test_support.bound_smf, .op = .{ .materialize = .{ .lane = "kick" } } },
        .{ .source = test_support.bound_it, .op = .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} },
            .delta = @divExact(TPQ, 4),
        } } },
        .{ .source = test_support.bound_it, .op = .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{64} },
            .delta = 3 * TPQ,
        } } },
        .{ .source = test_support.bound_it_rows, .op = .{ .retime = .{
            .sel = .{ .lanes = &.{"lead"}, .kinds = .notes, .keys = &.{60} },
            .delta = 4 * TPQ,
        } } },
    };
    const gpa = testing.allocator;
    for (cases) |case| {
        var fx = try test_support.Fixture.init(gpa, case.source);
        defer fx.deinit();
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            const planning = failing.allocator();
            const result = planWith(planning, fx.doc_(), &fx.tree, &fx.loaded.map, case.op);
            if (failing.has_induced_failure) {
                try testing.expectError(error.OutOfMemory, result);
            } else {
                var planned = try result;
                defer planned.deinit();
                // The plan the sweep ends on is an accepted one: a row
                // that refused would prove the refusal path, not the plan.
                try testing.expect(!planned.summary.refused);
                break;
            }
        }
    }
}
