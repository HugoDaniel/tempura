//! The native operations (plan 07, "The operations", every row that acts
//! on content the document itself holds).
//!
//! One function from a document and an operation to a list of SJON edit
//! actions. It never mutates the document, it never reads a file, and it
//! is total: what it cannot do it refuses, with the span of the form it
//! refused on.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const doc = @import("../doc/doc.zig");
const Grid = @import("../time/Grid.zig");
const Pos = @import("../time/Pos.zig");
const TimeMap = @import("../time/TimeMap.zig");

const Op = @import("Op.zig");
const Plan = @import("Plan.zig");
const Select = @import("Select.zig");
const Snap = @import("Snap.zig");
const locate = @import("locate.zig");
const ops_quantize = @import("ops_quantize.zig");
const value = @import("value.zig");

const testing = std.testing;

pub const Error = error{OutOfMemory};

/// Plan `op` over `d`, whose source `tree` is.
///
/// `d` and `tree` are two readings of ONE text: the document's values
/// come from the first and its addresses from the second, joined by the
/// span every `Doc` node carries. Handing in a tree of another document
/// is the one way to make this function say `sjon_diagnostic` about
/// itself.
///
/// The time map comes from the DOCUMENT LAYER (`doc.fromSjon.mapOf`),
/// which is the layer that owns it: a position this plan spells is then
/// the position the canonical printer would have spelled, conductor and
/// all. A caller that already holds the map — one that loaded the
/// document and kept `Result.map` — calls `planWith` and does not pay
/// for a second derive.
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
/// `map` must be the map `d` resolved its positions against —
/// `Result.map`, or `doc.fromSjon.mapOf(gpa, d)`. Another map would
/// spell positions the document does not mean.
pub fn planWith(
    gpa: std.mem.Allocator,
    d: *const doc.Doc,
    tree: *const sjon.Ast.Tree,
    map: *const TimeMap.TimeMap,
    op: Op.Op,
) Error!Plan.Plan {
    var b: Plan.Builder = .init(gpa);
    errdefer b.deinit();

    var loc: locate.Map = try .init(gpa, tree);
    defer loc.deinit();

    var ctx: Ctx = .{
        .gpa = gpa,
        .d = d,
        .tree = tree,
        .map = map,
        .loc = &loc,
        .b = &b,
    };
    try ctx.run(op);
    return b.finish();
}

/// One child of a lane, as both readings see it: where its bytes are and
/// what the document says it is.
const Child = struct {
    slot: u32,
    at: i64,
    kind: Select.Kind,
    item: u32,
    span: Diag.Span,
};

