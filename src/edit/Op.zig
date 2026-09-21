//! The operations (plan 07, "The operations").
//!
//! One union over everything an editor can ask for, and the payloads
//! those asks carry. Every position here is a TICK: plan 03's grid is the
//! one coordinate above `doc/`, and the SPELLING a tick reaches the
//! document in is the printer's rule, not the caller's choice.
//!
//! The payload types are the AUTHORING shapes and deliberately not
//! `Doc`'s reading ones: a note to be inserted has no span yet, because
//! it has no bytes yet.

const std = @import("std");

const Diag = @import("../Diag.zig");
const doc = @import("../doc/doc.zig");
const select_file = @import("Select.zig");
const Select = select_file.Select;
const Kind = select_file.Kind;
const Kinds = select_file.Kinds;
const Grid = @import("../time/Grid.zig");
const Snap = @import("Snap.zig");

const testing = std.testing;

pub const Error = error{OutOfMemory};

/// A note to insert.
pub const NewNote = struct {
    at: i64,
    dur: i64,
    key: u7,
    vel: ?u7 = null,
    /// The rendering channel, ON THE WIRE (`:ch 1` is 0), as `Doc` keeps
    /// it. Null leaves the key off and the lane's default applies.
    ch: ?u4 = null,
    off_vel: ?u7 = null,
};

/// A keyframe to insert.
pub const NewKeyframe = struct {
    at: i64,
    value: [4]f32 = .{ 0, 0, 0, 0 },
    ncomp: u3 = 1,
    /// The `:ease` value as SJON SOURCE TEXT — `in-cubic`, or a whole
    /// `(spring :damping 0.5)`. Typed by pacer's own `ease-spec`, so
    /// tempura carries the spelling and never re-spells it; null leaves
    /// the key off and the schema's `linear` applies.
    ease: ?[]const u8 = null,
};

/// A clip to insert.
pub const NewClip = struct {
    at: i64,
    phrase: []const u8,
    repeat: ?u32 = null,
    offset: ?i64 = null,
    length: ?i64 = null,
    transpose: ?i8 = null,
};

pub const NewSection = struct { name: []const u8, at: i64, dur: i64 };
pub const NewCue = struct { name: []const u8, at: i64 };

/// A lane to insert — empty. Content goes in with its own `insert`,
/// which is how a document gets built one addressable step at a time.
pub const NewLane = struct {
    name: []const u8,
    kind: doc.LaneKind = .notes,
    target: ?[]const u8 = null,
};

/// A phrase to insert. `lanes` are the names of the empty lanes it opens
/// with: the schema wants at least one, and a phrase with no lane places
/// nothing.
pub const NewPhrase = struct {
    name: []const u8,
    length: i64,
    lanes: []const []const u8 = &.{},
};

/// What `insert` puts where.
///
/// A tempo point and a meter point are NOT here: inserting one is
/// `insert_tempo` / `insert_meter`, which are that insert plus the work
/// the map change makes necessary, and a second spelling of the plain
/// insert would be a second answer to the same question.
pub const New = union(enum) {
    note: NewNote,
    keyframe: NewKeyframe,
    clip: NewClip,
    section: NewSection,
    cue: NewCue,
    lane: NewLane,
    phrase: NewPhrase,

    /// Whether this goes into a lane (a child) or into the document (a
    /// root).
    pub fn isChild(self: New) bool {
        return switch (self) {
            .note, .keyframe, .clip => true,
            .section, .cue, .lane, .phrase => false,
        };
    }

    /// The head of the form it becomes.
    pub fn head(self: New) []const u8 {
        return @tagName(self);
    }
};

pub const Insert = struct {
    /// Which lane a child goes into, by name. Ignored by a root.
    lane: ?[]const u8 = null,
    what: New,
};

/// What `remove` takes, and whether it means the occurrences a shared
/// Impulse Tracker pattern has beside the one the selection reached.
pub const Remove = struct {
    sel: Select,
    allow_shared: bool = false,
};

/// Where a selection moves to: by `delta`, or onto `to`. Exactly one;
/// neither is a refusal, both is `delta`.
pub const Retime = struct {
    sel: Select,
    delta: ?i64 = null,
    to: ?i64 = null,
    /// Edit a bound Impulse Tracker cell in — or into — a pattern that
    /// more than one order plays, knowing that EVERY occurrence changes
    /// — plan 07's `:allow-shared`. Without it such an edit is
    /// `edit_pattern_shared`. Nothing else reads it: a pattern is the
    /// only content in this vocabulary that is played more than once.
    allow_shared: bool = false,
};

pub const Revalue = struct {
    sel: Select,
    value: [4]f32,
    ncomp: u3 = 1,
};

pub const Ease = struct {
    sel: Select,
    /// A pacer `ease-spec` as source text — a name or a form.
    ease: []const u8,
};

/// `:dur` for a note or a section, `:length` and `:repeat` for a clip —
/// the three ways a thing on the timeline says how long it lasts.
pub const Resize = struct {
    sel: Select,
    dur: ?i64 = null,
    repeat: ?u32 = null,
};

pub const Velocity = struct {
    sel: Select,
    vel: u7,
    /// `Retime.allow_shared`, for the same reason: writing a bound IT
    /// cell's volume column writes it for every order that plays the
    /// pattern.
    allow_shared: bool = false,
};

/// Split every selected clip at `at`.
pub const Split = struct { sel: Select, at: i64 };

/// Merge the selected clips: two adjacent windows of one phrase on one
/// lane, back into one.
pub const Merge = struct { sel: Select };

pub const Duplicate = struct {
    sel: Select,
    delta: ?i64 = null,
    to: ?i64 = null,
};

pub const Quantize = struct {
    sel: Select,
    grid: Snap.Grid,
    /// How far onto the line, 0..1. Below 1 the target moves a fraction
    /// of the way and lands on a tick.
    strength: f64 = 1,
    /// −1..1, the fraction of a step every second line moves by.
    swing: f64 = 0,
    /// Move the end with the onset, keeping the duration in grid terms
    /// rather than in ticks.
    dur_too: bool = false,
};

/// By ticks, or by counted steps of a grid.
pub const Delta = union(enum) {
    ticks: i64,
    steps: struct { grid: Snap.Grid, count: i32 },

    /// The most grid lines a nudge counts, either way.
    ///
    /// `ops_quantize.nudged` walks the lines one at a time — a step is
    /// counted from the tick's own bar, so a meter change is honoured
    /// line by line — and a count is therefore time: about 4 µs a line
    /// per target. The `i32` above admits two billion, and a `count` of
    /// 2000000000 ran for hours where it should have been refused. 65536
    /// sixteenths is 4096 bars of `[4 4]`, 65536 bars at 120 qpm is a
    /// day and a half; a nudge that wants more is not a nudge, and
    /// `fromJson` refuses it by name.
    pub const max_steps: i32 = 1 << 16;
};

pub const Nudge = struct { sel: Select, delta: Delta };

pub const Transpose = struct { sel: Select, semitones: i8 };

/// Scale `[from, to)` by `p/q`, and shift what follows by the growth.
pub const Stretch = struct {
    from: i64,
    to: i64,
    p: u32,
    q: u32,
};

pub const InsertTempo = struct {
    point: doc.TempoPoint,
    /// `musical` keeps every musical position where it is (a tempo
    /// change never moves a bar line, plan 03). `wall_clock` keeps every
    /// event's SECONDS instead, and retimes the document after the point
    /// to do it — lossy by construction, counted, and opt-in.
    mode: enum { musical, wall_clock } = .musical,
};

pub const InsertMeter = struct { point: doc.MeterPoint };

/// What a name belongs to. Each one has its own cross-refs, and renaming
/// follows them.
pub const Renamed = enum { lane, section, phrase, target, anchor };

pub const Rename = struct {
    what: Renamed,
    from: []const u8,
    to: []const u8,
};

pub const Bind = struct {
    lane: []const u8,
    anchor: []const u8,
    address: doc.Address,
};

pub const Unbind = struct { lane: []const u8 };

/// Copy a bound lane's content into the document and take it out of the
/// anchor's file — plan 07's `materialize`, which is plan 04's "one
/// home" made into an operation.
pub const Materialize = struct { lane: []const u8 };

