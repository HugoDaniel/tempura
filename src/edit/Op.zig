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
};

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
        .a = arena.allocator(),
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
            "{d} is outside the range the field it was written for can hold; this operation names no edit",
            .{x},
        );
        return .{ .op = null, .diags = diags, .arena = arena };
    }
    return .{ .op = op, .diags = diags, .arena = arena };
}

/// The decode, one field at a time. Everything it cannot read it says so
/// about and answers null, so one malformed operation gives one
/// complaint and no half-built value.
const Reader = struct {
    a: std.mem.Allocator,
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

    fn fail(self: *Reader, comptime fmt: []const u8, args: anytype) Error!void {
        try self.diags.add(.sjon_diagnostic, .err, self.span, fmt, args);
    }

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

        if (eql(name, "insert")) return try self.insert(o);
        if (eql(name, "remove")) return .{ .remove = .{
            .sel = try self.select(o.get("sel")),
            .allow_shared = self.optBool(o.get("allow-shared")) orelse false,
        } };
        if (eql(name, "retime")) {
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
        if (eql(name, "revalue")) {
            const got = self.components(o.get("value")) orelse {
                try self.fail("revalue wants a \"value\": a number or one to four of them", .{});
                return null;
            };
            return .{ .revalue = .{ .sel = try self.select(o.get("sel")), .value = got.value, .ncomp = got.ncomp } };
        }
        if (eql(name, "ease")) return .{ .ease = .{
            .sel = try self.select(o.get("sel")),
            .ease = try self.str(o.get("ease") orelse .null) orelse {
                try self.fail("ease wants an \"ease\": a pacer easing, as SJON text", .{});
                return null;
            },
        } };
        if (eql(name, "resize")) return .{ .resize = .{
            .sel = try self.select(o.get("sel")),
            .dur = self.optInt(o.get("dur")),
            .repeat = if (self.optInt(o.get("repeat"))) |r| self.narrow(u32, @max(1, r), 1) else null,
        } };
        if (eql(name, "velocity")) return .{ .velocity = .{
            .sel = try self.select(o.get("sel")),
            .vel = @intCast(std.math.clamp(self.optInt(o.get("vel")) orelse 100, 1, 127)),
            .allow_shared = self.optBool(o.get("allow-shared")) orelse false,
        } };
        if (eql(name, "split")) return .{ .split = .{
            .sel = try self.select(o.get("sel")),
            .at = self.optInt(o.get("at")) orelse {
                try self.fail("split wants an \"at\": the tick to split at", .{});
                return null;
            },
        } };
        if (eql(name, "merge")) return .{ .merge = .{ .sel = try self.select(o.get("sel")) } };
        if (eql(name, "duplicate")) {
            const sel = try self.select(o.get("sel"));
            const delta = self.optInt(o.get("delta"));
            const to = self.optInt(o.get("to"));
            if (delta == null and to == null) {
                try self.fail("duplicate wants a \"delta\" or a \"to\", in ticks", .{});
                return null;
            }
            return .{ .duplicate = .{ .sel = sel, .delta = delta, .to = to } };
        }
        if (eql(name, "quantize")) return .{ .quantize = .{
            .sel = try self.select(o.get("sel")),
            .grid = try self.grid(o.get("grid")) orelse return null,
            .strength = self.fraction(o.get("strength"), 1, 0, 1),
            .swing = self.fraction(o.get("swing"), 0, -1, 1),
            .dur_too = self.optBool(o.get("dur-too")) orelse false,
        } };
        if (eql(name, "nudge")) {
            const sel = try self.select(o.get("sel"));
            if (self.optInt(o.get("ticks"))) |ticks| {
                return .{ .nudge = .{ .sel = sel, .delta = .{ .ticks = ticks } } };
            }
            const g = try self.grid(o.get("grid")) orelse return null;
            return .{ .nudge = .{ .sel = sel, .delta = .{ .steps = .{
                .grid = g,
                .count = self.narrow(i32, self.optInt(o.get("count")) orelse 1, 1),
            } } } };
        }
        if (eql(name, "transpose")) return .{ .transpose = .{
            .sel = try self.select(o.get("sel")),
            .semitones = @intCast(std.math.clamp(self.optInt(o.get("semitones")) orelse 0, -127, 127)),
        } };
        if (eql(name, "stretch")) return .{ .stretch = .{
            .from = self.optInt(o.get("from")) orelse 0,
            .to = self.optInt(o.get("to")) orelse 0,
            .p = self.narrow(u32, @max(0, self.optInt(o.get("p")) orelse 0), 0),
            .q = self.narrow(u32, @max(0, self.optInt(o.get("q")) orelse 0), 0),
        } };
        if (eql(name, "insert-tempo")) {
            const at = self.optInt(o.get("at")) orelse 0;
            const tempo: @FieldType(doc.TempoPoint, "tempo") = if (self.optInt(o.get("us"))) |us|
                .{ .us = @intCast(std.math.clamp(us, 1, 16_777_215)) }
            else if (self.optFloat(o.get("qpm"))) |qpm|
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
        if (eql(name, "insert-meter")) {
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
        if (eql(name, "rename")) {
            const what = try self.str(o.get("what") orelse .null) orelse "";
            const which = std.meta.stringToEnum(Renamed, what) orelse {
                try self.fail("rename wants a \"what\": lane, section, phrase, target or anchor", .{});
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
        if (eql(name, "bind")) {
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
        if (eql(name, "unbind")) return .{ .unbind = .{
            .lane = try self.str(o.get("lane") orelse .null) orelse {
                try self.fail("unbind wants a \"lane\"", .{});
                return null;
            },
        } };
        if (eql(name, "materialize")) return .{ .materialize = .{
            .lane = try self.str(o.get("lane") orelse .null) orelse {
                try self.fail("materialize wants a \"lane\"", .{});
                return null;
            },
        } };

        try self.fail("no operation is called {s}", .{name});
        return null;
    }

    fn insert(self: *Reader, o: std.json.ObjectMap) Error!?Op {
        const lane = try self.str(o.get("lane") orelse .null);
        inline for (@typeInfo(New).@"union".fields) |field| {
            if (o.get(field.name)) |v| {
                const what = try self.newOf(field.name, v) orelse return null;
                return .{ .insert = .{ .lane = lane, .what = what } };
            }
        }
        try self.fail("insert wants one of: note, keyframe, clip, section, cue, lane, phrase", .{});
        return null;
    }

    fn newOf(self: *Reader, comptime name: []const u8, v: std.json.Value) Error!?New {
        const o = switch (v) {
            .object => |o| o,
            else => {
                try self.fail("a {s} to insert is a JSON object", .{name});
                return null;
            },
        };
        if (comptime eql(name, "note")) return .{
            .note = .{
                .at = self.optInt(o.get("at")) orelse 0,
                .dur = self.optInt(o.get("dur")) orelse 0,
                .key = @intCast(std.math.clamp(self.optInt(o.get("key")) orelse 60, 0, 127)),
                .vel = if (self.optInt(o.get("vel"))) |x| @intCast(std.math.clamp(x, 1, 127)) else null,
                // `:ch 1` is channel 0 — the wire numbering a `Doc` keeps.
                .ch = if (self.optInt(o.get("ch"))) |x| @intCast(std.math.clamp(x - 1, 0, 15)) else null,
                .off_vel = if (self.optInt(o.get("off-vel"))) |x| @intCast(std.math.clamp(x, 0, 127)) else null,
            },
        };
        if (comptime eql(name, "keyframe")) {
            const got: Reader.Components = self.components(o.get("value")) orelse
                .{ .value = .{ 0, 0, 0, 0 }, .ncomp = 1 };
            return .{ .keyframe = .{
                .at = self.optInt(o.get("at")) orelse 0,
                .value = got.value,
                .ncomp = got.ncomp,
                .ease = try self.str(o.get("ease") orelse .null),
            } };
        }
        if (comptime eql(name, "clip")) return .{ .clip = .{
            .at = self.optInt(o.get("at")) orelse 0,
            .phrase = try self.str(o.get("phrase") orelse .null) orelse {
                try self.fail("a clip names its \"phrase\"", .{});
                return null;
            },
            .repeat = if (self.optInt(o.get("repeat"))) |x| self.narrow(u32, @max(1, x), 1) else null,
            .offset = self.optInt(o.get("offset")),
            .length = self.optInt(o.get("length")),
            .transpose = if (self.optInt(o.get("transpose"))) |x| @intCast(std.math.clamp(x, -120, 120)) else null,
        } };
        if (comptime eql(name, "section")) return .{ .section = .{
            .name = try self.str(o.get("name") orelse .null) orelse {
                try self.fail("a section has a \"name\"", .{});
                return null;
            },
            .at = self.optInt(o.get("at")) orelse 0,
            .dur = self.optInt(o.get("dur")) orelse 0,
        } };
        if (comptime eql(name, "cue")) return .{ .cue = .{
            .name = try self.str(o.get("name") orelse .null) orelse {
                try self.fail("a cue has a \"name\"", .{});
                return null;
            },
            .at = self.optInt(o.get("at")) orelse 0,
        } };
        if (comptime eql(name, "lane")) return .{ .lane = .{
            .name = try self.str(o.get("name") orelse .null) orelse {
                try self.fail("a lane has a \"name\"", .{});
                return null;
            },
            .kind = std.meta.stringToEnum(doc.LaneKind, try self.str(o.get("kind") orelse .null) orelse "notes") orelse .notes,
            .target = try self.str(o.get("target") orelse .null),
        } };
        if (comptime eql(name, "phrase")) return .{ .phrase = .{
            .name = try self.str(o.get("name") orelse .null) orelse {
                try self.fail("a phrase has a \"name\"", .{});
                return null;
            },
            .length = self.optInt(o.get("length")) orelse 0,
            .lanes = try self.strings(o.get("lanes")),
        } };
        unreachable;
    }

    fn address(self: *Reader, o: std.json.ObjectMap) Error!?doc.Address {
        if (o.get("channel")) |v| {
            const column = try self.str(o.get("column") orelse .null);
            const fx = try self.str(o.get("fx") orelse .null);
            return .{ .it = .{
                .channel = @intCast(std.math.clamp((self.int(v) orelse 1) - 1, 0, 63)),
                .column = if (column) |c| std.meta.stringToEnum(doc.ItColumn, c) else null,
                .fx = if (fx) |f| (if (f.len > 0) f[0] else null) else null,
            } };
        }
        if (o.get("track")) |v| {
            var curve: ?doc.SmfCurve = null;
            if (o.get("cc")) |cc| {
                if (self.pair(cc)) |two| {
                    curve = .{ .cc14 = .{ @intCast(std.math.clamp(two[0], 0, 127)), @intCast(std.math.clamp(two[1], 0, 127)) } };
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
            return .{ .smf = .{
                .track = @intCast(std.math.clamp(self.int(v) orelse 1, 1, 65535)),
                .ch = @intCast(std.math.clamp((self.optInt(o.get("ch")) orelse 1) - 1, 0, 15)),
                .key = if (self.optInt(o.get("key"))) |k| @intCast(std.math.clamp(k, 0, 127)) else null,
                .curve = curve,
            } };
        }
        try self.fail("bind wants an address: \"track\" (and \"ch\") for a .mid anchor, \"channel\" for a .it one", .{});
        return null;
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
                const out = try self.a.alloc(u7, keys.array.items.len);
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
            try self.fail("this operation wants a \"grid\": 1/4, 1/8, 1/12, 1/16, 1/32, 1bar or 1b", .{});
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
            .string => |text| try self.a.dupe(u8, text),
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
            try out.append(self.a, one);
        }
        return out.toOwnedSlice(self.a);
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
            else => return null,
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
                    out[i] = @floatCast(self.optFloat(item) orelse return null);
                }
                return .{ .value = out, .ncomp = @intCast(arr.items.len) };
            },
            else => |scalar| {
                out[0] = @floatCast(self.optFloat(scalar) orelse return null);
                return .{ .value = out, .ncomp = 1 };
            },
        }
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
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
        try testing.expectEqual(@as(@TypeOf(p.op.?.insert_tempo.mode), .wall_clock), p.op.?.insert_tempo.mode);

        var q = try parsed(
            \\{"op":"insert-tempo","at":0,"us":500000}
        );
        defer q.deinit();
        try testing.expectEqual(@as(u32, 500000), q.op.?.insert_tempo.point.tempo.us);
        try testing.expectEqual(@as(@TypeOf(q.op.?.insert_tempo.mode), .musical), q.op.?.insert_tempo.mode);
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
        try testing.expectEqual(@as(u4, 1), addr.ch);
        try testing.expectEqual(@as(u7, 36), addr.key.?);

        var q = try parsed(
            \\{"op":"bind","lane":"bass","anchor":"song","channel":5,"column":"vol"}
        );
        defer q.deinit();
        try testing.expectEqual(@as(u6, 4), q.op.?.bind.address.it.channel);
        try testing.expectEqual(doc.ItColumn.vol, q.op.?.bind.address.it.column.?);
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
        try testing.expectEqual(Diag.Code.sjon_diagnostic, p.diags.items()[p.diags.items().len - 1].code);
    }
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
