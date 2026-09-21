//! WASM boundary blobs — the packed little-endian formats that cross the
//! `tempura.wasm` linear-memory boundary, kept out of `wasm_entry.zig` so
//! both directions are natively testable (pacer's `src/Abi.zig`
//! discipline, which is SJON's `wasm_common` one). The JS glue in
//! `npm/tempura/src/blobs.js` mirrors each with one `DataView` pass.
//!
//! Three blobs, all outbound: tempura's inbound zones carry TEXT and
//! BYTES, never a packed structure, so there is no `'PACT'` twin here.
//!
//! ## `'TPDG'` — diagnostics out
//!
//! pacer's `'PACD'` layout, byte for byte, with tempura's `Diag.Code`
//! ordinals and tempura's THREE severities:
//!
//!     [magic u32]['TPDG'][version u32][count u32]
//!     count × { stage u8, severity u8, code u16, start u32, end u32,
//!               msg_len u32, msg bytes }
//!
//!     stage:    which producer's list the record came from —
//!               0 = the document load, 1 = the derivation, 2 = the
//!               verb that was called (a plan, an apply, an export, a
//!               build, or a zone that could not hold an answer).
//!               pacer's `source` byte in the same slot; there it names
//!               the layer, here the stage, because tempura folds SJON's
//!               own diagnostics into `sjon_diagnostic` and one enum
//!               crosses the boundary.
//!     severity: `Diag.Severity`'s ordinal — 0 = error, 1 = warning,
//!               2 = info.
//!     code:     `Diag.Code`'s ordinal, APPEND-ONLY from E3.
//!
//! Spans are byte offsets into whatever the producer read — a document's
//! text for a load, a file's bytes for a dump — and the producer's
//! message says which (`Diag.Span`'s own header).
//!
//! ## `'TPTL'` — the timeline out
//!
//! `Derived` as a packed blob: the fixed header carries the facts that
//! are scalars, and everything that is a LIST rides the TLV section
//! stream after it (pacer's `'PACM'` shape):
//!
//!     [magic u32]['TPTL'][version u32]
//!     [length i64][loop_secs f64][end u8][integral u8][rsv u16][rsv u32]
//!         end: 0 = loop, 1 = hold (`TimeMap.End`'s ordinal).
//!         integral: whether the map took the exact integer path.
//!
//! then zero or more length-prefixed sections, walked to end-of-buffer:
//!
//!     [section_id u32][payload_len u32][payload : payload_len bytes]
//!
//! `section_id` is a 4-CC read LE (house magic style) and `payload_len`
//! counts the payload alone, so a decoder loops to the buffer's end,
//! dispatches the ids it knows and skips the rest by length (`off += 8 +
//! payload_len`). A decoder predating a section ignores it, and adding
//! one never bumps `TIMELINE_VERSION`. Each id appears at most once, in
//! the fixed order below, and a section whose count is 0 is OMITTED — an
//! empty and an absent section are the same thing to a decoder, which
//! keeps a bare blob byte-stable. Defined, in emission order:
//!
//!     'TSEG' tempo segments — [count u32] then count × 32
//!         { tick i64, us f64, tps f64, start_sec f64 }
//!
//!     'TMET' meter segments — [count u32] then count × 32
//!         { tick i64, first_bar i64, beats_before i64, n u8, d u8, rsv u8×6 }
//!
//!     'TBAR' the bar table's SHAPE — [count u32][rsv u32][last_start i64].
//!       A summary, deliberately: the table is one `i64` per bar up to
//!       `:length` and `TimeMap.MAX_BARS` is 2^20 of them, so copying it
//!       would cost eight megabytes of a zone for something 'TMET' already
//!       determines (each meter segment names its first bar and its bar
//!       length). What a host cannot recompute — how many bars there are
//!       and where the last one starts — is what rides.
//!
//!     'TSEC' sections — [count u32] then count × (20 + name_len)
//!         { at i64, dur i64, name_len u16, rsv u16, name bytes }
//!
//!     'TCUE' cues — [count u32] then count × (12 + name_len)
//!         { at i64, name_len u16, rsv u16, name bytes }
//!
//!     'TLAN' the lane index — [count u32] then count × (32 + name_len)
//!         { kind u8 (`Doc.LaneKind`'s ordinal), bound u8, name_len u16,
//!           onsets u32, steps u32, first_tick i64, last_tick i64,
//!           rsv u32, name bytes }
//!       `first_tick` / `last_tick` are the lane's first and last onset,
//!       both 0 when it has none — the two facts `Derived.echo` prints,
//!       computed here so a host never walks an onset list to draw a
//!       lane's extent.
//!
//! A name's length is a `u16`, and nothing upstream bounds a name to it:
//! a `(cue :name "…")` is a string in a document the doc zone holds a
//! megabyte of, and a `.mid` marker is as long as its file says. So a
//! name past 65 535 bytes rides CUT, at the last UTF-8 boundary that fits
//! (`wireName`) — the one spelling of "too long" a fixed-width length
//! has, and never a wrapped length or a record that lies about its size.
//!
//! ## `'TPPH'` — one playhead out
//!
//! A single fixed record, 80 bytes plus its section-id tail:
//!
//!     [magic u32]['TPPH'][version u32]
//!     [tick i64][bar i64][beat i64][sub_ticks i64][seconds_into_bar f64]
//!     [flags u8][refused u8][section_count u16]
//!     [prev_cue u32][next_cue u32][order u32][row u32][rsv u32]
//!     [tick_in_row i64]
//!     section_count × { section_id u32 }
//!
//!     section_count: sections may overlap, so a tick can sit in any
//!              number of them; past 65 535 the record carries the FIRST
//!              65 535 in document order (`wireSections`), for the same
//!              reason a name is cut.
//!     flags:   bit0 = prev_cue present, bit1 = next_cue present,
//!              bit2 = the tracker position (order/row/tick_in_row) present.
//!     refused: 0 = a real position, 1 = tick-overflow, 2 = non-finite-time
//!              (`Refusal`'s ordinal). `Playhead.at` takes SECONDS from
//!              outside, so the two host guards ride out with it; on a
//!              refusal every other field is zero.
//!
//! ## Release policy
//!
//! Every surface here is append-only from E3, together with the `tpr_*`
//! export set and `Diag.Code`: append a TLV section, a trailing field or
//! an enum variant and the release is a MINOR; bump a blob `VERSION` or
//! reuse a section 4-CC and it is BREAKING (pacer's rule verbatim).

