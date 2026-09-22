//! The envelope, the record bodies, and the four content hashes.
//!
//! Plan 04, "What the residue is" items 2 and 3, and the framing both
//! carriers share. Everything here is a BYTE LAYOUT, written down in full
//! because a hash nobody else can compute is useless: `docs/residue.md`
//! restates this header at E3 so a second implementation agrees with this
//! one to the byte.
//!
//! # The envelope
//!
//! ```
//! 7D 74 65 6D  ver  kind  seq  total  <body>
//! ```
//!
//! `7D` is the manufacturer id reserved for non-commercial use, so the
//! three bytes `tem` follow it and tell tempura's payload from another
//! project's (midi 03's `7D 'pau'` precedent). `ver` is 1. `kind` is
//! `01` the essence, `02` a lane record, `03` the conductor record, and
//! `04` is RESERVED for midivia's easing-hint body, never written here
//! and never consumed. `seq` / `total` number the parts of a body split
//! across several carriers, both u8, `seq` counting from 0 and
//! `total >= 1`; a record is always `0 / 1`.
//!
//! In a `.mid` the envelope IS the `FF 7F <len VLQ>` payload and the
//! meta event's own length delimits the body, so nothing else is needed
//! (`smf.zig`, and `src/smf/read.zig` parses it into `TempuraResidue`).
//! In a `.it` the records sit end to end inside one `TMPU` chunk with
//! no delimiter of their own, so each one carries its length:
//!
//! ```
//! 7D 74 65 6D  ver  kind  seq  total  len u32 LE  <body[len]>
//! ```
//!
//! — the same eight bytes, then the length. A reader that does not know
//! a `ver` or a `kind` can still step over the record (`it.zig`).
//!
//! # The record bodies
//!
//! Little-endian throughout, no padding, no alignment.
//!
//! **`kind 02`, a lane record** (`LaneRecord`):
//!
//! | off | size | field |
//! | --- | --- | --- |
//! | 0 | 32 | `hash` — SHA-256 over the rendered events (below) |
//! | 32 | 8 | `address` — the native address (below) |
//! | 40 | 2 | `name_len` u16 |
//! | 42 | 2 | `segments` u16 — how many follow |
//! | 44 | `name_len` | the lane's name, UTF-8 |
//! | … | | `segments` × `{ at i64, ease_len u16, ease[ease_len] }` |
//!
//! **`kind 03`, the conductor record** (`ConductorRecord`): the 32 hash
//! bytes and nothing else.
//!
//! **The address**, 8 bytes, tagged:
//!
//! | off | size | smf (`tag 0`) | it (`tag 1`) |
//! | --- | --- | --- | --- |
//! | 0 | 1 | `0` | `1` |
//! | 1 | 2 | `track` u16, 1-based file order | `channel` u8 at +1, then a 0 |
//! | 3 | 1 | `ch`, 0-based, ONE channel (¹) | `column` (²) |
//! | 4 | 1 | `key` (`FF` none) | `fx` letter, ASCII, 0 none |
//! | 5 | 1 | `curve` (³) | 0 |
//! | 6 | 1 | the `cc` number, or the MSB of a `cc14` pair | 0 |
//! | 7 | 1 | the LSB of a `cc14` pair | 0 |
//!
//! (¹) a lane rendered on several channels writes one record each.
//! (²) `FF` none, else `vol` 0 / `pan` 1 / `fx` 2.
//! (³) `FF` none, else `cc` 0 / `cc14` 1 / `bend` 2 / `pressure` 3 /
//! `velocity` 4.
//!
//! # The hashes
//!
//! SHA-256 (SJON's `Sha256Pin` idiom), over EVENTS IN TEMPURA TICKS and
//! never over bytes (plan 04, decision 16). That is the whole point: a
//! `write ∘ read` of the file cannot change a hash — running-status
//! choices, delta-time spellings and byte order are not in it — and a
//! `division` rescale that keeps the music cannot either, because every
//! position goes through `Grid.smfToTicks` before it is hashed. A
//! `division` change UNDER unchanged ticks moves every event on the
//! grid, and the hash says so.
//!
//! A position past the grid's ceiling hashes SATURATED, and `smfToTicks`'
//! `overflow` is not reported here: a hash is a fingerprint with no
//! diagnostic list and no span to give one, and it is the same number on
//! both sides of the comparison it serves (a build's record against a
//! file's), so saturation cannot make two readings of one file disagree.
//! The file's overflow is said where its time is READ — `fromSjon`'s
//! conductor for the whole file, `time/derive` for each bound lane.
//!
//! Each hash starts with an ASCII domain tag ending in `\n`, so two
//! layouts can never collide, and the tag carries the layout's version.
//!
//! **`hashSmfLane(seq, track, ch, ppq)`** — `"tmpu/lane/smf/1\n"`, then
//! `track` u16, `ch` u8; then, for every event of that track whose kind
//! carries a channel and whose channel is `ch`, in the track's own order
//! (which is tick order, ties in file order):
//! `kind` u8 (the `smf.Kind` ordinal), the tempura tick i64, `n` u8 and
//! `n` data bytes — the channel message's data in wire order, so a pitch
//! bend is LSB then MSB.
//!
//! **`hashSmfConductor(seq)`** — `"tmpu/cond/smf/1\n"`, then `format` u8
//! and the division's CLASS u8 (`0` pulses per quarter, `1` SMPTE). The
//! division's VALUE is deliberately absent: it is a unit, and the ticks
//! are already converted through it, so a rescale that keeps the music
//! hashes the same and a change under unchanged ticks does not. Then,
//! for every track in file order and every event of that track in order
//! whose kind is `set_tempo`, `time_signature`, `marker` or `cue_point`
//! (every track: a tempo event on track 3 conducts, midi 04's rule):
//! `kind` u8, the tempura tick i64, then `us` u32 for a tempo, `nn dd cc
//! bb` for a meter, and `len` u32 with the text for a marker or a cue
//! point.
//!
//! **`hashItLane(module, rowmap, channels, patterns)`** —
//! `"tmpu/lane/it/1\n"`, then `channels.len` u32 and the channel bytes,
//! `patterns.len` u32 and the pattern numbers u16 — the address, pinned.
//! Then, for every row the walk PLAYED in play order whose pattern is in
//! `patterns`, and for each channel of `channels` in the order given, a
//! non-empty cell contributes: the tempura tick i64 (the row's
//! `start_tick` times `Grid.IT_TICK`), `channel` u8, then `note`, `ins`,
//! `vol`, `fx` and `param`. A pattern played twice contributes twice, at
//! its two ticks — the hash is over what SOUNDS, which is what a tracker
//! edits.
//!
//! **Two limits of these layouts, stated so nobody has to find them.**
//! A lane hash is over the whole `(track, ch)` pair and not over the
//! narrower address a record may carry: two lanes bound to one channel —
//! one by `:key 36`, one by `:cc 74` — share a hash, so an edit to
//! either moves both. That is deliberate (the record's question is "were
//! these events written by tempura", and a DAW edits a channel, not a
//! controller), and it means a stale verdict can name a lane whose own
//! bytes nobody touched. And the SMF conductor's division rule has a
//! blind spot at the origin: tick 0 maps to tempura tick 0 under every
//! division, so a conductor whose only timing events sit at tick 0 —
//! one `set-tempo` and one `time-signature`, the common case — hashes
//! the same after a `division` change under unchanged ticks. The
//! division's CLASS is in the hash, so ppq ⇄ SMPTE is still caught; a
//! ppq → ppq change with nothing past tick 0 is not, and nothing in that
//! file moved either.
//!
//! **`hashItConductor(module)`** — `"tmpu/cond/it/1\n"`, then the
//! effective speed and tempo u8 (the loader's, `Header.effectiveSpeed` /
//! `effectiveTempo`, so a file IT itself would floor hashes as IT reads
//! it), `highlight_minor` and `highlight_major` u8, then `n` u32 and the
//! order list trimmed of its trailing end markers (the canonical
//! writer's normalisation, so a re-save cannot change it). Then every
//! `Axx` and `Txx` cell of every pattern, in pattern, row, channel
//! order: `pattern` u16, `row` u16, `channel` u8, `fx` u8, `param` u8.
//! Positions are PATTERN COORDINATES here and not ticks, because these
//! cells are what the tick grid is derived FROM (plan 04 lists exactly
//! this content).

