//! tempura's one diagnostic vocabulary.
//!
//! Every producer — the schema bridge, the format cores, the timing walk,
//! the edit engine, the exporters, the residue — reports through `Code`,
//! and every host decodes one enum. Validation failures are diagnostics on
//! a successfully returned value (collection over abort, the SJON
//! discipline), never errors: user input is never asserted on.
//!
//! ## Append-only, from E3
//!
//! A code's ORDINAL is the wire: it rides in the `'TPDG'` blob (pacer's
//! `'PACD'` layout) and in the CLI's JSON. Append at the END, never
//! reorder, never remove, never rename — `Diag.Code` freezes at E3
//! together with the residue payloads and the wasm exports (plan 04,
//! plan 10). The two tests at the bottom of this file are the gate, and
//! `zig build audit-diagnostics` refuses a code no test names.
//!
//! Severity is orthogonal to the code: the same condition can be an error
//! in one context and a warning in another (an inexact division refuses a
//! build and merely annotates a dump), so the producer chooses it.

const std = @import("std");
const testing = std.testing;

/// What went wrong, as a stable u16 that crosses every boundary.
///
/// Grouped by the part that raises it, in the order the parts were
/// planned; the grouping is documentation, the ORDER is the contract.
pub const Code = enum(u16) {
    // ---- positions, the grid, the maps (P103, plan 03) ----
    unit_required,
    position_not_integer,
    position_negative,
    tick_overflow,
    tempo_map_invalid,
    meter_map_invalid,
    meter_off_bar,
    conductor_conflict,

    // ---- the document: structure, anchors, addresses (P102, plan 02) ----
    timeline_duplicate,
    anchor_missing,
    anchor_dump_duplicate,
    anchor_conflict,
    anchor_mismatch,
    anchor_unavailable,
    address_invalid,
    bound_lane_has_content,
    bound_kind_invalid,
    note_overlap,
    clip_lane_missing,
    clip_nested,
    phrase_lane_bound,
    passthrough_conducts,
    scene_duplicate,
    passthrough_preferred_native,
    it_field_not_materialized,
    division_inexact,
    smpte_tempo_ignored,

    // ---- the SMF core (P100, plan 05) ----
    smf_format2,
    smf_bad_header,
    smf_ntrks_mismatch,
    smf_chunk_truncated,
    smf_track_truncated,
    smf_unknown_chunk,
    smf_riff_unwrapped,
    smf_running_status_across_meta,
    smf_set_tempo_zero,
    vlq_too_long,
    at_not_monotone,
    end_of_track_missing,
    end_of_track_early,
    ppq_rescale_inexact,
    note_retrigger,
    ease_hint_mismatch,

    // ---- the IT core and its timing walk (P101, plan 06) ----
    it_bad_magic,
    it_truncated,
    it_count_exceeds_spec,
    it_history_flag_without_block,
    it_pattern_rows_out_of_range,
    it_command_unknown,
    it_pattern_too_large,
    it_sample_extent_truncated,
    it_parapointer_out_of_range,
    it_message_encoding_lossy,
    it_no_instrument,
    walk_runaway,

    // ---- the residue (P104, plan 04) ----
    residue_only,
    residue_stale,
    residue_version,
    residue_newer_kept,
    residue_corrupt,
    residue_partial,
    residue_tail_truncated,

    // ---- the edit engine (P105, plan 07) ----
    edit_target_bound,
    edit_would_duplicate,
    edit_overlap,
    edit_off_bar,
    edit_pattern_shared,
    edit_range_empty,
    edit_inexact,
    edit_readonly_passthrough,

    // ---- the exporters (P106, plan 08) ----
    export_bpm_out_of_range,
    export_meter_unsupported,
    render_inexact,
    render_cc_missing,
    render_format_promoted,
    render_channels_exhausted,
    render_polyphony_exceeded,
    tempo_inexact,
    build_cross_kind,

    // ---- appended after the E0 seeding, in landing order ----

    /// SMF: a byte where an event's status was due is one no track may
    /// carry — a data byte with no running status in effect, or a system
    /// common / real-time status (`F1`..`F6`, `F8`..`FE`) a file has no
    /// room for. The reader keeps the prefix it parsed (P100, plan 05).
    smf_status_invalid,

    /// A foreign SJON diagnostic, carried through verbatim. The document
    /// bridge validates against the preloaded manifests and every
    /// complaint the SCHEMA raises belongs to SJON's own code space, not
    /// to this one — so it rides across under one tempura code, keeping
    /// SJON's rendered text as its message and SJON's span. tempura never
    /// re-spells a rule the manifest already says (`src/doc/`, plan 02).
    sjon_diagnostic,

    /// The document has no `(timeline …)` root, or one that is not its
    /// FIRST root — `timeline_duplicate`'s sibling for the other half of
    /// plan 02's "once, first". A head-set counts a form's children and
    /// not a document's roots, so both halves are host checks.
    timeline_missing,

    /// A `(note :key …)` string that is not a note name: a letter A-G,
    /// any number of `#` or `b`, then the octave (`"C4"` is 60, the midi
    /// set's convention, midi 02). The manifest types the slot as a
    /// string and says the spelling is checked host-side, so this is
    /// where a typo names the octave it could not read (plan 02,
    /// "(note …)").
    note_key_invalid,

    /// Two `(lane …)` forms share a `:name`. A lane's name is unique
    /// across the timeline's lanes — it is what a `(clip …)` matches a
    /// phrase's lane by, so a second one makes the match ambiguous
    /// (plan 02, "(lane …)"). A form's own shape cannot see a sibling,
    /// so this is a host check like `scene_duplicate` beside it.
    lane_duplicate,

    /// The residue could not encode the document's timeline tier: the
    /// tree is past one of SJON's Binary IR limits (`MAX_NODES`,
    /// `MAX_COMMENTS_PER_NODE`, `MAX_STRING_LENGTH`, the depth cap —
    /// `SJON/docs/LANGUAGE.md` §10.6), so there is no essence to carry
    /// and the file would hold only what its own format can say. The
    /// reader's counterpart is `residue_corrupt`; this one is the
    /// WRITER's, raised by `pack` and restated by a carrier handed an
    /// empty essence (plan 04, "What the residue is").
    residue_unencodable,

    /// `export-score`: a notes lane carries more onsets than pacer's
    /// parked `:at`-list cap of 1 000. Every onset is still emitted —
    /// plan 08's rule is that a trigger keeps them all — so this is the
    /// warning that says the score is past the size pacer's own plans
    /// budgeted for (plan 08, "The key budget", item 4).
    export_onset_budget,

    /// `export-score`: a curve lane printed more keys than
    /// `--max-keys-per-track`, the per-track share of pacer's
    /// `MAX_KEYS = 4096`. A bound lane has already been through both
    /// budget stages and a native one is never simplified at all, so the
    /// keys stand and the count is reported (plan 08, "The key budget",
    /// item 3).
    export_key_budget,

    /// `export-score`: the tempo map needs more than pacer's
    /// `MAX_TEMPO_SEGMENTS = 512` even after coalescing everything
    /// within `--tempo-eps` — a per-tick slide over a whole song. The
    /// score drops its `(tempo …)` table and prints every position in
    /// SECONDS instead, so the piece still sounds right while its bar
    /// and beat lanes run on the transport's one tempo (plan 08,
    /// "Transport and tempo"; the it set's 09 fallback).
    export_tempo_budget,

    /// `(it/midi …)`: a macro that cannot cross between the module's
    /// 4896-byte block and the document. On dump, a slot whose text is
    /// not printable ASCII (0x20..0x7E up to its NUL) has no spelling
    /// the document can carry losslessly, so it is left out and named,
    /// and reads back empty. On build, a `(macro …)` whose name is none
    /// of the 153 slots, whose body is past 32 characters (cut to 32)
    /// or holds a byte outside that range (left empty), or that spells
    /// a slot a second time (the later body stands). The volume column's
    /// `it_command_unknown` is the same shape for a pattern cell (plan
    /// 06, "The binary model").
    it_midi_macro_invalid,
};