const std = @import("std");
const testing = std.testing;

const Diag = @import("Diag.zig");
const time = @import("time/time.zig");
const Doc = @import("doc/Value.zig");
const walk = @import("itf/walk.zig");
const time_test_support = @import("time/test_support.zig");

const Derived = time.derive.Derived;
const Playhead = time.Playhead;

/// The tracker position a document with no IT conductor reports: all
/// zeroes, which the record's `flags` bit 2 tells a host to ignore.
const no_tracker_position: walk.Position = .{ .order = 0, .row = 0, .tick_in_row = 0 };

/// This module's error set: a destination buffer too small for the blob.
/// Never a partial write — a caller that sees this has an untouched
/// buffer's worth of nothing, and `encodeDiags` (which truncates by
/// design, pacer's rule) does not return it.
pub const Error = error{BufferTooSmall};

// ---------------------------------------------------------------------------
// Magics, versions, widths
// ---------------------------------------------------------------------------

/// A four-character code read as a little-endian u32 — the house spelling
/// of a magic, so `"TPTL"` in a hex dump reads left to right.
fn fourcc(comptime tag: *const [4]u8) u32 {
    return std.mem.readInt(u32, tag, .little);
}

/// `"TPDG"` read LE.
pub const DIAGS_MAGIC: u32 = fourcc("TPDG");
pub const DIAGS_VERSION: u32 = 1;
/// `"TPTL"` read LE.
pub const TIMELINE_MAGIC: u32 = fourcc("TPTL");
pub const TIMELINE_VERSION: u32 = 1;
/// `"TPPH"` read LE.
pub const PLAYHEAD_MAGIC: u32 = fourcc("TPPH");
pub const PLAYHEAD_VERSION: u32 = 1;

pub const DIAGS_HEADER_LEN: usize = 12;
/// Fixed bytes per diagnostic record, before its message.
pub const DIAG_RECORD_LEN: usize = 16;

/// magic + version (8) + length/loop/end/integral/reserved (24).
pub const TIMELINE_HEADER_LEN: usize = 32;
/// A TLV frame's own header: `section_id` + `payload_len`.
pub const SECTION_HEADER_LEN: usize = 8;

pub const SEGMENTS_SECTION_ID: u32 = fourcc("TSEG");
pub const SEGMENT_REC_LEN: usize = 32;
pub const METERS_SECTION_ID: u32 = fourcc("TMET");
pub const METER_REC_LEN: usize = 32;
pub const BARS_SECTION_ID: u32 = fourcc("TBAR");
/// The whole `'TBAR'` payload: it is a summary, not a table.
pub const BARS_PAYLOAD_LEN: usize = 16;
pub const SECTIONS_SECTION_ID: u32 = fourcc("TSEC");
/// Fixed bytes per section record, before its name.
pub const SECTION_REC_LEN: usize = 20;
pub const CUES_SECTION_ID: u32 = fourcc("TCUE");
/// Fixed bytes per cue record, before its name.
pub const CUE_REC_LEN: usize = 12;
pub const LANES_SECTION_ID: u32 = fourcc("TLAN");
/// Fixed bytes per lane record, before its name.
pub const LANE_REC_LEN: usize = 32;

/// The whole `'TPPH'` record, before its section-id tail.
pub const PLAYHEAD_LEN: usize = 80;

/// Which producer's list a `'TPDG'` record came from: the document's
/// load, its derivation, or the verb a host called (a plan, an apply, an
/// export, a build — or a zone that could not hold what one produced).
pub const Stage = enum(u8) { document, derivation, operation };

/// Why a position query has no answer — `Playhead.Error`'s two host
/// guards on the wire, and `none` for a real position.
pub const Refusal = enum(u8) {
    none,
    tick_overflow,
    non_finite_time,

    /// `Playhead.Error` without its allocation failure: the two host
    /// guards, the only errors that ARE a refusal.
    pub const Guard = error{ TickOverflow, NonFiniteTime };

    /// The guard `Playhead.at` raised, as this enum spells it. Takes the
    /// two guards and nothing else: running out of memory is not a
    /// refusal (a host sees status 3), so a caller handles
    /// `error.OutOfMemory` first — and the parameter's type is what makes
    /// forgetting to a compile error rather than undefined behaviour.
    pub fn of(err: Guard) Refusal {
        return switch (err) {
            error.TickOverflow => .tick_overflow,
            error.NonFiniteTime => .non_finite_time,
        };
    }
};

/// One list of diagnostics with the stage that produced it — what
/// `encodeDiags` takes, so the blob's records carry their provenance and
/// a host reads one stream in producer order.
pub const DiagSource = struct { stage: Stage, list: *const Diag.List };

// ---------------------------------------------------------------------------
// 'TPDG' — diagnostics out
// ---------------------------------------------------------------------------

/// Exact encoded size of every diagnostic in `sources`. `encodeDiags`
/// into a buffer at least this large never drops a record.
pub fn diagsEncodedLen(sources: []const DiagSource) usize {
    var len: usize = DIAGS_HEADER_LEN;
    for (sources) |src| {
        for (src.list.items()) |d| len += DIAG_RECORD_LEN + d.message.len;
    }
    return len;
}