const std = @import("std");

const Diag = @import("../Diag.zig");
const Doc = @import("../doc/Value.zig");
const Grid = @import("../time/Grid.zig");
const Sequence = @import("../smf/Sequence.zig");
const itf = @import("../itf/itf.zig");
const walk = @import("../itf/walk.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const testing = std.testing;

/// Only resource exhaustion is an error; a defective body is a returned
/// variant.
pub const Error = error{OutOfMemory};

// ---- the envelope ----------------------------------------------------

/// `7D 't' 'e' 'm'` — the manufacturer id every non-commercial project
/// shares, then tempura's tag. The SMF core owns the spelling
/// (`Sequence.residue_tag`); the IT chunk's framing uses the same four.
pub const magic = Sequence.residue_tag;

/// The envelope version this build writes and understands.
pub const version: u8 = 1;

/// The eight bytes before a body.
pub const head_len: usize = Sequence.residue_head_len;

/// What a payload is. `reserved` is midivia's easing-hint body (plan 04,
/// "The SMF carrier"): tempura never writes one and never consumes one.
pub const Kind = enum(u8) {
    essence = 1,
    lane = 2,
    conductor = 3,
    reserved = 4,
    _,
};

/// One framed payload: the envelope's four bytes and the body they
/// describe. `body` is borrowed.
pub const Payload = struct {
    ver: u8 = version,
    kind: u8,
    seq: u8 = 0,
    total: u8 = 1,
    body: []const u8,
};

/// What a carrier is asked to carry, and what it hands back.
///
/// `essence` is one body however long — the SMF carrier splits it across
/// events and reassembles it, the IT chunk holds it whole. `lanes` are
/// the encoded `kind 02` bodies; each one carries its own address, so a
/// carrier reads the placement out of the body rather than being told it
/// twice.
pub const Payloads = struct {
    /// The packed timeline tier, or null when there is none to carry.
    /// An EMPTY body is not the same as no body: it is what `pack`
    /// returns when the tier is past SJON's wire limits, and a carrier
    /// handed one says `residue_unencodable` rather than writing
    /// nothing (`essence.Packed`).
    essence: ?[]const u8 = null,
    conductor: ?[]const u8 = null,
    lanes: []const []const u8 = &.{},
};

/// Write the eight envelope bytes of `p` into `out`.
pub fn writeHead(out: *std.ArrayList(u8), gpa: Allocator, p: Payload) Error!void {
    assertWritable(p);
    const before = out.items.len;
    try out.appendSlice(gpa, &magic);
    try out.appendSlice(gpa, &[_]u8{ p.ver, p.kind, p.seq, p.total });
    std.debug.assert(out.items.len - before == head_len);
}

/// What a WRITER of this build seats, asserted at the write side: its
/// own envelope version, a kind it writes, a split of at least one part
/// and a `seq` inside it. Both carriers call it before an envelope goes
/// out (`writeHead` here, `smf.addPayload` for the SMF core's typed
/// event). The READER diagnoses the same four and never asserts them —
/// a payload off a file is somebody's bytes, not this build's promise.
pub fn assertWritable(p: Payload) void {
    std.debug.assert(p.ver == version);
    std.debug.assert(isWritten(p.kind));
    std.debug.assert(p.total >= 1);
    std.debug.assert(p.seq < p.total);
}

/// Whether `kind` is one this build writes: the essence, a lane record
/// or the conductor record. `reserved` is midivia's and the rest are
/// nobody's, and neither is ever seated by tempura.
fn isWritten(kind: u8) bool {
    return switch (@as(Kind, @enumFromInt(kind))) {
        .essence, .lane, .conductor => true,
        .reserved, _ => false,
    };
}

/// Read an envelope head at `bytes[0..8]`, or null when the bytes are
/// too short or not tempura's.
pub fn readHead(bytes: []const u8) ?Payload {
    if (bytes.len < head_len) return null;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return null;
    return .{
        .ver = bytes[4],
        .kind = bytes[5],
        .seq = bytes[6],
        .total = bytes[7],
        .body = &.{},
    };
}

/// How many parts a `seq` / `total` pair can number — the essence may
/// be split across that many carriers and no more.
pub const max_parts: usize = 255;

/// One part of a split essence, as detach found it.
pub const Part = struct {
    seq: u8,
    total: u8,
    body: []const u8,
};

/// The payloads of this build's envelope version, gathered one record
/// at a time as a carrier walks its file — `smf.detach` off the events,
/// `it.parseChunk` off the framed list. Every body is copied into the
/// `arena` the caller passes, which owns the lot.
pub const Gathered = struct {
    parts: std.ArrayList(Part) = .empty,
    lanes: std.ArrayList([]const u8) = .empty,
    conductor: ?[]const u8 = null,

    /// Whether `p` was taken: an essence part, a lane record, or a
    /// conductor record — the first one; a second is taken and dropped,
    /// because two conductors are one torn residue. `kind 04` is
    /// midivia's and anything else is nobody's this build knows, and
    /// neither is taken: what the caller does with the record then —
    /// copy the event back, step over the framed bytes — is the
    /// carrier's own business. The caller has already checked `ver`.
    pub fn take(self: *Gathered, arena: Allocator, p: Payload) Error!bool {
        switch (@as(Kind, @enumFromInt(p.kind))) {
            .essence => try self.parts.append(arena, .{
                .seq = p.seq,
                .total = p.total,
                .body = try arena.dupe(u8, p.body),
            }),
            .lane => try self.lanes.append(arena, try arena.dupe(u8, p.body)),
            .conductor => if (self.conductor == null) {
                self.conductor = try arena.dupe(u8, p.body);
            },
            .reserved, _ => return false,
        }
        return true;
    }

    /// Nothing of this version was gathered at all.
    pub fn isEmpty(self: *const Gathered) bool {
        return self.parts.items.len == 0 and self.lanes.items.len == 0 and self.conductor == null;
    }
};

/// The parts back into one body, or nothing at all.
///
/// A split essence is all or none: a body with a hole in it is not a
/// shorter essence, it is Binary IR that would decode as garbage. So a
/// missing part, a disagreeing `total` or a repeated `seq` is
/// `residue_corrupt` and the caller takes the skeleton path (plan 04,
/// rule 4). No parts at all is no essence, and no complaint.
///
/// The parent of the two leaves below: `partsSize` decides, this
/// diagnoses, `join` allocates. The body is `gpa`'s — pass an arena, as
/// both carriers do, or free it.
pub fn reassemble(gpa: Allocator, parts: []const Part, diags: *Diag.List) Error!?[]const u8 {
    if (parts.len == 0) return null;
    const size = partsSize(parts) orelse {
        try diags.add(
            .residue_corrupt,
            .warning,
            .{ .start = 0, .end = 0 },
            "the essence rides in {d} of {d} parts; a split body is all or none, so none of it " ++
                "was used",
            .{ parts.len, parts[0].total },
        );
        return null;
    };
    return try join(gpa, parts, size);
}

/// The length of the body `parts` join into, or null when they do not
/// make one whole split: none at all, a `total` of zero or one two parts
/// disagree on, a `seq` past `total`, a `seq` twice, or a part missing.
/// Pure over the parts, and what a carrier asks when it wants the
/// verdict without a report (`it.parseChunk`).
pub fn partsSize(parts: []const Part) ?usize {
    if (parts.len == 0) return null;
    const total = parts[0].total;
    if (total == 0 or parts.len != @as(usize, total)) return null;
    var seen = [_]bool{false} ** (max_parts + 1);
    var size: usize = 0;
    for (parts) |p| {
        if (p.total != total or p.seq >= total or seen[p.seq]) return null;
        seen[p.seq] = true;
        size += p.body.len;
    }
    return size;
}

/// The parts' bodies end to end, in `seq` order, in `size` bytes owned
/// by `gpa`. PRECONDITION: `size == partsSize(parts).?` — so every `seq`
/// below `total` is there exactly once and the copies fill the buffer.
pub fn join(gpa: Allocator, parts: []const Part, size: usize) Error![]u8 {
    const out = try gpa.alloc(u8, size);
    var at: usize = 0;
    const total = parts[0].total;
    var want: u8 = 0;
    while (want < total) : (want += 1) {
        for (parts) |p| {
            if (p.seq != want) continue;
            @memcpy(out[at..][0..p.body.len], p.body);
            at += p.body.len;
            break;
        }
    }
    std.debug.assert(at == size);
    return out;
}

// ---- the records -----------------------------------------------------

/// One rendered curve segment, as a hint: the tick of the keyframe that
/// ENDS the segment (pacer's semantics, plan 02) and the `:ease` source
/// text that shaped it, verbatim.
///
/// This is all a lane record keeps of a curve's shape. The VALUES live
/// in the essence and in the file's own steps; the easing is the one
/// thing neither can say, and rule 2 of plan 04's reconciliation
/// verifies it against the steps and drops it where it disagrees.
pub const Segment = struct {
    at: i64,
    ease: []const u8,
};

/// One rendered native lane: what it is called, where it was rendered
/// to, the hash of what was written there, and the easing hints.
pub const LaneRecord = struct {
    lane: []const u8,
    address: Doc.Address,
    hash: [32]u8,
    steps_only: []Segment = &.{},
};

/// The file's whole timing context, hashed.
pub const ConductorRecord = struct {
    hash: [32]u8,
};

/// A decoded lane record. `lane` and every `ease` BORROW the body that
/// was decoded; `steps_only` is the allocator's.
pub const DecodedLane = union(enum) {
    ok: LaneRecord,
    corrupt: Diag.Code,

    /// Frees an `.ok`'s segment list with the `gpa` `decodeLane` was given;
    /// the name and the easings it borrows belong to the decoded body.
    pub fn deinit(self: *DecodedLane, gpa: Allocator) void {
        switch (self.*) {
            .ok => |r| gpa.free(r.steps_only),
            .corrupt => {},
        }
    }
};

/// The `kind 02` body of `rec`. Caller owns the bytes.
///
/// A name or an easing longer than a `u16` is truncated rather than
/// refused: the record is a HINT beside a hash, and losing the tail of an
/// absurd name costs nothing a diagnostic could buy back.
pub fn encodeLane(gpa: Allocator, rec: LaneRecord) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const name = rec.lane[0..@min(rec.lane.len, std.math.maxInt(u16))];
    const segments = rec.steps_only[0..@min(rec.steps_only.len, std.math.maxInt(u16))];

    try out.appendSlice(gpa, &rec.hash);
    try out.appendSlice(gpa, &encodeAddress(rec.address));
    try appendInt(&out, gpa, u16, @intCast(name.len));
    try appendInt(&out, gpa, u16, @intCast(segments.len));
    try out.appendSlice(gpa, name);
    for (segments) |seg| {
        const ease = seg.ease[0..@min(seg.ease.len, std.math.maxInt(u16))];
        try appendInt(&out, gpa, i64, seg.at);
        try appendInt(&out, gpa, u16, @intCast(ease.len));
        try out.appendSlice(gpa, ease);
    }
    return out.toOwnedSlice(gpa);
}