/// How much a diagnostic costs its caller. Orthogonal to `Code` — the
/// producer decides, because the same condition is fatal in one verb and
/// an annotation in another.
pub const Severity = enum(u8) {
    /// The value the caller asked for is not usable as asked for.
    err,
    /// The value is usable, and something about it is not what the
    /// document said (a rounding, a promotion, a dropped detail).
    warning,
    /// Nothing is wrong; the producer is reporting a choice it made.
    info,
};

/// A half-open byte range `[start, end)` into whatever the producer
/// parsed — a document's text or a file's bytes. There is one span type
/// because a diagnostic never crosses from one into the other: the
/// producer that raised it knows which it read, and says so in the
/// message.
pub const Span = struct {
    start: u32,
    end: u32,
};

/// One reported condition.
pub const Diagnostic = struct {
    code: Code,
    severity: Severity,
    span: Span,
    /// Owned by the `List` that formatted it, and valid until that list's
    /// `deinit`. Never borrowed from the caller's buffers.
    message: []const u8,
};

/// This module's error set. Collecting a diagnostic can only fail the way
/// any allocation fails — a defective document is never an error here, it
/// IS the diagnostic (the SJON discipline, `CLAUDE.md`).
pub const Error = error{OutOfMemory};

/// The collector every producer fills: arena-backed, so a caller frees a
/// whole report in one call and no message outlives its list.
///
/// `init(gpa)` / `defer deinit()` is the whole lifetime (the memory model
/// in `src/root.zig`'s header). The list never retains the caller's GPA
/// beyond the arena it hands it to, and entries keep INSERTION order —
/// the order a producer walked its input is the order a host prints.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Diagnostic) = .empty,

    pub fn init(gpa: std.mem.Allocator) List {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *List) void {
        self.arena.deinit();
    }

    /// Append one diagnostic, formatting its message into the arena.
    ///
    /// The only failure is `OutOfMemory`: a diagnostic is never itself a
    /// reportable condition.
    pub fn add(
        self: *List,
        code: Code,
        severity: Severity,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        // The write side of `invariantsOf`'s span clause: a producer that
        // hands in an inverted span has a bug, whatever the input was.
        std.debug.assert(span.start <= span.end);
        const arena = self.arena.allocator();
        const message = try std.fmt.allocPrint(arena, fmt, args);
        try self.entries.append(arena, .{
            .code = code,
            .severity = severity,
            .span = span,
            .message = message,
        });
    }

    /// The report so far, in insertion order. Borrowed from the list.
    pub fn items(self: *const List) []const Diagnostic {
        return self.entries.items;
    }

    /// The read side: what every consumer of a WHOLE list may assume of
    /// it, asserted once at its entry (plan 12). `invariantsOf` is the
    /// same check over a borrowed slice, for a consumer that was handed
    /// several lists' entries joined.
    pub fn invariants(self: *const List) void {
        invariantsOf(self.entries.items);
    }

    /// Whether any entry is an `err` — the one question a caller asks
    /// before using the value a producer returned alongside the list.
    pub fn hasErrors(self: *const List) bool {
        for (self.entries.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }

    /// How many entries carry `code`, at any severity. The corpus and the
    /// tests count by code; nothing in the library branches on it.
    pub fn count(self: *const List, code: Code) usize {
        var n: usize = 0;
        for (self.entries.items) |d| {
            if (d.code == code) n += 1;
        }
        return n;
    }
};