/// Encode every diagnostic in `sources`, in the order the lists are
/// given and each list in insertion order.
///
/// Total, like pacer's: a record that does not fit is DROPPED and `count`
/// reflects what was written, so a pathological report degrades to a
/// short one rather than to a corrupt blob. Size `dest` with
/// `diagsEncodedLen` when that matters; the wasm zone accepts truncation.
pub fn encodeDiags(sources: []const DiagSource, dest: []u8) []u8 {
    std.debug.assert(dest.len >= DIAGS_HEADER_LEN);
    var pos: usize = DIAGS_HEADER_LEN;
    var count: u32 = 0;
    outer: for (sources) |src| {
        // The read side of `Diag.List`'s contract: every code about to go
        // on the wire is one a decoder with this enum can name.
        src.list.invariants();
        for (src.list.items()) |d| {
            if (!appendDiag(dest, &pos, src.stage, d)) break :outer;
            count += 1;
        }
    }
    std.mem.writeInt(u32, dest[0..4], DIAGS_MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], DIAGS_VERSION, .little);
    std.mem.writeInt(u32, dest[8..12], count, .little);
    return dest[0..pos];
}

fn appendDiag(dest: []u8, pos: *usize, stage: Stage, d: Diag.Diagnostic) bool {
    if (dest.len - pos.* < DIAG_RECORD_LEN + d.message.len) return false;
    dest[pos.*] = @intFromEnum(stage);
    dest[pos.* + 1] = @intFromEnum(d.severity);
    std.mem.writeInt(u16, dest[pos.* + 2 ..][0..2], @intFromEnum(d.code), .little);
    std.mem.writeInt(u32, dest[pos.* + 4 ..][0..4], d.span.start, .little);
    std.mem.writeInt(u32, dest[pos.* + 8 ..][0..4], d.span.end, .little);
    std.mem.writeInt(u32, dest[pos.* + 12 ..][0..4], @intCast(d.message.len), .little);
    pos.* += DIAG_RECORD_LEN;
    @memcpy(dest[pos.*..][0..d.message.len], d.message);
    pos.* += d.message.len;
    return true;
}

// ---------------------------------------------------------------------------
// 'TPTL' — the timeline out
// ---------------------------------------------------------------------------

/// Exact encoded size of a derivation's `'TPTL'` blob — the sum a zone
/// sizer and `encodeTimeline`'s own bounds check both read, so the
/// format is stated once.
pub fn timelineEncodedLen(d: *const Derived) usize {
    var len: usize = TIMELINE_HEADER_LEN;
    if (d.map.segments.len > 0)
        len += SECTION_HEADER_LEN + 4 + d.map.segments.len * SEGMENT_REC_LEN;
    if (d.map.meters.len > 0)
        len += SECTION_HEADER_LEN + 4 + d.map.meters.len * METER_REC_LEN;
    if (d.map.bars.len > 0)
        len += SECTION_HEADER_LEN + BARS_PAYLOAD_LEN;
    if (d.sections.len > 0) {
        len += SECTION_HEADER_LEN + 4;
        for (d.sections) |s| len += SECTION_REC_LEN + wireName(s.name).len;
    }
    if (d.cues.len > 0) {
        len += SECTION_HEADER_LEN + 4;
        for (d.cues) |c| len += CUE_REC_LEN + wireName(c.name).len;
    }
    if (d.lanes.len > 0) {
        len += SECTION_HEADER_LEN + 4;
        for (d.lanes) |l| len += LANE_REC_LEN + wireName(l.name).len;
    }
    return len;
}

/// The most bytes a record's `u16` name length can say.
pub const MAX_WIRE_NAME: usize = std.math.maxInt(u16);

/// A name as the wire carries it: whole when its length fits the
/// record's `u16`, else cut to at most `MAX_WIRE_NAME` bytes at a UTF-8
/// boundary (the header says why). Borrowed from `name`. The ONE place a
/// name's wire length is decided — `timelineEncodedLen` and every writer
/// read it, so the sum and the stream cannot disagree.
///
/// The cut backs off a split codepoint: a UTF-8 sequence is at most four
/// bytes, so its lead byte is at most three before the cut. Bytes that
/// are not UTF-8 there (a `.mid` marker is whatever its file says) have
/// no boundary to find, and the cut stays within those three.
pub fn wireName(name: []const u8) []const u8 {
    if (name.len <= MAX_WIRE_NAME) return name;
    var end: usize = MAX_WIRE_NAME;
    // `name[end]` is the first byte cut off; while it continues a
    // sequence, the kept prefix would end inside that sequence.
    for (0..3) |_| {
        if (name[end] & 0xC0 != 0x80) break;
        end -= 1;
    }
    std.debug.assert(end <= MAX_WIRE_NAME);
    return name[0..end];
}

/// Encode a derivation as a `'TPTL'` blob. Never partial: a `dest` that
/// cannot hold the whole thing is `error.BufferTooSmall` and nothing is
/// written, because half a timeline is a wrong timeline (pacer's meta
/// zone degrades to an ABSENT blob for the same reason).
///
/// The header, then one section per non-empty list in the header's
/// fixed order; each section helper takes the offset it starts at and
/// returns the offset after it, so the stream is one straight line of
/// `pos = …` and the sum is checked against `timelineEncodedLen` at the
/// end.
pub fn encodeTimeline(d: *const Derived, dest: []u8) Error![]u8 {
    d.invariants();
    if (dest.len < timelineEncodedLen(d)) return error.BufferTooSmall;

    var pos = writeTimelineHeader(dest, &d.map);
    if (d.map.segments.len > 0) pos = writeSegments(dest, pos, d.map.segments);
    if (d.map.meters.len > 0) pos = writeMeters(dest, pos, d.map.meters);
    if (d.map.bars.len > 0) pos = writeBars(dest, pos, d.map.bars);
    if (d.sections.len > 0) pos = writeSections(dest, pos, d.sections);
    if (d.cues.len > 0) pos = writeCues(dest, pos, d.cues);
    if (d.lanes.len > 0) pos = writeLanes(dest, pos, d.lanes);

    std.debug.assert(pos == timelineEncodedLen(d));
    return dest[0..pos];
}