/// A `kind 02` body back into a record. Total on arbitrary bytes: every
/// short read, every field out of its domain and every trailing byte is
/// `residue_corrupt`.
pub fn decodeLane(gpa: Allocator, body: []const u8) Error!DecodedLane {
    var c: Cursor = .{ .bytes = body };

    const hash = c.take(32) orelse return corruptLane();
    const addr_bytes = c.take(8) orelse return corruptLane();
    const address = decodeAddress(addr_bytes[0..8].*) orelse return corruptLane();
    const name_len = c.int(u16) orelse return corruptLane();
    const seg_count = c.int(u16) orelse return corruptLane();
    const name = c.take(name_len) orelse return corruptLane();

    // `.corrupt` is a RETURN, not an error, so `errdefer` would not fire:
    // the flag is what frees the segments on every way out but the last.
    // The count is bounded BEFORE it is trusted with an allocation: a
    // segment is at least ten bytes (`at` i64 and an `ease_len` u16), so
    // a body promising more than it could possibly hold is corrupt and
    // nothing is reserved for it.
    if (c.left() / 10 < seg_count) return corruptLane();

    const segments = try gpa.alloc(Segment, seg_count);
    var kept = false;
    defer if (!kept) gpa.free(segments);

    for (segments) |*seg| {
        const at = c.int(i64) orelse return corruptLane();
        const ease_len = c.int(u16) orelse return corruptLane();
        const ease = c.take(ease_len) orelse return corruptLane();
        seg.* = .{ .at = at, .ease = ease };
    }
    // A body that promised less than it carries is as broken as one that
    // promised more: nothing may ride along unread.
    if (c.at != body.len) return corruptLane();

    kept = true;
    return .{ .ok = .{
        .lane = name,
        .address = address,
        .hash = hash[0..32].*,
        .steps_only = segments,
    } };
}