/// What a consumer may assume of any run of diagnostics, wherever they
/// came from: every span runs forward (`start <= end`, asserted at the
/// write side in `add` too), and every code's ordinal is one `code_order`
/// pins, so what goes on the wire as a `u16` is a code a decoder with this
/// enum can name. Compiles out of `ReleaseSmall`, so the wasm pays nothing.
///
/// The span clause holds because the readers clamp: the IT reader spans a
/// truncation from a DECLARED offset, which may lie past the file's end,
/// and `itf/read.zig`'s `toEnd` clamps it to the length.
pub fn invariantsOf(diags: []const Diagnostic) void {
    for (diags) |d| {
        std.debug.assert(d.span.start <= d.span.end);
        const ordinal = @intFromEnum(d.code);
        std.debug.assert(ordinal < code_order.len);
        std.debug.assert(code_order[ordinal] == d.code);
    }
}

/// Every variant in ordinal order, pinned by NAME — the table the test
/// below walks. Append here in the same edit that appends to `Code`.
///
/// Deliberately a container-level const and NOT a literal inside a test
/// body: `tools/audit_diagnostic_coverage.sh` reads test bodies to find
/// out which codes a test names, and a table of all of them inside one
/// would hand every code its coverage for free — the audit would never
/// be able to fail again.
const code_order = [_]Code{
    .unit_required,
    .position_not_integer,
    .position_negative,
    .tick_overflow,
    .tempo_map_invalid,
    .meter_map_invalid,
    .meter_off_bar,
    .conductor_conflict,
    .timeline_duplicate,
    .anchor_missing,
    .anchor_dump_duplicate,
    .anchor_conflict,
    .anchor_mismatch,
    .anchor_unavailable,
    .address_invalid,
    .bound_lane_has_content,
    .bound_kind_invalid,
    .note_overlap,
    .clip_lane_missing,
    .clip_nested,
    .phrase_lane_bound,
    .passthrough_conducts,
    .scene_duplicate,
    .passthrough_preferred_native,
    .it_field_not_materialized,
    .division_inexact,
    .smpte_tempo_ignored,
    .smf_format2,
    .smf_bad_header,
    .smf_ntrks_mismatch,
    .smf_chunk_truncated,
    .smf_track_truncated,
    .smf_unknown_chunk,
    .smf_riff_unwrapped,
    .smf_running_status_across_meta,
    .smf_set_tempo_zero,
    .vlq_too_long,
    .at_not_monotone,
    .end_of_track_missing,
    .end_of_track_early,
    .ppq_rescale_inexact,
    .note_retrigger,
    .ease_hint_mismatch,
    .it_bad_magic,
    .it_truncated,
    .it_count_exceeds_spec,
    .it_history_flag_without_block,
    .it_pattern_rows_out_of_range,
    .it_command_unknown,
    .it_pattern_too_large,
    .it_sample_extent_truncated,
    .it_parapointer_out_of_range,
    .it_message_encoding_lossy,
    .it_no_instrument,
    .walk_runaway,
    .residue_only,
    .residue_stale,
    .residue_version,
    .residue_newer_kept,
    .residue_corrupt,
    .residue_partial,
    .residue_tail_truncated,
    .edit_target_bound,
    .edit_would_duplicate,
    .edit_overlap,
    .edit_off_bar,
    .edit_pattern_shared,
    .edit_range_empty,
    .edit_inexact,
    .edit_readonly_passthrough,
    .export_bpm_out_of_range,
    .export_meter_unsupported,
    .render_inexact,
    .render_cc_missing,
    .render_format_promoted,
    .render_channels_exhausted,
    .render_polyphony_exceeded,
    .tempo_inexact,
    .build_cross_kind,
    .smf_status_invalid,
    .sjon_diagnostic,
    .timeline_missing,
    .note_key_invalid,
    .lane_duplicate,
    .residue_unencodable,
    .export_onset_budget,
    .export_key_budget,
    .export_tempo_budget,
    .it_midi_macro_invalid,
};