/// What every operation plans against.
const Ctx = struct {
    gpa: std.mem.Allocator,
    d: *const doc.Doc,
    tree: *const sjon.Ast.Tree,
    map: *const TimeMap.TimeMap,
    loc: *const locate.Map,
    b: *Plan.Builder,
    /// How many roots this plan has already inserted. A root insert's
    /// index is a slot in the document the plan PRODUCES, so the second
    /// one after a given head lands one further along than the first.
    root_inserts: u32 = 0,

    fn a(self: *Ctx) std.mem.Allocator {
        return self.b.allocator();
    }

    fn run(self: *Ctx, op: Op.Op) Error!void {
        switch (op) {
            .insert => |x| try self.insert(x),
            .remove => |x| try self.remove(x),
            .retime => |x| try self.retime(x),
            .revalue => |x| try self.revalue(x),
            .ease => |x| try self.ease(x),
            .resize => |x| try self.resize(x),
            .velocity => |x| try self.velocity(x),
            .transpose => |x| try self.transpose(x),
            .split => |x| try self.split(x),
            .merge => |x| try self.merge(x),
            .duplicate => |x| try self.duplicate(x),
            .stretch => |x| try self.stretch(x),
            .insert_tempo => |x| try self.insertTempo(x),
            .insert_meter => |x| try self.insertMeter(x),
            .rename => |x| try self.rename(x),
            .bind => |x| try self.bind(x),
            .unbind => |x| try self.unbind(x),
            // The one operation of plan 07's table that reads an
            // anchor's events: `ops_bound` takes it before this file is
            // reached, and a caller that came straight here is told so
            // rather than handed a silent no-op.
            .materialize => |x| try self.materializeElsewhere(x),
            // Both are a `retime` with a rule for where to, and the
            // rule is `ops_quantize`'s.
            .quantize => |x| try self.quantize(x),
            .nudge => |x| try self.nudge(x),
        }
    }

    // ---- the joins ----

    /// The address of the form whose span is `span`.
    ///
    /// The one place a pass-through pacer form is stopped: the studio
    /// edits those through pacer's own spans, so an operation that lands
    /// inside one is refused rather than half-done.
    fn where(self: *Ctx, span: Diag.Span) Error!?locate.Where {
        for (self.d.passthrough) |pt| {
            if (span.start >= pt.span.start and span.end <= pt.span.end) {
                try self.b.refuse(
                    .edit_readonly_passthrough,
                    span,
                    "({s} …) passes through to pacer; tempura does not edit it",
                    .{pt.head},
                );
                return null;
            }
        }
        const w = try self.loc.at(self.a(), span);
        if (w == null) try self.refuseUnaddressable(span);
        return w;
    }

    /// The document and its tree disagree: a form the `Doc` holds that
    /// the tree cannot address, or one with no container where a
    /// container is needed. Nothing a document can say causes it — a
    /// host that handed in the wrong tree can — and it is said out loud
    /// rather than quietly shortening the plan.
    fn refuseUnaddressable(self: *Ctx, span: Diag.Span) Error!void {
        try self.b.refuse(
            .sjon_diagnostic,
            span,
            "the document and its source tree disagree about the form at {d}..{d}",
            .{ span.start, span.end },
        );
    }

    /// The selection's targets, or a refusal: bound content is not
    /// editable here, and an empty selection is nothing to do.
    fn targets(self: *Ctx, sel: Select.Select) Error!?Select.Resolved {
        var r = try Select.resolve(self.gpa, self.d, sel);
        errdefer r.deinit();
        if (r.bound) |span| {
            try self.b.refuse(
                .edit_target_bound,
                span,
                "this lane's content lives in its anchor's file; inline it first",
                .{},
            );
            r.deinit();
            return null;
        }
        if (r.targets.len == 0) {
            try self.b.refuse(.edit_range_empty, self.selectionSpan(sel), "the selection resolved to nothing", .{});
            r.deinit();
            return null;
        }
        self.b.summary.targets = @intCast(r.targets.len);
        return r;
    }

    /// Where to point a refusal that has no node: the first lane the
    /// selection named, or the start of the document.
    fn selectionSpan(self: *Ctx, sel: Select.Select) Diag.Span {
        if (sel.lanes) |names| {
            for (names) |name| {
                for (self.d.lanes) |lane| {
                    if (std.mem.eql(u8, lane.name, name)) return lane.span;
                }
            }
        }
        return .{ .start = 0, .end = 0 };
    }

    fn laneByName(self: *Ctx, name: []const u8) ?u32 {
        for (self.d.lanes, 0..) |lane, i| {
            if (std.mem.eql(u8, lane.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Every child of lane `li`, in positional order.
    fn children(self: *Ctx, li: u32) Error!?[]Child {
        const lane = self.d.lanes[li];
        var list: std.ArrayList(Child) = .empty;
        const alloc = self.a();
        for (lane.notes, 0..) |n, i| {
            const w = (try self.where(n.span)) orelse return null;
            try list.append(alloc, .{ .slot = w.slot, .at = n.at, .kind = .note, .item = @intCast(i), .span = n.span });
        }
        for (lane.keyframes, 0..) |k, i| {
            const w = (try self.where(k.span)) orelse return null;
            try list.append(alloc, .{ .slot = w.slot, .at = k.at, .kind = .keyframe, .item = @intCast(i), .span = k.span });
        }
        for (lane.clips, 0..) |c, i| {
            const w = (try self.where(c.span)) orelse return null;
            try list.append(alloc, .{ .slot = w.slot, .at = c.at, .kind = .clip, .item = @intCast(i), .span = c.span });
        }
        const out = try list.toOwnedSlice(alloc);
        std.sort.insertion(Child, out, {}, bySlot);
        return out;
    }

    /// The span of a note on `key` that `[at, at + dur)` would sound
    /// over, or null — `ignore` is the note being moved, which does not
    /// overlap itself.
    ///
    /// Two notes on one key in one lane cannot overlap (the document's
    /// own `note_overlap`), so an edit that would make them is refused
    /// before it is planned rather than written and complained about.
    fn overlapping(self: *Ctx, li: u32, key: u7, at: i64, dur: i64, ignore: ?Diag.Span) ?Diag.Span {
        if (dur <= 0) return null;
        for (self.d.lanes[li].notes) |n| {
            if (n.key != key or n.dur <= 0) continue;
            if (ignore) |sp| {
                if (n.span.start == sp.start and n.span.end == sp.end) continue;
            }
            if (at < n.at +| n.dur and n.at < at +| dur) return n.span;
        }
        return null;
    }

    /// The tree node of the form whose span is `span`.
    fn nodeOf(self: *Ctx, span: Diag.Span) ?sjon.Ast.NodeIndex {
        return sjon.Edit.nodeAtSpan(self.tree, .{ .start = span.start, .end = span.end });
    }

    /// The source text of `key`'s value on the form at `span`, or null
    /// when the form does not carry that key.
    fn keyText(self: *Ctx, span: Diag.Span, key: []const u8) ?[]const u8 {
        const idx = self.nodeOf(span) orelse return null;
        if (self.tree.tagOf(idx) != .form) return null;
        for (self.tree.formHeader(idx).children) |child| {
            if (self.tree.tagOf(child) != .kvpair) continue;
            const kv = self.tree.kvpairHeader(child);
            if (!std.mem.eql(u8, kv.key, key)) continue;
            const s = self.tree.spanOf(kv.value);
            return self.tree.source[s.start..s.end];
        }
        return null;
    }

    // ---- the value writers ----

    fn positionJson(self: *Ctx, tick: i64) Error![]const u8 {
        var out: value.Buf = .empty;
        defer out.deinit(self.gpa);
        try value.position(self.gpa, &out, self.map, tick);
        return self.a().dupe(u8, out.items);
    }

    fn durationJson(self: *Ctx, ticks: i64, at: i64) Error![]const u8 {
        var out: value.Buf = .empty;
        defer out.deinit(self.gpa);
        try value.duration(self.gpa, &out, self.map, ticks, at);
        return self.a().dupe(u8, out.items);
    }

    fn intJson(self: *Ctx, v: i64) Error![]const u8 {
        return std.fmt.allocPrint(self.a(), "{d}", .{v});
    }

    // ---- the operations ----

    fn insert(self: *Ctx, x: Op.Insert) Error!void {
        if (x.what.isChild()) return self.insertChild(x);
        return self.insertRoot(x.what);
    }

    /// A child goes in at the index that keeps the lane's EXISTING order
    /// (plan 07's risk note: the plan never reorders a document it did
    /// not write), which for a sorted lane is the sorted index.
    fn insertChild(self: *Ctx, x: Op.Insert) Error!void {
        const name = x.lane orelse {
            try self.b.refuse(.edit_range_empty, .{ .start = 0, .end = 0 }, "a {s} goes into a lane, and none was named", .{x.what.head()});
            return;
        };
        const li = self.laneByName(name) orelse {
            try self.b.refuse(.edit_range_empty, .{ .start = 0, .end = 0 }, "no lane is named {s}", .{name});
            return;
        };
        const lane = self.d.lanes[li];
        if (lane.binding != null) {
            try self.b.refuse(.edit_target_bound, lane.span, "this lane's content lives in its anchor's file; inline it first", .{});
            return;
        }
        const lane_where = (try self.where(lane.span)) orelse return;
        const kids = (try self.children(li)) orelse return;

        const at = switch (x.what) {
            .note => |n| n.at,
            .keyframe => |k| k.at,
            .clip => |c| c.at,
            else => unreachable,
        };
        var index: u32 = @intCast(kids.len);
        for (kids, 0..) |kid, i| {
            if (kid.at > at) {
                index = @intCast(i);
                break;
            }
        }

        if (x.what == .note) {
            const n = x.what.note;
            if (self.overlapping(li, n.key, n.at, n.dur, null)) |span| {
                try self.b.refuse(
                    .edit_overlap,
                    span,
                    "a note on key {d} already sounds there",
                    .{n.key},
                );
                return;
            }
        }

        var form = try self.newForm(x.what);
        defer form.deinit();
        try self.b.insertPositional(lane_where.site, index, try form.done());
    }

    /// A root goes in after the last root of the same head, which is
    /// where a reader expects it and which keeps the document's own
    /// grouping.
    fn insertRoot(self: *Ctx, what: Op.New) Error!void {
        var form = try self.newForm(what);
        defer form.deinit();
        try self.insertRootAfterHead(what.head(), try form.done());
    }

    /// `insert_root` after the last root spelling `head`, or an append
    /// when the document has none.
    fn insertRootAfterHead(self: *Ctx, head: []const u8, json: []const u8) Error!void {
        var after: ?u32 = null;
        for (self.tree.root, 0..) |root, i| {
            if (self.tree.tagOf(root) != .form) continue;
            if (std.mem.eql(u8, self.tree.formHeader(root).head, head)) after = @intCast(i);
        }
        const count: u32 = @intCast(self.tree.root.len);
        // An append past the last root is the omitted-index spelling
        // (§11.3), and it lands where a re-print would put it — past the
        // document's trailing comments rather than in front of them.
        const index: ?u32 = if (after) |i| blk: {
            const want = i + 1 + self.root_inserts;
            break :blk if (want >= count + self.root_inserts) null else want;
        } else null;
        self.root_inserts += 1;
        try self.b.insertRoot(index, json);
    }

    /// The form an `insert` builds, key by key in the schema's own order.
    fn newForm(self: *Ctx, what: Op.New) Error!value.Form {
        var f = try value.Form.init(self.gpa, what.head());
        errdefer f.deinit();
        switch (what) {
            .note => |n| {
                try f.position("at", self.map, n.at);
                try f.duration("dur", self.map, n.dur, n.at);
                try f.integer("key", n.key);
                if (n.vel) |v| try f.integer("vel", v);
                if (n.ch) |c| try f.integer("ch", @as(i64, c) + 1);
                if (n.off_vel) |v| try f.integer("off-vel", v);
            },
            .keyframe => |k| {
                try f.position("at", self.map, k.at);
                try f.components("value", k.value, k.ncomp);
                if (k.ease) |text| {
                    var out: value.Buf = .empty;
                    defer out.deinit(self.gpa);
                    if (try value.source(self.gpa, &out, text)) try f.raw("ease", out.items);
                }
            },
            .clip => |c| {
                try f.position("at", self.map, c.at);
                try f.symbol("phrase", c.phrase);
                if (c.repeat) |r| try f.integer("repeat", r);
                if (c.offset) |o| try f.duration("offset", self.map, o, c.at);
                if (c.length) |l| try f.duration("length", self.map, l, c.at);
                if (c.transpose) |t| try f.integer("transpose", t);
            },
            .section => |s| {
                try f.symbol("name", s.name);
                try f.position("at", self.map, s.at);
                try f.duration("dur", self.map, s.dur, s.at);
            },
            .cue => |c| {
                try f.string("name", c.name);
                try f.position("at", self.map, c.at);
            },
            .lane => |l| {
                try f.symbol("name", l.name);
                try f.symbol("kind", @tagName(l.kind));
                if (l.target) |t| try f.symbol("target", t);
            },
            .phrase => |p| {
                try f.symbol("name", p.name);
                try f.duration("length", self.map, p.length, 0);
                var kids: std.ArrayList([]const u8) = .empty;
                defer {
                    for (kids.items) |k| self.gpa.free(k);
                    kids.deinit(self.gpa);
                }
                for (p.lanes) |name| {
                    var inner = try value.Form.init(self.gpa, "lane");
                    defer inner.deinit();
                    try inner.symbol("name", name);
                    try kids.append(self.gpa, try self.gpa.dupe(u8, try inner.done()));
                }
                if (kids.items.len > 0) try f.children(kids.items);
            },
        }
        return f;
    }

    fn remove(self: *Ctx, sel: Select.Select) Error!void {
        var r = (try self.targets(sel)) orelse return;
        defer r.deinit();
        for (r.targets) |t| {
            const w = (try self.where(t.span)) orelse return;
            if (w.parent) |parent| {
                try self.b.removePositional(parent, w.slot);
            } else {
                try self.b.removeRoot(w.slot);
            }
        }
    }

    fn retime(self: *Ctx, x: Op.Retime) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();

        var moves: std.ArrayList(Move) = .empty;
        defer moves.deinit(self.gpa);
        for (r.targets) |t| {
            const to = if (x.delta) |delta| t.at +| delta else (x.to orelse t.at);
            try moves.append(self.gpa, .{ .t = t, .to = @max(0, to) });
        }
        try self.moveAll(moves.items);
    }

    /// One target and where it goes, plus the duration an operation
    /// wants on it (a `dur-too` quantize) or null for the document's
    /// own.
    const Move = struct {
        t: Select.Target,
        to: i64,
        dur: ?i64 = null,
    };

    /// Plan a whole batch of moves.
    ///
    /// The batch and not one target at a time, because `apply` runs
    /// EVERY removal before ANY insert: an index computed against the
    /// untouched document names the wrong slot — or no slot at all — by
    /// the time the insert is reached. So a lane's moves are planned
    /// together, against a running model of the document the plan
    /// produces, exactly as `duplicate` builds one.
    ///
    /// Within a lane the rule is plan 07's: `set_keyword :at` wherever
    /// the positional order the document already has still holds, so the
    /// node keeps its comments, and a remove + insert only for the
    /// children that no longer fit where they sit. A whole-lane drag
    /// therefore touches no structure at all.
    fn moveAll(self: *Ctx, moves: []const Move) Error!void {
        if (moves.len == 0) return;
        if (try self.refuseOverlaps(moves)) return;

        // Targets arrive in the plan's order — lanes in document order,
        // then tick — so one lane's moves are contiguous and the roots
        // come last.
        var i: usize = 0;
        while (i < moves.len) {
            const li = moves[i].t.lane orelse {
                try self.moveRoot(moves[i]);
                i += 1;
                continue;
            };
            var j = i + 1;
            while (j < moves.len and moves[j].t.lane != null and moves[j].t.lane.? == li) j += 1;
            try self.moveInLane(li, moves[i..j]);
            i = j;
        }
    }

    /// A root is not sorted by anything: the document's order is the
    /// author's, and a retime never reorders roots.
    fn moveRoot(self: *Ctx, m: Move) Error!void {
        const w = (try self.where(m.t.span)) orelse return;
        for (try self.writesFor(m)) |write| {
            try self.b.setKeyword(w.site, write.key, write.json.?);
        }
    }

    /// One lane's whole batch.
    fn moveInLane(self: *Ctx, li: u32, moves: []const Move) Error!void {
        const kids = (try self.children(li)) orelse return;
        if (kids.len == 0) return;
        const arena = self.a();

        // Where each child ends up, and which move put it there.
        const finals = try arena.alloc(i64, kids.len);
        const by_kid = try arena.alloc(?usize, kids.len);
        for (kids, finals, by_kid) |kid, *f, *m| {
            f.* = kid.at;
            m.* = null;
        }
        for (moves, 0..) |m, mi| {
            const w = (try self.where(m.t.span)) orelse return;
            for (kids, 0..) |kid, k| {
                if (kid.slot != w.slot) continue;
                finals[k] = m.to;
                by_kid[k] = mi;
            }
        }

        // Who keeps its slot. An UNMOVED child always does — the plan
        // never reorders a document it did not write (plan 07's risk
        // note) — and a moved one does when it still sits between the
        // last child that kept its slot and the next child that will.
        const keep = try arena.alloc(bool, kids.len);
        var last: i64 = std.math.minInt(i64);
        for (0..kids.len) |k| {
            if (by_kid[k] == null) {
                keep[k] = true;
                last = finals[k];
                continue;
            }
            var next: i64 = std.math.maxInt(i64);
            for (k + 1..kids.len) |n| {
                if (by_kid[n] != null) continue;
                next = finals[n];
                break;
            }
            keep[k] = finals[k] >= last and finals[k] <= next;
            if (keep[k]) last = finals[k];
        }

        // The ones that stay, in slot order.
        for (0..kids.len) |k| {
            const mi = by_kid[k] orelse continue;
            if (!keep[k]) continue;
            const w = (try self.where(moves[mi].t.span)) orelse return;
            for (try self.writesFor(moves[mi])) |write| {
                try self.b.setKeyword(w.site, write.key, write.json.?);
            }
        }

        // The ones that move: every removal, then every insert against
        // the list the removals leave behind.
        var rest: std.ArrayList(i64) = .empty;
        defer rest.deinit(self.gpa);
        var relocated: std.ArrayList(usize) = .empty;
        defer relocated.deinit(self.gpa);
        var parent: ?locate.Site = null;

        for (0..kids.len) |k| {
            if (by_kid[k] == null or keep[k]) {
                try rest.append(self.gpa, finals[k]);
                continue;
            }
            const m = moves[by_kid[k].?];
            const w = (try self.where(m.t.span)) orelse return;
            parent = w.parent orelse {
                try self.refuseUnaddressable(m.t.span);
                return;
            };
            try self.b.removePositional(parent.?, w.slot);
            try relocated.append(self.gpa, k);
        }
        if (relocated.items.len == 0) return;

        // Ascending destination, so every index is a slot in the list as
        // it stands when that insert is reached.
        std.sort.insertion(usize, relocated.items, @as([]const i64, finals), byFinal);
        for (relocated.items) |k| {
            const m = moves[by_kid[k].?];
            const node = self.nodeOf(m.t.span) orelse {
                try self.refuseUnaddressable(m.t.span);
                return;
            };
            var out: value.Buf = .empty;
            defer out.deinit(self.gpa);
            try value.form(self.gpa, &out, self.tree, node, try self.writesFor(m));

            var index: u32 = @intCast(rest.items.len);
            for (rest.items, 0..) |at, n| {
                if (at > m.to) {
                    index = @intCast(n);
                    break;
                }
            }
            try rest.insert(self.gpa, index, m.to);
            try self.b.insertPositional(parent.?, index, out.items);
        }
    }

    /// The keys whose value is a DURATION measured from its form's own
    /// `:at` — the ones a move can silently change the meaning of.
    const duration_keys = [_][]const u8{ "dur", "offset", "length" };

    /// Everything a move writes on its form: the new `:at`, the duration
    /// the operation asked for, and the durations whose SPELLING has to
    /// follow the anchor.
    ///
    /// ONE list, so the in-place branch and the rebuild write exactly the
    /// same thing and neither writes a key twice: `:dur 1bar` on a note
    /// at a bar line is four quarters and the same four bytes one quarter
    /// later are three, so a duration is re-read AT ITS NEW ANCHOR and
    /// written out again only when it would come back a different tick.
    fn writesFor(self: *Ctx, m: Move) Error![]value.Override {
        var out: std.ArrayList(value.Override) = .empty;
        const arena = self.a();
        if (m.to != m.t.at) {
            try out.append(arena, .{ .key = "at", .json = try self.positionJson(m.to) });
        }
        const asked = self.durKeyOf(m.t);
        for (duration_keys) |key| {
            if (m.dur) |d| {
                if (asked != null and std.mem.eql(u8, asked.?, key) and d != m.t.dur) {
                    try out.append(arena, .{ .key = key, .json = try self.durationJson(@max(0, d), m.to) });
                    continue;
                }
            }
            // An anchor that did not move cannot change what a duration
            // spelled against it means.
            if (m.to == m.t.at) continue;
            if (try self.driftJson(m.t, key, m.to)) |json| {
                try out.append(arena, .{ .key = key, .json = json });
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// Which key says how long this target lasts — and only when the
    /// document SPELLS it: a clip's window is the phrase's length times
    /// `:repeat` unless it says otherwise, and writing that out would fix
    /// a number the document left to the phrase.
    fn durKeyOf(self: *Ctx, t: Select.Target) ?[]const u8 {
        return switch (t.kind) {
            .note, .section => "dur",
            .clip => if (self.keyText(t.span, "length") != null) "length" else null,
            .keyframe, .cue => null,
        };
    }

    /// Refuse a batch that would sound two notes on one key at once.
    ///
    /// The whole batch at once, because a plan collides with ITSELF: two
    /// notes quantizing onto one line overlap each other and neither
    /// overlaps anything in the document as it stands. Two notes that
    /// already overlap before the edit are the document's own
    /// `note_overlap` and not this operation's business.
    ///
    /// Answers whether it refused.
    fn refuseOverlaps(self: *Ctx, moves: []const Move) Error!bool {
        var seen: std.ArrayList(u32) = .empty;
        defer seen.deinit(self.gpa);
        for (moves) |m| {
            if (m.t.kind != .note) continue;
            const li = m.t.lane orelse continue;
            var already = false;
            for (seen.items) |one| {
                if (one == li) already = true;
            }
            if (already) continue;
            try seen.append(self.gpa, li);
            if (try self.refuseLaneOverlaps(li, moves)) return true;
        }
        return false;
    }

    fn refuseLaneOverlaps(self: *Ctx, li: u32, moves: []const Move) Error!bool {
        const notes = self.d.lanes[li].notes;
        if (notes.len == 0) return false;
        const arena = self.a();
        const at = try arena.alloc(i64, notes.len);
        const dur = try arena.alloc(i64, notes.len);
        const moving = try arena.alloc(bool, notes.len);
        for (notes, at, dur, moving) |n, *x, *d, *mv| {
            x.* = n.at;
            d.* = n.dur;
            mv.* = false;
        }
        for (moves) |m| {
            if (m.t.kind != .note) continue;
            if ((m.t.lane orelse continue) != li or m.t.item >= notes.len) continue;
            at[m.t.item] = m.to;
            dur[m.t.item] = m.dur orelse notes[m.t.item].dur;
            moving[m.t.item] = true;
        }
        for (notes, 0..) |x, i| {
            if (dur[i] <= 0) continue;
            for (notes[i + 1 ..], i + 1..) |y, j| {
                if (y.key != x.key or dur[j] <= 0) continue;
                if (!moving[i] and !moving[j]) continue;
                if (at[i] >= at[j] +| dur[j] or at[j] >= at[i] +| dur[i]) continue;
                // Name the one that is NOT moving, which is the obstacle
                // a musician sees; when both move, the later of the two.
                const obstacle = if (!moving[j]) y.span else if (!moving[i]) x.span else y.span;
                try self.b.refuse(
                    .edit_overlap,
                    obstacle,
                    "this edit would sound two notes on key {d} at once",
                    .{x.key},
                );
                return true;
            }
        }
        return false;
    }

    /// `key`'s value re-spelled for an anchor at `to`, or null when the
    /// bytes already there still mean the same tick.
    fn driftJson(self: *Ctx, t: Select.Target, key: []const u8, to: i64) Error!?[]const u8 {
        const text = self.keyText(t.span, key) orelse return null;
        const lit = switch (Pos.parse(text)) {
            .ok => |l| l,
            .err => return null,
        };
        const was = switch (self.map.durationTicks(lit, t.at) catch return null) {
            .tick => |v| v,
            .err => return null,
        };
        const now = switch (self.map.durationTicks(lit, to) catch return null) {
            .tick => |v| v,
            .err => return null,
        };
        if (was == now) return null;
        return try self.durationJson(was, to);
    }

    fn revalue(self: *Ctx, x: Op.Revalue) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();
        var out: value.Buf = .empty;
        defer out.deinit(self.gpa);
        try value.components(self.gpa, &out, x.value, x.ncomp);
        for (r.targets) |t| {
            if (t.kind != .keyframe) continue;
            const w = (try self.where(t.span)) orelse return;
            try self.b.setKeyword(w.site, "value", out.items);
        }
    }

    fn ease(self: *Ctx, x: Op.Ease) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();
        var out: value.Buf = .empty;
        defer out.deinit(self.gpa);
        if (!try value.source(self.gpa, &out, x.ease)) {
            try self.b.refuse(
                .sjon_diagnostic,
                r.targets[0].span,
                "the easing {s} is not one SJON value",
                .{x.ease},
            );
            return;
        }
        for (r.targets) |t| {
            if (t.kind != .keyframe) continue;
            const w = (try self.where(t.span)) orelse return;
            try self.b.setKeyword(w.site, "ease", out.items);
        }
    }

    fn resize(self: *Ctx, x: Op.Resize) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();
        for (r.targets) |t| {
            const w = (try self.where(t.span)) orelse return;
            switch (t.kind) {
                .note, .section => {
                    const dur = x.dur orelse continue;
                    try self.b.setKeyword(w.site, "dur", try self.durationJson(@max(0, dur), t.at));
                },
                .clip => {
                    if (x.repeat) |rep| try self.b.setKeyword(w.site, "repeat", try self.intJson(rep));
                    // A clip's own length is its playback window, which
                    // is what `:dur` means for the one form that spells
                    // it with another key.
                    if (x.dur) |dur| try self.b.setKeyword(w.site, "length", try self.durationJson(@max(0, dur), t.at));
                },
                // A keyframe and a cue are points: there is no end to
                // move.
                .keyframe, .cue => {},
            }
        }
    }

    fn velocity(self: *Ctx, x: Op.Velocity) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();
        for (r.targets) |t| {
            if (t.kind != .note) continue;
            const w = (try self.where(t.span)) orelse return;
            try self.b.setKeyword(w.site, "vel", try self.intJson(x.vel));
        }
    }

    fn transpose(self: *Ctx, x: Op.Transpose) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();
        var clamped: u32 = 0;
        for (r.targets) |t| {
            const w = (try self.where(t.span)) orelse return;
            switch (t.kind) {
                .note => {
                    const want = @as(i32, t.key orelse 0) + x.semitones;
                    const key = std.math.clamp(want, 0, 127);
                    if (key != want) clamped += 1;
                    try self.b.setKeyword(w.site, "key", try self.intJson(key));
                },
                .clip => {
                    const clip = self.d.lanes[t.lane.?].clips[t.item];
                    const want = @as(i32, clip.transpose) + x.semitones;
                    const semis = std.math.clamp(want, -120, 120);
                    if (semis != want) clamped += 1;
                    try self.b.setKeyword(w.site, "transpose", try self.intJson(semis));
                },
                else => {},
            }
        }
        if (clamped > 0) {
            self.b.summary.inexact = clamped;
            try self.b.note(
                .edit_inexact,
                .warning,
                r.targets[0].span,
                "{d} target(s) clamped to the key range",
                .{clamped},
            );
        }
    }

    // ---- snapping ----

    /// Every selected onset onto the grid, a `strength` of the way.
    ///
    /// `dur-too` moves the END onto the grid as well, and rides along in
    /// the move so it lands whether the onset stays where it is or has
    /// to be re-inserted somewhere else.
    fn quantize(self: *Ctx, x: Op.Quantize) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();

        var moves: std.ArrayList(Move) = .empty;
        defer moves.deinit(self.gpa);
        for (r.targets) |t| {
            const to = ops_quantize.quantized(self.map, t.at, x.grid, x.strength, x.swing);
            var dur: ?i64 = null;
            if (x.dur_too and t.dur > 0) {
                const end = ops_quantize.quantized(self.map, t.at +| t.dur, x.grid, x.strength, x.swing);
                dur = @max(0, end - to);
            }
            try moves.append(self.gpa, .{ .t = t, .to = to, .dur = dur });
        }
        try self.moveAll(moves.items);
    }

    /// By ticks, or by counted steps of a grid.
    fn nudge(self: *Ctx, x: Op.Nudge) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();

        var moves: std.ArrayList(Move) = .empty;
        defer moves.deinit(self.gpa);
        for (r.targets) |t| {
            try moves.append(self.gpa, .{
                .t = t,
                .to = @max(0, ops_quantize.nudged(self.map, t.at, x.delta)),
            });
        }
        try self.moveAll(moves.items);
    }

    // ---- the clip operations ----

    /// Split every selected clip at `at`: the left keeps its bytes and
    /// gains a `:length` up to the split, the right starts there with
    /// `:offset` advanced and the rest of the window.
    ///
    /// Plan 07 spells this as a `replace` by two clips. One of the two IS
    /// the clip that is already there, and a `set_keyword` leaves its
    /// comments and its spelling alone where a rebuild would not, so the
    /// left half is edited in place and only the right half is new — the
    /// same mitigation the risk note asks of `retime`.
    fn split(self: *Ctx, x: Op.Split) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();

        var made: u32 = 0;
        var lane: ?u32 = null;
        for (r.targets) |t| {
            if (t.kind != .clip) continue;
            // The split has to fall INSIDE the window: on either edge it
            // would make an empty clip, which is not a split.
            if (x.at <= t.at or x.at >= t.at +| t.dur) continue;
            if (lane == null or lane.? != t.lane.?) {
                lane = t.lane.?;
                made = 0;
            }

            const w = (try self.where(t.span)) orelse return;
            const parent = w.parent orelse {
                try self.refuseUnaddressable(t.span);
                return;
            };
            const node = self.nodeOf(t.span) orelse {
                try self.refuseUnaddressable(t.span);
                return;
            };
            const clip = self.d.lanes[t.lane.?].clips[t.item];
            const left = x.at - t.at;

            try self.b.setKeyword(w.site, "length", try self.durationJson(left, t.at));

            var out: value.Buf = .empty;
            defer out.deinit(self.gpa);
            try value.form(self.gpa, &out, self.tree, node, &.{
                .{ .key = "at", .json = try self.positionJson(x.at) },
                .{ .key = "offset", .json = try self.durationJson(clip.offset + left, x.at) },
                .{ .key = "length", .json = try self.durationJson(t.dur - left, x.at) },
            });
            try self.b.insertPositional(parent, w.slot + 1 + made, out.items);
            made += 1;
        }
        if (made == 0 and !self.b.summary.refused) {
            try self.b.refuse(
                .edit_range_empty,
                r.targets[0].span,
                "no selected clip has {d} inside its window",
                .{x.at},
            );
        }
    }

    /// Merge two adjacent clips of one phrase back into one window.
    ///
    /// The selection has to name exactly that. Anything else is a
    /// selection this operation has nothing to do with, which is
    /// `edit_range_empty` in the same sense an empty one is.
    fn merge(self: *Ctx, x: Op.Merge) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();

        var left: ?Select.Target = null;
        var right: ?Select.Target = null;
        for (r.targets) |t| {
            if (t.kind != .clip) continue;
            if (left == null) {
                left = t;
            } else if (right == null) {
                right = t;
            }
        }
        const a_t = left orelse {
            try self.b.refuse(.edit_range_empty, r.targets[0].span, "merge wants two clips and the selection named none", .{});
            return;
        };
        const b_t = right orelse {
            try self.b.refuse(.edit_range_empty, a_t.span, "merge wants two clips and the selection named one", .{});
            return;
        };

        const aw = (try self.where(a_t.span)) orelse return;
        const bw = (try self.where(b_t.span)) orelse return;
        const lane = self.d.lanes[a_t.lane.?];
        const ac = lane.clips[a_t.item];
        const bc = self.d.lanes[b_t.lane.?].clips[b_t.item];

        const adjacent = a_t.lane.? == b_t.lane.? and
            bw.slot == aw.slot + 1 and
            std.mem.eql(u8, ac.phrase, bc.phrase) and
            a_t.at +| a_t.dur == b_t.at;
        if (!adjacent) {
            try self.b.refuse(
                .edit_range_empty,
                b_t.span,
                "these two clips are not adjacent windows of one phrase",
                .{},
            );
            return;
        }

        const parent = bw.parent orelse {
            try self.refuseUnaddressable(b_t.span);
            return;
        };
        try self.b.setKeyword(aw.site, "length", try self.durationJson(b_t.at +| b_t.dur - a_t.at, a_t.at));
        try self.b.removePositional(parent, bw.slot);
    }

    /// Copies of the selection, retimed — inserts and nothing else.
    fn duplicate(self: *Ctx, x: Op.Duplicate) Error!void {
        var r = (try self.targets(x.sel)) orelse return;
        defer r.deinit();

        // The lane the simulation below is following, and the positions
        // its children will have once every insert has landed: an insert
        // index is a slot in the document the plan PRODUCES.
        var lane: ?u32 = null;
        var sim: std.ArrayList(i64) = .empty;
        defer sim.deinit(self.gpa);

        for (r.targets) |t| {
            const to = @max(0, if (x.delta) |delta| t.at +| delta else (x.to orelse t.at));
            if (t.kind == .note) {
                // A copy is a new note, so it overlaps its own original
                // too — nothing is ignored here.
                if (self.overlapping(t.lane.?, t.key.?, to, t.dur, null)) |span| {
                    try self.b.refuse(
                        .edit_overlap,
                        span,
                        "the copy at {d} would sound over a note on key {d}",
                        .{ to, t.key.? },
                    );
                    return;
                }
            }
            const node = self.nodeOf(t.span) orelse {
                try self.refuseUnaddressable(t.span);
                return;
            };

            var overrides: std.ArrayList(value.Override) = .empty;
            defer overrides.deinit(self.gpa);
            try overrides.append(self.gpa, .{ .key = "at", .json = try self.positionJson(to) });
            for (duration_keys) |key| {
                if (try self.driftJson(t, key, to)) |json| {
                    try overrides.append(self.gpa, .{ .key = key, .json = json });
                }
            }
            var out: value.Buf = .empty;
            defer out.deinit(self.gpa);
            try value.form(self.gpa, &out, self.tree, node, overrides.items);

            const li = t.lane orelse {
                // A section or a cue is a root, and a copy of one goes
                // where a new one would.
                try self.insertRootAfterHead(@tagName(t.kind), out.items);
                continue;
            };
            if (lane == null or lane.? != li) {
                lane = li;
                sim.clearRetainingCapacity();
                const kids = (try self.children(li)) orelse return;
                for (kids) |kid| try sim.append(self.gpa, kid.at);
            }
            const w = (try self.where(t.span)) orelse return;
            const parent = w.parent orelse {
                try self.refuseUnaddressable(t.span);
                return;
            };

            var index: u32 = @intCast(sim.items.len);
            for (sim.items, 0..) |at, i| {
                if (at > to) {
                    index = @intCast(i);
                    break;
                }
            }
            try sim.insert(self.gpa, index, to);
            try self.b.insertPositional(parent, index, out.items);
        }
    }

    // ---- the range operations ----

    /// Scale `[from, to)` by `p/q` and shift what follows by the growth.
    ///
    /// One mapping does all of it: a tick before the range stays, a tick
    /// inside it scales from the range's start, and a tick after it moves
    /// by the range's growth. Every `:at` goes through that mapping and
    /// every `:dur` is the distance between its form's two mapped ends,
    /// so a note inside the range is scaled, a note that merely REACHES
    /// into it is stretched by what happened inside, and a note after it
    /// only moves.
    ///
    /// The mapping is strictly increasing, so nothing overtakes a
    /// neighbour and every action is a `set_keyword`. A position that
    /// leaves the integer grid is rounded (half to even, so a scaled
    /// document does not drift one way) and counted in `edit_inexact`.
    fn stretch(self: *Ctx, x: Op.Stretch) Error!void {
        if (x.p == 0 or x.q == 0 or x.to <= x.from) {
            try self.b.refuse(
                .edit_range_empty,
                .{ .start = 0, .end = 0 },
                "a stretch wants a non-empty range and a non-zero ratio",
                .{},
            );
            return;
        }
        var inexact: u32 = 0;
        // The range's own growth is not a POSITION: it is how far what
        // follows moves, and rounding it is one fact about the stretch
        // rather than one document position that landed off the grid.
        var growth_rounded: u32 = 0;
        const span = x.to - x.from;
        const growth = scaleTicks(span, x.p, x.q, &growth_rounded) - span;

        var r = try Select.resolve(self.gpa, self.d, .{});
        defer r.deinit();
        if (r.targets.len == 0) {
            try self.b.refuse(.edit_range_empty, .{ .start = 0, .end = 0 }, "the document holds nothing to stretch", .{});
            return;
        }
        self.b.summary.targets = @intCast(r.targets.len);

        for (r.targets) |t| {
            const to = stretched(x, growth, t.at, &inexact);
            const w = (try self.where(t.span)) orelse return;
            if (to != t.at) try self.b.setKeyword(w.site, "at", try self.positionJson(to));

            const key: []const u8 = switch (t.kind) {
                .note, .section => "dur",
                // A window the document does not spell is the phrase's
                // length times `:repeat`, and writing it out would fix a
                // number the document deliberately left to the phrase.
                .clip => "length",
                .keyframe, .cue => continue,
            };
            if (self.keyText(t.span, key) == null) continue;
            const dur = stretched(x, growth, t.at +| t.dur, &inexact) - to;
            if (dur == t.dur) {
                // Unmoved, but its spelling may still have to follow its
                // anchor — `1bar` from a bar line is not `1bar` from a
                // quarter note later.
                if (try self.driftJson(t, key, to)) |json| try self.b.setKeyword(w.site, key, json);
                continue;
            }
            try self.b.setKeyword(w.site, key, try self.durationJson(@max(0, dur), to));
        }

        if (inexact > 0 or growth_rounded > 0) {
            self.b.summary.inexact = inexact;
            try self.b.note(
                .edit_inexact,
                .warning,
                .{ .start = 0, .end = 0 },
                "{d} position(s) rounded onto the grid by {d}/{d}{s}",
                .{
                    inexact,
                    x.p,
                    x.q,
                    if (growth_rounded > 0) "; the range's own growth rounded too" else "",
                },
            );
        }
    }

    // ---- the map operations ----

    /// A tempo point, and — in `wall_clock` mode — the retime that keeps
    /// every later event at the second it was already at.
    fn insertTempo(self: *Ctx, x: Op.InsertTempo) Error!void {
        var points: std.ArrayList(doc.TempoPoint) = .empty;
        defer points.deinit(self.gpa);
        try points.appendSlice(self.gpa, self.d.tempo);
        var at: usize = points.items.len;
        for (points.items, 0..) |p, i| {
            if (p.tick > x.point.tick) {
                at = i;
                break;
            }
        }
        try points.insert(self.gpa, at, x.point);

        if (x.mode == .wall_clock) {
            var after = try TimeMap.derive(self.gpa, points.items, self.d.meter, self.map.length, self.d.end);
            defer after.deinit();

            var moved = try Select.resolve(self.gpa, self.d, .{ .range = .{ x.point.tick + 1, Grid.MAX_TICK } });
            defer moved.deinit();
            self.b.summary.targets = @intCast(moved.targets.len);

            var inexact: u32 = 0;
            var moves: std.ArrayList(Move) = .empty;
            defer moves.deinit(self.gpa);
            for (moved.targets) |t| {
                const seconds = self.map.secondsFromTick(t.at);
                const to = after.map.tickFromSeconds(seconds) catch {
                    inexact += 1;
                    continue;
                };
                if (after.map.secondsFromTick(to) != seconds) inexact += 1;
                try moves.append(self.gpa, .{ .t = t, .to = to });
            }
            try self.moveAll(moves.items);
            if (inexact > 0) {
                self.b.summary.inexact = inexact;
                try self.b.note(
                    .edit_inexact,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "{d} wall-clock position(s) rounded onto the grid",
                    .{inexact},
                );
            }
        }

        var f = try value.Form.init(self.gpa, "tempo-point");
        defer f.deinit();
        try f.position("at", self.map, x.point.tick);
        switch (x.point.tempo) {
            .us => |us| try f.integer("us", us),
            .qpm => |qpm| try f.float("qpm", @floatCast(qpm)),
        }
        try self.insertRootAfterHead("tempo-point", try f.done());
    }

    /// A meter point, and the re-spelling that keeps the document saying
    /// what it said.
    ///
    /// A `bar` or a `b` literal after the change means a different tick
    /// the moment the bars change length, so every literal whose MEANING
    /// would move is written out again from the tick it meant — under the
    /// new map, in the same plan. A `q`, a `t` and an `s` stand: they name
    /// the grid and the clock, neither of which a meter touches.
    fn insertMeter(self: *Ctx, x: Op.InsertMeter) Error!void {
        if (self.map.isBarLine(x.point.tick) == null) {
            try self.b.refuse(
                .edit_off_bar,
                self.lastSpan(.meter),
                "a meter point sits on a bar line of the meter before it; tick {d} does not",
                .{x.point.tick},
            );
            return;
        }

        var points: std.ArrayList(doc.MeterPoint) = .empty;
        defer points.deinit(self.gpa);
        try points.appendSlice(self.gpa, self.d.meter);
        var at: usize = points.items.len;
        for (points.items, 0..) |p, i| {
            if (p.tick > x.point.tick) {
                at = i;
                break;
            }
        }
        try points.insert(self.gpa, at, x.point);

        var after = try TimeMap.derive(self.gpa, self.d.tempo, points.items, self.map.length, self.d.end);
        defer after.deinit();

        for (self.tree.root) |root| {
            if (self.tree.tagOf(root) != .form) continue;
            try self.respellUnder(&after.map, root);
        }

        var f = try value.Form.init(self.gpa, "meter-point");
        defer f.deinit();
        try f.position("at", self.map, x.point.tick);
        try f.raw("sig", try std.fmt.allocPrint(self.a(), "[{d},{d}]", .{ x.point.n, x.point.d }));
        try self.insertRootAfterHead("meter-point", try f.done());
    }

    /// Re-spell every position and duration of `node` (and of its
    /// children) that `after` would read as a different tick.
    fn respellUnder(self: *Ctx, after: *const TimeMap.TimeMap, node: sjon.Ast.NodeIndex) Error!void {
        const hdr = self.tree.formHeader(node);
        const span: Diag.Span = .{ .start = self.tree.spanOf(node).start, .end = self.tree.spanOf(node).end };

        // The anchor every duration on this form is measured from.
        var anchor: i64 = 0;
        if (self.literalOf(node, "at")) |lit| {
            anchor = switch (self.map.tickFromLiteral(lit) catch return) {
                .tick => |t| t,
                .err => 0,
            };
        }

        if (self.literalOf(node, "at")) |lit| {
            const now = switch (after.tickFromLiteral(lit) catch return) {
                .tick => |t| t,
                .err => anchor,
            };
            if (now != anchor) {
                const w = (try self.where(span)) orelse return;
                var out: value.Buf = .empty;
                defer out.deinit(self.gpa);
                try value.position(self.gpa, &out, after, anchor);
                try self.b.setKeyword(w.site, "at", out.items);
            }
        }
        for (duration_keys) |key| {
            const lit = self.literalOf(node, key) orelse continue;
            const was = switch (self.map.durationTicks(lit, anchor) catch continue) {
                .tick => |t| t,
                .err => continue,
            };
            const now = switch (after.durationTicks(lit, anchor) catch continue) {
                .tick => |t| t,
                .err => continue,
            };
            if (was == now) continue;
            const w = (try self.where(span)) orelse return;
            var out: value.Buf = .empty;
            defer out.deinit(self.gpa);
            try value.duration(self.gpa, &out, after, was, anchor);
            try self.b.setKeyword(w.site, key, out.items);
        }

        for (hdr.children) |child| {
            if (self.tree.tagOf(child) != .form) continue;
            try self.respellUnder(after, child);
        }
    }

    /// `key`'s value on `node` as a position literal, or null when the
    /// form has no such key or it is not a number with a unit.
    fn literalOf(self: *Ctx, node: sjon.Ast.NodeIndex, key: []const u8) ?Pos.Literal {
        for (self.tree.formHeader(node).children) |child| {
            if (self.tree.tagOf(child) != .kvpair) continue;
            const kv = self.tree.kvpairHeader(child);
            if (!std.mem.eql(u8, kv.key, key)) continue;
            if (self.tree.tagOf(kv.value) != .number_with_unit) return null;
            const s = self.tree.spanOf(kv.value);
            return switch (Pos.parse(self.tree.source[s.start..s.end])) {
                .ok => |lit| lit,
                .err => null,
            };
        }
        return null;
    }

    /// Where to point a refusal about the tempo or meter map: its last
    /// point, or the start of the document.
    fn lastSpan(self: *Ctx, which: enum { tempo, meter }) Diag.Span {
        return switch (which) {
            .tempo => if (self.d.tempo.len > 0) self.d.tempo[self.d.tempo.len - 1].span else .{ .start = 0, .end = 0 },
            .meter => if (self.d.meter.len > 0) self.d.meter[self.d.meter.len - 1].span else .{ .start = 0, .end = 0 },
        };
    }

    // ---- names ----

    /// One `set_keyword` a rename wants, before they are put in document
    /// order.
    const Write = struct { site: locate.Site, key: []const u8, json: []const u8 };

    /// A name, on the form that owns it and on every cross-ref to it.
    fn rename(self: *Ctx, x: Op.Rename) Error!void {
        var writes: std.ArrayList(Write) = .empty;
        defer writes.deinit(self.gpa);
        const to = try self.symbolJson(x.to);

        switch (x.what) {
            .lane => {
                for (self.d.lanes) |lane| {
                    if (!std.mem.eql(u8, lane.name, x.from)) continue;
                    const w = (try self.where(lane.span)) orelse return;
                    try writes.append(self.gpa, .{ .site = w.site, .key = "name", .json = to });
                    // A clip places the phrase's lane of the SAME name,
                    // so the phrases this lane places follow it.
                    for (lane.clips) |clip| {
                        const phrase = self.d.phraseByName(clip.phrase) orelse continue;
                        for (phrase.lanes) |inner| {
                            if (!std.mem.eql(u8, inner.name, x.from)) continue;
                            const iw = (try self.where(inner.span)) orelse return;
                            try writes.append(self.gpa, .{ .site = iw.site, .key = "name", .json = to });
                        }
                    }
                }
            },
            .section => {
                for (self.d.sections) |s| {
                    if (!std.mem.eql(u8, s.name, x.from)) continue;
                    const w = (try self.where(s.span)) orelse return;
                    try writes.append(self.gpa, .{ .site = w.site, .key = "name", .json = to });
                }
            },
            .phrase => {
                for (self.d.phrases) |p| {
                    if (!std.mem.eql(u8, p.name, x.from)) continue;
                    const w = (try self.where(p.span)) orelse return;
                    try writes.append(self.gpa, .{ .site = w.site, .key = "name", .json = to });
                }
                for (self.d.lanes) |lane| {
                    for (lane.clips) |clip| {
                        if (!std.mem.eql(u8, clip.phrase, x.from)) continue;
                        const w = (try self.where(clip.span)) orelse return;
                        try writes.append(self.gpa, .{ .site = w.site, .key = "phrase", .json = to });
                    }
                }
            },
            .target => {
                // A pacer form that declares this name is not ours to
                // edit, and renaming only our half would break the pair.
                for (self.d.passthrough) |pt| {
                    if (!self.passthroughNames(pt, x.from)) continue;
                    try self.b.refuse(
                        .edit_readonly_passthrough,
                        pt.span,
                        "({s} …) passes through to pacer and names {s}; rename it there",
                        .{ pt.head, x.from },
                    );
                    return;
                }
                for (self.d.lanes) |lane| {
                    if (!std.mem.eql(u8, lane.target, x.from)) continue;
                    const w = (try self.where(lane.span)) orelse return;
                    try writes.append(self.gpa, .{ .site = w.site, .key = "target", .json = to });
                }
            },
            .anchor => {
                for (self.d.anchors) |anchor| {
                    if (!std.mem.eql(u8, anchor.id, x.from)) continue;
                    const w = (try self.where(anchor.span)) orelse return;
                    try writes.append(self.gpa, .{ .site = w.site, .key = "id", .json = to });
                }
                if (self.d.conductor) |cond| {
                    if (std.mem.eql(u8, cond, x.from)) {
                        if (self.timelineSite()) |site| {
                            try writes.append(self.gpa, .{ .site = site, .key = "conductor", .json = to });
                        }
                    }
                }
                for (self.d.lanes) |lane| {
                    const binding = lane.binding orelse continue;
                    if (!std.mem.eql(u8, binding.anchor, x.from)) continue;
                    const w = (try self.where(lane.span)) orelse return;
                    try writes.append(self.gpa, .{ .site = w.site, .key = "from", .json = to });
                }
            },
        }

        if (writes.items.len == 0) {
            try self.b.refuse(
                .edit_range_empty,
                .{ .start = 0, .end = 0 },
                "nothing in this document is a {s} named {s}",
                .{ @tagName(x.what), x.from },
            );
            return;
        }
        // Document order: a rename touches forms all over a document and
        // the order it touches them in is the document's own.
        std.sort.insertion(Write, writes.items, {}, byDocumentOrder);
        for (writes.items) |w| try self.b.setKeyword(w.site, w.key, w.json);
    }

    /// Whether a pass-through pacer form declares `name` — as its
    /// `:name`, its `:id` or its `:target`.
    fn passthroughNames(self: *Ctx, pt: doc.Passthrough, name: []const u8) bool {
        const node = self.nodeOf(pt.span) orelse return false;
        if (self.tree.tagOf(node) != .form) return false;
        for (self.tree.formHeader(node).children) |child| {
            if (self.tree.tagOf(child) != .kvpair) continue;
            const kv = self.tree.kvpairHeader(child);
            const is_name = std.mem.eql(u8, kv.key, "name") or
                std.mem.eql(u8, kv.key, "id") or
                std.mem.eql(u8, kv.key, "target");
            if (!is_name) continue;
            if (self.tree.tagOf(kv.value) != .symbol) continue;
            if (std.mem.eql(u8, self.tree.symbolText(kv.value), name)) return true;
        }
        return false;
    }

    /// The `(timeline …)` root's address — the document's first root, by
    /// plan 02's "once, first".
    fn timelineSite(self: *Ctx) ?locate.Site {
        for (self.tree.root, 0..) |root, i| {
            if (self.tree.tagOf(root) != .form) continue;
            if (!std.mem.eql(u8, self.tree.formHeader(root).head, "timeline")) continue;
            return .{ .root = @intCast(i), .path = &.{} };
        }
        return null;
    }

    fn symbolJson(self: *Ctx, text: []const u8) Error![]const u8 {
        var out: value.Buf = .empty;
        defer out.deinit(self.gpa);
        try value.symbol(self.gpa, &out, text);
        return self.a().dupe(u8, out.items);
    }

    // ---- binding ----

    fn bind(self: *Ctx, x: Op.Bind) Error!void {
        const li = self.laneByName(x.lane) orelse {
            try self.b.refuse(.edit_range_empty, .{ .start = 0, .end = 0 }, "no lane is named {s}", .{x.lane});
            return;
        };
        const lane = self.d.lanes[li];
        // Content has ONE home (plan 04): a lane that carries its own
        // notes cannot also read them from a file.
        if (lane.notes.len + lane.keyframes.len + lane.clips.len > 0) {
            try self.b.refuse(
                .edit_would_duplicate,
                lane.span,
                "this lane carries its own content; binding it would give that content two homes",
                .{},
            );
            return;
        }
        const w = (try self.where(lane.span)) orelse return;
        try self.b.setKeyword(w.site, "from", try self.symbolJson(x.anchor));
        switch (x.address) {
            .smf => |a_| {
                try self.b.setKeyword(w.site, "track", try self.intJson(a_.track));
                try self.b.setKeyword(w.site, "ch", try self.intJson(@as(i64, a_.ch) + 1));
                if (a_.key) |key| try self.b.setKeyword(w.site, "key", try self.intJson(key));
                if (a_.curve) |curve| switch (curve) {
                    .cc => |n| try self.b.setKeyword(w.site, "cc", try self.intJson(n)),
                    .cc14 => |pair| try self.b.setKeyword(
                        w.site,
                        "cc",
                        try std.fmt.allocPrint(self.a(), "[{d},{d}]", .{ pair[0], pair[1] }),
                    ),
                    .bend => try self.b.setKeyword(w.site, "bend", "true"),
                    .pressure => try self.b.setKeyword(w.site, "pressure", "true"),
                    .velocity => try self.b.setKeyword(w.site, "velocity", "true"),
                };
            },
            .it => |a_| {
                try self.b.setKeyword(w.site, "channel", try self.intJson(@as(i64, a_.channel) + 1));
                if (a_.column) |column| try self.b.setKeyword(w.site, "column", try self.symbolJson(@tagName(column)));
                if (a_.fx) |fx| {
                    var out: value.Buf = .empty;
                    defer out.deinit(self.gpa);
                    try value.string(self.gpa, &out, &.{fx});
                    try self.b.setKeyword(w.site, "fx", out.items);
                }
            },
        }
    }

    /// `materialize` belongs to `ops_bound.zig`, which is the front
    /// door every host comes through (`edit.plan`). This entry point
    /// plans NATIVE content, and a lane's native content is exactly what
    /// materialize does not have yet.
    fn materializeElsewhere(self: *Ctx, x: Op.Materialize) Error!void {
        const span = if (self.laneByName(x.lane)) |li| self.d.lanes[li].span else Diag.Span{ .start = 0, .end = 0 };
        try self.b.refuse(
            .sjon_diagnostic,
            span,
            "materialize reads an anchor's events; plan it through edit.plan, which routes it to ops_bound",
            .{},
        );
    }

    fn unbind(self: *Ctx, x: Op.Unbind) Error!void {
        const li = self.laneByName(x.lane) orelse {
            try self.b.refuse(.edit_range_empty, .{ .start = 0, .end = 0 }, "no lane is named {s}", .{x.lane});
            return;
        };
        const lane = self.d.lanes[li];
        if (lane.binding == null) {
            try self.b.refuse(.edit_range_empty, lane.span, "this lane is not bound", .{});
            return;
        }
        if (lane.notes.len + lane.keyframes.len + lane.clips.len > 0) {
            try self.b.refuse(
                .edit_would_duplicate,
                lane.span,
                "this lane carries content beside its binding",
                .{},
            );
            return;
        }
        const w = (try self.where(lane.span)) orelse return;
        try self.b.removeKeyword(w.site, "from");
        // Only the keys the document actually wrote: a plan says what it
        // changes and nothing else.
        for (address_keys) |key| {
            if (self.keyText(lane.span, key) == null) continue;
            try self.b.removeKeyword(w.site, key);
        }
    }
};

