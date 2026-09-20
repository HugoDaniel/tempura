//! The SMF carrier: the residue as `FF 7F` sequencer-specific events.
//!
//! Plan 04, "The SMF carrier". RP-001 reserves `FF 7F` for exactly this
//! and requires readers to skip what they do not know, so the payloads
//! ride in a file every DAW opens as if nothing were there. Each one is
//! the envelope `records.zig` spells — `7D 74 65 6D ver kind seq total`
//! and the body — and the SMF core already reads and writes that
//! envelope typed (`smf.Kind.tempura_residue`, `Sequence.TempuraResidue`),
//! so nothing here touches a byte of the file format.
//!
//! **Placement** (plan 04): the essence and the conductor record at tick
//! 0 of track 0 — the conductor track, and in a format-0 file the only
//! track — BEFORE any other event at that tick; a lane record at tick 0
//! of the track it describes, which it names itself in its address. The
//! canonical writer stable-sorts by tick, so first in the track's event
//! list is first in the file (`src/smf/write.zig`).
//!
//! **Splitting.** The essence is one body however long; a meta event's
//! VLQ admits `0x0FFFFFFF` bytes but some sequencers cap one far lower,
//! so `Options.max_event` bounds the body of a single event and the
//! essence is cut into `total` consecutive parts numbered `seq = 0 …
//! total - 1`. `total` is a u8, so a carrier holds `255 × max_event`
//! bytes of essence; an essence past that is not written at all —
//! `residue_partial` says so — because half an essence would only decode
//! as corrupt.
//!
//! **What detach consumes, and what it leaves.** A `7F` payload without
//! the `7D 74 65 6D` tag is somebody else's and stays in the sequence
//! verbatim. So does `kind 04`, which is reserved for midivia's easing
//! hint. So does any payload whose `ver` is not this build's: a newer
//! tempura's essence is kept where it is, unparsed, and `residue_version`
//! names it (plan 04, rule 3) — an older reader never shadows a newer
//! one's work.
//!
//! ```zig
//! var carried = try residue.smf.attach(gpa, &seq, payloads, .{});
//! defer carried.deinit();
//!
//! var back = try residue.smf.detach(gpa, &carried.sequence);
//! defer back.deinit();
//! // back.sequence is event-identical to `seq`; back.payloads is what rode.
//! ```

const std = @import("std");

