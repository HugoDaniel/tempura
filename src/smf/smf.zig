//! P100, the SMF core: a Standard MIDI File as a value, read and written.
//!
//! `read` turns bytes into a `Sequence` (absolute ticks, typed events,
//! one byte pool) beside a `SourceMap` and a `Diag.List`; `write` turns a
//! `Sequence` back into the canonical byte layout plan 05 freezes at E1.
//! Between them sit the two fidelity rungs the whole design rests on:
//! `write(read(bytes)) == bytes` for any file this writer produced, and
//! `read(write(read(bytes)))` equal event for event to `read(bytes)` for
//! any file at all.
//!
//! Imports `std` and `../Diag.zig` and nothing else, for ever (plan 01,
//! the layering rule). Nothing here knows what SJON is: the bridge that
//! spells a `Sequence` as `(midi/…)` forms, the residue that rides in a
//! `7D 'tem'` payload, and the timing walk that reads its tempo events
//! are all built ON this, never into it.
//!
//! ```zig
//! var result = try smf.read(gpa, bytes);
//! defer result.deinit();
//! var file = try smf.write(gpa, &result.sequence, .{});
//! defer file.deinit();
//! ```
//!
//! The aggregator, as every part directory has one: `test { _ = … }`
//! forces the subtree's inline tests to be discovered by
//! `zig build test -Dtest-root=src/smf/smf.zig`.

const std = @import("std");

const sequence = @import("Sequence.zig");
const read_file = @import("read.zig");
const write_file = @import("write.zig");

/// Variable-length quantities: SMF's delta times and payload lengths.
pub const vlq = @import("vlq.zig");

// ---- the value ----

/// The header's `division`, and the conversion to a pulses-per-quarter
/// grid.
pub const Division = sequence.Division;
/// A whole `.mid` as an arena-backed value.
pub const Sequence = sequence.Sequence;
/// One `MTrk`, its events in file order.
pub const Track = sequence.Track;
/// One event at an absolute tick.
pub const Event = sequence.Event;
/// What an event is — every row of RP-001's tables, plus tempura's.
pub const Kind = sequence.Kind;
/// What an event carries, in twelve bytes.
pub const Payload = sequence.Payload;
/// A run of bytes in a `Sequence`'s pool.
pub const Bytes = sequence.Bytes;
/// A preserved chunk that is neither `MThd` nor `MTrk`.
pub const ForeignChunk = sequence.ForeignChunk;
/// A parsed `7D 74 65 6D` payload: tempura's residue envelope.
pub const TempuraResidue = sequence.TempuraResidue;
/// Builds a `Sequence` programmatically.
pub const Builder = sequence.Builder;

// ---- reading ----

/// What `read` returns: the sequence, the map, and the report.
pub const Result = read_file.Result;
/// Where every chunk and every event came from.
pub const SourceMap = read_file.SourceMap;
/// Read a Standard MIDI File. Total on arbitrary bytes.
pub const read = read_file.read;

// ---- writing ----

/// The canonical writer's switches.
pub const Options = write_file.Options;
/// The bytes a `write` produced, and what it thought of them.
pub const Written = write_file.Written;
/// Write a `Sequence` as a Standard MIDI File.
pub const write = write_file.write;

/// This part's error set: only resource exhaustion. Every defect of a
/// file or of a sequence is a diagnostic on a returned value.
pub const Error = error{OutOfMemory};

test {
    _ = sequence;
    _ = vlq;
    _ = read_file;
    _ = write_file;
}

test "smf: the surface a consumer uses, end to end" {
    const gpa = std.testing.allocator;

    var b: Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 0;
    b.division = .{ .ppq = 96 };
    const track = try b.addTrack();
    try b.addEvent(track, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(track, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(track, 96, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
    var built = try b.finish();
    defer built.deinit();

    var file = try write(gpa, &built, .{});
    defer file.deinit();
    try std.testing.expect(!file.diags.hasErrors());

    var result = try read(gpa, file.bytes);
    defer result.deinit();
    try std.testing.expect(!result.diags.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), result.sequence.tracks.len);
    try std.testing.expectEqual(@as(usize, 4), result.sequence.tracks[0].events.len);
    try std.testing.expectEqual(Kind.end_of_track, result.sequence.tracks[0].events[3].kind);
    try std.testing.expectEqual(@as(u15, 96), result.sequence.division.pulsesPerQuarter());
    // `MThd` and one `MTrk`, and the header is the six bytes it must be.
    try std.testing.expectEqual(@as(usize, 2), result.source_map.chunks.len);
    try std.testing.expectEqual(@as(u32, 6), result.source_map.chunks[0].len);
}