/// The fixed header: magic, version, the map's scalars and the reserved
/// bytes zeroed. Returns the offset the section stream starts at.
fn writeTimelineHeader(dest: []u8, map: *const time.TimeMap.TimeMap) usize {
    std.mem.writeInt(u32, dest[0..4], TIMELINE_MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], TIMELINE_VERSION, .little);
    std.mem.writeInt(i64, dest[8..16], map.length, .little);
    writeF64(dest[16..24], map.loop_secs);
    dest[24] = @intFromEnum(map.end);
    dest[25] = @intFromBool(map.integral);
    std.mem.writeInt(u16, dest[26..28], 0, .little);
    std.mem.writeInt(u32, dest[28..32], 0, .little);
    return TIMELINE_HEADER_LEN;
}

/// `'TSEG'` at `at`: count × { tick i64, us f64, tps f64, start_sec f64 }.
/// Returns the offset after the section.
fn writeSegments(dest: []u8, at: usize, segments: []const time.TimeMap.Segment) usize {
    var body = openSection(dest, at, SEGMENTS_SECTION_ID, segments.len);
    for (segments) |s| {
        std.mem.writeInt(i64, dest[body..][0..8], s.tick, .little);
        writeF64(dest[body + 8 ..][0..8], s.us);
        writeF64(dest[body + 16 ..][0..8], s.tps);
        writeF64(dest[body + 24 ..][0..8], s.start_sec);
        body += SEGMENT_REC_LEN;
    }
    return closeSection(dest, at, body);
}

/// `'TMET'` at `at`: count × { tick i64, first_bar i64, beats_before i64,
/// n u8, d u8, rsv u8×6 }. Returns the offset after the section.
fn writeMeters(dest: []u8, at: usize, meters: []const time.TimeMap.MeterSeg) usize {
    var body = openSection(dest, at, METERS_SECTION_ID, meters.len);
    for (meters) |m| {
        std.mem.writeInt(i64, dest[body..][0..8], m.tick, .little);
        std.mem.writeInt(i64, dest[body + 8 ..][0..8], m.first_bar, .little);
        std.mem.writeInt(i64, dest[body + 16 ..][0..8], m.beats_before, .little);
        dest[body + 24] = m.n;
        dest[body + 25] = m.d;
        @memset(dest[body + 26 ..][0..6], 0);
        body += METER_REC_LEN;
    }
    return closeSection(dest, at, body);
}

/// `'TBAR'` at `at`: the table's SHAPE — its count and its last start —
/// never its entries (the header says why). Returns the offset after it.
fn writeBars(dest: []u8, at: usize, bars: []const i64) usize {
    std.debug.assert(bars.len > 0);
    const body = at + SECTION_HEADER_LEN;
    std.mem.writeInt(u32, dest[at..][0..4], BARS_SECTION_ID, .little);
    std.mem.writeInt(u32, dest[at + 4 ..][0..4], @intCast(BARS_PAYLOAD_LEN), .little);
    std.mem.writeInt(u32, dest[body..][0..4], @intCast(bars.len), .little);
    std.mem.writeInt(u32, dest[body + 4 ..][0..4], 0, .little);
    std.mem.writeInt(i64, dest[body + 8 ..][0..8], bars[bars.len - 1], .little);
    return body + BARS_PAYLOAD_LEN;
}

/// `'TSEC'` at `at`: count × { at i64, dur i64, name }. Returns the
/// offset after the section.
fn writeSections(dest: []u8, at: usize, sections: []const time.derive.Section) usize {
    var body = openSection(dest, at, SECTIONS_SECTION_ID, sections.len);
    for (sections) |s| {
        std.mem.writeInt(i64, dest[body..][0..8], s.at, .little);
        std.mem.writeInt(i64, dest[body + 8 ..][0..8], s.dur, .little);
        body += writeName(dest, body + 16, s.name) + 16;
    }
    return closeSection(dest, at, body);
}

/// `'TCUE'` at `at`: count × { at i64, name }. Returns the offset after
/// the section.
fn writeCues(dest: []u8, at: usize, cues: []const time.derive.Cue) usize {
    var body = openSection(dest, at, CUES_SECTION_ID, cues.len);
    for (cues) |c| {
        std.mem.writeInt(i64, dest[body..][0..8], c.at, .little);
        body += writeName(dest, body + 8, c.name) + 8;
    }
    return closeSection(dest, at, body);
}

/// `'TLAN'` at `at`: count × the lane record and its name, with the
/// extent (first and last onset tick, both 0 for a lane with none)
/// computed here so a host never walks an onset list. Returns the offset
/// after the section.
fn writeLanes(dest: []u8, at: usize, lanes: []const time.derive.LaneIndex) usize {
    var body = openSection(dest, at, LANES_SECTION_ID, lanes.len);
    for (lanes) |l| {
        const name = wireName(l.name);
        dest[body] = @intFromEnum(l.kind);
        dest[body + 1] = @intFromBool(l.bound);
        std.mem.writeInt(u16, dest[body + 2 ..][0..2], @intCast(name.len), .little);
        std.mem.writeInt(u32, dest[body + 4 ..][0..4], @intCast(l.onsets.len), .little);
        std.mem.writeInt(u32, dest[body + 8 ..][0..4], @intCast(l.steps.len), .little);
        const first: i64 = if (l.onsets.len == 0) 0 else l.onsets[0].tick;
        const last: i64 = if (l.onsets.len == 0) 0 else l.onsets[l.onsets.len - 1].tick;
        std.mem.writeInt(i64, dest[body + 12 ..][0..8], first, .little);
        std.mem.writeInt(i64, dest[body + 20 ..][0..8], last, .little);
        std.mem.writeInt(u32, dest[body + 28 ..][0..4], 0, .little);
        @memcpy(dest[body + LANE_REC_LEN ..][0..name.len], name);
        body += LANE_REC_LEN + name.len;
    }
    return closeSection(dest, at, body);
}