/// Every operation of plan 07's table that acts on native content.
pub const Op = union(enum) {
    insert: Insert,
    remove: Remove,
    retime: Retime,
    revalue: Revalue,
    ease: Ease,
    resize: Resize,
    velocity: Velocity,
    split: Split,
    merge: Merge,
    duplicate: Duplicate,
    quantize: Quantize,
    nudge: Nudge,
    transpose: Transpose,
    stretch: Stretch,
    insert_tempo: InsertTempo,
    insert_meter: InsertMeter,
    rename: Rename,
    bind: Bind,
    unbind: Unbind,
    materialize: Materialize,

    /// The first tick this operation NAMES that is off the grid, or null.
    ///
    /// Plan 03: `MAX_TICK = 2^53`, and "past it is a `tick_overflow`
    /// diagnostic, never a wrap". This is that rule over an operation's
    /// own numbers — one place, so no operation can be added without
    /// it, and checked at plan entry so the refusal arrives before any
    /// work: a `{"from":-9223372036854775808}` used to reach
    /// `ops_native.stretched` and overflow there, and a
    /// `{"delta":9223372036854775807}` used to plan an `:at` that the
    /// document could not load back (plan 07's contract is that an
    /// accepted plan is applicable).
    ///
    /// SELECTION ranges are deliberately not here: a `:range` only
    /// filters what is already in the document and lands nothing, so
    /// `[0 maxInt]` is "everything from the start" and not a position.
    /// A `count` of steps is not here either — it is a number of grid
    /// LINES, and `ops_quantize.nudged` walks them with `+|`; its own
    /// bound is `Delta.max_steps`, checked where the count is read.
    ///
    /// Destinations the plan COMPUTES are bounded separately, where they
    /// become text (`ops_native.Ctx.positionJson`): the two halves
    /// together are what make an accepted plan applicable.
    pub fn offGrid(self: Op) ?i64 {
        return switch (self) {
            .insert => |x| switch (x.what) {
                .note => |n| off(n.at) orelse off(n.dur),
                .keyframe => |k| off(k.at),
                .clip => |c| off(c.at) orelse offOpt(c.offset) orelse offOpt(c.length),
                .section => |s| off(s.at) orelse off(s.dur),
                .cue => |c| off(c.at),
                .phrase => |p| off(p.length),
                .lane => null,
            },
            .retime => |x| offOpt(x.delta) orelse offOpt(x.to),
            .resize => |x| offOpt(x.dur),
            .split => |x| off(x.at),
            .duplicate => |x| offOpt(x.delta) orelse offOpt(x.to),
            .nudge => |x| switch (x.delta) {
                .ticks => |d| off(d),
                .steps => null,
            },
            .stretch => |x| off(x.from) orelse off(x.to),
            .insert_tempo => |x| off(x.point.tick),
            .insert_meter => |x| off(x.point.tick),
            .remove,
            .revalue,
            .ease,
            .velocity,
            .merge,
            .quantize,
            .transpose,
            .rename,
            .bind,
            .unbind,
            .materialize,
            => null,
        };
    }
};

/// `v` when it is off the grid, null when it is on it. `@abs` on an
/// `i64` answers a `u64`, so `minInt` has a magnitude here rather than
/// an overflow.
fn off(v: i64) ?i64 {
    return if (@abs(v) > Grid.MAX_TICK) v else null;
}

fn offOpt(v: ?i64) ?i64 {
    return off(v orelse return null);
}

/// What `fromJson` answers: the operation, or the reasons it is not one.
pub const Parsed = struct {
    op: ?Op,
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
        self.diags.deinit();
        self.* = undefined;
    }
};

/// Read one operation from the CLI's `--op '<json>'` spelling.
///
/// The grammar is in this file's header. Every way the text can fail to
/// be an operation is a DIAGNOSTIC on the returned value and never an
/// error: `--op` is user input like any other, and a host shows the
/// complaint rather than catching an exception. The code is
/// `sjon_diagnostic`, tempura's one carrier for a complaint that belongs
/// to another vocabulary — here JSON's and this grammar's, neither of
/// which has a tempura code of its own.
///
/// Every string the operation holds is copied into the returned arena,
/// so the caller's `text` need not outlive the call.
pub fn fromJson(gpa: std.mem.Allocator, text: []const u8) Error!Parsed {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var reader: Reader = .{
        .arena = arena.allocator(),
        .diags = &diags,
        .span = .{ .start = 0, .end = @intCast(text.len) },
    };

    var json = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try reader.fail("the operation is not JSON: {s}", .{@errorName(e)});
            return .{ .op = null, .diags = diags, .arena = arena };
        },
    };
    defer json.deinit();

    const op = try reader.op(json.value);
    // A number no field of the grammar can hold is a REFUSAL, not a
    // saturation: `{"at":1e30}` means nothing, and quietly editing at
    // `maxInt(i64)` — or at the default the field would otherwise take —
    // would move somebody's notes somewhere they never asked for. The
    // reason is collected rather than raised where it is met, because
    // every one of those casts sits inside a struct literal with no room
    // for a diagnostic; this is the one funnel every operation passes.
    if (reader.out_of_range) |x| {
        try reader.fail(
            "{d} is outside the range the field it was written for can hold; this operation " ++
                "names no edit",
            .{x},
        );
        return .{ .op = null, .diags = diags, .arena = arena };
    }
    // The same funnel for a number that is not one: `{"at":"4q"}` read
    // as the field's default — tick 0 — and inserted a point nobody
    // asked for there. A position in this grammar is an integer tick
    // (the CLI's `at` verb spells one from a literal); a string is
    // refused, not defaulted. Only when the operation otherwise read,
    // so one malformed text keeps giving one complaint.
    if (op != null) if (reader.mistyped) |what| {
        try reader.fail(
            "a {s} was written where this operation wants a number (a position is an integer " ++
                "tick; 4q is 184504320); this operation names no edit",
            .{what},
        );
        return .{ .op = null, .diags = diags, .arena = arena };
    };
    // Every reader that answers null has said why first, and none says
    // anything about an operation it then returns.
    std.debug.assert((op == null) == diags.hasErrors());
    return .{ .op = op, .diags = diags, .arena = arena };
}