/// The keys an address can put on a lane, in the order the schema
/// declares them — the set `unbind` takes off again, and the set
/// `ops_bound.materialize` takes off with it. Shared so the two cannot
/// drift apart into two answers about one lane.
pub const address_keys = [_][]const u8{ "track", "ch", "key", "cc", "bend", "pressure", "velocity", "channel", "column", "fx" };

fn bySlot(_: void, x: Child, y: Child) bool {
    return x.slot < y.slot;
}

/// Two children of one lane by where they are GOING — the order a batch
/// of inserts has to land in.
fn byFinal(finals: []const i64, x: usize, y: usize) bool {
    return finals[x] < finals[y];
}

fn byDocumentOrder(_: void, x: Ctx.Write, y: Ctx.Write) bool {
    return locate.Site.order(x.site, y.site) == .lt;
}

/// Where a stretch puts one tick: before the range it stays, inside it
/// it scales from the range's start, after it it moves by the growth.
fn stretched(x: Op.Stretch, growth: i64, tick: i64, inexact: *u32) i64 {
    if (tick < x.from) return tick;
    if (tick >= x.to) return tick +| growth;
    return x.from + scaleTicks(tick - x.from, x.p, x.q, inexact);
}

/// `n · p / q`, rounded to NEAREST with ties to EVEN, counting the
/// roundings.
///
/// Ties to even for `Pos.tickFromQuarters`' reason: a scaled document
/// must not drift in one direction when it is scaled back, and every
/// other rounding in this repo that has a choice makes the same one. The
/// product is taken in `i128`, so a tick near the grid ceiling times a
/// large numerator cannot wrap.
fn scaleTicks(n: i64, p: u32, q: u32, inexact: *u32) i64 {
    if (q == 0) return n;
    const num = @as(i128, n) * @as(i128, p);
    const den = @as(i128, q);
    const quo = @divFloor(num, den);
    const rem = num - quo * den;
    if (rem == 0) return @intCast(quo);
    inexact.* += 1;
    const twice = rem * 2;
    const up = if (twice > den) true else if (twice < den) false else @rem(quo, 2) != 0;
    return @intCast(if (up) quo + 1 else quo);
}