/// Write a section's frame header and its `[count u32]` at `at`, and
/// hand back the offset its first record starts at. `payload_len` is
/// filled in by `closeSection`, which is what lets a variable-width
/// section be written in one pass.
fn openSection(dest: []u8, at: usize, id: u32, count: usize) usize {
    std.mem.writeInt(u32, dest[at..][0..4], id, .little);
    std.mem.writeInt(u32, dest[at + SECTION_HEADER_LEN ..][0..4], @intCast(count), .little);
    return at + SECTION_HEADER_LEN + 4;
}

/// Close the section `openSection` opened at `at`: the payload ran from
/// just after the frame header to `end`, which is returned as the offset
/// the next section starts at.
fn closeSection(dest: []u8, at: usize, end: usize) usize {
    std.debug.assert(end >= at + SECTION_HEADER_LEN + 4);
    const payload_len = end - at - SECTION_HEADER_LEN;
    std.mem.writeInt(u32, dest[at + 4 ..][0..4], @intCast(payload_len), .little);
    return end;
}

/// `[name_len u16][rsv u16][name bytes]` at `at`, the name as
/// `wireName` cuts it; returns the bytes written. A name is as long as a
/// document or a file makes it, and the `u16` is the wire's, so the cut
/// is here and not an assumption about the input.
fn writeName(dest: []u8, at: usize, full: []const u8) usize {
    const name = wireName(full);
    std.mem.writeInt(u16, dest[at..][0..2], @intCast(name.len), .little);
    std.mem.writeInt(u16, dest[at + 2 ..][0..2], 0, .little);
    @memcpy(dest[at + 4 ..][0..name.len], name);
    return 4 + name.len;
}

fn writeF64(dest: *[8]u8, x: f64) void {
    std.mem.writeInt(u64, dest, @bitCast(x), .little);
}

// ---------------------------------------------------------------------------
// 'TPPH' — one playhead out
// ---------------------------------------------------------------------------

/// Exact encoded size of one position: the fixed record and its
/// section-id tail.
pub fn playheadEncodedLen(pos: Playhead.Position) usize {
    return PLAYHEAD_LEN + wireSections(pos).len * 4;
}

/// The section ids a record carries: all of them, or the first 65 535
/// when more sections than its `u16` count can say overlap the tick (the
/// header's `section_count`). Sections may overlap, so the count is the
/// document's and not a thing any reader bounds. Borrowed from `pos`.
pub fn wireSections(pos: Playhead.Position) []const u32 {
    return pos.section_ids[0..@min(pos.section_ids.len, std.math.maxInt(u16))];
}

/// Encode one position. Never partial — see `encodeTimeline`.
pub fn encodePlayhead(pos: Playhead.Position, dest: []u8) Error![]u8 {
    if (dest.len < playheadEncodedLen(pos)) return error.BufferTooSmall;
    const ids = wireSections(pos);

    var flags: u8 = 0;
    if (pos.prev_cue != null) flags |= 1;
    if (pos.next_cue != null) flags |= 2;
    if (pos.order_row != null) flags |= 4;

    std.mem.writeInt(u32, dest[0..4], PLAYHEAD_MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], PLAYHEAD_VERSION, .little);
    std.mem.writeInt(i64, dest[8..16], pos.tick, .little);
    std.mem.writeInt(i64, dest[16..24], pos.bar, .little);
    std.mem.writeInt(i64, dest[24..32], pos.beat, .little);
    std.mem.writeInt(i64, dest[32..40], pos.sub_ticks, .little);
    writeF64(dest[40..48], pos.seconds_into_bar);
    dest[48] = flags;
    dest[49] = @intFromEnum(Refusal.none);
    std.mem.writeInt(u16, dest[50..52], @intCast(ids.len), .little);
    std.mem.writeInt(u32, dest[52..56], pos.prev_cue orelse 0, .little);
    std.mem.writeInt(u32, dest[56..60], pos.next_cue orelse 0, .little);
    const orow = pos.order_row orelse no_tracker_position;
    std.mem.writeInt(u32, dest[60..64], @intCast(orow.order), .little);
    std.mem.writeInt(u32, dest[64..68], @intCast(orow.row), .little);
    std.mem.writeInt(u32, dest[68..72], 0, .little);
    std.mem.writeInt(i64, dest[72..80], @intCast(orow.tick_in_row), .little);
    for (ids, 0..) |id, i| {
        std.mem.writeInt(u32, dest[PLAYHEAD_LEN + i * 4 ..][0..4], id, .little);
    }
    return dest[0..playheadEncodedLen(pos)];
}

/// Encode a refused position: the guard, and zero everywhere else. A
/// host reads `refused` first and never looks at a tick nobody could
/// answer for.
pub fn encodeRefusal(why: Refusal, dest: []u8) Error![]u8 {
    std.debug.assert(why != .none);
    if (dest.len < PLAYHEAD_LEN) return error.BufferTooSmall;
    @memset(dest[0..PLAYHEAD_LEN], 0);
    std.mem.writeInt(u32, dest[0..4], PLAYHEAD_MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], PLAYHEAD_VERSION, .little);
    dest[49] = @intFromEnum(why);
    return dest[0..PLAYHEAD_LEN];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A minimal section-stream reader, for the tests alone: the ids in the
/// order they were emitted, with each payload's slice. The JS glue is
/// the real decoder; this is what lets a test assert the stream's shape
/// without trusting it.
const Walked = struct {
    ids: [8]u32 = @splat(0),
    payloads: [8][]const u8 = @splat(&.{}),
    len: usize = 0,

    fn of(blob: []const u8) Walked {
        var self: Walked = .{};
        var off: usize = TIMELINE_HEADER_LEN;
        while (off < blob.len) {
            const id = std.mem.readInt(u32, blob[off..][0..4], .little);
            const plen = std.mem.readInt(u32, blob[off + 4 ..][0..4], .little);
            self.ids[self.len] = id;
            self.payloads[self.len] = blob[off + SECTION_HEADER_LEN ..][0..plen];
            self.len += 1;
            off += SECTION_HEADER_LEN + plen;
        }
        return self;
    }

    fn find(self: Walked, id: u32) ?[]const u8 {
        for (self.ids[0..self.len], self.payloads[0..self.len]) |got, payload| {
            if (got == id) return payload;
        }
        return null;
    }
};