fn corruptLane() DecodedLane {
    return .{ .corrupt = .residue_corrupt };
}

/// The `kind 03` body of `rec`: the hash, and nothing else.
pub fn encodeConductor(rec: ConductorRecord) [32]u8 {
    return rec.hash;
}

/// A `kind 03` body back into a record, or null when it is not 32 bytes.
pub fn decodeConductor(body: []const u8) ?ConductorRecord {
    if (body.len != 32) return null;
    return .{ .hash = body[0..32].* };
}

/// The address, as the eight bytes the header's table spells.
fn encodeAddress(a: Doc.Address) [8]u8 {
    var b: [8]u8 = @splat(0);
    switch (a) {
        .smf => |s| {
            b[0] = 0;
            std.mem.writeInt(u16, b[1..3], s.track, .little);
            // ONE channel: the wire is frozen and a record has always
            // named a `(track, ch)` pair, which is what its hash is
            // over. A lane whose notes name several channels writes one
            // record per channel (`export/render_smf.zig`, `notesLane`),
            // each a single, so a set never reaches here from a build;
            // a set that does (a bound lane's address, hashed for a
            // table) is spelled by its lowest channel, deterministically,
            // and decodes as that one channel.
            b[3] = s.ch.first();
            b[4] = if (s.key) |k| k else 0xFF;
            if (s.curve) |curve| switch (curve) {
                .cc => |n| {
                    b[5] = 0;
                    b[6] = n;
                },
                .cc14 => |pair| {
                    b[5] = 1;
                    b[6] = pair[0];
                    b[7] = pair[1];
                },
                .bend => b[5] = 2,
                .pressure => b[5] = 3,
                .velocity => b[5] = 4,
            } else b[5] = 0xFF;
        },
        .it => |s| {
            b[0] = 1;
            b[1] = s.channel;
            b[3] = if (s.column) |col| @intFromEnum(col) else 0xFF;
            b[4] = s.fx orelse 0;
        },
    }
    return b;
}

/// The inverse, or null when a field is outside its domain — a `ch` of
/// 200 is not a channel, and a record that claims one is not tempura's.
fn decodeAddress(b: [8]u8) ?Doc.Address {
    switch (b[0]) {
        0 => {
            if (b[3] > 15) return null;
            const key: ?u7 = if (b[4] == 0xFF) null else if (b[4] <= 127) @intCast(
                b[4],
            ) else return null;
            const curve: ?Doc.SmfCurve = switch (b[5]) {
                0xFF => null,
                0 => if (b[6] <= 127) .{ .cc = @intCast(b[6]) } else return null,
                1 => if (b[6] <= 127 and b[7] <= 127)
                    .{ .cc14 = .{ @intCast(b[6]), @intCast(b[7]) } }
                else
                    return null,
                2 => .bend,
                3 => .pressure,
                4 => .velocity,
                else => return null,
            };
            return .{ .smf = .{
                .track = std.mem.readInt(u16, b[1..3], .little),
                .ch = .single(@intCast(b[3])),
                .key = key,
                .curve = curve,
            } };
        },
        1 => {
            if (b[1] > 63) return null;
            const column: ?Doc.ItColumn = switch (b[3]) {
                0xFF => null,
                0 => .vol,
                1 => .pan,
                2 => .fx,
                else => return null,
            };
            return .{ .it = .{
                .channel = @intCast(b[1]),
                .column = column,
                .fx = if (b[4] == 0) null else b[4],
            } };
        },
        else => return null,
    }
}

/// A bounds-checked forward reader. Every `null` is a body that ended
/// early, which is the one way a record is corrupt.
const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Cursor, n: usize) ?[]const u8 {
        if (self.bytes.len - self.at < n) return null;
        defer self.at += n;
        return self.bytes[self.at..][0..n];
    }

    fn left(self: *const Cursor) usize {
        return self.bytes.len - self.at;
    }

    fn int(self: *Cursor, comptime T: type) ?T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        const raw = self.take(n) orelse return null;
        return std.mem.readInt(T, raw[0..n], .little);
    }
};