// ---------------------------------------------------------------------------

const test_support = @import("test_support.zig");
const apply = @import("apply.zig");

const TPQ = Grid.TPQ;

/// Plan `op` over the native fixture, pin the actions as text, and pin
/// the document the plan produces, byte for byte.
fn expectPlan(op: Op.Op, want_actions: []const u8, want_text: []const u8) !void {
    return expectPlanOn(test_support.native, op, want_actions, want_text);
}

fn expectPlanOn(source: [:0]const u8, op: Op.Op, want_actions: []const u8, want_text: []const u8) !void {
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

/// One region of the fixture, and what the edit makes of it.
const Region = struct { from: []const u8, to: []const u8 };

/// The fixture with `regions` replaced — the expected document, spelled
/// as the edit rather than as a whole second copy. Each `from` must
/// occur exactly once, so a test cannot quietly pin the wrong one.
fn edited(gpa: std.mem.Allocator, regions: []const Region) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, test_support.native);
    for (regions) |r| {
        const at = std.mem.indexOf(u8, out.items, r.from) orelse return error.NoSuchRegion;
        if (std.mem.indexOf(u8, out.items[at + r.from.len ..], r.from) != null) return error.AmbiguousRegion;
        try out.replaceRange(gpa, at, r.from.len, r.to);
    }
    return out.toOwnedSlice(gpa);
}