/// One document with something in every list: two tempo segments, a
/// section, a cue whose name needs escaping, and a lane with two onsets.
const two_segment_doc =
    \\(timeline :title "TprAbi" :length 4bar)
    \\
    \\(tempo-point :at 0bar :us 500000)
    \\(tempo-point :at 1bar :us 400000)
    \\
    \\(section :name intro :at 0bar :dur 2bar)
    \\(cue :name "drop \"one\"" :at 1bar)
    \\
    \\(lane :name flash :kind notes :target flash
    \\  (note :at 0bar :dur 1b :key 36 :vel 110)
    \\  (note :at 1bar :dur 1b :key 38 :vel 90))
;

fn deriveDoc(gpa: std.mem.Allocator, source: [:0]const u8) !struct {
    result: @import("doc/fromSjon.zig").Result,
    derived: Derived,
} {
    var result = try time_test_support.load(gpa, source);
    errdefer result.deinit();
    const derived = try time.derive.derive(gpa, &result.doc);
    return .{ .result = result, .derived = derived };
}

test "TprAbi: the magics are four-character codes read little-endian" {
    // A hex dump of any of the three reads left to right, which is the
    // one property a host debugging a blob needs from a magic.
    try testing.expectEqualStrings(
        "TPDG",
        &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, DIAGS_MAGIC))),
    );
    try testing.expectEqualStrings(
        "TPTL",
        &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, TIMELINE_MAGIC))),
    );
    try testing.expectEqualStrings(
        "TPPH",
        &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, PLAYHEAD_MAGIC))),
    );
    try testing.expectEqualStrings(
        "TSEG",
        &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, SEGMENTS_SECTION_ID))),
    );
    try testing.expectEqualStrings(
        "TMET",
        &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, METERS_SECTION_ID))),
    );
    try testing.expectEqualStrings(
        "TBAR",
        &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, BARS_SECTION_ID))),
    );
    try testing.expectEqualStrings(
        "TSEC",
        &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, SECTIONS_SECTION_ID))),
    );
    try testing.expectEqualStrings(
        "TCUE",
        &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, CUES_SECTION_ID))),
    );
    try testing.expectEqualStrings(
        "TLAN",
        &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, LANES_SECTION_ID))),
    );
}

test "TprAbi: 'TPTL' — the header, then the six sections in emission order" {
    const gpa = testing.allocator;
    var loaded = try deriveDoc(gpa, two_segment_doc);
    defer loaded.result.deinit();
    var d = loaded.derived;
    defer d.deinit();

    const buf = try gpa.alloc(u8, timelineEncodedLen(&d));
    defer gpa.free(buf);
    const blob = try encodeTimeline(&d, buf);
    try testing.expectEqual(timelineEncodedLen(&d), blob.len);

    try testing.expectEqual(TIMELINE_MAGIC, std.mem.readInt(u32, blob[0..4], .little));
    try testing.expectEqual(TIMELINE_VERSION, std.mem.readInt(u32, blob[4..8], .little));
    try testing.expectEqual(d.map.length, std.mem.readInt(i64, blob[8..16], .little));
    try testing.expectEqual(
        @as(u64, @bitCast(d.map.loop_secs)),
        std.mem.readInt(u64, blob[16..24], .little),
    );
    try testing.expectEqual(@intFromEnum(d.map.end), blob[24]);
    try testing.expectEqual(@intFromBool(d.map.integral), blob[25]);

    // The stream is in the header's fixed order, every section present
    // exactly once, and nothing else.
    const walked: Walked = .of(blob);
    try testing.expectEqualSlices(u32, &.{
        SEGMENTS_SECTION_ID,
        METERS_SECTION_ID,
        BARS_SECTION_ID,
        SECTIONS_SECTION_ID,
        CUES_SECTION_ID,
        LANES_SECTION_ID,
    }, walked.ids[0..walked.len]);

    const segs = walked.find(SEGMENTS_SECTION_ID).?;
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, segs[0..4], .little));
    try testing.expectEqual(
        @as(u64, @bitCast(d.map.segments[1].tps)),
        std.mem.readInt(u64, segs[4 + SEGMENT_REC_LEN + 16 ..][0..8], .little),
    );

    const bars = walked.find(BARS_SECTION_ID).?;
    try testing.expectEqual(BARS_PAYLOAD_LEN, bars.len);
    try testing.expectEqual(
        @as(u32, @intCast(d.map.bars.len)),
        std.mem.readInt(u32, bars[0..4], .little),
    );
    try testing.expectEqual(
        d.map.bars[d.map.bars.len - 1],
        std.mem.readInt(i64, bars[8..16], .little),
    );

    // A cue's name rides as bytes, so a `"` the author escaped in the
    // document is one byte here and the escaping is the reader's job.
    const cues = walked.find(CUES_SECTION_ID).?;
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, cues[0..4], .little));
    const name_len = std.mem.readInt(u16, cues[12..14], .little);
    try testing.expectEqualStrings("drop \"one\"", cues[16..][0..name_len]);

    // The lane index carries the extent, not the onsets.
    const lanes = walked.find(LANES_SECTION_ID).?;
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, lanes[0..4], .little));
    try testing.expectEqual(@intFromEnum(Doc.LaneKind.notes), lanes[4]);
    try testing.expectEqual(@as(u8, 0), lanes[5]); // not bound
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, lanes[8..12], .little));
    try testing.expectEqual(
        d.lanes[0].onsets[0].tick,
        std.mem.readInt(i64, lanes[16..24], .little),
    );
    try testing.expectEqual(
        d.lanes[0].onsets[1].tick,
        std.mem.readInt(i64, lanes[24..32], .little),
    );
    try testing.expectEqualStrings("flash", lanes[4 + LANE_REC_LEN ..][0..5]);
}

