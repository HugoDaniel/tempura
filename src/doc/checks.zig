//! The rules plan 02 states over the finished VALUE.
//!
//! `fromSjon.zig` walks the tree and builds a `Doc`; these four read the
//! `Doc` and never the tree. The seam is real and not a filing
//! convenience: an anchor's bytes, two notes overlapping, a clip's
//! phrase and a scene's name are all relations between values that a
//! tree walk happens to be standing next to, and the edit engine will
//! want to ask the same four questions of a `Doc` it has changed without
//! a tree in sight. (The split is also what the brief asks for once
//! `fromSjon.zig` passes its size: one responsibility per file.)
//!
//! Every one of them collects rather than aborts, and every diagnostic
//! carries the offending form's span from the value it was read into.

const std = @import("std");

const Diag = @import("../Diag.zig");
const Doc = @import("Value.zig");
const Resolver = @import("Resolver.zig");

const testing = std.testing;

/// Collecting a diagnostic can only fail the way any allocation fails.
pub const Error = error{OutOfMemory};

/// The anchor rules, at the point where its bytes would be honoured
/// (plan 02, "(anchor …)"; the controller's ruling on the two optional
/// keys).
///
/// An INLINE dump's anchor is left alone HERE and verified where its
/// dump is read instead (`fromSjon.Ctx.verifiedAnchorBytes`): an
/// `(it/module …)` keeps each opaque body as a `(bin :at :len)` into the
/// anchor's file, so those bytes are honoured after all and the check
/// belongs beside the offsets it guards, once per dump. A BY-REFERENCE
/// anchor is read only when the host handed the bridge a resolver:
/// without one nothing was asked of anybody, and the anchor is recorded
/// unresolved in silence.
///
/// Sets `anchor.resolved` on success. Either way the anchor stays in
/// the document: it is recorded, and what could not be verified is said
/// with a span rather than dropped.
pub fn anchorBytes(
    diags: *Diag.List,
    anchor: *Doc.Anchor,
    resolver: ?Resolver.Resolver,
) Error!void {
    if (anchor.inline_dump) return;
    const r = resolver orelse return;
    const span = anchor.span;

    const bytes = r.read(anchor.file) orelse {
        try diags.add(
            .anchor_unavailable,
            .err,
            span,
            "no resolver could read \"{s}\"; the anchor is recorded unresolved",
            .{anchor.file},
        );
        return;
    };
    // The manifest made `:size` and `:sha256` optional; the host does
    // not. Bytes honoured without both cannot be verified, and an
    // unverifiable read is the same refusal as a failed one — never a
    // silent re-read.
    const size = anchor.size orelse {
        try diags.add(
            .anchor_mismatch,
            .err,
            span,
            "\"{s}\" was read, and this anchor declares no :size to check it against",
            .{anchor.file},
        );
        return;
    };
    const digest = anchor.sha256 orelse {
        try diags.add(
            .anchor_mismatch,
            .err,
            span,
            "\"{s}\" was read, and this anchor declares no readable :sha256 to check it against",
            .{anchor.file},
        );
        return;
    };
    if (!Resolver.verify(bytes, size, digest)) {
        try diags.add(
            .anchor_mismatch,
            .err,
            span,
            "\"{s}\" is {d} bytes and does not match the declared :size {d} / :sha256",
            .{ anchor.file, bytes.len, size },
        );
        return;
    }
    anchor.resolved = true;
}

/// Two notes on one key overlapping in one lane (plan 02,
/// `note_overlap`; the midi set's `note_overlaps_self`).
///
/// A note with no duration sounds over an empty window and overlaps
/// nothing, which is what `[at, at + dur)` says. O(n²) over one lane's
/// notes, which is the honest shape: the pairs are what the rule is
/// about, and a lane's note count is a document's, not a file's.
pub fn noteOverlap(diags: *Diag.List, lane: *const Doc.Lane) Error!void {
    for (lane.notes, 0..) |a, i| {
        if (a.dur <= 0) continue;
        for (lane.notes[i + 1 ..]) |b| {
            if (b.dur <= 0 or b.key != a.key) continue;
            if (b.at < a.at +| a.dur and a.at < b.at +| b.dur) {
                try diags.add(
                    .note_overlap,
                    .err,
                    b.span,
                    "lane {s} already sounds key {d} at tick {d}",
                    .{ lane.name, a.key, b.at },
                );
            }
        }
    }
}

/// A clip places the phrase's lane of the same `:name` as the placing
/// lane; a phrase with no such lane places nothing (plan 02,
/// `clip_lane_missing`). That the phrase EXISTS is SJON's cross-ref and
/// not this.
///
/// Answers the furthest tick any clip reaches, which is the other half
/// of the `:length` default rule — "the end of the last event OR CLIP".
/// A clip's window is its `:length`, or the phrase's length times
/// `:repeat` minus `:offset`.
pub fn clipPlacement(diags: *Diag.List, doc: *const Doc.Doc) Error!i64 {
    var furthest: i64 = 0;
    for (doc.lanes) |lane| {
        for (lane.clips) |clip| {
            const phrase = doc.phraseByName(clip.phrase) orelse continue;

            var found = false;
            for (phrase.lanes) |pl| {
                if (std.mem.eql(u8, pl.name, lane.name)) found = true;
            }
            if (!found) try diags.add(
                .clip_lane_missing,
                .err,
                clip.span,
                "phrase {s} has no lane named {s}, so this clip places nothing",
                .{ clip.phrase, lane.name },
            );

            const window = clip.length orelse
                (phrase.length *| @as(i64, clip.repeat)) -| clip.offset;
            furthest = @max(furthest, clip.at +| @max(0, window));
        }
    }
    return furthest;
}