fn expectEdit(op: Op.Op, want_actions: []const u8, regions: []const Region) !void {
    const gpa = testing.allocator;
    const want = try edited(gpa, regions);
    defer gpa.free(want);
    try expectPlan(op, want_actions, want);
}

test "ops: insert a note at the sorted index of its lane" {
    try expectEdit(
        .{ .insert = .{ .lane = "flash", .what = .{ .note = .{
            .at = 3 * TPQ,
            .dur = @divExact(TPQ, 2),
            .key = 40,
            .vel = 100,
        } } } },
        \\[
        \\{"op":"insert_positional","root":6,"path":[],"index":3,"value":{"$form":"note","at":{"$num":[3,"q"]},"dur":{"$num":[0.5,"q"]},"key":40,"vel":100}}
        \\]
        \\
    ,
        &.{.{
            .from = "  (clip :at 4q :phrase fill :repeat 2))",
            .to = "  (note :at 3q :dur 0.5q :key 40 :vel 100)\n  (clip :at 4q :phrase fill :repeat 2))",
        }},
    );
}

test "ops: remove takes its targets right to left and leaves the lane" {
    try expectEdit(
        .{ .remove = .{ .lanes = &.{"flash"}, .kinds = .notes, .range = .{ 0, 2 * TPQ } } },
        \\[
        \\{"op":"remove_positional","root":6,"path":[],"index":0},
        \\{"op":"remove_positional","root":6,"path":[],"index":1}
        \\]
        \\
    ,
        &.{.{
            .from = "  ; the downbeat\n  (note :at 0q :dur 0.5q :key 36 :vel 110)\n  (note :at 1q :dur 0.5q :key 60 :vel 90)\n",
            .to = "",
        }},
    );
}