test "Diag.Code: ordinals are dense and unique — the wire contract" {
    const fields = @typeInfo(Code).@"enum".fields;
    try testing.expect(fields.len > 0);

    // Dense: variant i has ordinal i. Nobody may pin an explicit value,
    // because a hole would make the ordinal space unreadable to a decoder
    // that only has an older enum.
    inline for (fields, 0..) |f, i| {
        try testing.expectEqual(i, f.value);
    }

    // Unique follows: distinct indices with `value == index` cannot
    // collide, so density IS ordinal uniqueness. (A repeated NAME is a
    // compile error in Zig, so there is nothing for a test to add there.)

    // The last variant carries the count − 1, so appending is the only
    // edit that keeps this true.
    const last: Code = @enumFromInt(fields.len - 1);
    try testing.expectEqual(fields.len - 1, @intFromEnum(last));
}

test "Diag.Code: every code is pinned by name to its ordinal" {
    // The append-only surface, spelled out: a code's ORDINAL is what
    // crosses the wire (`'TPDG'`), so a reorder, a removal or a rename is
    // a breaking change and has to fail here. The table it walks is
    // `code_order`, a container-level const — see the note there for why
    // it may not move into this body.
    try testing.expectEqual(@typeInfo(Code).@"enum".fields.len, code_order.len);
    for (code_order, 0..) |code, i| {
        try testing.expectEqual(i, @intFromEnum(code));
    }
}