/// A section exports to a pacer `(scene …)` of the same name (plan 02,
/// plan 08), so two sections of one name and a pass-through scene under
/// a section's name are the same collision, `scene_duplicate`.
pub fn sceneNames(diags: *Diag.List, doc: *const Doc.Doc) Error!void {
    for (doc.sections, 0..) |s, i| {
        for (doc.sections[i + 1 ..]) |other| {
            if (std.mem.eql(u8, s.name, other.name)) try diags.add(
                .scene_duplicate,
                .err,
                other.span,
                "a section named {s} is already declared, and each exports to a pacer scene of that name",
                .{other.name},
            );
        }
    }
    for (doc.passthrough) |p| {
        if (!std.mem.eql(u8, p.head, "scene")) continue;
        const name = sceneName(p.text) orelse continue;
        for (doc.sections) |s| {
            if (std.mem.eql(u8, s.name, name)) try diags.add(
                .scene_duplicate,
                .err,
                p.span,
                "a (section :name {s} …) already exports to a scene of that name",
                .{name},
            );
        }
    }
}

/// Two `(lane …)` forms sharing a `:name` (plan 02, "(lane …)":
/// "`:name` symbol, unique across the timeline's lanes").
///
/// The name is what a `(clip …)` matches a phrase's lane by and what
/// `:target` defaults to, so a second one makes both ambiguous. Reported
/// at the SECOND lane's span — the first is the one that was already
/// there. A phrase's lanes are a different namespace (one per placing
/// lane name) and are not checked against these.
pub fn laneNames(diags: *Diag.List, doc: *const Doc.Doc) Error!void {
    for (doc.lanes, 0..) |lane, i| {
        for (doc.lanes[i + 1 ..]) |other| {
            if (std.mem.eql(u8, lane.name, other.name)) try diags.add(
                .lane_duplicate,
                .err,
                other.span,
                "a lane named {s} is already declared; a lane's name is unique across the timeline's lanes",
                .{other.name},
            );
        }
    }
}

/// The `:name` of a pass-through `(scene …)`, read out of its source
/// text.
///
/// A scene is pacer's form and tempura never parses one — it keeps the
/// text and hands it back (plan 02: "tempura never derives from them and
/// never edits them"). This reads the one token the rule has to compare
/// and answers null when the text spells none, which is a name that
/// cannot collide rather than a guess.
///
/// A QUOTED name is unquoted: pacer types a scene's `:name` as a string
/// (`schema/pacer.sjon`), so `(scene :name "intro" …)` and
/// `(section :name intro …)` are the same name and must collide. The
/// unquoting is textual and deliberately shallow — an escape inside a
/// scene name would not compare equal, which fails towards NOT reporting
/// a collision rather than towards inventing one.
fn sceneName(src: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, src, ":name") orelse return null;
    var i = at + ":name".len;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    if (i < src.len and src[i] == '"') {
        const start = i + 1;
        const close = std.mem.indexOfScalarPos(u8, src, start, '"') orelse return null;
        return if (close > start) src[start..close] else null;
    }
    const start = i;
    while (i < src.len and !std.ascii.isWhitespace(src[i]) and src[i] != ')') i += 1;
    return if (i > start) src[start..i] else null;
}

// ---------------------------------------------------------------------
// Tests
//
// The end-to-end tests for every code below live in `fromSjon.zig`, on
// whole documents — that is where the span and the message are worth
// asserting on. These are the unit tests for the parts a document
// cannot easily reach: the arithmetic and the text scan.
// ---------------------------------------------------------------------

fn lanesOf(notes: []Doc.Note) Doc.Lane {
    return .{
        .name = "flash",
        .kind = .notes,
        .target = "flash",
        .range = null,
        .binding = null,
        .notes = notes,
        .keyframes = &.{},
        .clips = &.{},
        .query_src = null,
        .expr_src = null,
        .span = .{ .start = 0, .end = 1 },
    };
}

fn note(at: i64, dur: i64, key: u7) Doc.Note {
    return .{
        .at = at,
        .dur = dur,
        .key = key,
        .vel = 100,
        .ch = 0,
        .off_vel = null,
        .span = .{ .start = @intCast(at), .end = @intCast(at + 1) },
    };
}