const Diag = @import("../Diag.zig");
const Sequence = @import("../smf/Sequence.zig");
const records = @import("records.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Only resource exhaustion is an error; everything a payload can be
/// wrong about is a diagnostic on the returned value.
pub const Error = error{OutOfMemory};

/// The default cap on ONE event's body. RP-001's VLQ would allow
/// `0x0FFFFFFF`; 65535 is the conservative bound plan 04 names, and the
/// E0 spike measures what each DAW really keeps.
pub const max_event: usize = 65535;

/// How many parts a `seq` / `total` pair can number — `records.zig`'s,
/// re-exported because the split is this carrier's reason for it.
pub const max_parts = records.max_parts;

pub const Options = struct {
    /// The largest body one event may carry. Lowered by the corpus and
    /// by whatever the E0 survival spike finds a sequencer truncates.
    max_event: usize = max_event,
};

/// A sequence with the residue seated in it.
pub const Attached = struct {
    sequence: Sequence.Sequence,
    diags: Diag.List,

    pub fn deinit(self: *Attached) void {
        self.diags.deinit();
        self.sequence.deinit();
    }
};

/// A sequence with the residue taken out of it, and what came out.
///
/// `sequence` is event-identical to the one `attach` was given.
/// `payloads` borrows `arena`, which this value owns.
pub const Detached = struct {
    arena: std.heap.ArenaAllocator,
    payloads: records.Payloads,
    sequence: Sequence.Sequence,
    diags: Diag.List,

    pub fn deinit(self: *Detached) void {
        self.diags.deinit();
        self.sequence.deinit();
        self.arena.deinit();
    }
};

/// Seat `payloads` in a copy of `seq`.
///
/// The returned sequence owns everything it holds; `seq` is borrowed for
/// the call and never mutated. Diagnostic spans are `{0, 0}`: there is no
/// file here to point into — a `Sequence` is the value, and what a caller
/// needs to know is in the message.
pub fn attach(
    gpa: Allocator,
    seq: *const Sequence.Sequence,
    payloads: records.Payloads,
    opts: Options,
) Error!Attached {
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = seq.format;
    b.division = seq.division;

    const cap = @max(opts.max_event, 1);
    const essence = payloads.essence orelse &.{};
    // An essence OFFERED and empty is `pack` reporting that the tier is
    // past SJON's wire limits (`essence.Packed`). Writing the file
    // anyway would leave it holding nothing the format cannot say, so
    // the loss is restated here rather than passing in silence — a
    // caller that means to carry no essence passes none.
    if (payloads.essence != null and essence.len == 0) try diags.add(
        .residue_unencodable,
        .err,
        .{ .start = 0, .end = 0 },
        "the essence handed to this carrier is empty; the timeline tier could not be packed, so this .mid would carry nothing the format cannot say itself",
        .{},
    );

    var parts: usize = if (essence.len == 0) 0 else (essence.len + cap - 1) / cap;
    if (parts > max_parts) {
        try diags.add(
            .residue_partial,
            .warning,
            .{ .start = 0, .end = 0 },
            "the essence is {d} bytes and one .mid carries at most {d} ({d} events of {d}); none of it was written, because half an essence only reads as corrupt",
            .{ essence.len, max_parts * cap, max_parts, cap },
        );
        parts = 0;
    }

    // Where each lane record goes: the track its own address names,
    // 1-based as the file counts them. A record that names a track this
    // file has not got — or an IT address in a `.mid` — rides on track
    // 0 beside the essence; the address in the BODY is what a reader
    // acts on, so placement is a courtesy to a DAW's track view.
    const carrying = parts > 0 or payloads.conductor != null or payloads.lanes.len > 0;
    const track_count = if (seq.tracks.len == 0 and carrying) 1 else seq.tracks.len;
    const lane_track = try gpa.alloc(usize, payloads.lanes.len);
    defer gpa.free(lane_track);
    for (payloads.lanes, lane_track) |body, *slot| {
        slot.* = @min(try laneTrack(gpa, body), track_count -| 1);
    }

    for (0..track_count) |ti| {
        const track = try b.addTrack();

        if (ti == 0) {
            var part: usize = 0;
            while (part < parts) : (part += 1) {
                const from = part * cap;
                const to = @min(from + cap, essence.len);
                try addPayload(&b, track, .{
                    .kind = @intFromEnum(records.Kind.essence),
                    .seq = @intCast(part),
                    .total = @intCast(parts),
                    .body = essence[from..to],
                });
            }
            if (payloads.conductor) |body| try addPayload(&b, track, .{
                .kind = @intFromEnum(records.Kind.conductor),
                .body = body,
            });
        }

        for (payloads.lanes, lane_track) |body, at| {
            if (at != ti) continue;
            try addPayload(&b, track, .{
                .kind = @intFromEnum(records.Kind.lane),
                .body = body,
            });
        }

        if (ti < seq.tracks.len) {
            for (seq.tracks[ti].events) |e| try copyEvent(&b, seq, e, track);
        }
    }

    for (seq.foreign) |chunk| {
        try b.addForeign(chunk.tag, try b.addBytes(seq.bytesOf(chunk.bytes)));
    }

    return .{ .sequence = try b.finish(), .diags = diags };
}

/// Take every payload this build understands out of `seq`.
///
/// What it does not understand stays: a `7F` payload without the tag, a
/// `kind 04`, and any `ver` this build does not write (`residue_version`,
/// plan 04's rule 3).
pub fn detach(gpa: Allocator, seq: *const Sequence.Sequence) Error!Detached {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = seq.format;
    b.division = seq.division;

    var parts: std.ArrayList(records.Part) = .empty;
    var lanes: std.ArrayList([]const u8) = .empty;
    var conductor: ?[]const u8 = null;

    for (seq.tracks) |t| {
        const track = try b.addTrack();
        for (t.events) |e| {
            if (e.kind == .tempura_residue) {
                const r = e.payload.residue;
                const body = seq.bytesOf(r.body);
                if (r.ver != records.version) {
                    try diags.add(
                        .residue_version,
                        .warning,
                        .{ .start = 0, .end = 0 },
                        "a residue payload of envelope version {d} (this build writes {d}); it stays in the file, unparsed",
                        .{ r.ver, records.version },
                    );
                } else switch (@as(records.Kind, @enumFromInt(r.kind))) {
                    .essence => {
                        try parts.append(a, .{ .seq = r.seq, .total = r.total, .body = try a.dupe(u8, body) });
                        continue;
                    },
                    .lane => {
                        try lanes.append(a, try a.dupe(u8, body));
                        continue;
                    },
                    .conductor => {
                        if (conductor == null) conductor = try a.dupe(u8, body);
                        continue;
                    },
                    // `04` is midivia's and anything else is nobody's
                    // this build knows: both stay bytes in the file.
                    .reserved, _ => {},
                }
            }
            try copyEvent(&b, seq, e, track);
        }
    }

    // The chunks that are neither `MThd` nor `MTrk` are the file's, not
    // the residue's: `attach` copied them and `detach` gives them back,
    // or the round trip would quietly lose a chunk RP-001 told every
    // reader to preserve.
    for (seq.foreign) |ch| {
        try b.addForeign(ch.tag, try b.addBytes(seq.bytesOf(ch.bytes)));
    }

    // BEFORE the struct literal, and deliberately: a field initialiser
    // runs in order, so `.arena = arena` would COPY the arena's state
    // and a `reassemble` after it could grow the original with a buffer
    // the copy never hears about — which is a leak of everything on that
    // buffer. `reconcile`'s round trip is what found it (a real essence
    // is kilobytes and needs a second buffer; the 21-byte one here did
    // not), and `it.zig`'s `parseChunk` has always hoisted it for the
    // same reason.
    const essence_body = try records.reassemble(a, parts.items, &diags);
    const sequence = try b.finish();

    return .{
        .arena = arena,
        .payloads = .{
            .essence = essence_body,
            .conductor = conductor,
            .lanes = lanes.items,
        },
        .sequence = sequence,
        .diags = diags,
    };
}

/// One `FF 7F` event, its body copied into the builder's pool.
fn addPayload(b: *Sequence.Builder, track: u32, p: records.Payload) Error!void {
    const body = try b.addBytes(p.body);
    try b.addEvent(track, 0, .tempura_residue, .{ .residue = .{
        .ver = p.ver,
        .kind = p.kind,
        .seq = p.seq,
        .total = p.total,
        .body = body,
    } });
}

/// Which track index a lane record's own address names.
fn laneTrack(gpa: Allocator, body: []const u8) Error!usize {
    var decoded = try records.decodeLane(gpa, body);
    defer decoded.deinit(gpa);
    return switch (decoded) {
        .ok => |r| switch (r.address) {
            .smf => |s| if (s.track == 0) 0 else s.track - 1,
            .it => 0,
        },
        .corrupt => 0,
    };
}

/// One event from `src` into `b`, pool bytes and all.
fn copyEvent(
    b: *Sequence.Builder,
    src: *const Sequence.Sequence,
    e: Sequence.Event,
    track: u32,
) Error!void {
    const payload: Sequence.Payload = switch (e.kind.payloadField()) {
        .bytes => .{ .bytes = try b.addBytes(src.bytesOf(e.payload.bytes)) },
        .meta => .{ .meta = .{
            .bytes = try b.addBytes(src.bytesOf(e.payload.meta.bytes)),
            .meta_type = e.payload.meta.meta_type,
        } },
        .residue => .{ .residue = .{
            .ver = e.payload.residue.ver,
            .kind = e.payload.residue.kind,
            .seq = e.payload.residue.seq,
            .total = e.payload.residue.total,
            .body = try b.addBytes(src.bytesOf(e.payload.residue.body)),
        } },
        else => e.payload,
    };
    try b.addEvent(track, e.at, e.kind, payload);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const smf_read = @import("../smf/read.zig");
const smf_write = @import("../smf/write.zig");

/// A two-track sequence with a foreign `7F` payload on track 0 — the
/// one that must come out the other end untouched.
fn fixture(gpa: Allocator) !Sequence.Sequence {
    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = 96 };

    const t0 = try b.addTrack();
    try b.addEvent(t0, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(t0, 0, .sequencer_specific, .{ .bytes = try b.addBytes("\x7Fsomebody else's") });
    try b.addEvent(t0, 0, .marker, .{ .bytes = try b.addBytes("intro") });
    try b.addEvent(t0, 384, .end_of_track, .empty);

    const t1 = try b.addTrack();
    try b.addEvent(t1, 0, .note_on, .{ .note = .{ .ch = 3, .key = 60, .vel = 100 } });
    try b.addEvent(t1, 96, .note_off, .{ .note = .{ .ch = 3, .key = 60, .vel = 64 } });
    try b.addEvent(t1, 384, .end_of_track, .empty);

    // A chunk that is neither `MThd` nor `MTrk`: RP-001 tells a reader
    // to keep it, and the residue must not be what loses it.
    const kept = try b.addBytes("some other tool's chunk");
    try b.addForeign("XFIR".*, kept);

    return b.finish();
}

/// Everything `sameEvents` compares, plus the foreign chunks with their
/// tags — the whole value, for the two functions that must not lose any
/// of it.
fn sameSequence(a: *const Sequence.Sequence, b: *const Sequence.Sequence) bool {
    if (a.foreign.len != b.foreign.len) return false;
    for (a.foreign, b.foreign) |fa, fb| {
        if (!std.mem.eql(u8, &fa.tag, &fb.tag)) return false;
        if (!std.mem.eql(u8, a.bytesOf(fa.bytes), b.bytesOf(fb.bytes))) return false;
    }
    return sameEvents(a, b);
}

/// Event for event, ACROSS two sequences: kinds, ticks, the payload
/// outside the pool, and the bytes each payload points at.
fn sameEvents(a: *const Sequence.Sequence, b: *const Sequence.Sequence) bool {
    if (a.tracks.len != b.tracks.len) return false;
    for (a.tracks, b.tracks) |ta, tb| {
        if (ta.events.len != tb.events.len) return false;
        for (ta.events, tb.events) |ea, eb| {
            if (ea.kind != eb.kind or ea.at != eb.at) return false;
            if (!ea.payload.eqlOutsidePool(eb.payload, ea.kind)) return false;
            const pa = ea.payload.poolBytes(ea.kind);
            const pb = eb.payload.poolBytes(eb.kind);
            if ((pa == null) != (pb == null)) return false;
            if (pa) |run| {
                if (!std.mem.eql(u8, a.bytesOf(run), b.bytesOf(pb.?))) return false;
            }
        }
    }
    return true;
}

/// A lane record body addressed at SMF track `track` (1-based, as the
/// file counts).
fn laneBody(gpa: Allocator, name: []const u8, track: u16) ![]u8 {
    return records.encodeLane(gpa, .{
        .lane = name,
        .address = .{ .smf = .{ .track = track, .ch = 3, .key = null, .curve = null } },
        .hash = @splat(0x11),
    });
}

test "smf: the essence and the conductor lead track 0, a lane record leads its own" {
    const gpa = testing.allocator;
    var seq = try fixture(gpa);
    defer seq.deinit();

    const lane = try laneBody(gpa, "kick", 2);
    defer gpa.free(lane);

    var carried = try attach(gpa, &seq, .{
        .essence = "ESSENCE",
        .conductor = &records.encodeConductor(.{ .hash = @splat(0x22) }),
        .lanes = &.{lane},
    }, .{});
    defer carried.deinit();
    try testing.expect(!carried.diags.hasErrors());

    const t0 = carried.sequence.tracks[0].events;
    try testing.expectEqual(Sequence.Kind.tempura_residue, t0[0].kind);
    try testing.expectEqual(@as(i64, 0), t0[0].at);
    try testing.expectEqual(@as(u8, @intFromEnum(records.Kind.essence)), t0[0].payload.residue.kind);
    try testing.expectEqual(@as(u8, 1), t0[0].payload.residue.ver);
    try testing.expectEqual(@as(u8, 0), t0[0].payload.residue.seq);
    try testing.expectEqual(@as(u8, 1), t0[0].payload.residue.total);
    try testing.expectEqualStrings("ESSENCE", carried.sequence.bytesOf(t0[0].payload.residue.body));

    try testing.expectEqual(Sequence.Kind.tempura_residue, t0[1].kind);
    try testing.expectEqual(@as(u8, @intFromEnum(records.Kind.conductor)), t0[1].payload.residue.kind);
    // …and then the track's own first event, still at tick 0.
    try testing.expectEqual(Sequence.Kind.set_tempo, t0[2].kind);

    // The lane record named track 2, so it leads track index 1.
    const t1 = carried.sequence.tracks[1].events;
    try testing.expectEqual(Sequence.Kind.tempura_residue, t1[0].kind);
    try testing.expectEqual(@as(u8, @intFromEnum(records.Kind.lane)), t1[0].payload.residue.kind);
    try testing.expectEqual(@as(i64, 0), t1[0].at);
    try testing.expectEqual(Sequence.Kind.note_on, t1[1].kind);

    // Nothing else moved: the header, the track count, the foreign
    // payload and every original event are where they were.
    try testing.expectEqual(@as(u8, 1), carried.sequence.format);
    try testing.expectEqual(@as(u15, 96), carried.sequence.division.pulsesPerQuarter());
    try testing.expectEqual(seq.tracks[0].events.len + 2, t0.len);
    try testing.expectEqual(seq.tracks[1].events.len + 1, t1.len);
}

test "smf: detach hands the payloads back and the sequence event-identical" {
    const gpa = testing.allocator;
    var seq = try fixture(gpa);
    defer seq.deinit();

    const lane = try laneBody(gpa, "kick", 2);
    defer gpa.free(lane);
    const conductor = records.encodeConductor(.{ .hash = @splat(0x22) });

    var carried = try attach(gpa, &seq, .{
        .essence = "ESSENCE",
        .conductor = &conductor,
        .lanes = &.{lane},
    }, .{});
    defer carried.deinit();

    var back = try detach(gpa, &carried.sequence);
    defer back.deinit();
    try testing.expect(!back.diags.hasErrors());

    try testing.expectEqualStrings("ESSENCE", back.payloads.essence.?);
    try testing.expectEqualSlices(u8, &conductor, back.payloads.conductor.?);
    try testing.expectEqual(@as(usize, 1), back.payloads.lanes.len);
    try testing.expectEqualSlices(u8, lane, back.payloads.lanes[0]);

    // The one property the whole carrier rests on — events AND the
    // foreign chunks, which is what makes the fixture carry one.
    try testing.expectEqual(@as(usize, 1), carried.sequence.foreign.len);
    try testing.expectEqual(@as(usize, 1), back.sequence.foreign.len);
    try testing.expectEqualStrings("XFIR", &back.sequence.foreign[0].tag);
    try testing.expectEqualStrings(
        "some other tool's chunk",
        back.sequence.bytesOf(back.sequence.foreign[0].bytes),
    );
    try testing.expect(sameSequence(&seq, &back.sequence));

    // And with nothing to carry, `attach` is a copy: no track invented,
    // no event moved.
    var nothing = try attach(gpa, &seq, .{}, .{});
    defer nothing.deinit();
    try testing.expect(sameSequence(&seq, &nothing.sequence));
    try testing.expectEqual(@as(usize, 0), nothing.diags.items().len);
}

test "smf: a split essence reassembles, and a missing part is residue_corrupt" {
    const gpa = testing.allocator;
    var seq = try fixture(gpa);
    defer seq.deinit();

    const essence = "0123456789abcdefghijklmnopqrstuvwxyz";
    var carried = try attach(gpa, &seq, .{ .essence = essence }, .{ .max_event = 10 });
    defer carried.deinit();

    const t0 = carried.sequence.tracks[0].events;
    try testing.expectEqual(@as(u8, 4), t0[0].payload.residue.total);
    for (0..4) |i| {
        const r = t0[i].payload.residue;
        try testing.expectEqual(@as(u8, @intCast(i)), r.seq);
        try testing.expectEqual(@as(u8, 4), r.total);
    }
    try testing.expectEqualStrings("0123456789", carried.sequence.bytesOf(t0[0].payload.residue.body));
    try testing.expectEqualStrings("uvwxyz", carried.sequence.bytesOf(t0[3].payload.residue.body));

    var back = try detach(gpa, &carried.sequence);
    defer back.deinit();
    try testing.expectEqualStrings(essence, back.payloads.essence.?);

    // Drop the third part: the rest cannot be trusted to be the essence,
    // so nothing is handed back and the loss is named.
    var holed: Sequence.Builder = .init(gpa);
    errdefer holed.deinit();
    holed.format = carried.sequence.format;
    holed.division = carried.sequence.division;
    for (carried.sequence.tracks, 0..) |t, ti| {
        const track = try holed.addTrack();
        for (t.events) |e| {
            if (ti == 0 and e.kind == .tempura_residue and e.payload.residue.seq == 2) continue;
            const payload: Sequence.Payload = if (e.payload.poolBytes(e.kind)) |run| switch (e.kind.payloadField()) {
                .residue => .{ .residue = .{
                    .ver = e.payload.residue.ver,
                    .kind = e.payload.residue.kind,
                    .seq = e.payload.residue.seq,
                    .total = e.payload.residue.total,
                    .body = try holed.addBytes(carried.sequence.bytesOf(run)),
                } },
                .meta => .{ .meta = .{
                    .bytes = try holed.addBytes(carried.sequence.bytesOf(run)),
                    .meta_type = e.payload.meta.meta_type,
                } },
                else => .{ .bytes = try holed.addBytes(carried.sequence.bytesOf(run)) },
            } else e.payload;
            try holed.addEvent(track, e.at, e.kind, payload);
        }
    }
    var holed_seq = try holed.finish();
    defer holed_seq.deinit();

    var bad = try detach(gpa, &holed_seq);
    defer bad.deinit();
    try testing.expect(bad.payloads.essence == null);
    try testing.expectEqual(@as(usize, 1), bad.diags.count(.residue_corrupt));
}

test "smf: a foreign 7F, a reserved kind 04 and a newer ver all stay where they are" {
    const gpa = testing.allocator;

    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const t0 = try b.addTrack();
    try b.addEvent(t0, 0, .sequencer_specific, .{ .bytes = try b.addBytes("\x7Fnot ours") });
    try b.addEvent(t0, 0, .ease_hint, .{ .bytes = try b.addBytes("\x7Dpau\x01") });
    try b.addEvent(t0, 0, .tempura_residue, .{ .residue = .{
        .ver = 1,
        .kind = @intFromEnum(records.Kind.reserved),
        .seq = 0,
        .total = 1,
        .body = try b.addBytes("midivia's"),
    } });
    try b.addEvent(t0, 0, .tempura_residue, .{ .residue = .{
        .ver = 2,
        .kind = @intFromEnum(records.Kind.essence),
        .seq = 0,
        .total = 1,
        .body = try b.addBytes("from the future"),
    } });
    try b.addEvent(t0, 0, .tempura_residue, .{ .residue = .{
        .ver = 1,
        .kind = @intFromEnum(records.Kind.essence),
        .seq = 0,
        .total = 1,
        .body = try b.addBytes("ours"),
    } });
    try b.addEvent(t0, 96, .end_of_track, .empty);
    var seq = try b.finish();
    defer seq.deinit();

    var back = try detach(gpa, &seq);
    defer back.deinit();

    try testing.expectEqualStrings("ours", back.payloads.essence.?);
    // Four events kept: the two foreign payloads, the reserved kind, the
    // newer version — and the end of track.
    const kept = back.sequence.tracks[0].events;
    try testing.expectEqual(@as(usize, 5), kept.len);
    try testing.expectEqual(Sequence.Kind.sequencer_specific, kept[0].kind);
    try testing.expectEqualStrings("\x7Fnot ours", back.sequence.bytesOf(kept[0].payload.bytes));
    try testing.expectEqual(Sequence.Kind.ease_hint, kept[1].kind);
    try testing.expectEqual(Sequence.Kind.tempura_residue, kept[2].kind);
    try testing.expectEqual(@as(u8, 4), kept[2].payload.residue.kind);
    try testing.expectEqual(Sequence.Kind.tempura_residue, kept[3].kind);
    try testing.expectEqual(@as(u8, 2), kept[3].payload.residue.ver);
    try testing.expectEqual(Sequence.Kind.end_of_track, kept[4].kind);

    // The newer version is REPORTED, not swallowed.
    try testing.expectEqual(@as(usize, 1), back.diags.count(.residue_version));
    try testing.expect(!back.diags.hasErrors());
}

test "smf: an essence past what the carrier can hold is refused whole" {
    const gpa = testing.allocator;
    var seq = try fixture(gpa);
    defer seq.deinit();

    const big = try gpa.alloc(u8, 2 * max_parts + 1);
    defer gpa.free(big);
    @memset(big, 'x');

    var carried = try attach(gpa, &seq, .{ .essence = big }, .{ .max_event = 2 });
    defer carried.deinit();

    try testing.expectEqual(@as(usize, 1), carried.diags.count(.residue_partial));
    // Half an essence would only ever decode as corrupt, so none of it
    // is written.
    for (carried.sequence.tracks) |t| {
        for (t.events) |e| try testing.expect(e.kind != .tempura_residue);
    }
}

test "smf: an essence that could not be packed is refused, not written as nothing" {
    // `essence.pack` hands back an empty body with `residue_unencodable`
    // when the tier is past SJON's wire limits. A carrier that wrote the
    // file anyway would leave it holding nothing of the timeline and say
    // nothing about it.
    const gpa = testing.allocator;
    var seq = try fixture(gpa);
    defer seq.deinit();

    var refused = try attach(gpa, &seq, .{ .essence = "" }, .{});
    defer refused.deinit();
    try testing.expectEqual(@as(usize, 1), refused.diags.count(.residue_unencodable));
    try testing.expect(refused.diags.hasErrors());

    // No essence OFFERED is a different thing and stays silent.
    var silent = try attach(gpa, &seq, .{}, .{});
    defer silent.deinit();
    try testing.expectEqual(@as(usize, 0), silent.diags.items().len);
}

test "smf: pack → attach → write → read → detach, the whole carrier round trip" {
    // The corpus case `residue-smf-exact` (plan 04, phase 3's gate),
    // held as a unit test until the runner learns `(build)` / `(dump)`.
    const gpa = testing.allocator;
    var seq = try fixture(gpa);
    defer seq.deinit();

    const lane = try laneBody(gpa, "kick", 2);
    defer gpa.free(lane);
    const conductor = records.encodeConductor(.{
        .hash = records.hashSmfConductor(&seq),
    });

    var carried = try attach(gpa, &seq, .{
        .essence = "(timeline :title \"x\")",
        .conductor = &conductor,
        .lanes = &.{lane},
    }, .{});
    defer carried.deinit();

    var file = try smf_write.write(gpa, &carried.sequence, .{});
    defer file.deinit();
    try testing.expect(!file.diags.hasErrors());

    var read_back = try smf_read.read(gpa, file.bytes);
    defer read_back.deinit();
    try testing.expect(!read_back.diags.hasErrors());

    var back = try detach(gpa, &read_back.sequence);
    defer back.deinit();

    try testing.expectEqualStrings("(timeline :title \"x\")", back.payloads.essence.?);
    try testing.expectEqualSlices(u8, &conductor, back.payloads.conductor.?);
    try testing.expectEqualSlices(u8, lane, back.payloads.lanes[0]);

    // The file's own EVENTS survived the whole trip. Not the foreign
    // chunk: the canonical writer emits a header and its tracks and
    // nothing else (`Sequence.ForeignChunk`), so a chunk is lost to a
    // `write`, which is the SMF core's contract and not the residue's
    // doing — `attach` and `detach` both carry it, and the test above
    // is where that is pinned.
    try testing.expect(sameEvents(&seq, &back.sequence));
    try testing.expectEqual(@as(usize, 0), back.sequence.foreign.len);
}