fn appendInt(out: *std.ArrayList(u8), gpa: Allocator, comptime T: type, v: T) Error!void {
    var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

// ---- the hashes ------------------------------------------------------

/// The ASCII domain tags. Each ends in a newline, which no tag contains,
/// so no two hash layouts can ever be fed the same bytes.
const tag_smf_lane = "tmpu/lane/smf/1\n";
const tag_smf_conductor = "tmpu/cond/smf/1\n";
const tag_it_lane = "tmpu/lane/it/1\n";
const tag_it_conductor = "tmpu/cond/it/1\n";

/// A hash under way. The four writers below are the whole vocabulary a
/// layout may use, so the header's tables are the complete story.
const Hash = struct {
    h: Sha256,

    fn init(tag: []const u8) Hash {
        var h = Sha256.init(.{});
        h.update(tag);
        return .{ .h = h };
    }

    fn byte(self: *Hash, v: u8) void {
        self.h.update(&[_]u8{v});
    }

    fn int(self: *Hash, comptime T: type, v: T) void {
        var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        self.h.update(&buf);
    }

    fn bytes(self: *Hash, v: []const u8) void {
        self.h.update(v);
    }

    fn final(self: *Hash) [32]u8 {
        return self.h.finalResult();
    }
};

/// The rendered events at `(track, ch)`, hashed in tempura ticks.
///
/// `track` INDEXES `seq.tracks`; a lane record's address spells the same
/// track 1-based, as the file does (`smf.zig` converts). An index past
/// the end hashes the address and no events — an empty lane, not a
/// panic.
pub fn hashSmfLane(seq: *const Sequence.Sequence, track: u32, ch: u4, ppq: u15) [32]u8 {
    var h: Hash = .init(tag_smf_lane);
    h.int(u16, @truncate(track));
    h.byte(ch);

    if (track < seq.tracks.len) {
        for (seq.tracks[track].events) |e| {
            if (channelOf(e) != ch) continue;
            var buf: [2]u8 = undefined;
            const data = dataOf(e, &buf);
            h.byte(@intFromEnum(e.kind));
            h.int(i64, Grid.smfToTicks(e.at, ppq).tick);
            h.byte(@intCast(data.len));
            h.bytes(data);
        }
    }
    return h.final();
}

/// The channel an event carries, or null when it carries none. Public
/// because a lane hash's scope — "the channel events at this address" —
/// is also what a dump CONSUMES once the hash has matched
/// (`reconcile.consumeSmf`), and the two must agree on which events
/// those are.
pub fn channelOf(e: Sequence.Event) ?u4 {
    return switch (e.kind.payloadField()) {
        .note => @intCast(e.payload.note.ch & 0x0F),
        .poly => @intCast(e.payload.poly.ch & 0x0F),
        .control => @intCast(e.payload.control.ch & 0x0F),
        .program => @intCast(e.payload.program.ch & 0x0F),
        .pressure => @intCast(e.payload.pressure.ch & 0x0F),
        .bend => @intCast(e.payload.bend.ch & 0x0F),
        else => null,
    };
}

/// A channel message's data bytes, in WIRE order — so a pitch bend is
/// LSB then MSB, exactly as the file spells it.
fn dataOf(e: Sequence.Event, buf: *[2]u8) []const u8 {
    switch (e.kind.payloadField()) {
        .note => {
            buf[0] = e.payload.note.key;
            buf[1] = e.payload.note.vel;
            return buf[0..2];
        },
        .poly => {
            buf[0] = e.payload.poly.key;
            buf[1] = e.payload.poly.val;
            return buf[0..2];
        },
        .control => {
            buf[0] = e.payload.control.num;
            buf[1] = e.payload.control.val;
            return buf[0..2];
        },
        .program => {
            buf[0] = e.payload.program.num;
            return buf[0..1];
        },
        .pressure => {
            buf[0] = e.payload.pressure.val;
            return buf[0..1];
        },
        .bend => {
            buf[0] = @truncate(e.payload.bend.value & 0x7F);
            buf[1] = @truncate((e.payload.bend.value >> 7) & 0x7F);
            return buf[0..2];
        },
        else => return buf[0..0],
    }
}

/// The file's whole timing context, hashed in tempura ticks.
pub fn hashSmfConductor(seq: *const Sequence.Sequence) [32]u8 {
    var h: Hash = .init(tag_smf_conductor);
    h.byte(seq.format);
    // The division's CLASS, never its value: the ticks below are already
    // converted through it, so a rescale that keeps the music hashes the
    // same and a change under unchanged ticks does not (plan 04's phase
    // 2 reds, decision 16).
    h.byte(switch (seq.division) {
        .ppq => 0,
        .smpte => 1,
    });

    const ppq = seq.division.pulsesPerQuarter();
    for (seq.tracks) |t| {
        for (t.events) |e| {
            switch (e.kind) {
                .set_tempo, .time_signature, .marker, .cue_point => {},
                else => continue,
            }
            h.byte(@intFromEnum(e.kind));
            h.int(i64, Grid.smfToTicks(e.at, ppq).tick);
            switch (e.kind) {
                .set_tempo => h.int(u32, e.payload.tempo),
                .time_signature => {
                    const ts = e.payload.time_sig;
                    h.bytes(&[_]u8{ ts.nn, ts.dd, ts.cc, ts.bb });
                },
                else => {
                    const text = seq.bytesOf(e.payload.bytes);
                    h.int(u32, @intCast(text.len));
                    h.bytes(text);
                },
            }
        }
    }
    return h.final();
}

/// The cells of `channels` in `patterns`, hashed at the ticks the walk
/// says they sound.
pub fn hashItLane(
    module: *const itf.Module,
    rowmap: *const walk.RowMap,
    channels: []const u8,
    patterns: []const u16,
) [32]u8 {
    var h: Hash = .init(tag_it_lane);
    h.int(u32, @intCast(channels.len));
    h.bytes(channels);
    h.int(u32, @intCast(patterns.len));
    for (patterns) |p| h.int(u16, p);

    for (rowmap.rows) |row| {
        if (std.mem.indexOfScalar(u16, patterns, row.pattern) == null) continue;
        if (row.pattern >= module.patterns.len) continue;
        const p = module.patterns[row.pattern];
        if (row.row >= p.rows) continue;
        if (p.cells.len < @as(usize, p.rows) * itf.model.channels) continue;
        for (channels) |c| {
            if (c >= itf.model.channels) continue;
            const cell = p.cells[@as(usize, row.row) * itf.model.channels + c];
            if (cell.isEmpty()) continue;
            h.int(i64, itTicks(row.start_tick));
            h.byte(c);
            h.bytes(&[_]u8{ cell.note, cell.ins, cell.vol, cell.fx, cell.param });
        }
    }
    return h.final();
}

/// IT ticks onto the grid, saturating rather than wrapping — a walk that
/// ran away is still hashable.
fn itTicks(it_tick: i64) i64 {
    return std.math.mul(i64, it_tick, Grid.IT_TICK) catch std.math.maxInt(i64);
}

/// `Axx` and `Txx`, by ITTECH's command numbering (`cmd = letter - '@'`).
const fx_a: u8 = 'A' - '@';
const fx_t: u8 = 'T' - '@';

/// The module's whole timing context, hashed.
pub fn hashItConductor(module: *const itf.Module) [32]u8 {
    var h: Hash = .init(tag_it_conductor);
    // The LOADER's values, not the raw bytes: a zero speed is IT's 6 and
    // a tempo under 31 is IT's 31, so two files that play identically
    // hash identically (`Header.effectiveSpeed` / `effectiveTempo`).
    h.byte(module.header.effectiveSpeed());
    h.byte(module.header.effectiveTempo());
    h.byte(module.header.highlight_minor);
    h.byte(module.header.highlight_major);

    // The order list without its trailing end markers — what the
    // canonical writer normalises to, so a re-save cannot move the hash.
    var n = module.orders.len;
    while (n > 0 and module.orders[n - 1] == 255) n -= 1;
    h.int(u32, @intCast(n));
    h.bytes(module.orders[0..n]);

    for (module.patterns, 0..) |p, pi| {
        if (p.cells.len < @as(usize, p.rows) * itf.model.channels) continue;
        var row: u16 = 0;
        while (row < p.rows) : (row += 1) {
            var c: u16 = 0;
            while (c < itf.model.channels) : (c += 1) {
                const cell = p.cells[@as(usize, row) * itf.model.channels + c];
                if (cell.fx != fx_a and cell.fx != fx_t) continue;
                h.int(u16, @intCast(pi));
                h.int(u16, row);
                h.byte(@intCast(c));
                h.byte(cell.fx);
                h.byte(cell.param);
            }
        }
    }
    return h.final();
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const smf_read = @import("../smf/read.zig");
const smf_write = @import("../smf/write.zig");
const itf_read = @import("../itf/read.zig");
const itf_write = @import("../itf/write.zig");

/// A two-track sequence: the conductor track carries a tempo, a meter, a
/// marker and a cue point; track 1 carries a note pair and a controller
/// step on channel 3, plus one note on channel 10 that belongs to another
/// lane. `scale` multiplies every tick, so `(96, 1)` and `(480, 5)` are
/// the same music on two divisions.
const Fix = struct {
    ppq: u15 = 96,
    scale: i64 = 1,
    tempo: u32 = 500_000,
    marker: []const u8 = "intro",
    /// A `set-tempo` on track 1 — the track that is not the conductor's.
    extra_tempo: bool = false,
};

fn smfFixture(gpa: Allocator, f: Fix) !Sequence.Sequence {
    var b: Sequence.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = f.ppq };

    const t0 = try b.addTrack();
    try b.addEvent(t0, 0, .set_tempo, .{ .tempo = f.tempo });
    try b.addEvent(
        t0,
        0,
        .time_signature,
        .{ .time_sig = .{ .nn = 4, .dd = 2, .cc = 24, .bb = 8 } },
    );
    try b.addEvent(t0, 96 * f.scale, .marker, .{ .bytes = try b.addBytes(f.marker) });
    try b.addEvent(t0, 192 * f.scale, .cue_point, .{ .bytes = try b.addBytes("bar 2") });
    try b.addEvent(t0, 384 * f.scale, .end_of_track, .empty);

    const t1 = try b.addTrack();
    try b.addEvent(t1, 0, .note_on, .{ .note = .{ .ch = 3, .key = 60, .vel = 100 } });
    try b.addEvent(t1, 0, .control_change, .{ .control = .{ .ch = 3, .num = 74, .val = 64 } });
    try b.addEvent(t1, 96 * f.scale, .note_off, .{ .note = .{ .ch = 3, .key = 60, .vel = 64 } });
    try b.addEvent(t1, 96 * f.scale, .note_on, .{ .note = .{ .ch = 9, .key = 36, .vel = 110 } });
    if (f.extra_tempo) try b.addEvent(t1, 48 * f.scale, .set_tempo, .{ .tempo = 300_000 });
    try b.addEvent(t1, 384 * f.scale, .end_of_track, .empty);

    return b.finish();
}

/// `write` then `read` — the round trip a hash must survive.
fn roundTrip(gpa: Allocator, seq: *const Sequence.Sequence) !smf_read.Result {
    var file = try smf_write.write(gpa, seq, .{});
    defer file.deinit();
    return smf_read.read(gpa, file.bytes);
}

test "records: a write ∘ read of the file changes no hash — the hashes are over events" {
    const gpa = testing.allocator;
    var seq = try smfFixture(gpa, .{});
    defer seq.deinit();

    const lane = hashSmfLane(&seq, 1, 3, 96);
    const conductor = hashSmfConductor(&seq);

    var back = try roundTrip(gpa, &seq);
    defer back.deinit();
    try testing.expect(!back.diags.hasErrors());

    try testing.expectEqual(lane, hashSmfLane(&back.sequence, 1, 3, 96));
    try testing.expectEqual(conductor, hashSmfConductor(&back.sequence));
}

test "records: one velocity byte changes a lane hash, and the other channel is not in it" {
    const gpa = testing.allocator;
    var seq = try smfFixture(gpa, .{});
    defer seq.deinit();
    const before = hashSmfLane(&seq, 1, 3, 96);

    seq.tracks[1].events[0].payload.note.vel = 99;
    try testing.expect(!std.mem.eql(u8, &before, &hashSmfLane(&seq, 1, 3, 96)));
    seq.tracks[1].events[0].payload.note.vel = 100;
    try testing.expectEqual(before, hashSmfLane(&seq, 1, 3, 96));

    // Channel 10's note lives on the same track and belongs to another
    // lane: editing it leaves this lane's hash alone.
    seq.tracks[1].events[3].payload.note.vel = 1;
    try testing.expectEqual(before, hashSmfLane(&seq, 1, 3, 96));
    // …and is in ITS lane's hash.
    const other = hashSmfLane(&seq, 1, 9, 96);
    seq.tracks[1].events[3].payload.note.vel = 2;
    try testing.expect(!std.mem.eql(u8, &other, &hashSmfLane(&seq, 1, 9, 96)));
}

test "records: a division rescale that keeps the music keeps both hashes" {
    const gpa = testing.allocator;
    var slow = try smfFixture(gpa, .{});
    defer slow.deinit();
    var fast = try smfFixture(gpa, .{ .ppq = 480, .scale = 5 });
    defer fast.deinit();

    try testing.expectEqual(hashSmfConductor(&slow), hashSmfConductor(&fast));
    try testing.expectEqual(hashSmfLane(&slow, 1, 3, 96), hashSmfLane(&fast, 1, 3, 480));
}

test "records: a division change under unchanged ticks changes the conductor hash" {
    const gpa = testing.allocator;
    var a = try smfFixture(gpa, .{});
    defer a.deinit();
    var b = try smfFixture(gpa, .{ .ppq = 480 });
    defer b.deinit();

    // Every event moved on the grid: the music is four times slower.
    try testing.expect(!std.mem.eql(u8, &hashSmfConductor(&a), &hashSmfConductor(&b)));
    try testing.expect(!std.mem.eql(u8, &hashSmfLane(&a, 1, 3, 96), &hashSmfLane(&b, 1, 3, 480)));
}

test "records: a tempo edit, a marker rename and a set-tempo on another track all conduct" {
    const gpa = testing.allocator;
    var seq = try smfFixture(gpa, .{});
    defer seq.deinit();
    const before = hashSmfConductor(&seq);

    // One tempo value.
    var retempoed = try smfFixture(gpa, .{ .tempo = 400_000 });
    defer retempoed.deinit();
    try testing.expect(!std.mem.eql(u8, &before, &hashSmfConductor(&retempoed)));

    // A marker renamed: same kind, same tick, different text.
    var renamed = try smfFixture(gpa, .{ .marker = "outro" });
    defer renamed.deinit();
    try testing.expect(!std.mem.eql(u8, &before, &hashSmfConductor(&renamed)));

    // A `set-tempo` added on track 1 conducts (midi 04's rule), even
    // though track 1 is not the conductor track — and it is not a
    // channel event, so no lane's hash moves with it.
    var extra = try smfFixture(gpa, .{ .extra_tempo = true });
    defer extra.deinit();
    try testing.expect(!std.mem.eql(u8, &before, &hashSmfConductor(&extra)));
    try testing.expectEqual(hashSmfLane(&seq, 1, 3, 96), hashSmfLane(&extra, 1, 3, 96));
}

/// A module with two orders over two patterns: channel 0 carries notes,
/// channel 1 a volume column, and the second pattern an `A06` and a
/// `T20` — the conductor's own cells.
fn itFixture(gpa: Allocator) !itf.Module {
    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();

    const p0 = try b.addPattern(64);
    p0.at(0, 0).* = .{ .note = 60, .ins = 1, .vol = 64 };
    p0.at(16, 0).* = .{ .note = 62, .ins = 1, .vol = 48 };
    p0.at(32, 1).* = .{ .note = 48, .ins = 2 };

    const p1 = try b.addPattern(64);
    p1.at(0, 0).* = .{ .note = 64, .ins = 1, .vol = 64 };
    p1.at(0, 0).fx = 'A' - '@';
    p1.at(0, 0).param = 6;
    p1.at(8, 1).* = .{ .fx = 'T' - '@', .param = 0x20 };

    try b.addOrder(0);
    try b.addOrder(1);
    return b.finish();
}

test "records: the IT hashes survive a write ∘ read and notice a cell edit" {
    const gpa = testing.allocator;
    var m = try itFixture(gpa);
    defer m.deinit();

    var map = try walk.derive(gpa, &m, .{});
    defer map.deinit();

    const channels = [_]u8{0};
    const patterns = [_]u16{ 0, 1 };
    const lane = hashItLane(&m, &map, &channels, &patterns);
    const conductor = hashItConductor(&m);

    var file = try itf_write.write(gpa, &m, null, .{});
    defer file.deinit();
    var back = try itf_read.read(gpa, file.bytes);
    defer back.deinit();
    try testing.expect(!back.diags.hasErrors());

    var back_map = try walk.derive(gpa, &back.module, .{});
    defer back_map.deinit();
    try testing.expectEqual(lane, hashItLane(&back.module, &back_map, &channels, &patterns));
    try testing.expectEqual(conductor, hashItConductor(&back.module));

    // One volume byte on the lane's channel: the lane hash moves, the
    // conductor's does not.
    m.patterns[0].at(0, 0).vol = 63;
    try testing.expect(!std.mem.eql(u8, &lane, &hashItLane(&m, &map, &channels, &patterns)));
    try testing.expectEqual(conductor, hashItConductor(&m));
    m.patterns[0].at(0, 0).vol = 64;

    // The `A06` is the conductor's: it moves the conductor hash, and it
    // is on the lane's channel so it moves that one too.
    m.patterns[1].at(0, 0).param = 5;
    try testing.expect(!std.mem.eql(u8, &conductor, &hashItConductor(&m)));
    m.patterns[1].at(0, 0).param = 6;

    // Another channel's cell is not in this lane's hash.
    m.patterns[0].at(32, 1).note = 49;
    try testing.expectEqual(lane, hashItLane(&m, &map, &channels, &patterns));

    // The header's own timing fields conduct.
    m.header.initial_tempo = 140;
    try testing.expect(!std.mem.eql(u8, &conductor, &hashItConductor(&m)));
    m.header.initial_tempo = 125;
    m.header.highlight_major = 8;
    try testing.expect(!std.mem.eql(u8, &conductor, &hashItConductor(&m)));
    m.header.highlight_major = 16;
    try testing.expectEqual(conductor, hashItConductor(&m));
}

test "records: the four hash domains never collide" {
    const gpa = testing.allocator;
    var seq = try smfFixture(gpa, .{});
    defer seq.deinit();
    var m = try itFixture(gpa);
    defer m.deinit();
    var map = try walk.derive(gpa, &m, .{});
    defer map.deinit();

    const all = [_][32]u8{
        hashSmfLane(&seq, 1, 3, 96),
        hashSmfConductor(&seq),
        hashItLane(&m, &map, &[_]u8{0}, &[_]u16{ 0, 1 }),
        hashItConductor(&m),
    };
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, &a, &b));
    }
}