test "ops: retime keeps the sorted order, so the node keeps its comments" {
    try expectEdit(
        .{ .retime = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .notes, .range = .{ 0, 1 } },
            .delta = @divExact(TPQ, 4),
        } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[0],"key":"at","value":{"$num":[0.25,"q"]}}
        \\]
        \\
    ,
        &.{.{
            .from = "(note :at 0q :dur 0.5q :key 36 :vel 110)",
            .to = "(note :at 0.25q :dur 0.5q :key 36 :vel 110)",
        }},
    );
}

test "ops: retime past a neighbour is a remove and an insert at the new index" {
    try expectEdit(
        .{ .retime = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .notes, .range = .{ 0, 1 } },
            .to = 3 * TPQ,
        } },
        \\[
        \\{"op":"remove_positional","root":6,"path":[],"index":0},
        \\{"op":"insert_positional","root":6,"path":[],"index":2,"value":{"$form":"note","at":{"$num":[3,"q"]},"dur":{"$num":[0.5,"q"]},"key":36,"vel":110}}
        \\]
        \\
    ,
        &.{
            // The moved node leaves with the comment that led it — the
            // JSON bridge carries no trivia, so a move that has to be a
            // remove and an insert cannot take it along (plan 07's risk).
            .{
                .from = "  ; the downbeat\n  (note :at 0q :dur 0.5q :key 36 :vel 110)\n",
                .to = "",
            },
            .{
                .from = "  (clip :at 4q",
                .to = "  (note :at 3q :dur 0.5q :key 36 :vel 110)\n  (clip :at 4q",
            },
        },
    );
}

test "ops: revalue and ease write a keyframe's two keys" {
    try expectEdit(
        .{ .revalue = .{
            .sel = .{ .lanes = &.{"glow"}, .kinds = .keyframes, .range = .{ 0, 1 } },
            .value = .{ 0.1, 0.2, 0.3, 0 },
            .ncomp = 3,
        } },
        \\[
        \\{"op":"set_keyword","root":7,"path":[0],"key":"value","value":[0.1,0.2,0.3]}
        \\]
        \\
    ,
        &.{.{
            .from = "(keyframe :at 0q :value 0.2 :ease hold)",
            .to = "(keyframe :at 0q :value [0.1 0.2 0.3] :ease hold)",
        }},
    );

    try expectEdit(
        .{ .ease = .{
            .sel = .{ .lanes = &.{"glow"}, .kinds = .keyframes, .range = .{ 0, 1 } },
            .ease = "(spring :damping 0.5)",
        } },
        \\[
        \\{"op":"set_keyword","root":7,"path":[0],"key":"ease","value":{"$form":"spring","damping":0.5}}
        \\]
        \\
    ,
        &.{.{
            .from = "(keyframe :at 0q :value 0.2 :ease hold)",
            .to = "(keyframe :at 0q :value 0.2 :ease (spring :damping 0.5))",
        }},
    );
}

test "ops: resize writes :dur on a note and :repeat on a clip" {
    try expectEdit(
        .{ .resize = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .notes, .range = .{ 0, 1 } },
            .dur = TPQ,
        } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[0],"key":"dur","value":{"$num":[1,"q"]}}
        \\]
        \\
    ,
        &.{.{
            .from = "(note :at 0q :dur 0.5q :key 36 :vel 110)",
            .to = "(note :at 0q :dur 1q :key 36 :vel 110)",
        }},
    );

    try expectEdit(
        .{ .resize = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .clips },
            .repeat = 3,
        } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[3],"key":"repeat","value":3}
        \\]
        \\
    ,
        &.{.{
            .from = "(clip :at 4q :phrase fill :repeat 2)",
            .to = "(clip :at 4q :phrase fill :repeat 3)",
        }},
    );
}

test "ops: velocity and transpose write :vel and :key" {
    try expectEdit(
        .{ .velocity = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .notes, .keys = &.{36} },
            .vel = 64,
        } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[0],"key":"vel","value":64},
        \\{"op":"set_keyword","root":6,"path":[2],"key":"vel","value":64}
        \\]
        \\
    ,
        &.{.{
            .from = "  (note :at 0q :dur 0.5q :key 36 :vel 110)\n  (note :at 1q :dur 0.5q :key 60 :vel 90)\n  (note :at 2q :dur 0.5q :key 36 :vel 80)",
            .to = "  (note :at 0q :dur 0.5q :key 36 :vel 64)\n  (note :at 1q :dur 0.5q :key 60 :vel 90)\n  (note :at 2q :dur 0.5q :key 36 :vel 64)",
        }},
    );

    try expectEdit(
        .{ .transpose = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .notes, .range = .{ 0, 1 } },
            .semitones = 12,
        } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[0],"key":"key","value":48}
        \\]
        \\
    ,
        &.{.{
            .from = "(note :at 0q :dur 0.5q :key 36 :vel 110)",
            .to = "(note :at 0q :dur 0.5q :key 48 :vel 110)",
        }},
    );
}

test "ops: a selection that resolves to nothing is edit_range_empty" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, .{
        .retime = .{ .sel = .{ .lanes = &.{"flash"}, .range = .{ 100 * TPQ, 200 * TPQ } }, .delta = 1 },
    });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    try testing.expect(p.summary.refused);
    try testing.expect(p.findDiag(.edit_range_empty) != null);
}

test "ops: a bound lane has nothing to edit here — edit_target_bound" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, .{
        .retime = .{ .sel = .{ .lanes = &.{"kick"} }, .delta = TPQ },
    });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    const d = p.findDiag(.edit_target_bound).?;
    try testing.expectEqual(fx.doc_().lanes[2].span, d.span);
}

test "ops: split a clip into two windows of one phrase" {
    try expectEdit(
        .{ .split = .{ .sel = .{ .lanes = &.{"flash"}, .kinds = .clips }, .at = 6 * TPQ } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[3],"key":"length","value":{"$num":[2,"q"]}},
        \\{"op":"insert_positional","root":6,"path":[],"index":4,"value":{"$form":"clip","at":{"$num":[6,"q"]},"phrase":{"$sym":"fill"},"repeat":2,"offset":{"$num":[2,"q"]},"length":{"$num":[6,"q"]}}}
        \\]
        \\
    ,
        &.{.{
            .from = "  (clip :at 4q :phrase fill :repeat 2))",
            .to = "  (clip :at 4q :phrase fill :repeat 2 :length 2q)\n  (clip :at 6q :phrase fill :repeat 2 :offset 2q :length 6q))",
        }},
    );
}

test "ops: merge is the inverse — one window, one clip" {
    const want =
        \\(timeline :length 4bar)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(anchor :id song :kind it :file "impulse-04.it")
        \\
        \\(lane :name flash
        \\  (clip :at 0bar :phrase fill :length 2bar))
        \\(lane :name spare)
        \\
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash
        \\    (note :at 0q :dur 0.25q :key 38 :vel 100)))
        \\
    ;
    try expectPlanOn(
        test_support.clips,
        .{ .merge = .{ .sel = .{ .lanes = &.{"flash"}, .kinds = .clips } } },
        \\[
        \\{"op":"set_keyword","root":4,"path":[0],"key":"length","value":{"$num":[2,"bar"]}},
        \\{"op":"remove_positional","root":4,"path":[],"index":1}
        \\]
        \\
    ,
        want,
    );
}

test "ops: duplicate inserts retimed copies at their sorted indices" {
    try expectEdit(
        .{ .duplicate = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .notes },
            .delta = 4 * TPQ,
        } },
        \\[
        \\{"op":"insert_positional","root":6,"path":[],"index":4,"value":{"$form":"note","at":{"$num":[1,"bar"]},"dur":{"$num":[0.5,"q"]},"key":36,"vel":110}},
        \\{"op":"insert_positional","root":6,"path":[],"index":5,"value":{"$form":"note","at":{"$num":[5,"q"]},"dur":{"$num":[0.5,"q"]},"key":60,"vel":90}},
        \\{"op":"insert_positional","root":6,"path":[],"index":6,"value":{"$form":"note","at":{"$num":[6,"q"]},"dur":{"$num":[0.5,"q"]},"key":36,"vel":80}}
        \\]
        \\
    ,
        &.{.{
            .from = "  (clip :at 4q :phrase fill :repeat 2))",
            .to = "  (clip :at 4q :phrase fill :repeat 2)\n  (note :at 1bar :dur 0.5q :key 36 :vel 110)\n  (note :at 5q :dur 0.5q :key 60 :vel 90)\n  (note :at 6q :dur 0.5q :key 36 :vel 80))",
        }},
    );
}

test "ops: stretch scales the range and shifts what follows, counting what rounded" {
    // 3/2 over the first two quarter notes: 0q stays, 1q becomes 1.5q,
    // and everything after 2q moves by the growth (one quarter note).
    // The note at 1q has a 0.5q duration, which 3/2 makes 0.75q — exact;
    // the note at 2q is outside the range and only shifts.
    try expectEdit(
        .{ .stretch = .{ .from = 0, .to = 2 * TPQ, .p = 3, .q = 2 } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[0],"key":"dur","value":{"$num":[0.75,"q"]}},
        \\{"op":"set_keyword","root":6,"path":[1],"key":"at","value":{"$num":[1.5,"q"]}},
        \\{"op":"set_keyword","root":6,"path":[1],"key":"dur","value":{"$num":[0.75,"q"]}},
        \\{"op":"set_keyword","root":6,"path":[2],"key":"at","value":{"$num":[3,"q"]}},
        \\{"op":"set_keyword","root":6,"path":[3],"key":"at","value":{"$num":[5,"q"]}},
        \\{"op":"set_keyword","root":7,"path":[1],"key":"at","value":{"$num":[5,"q"]}},
        \\{"op":"set_keyword","root":4,"path":[],"key":"dur","value":{"$num":[17,"q"]}},
        \\{"op":"set_keyword","root":5,"path":[],"key":"at","value":{"$num":[17,"q"]}}
        \\]
        \\
    ,
        &.{
            .{ .from = "(note :at 0q :dur 0.5q :key 36 :vel 110)", .to = "(note :at 0q :dur 0.75q :key 36 :vel 110)" },
            .{ .from = "(note :at 1q :dur 0.5q :key 60 :vel 90)", .to = "(note :at 1.5q :dur 0.75q :key 60 :vel 90)" },
            .{ .from = "(note :at 2q :dur 0.5q :key 36 :vel 80)", .to = "(note :at 3q :dur 0.5q :key 36 :vel 80)" },
            .{ .from = "(clip :at 4q :phrase fill :repeat 2)", .to = "(clip :at 5q :phrase fill :repeat 2)" },
            .{ .from = "(keyframe :at 4q :value 0.9 :ease in-cubic)", .to = "(keyframe :at 5q :value 0.9 :ease in-cubic)" },
            // The section opens before the range and reaches past it, so
            // its onset stays and its window grows by what the stretch
            // put inside it.
            .{ .from = "(section :name intro :at 0bar :dur 4bar)", .to = "(section :name intro :at 0bar :dur 17q)" },
            .{ .from = "(cue :name \"the drop\" :at 4bar)", .to = "(cue :name \"the drop\" :at 17q)" },
        },
    );
}

