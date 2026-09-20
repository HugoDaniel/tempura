//! Bound content (plan 07, "Bound content, precisely").
const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const doc = @import("../doc/doc.zig");
const Grid = @import("../time/Grid.zig");
const walk = @import("../itf/walk.zig");

const Op = @import("Op.zig");
const Plan = @import("Plan.zig");
const Select = @import("Select.zig");
const locate = @import("locate.zig");
const ops_native = @import("ops_native.zig");
const value = @import("value.zig");

const testing = std.testing;

pub const Error = error{OutOfMemory};

pub fn plan(
    gpa: std.mem.Allocator,
    d: *const doc.Doc,
    tree: *const sjon.Ast.Tree,
    op: Op.Op,
) Error!Plan.Plan {
    return ops_native.plan(gpa, d, tree, op);
}

// ---------------------------------------------------------------------------

const test_support = @import("test_support.zig");

/// A document whose one anchor is an inline `.mid`.
pub const smf_source: [:0]const u8 =
    \\; bound — the SMF fixture
    \\(timeline :title "bound" :conductor song :length 2bar)
    \\
    \\(anchor :id song :kind smf :file "x.mid")
    \\(midi/smf :format 0 :division 480)
    \\(midi/mtrk
    \\  (set-tempo      :at 0    :us 500000)
    \\  (control-change :at 0    :ch 1 :num 74 :val 10)
    \\  ; the downbeat
    \\  (note-on        :at 0    :ch 1 :key 36 :vel 100)
    \\  (note-off       :at 240  :ch 1 :key 36 :vel 64)
    \\  (note-on        :at 480  :ch 1 :key 38 :vel 90)
    \\  (note-off       :at 720  :ch 1 :key 38 :vel 64)
    \\  (control-change :at 960  :ch 1 :num 74 :val 100)
    \\  (note-on        :at 960  :ch 1 :key 41 :vel 80)
    \\  (note-off       :at 1200 :ch 1 :key 41 :vel 64)
    \\  (end-of-track   :at 1920))
    \\
    \\(lane :name kick :kind notes :from song :track 1 :ch 1)
    \\(lane :name filter :kind curve :from song :track 1 :ch 1 :cc 74)
    \\
;

/// A document whose one anchor is an inline `.it`.
pub const it_source: [:0]const u8 =
    \\; bound — the IT fixture
    \\(timeline :title "bound" :conductor mod :length 4bar)
    \\
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
    \\
    \\(lane :name lead :kind notes :from mod :channel 1)
    \\
;

test "probe: the fixtures load" {
    const gpa = testing.allocator;
    {
        var fx = try test_support.Fixture.init(gpa, smf_source);
        defer fx.deinit();
        std.debug.print("\nSMF tiers={d} tracks={d}\n", .{ fx.doc_().midi.len, fx.doc_().midi[0].sequence.tracks.len });
        for (fx.doc_().midi[0].sequence.tracks[0].events, 0..) |e, i| {
            std.debug.print("  ev {d}: {t} @{d}\n", .{ i, e.kind, e.at });
        }
    }
    {
        var fx = try test_support.Fixture.init(gpa, it_source);
        defer fx.deinit();
        std.debug.print("\nIT tiers={d}\n", .{fx.doc_().it.len});
        var map = try walk.derive(gpa, &fx.doc_().it[0].module, .{});
        defer map.deinit();
        std.debug.print("  rows={d} total={d}\n", .{ map.rows.len, map.total_ticks });
        for (map.rows) |r| std.debug.print("   order {d} pat {d} row {d} @{d} +{d}\n", .{ r.order, r.pattern, r.row, r.start_tick, r.ticks });
        for (map.onsets) |o| std.debug.print("   onset ch {d} @{d} note {d}\n", .{ o.channel, o.tick, o.cell.note });
    }
}