test "records: a lane record round-trips through its body, and rubbish is residue_corrupt" {
    const gpa = testing.allocator;

    var segments = [_]Segment{
        .{ .at = 0, .ease = "in-cubic" },
        .{ .at = 46_126_080, .ease = "(spring :damping 0.5)" },
    };
    const rec: LaneRecord = .{
        .lane = "bass-vol",
        .address = .{
            .smf = .{
                .track = 3,
                .ch = .single(5),
                .key = null,
                .curve = .{ .cc14 = .{ 74, 106 } },
            },
        },
        .hash = @splat(0xAB),
        .steps_only = &segments,
    };

    const body = try encodeLane(gpa, rec);
    defer gpa.free(body);
    var got = try decodeLane(gpa, body);
    defer got.deinit(gpa);

    try testing.expectEqualStrings("bass-vol", got.ok.lane);
    try testing.expectEqual(rec.hash, got.ok.hash);
    try testing.expectEqual(@as(u16, 3), got.ok.address.smf.track);
    try testing.expect(got.ok.address.smf.ch.eql(.single(5)));
    try testing.expect(got.ok.address.smf.key == null);
    try testing.expectEqual([2]u7{ 74, 106 }, got.ok.address.smf.curve.?.cc14);
    try testing.expectEqual(@as(usize, 2), got.ok.steps_only.len);
    try testing.expectEqual(@as(i64, 46_126_080), got.ok.steps_only[1].at);
    try testing.expectEqualStrings("(spring :damping 0.5)", got.ok.steps_only[1].ease);

    // The IT address, and a lane with no segments at all.
    const it_rec: LaneRecord = .{
        .lane = "kick",
        .address = .{ .it = .{ .channel = 2, .column = .vol, .fx = null } },
        .hash = @splat(7),
    };
    const it_body = try encodeLane(gpa, it_rec);
    defer gpa.free(it_body);
    var it_got = try decodeLane(gpa, it_body);
    defer it_got.deinit(gpa);
    try testing.expectEqualStrings("kick", it_got.ok.lane);
    try testing.expectEqual(@as(u6, 2), it_got.ok.address.it.channel);
    try testing.expectEqual(Doc.ItColumn.vol, it_got.ok.address.it.column.?);
    try testing.expect(it_got.ok.address.it.fx == null);
    try testing.expectEqual(@as(usize, 0), it_got.ok.steps_only.len);

    // A channel SET encodes as its FIRST channel, and decodes as that
    // one channel alone. The wire is frozen (a record names a `(track,
    // ch)` pair, which is its hash's scope) and a build never hands one
    // over — a lane rendered on several channels writes one single-
    // channel record each — so the only thing a set can mean here is
    // "the lowest of them", said the same way every time.
    const set_rec: LaneRecord = .{
        .lane = "kit",
        .address = .{
            .smf = .{
                .track = 2,
                .ch = Doc.Channels.single(9).with(3),
                .key = null,
                .curve = null,
            },
        },
        .hash = @splat(1),
    };
    const set_body = try encodeLane(gpa, set_rec);
    defer gpa.free(set_body);
    try testing.expectEqual(@as(u8, 3), set_body[32 + 3]);
    var set_got = try decodeLane(gpa, set_body);
    defer set_got.deinit(gpa);
    try testing.expect(set_got.ok.address.smf.ch.eql(.single(3)));

    // Total on anything: a truncated body, a header that promises more
    // than it carries, and nothing at all.
    for ([_][]const u8{ body[0 .. body.len - 1], body[0..20], "" }) |bad| {
        var c = try decodeLane(gpa, bad);
        defer c.deinit(gpa);
        try testing.expectEqual(Diag.Code.residue_corrupt, c.corrupt);
    }
}