test "ops: insert-tempo, musical — one root and nothing moves" {
    try expectEdit(
        .{ .insert_tempo = .{ .point = .{ .tick = 4 * TPQ, .tempo = .{ .qpm = 240 } } } },
        \\[
        \\{"op":"insert_root","index":2,"value":{"$form":"tempo-point","at":{"$num":[1,"bar"]},"qpm":240}}
        \\]
        \\
    ,
        &.{.{
            .from = "(tempo-point :at 0q :qpm 120)\n",
            .to = "(tempo-point :at 0q :qpm 120)\n(tempo-point :at 1bar :qpm 240)\n",
        }},
    );
}

test "ops: insert-tempo, wall-clock — every event after it keeps its seconds" {
    // 120 quarter notes per minute is half a second each, so the cue at
    // 16q sits at 8 seconds. Doubling the tempo at 4q (2 seconds in)
    // makes every quarter after it a quarter second, so 8 seconds is
    // 4q + 24q = 28q — seven bars of [4 4].
    try expectEdit(
        .{ .insert_tempo = .{
            .point = .{ .tick = 4 * TPQ, .tempo = .{ .qpm = 240 } },
            .mode = .wall_clock,
        } },
        \\[
        \\{"op":"set_keyword","root":5,"path":[],"key":"at","value":{"$num":[7,"bar"]}},
        \\{"op":"insert_root","index":2,"value":{"$form":"tempo-point","at":{"$num":[1,"bar"]},"qpm":240}}
        \\]
        \\
    ,
        &.{
            .{
                .from = "(tempo-point :at 0q :qpm 120)\n",
                .to = "(tempo-point :at 0q :qpm 120)\n(tempo-point :at 1bar :qpm 240)\n",
            },
            .{ .from = "(cue :name \"the drop\" :at 4bar)", .to = "(cue :name \"the drop\" :at 7bar)" },
        },
    );
}

test "ops: insert-meter respells every bar literal the change would move" {
    // [3 4] from bar 1 on. Every `bar` literal after it resolves to a
    // different tick under the new map, so each is re-spelled from the
    // tick it MEANT: the cue at 16q is bar 5 now, the section's four
    // bars are five of them, and the eight-bar length is 32 quarters.
    try expectEdit(
        .{ .insert_meter = .{ .point = .{ .tick = 4 * TPQ, .n = 3, .d = 4 } } },
        \\[
        \\{"op":"set_keyword","root":0,"path":[],"key":"length","value":{"$num":[32,"q"]}},
        \\{"op":"set_keyword","root":4,"path":[],"key":"dur","value":{"$num":[5,"bar"]}},
        \\{"op":"set_keyword","root":5,"path":[],"key":"at","value":{"$num":[5,"bar"]}},
        \\{"op":"insert_root","index":3,"value":{"$form":"meter-point","at":{"$num":[1,"bar"]},"sig":[3,4]}}
        \\]
        \\
    ,
        &.{
            .{ .from = ":length 8bar", .to = ":length 32q" },
            // The new root lands at the anchor's own span start and
            // takes the blank line that separated it, so it reads as its
            // own paragraph (§11.6: an inserted root copies the
            // whitespace run before its neighbour).
            .{ .from = "\n(anchor :id song", .to = "\n(meter-point :at 1bar :sig [3 4])\n\n(anchor :id song" },
            .{ .from = "(section :name intro :at 0bar :dur 4bar)", .to = "(section :name intro :at 0bar :dur 5bar)" },
            .{ .from = "(cue :name \"the drop\" :at 4bar)", .to = "(cue :name \"the drop\" :at 5bar)" },
        },
    );
}

test "ops: insert-meter off a bar line is edit_off_bar" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, .{
        .insert_meter = .{ .point = .{ .tick = 5 * TPQ, .n = 3, .d = 4 } },
    });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    try testing.expect(p.findDiag(.edit_off_bar) != null);
}

test "ops: rename a phrase, and every clip that places it" {
    try expectEdit(
        .{ .rename = .{ .what = .phrase, .from = "fill", .to = "roll" } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[3],"key":"phrase","value":{"$sym":"roll"}},
        \\{"op":"set_keyword","root":9,"path":[],"key":"name","value":{"$sym":"roll"}}
        \\]
        \\
    ,
        &.{
            .{ .from = "(clip :at 4q :phrase fill :repeat 2)", .to = "(clip :at 4q :phrase roll :repeat 2)" },
            .{ .from = "(phrase :name fill :length 1bar", .to = "(phrase :name roll :length 1bar" },
        },
    );
}

test "ops: rename a lane, and the phrase lane its clips place" {
    try expectEdit(
        .{ .rename = .{ .what = .lane, .from = "flash", .to = "strobe" } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[],"key":"name","value":{"$sym":"strobe"}},
        \\{"op":"set_keyword","root":9,"path":[0],"key":"name","value":{"$sym":"strobe"}}
        \\]
        \\
    ,
        &.{
            .{ .from = "(lane :name flash :target flash", .to = "(lane :name strobe :target flash" },
            .{ .from = "  (lane :name flash\n", .to = "  (lane :name strobe\n" },
        },
    );
}

test "ops: rename an anchor, and the bound lane that names it" {
    try expectEdit(
        .{ .rename = .{ .what = .anchor, .from = "song", .to = "module" } },
        \\[
        \\{"op":"set_keyword","root":3,"path":[],"key":"id","value":{"$sym":"module"}},
        \\{"op":"set_keyword","root":8,"path":[],"key":"from","value":{"$sym":"module"}}
        \\]
        \\
    ,
        &.{
            .{ .from = "(anchor :id song", .to = "(anchor :id module" },
            .{ .from = ":kind notes :from song", .to = ":kind notes :from module" },
        },
    );
}

test "ops: renaming a target a pacer form declares is edit_readonly_passthrough" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, .{
        .rename = .{ .what = .target, .from = "glow", .to = "halo" },
    });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    const d = p.findDiag(.edit_readonly_passthrough).?;
    try testing.expectEqual(fx.doc_().passthrough[0].span, d.span);
}

test "ops: bind an empty lane, and refuse one that carries content" {
    const want =
        \\(timeline :length 4bar)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(anchor :id song :kind it :file "impulse-04.it")
        \\
        \\(lane :name flash
        \\  (clip :at 0bar :phrase fill :length 1bar)
        \\  (clip :at 1bar :phrase fill :offset 1bar :length 1bar))
        \\(lane :name spare :from song :channel 5)
        \\
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash
        \\    (note :at 0q :dur 0.25q :key 38 :vel 100)))
        \\
    ;
    try expectPlanOn(
        test_support.clips,
        .{ .bind = .{
            .lane = "spare",
            .anchor = "song",
            .address = .{ .it = .{ .channel = 4, .column = null, .fx = null } },
        } },
        \\[
        \\{"op":"set_keyword","root":5,"path":[],"key":"from","value":{"$sym":"song"}},
        \\{"op":"set_keyword","root":5,"path":[],"key":"channel","value":5}
        \\]
        \\
    ,
        want,
    );

    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.clips);
    defer fx.deinit();

    var p = try plan(gpa, fx.doc_(), &fx.tree, .{ .bind = .{
        .lane = "flash",
        .anchor = "song",
        .address = .{ .it = .{ .channel = 4, .column = null, .fx = null } },
    } });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    try testing.expect(p.findDiag(.edit_would_duplicate) != null);
}

test "ops: unbind takes the anchor and the address keys off" {
    try expectEdit(
        .{ .unbind = .{ .lane = "kick" } },
        \\[
        \\{"op":"remove_keyword","root":8,"path":[],"key":"from"},
        \\{"op":"remove_keyword","root":8,"path":[],"key":"channel"}
        \\]
        \\
    ,
        &.{.{
            .from = "(lane :name kick :kind notes :from song :channel 3)",
            .to = "(lane :name kick :kind notes)",
        }},
    );
}

test "ops: a move that would sound two notes on one key at once is edit_overlap" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    // The lane's third note is on key 36, as its first is: moving it
    // onto the first would make the overlap the document itself refuses.
    var p = try plan(gpa, fx.doc_(), &fx.tree, .{
        .retime = .{
            .sel = .{ .lanes = &.{"flash"}, .kinds = .notes, .range = .{ 2 * TPQ, 3 * TPQ } },
            .to = 0,
        },
    });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    const d = p.findDiag(.edit_overlap).?;
    try testing.expectEqual(fx.doc_().lanes[0].notes[0].span, d.span);
}

test "ops: quantize at half strength moves half the way, ties down" {
    // A half-note grid puts a line on 0q and 2q, so the note at 1q is
    // exactly between them: the tie resolves DOWN, and half strength
    // takes it half of that distance.
    try expectEdit(
        .{ .quantize = .{
            .sel = .{ .lanes = &.{"flash"} },
            .grid = .{ .div = 2 },
            .strength = 0.5,
        } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[1],"key":"at","value":{"$num":[0.5,"q"]}}
        \\]
        \\
    ,
        &.{.{
            .from = "(note :at 1q :dur 0.5q :key 60 :vel 90)",
            .to = "(note :at 0.5q :dur 0.5q :key 60 :vel 90)",
        }},
    );
}

test "ops: quantize with :dur-too moves the end onto the grid as well" {
    const source: [:0]const u8 =
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name flash
        \\  (note :at 0.3q :dur 0.4q :key 36))
        \\
    ;
    const want =
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name flash
        \\  (note :at 0bar :dur 1q :key 36))
        \\
    ;
    try expectPlanOn(
        source,
        .{ .quantize = .{
            .sel = .{ .lanes = &.{"flash"} },
            .grid = .{ .div = 4 },
            .dur_too = true,
        } },
        \\[
        \\{"op":"set_keyword","root":3,"path":[0],"key":"at","value":{"$num":[0,"bar"]}},
        \\{"op":"set_keyword","root":3,"path":[0],"key":"dur","value":{"$num":[1,"q"]}}
        \\]
        \\
    ,
        want,
    );
}

test "ops: nudge by one step of a grid" {
    try expectEdit(
        .{ .nudge = .{
            .sel = .{ .lanes = &.{"flash"} },
            .delta = .{ .steps = .{ .grid = .{ .div = 16 }, .count = 1 } },
        } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[0],"key":"at","value":{"$num":[0.25,"q"]}},
        \\{"op":"set_keyword","root":6,"path":[1],"key":"at","value":{"$num":[1.25,"q"]}},
        \\{"op":"set_keyword","root":6,"path":[2],"key":"at","value":{"$num":[2.25,"q"]}},
        \\{"op":"set_keyword","root":6,"path":[3],"key":"at","value":{"$num":[4.25,"q"]}}
        \\]
        \\
    ,
        &.{
            .{ .from = "(note :at 0q :dur 0.5q :key 36 :vel 110)", .to = "(note :at 0.25q :dur 0.5q :key 36 :vel 110)" },
            .{ .from = "(note :at 1q :dur 0.5q :key 60 :vel 90)", .to = "(note :at 1.25q :dur 0.5q :key 60 :vel 90)" },
            .{ .from = "(note :at 2q :dur 0.5q :key 36 :vel 80)", .to = "(note :at 2.25q :dur 0.5q :key 36 :vel 80)" },
            .{ .from = "(clip :at 4q :phrase fill :repeat 2)", .to = "(clip :at 4.25q :phrase fill :repeat 2)" },
        },
    );
}

test "ops: insert a section root after the last one of its head" {
    try expectEdit(
        .{ .insert = .{ .what = .{ .section = .{ .name = "outro", .at = 16 * TPQ, .dur = 16 * TPQ } } } },
        \\[
        \\{"op":"insert_root","index":5,"value":{"$form":"section","name":{"$sym":"outro"},"at":{"$num":[4,"bar"]},"dur":{"$num":[4,"bar"]}}}
        \\]
        \\
    ,
        &.{.{
            .from = "(cue :name \"the drop\" :at 4bar)",
            .to = "(section :name outro :at 4bar :dur 4bar)\n(cue :name \"the drop\" :at 4bar)",
        }},
    );
}