test "TprAbi: 'TPTL' — a list with nothing in it has no section at all" {
    const gpa = testing.allocator;
    var loaded = try deriveDoc(gpa, "(timeline :length 1bar)");
    defer loaded.result.deinit();
    var d = loaded.derived;
    defer d.deinit();

    const buf = try gpa.alloc(u8, timelineEncodedLen(&d));
    defer gpa.free(buf);
    const blob = try encodeTimeline(&d, buf);

    // Segments, meters and bars a document always has; sections, cues
    // and lanes this one has none of, and an absent section is how the
    // blob says so (an empty one would be a second spelling).
    const walked: Walked = .of(blob);
    try testing.expectEqualSlices(u32, &.{
        SEGMENTS_SECTION_ID,
        METERS_SECTION_ID,
        BARS_SECTION_ID,
    }, walked.ids[0..walked.len]);
}

test "TprAbi: 'TPTL' — one byte short is a refusal, never a partial blob" {
    const gpa = testing.allocator;
    var loaded = try deriveDoc(gpa, two_segment_doc);
    defer loaded.result.deinit();
    var d = loaded.derived;
    defer d.deinit();

    const exact = timelineEncodedLen(&d);
    const buf = try gpa.alloc(u8, exact);
    defer gpa.free(buf);
    @memset(buf, 0xaa);
    try testing.expectError(error.BufferTooSmall, encodeTimeline(&d, buf[0 .. exact - 1]));
    // Nothing was written: half a timeline is a wrong timeline.
    for (buf) |b| try testing.expectEqual(@as(u8, 0xaa), b);
}

test "TprAbi: 'TPTL' — a 70 000-byte cue name rides cut at a UTF-8 boundary, never wrapped" {
    // A `(cue :name …)` is a string in a document the doc zone holds a
    // megabyte of, so a name past the record's u16 length is INPUT, and
    // `tpr_load` → `tpr_timeline` reaches this encoder with it. Every
    // character is `é` (two bytes), so the 65 535-byte cut lands inside
    // one and backs off to the boundary before it.
    const gpa = testing.allocator;
    const name = try gpa.alloc(u8, 70_000);
    defer gpa.free(name);
    for (0..35_000) |i| @memcpy(name[2 * i ..][0..2], "é");
    const source = try std.fmt.allocPrintSentinel(
        gpa,
        "(timeline :length 1bar)\n(cue :name \"{s}\" :at 0bar)\n",
        .{name},
        0,
    );
    defer gpa.free(source);

    var loaded = try deriveDoc(gpa, source);
    defer loaded.result.deinit();
    var d = loaded.derived;
    defer d.deinit();
    try testing.expectEqual(@as(usize, 70_000), d.cues[0].name.len);

    const buf = try gpa.alloc(u8, timelineEncodedLen(&d));
    defer gpa.free(buf);
    const blob = try encodeTimeline(&d, buf);
    try testing.expectEqual(buf.len, blob.len);

    const cues = Walked.of(blob).find(CUES_SECTION_ID).?;
    const name_len = std.mem.readInt(u16, cues[12..14], .little);
    try testing.expectEqual(@as(u16, 65_534), name_len);
    const cut = cues[16..][0..name_len];
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expectEqualSlices(u8, name[0..name_len], cut);
}

test "TprAbi.wireName: whole when it fits, and a cut backs off at most three bytes" {
    const gpa = testing.allocator;
    try testing.expectEqualStrings("flash", wireName("flash"));

    const long = try gpa.alloc(u8, MAX_WIRE_NAME + 8);
    defer gpa.free(long);
    // ASCII: every byte is a boundary, so the cut is the ceiling itself.
    @memset(long, 'x');
    try testing.expectEqual(MAX_WIRE_NAME, wireName(long).len);
    // Not UTF-8 at all — continuation bytes as far as the eye can see, as
    // a `.mid` marker may be: there is no boundary to find, and the
    // back-off stops at its bound rather than walking the name.
    @memset(long, 0x80);
    try testing.expectEqual(MAX_WIRE_NAME - 3, wireName(long).len);
}

test "TprAbi: 'TPPH' — past 65 535 overlapping sections the tail carries the first 65 535" {
    // Sections may overlap, so how many hold one tick is the document's
    // number; the record's count is a u16, and a native host encoding
    // into its own buffer (not the wasm's 4 KiB zone) reaches this.
    const gpa = testing.allocator;
    const ids = try gpa.alloc(u32, 70_000);
    defer gpa.free(ids);
    for (ids, 0..) |*id, i| id.* = @intCast(i);
    const pos: Playhead.Position = .{
        .tick = 0,
        .bar = 0,
        .beat = 0,
        .sub_ticks = 0,
        .seconds_into_bar = 0,
        .section_ids = ids,
        .prev_cue = null,
        .next_cue = null,
        .order_row = null,
    };

    const buf = try gpa.alloc(u8, playheadEncodedLen(pos));
    defer gpa.free(buf);
    try testing.expectEqual(PLAYHEAD_LEN + 65_535 * 4, buf.len);
    const blob = try encodePlayhead(pos, buf);
    try testing.expectEqual(@as(u16, 65_535), std.mem.readInt(u16, blob[50..52], .little));
    const last = blob[PLAYHEAD_LEN + 65_534 * 4 ..][0..4];
    try testing.expectEqual(@as(u32, 65_534), std.mem.readInt(u32, last, .little));
}

