//! Fixtures the time part's tests share.
//!
//! `derive.zig` and `Playhead.zig` both want the same conducted module
//! and the same "load a document the way a host does" helper, and a
//! production file is no place for either (the smf and itf parts keep
//! their fixtures in a `test_support.zig` for the same reason).

const std = @import("std");

const Module = @import("../itf/Module.zig");
const Schema = @import("../Schema.zig");
const fromSjon = @import("../doc/fromSjon.zig");

/// The three-segment map of plan 03, phase 3, as an Impulse Tracker
/// module: 125, 150 and 200 quarter notes per minute at ticks 0, 1q and
/// 2q.
///
/// Speed 6 and 24 ticks to the quarter make a row a 16th note, so row 4
/// is 1q and row 8 is 2q. Pattern 1 is a one-row `B01` that jumps to
/// itself: the walk ends at the second visit of that row, with the state
/// it left pattern 0 in — so the module plays its tempo changes ONCE and
/// the segment table is the three the document authored.
pub fn threeSegmentModule(gpa: std.mem.Allocator) !Module.Module {
    var b: Module.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;
    try b.addOrder(0);
    try b.addOrder(1);
    const song = try b.addPattern(16);
    // `Txx` with xx >= 0x20 sets the tempo: 0x96 = 150, 0xC8 = 200.
    song.at(4, 0).* = .{ .fx = 'T' - '@', .param = 150 };
    song.at(8, 0).* = .{ .fx = 'T' - '@', .param = 200 };
    const tail = try b.addPattern(1);
    tail.at(0, 0).* = .{ .fx = 'B' - '@', .param = 1 };
    return b.finish();
}

/// Load a document the way a host does — the preloaded manifests, one
/// source, no resolver — so a test can compare what the DOCUMENT layer
/// derived with what the time layer derives from its value.
pub fn load(gpa: std.mem.Allocator, source: [:0]const u8) !fromSjon.Result {
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    return fromSjon.fromSource(gpa, &schema, source, null);
}