test "ops: insert the other children and the other roots" {
    // A keyframe and a clip into their lanes, and the two roots a
    // document grows by — every arm of the form builder, so no shape is
    // written for the first time by a host.
    try expectEdit(
        .{ .insert = .{ .lane = "glow", .what = .{ .keyframe = .{
            .at = 2 * TPQ,
            .value = .{ 0.5, 0, 0, 0 },
            .ncomp = 1,
            .ease = "in-cubic",
        } } } },
        \\[
        \\{"op":"insert_positional","root":7,"path":[],"index":1,"value":{"$form":"keyframe","at":{"$num":[2,"q"]},"value":0.5,"ease":{"$sym":"in-cubic"}}}
        \\]
        \\
    ,
        &.{.{
            .from = "  (keyframe :at 4q",
            .to = "  (keyframe :at 2q :value 0.5 :ease in-cubic)\n  (keyframe :at 4q",
        }},
    );

    try expectEdit(
        .{ .insert = .{ .lane = "flash", .what = .{ .clip = .{
            .at = 8 * TPQ,
            .phrase = "fill",
            .repeat = 2,
            .offset = 0,
        } } } },
        \\[
        \\{"op":"insert_positional","root":6,"path":[],"index":4,"value":{"$form":"clip","at":{"$num":[2,"bar"]},"phrase":{"$sym":"fill"},"repeat":2,"offset":{"$num":[0,"bar"]}}}
        \\]
        \\
    ,
        &.{.{
            .from = "  (clip :at 4q :phrase fill :repeat 2))",
            .to = "  (clip :at 4q :phrase fill :repeat 2)\n  (clip :at 2bar :phrase fill :repeat 2 :offset 0bar))",
        }},
    );

    try expectEdit(
        .{ .insert = .{ .what = .{ .lane = .{ .name = "haze", .kind = .curve, .target = "haze" } } } },
        \\[
        \\{"op":"insert_root","index":9,"value":{"$form":"lane","name":{"$sym":"haze"},"kind":{"$sym":"curve"},"target":{"$sym":"haze"}}}
        \\]
        \\
    ,
        &.{.{
            .from = "\n(phrase :name fill",
            .to = "\n(lane :name haze :kind curve :target haze)\n\n(phrase :name fill",
        }},
    );

    try expectEdit(
        .{ .insert = .{ .what = .{ .phrase = .{
            .name = "roll",
            .length = 4 * TPQ,
            .lanes = &.{"flash"},
        } } } },
        \\[
        \\{"op":"insert_root","index":10,"value":{"$form":"phrase","name":{"$sym":"roll"},"length":{"$num":[1,"bar"]},"$children":[{"$form":"lane","name":{"$sym":"flash"}}]}}
        \\]
        \\
    ,
        &.{.{
            .from = "\n(target :name glow :arity 1)",
            // A form built from an action's value is PRINTED, and the
            // printer keeps a short one on its line (§11.6's second
            // caveat: a splice does not refold).
            .to = "\n(phrase :name roll :length 1bar (lane :name flash))\n\n(target :name glow :arity 1)",
        }},
    );
}

test "ops: the same document and the same operation give the same plan" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.native);
    defer fx.deinit();

    const op: Op.Op = .{ .quantize = .{
        .sel = .{},
        .grid = .{ .div = 2 },
        .strength = 0.5,
    } };

    var first = try plan(gpa, fx.doc_(), &fx.tree, op);
    defer first.deinit();
    var second = try plan(gpa, fx.doc_(), &fx.tree, op);
    defer second.deinit();

    const a_text = try first.text(gpa);
    defer gpa.free(a_text);
    const b_text = try second.text(gpa);
    defer gpa.free(b_text);
    try testing.expectEqualStrings(a_text, b_text);

    // …and the document it reads is the document it was handed: `plan`
    // is a pure function of the two, and a second reading of the same
    // source still equals the one it walked.
    var again = try test_support.Fixture.init(gpa, test_support.native);
    defer again.deinit();
    try testing.expect(fx.doc_().eql(again.doc_()));
}

test "ops: a whole-lane retime moves every child and touches no structure" {
    // The bug this pins: `apply` runs EVERY removal before ANY insert, so
    // a batch planned one target at a time would remove three children
    // and then insert three at indices that named the untouched
    // document. Planned together, the lane's order never changes and
    // nothing structural happens at all.
    try expectEdit(
        .{ .retime = .{ .sel = .{ .lanes = &.{"flash"} }, .delta = 10 * TPQ } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[0],"key":"at","value":{"$num":[10,"q"]}},
        \\{"op":"set_keyword","root":6,"path":[1],"key":"at","value":{"$num":[11,"q"]}},
        \\{"op":"set_keyword","root":6,"path":[2],"key":"at","value":{"$num":[3,"bar"]}},
        \\{"op":"set_keyword","root":6,"path":[3],"key":"at","value":{"$num":[14,"q"]}}
        \\]
        \\
    ,
        &.{
            .{ .from = "(note :at 0q :dur 0.5q :key 36 :vel 110)", .to = "(note :at 10q :dur 0.5q :key 36 :vel 110)" },
            .{ .from = "(note :at 1q :dur 0.5q :key 60 :vel 90)", .to = "(note :at 11q :dur 0.5q :key 60 :vel 90)" },
            .{ .from = "(note :at 2q :dur 0.5q :key 36 :vel 80)", .to = "(note :at 3bar :dur 0.5q :key 36 :vel 80)" },
            .{ .from = "(clip :at 4q :phrase fill :repeat 2)", .to = "(clip :at 14q :phrase fill :repeat 2)" },
        },
    );
}

test "ops: two of four moved backwards past one that stays" {
    // Slots 2 and 3 move to 0.5q and 1.5q. The second still fits where
    // it sits; the first does not, so it alone is removed and inserted —
    // and its index is a slot in the list the removal LEAVES, which is
    // the whole of critical fix 1.
    const want =
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\
        \\(lane :name flash
        \\  (note :at 0q :dur 0.25q :key 36)
        \\  (note :at 0.5q :dur 0.25q :key 40)
        \\  (note :at 1q :dur 0.25q :key 38)
        \\  (note :at 1.5q :dur 0.25q :key 41))
        \\
    ;
    try expectPlanOn(
        test_support.four,
        .{ .retime = .{
            .sel = .{ .lanes = &.{"flash"}, .range = .{ 2 * TPQ, 4 * TPQ } },
            .delta = -3 * @divExact(TPQ, 2),
        } },
        \\[
        \\{"op":"set_keyword","root":3,"path":[3],"key":"at","value":{"$num":[1.5,"q"]}},
        \\{"op":"remove_positional","root":3,"path":[],"index":2},
        \\{"op":"insert_positional","root":3,"path":[],"index":1,"value":{"$form":"note","at":{"$num":[0.5,"q"]},"dur":{"$num":[0.25,"q"]},"key":40}}
        \\]
        \\
    ,
        want,
    );
}

test "ops: a quantize that would stack two notes on one key is edit_overlap" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.crossing);
    defer fx.deinit();

    // A half-note grid puts both notes on tick 0, where they would sound
    // over each other — a collision the plan makes with ITSELF, invisible
    // to a check that only looks at the document as it stands.
    var p = try plan(gpa, fx.doc_(), &fx.tree, .{ .quantize = .{
        .sel = .{ .lanes = &.{"flash"} },
        .grid = .{ .div = 2 },
    } });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.actions.len);
    const d = p.findDiag(.edit_overlap).?;
    try testing.expectEqual(fx.doc_().lanes[0].notes[1].span, d.span);
}

test "ops: dur-too lands on an unsorted lane, moved or not" {
    // The lane is not sorted, which is legal. One note stays where it is
    // and takes only the quantized `:dur`; the other moves far enough to
    // be re-inserted, and carries its `:dur` into the rebuilt form —
    // both halves of one override set.
    const want =
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\
        \\(lane :name flash
        \\  (note :at 0bar :dur 1q :key 38)
        \\  (note :at 2q :dur 1q :key 36))
        \\
    ;
    try expectPlanOn(
        test_support.unsorted,
        .{ .quantize = .{
            .sel = .{ .lanes = &.{"flash"} },
            .grid = .{ .div = 4 },
            .dur_too = true,
        } },
        \\[
        \\{"op":"set_keyword","root":3,"path":[0],"key":"dur","value":{"$num":[1,"q"]}},
        \\{"op":"remove_positional","root":3,"path":[],"index":1},
        \\{"op":"insert_positional","root":3,"path":[],"index":0,"value":{"$form":"note","at":{"$num":[0,"bar"]},"dur":{"$num":[1,"q"]},"key":38}}
        \\]
        \\
    ,
        want,
    );
}

test "ops: a conducted document is spelled under its conductor's own meter" {
    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, test_support.conducted);
    defer fx.deinit();

    // The file says `[3 4]`, so its bars are three quarter notes: the cue
    // at `1bar` is 3q and three quarters later is bar 2. Under the
    // placeholder a conducted document would otherwise get, the same tick
    // is a bar and a half and spells `6q`.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try fx.loaded.map.spell(&w, 6 * TPQ);
    try testing.expectEqualStrings("2bar", w.buffered());

    var p = try plan(gpa, fx.doc_(), &fx.tree, .{ .retime = .{
        .sel = .{ .kinds = .{ .cue = true } },
        .delta = 3 * TPQ,
    } });
    defer p.deinit();

    var applied = try apply.apply(gpa, fx.source, &p);
    defer applied.deinit();
    try testing.expect(!applied.diags.hasErrors());
    try testing.expect(std.mem.indexOf(u8, applied.text, "(cue :name \"two\" :at 2bar)") != null);
}

test "ops: stretch counts the positions that rounded, and not its own growth" {
    // A tick that is not divisible by two cannot survive 3/2: one
    // position rounds (half to even, so 1t lands on 2t) and the range's
    // own growth is exact, which is not a position and is not counted.
    const source: [:0]const u8 =
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name flash
        \\  (note :at 1t :dur 1t :key 36))
        \\
    ;
    const want =
        \\(timeline :length 1bar)
        \\(tempo-point :at 0q :qpm 120)
        \\(meter-point :at 0bar :sig [4 4])
        \\(lane :name flash
        \\  (note :at 2t :dur 1t :key 36))
        \\
    ;
    try expectPlanOn(
        source,
        .{ .stretch = .{ .from = 0, .to = 4 * TPQ, .p = 3, .q = 2 } },
        \\[
        \\{"op":"set_keyword","root":3,"path":[0],"key":"at","value":{"$num":[2,"t"]}}
        \\]
        \\
    ,
        want,
    );

    const gpa = testing.allocator;
    var fx = try test_support.Fixture.init(gpa, source);
    defer fx.deinit();
    var p = try plan(gpa, fx.doc_(), &fx.tree, .{
        .stretch = .{ .from = 0, .to = 4 * TPQ, .p = 3, .q = 2 },
    });
    defer p.deinit();
    try testing.expectEqual(@as(u32, 1), p.summary.inexact);
    try testing.expectEqual(Diag.Severity.warning, p.findDiag(.edit_inexact).?.severity);
}

test "ops: insert a cue, and duplicate one" {
    try expectEdit(
        .{ .insert = .{ .what = .{ .cue = .{ .name = "the lift", .at = 32 * TPQ } } } },
        \\[
        \\{"op":"insert_root","index":6,"value":{"$form":"cue","name":"the lift","at":{"$num":[8,"bar"]}}}
        \\]
        \\
    ,
        &.{.{
            .from = "\n(lane :name flash :target flash",
            .to = "\n(cue :name \"the lift\" :at 8bar)\n\n(lane :name flash :target flash",
        }},
    );

    try expectEdit(
        .{ .duplicate = .{ .sel = .{ .kinds = .{ .cue = true } }, .delta = 16 * TPQ } },
        \\[
        \\{"op":"insert_root","index":6,"value":{"$form":"cue","name":"the drop","at":{"$num":[8,"bar"]}}}
        \\]
        \\
    ,
        &.{.{
            .from = "\n(lane :name flash :target flash",
            .to = "\n(cue :name \"the drop\" :at 8bar)\n\n(lane :name flash :target flash",
        }},
    );
}

test "ops: rename a section, and rename a target no pacer form declares" {
    try expectEdit(
        .{ .rename = .{ .what = .section, .from = "intro", .to = "opening" } },
        \\[
        \\{"op":"set_keyword","root":4,"path":[],"key":"name","value":{"$sym":"opening"}}
        \\]
        \\
    ,
        &.{.{
            .from = "(section :name intro :at 0bar :dur 4bar)",
            .to = "(section :name opening :at 0bar :dur 4bar)",
        }},
    );

    try expectEdit(
        .{ .rename = .{ .what = .target, .from = "flash", .to = "strobe" } },
        \\[
        \\{"op":"set_keyword","root":6,"path":[],"key":"target","value":{"$sym":"strobe"}}
        \\]
        \\
    ,
        &.{.{
            .from = "(lane :name flash :target flash",
            .to = "(lane :name flash :target strobe",
        }},
    );
}