test "TprAbi: 'TPPH' — one position, its flags and its section-id tail" {
    const gpa = testing.allocator;
    var loaded = try deriveDoc(gpa, two_segment_doc);
    defer loaded.result.deinit();
    var d = loaded.derived;
    defer d.deinit();

    var pos = try Playhead.atTick(gpa, &d, 184504320);
    defer pos.deinit(gpa);

    var buf: [PLAYHEAD_LEN + 64]u8 = undefined;
    const blob = try encodePlayhead(pos, &buf);
    try testing.expectEqual(playheadEncodedLen(pos), blob.len);
    try testing.expectEqual(PLAYHEAD_MAGIC, std.mem.readInt(u32, blob[0..4], .little));
    try testing.expectEqual(pos.tick, std.mem.readInt(i64, blob[8..16], .little));
    try testing.expectEqual(pos.bar, std.mem.readInt(i64, blob[16..24], .little));
    try testing.expectEqual(pos.beat, std.mem.readInt(i64, blob[24..32], .little));
    try testing.expectEqual(pos.sub_ticks, std.mem.readInt(i64, blob[32..40], .little));
    try testing.expectEqual(
        @as(u64, @bitCast(pos.seconds_into_bar)),
        std.mem.readInt(u64, blob[40..48], .little),
    );
    // One cue at 1bar, and the playhead is on it: prev present, next not.
    try testing.expectEqual(@as(u8, 1), blob[48]);
    try testing.expectEqual(@intFromEnum(Refusal.none), blob[49]);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, blob[52..56], .little));
    // The intro section is [0bar, 2bar), so the tail carries its index.
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, blob[50..52], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, blob[PLAYHEAD_LEN..][0..4], .little));
}

test "TprAbi: 'TPPH' — a refused clock carries the guard and nothing else" {
    var buf: [PLAYHEAD_LEN]u8 = @splat(0xaa);
    const blob = try encodeRefusal(.non_finite_time, &buf);
    try testing.expectEqual(PLAYHEAD_LEN, blob.len);
    try testing.expectEqual(PLAYHEAD_MAGIC, std.mem.readInt(u32, blob[0..4], .little));
    try testing.expectEqual(@intFromEnum(Refusal.non_finite_time), blob[49]);
    try testing.expectEqual(@as(i64, 0), std.mem.readInt(i64, blob[8..16], .little));
    try testing.expectEqual(@as(u8, 0), blob[48]);
    try testing.expectEqual(Refusal.tick_overflow, Refusal.of(error.TickOverflow));
    try testing.expectEqual(Refusal.non_finite_time, Refusal.of(error.NonFiniteTime));
    try testing.expectError(
        error.BufferTooSmall,
        encodeRefusal(.tick_overflow, buf[0 .. PLAYHEAD_LEN - 1]),
    );
}

test "TprAbi: 'TPDG' — pacer's layout, tempura's codes, three severities" {
    const gpa = testing.allocator;
    var load_diags: Diag.List = .init(gpa);
    defer load_diags.deinit();
    try load_diags.add(.anchor_unavailable, .err, .{ .start = 7, .end = 19 }, "no resolver", .{});
    var derive_diags: Diag.List = .init(gpa);
    defer derive_diags.deinit();
    try derive_diags.add(
        .tick_overflow,
        .warning,
        .{ .start = 0, .end = 0 },
        "past the ceiling",
        .{},
    );
    try derive_diags.add(.smpte_tempo_ignored, .info, .{ .start = 1, .end = 2 }, "smpte", .{});

    const sources = [_]DiagSource{
        .{ .stage = .document, .list = &load_diags },
        .{ .stage = .derivation, .list = &derive_diags },
    };
    const buf = try gpa.alloc(u8, diagsEncodedLen(&sources));
    defer gpa.free(buf);
    const blob = encodeDiags(&sources, buf);
    try testing.expectEqual(diagsEncodedLen(&sources), blob.len);

    try testing.expectEqual(DIAGS_MAGIC, std.mem.readInt(u32, blob[0..4], .little));
    try testing.expectEqual(DIAGS_VERSION, std.mem.readInt(u32, blob[4..8], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, blob[8..12], .little));

    // Record 0: the document stage, an error, the code's ordinal, the span.
    var off: usize = DIAGS_HEADER_LEN;
    try testing.expectEqual(@intFromEnum(Stage.document), blob[off]);
    try testing.expectEqual(@intFromEnum(Diag.Severity.err), blob[off + 1]);
    try testing.expectEqual(
        @intFromEnum(Diag.Code.anchor_unavailable),
        std.mem.readInt(u16, blob[off + 2 ..][0..2], .little),
    );
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, blob[off + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 19), std.mem.readInt(u32, blob[off + 8 ..][0..4], .little));
    const msg_len = std.mem.readInt(u32, blob[off + 12 ..][0..4], .little);
    try testing.expectEqualStrings("no resolver", blob[off + DIAG_RECORD_LEN ..][0..msg_len]);
    off += DIAG_RECORD_LEN + msg_len;

    // Records 1 and 2: the derivation stage, a warning then an info —
    // the third severity pacer's layout has no spelling for.
    try testing.expectEqual(@intFromEnum(Stage.derivation), blob[off]);
    try testing.expectEqual(@intFromEnum(Diag.Severity.warning), blob[off + 1]);
    off += DIAG_RECORD_LEN + std.mem.readInt(u32, blob[off + 12 ..][0..4], .little);
    try testing.expectEqual(@intFromEnum(Diag.Severity.info), blob[off + 1]);
}

test "TprAbi: 'TPDG' — a record that does not fit is dropped, and the count says so" {
    const gpa = testing.allocator;
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();
    try diags.add(.tick_overflow, .err, .{ .start = 0, .end = 0 }, "first", .{});
    try diags.add(.tick_overflow, .err, .{ .start = 0, .end = 0 }, "second", .{});

    const sources = [_]DiagSource{.{ .stage = .operation, .list = &diags }};
    // Room for the header and the first record alone.
    var buf: [DIAGS_HEADER_LEN + DIAG_RECORD_LEN + 5]u8 = undefined;
    const blob = encodeDiags(&sources, &buf);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, blob[8..12], .little));
    try testing.expectEqual(DIAGS_HEADER_LEN + DIAG_RECORD_LEN + 5, blob.len);
    try testing.expectEqualStrings("first", blob[DIAGS_HEADER_LEN + DIAG_RECORD_LEN ..][0..5]);
}