/// The decode, one field at a time. Everything it cannot read it says so
/// about and answers null, so one malformed operation gives one
/// complaint and no half-built value.
const Reader = struct {
    /// The `Parsed` arena: every string the operation holds is copied
    /// here and lives until the caller's `Parsed.deinit`.
    arena: std.mem.Allocator,
    diags: *Diag.List,
    span: Diag.Span,
    /// The first user number that no field of the grammar could hold — a
    /// float past `i64` (`{"at":1e30}`) or an integer past the `u32` /
    /// `i32` / `u16` a field narrows to (`{"repeat":5000000000}`).
    ///
    /// Recorded here and refused ONCE, in `fromJson`: `int` and `narrow`
    /// are called from inside struct literals that have nowhere to put a
    /// diagnostic, and a cast that panicked on user input was the whole
    /// defect (`root.zig`: "user input is never asserted on").
    out_of_range: ?f64 = null,
    /// The JSON type of the first value that reached `int` and was not
    /// a number at all — `"4q"` where a tick goes. Recorded and refused
    /// as `out_of_range` is: the field's DEFAULT is not what was asked
    /// for either.
    mistyped: ?[]const u8 = null,

    fn fail(self: *Reader, comptime fmt: []const u8, args: anytype) Error!void {
        try self.diags.add(.sjon_diagnostic, .err, self.span, fmt, args);
    }

    /// One operation's reader: the JSON object under `"op"` to the
    /// payload that name means, or null after a `fail`.
    const ReadFn = *const fn (*Reader, std.json.ObjectMap) Error!?Op;

    /// Plan 07's table, one row per name the grammar spells. `op` walks
    /// it and nothing else decides which reader a name has; the names
    /// are distinct, so the order is the header's and not a precedence.
    const readers = [_]struct { name: []const u8, read: ReadFn }{
        .{ .name = "insert", .read = &insert },
        .{ .name = "remove", .read = &remove },
        .{ .name = "retime", .read = &retime },
        .{ .name = "revalue", .read = &revalue },
        .{ .name = "ease", .read = &ease },
        .{ .name = "resize", .read = &resize },
        .{ .name = "velocity", .read = &velocity },
        .{ .name = "split", .read = &split },
        .{ .name = "merge", .read = &merge },
        .{ .name = "duplicate", .read = &duplicate },
        .{ .name = "quantize", .read = &quantize },
        .{ .name = "nudge", .read = &nudge },
        .{ .name = "transpose", .read = &transpose },
        .{ .name = "stretch", .read = &stretch },
        .{ .name = "insert-tempo", .read = &insertTempo },
        .{ .name = "insert-meter", .read = &insertMeter },
        .{ .name = "rename", .read = &rename },
        .{ .name = "bind", .read = &bind },
        .{ .name = "unbind", .read = &unbind },
        .{ .name = "materialize", .read = &materialize },
    };

    /// The dispatch: the object, its `"op"`, and the one reader that
    /// name has. Every reader takes the whole object, because each
    /// operation's keys sit beside `"op"` and not under it.
    fn op(self: *Reader, v: std.json.Value) Error!?Op {
        const o = switch (v) {
            .object => |o| o,
            else => {
                try self.fail("an operation is a JSON object", .{});
                return null;
            },
        };
        const name = try self.str(o.get("op") orelse {
            try self.fail("the operation has no \"op\"", .{});
            return null;
        }) orelse {
            try self.fail("\"op\" is the operation's name, as a string", .{});
            return null;
        };
        for (readers) |r| {
            if (eql(name, r.name)) return try r.read(self, o);
        }
        try self.fail("no operation is called {s}", .{name});
        return null;
    }

    // ---- one reader per operation ----

    fn remove(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        return .{ .remove = .{
            .sel = try self.select(o.get("sel")),
            .allow_shared = self.optBool(o.get("allow-shared")) orelse false,
        } };
    }

    fn retime(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const sel = try self.select(o.get("sel"));
        const delta = self.optInt(o.get("delta"));
        const to = self.optInt(o.get("to"));
        if (delta == null and to == null) {
            try self.fail("retime wants a \"delta\" or a \"to\", in ticks", .{});
            return null;
        }
        return .{ .retime = .{
            .sel = sel,
            .delta = delta,
            .to = to,
            .allow_shared = self.optBool(o.get("allow-shared")) orelse false,
        } };
    }

    fn revalue(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const got = self.components(o.get("value")) orelse {
            try self.fail("revalue wants a \"value\": a number or one to four of them", .{});
            return null;
        };
        return .{ .revalue = .{
            .sel = try self.select(o.get("sel")),
            .value = got.value,
            .ncomp = got.ncomp,
        } };
    }

    fn ease(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        return .{ .ease = .{
            .sel = try self.select(o.get("sel")),
            .ease = try self.str(o.get("ease") orelse .null) orelse {
                try self.fail("ease wants an \"ease\": a pacer easing, as SJON text", .{});
                return null;
            },
        } };
    }

    fn resize(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const sel = try self.select(o.get("sel"));
        const dur = self.optInt(o.get("dur"));
        const repeat = self.optInt(o.get("repeat"));
        return .{ .resize = .{
            .sel = sel,
            .dur = dur,
            .repeat = if (repeat) |r| self.narrow(u32, @max(1, r), 1) else null,
        } };
    }

    fn velocity(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        return .{ .velocity = .{
            .sel = try self.select(o.get("sel")),
            .vel = @intCast(std.math.clamp(self.optInt(o.get("vel")) orelse 100, 1, 127)),
            .allow_shared = self.optBool(o.get("allow-shared")) orelse false,
        } };
    }

    fn split(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        return .{ .split = .{
            .sel = try self.select(o.get("sel")),
            .at = self.optInt(o.get("at")) orelse {
                try self.fail("split wants an \"at\": the tick to split at", .{});
                return null;
            },
        } };
    }

    fn merge(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        return .{ .merge = .{ .sel = try self.select(o.get("sel")) } };
    }

    fn duplicate(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const sel = try self.select(o.get("sel"));
        const delta = self.optInt(o.get("delta"));
        const to = self.optInt(o.get("to"));
        if (delta == null and to == null) {
            try self.fail("duplicate wants a \"delta\" or a \"to\", in ticks", .{});
            return null;
        }
        return .{ .duplicate = .{ .sel = sel, .delta = delta, .to = to } };
    }

    fn quantize(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        return .{ .quantize = .{
            .sel = try self.select(o.get("sel")),
            .grid = try self.grid(o.get("grid")) orelse return null,
            .strength = self.fraction(o.get("strength"), 1, 0, 1),
            .swing = self.fraction(o.get("swing"), 0, -1, 1),
            .dur_too = self.optBool(o.get("dur-too")) orelse false,
        } };
    }

    fn nudge(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const sel = try self.select(o.get("sel"));
        if (self.optInt(o.get("ticks"))) |ticks| {
            return .{ .nudge = .{ .sel = sel, .delta = .{ .ticks = ticks } } };
        }
        const g = try self.grid(o.get("grid")) orelse return null;
        const count = self.narrow(i32, self.optInt(o.get("count")) orelse 1, 1);
        // The bound is the walk's, not the field's (`Delta.max_steps`);
        // a number the field cannot hold went through `out_of_range`
        // above and is refused by the funnel in `fromJson`.
        if (count > Delta.max_steps or count < -Delta.max_steps) {
            try self.fail(
                "a nudge of {d} steps is refused: the walk counts grid lines one by one " ++
                    "and stops at {d} either way",
                .{ count, Delta.max_steps },
            );
            return null;
        }
        return .{ .nudge = .{ .sel = sel, .delta = .{ .steps = .{
            .grid = g,
            .count = count,
        } } } };
    }

    fn transpose(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const sel = try self.select(o.get("sel"));
        const semitones = self.optInt(o.get("semitones")) orelse 0;
        return .{ .transpose = .{
            .sel = sel,
            .semitones = @intCast(std.math.clamp(semitones, -127, 127)),
        } };
    }

    fn stretch(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        return .{ .stretch = .{
            .from = self.optInt(o.get("from")) orelse 0,
            .to = self.optInt(o.get("to")) orelse 0,
            .p = self.narrow(u32, @max(0, self.optInt(o.get("p")) orelse 0), 0),
            .q = self.narrow(u32, @max(0, self.optInt(o.get("q")) orelse 0), 0),
        } };
    }

    fn insertTempo(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const at = self.optInt(o.get("at")) orelse 0;
        const tempo: @FieldType(doc.TempoPoint, "tempo") = if (self.optInt(o.get("us"))) |us|
            .{ .us = @intCast(std.math.clamp(us, 1, 16_777_215)) }
        else if (self.real(o.get("qpm"))) |qpm|
            .{ .qpm = qpm }
        else {
            try self.fail("insert-tempo wants a \"us\" or a \"qpm\"", .{});
            return null;
        };
        const mode = try self.str(o.get("mode") orelse .null) orelse "musical";
        return .{ .insert_tempo = .{
            .point = .{ .tick = at, .tempo = tempo },
            .mode = if (eql(mode, "wall-clock")) .wall_clock else .musical,
        } };
    }

    fn insertMeter(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const sig = self.pair(o.get("sig")) orelse {
            try self.fail("insert-meter wants a \"sig\": [n d]", .{});
            return null;
        };
        return .{ .insert_meter = .{ .point = .{
            .tick = self.optInt(o.get("at")) orelse 0,
            .n = @intCast(std.math.clamp(sig[0], 1, 64)),
            .d = @intCast(std.math.clamp(sig[1], 1, 64)),
        } } };
    }

    fn rename(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const what = try self.str(o.get("what") orelse .null) orelse "";
        const which = std.meta.stringToEnum(Renamed, what) orelse {
            try self.fail(
                "rename wants a \"what\": lane, section, phrase, target or anchor",
                .{},
            );
            return null;
        };
        return .{ .rename = .{
            .what = which,
            .from = try self.str(o.get("from") orelse .null) orelse {
                try self.fail("rename wants a \"from\" and a \"to\"", .{});
                return null;
            },
            .to = try self.str(o.get("to") orelse .null) orelse {
                try self.fail("rename wants a \"from\" and a \"to\"", .{});
                return null;
            },
        } };
    }

    fn bind(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const lane = try self.str(o.get("lane") orelse .null) orelse {
            try self.fail("bind wants a \"lane\"", .{});
            return null;
        };
        const anchor = try self.str(o.get("anchor") orelse .null) orelse {
            try self.fail("bind wants an \"anchor\"", .{});
            return null;
        };
        const where = try self.address(o) orelse return null;
        return .{ .bind = .{ .lane = lane, .anchor = anchor, .address = where } };
    }

    fn unbind(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        return .{ .unbind = .{
            .lane = try self.str(o.get("lane") orelse .null) orelse {
                try self.fail("unbind wants a \"lane\"", .{});
                return null;
            },
        } };
    }

    fn materialize(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        return .{ .materialize = .{
            .lane = try self.str(o.get("lane") orelse .null) orelse {
                try self.fail("materialize wants a \"lane\"", .{});
                return null;
            },
        } };
    }

    // ---- insert, and one reader per thing it can put somewhere ----

    fn insert(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const lane = try self.str(o.get("lane") orelse .null);
        inline for (@typeInfo(New).@"union".fields) |field| {
            if (o.get(field.name)) |v| {
                const what = try self.newOf(@field(NewTag, field.name), v) orelse return null;
                return .{ .insert = .{ .lane = lane, .what = what } };
            }
        }
        try self.fail(
            "insert wants one of: note, keyframe, clip, section, cue, lane, phrase",
            .{},
        );
        return null;
    }

    const NewTag = std.meta.Tag(New);

    /// The thing an `insert` carries, by the key it came under. The
    /// object check is here, once; each shape's own reader takes the
    /// object.
    fn newOf(self: *Reader, comptime tag: NewTag, v: std.json.Value) Error!?New {
        const o = switch (v) {
            .object => |o| o,
            else => {
                try self.fail("a {s} to insert is a JSON object", .{@tagName(tag)});
                return null;
            },
        };
        return switch (tag) {
            .note => try self.newNote(o),
            .keyframe => try self.newKeyframe(o),
            .clip => try self.newClip(o),
            .section => try self.newSection(o),
            .cue => try self.newCue(o),
            .lane => try self.newLane(o),
            .phrase => try self.newPhrase(o),
        };
    }

    fn newNote(self: *Reader, o: std.json.ObjectMap) Error!?New {
        const at = self.optInt(o.get("at")) orelse 0;
        const dur = self.optInt(o.get("dur")) orelse 0;
        const key = self.optInt(o.get("key")) orelse 60;
        const vel = self.optInt(o.get("vel"));
        // `:ch 1` is channel 0 — the wire numbering a `Doc` keeps.
        const ch = self.optInt(o.get("ch"));
        const off_vel = self.optInt(o.get("off-vel"));
        return .{ .note = .{
            .at = at,
            .dur = dur,
            .key = @intCast(std.math.clamp(key, 0, 127)),
            .vel = if (vel) |x| @intCast(std.math.clamp(x, 1, 127)) else null,
            .ch = if (ch) |x| wireOf(u4, x) else null,
            .off_vel = if (off_vel) |x| @intCast(std.math.clamp(x, 0, 127)) else null,
        } };
    }

    fn newKeyframe(self: *Reader, o: std.json.ObjectMap) Error!?New {
        const got: Reader.Components = self.components(o.get("value")) orelse
            .{ .value = .{ 0, 0, 0, 0 }, .ncomp = 1 };
        return .{ .keyframe = .{
            .at = self.optInt(o.get("at")) orelse 0,
            .value = got.value,
            .ncomp = got.ncomp,
            .ease = try self.str(o.get("ease") orelse .null),
        } };
    }

    fn newClip(self: *Reader, o: std.json.ObjectMap) Error!?New {
        const at = self.optInt(o.get("at")) orelse 0;
        const phrase = try self.str(o.get("phrase") orelse .null) orelse {
            try self.fail("a clip names its \"phrase\"", .{});
            return null;
        };
        const repeat = self.optInt(o.get("repeat"));
        const offset = self.optInt(o.get("offset"));
        const length = self.optInt(o.get("length"));
        const shift = self.optInt(o.get("transpose"));
        return .{ .clip = .{
            .at = at,
            .phrase = phrase,
            .repeat = if (repeat) |x| self.narrow(u32, @max(1, x), 1) else null,
            .offset = offset,
            .length = length,
            .transpose = if (shift) |x| @intCast(std.math.clamp(x, -120, 120)) else null,
        } };
    }

    fn newSection(self: *Reader, o: std.json.ObjectMap) Error!?New {
        return .{ .section = .{
            .name = try self.str(o.get("name") orelse .null) orelse {
                try self.fail("a section has a \"name\"", .{});
                return null;
            },
            .at = self.optInt(o.get("at")) orelse 0,
            .dur = self.optInt(o.get("dur")) orelse 0,
        } };
    }

    fn newCue(self: *Reader, o: std.json.ObjectMap) Error!?New {
        return .{ .cue = .{
            .name = try self.str(o.get("name") orelse .null) orelse {
                try self.fail("a cue has a \"name\"", .{});
                return null;
            },
            .at = self.optInt(o.get("at")) orelse 0,
        } };
    }

    fn newLane(self: *Reader, o: std.json.ObjectMap) Error!?New {
        const name = try self.str(o.get("name") orelse .null) orelse {
            try self.fail("a lane has a \"name\"", .{});
            return null;
        };
        const kind = try self.str(o.get("kind") orelse .null) orelse "notes";
        return .{ .lane = .{
            .name = name,
            .kind = std.meta.stringToEnum(doc.LaneKind, kind) orelse .notes,
            .target = try self.str(o.get("target") orelse .null),
        } };
    }

    fn newPhrase(self: *Reader, o: std.json.ObjectMap) Error!?New {
        return .{ .phrase = .{
            .name = try self.str(o.get("name") orelse .null) orelse {
                try self.fail("a phrase has a \"name\"", .{});
                return null;
            },
            .length = self.optInt(o.get("length")) orelse 0,
            .lanes = try self.strings(o.get("lanes")),
        } };
    }

    fn address(self: *Reader, o: std.json.ObjectMap) Error!?doc.Address {
        if (o.get("channel")) |v| {
            const column = try self.str(o.get("column") orelse .null);
            const fx = try self.str(o.get("fx") orelse .null);
            return .{ .it = .{
                .channel = wireOf(u6, self.int(v) orelse 1),
                .column = if (column) |c| std.meta.stringToEnum(doc.ItColumn, c) else null,
                .fx = if (fx) |f| (if (f.len > 0) f[0] else null) else null,
            } };
        }
        if (o.get("track")) |v| {
            var curve: ?doc.SmfCurve = null;
            if (o.get("cc")) |cc| {
                if (self.pair(cc)) |two| {
                    curve = .{
                        .cc14 = .{
                            @intCast(std.math.clamp(two[0], 0, 127)),
                            @intCast(std.math.clamp(two[1], 0, 127)),
                        },
                    };
                } else if (self.int(cc)) |n| {
                    curve = .{ .cc = @intCast(std.math.clamp(n, 0, 127)) };
                }
            } else if (self.optBool(o.get("bend")) orelse false) {
                curve = .bend;
            } else if (self.optBool(o.get("pressure")) orelse false) {
                curve = .pressure;
            } else if (self.optBool(o.get("velocity")) orelse false) {
                curve = .velocity;
            }
            const chs = self.channels(o.get("ch")) orelse {
                try self.fail(
                    "bind's \"ch\" is a channel 1..16, or an array of distinct ones",
                    .{},
                );
                return null;
            };
            return .{ .smf = .{
                .track = @intCast(std.math.clamp(self.int(v) orelse 1, 1, 65535)),
                .ch = chs,
                .key = if (self.optInt(
                    o.get("key"),
                )) |k| @intCast(std.math.clamp(k, 0, 127)) else null,
                .curve = curve,
            } };
        }
        try self.fail(
            "bind wants an address: \"track\" (and \"ch\") for a .mid anchor, \"channel\" for a " ++
                ".it one",
            .{},
        );
        return null;
    }

    /// A bound SMF lane's channels — the JSON spelling of `:ch 2` /
    /// `:ch [1 2]`: one number, or an array of them, each clamped into
    /// 1..16 the way a single one always was. Absent is channel 1. An
    /// empty array, a repeated channel or a non-number in the array is
    /// not an address and answers null.
    fn channels(self: *Reader, v: ?std.json.Value) ?doc.Channels {
        const value = v orelse return .single(0);
        switch (value) {
            .array => |arr| {
                if (arr.items.len == 0) return null;
                var set: doc.Channels = .none;
                for (arr.items) |item| {
                    const n = self.int(item) orelse return null;
                    const c: u4 = wireOf(u4, n);
                    if (set.has(c)) return null;
                    set = set.with(c);
                }
                return set;
            },
            else => return .single(wireOf(u4, self.int(value) orelse 1)),
        }
    }

    fn select(self: *Reader, v: ?std.json.Value) Error!Select {
        const o = switch (v orelse .null) {
            .object => |o| o,
            // No selection at all is every lane, every tick, every kind:
            // the question an editor asks when nothing is selected.
            else => return .{},
        };
        var sel: Select = .{
            .lanes = if (o.get("lanes")) |lanes| try self.strings(lanes) else null,
            .keys = null,
            .range = null,
        };
        if (o.get("range")) |r| {
            if (self.pair(r)) |two| sel.range = .{ two[0], two[1] };
        }
        if (o.get("keys")) |keys| {
            if (keys == .array) {
                const out = try self.arena.alloc(u7, keys.array.items.len);
                for (keys.array.items, out) |item, *slot| {
                    slot.* = @intCast(std.math.clamp(self.int(item) orelse 0, 0, 127));
                }
                sel.keys = out;
            }
        }
        if (o.get("kinds")) |kinds| {
            var set: Kinds = .{};
            if (kinds == .array) {
                for (kinds.array.items) |item| {
                    const name = try self.str(item) orelse continue;
                    if (std.meta.stringToEnum(Kind, name)) |kind| switch (kind) {
                        .note => set.note = true,
                        .keyframe => set.keyframe = true,
                        .clip => set.clip = true,
                        .section => set.section = true,
                        .cue => set.cue = true,
                    };
                }
            }
            sel.kinds = if (set.any()) set else .all;
        }
        return sel;
    }

    fn grid(self: *Reader, v: ?std.json.Value) Error!?Snap.Grid {
        const text = try self.str(v orelse .null) orelse {
            try self.fail(
                "this operation wants a \"grid\": 1/4, 1/8, 1/12, 1/16, 1/32, 1bar or 1b",
                .{},
            );
            return null;
        };
        return Snap.Grid.parse(text) orelse {
            try self.fail("{s} is not a grid: 1/4, 1/8, 1/12, 1/16, 1/32, 1bar or 1b", .{text});
            return null;
        };
    }

    // ---- the leaves ----

    /// A JSON string, copied into the arena so the caller's text need
    /// not outlive the call. Running out of memory is an ERROR and never
    /// a "this was not a string": a plan that quietly dropped a lane's
    /// name under memory pressure would edit the wrong lane.
    fn str(self: *Reader, v: std.json.Value) Error!?[]const u8 {
        return switch (v) {
            .string => |text| try self.arena.dupe(u8, text),
            else => null,
        };
    }

    fn strings(self: *Reader, v: ?std.json.Value) Error![]const []const u8 {
        const arr = switch (v orelse .null) {
            .array => |a| a.items,
            else => return &.{},
        };
        var out: std.ArrayList([]const u8) = .empty;
        for (arr) |item| {
            const one = try self.str(item) orelse continue;
            try out.append(self.arena, one);
        }
        return out.toOwnedSlice(self.arena);
    }

    /// One JSON number as a tick. The ONE place a float becomes an i64
    /// in this grammar, and every operation's every integer field goes
    /// through it.
    ///
    /// `2^63` as an f64 is exact, so `@abs(f) < 2^63` is precisely the
    /// domain `@intFromFloat(@trunc(f))` has: anything at or past it —
    /// `1e30`, an infinity, a NaN — is recorded in `out_of_range` and
    /// refused by `fromJson` rather than truncated into whatever the
    /// bit pattern happens to be.
    fn int(self: *Reader, v: std.json.Value) ?i64 {
        switch (v) {
            .integer => |n| return n,
            .float => |f| {
                if (std.math.isFinite(f) and @abs(f) < 9_223_372_036_854_775_808.0) {
                    return @intFromFloat(@trunc(f));
                }
                if (self.out_of_range == null) self.out_of_range = f;
                return null;
            },
            // An explicit null is the field left out.
            .null => return null,
            // A string, a bool, an array or an object where a number
            // goes: recorded, and refused once by `fromJson`.
            else => {
                if (self.mistyped == null) self.mistyped = @tagName(v);
                return null;
            },
        }
    }

    /// One tick narrowed to the field that holds it — `:repeat`'s `u32`,
    /// `:count`'s `i32`, a ratio's `u32`.
    ///
    /// `std.math.cast` or a refusal: a `@intCast` here was a panic
    /// waiting for `{"repeat":5000000000}`, and a CLAMP would be a
    /// different edit than the one that was asked for (`:repeat
    /// 5000000000` is not `:repeat 4294967295`). The fallback is only
    /// ever the value the refused operation never reaches production
    /// with.
    fn narrow(self: *Reader, comptime T: type, v: i64, fallback: T) T {
        return std.math.cast(T, v) orelse {
            if (self.out_of_range == null) self.out_of_range = @floatFromInt(v);
            return fallback;
        };
    }

    /// A user fraction clamped onto the range its rule is defined over —
    /// `:strength` in 0..1, `:swing` in −1..1.
    ///
    /// Clamping IS the rule here, unlike `narrow`: a swing past ±1 is
    /// not a different edit, it is the same shuffle asked for too
    /// loudly, and the grid it offsets has no line past one step. NaN
    /// takes the fallback, which `std.math.clamp` alone would let
    /// through.
    fn fraction(self: *Reader, v: ?std.json.Value, fallback: f64, lo: f64, hi: f64) f64 {
        const x = self.optFloat(v) orelse return fallback;
        if (std.math.isNan(x)) return fallback;
        return std.math.clamp(x, lo, hi);
    }

    fn optInt(self: *Reader, v: ?std.json.Value) ?i64 {
        return self.int(v orelse return null);
    }

    fn optFloat(_: *Reader, v: ?std.json.Value) ?f64 {
        return switch (v orelse return null) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            else => null,
        };
    }

    fn optBool(self: *Reader, v: ?std.json.Value) ?bool {
        _ = self;
        return switch (v orelse return null) {
            .bool => |b| b,
            else => null,
        };
    }

    /// A two-element integer array — a `[n d]` signature, a `[from to)`
    /// range, a 14-bit controller pair.
    fn pair(self: *Reader, v: ?std.json.Value) ?[2]i64 {
        const arr = switch (v orelse return null) {
            .array => |a| a.items,
            else => return null,
        };
        if (arr.len != 2) return null;
        return .{ self.int(arr[0]) orelse return null, self.int(arr[1]) orelse return null };
    }

    /// What `components` answers: a keyframe value and how many of it
    /// the document spells.
    const Components = struct { value: [4]f32, ncomp: u3 };

    /// A scalar or a one-to-four component vector.
    fn components(self: *Reader, v: ?std.json.Value) ?Components {
        var out: [4]f32 = .{ 0, 0, 0, 0 };
        switch (v orelse return null) {
            .array => |arr| {
                if (arr.items.len == 0 or arr.items.len > 4) return null;
                for (arr.items, 0..) |item, i| {
                    out[i] = @floatCast(self.real(item) orelse return null);
                }
                return .{ .value = out, .ncomp = @intCast(arr.items.len) };
            },
            else => |scalar| {
                out[0] = @floatCast(self.real(scalar) orelse return null);
                return .{ .value = out, .ncomp = 1 };
            },
        }
    }

    /// One JSON number the document will spell as an f32 — a keyframe
    /// component, a `:qpm` (`value.float` writes both). The number is
    /// kept as read; what is checked is its f32. Past f32's range
    /// (`1e39`), or not finite at all (`1e999`, which std.json reads as
    /// an infinity), that f32 is an infinity, which prints `inf`: not
    /// JSON, so the plan carrying it was accepted here and then met
    /// `apply`'s re-parse as `unreachable`. Recorded in `out_of_range`
    /// and refused once by `fromJson`, as `int` records a float past
    /// `i64`.
    fn real(self: *Reader, v: ?std.json.Value) ?f64 {
        const x = self.optFloat(v) orelse return null;
        const narrowed: f32 = @floatCast(x);
        if (std.math.isFinite(narrowed)) return x;
        if (self.out_of_range == null) self.out_of_range = x;
        return null;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A channel as a musician counts it (`1` is the first) to the wire's
/// numbering, `T`'s whole range: `u4` for a MIDI channel, `u6` for an
/// Impulse Tracker one. Clamped into `1..2^bits` BEFORE the subtraction,
/// because `x` is any JSON integer and `minInt(i64) - 1` overflows; for
/// every other `x` this is the `clamp(x - 1, 0, 2^bits - 1)` it replaces.
fn wireOf(comptime T: type, x: i64) T {
    const count: i64 = std.math.maxInt(T) + 1;
    return @intCast(std.math.clamp(x, 1, count) - 1);
}

/// A bound SMF lane's channels as the JSON value a `:ch` edit action
/// carries — `2` for one channel, `[1,2]` for a set — the inverse of
/// `Reader.channels`, and the spelling `ops_native.zig`'s `bind` writes.
/// The slice is the caller's to free with `gpa`.
pub fn channelsJson(gpa: std.mem.Allocator, chs: doc.Channels) Error![]const u8 {
    if (chs.count() == 1) return std.fmt.allocPrint(gpa, "{d}", .{@as(u8, chs.first()) + 1});
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '[');
    var it = chs.iterator();
    var sep = false;
    while (it.next()) |c| {
        if (sep) try out.append(gpa, ',');
        sep = true;
        try out.print(gpa, "{d}", .{@as(u8, c) + 1});
    }
    try out.append(gpa, ']');
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------

fn parsed(text: []const u8) !Parsed {
    var p = try fromJson(testing.allocator, text);
    errdefer p.deinit();
    if (p.op == null) {
        for (p.diags.items()) |d| std.debug.print("fromJson: {s}\n", .{d.message});
        return error.NotAnOperation;
    }
    return p;
}

test "Op.fromJson: a selection, and the three ops that only carry one" {
    var p = try parsed(
        \\{"op":"remove","sel":{"lanes":["flash","glow"],"range":[0,184504320],"kinds":["note","clip"],"keys":[36]}}
    );
    defer p.deinit();

    const sel = p.op.?.remove.sel;
    try testing.expectEqual(@as(usize, 2), sel.lanes.?.len);
    try testing.expectEqualStrings("flash", sel.lanes.?[0]);
    try testing.expectEqualStrings("glow", sel.lanes.?[1]);
    try testing.expectEqual([2]i64{ 0, 184504320 }, sel.range.?);
    try testing.expect(sel.kinds.note and sel.kinds.clip);
    try testing.expect(!sel.kinds.keyframe and !sel.kinds.section);
    try testing.expectEqualSlices(u7, &.{36}, sel.keys.?);

    var q = try parsed(
        \\{"op":"merge","sel":{}}
    );
    defer q.deinit();
    try testing.expect(q.op.?.merge.sel.lanes == null);
    // An omitted `kinds` is every kind, which is what a rubber band over
    // a document means.
    try testing.expect(q.op.?.merge.sel.kinds.cue);
}

test "Op.fromJson: the payload of every operation the CLI can spell" {
    {
        var p = try parsed(
            \\{"op":"insert","lane":"flash","note":{"at":46126080,"dur":23063040,"key":40,"vel":100,"ch":1}}
        );
        defer p.deinit();
        const x = p.op.?.insert;
        try testing.expectEqualStrings("flash", x.lane.?);
        try testing.expectEqual(@as(i64, 46126080), x.what.note.at);
        try testing.expectEqual(@as(u7, 40), x.what.note.key);
        try testing.expectEqual(@as(u7, 100), x.what.note.vel.?);
        // Channels are on the wire in a `Doc`, as `:ch 1` is channel 0.
        try testing.expectEqual(@as(u4, 0), x.what.note.ch.?);
    }
    {
        var p = try parsed(
            \\{"op":"insert","cue":{"name":"the drop","at":184504320}}
        );
        defer p.deinit();
        try testing.expectEqualStrings("the drop", p.op.?.insert.what.cue.name);
    }
    {
        var p = try parsed(
            \\{"op":"retime","sel":{},"delta":-46126080}
        );
        defer p.deinit();
        try testing.expectEqual(@as(i64, -46126080), p.op.?.retime.delta.?);
        try testing.expect(p.op.?.retime.to == null);
    }
    {
        var p = try parsed(
            \\{"op":"revalue","sel":{},"value":[0.1,0.2,0.3]}
        );
        defer p.deinit();
        try testing.expectEqual(@as(u3, 3), p.op.?.revalue.ncomp);
        try testing.expectEqual(@as(f32, 0.2), p.op.?.revalue.value[1]);
    }
    {
        var p = try parsed(
            \\{"op":"ease","sel":{},"ease":"(spring :damping 0.5)"}
        );
        defer p.deinit();
        try testing.expectEqualStrings("(spring :damping 0.5)", p.op.?.ease.ease);
    }
    {
        var p = try parsed(
            \\{"op":"resize","sel":{},"dur":46126080,"repeat":3}
        );
        defer p.deinit();
        try testing.expectEqual(@as(i64, 46126080), p.op.?.resize.dur.?);
        try testing.expectEqual(@as(u32, 3), p.op.?.resize.repeat.?);
    }
    {
        var p = try parsed(
            \\{"op":"velocity","sel":{},"vel":64}
        );
        defer p.deinit();
        try testing.expectEqual(@as(u7, 64), p.op.?.velocity.vel);
    }
    {
        var p = try parsed(
            \\{"op":"split","sel":{},"at":184504320}
        );
        defer p.deinit();
        try testing.expectEqual(@as(i64, 184504320), p.op.?.split.at);
    }
    {
        var p = try parsed(
            \\{"op":"duplicate","sel":{},"to":184504320}
        );
        defer p.deinit();
        try testing.expectEqual(@as(i64, 184504320), p.op.?.duplicate.to.?);
    }
    {
        var p = try parsed(
            \\{"op":"quantize","sel":{},"grid":"1/8","strength":0.5,"swing":0.25,"dur-too":true}
        );
        defer p.deinit();
        const x = p.op.?.quantize;
        try testing.expectEqual(Snap.Grid{ .div = 8 }, x.grid);
        try testing.expectEqual(@as(f64, 0.5), x.strength);
        try testing.expectEqual(@as(f64, 0.25), x.swing);
        try testing.expect(x.dur_too);
    }
    {
        var p = try parsed(
            \\{"op":"nudge","sel":{},"grid":"1bar","count":-2}
        );
        defer p.deinit();
        try testing.expectEqual(Snap.Grid.bar, p.op.?.nudge.delta.steps.grid);
        try testing.expectEqual(@as(i32, -2), p.op.?.nudge.delta.steps.count);

        var q = try parsed(
            \\{"op":"nudge","sel":{},"ticks":-120}
        );
        defer q.deinit();
        try testing.expectEqual(@as(i64, -120), q.op.?.nudge.delta.ticks);
    }
    {
        var p = try parsed(
            \\{"op":"transpose","sel":{},"semitones":-12}
        );
        defer p.deinit();
        try testing.expectEqual(@as(i8, -12), p.op.?.transpose.semitones);
    }
    {
        var p = try parsed(
            \\{"op":"stretch","from":0,"to":184504320,"p":3,"q":2}
        );
        defer p.deinit();
        try testing.expectEqual(@as(u32, 3), p.op.?.stretch.p);
        try testing.expectEqual(@as(u32, 2), p.op.?.stretch.q);
    }
    {
        var p = try parsed(
            \\{"op":"insert-tempo","at":184504320,"qpm":140,"mode":"wall-clock"}
        );
        defer p.deinit();
        try testing.expectEqual(@as(i64, 184504320), p.op.?.insert_tempo.point.tick);
        try testing.expectEqual(@as(f64, 140), p.op.?.insert_tempo.point.tempo.qpm);
        try testing.expectEqual(
            @as(@TypeOf(p.op.?.insert_tempo.mode), .wall_clock),
            p.op.?.insert_tempo.mode,
        );

        var q = try parsed(
            \\{"op":"insert-tempo","at":0,"us":500000}
        );
        defer q.deinit();
        try testing.expectEqual(@as(u32, 500000), q.op.?.insert_tempo.point.tempo.us);
        try testing.expectEqual(
            @as(@TypeOf(q.op.?.insert_tempo.mode), .musical),
            q.op.?.insert_tempo.mode,
        );
    }
    {
        var p = try parsed(
            \\{"op":"insert-meter","at":184504320,"sig":[3,4]}
        );
        defer p.deinit();
        try testing.expectEqual(@as(u8, 3), p.op.?.insert_meter.point.n);
        try testing.expectEqual(@as(u8, 4), p.op.?.insert_meter.point.d);
    }
    {
        var p = try parsed(
            \\{"op":"rename","what":"phrase","from":"fill","to":"roll"}
        );
        defer p.deinit();
        try testing.expectEqual(Renamed.phrase, p.op.?.rename.what);
        try testing.expectEqualStrings("roll", p.op.?.rename.to);
    }
    {
        var p = try parsed(
            \\{"op":"bind","lane":"pad","anchor":"song","track":1,"ch":2,"key":36}
        );
        defer p.deinit();
        const addr = p.op.?.bind.address.smf;
        try testing.expectEqual(@as(u16, 1), addr.track);
        try testing.expect(addr.ch.eql(.single(1)));
        try testing.expectEqual(@as(u7, 36), addr.key.?);

        var q = try parsed(
            \\{"op":"bind","lane":"bass","anchor":"song","channel":5,"column":"vol"}
        );
        defer q.deinit();
        try testing.expectEqual(@as(u6, 4), q.op.?.bind.address.it.channel);
        try testing.expectEqual(doc.ItColumn.vol, q.op.?.bind.address.it.column.?);

        // A channel SET, the JSON spelling of `:ch [1 2]`, and its
        // inverse; an empty or repeating one is refused.
        var s = try parsed(
            \\{"op":"bind","lane":"kit","anchor":"song","track":2,"ch":[2,1]}
        );
        defer s.deinit();
        try testing.expect(s.op.?.bind.address.smf.ch.eql(doc.Channels.single(0).with(1)));
        const spelled = try channelsJson(testing.allocator, s.op.?.bind.address.smf.ch);
        defer testing.allocator.free(spelled);
        try testing.expectEqualStrings("[1,2]", spelled);
        const one = try channelsJson(testing.allocator, .single(1));
        defer testing.allocator.free(one);
        try testing.expectEqualStrings("2", one);
        var empty = try fromJson(testing.allocator,
            \\{"op":"bind","lane":"kit","anchor":"song","track":2,"ch":[]}
        );
        defer empty.deinit();
        try testing.expect(empty.op == null);
        try testing.expectEqual(@as(usize, 1), empty.diags.items().len);
        var twice = try fromJson(testing.allocator,
            \\{"op":"bind","lane":"kit","anchor":"song","track":2,"ch":[3,3]}
        );
        defer twice.deinit();
        try testing.expect(twice.op == null);
        try testing.expectEqual(@as(usize, 1), twice.diags.items().len);
    }
    {
        var p = try parsed(
            \\{"op":"unbind","lane":"kick"}
        );
        defer p.deinit();
        try testing.expectEqualStrings("kick", p.op.?.unbind.lane);
    }
    {
        var p = try parsed(
            \\{"op":"materialize","lane":"kick"}
        );
        defer p.deinit();
        try testing.expectEqualStrings("kick", p.op.?.materialize.lane);
    }
    {
        // `:allow-shared` rides on a retime and defaults to off, which
        // is what makes a shared-pattern move a refusal a host has to
        // ask for again rather than one it never sees.
        var p = try parsed(
            \\{"op":"retime","sel":{},"delta":46126080}
        );
        defer p.deinit();
        try testing.expect(!p.op.?.retime.allow_shared);

        var q = try parsed(
            \\{"op":"retime","sel":{},"delta":46126080,"allow-shared":true}
        );
        defer q.deinit();
        try testing.expect(q.op.?.retime.allow_shared);

        // The same key on the other two edits a shared pattern's cell
        // can take: plan 07's diagnostics table is about the CELL, not
        // about which operation reached it.
        var r = try parsed(
            \\{"op":"remove","sel":{},"allow-shared":true}
        );
        defer r.deinit();
        try testing.expect(r.op.?.remove.allow_shared);

        var v = try parsed(
            \\{"op":"velocity","sel":{},"vel":64,"allow-shared":true}
        );
        defer v.deinit();
        try testing.expect(v.op.?.velocity.allow_shared);
        try testing.expectEqual(@as(u7, 64), v.op.?.velocity.vel);
    }
}

test "Op.fromJson: what is not an operation is a diagnostic, never an error" {
    const bad = [_][]const u8{
        "not json at all",
        "[1,2,3]",
        \\{"lane":"flash"}
        ,
        \\{"op":"fly","sel":{}}
        ,
        \\{"op":"retime","sel":{},"delta":"soon"}
        ,
        \\{"op":"quantize","sel":{},"grid":"quarter"}
        ,
        \\{"op":"insert","lane":"flash"}
        ,
        \\{"op":"insert-tempo","at":0}
        ,
        \\{"op":"rename","what":"colour","from":"a","to":"b"}
        ,
    };
    for (bad) |text| {
        var p = try fromJson(testing.allocator, text);
        defer p.deinit();
        try testing.expect(p.op == null);
        try testing.expect(p.diags.hasErrors());
        try testing.expectEqual(Diag.Code.sjon_diagnostic, p.diags.items()[0].code);
    }
}

test "Op.fromJson: a number no field can hold is refused, never truncated" {
    // The final review's I1 at this boundary. Each of these panicked —
    // `@intFromFloat` past `i64` for the floats, `@intCast` past the
    // field's own width for the integers — on text `--op` and `tpr_plan`
    // accept from anybody. A refusal is the only honest answer: a
    // saturated `{"at":1e30}` would edit at tick 9223372036854775807 and
    // a defaulted one would edit at 0, and neither is what was asked.
    const refused = [_][]const u8{
        // `int()`: any integer field, as a float past 2^63.
        \\{"op":"retime","sel":{},"delta":1e30}
        ,
        \\{"op":"retime","sel":{},"delta":-1e30}
        ,
        \\{"op":"split","sel":{},"at":1e300}
        ,
        \\{"op":"insert","lane":"flash","note":{"at":1e30,"dur":0,"key":60}}
        ,
        // the narrowing fields: `:repeat` u32, `:count` i32, `p`/`q` u32.
        \\{"op":"resize","sel":{},"repeat":5000000000}
        ,
        \\{"op":"nudge","sel":{},"grid":"1/16","count":5000000000}
        ,
        \\{"op":"stretch","from":0,"to":184504320,"p":5000000000,"q":2}
        ,
        \\{"op":"stretch","from":0,"to":184504320,"p":3,"q":5000000000}
        ,
        \\{"op":"insert","lane":"flash","clip":{"at":0,"phrase":"fill","repeat":5000000000}}
        ,
    };
    for (refused) |text| {
        var p = try fromJson(testing.allocator, text);
        defer p.deinit();
        if (p.op != null) {
            std.debug.print("not refused: {s}\n", .{text});
            return error.NumberNotRefused;
        }
        try testing.expect(p.diags.hasErrors());
        try testing.expectEqual(
            Diag.Code.sjon_diagnostic,
            p.diags.items()[p.diags.items().len - 1].code,
        );
    }
}

test "Op.fromJson: a value the document spells as an f32 is refused past f32's range" {
    // A keyframe component and a `:qpm` are written by `value.float` as
    // f32. `1e39` narrowed to an infinity, which printed as `inf` — not
    // JSON — so the plan was accepted and `apply`'s re-parse of it was
    // `unreachable`. `1e999` is an infinity already when std.json reads it.
    const refused = [_][]const u8{
        \\{"op":"revalue","sel":{},"value":1e39}
        ,
        \\{"op":"revalue","sel":{},"value":[0.5,-1e39]}
        ,
        \\{"op":"revalue","sel":{},"value":1e999}
        ,
        \\{"op":"insert","lane":"glow","keyframe":{"at":0,"value":1e39}}
        ,
        \\{"op":"insert-tempo","at":46126080,"qpm":1e39}
        ,
        \\{"op":"insert-tempo","at":46126080,"qpm":-1e999}
        ,
    };
    for (refused) |text| {
        var p = try fromJson(testing.allocator, text);
        defer p.deinit();
        if (p.op != null) {
            std.debug.print("not refused: {s}\n", .{text});
            return error.NumberNotRefused;
        }
        const last = p.diags.items()[p.diags.items().len - 1];
        try testing.expectEqual(Diag.Code.sjon_diagnostic, last.code);
    }

    // A number near f32's own largest finite value still reads.
    var p = try parsed(
        \\{"op":"revalue","sel":{},"value":3.4e38}
    );
    defer p.deinit();
    try testing.expectEqual(@as(f32, 3.4e38), p.op.?.revalue.value[0]);
}

test "Op.fromJson: a channel counted from 1 is clamped before it is made a wire number" {
    // `clamp(x - 1, …)` subtracted first, and `x` is any JSON integer: at
    // `minInt(i64)` the subtraction overflowed on text `--op` and
    // `tpr_plan` take from anybody. Clamped into the counted range first,
    // the answer is the one the old spelling gave every other number.
    const min = std.math.minInt(i64);
    {
        var p = try parsed(std.fmt.comptimePrint(
            \\{{"op":"insert","lane":"flash","note":{{"at":0,"dur":1,"key":60,"ch":{d}}}}}
        , .{min}));
        defer p.deinit();
        try testing.expectEqual(@as(u4, 0), p.op.?.insert.what.note.ch.?);
    }
    {
        var p = try parsed(std.fmt.comptimePrint(
            \\{{"op":"bind","lane":"bass","anchor":"song","channel":{d}}}
        , .{min}));
        defer p.deinit();
        try testing.expectEqual(@as(u6, 0), p.op.?.bind.address.it.channel);
    }
    {
        var p = try parsed(std.fmt.comptimePrint(
            \\{{"op":"bind","lane":"pad","anchor":"song","track":1,"ch":{d}}}
        , .{min}));
        defer p.deinit();
        try testing.expect(p.op.?.bind.address.smf.ch.has(0));
    }
    {
        var p = try fromJson(testing.allocator, std.fmt.comptimePrint(
            \\{{"op":"bind","lane":"pad","anchor":"song","track":1,"ch":[{d},16,99]}}
        , .{min}));
        defer p.deinit();
        // 16 and 99 both clamp onto channel 16, which is one channel
        // named twice — not an address, as before.
        try testing.expect(p.op == null);
    }
    {
        var p = try parsed(std.fmt.comptimePrint(
            \\{{"op":"bind","lane":"pad","anchor":"song","track":1,"ch":[{d},2]}}
        , .{min}));
        defer p.deinit();
        const chs = p.op.?.bind.address.smf.ch;
        try testing.expect(chs.has(0) and chs.has(1));
        try testing.expectEqual(@as(u8, 2), chs.count());
    }
}

test "Op.fromJson: a nudge counts at most 65536 grid lines, either way" {
    // `nudged` walks the lines one by one, so a count is time: about
    // 4 µs a line on this machine, and the `i32` the field narrows to
    // admits two billion of them — a `count` of 2000000000 ran for
    // hours rather than being refused. 65536 sixteenths is 4096 bars of
    // `[4 4]`; a nudge that wants more is not a nudge.
    const inside = [_][]const u8{
        \\{"op":"nudge","sel":{},"grid":"1/16","count":65536}
        ,
        \\{"op":"nudge","sel":{},"grid":"1bar","count":-65536}
        ,
    };
    for (inside) |text| {
        var p = try fromJson(testing.allocator, text);
        defer p.deinit();
        try testing.expect(p.op != null);
        try testing.expectEqual(@as(usize, 0), p.diags.items().len);
    }

    const beyond = [_][]const u8{
        \\{"op":"nudge","sel":{},"grid":"1/16","count":65537}
        ,
        \\{"op":"nudge","sel":{},"grid":"1bar","count":-65537}
        ,
    };
    for (beyond) |text| {
        var p = try fromJson(testing.allocator, text);
        defer p.deinit();
        if (p.op != null) {
            std.debug.print("not refused: {s}\n", .{text});
            return error.CountNotRefused;
        }
        try testing.expect(p.diags.hasErrors());
        const last = p.diags.items()[p.diags.items().len - 1];
        try testing.expectEqual(Diag.Code.sjon_diagnostic, last.code);
        // The refusal names the bound, so the user knows what would pass.
        try testing.expect(std.mem.indexOf(u8, last.message, "65536") != null);
    }
}

test "Op.fromJson: a string where a tick goes is refused, never read as the field's default" {
    // `{"at":"4q"}` read as `at = 0` — a tempo point at tick 0 nobody
    // asked for, with no diagnostic. A position in this grammar is an
    // integer tick, and a string is a refusal like a float past `i64`.
    const refused = [_][]const u8{
        \\{"op":"insert-tempo","at":"4q","qpm":110}
        ,
        \\{"op":"insert-meter","at":"1bar","sig":[3,4]}
        ,
        \\{"op":"insert","lane":"flash","note":{"at":"0q","dur":1,"key":60}}
        ,
        \\{"op":"stretch","from":"0","to":184504320,"p":3,"q":2}
        ,
        \\{"op":"resize","sel":{},"dur":true}
        ,
        \\{"op":"remove","sel":{"lanes":["flash"],"range":["0q","4q"]}}
        ,
    };
    for (refused) |text| {
        var p = try fromJson(testing.allocator, text);
        defer p.deinit();
        if (p.op != null) {
            std.debug.print("not refused: {s}\n", .{text});
            return error.StringNotRefused;
        }
        try testing.expect(p.diags.hasErrors());
        // One complaint per malformed text.
        try testing.expectEqual(@as(usize, 1), p.diags.items().len);
        try testing.expectEqual(Diag.Code.sjon_diagnostic, p.diags.items()[0].code);
    }

    // …and an explicit JSON null is the field left out, as before.
    var p = try parsed(
        \\{"op":"insert-tempo","at":null,"qpm":110}
    );
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0), p.op.?.insert_tempo.point.tick);
}