test "records: the conductor body is the hash, and a wrong length is refused" {
    const rec: ConductorRecord = .{ .hash = @splat(0x5A) };
    const body = encodeConductor(rec);
    try testing.expectEqual(@as(usize, 32), body.len);
    try testing.expectEqual(rec.hash, decodeConductor(&body).?.hash);
    try testing.expect(decodeConductor(body[0..31]) == null);
    try testing.expect(decodeConductor("") == null);
}

test "records: the parts of a split essence, in order, once each, or not at all" {
    const gpa = testing.allocator;
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    // In order.
    const whole = [_]Part{
        .{ .seq = 0, .total = 3, .body = "one" },
        .{ .seq = 1, .total = 3, .body = "two" },
        .{ .seq = 2, .total = 3, .body = "three" },
    };
    try testing.expectEqualStrings("onetwothree", (try reassemble(scratch, &whole, &diags)).?);

    // OUT of order: the carrier may hand them back in any order, and
    // `seq` — not arrival — is what says where a part belongs.
    const shuffled = [_]Part{ whole[2], whole[0], whole[1] };
    try testing.expectEqualStrings("onetwothree", (try reassemble(scratch, &shuffled, &diags)).?);
    try testing.expectEqual(@as(usize, 0), diags.items().len);

    // A DUPLICATE `seq`: three parts, `total` 3, but part 1 is missing
    // and part 0 is there twice. Counting alone would accept it.
    const duplicated = [_]Part{ whole[0], whole[0], whole[2] };
    try testing.expect((try reassemble(scratch, &duplicated, &diags)) == null);
    try testing.expectEqual(@as(usize, 1), diags.count(.residue_corrupt));

    // A `total` two parts disagree on, a `seq` past `total`, a `total`
    // of zero, and a part that is simply missing.
    const cases = [_][]const Part{
        &.{ .{ .seq = 0, .total = 2, .body = "a" }, .{ .seq = 1, .total = 3, .body = "b" } },
        &.{ .{ .seq = 0, .total = 2, .body = "a" }, .{ .seq = 9, .total = 2, .body = "b" } },
        &.{.{ .seq = 0, .total = 0, .body = "a" }},
        &.{ whole[0], whole[1] },
    };
    for (cases) |parts| {
        try testing.expect((try reassemble(scratch, parts, &diags)) == null);
    }
    try testing.expectEqual(@as(usize, 5), diags.count(.residue_corrupt));

    // No parts at all is no essence, and no complaint.
    try testing.expect((try reassemble(scratch, &.{}, &diags)) == null);
    try testing.expectEqual(@as(usize, 5), diags.count(.residue_corrupt));

    // The pure verdict agrees case for case, and says nothing.
    try testing.expectEqual(@as(?usize, 11), partsSize(&whole));
    try testing.expectEqual(@as(?usize, 11), partsSize(&shuffled));
    try testing.expectEqual(@as(?usize, null), partsSize(&duplicated));
    for (cases) |parts| try testing.expectEqual(@as(?usize, null), partsSize(parts));
    try testing.expectEqual(@as(?usize, null), partsSize(&.{}));
    try testing.expectEqualStrings("onetwothree", try join(scratch, &shuffled, 11));
}

test "records: the envelope is 7D 74 65 6D ver kind seq total" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try writeHead(
        &out,
        gpa,
        .{ .kind = @intFromEnum(Kind.essence), .seq = 2, .total = 5, .body = &.{} },
    );
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7D, 0x74, 0x65, 0x6D, 1, 1, 2, 5 }, out.items);

    const back = readHead(out.items).?;
    try testing.expectEqual(@as(u8, 1), back.ver);
    try testing.expectEqual(@as(u8, @intFromEnum(Kind.essence)), back.kind);
    try testing.expectEqual(@as(u8, 2), back.seq);
    try testing.expectEqual(@as(u8, 5), back.total);

    // Somebody else's `7F` payload, and a short one.
    try testing.expect(readHead("\x7Dpau\x01\x01\x00\x01") == null);
    try testing.expect(readHead("\x7Dtem\x01") == null);

    // The kinds plan 04 freezes.
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Kind.essence));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Kind.lane));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Kind.conductor));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Kind.reserved));
}