test "Diag.List: add formats the message and preserves insertion order" {
    var list: List = .init(testing.allocator);
    defer list.deinit();

    try testing.expectEqual(@as(usize, 0), list.items().len);

    try list.add(
        .tick_overflow,
        .err,
        .{ .start = 4, .end = 9 },
        "tick {d} is past the grid ceiling",
        .{@as(i64, 1) << 53},
    );
    try list.add(
        .note_overlap,
        .warning,
        .{ .start = 12, .end = 20 },
        "lane {s} overlaps at {d}",
        .{ "kick", 3 },
    );

    const got = list.items();
    try testing.expectEqual(@as(usize, 2), got.len);

    try testing.expectEqual(Code.tick_overflow, got[0].code);
    try testing.expectEqual(Severity.err, got[0].severity);
    try testing.expectEqual(Span{ .start = 4, .end = 9 }, got[0].span);
    try testing.expectEqualStrings(
        "tick 9007199254740992 is past the grid ceiling",
        got[0].message,
    );

    try testing.expectEqual(Code.note_overlap, got[1].code);
    try testing.expectEqual(Severity.warning, got[1].severity);
    try testing.expectEqual(Span{ .start = 12, .end = 20 }, got[1].span);
    try testing.expectEqualStrings("lane kick overlaps at 3", got[1].message);
}

test "Diag.List: the message belongs to the list's arena, not the caller's buffer" {
    // The ownership contract: a producer formats from whatever it has on
    // hand — a slice into the document, a stack buffer — and the list
    // outlives all of it.
    var list: List = .init(testing.allocator);
    defer list.deinit();

    var lane = [_]u8{ 'k', 'i', 'c', 'k' };
    try list.add(
        .clip_lane_missing,
        .err,
        .{ .start = 0, .end = 1 },
        "lane {s} is missing",
        .{lane[0..]},
    );
    @memset(&lane, 'x');

    try testing.expectEqualStrings("lane kick is missing", list.items()[0].message);
}

test "Diag.List: invariants hold on an empty list, a full one and a joined slice" {
    var list: List = .init(testing.allocator);
    defer list.deinit();
    list.invariants();

    // Only codes this file's other tests already name: a test body here
    // counts as coverage for `tools/zt audit-diagnostics`, and a new name
    // would hand a code coverage nobody earned.
    try list.add(.tick_overflow, .err, .{ .start = 0, .end = 0 }, "empty span", .{});
    try list.add(.build_cross_kind, .info, .{ .start = 3, .end = 9 }, "another", .{});
    list.invariants();

    // A consumer handed several lists joined checks the slice it got.
    var joined: std.ArrayList(Diagnostic) = .empty;
    defer joined.deinit(testing.allocator);
    try joined.appendSlice(testing.allocator, list.items());
    try joined.appendSlice(testing.allocator, list.items());
    invariantsOf(joined.items);
    try testing.expectEqual(@as(usize, 4), joined.items.len);
}

test "Diag.List: hasErrors reflects severity and count is per code" {
    var list: List = .init(testing.allocator);
    defer list.deinit();

    try testing.expect(!list.hasErrors());
    try testing.expectEqual(@as(usize, 0), list.count(.render_inexact));

    // A warning and an info are not errors: a dump annotated with either
    // is still a dump the caller may keep.
    try list.add(.render_inexact, .warning, .{ .start = 0, .end = 2 }, "rounded to the grid", .{});
    try list.add(.render_inexact, .info, .{ .start = 2, .end = 4 }, "rounded again", .{});
    try testing.expect(!list.hasErrors());
    try testing.expectEqual(@as(usize, 2), list.count(.render_inexact));

    try list.add(
        .build_cross_kind,
        .err,
        .{ .start = 9, .end = 11 },
        "a .mid document cannot build a .it file",
        .{},
    );
    try testing.expect(list.hasErrors());
    try testing.expectEqual(@as(usize, 1), list.count(.build_cross_kind));
    try testing.expectEqual(@as(usize, 2), list.count(.render_inexact));
    try testing.expectEqual(@as(usize, 0), list.count(.tick_overflow));
}