test "Op.fromJson: :strength and :swing are clamped onto the range their rule has" {
    // Clamped rather than refused, and that is the difference between
    // the two helpers: a swing past ±1 asks for the same shuffle too
    // loudly (the offset would be longer than the step it is a fraction
    // of), while a `:repeat` past `u32` asks for a different edit.
    // `-1e300` reached `Snap.lineOf`'s truncation and panicked there.
    var p = try parsed(
        \\{"op":"quantize","sel":{},"grid":"1/8","strength":9,"swing":-1e300}
    );
    defer p.deinit();
    try testing.expectEqual(@as(f64, 1), p.op.?.quantize.strength);
    try testing.expectEqual(@as(f64, -1), p.op.?.quantize.swing);

    var q = try parsed(
        \\{"op":"quantize","sel":{},"grid":"1/8","strength":-4,"swing":1e300}
    );
    defer q.deinit();
    try testing.expectEqual(@as(f64, 0), q.op.?.quantize.strength);
    try testing.expectEqual(@as(f64, 1), q.op.?.quantize.swing);

    // …and a value inside the range crosses unchanged.
    var r = try parsed(
        \\{"op":"quantize","sel":{},"grid":"1/8","strength":0.5,"swing":0.25}
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 0.5), r.op.?.quantize.strength);
    try testing.expectEqual(@as(f64, 0.25), r.op.?.quantize.swing);
}

test "Op.fromJson: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails with
    // error.OutOfMemory and testing.allocator sees no leak; past the last
    // index it succeeds. Bounded by the number of allocations the call
    // makes, which the loop discovers. Two texts: an operation that
    // reads (strings, a selection, a key list into the arena) and one
    // that is refused (the diagnostic's own allocation).
    const texts = [_][]const u8{
        \\{"op":"retime","sel":{"lanes":["flash"],"kinds":["note"],"keys":[36]},"delta":46126080}
        ,
        \\{"op":"rename","what":"phrase","from":"fill"}
        ,
    };
    for (texts) |text| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(testing.allocator, .{
                .fail_index = fail_index,
            });
            const result = fromJson(failing.allocator(), text);
            if (failing.has_induced_failure) {
                try testing.expectError(error.OutOfMemory, result);
            } else {
                var value = try result;
                value.deinit();
                break;
            }
        }
    }
}