test "checks.noteOverlap: the half-open window, one key at a time" {
    var diags: Diag.List = .init(testing.allocator);
    defer diags.deinit();

    // Touching is not overlapping: `[0, 4)` then `[4, 8)`.
    var touching = [_]Doc.Note{ note(0, 4, 36), note(4, 4, 36) };
    var lane = lanesOf(&touching);
    try noteOverlap(&diags, &lane);
    try testing.expectEqual(@as(usize, 0), diags.count(.note_overlap));

    // Different keys never collide, however deep they sit in each other.
    var keys = [_]Doc.Note{ note(0, 8, 36), note(1, 8, 38) };
    lane = lanesOf(&keys);
    try noteOverlap(&diags, &lane);
    try testing.expectEqual(@as(usize, 0), diags.count(.note_overlap));

    // A zero-length note sounds over nothing.
    var empty = [_]Doc.Note{ note(0, 0, 36), note(0, 4, 36) };
    lane = lanesOf(&empty);
    try noteOverlap(&diags, &lane);
    try testing.expectEqual(@as(usize, 0), diags.count(.note_overlap));

    // And the real thing, reported at the SECOND note's span.
    var over = [_]Doc.Note{ note(0, 8, 36), note(4, 8, 36) };
    lane = lanesOf(&over);
    try noteOverlap(&diags, &lane);
    try testing.expectEqual(@as(usize, 1), diags.count(.note_overlap));
    try testing.expectEqual(@as(u32, 4), diags.items()[0].span.start);
}

test "checks.sceneName: the one token the scene rule compares" {
    try testing.expectEqualStrings("intro", sceneName("(scene :name intro :at 0b :dur 4b)").?);
    try testing.expectEqualStrings("intro", sceneName("(scene :at 0b :name intro)").?);
    try testing.expectEqualStrings("intro", sceneName("(scene :name intro)").?);
    // No name, or nothing after it: a scene that cannot collide.
    try testing.expect(sceneName("(scene :at 0b :dur 4b)") == null);
    try testing.expect(sceneName("(scene :name )") == null);
}

test "checks.clipPlacement: the furthest tick a clip reaches" {
    const gpa = testing.allocator;
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var doc: Doc.Doc = .empty(gpa);
    defer doc.deinit();

    var phrase_lanes = [_]Doc.Lane{lanesOf(&.{})};
    var phrases = [_]Doc.Phrase{.{
        .name = "fill",
        .length = 100,
        .lanes = &phrase_lanes,
        .span = .{ .start = 0, .end = 1 },
    }};
    var clips = [_]Doc.Clip{.{
        .at = 1000,
        .phrase = "fill",
        .repeat = 3,
        .offset = 20,
        .length = null,
        .transpose = 0,
        .span = .{ .start = 0, .end = 1 },
    }};
    var lanes = [_]Doc.Lane{lanesOf(&.{})};
    lanes[0].clips = &clips;
    doc.phrases = &phrases;
    doc.lanes = &lanes;

    // 100 ticks of phrase, three times, less the 20-tick offset: the
    // window is 280 and the clip sits at 1000.
    try testing.expectEqual(@as(i64, 1280), try clipPlacement(&diags, &doc));
    try testing.expectEqual(@as(usize, 0), diags.count(.clip_lane_missing));

    // An explicit `:length` is the window instead.
    clips[0].length = 50;
    try testing.expectEqual(@as(i64, 1050), try clipPlacement(&diags, &doc));

    // A phrase with no lane of the placing lane's name places nothing.
    phrase_lanes[0].name = "glow";
    _ = try clipPlacement(&diags, &doc);
    try testing.expectEqual(@as(usize, 1), diags.count(.clip_lane_missing));
}

test "checks.sceneName: a quoted name is the same name" {
    // pacer types a scene's `:name` as a string, so the two spellings of
    // one name have to collide.
    try testing.expectEqualStrings("intro", sceneName("(scene :name \"intro\" :at 0b :dur 4b)").?);
    try testing.expectEqualStrings("bar 41", sceneName("(scene :name \"bar 41\")").?);
    try testing.expect(sceneName("(scene :name \"\")") == null);
    try testing.expect(sceneName("(scene :name \"unterminated)") == null);
}

test "checks.laneNames: the second lane of a name is lane_duplicate" {
    const gpa = testing.allocator;
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();

    var doc: Doc.Doc = .empty(gpa);
    defer doc.deinit();

    var lanes = [_]Doc.Lane{ lanesOf(&.{}), lanesOf(&.{}), lanesOf(&.{}) };
    lanes[0].name = "flash";
    lanes[1].name = "glow";
    lanes[2].name = "flash";
    lanes[2].span = .{ .start = 77, .end = 99 };
    doc.lanes = &lanes;

    try laneNames(&diags, &doc);
    try testing.expectEqual(@as(usize, 1), diags.count(.lane_duplicate));
    // Reported at the SECOND one: the first is the lane that was there.
    try testing.expectEqual(@as(u32, 77), diags.items()[0].span.start);

    lanes[2].name = "pulse";
    var clean: Diag.List = .init(gpa);
    defer clean.deinit();
    try laneNames(&clean, &doc);
    try testing.expectEqual(@as(usize, 0), clean.count(.lane_duplicate));
}
