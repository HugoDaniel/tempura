//! The timeline vocabulary, preloaded once.
//!
//! Four portable SJON manifests make one project: `schema/tempura.sjon`
//! (the timeline tier and the only original vocabulary here),
//! `schema/midi.sjon` and `schema/it.sjon` (the sibling sets' file
//! vocabularies, hosted under `midi/` and `it/`), and `schema/pacer.sjon`
//! (a verbatim copy, so a keyframe's `:ease` is typed by pacer's own
//! `pacer/ease-spec` and any pacer form passes through a timeline
//! document). They share no head — plan 02's collision table — so one
//! aggregate resolves every bare head.
//!
//! Each is `@embedFile`'d via its build import, so the whole vocabulary
//! reaches wasm32-freestanding with no filesystem.
//!
//! This module owns the TWO-PHASE construction (pacer's `src/Schema.zig`):
//! the manifests are parsed, loaded and aggregate-validated ONCE into a
//! `sjon.Host.PreloadedSchema`, and every `validate` hands that bundle
//! back through `HostOptions.preloaded`. The document is then parsed on
//! its own, so every diagnostic span is a DOCUMENT coordinate by
//! construction — there is no manifest prefix to subtract.
//!
//! `loadCorpus` is the second bundle: `schema/tempura-corpus.sjon`, the
//! golden-corpus harness vocabulary, preloaded ALONE. It is never
//! composed with the timeline one — both declare a `timing` form (the
//! `it/` tier's header section, and the harness verb that echoes a
//! conductor's walk), and one schema holding two would make every
//! unqualified `(timing …)` `ambiguous_form` in documents and in harness
//! files alike. Two bundles, never a shared schema — pacer's rule for
//! `pacer-corpus.sjon`, with a different head doing the colliding.
//!
//! Lifetime — the borrow-whole rule, pacer's outer ring: a `HostResult`
//! borrows the bundle (its plugin structs alias the preload arena), so
//! build a `Schema` once, above every result, and deinit it last.
//!
//! ```zig
//! var schema = try tempura.Schema.load(gpa);
//! defer schema.deinit();
//! var res = try tempura.Schema.validate(gpa, &schema, doc_source);
//! defer res.deinit();
//! ```

const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;

const Schema = @This();

/// Explicit error set. A malformed manifest is not an error here — see
/// `load`: these manifests are `@embedFile`'d repo content, so a defect in
/// one is a build defect, not a diagnostic a caller could handle.
pub const Error = error{OutOfMemory};

/// The timeline vocabulary — plan 02's eight global heads, the three
/// slot-locals under `lane`, and the `position` kind of plan 03.
pub const tempura_manifest_src: [:0]const u8 = @embedFile("tempura_schema");

/// The hosted `midi/` tier: the SMF file vocabulary, core forms only.
pub const midi_manifest_src: [:0]const u8 = @embedFile("midi_schema");

/// The hosted `it/` tier: the Impulse Tracker vocabulary.
pub const it_manifest_src: [:0]const u8 = @embedFile("it_schema");

/// pacer's score manifest, copied verbatim (drift-gated by
/// `tools/pacer_schema_drift.sh`).
pub const pacer_manifest_src: [:0]const u8 = @embedFile("pacer_schema");

/// The golden-corpus harness vocabulary. Its own bundle — see the header.
pub const corpus_manifest_src: [:0]const u8 = @embedFile("corpus_schema");

/// The four timeline manifests in composition order. `plugins[i]` of a
/// bundle loaded from this follows the same order.
pub const timeline_manifest_srcs = [_][:0]const u8{
    tempura_manifest_src,
    midi_manifest_src,
    it_manifest_src,
    pacer_manifest_src,
};

/// The loaded bundle. Borrowed by every `HostResult` built against it.
preloaded: sjon.Host.PreloadedSchema,

/// Preload the four composed timeline manifests. O(manifests), paid ONCE
/// per host.
///
/// Asserts they loaded with zero diagnostics. That is not laxity about
/// user input (the SJON discipline is collection over abort for
/// *documents*): these are repo-owned embedded manifests, so a defect in
/// one has no user to report it to. The assert is non-vacuous — the test
/// below feeds `loadSourcesUnchecked` a broken manifest and watches it diagnose.
pub fn load(gpa: Allocator) Error!Schema {
    return loadChecked(gpa, &timeline_manifest_srcs);
}

/// Preload the golden-corpus harness vocabulary ALONE. Never composed
/// with `load`'s bundle — see the module header.
pub fn loadCorpus(gpa: Allocator) Error!Schema {
    return loadChecked(gpa, &.{corpus_manifest_src});
}

/// `load` over an arbitrary set of EMBEDDED manifests — same build
/// invariant, same assert.
pub fn loadChecked(gpa: Allocator, sources: []const [:0]const u8) Error!Schema {
    var self = try loadSourcesUnchecked(gpa, sources);
    errdefer self.deinit();
    std.debug.assert(self.preloaded.diagnostics.len == 0);
    return self;
}

/// `loadChecked` without the assert: the composition a caller reaches
/// for when the manifests may legitimately disagree — the sibling-heads
/// cross-check composes vocabularies that collide with each other on
/// purpose, and the test below feeds it a broken manifest to show
/// `loadChecked`'s assert is guarding something. Production code that
/// owns its manifests calls `load` / `loadCorpus`.
pub fn loadSourcesUnchecked(gpa: Allocator, sources: []const [:0]const u8) Error!Schema {
    return .{ .preloaded = try sjon.Host.preloadSchema(gpa, sources) };
}

/// Release the bundle. Every `HostResult` built against it must be
/// deinited FIRST — see the module header.
pub fn deinit(self: *Schema) void {
    self.preloaded.deinit();
    self.* = undefined;
}

/// Validate one document against a preloaded bundle. The convenience
/// every caller wants: the document is parsed on its own and the bundle
/// rides in through `HostOptions.preloaded`, so spans are document
/// coordinates and the manifests are not re-read.
///
/// The result borrows `schema` and owns its own arena; `deinit` it before
/// the schema.
pub fn validate(
    gpa: Allocator,
    schema: *const Schema,
    source: [:0]const u8,
) sjon.Host.Error!sjon.Host.HostResult {
    return sjon.Host.validateDocument(gpa, source, .{ .preloaded = &schema.preloaded });
}

test {
    _ = @import("schema_tests.zig");
}

const t_ = std.testing;

test "Schema: the four embedded manifests preload clean and compose" {
    var schema = try load(t_.allocator);
    defer schema.deinit();

    try t_.expectEqual(@as(usize, 0), schema.preloaded.diagnostics.len);
    try t_.expect(!schema.preloaded.hasErrors());

    // Four manifests in, four plugins out, in composition order.
    try t_.expectEqual(@as(usize, 4), schema.preloaded.plugins.len);
    for ([_][]const u8{ "tempura", "midi", "it", "pacer" }, schema.preloaded.plugins) |want, got| {
        try t_.expectEqualStrings(want, got.name);
    }
}

test "Schema: load's assert is non-vacuous — a broken manifest does diagnose" {
    // Same code path as `load`, minus the assert: `:underlying` names a
    // shape that does not exist, so the loader reports and the plugin
    // carries the defect. If this came back clean, `load`'s assert would
    // be guarding nothing.
    var schema = try loadSourcesUnchecked(t_.allocator, &.{
        \\(plugin :name broken
        \\  (value-kind :name nope :underlying not-a-shape))
    });
    defer schema.deinit();

    try t_.expect(schema.preloaded.diagnostics.len > 0);
}

test "Schema: the corpus harness vocabulary preloads alone" {
    var schema = try loadCorpus(t_.allocator);
    defer schema.deinit();

    try t_.expectEqual(@as(usize, 0), schema.preloaded.diagnostics.len);
    try t_.expectEqual(@as(usize, 1), schema.preloaded.plugins.len);
    try t_.expectEqualStrings("tempura-corpus", schema.preloaded.plugins[0].name);
}

test "Schema: the corpus and timeline vocabularies are never composed" {
    // Both declare a `timing` form: the `it/` tier's header section, and
    // the harness verb that echoes a conductor's walk. Composing them is
    // what the two-bundle rule exists to prevent, and this is the proof
    // that the collision is real rather than theoretical — the same
    // aggregate that resolves `timing` cleanly in `load`'s bundle reports
    // it ambiguous the moment the harness manifest joins.
    var one = try load(t_.allocator);
    defer one.deinit();
    try t_.expect(one.preloaded.schema.lookupForm("timing", null) == .found);

    var both = try loadSourcesUnchecked(t_.allocator, &(timeline_manifest_srcs ++ [_][:0]const u8{corpus_manifest_src}));
    defer both.deinit();
    try t_.expect(both.preloaded.schema.lookupForm("timing", null) == .ambiguous);
}

test "Schema: the timeline vocabulary is reachable through the bundle" {
    var schema = try load(t_.allocator);
    defer schema.deinit();

    // Plan 02's eight global heads.
    for ([_][]const u8{
        "timeline", "anchor", "tempo-point", "meter-point",
        "section",  "cue",    "lane",        "phrase",
    }) |head| {
        try t_.expect(schema.preloaded.schema.lookupForm(head, null) == .found);
    }
    // …and `note` / `keyframe` / `clip` are NOT among them: they are
    // slot-local to `(lane …)`, so the only way to reach one is through
    // its parent's positional head-set.
    for ([_][]const u8{ "note", "keyframe", "clip" }) |head| {
        try t_.expect(schema.preloaded.schema.lookupForm(head, null) != .found);
    }
}

test "Schema: no manifest declares a :version — one spelling of the version, not two" {
    // `:version` exists to be pinned by a `(use-plugin … :version …)` a
    // timeline document never writes (the schema is preloaded, not
    // resolved by name), so a number here is read by nobody and drifts
    // from the real one in `build.zig.zon` / `src/root.zig`. pacer's copy
    // declares none for the same reason, and the drift check keeps it so.
    var schema = try load(t_.allocator);
    defer schema.deinit();

    for (schema.preloaded.plugins) |p| try t_.expectEqualStrings("", p.version);
}

test "Schema: the workspace project file composes these same four manifests" {
    // `sjon-project.sjon` is what `sjon-lsp` and the `sjon` CLI read to
    // learn the timeline vocabulary; the five `manifest_src` constants
    // are what every host embeds. Nothing but this test says they are the
    // same files — a renamed manifest, a stale `:plugins` path or a
    // typo'd project key costs every example and every corpus document
    // its editor support and breaks nothing that builds.
    //
    // The route is the real one: `sjon.loadProject` over the repo root is
    // precisely what an LSP handler calls.
    const repo_root = @import("build_options").repo_root;

    var project = try sjon.loadProject(t_.allocator, .{
        .project_root = repo_root,
        .io = t_.io,
    });
    defer project.deinit();

    // Project-file parse failures, unknown project keys (advisory) and
    // per-manifest load failures all land here.
    try t_.expectEqual(@as(usize, 0), project.diagnostics.len);

    // `plugins[0]` is `core`, seeded by the loader; the four are what the
    // project file contributed — and the harness manifest is NOT among
    // them (see the module header). Membership, not order: the resolver
    // decides the order it loads a project's `:plugins` in, and nothing
    // downstream depends on it (the four share no head).
    try t_.expectEqual(@as(usize, 5), project.plugins.len);
    for ([_][]const u8{ "tempura", "midi", "it", "pacer" }) |want| {
        var found = false;
        for (project.plugins[1..]) |got| {
            if (std.mem.eql(u8, want, got.name)) found = true;
        }
        if (!found) {
            std.debug.print("sjon-project.sjon does not compose `{s}`\n", .{want});
            return error.ProjectPluginMissing;
        }
    }
    for (project.plugins[1..]) |got| {
        try t_.expect(!std.mem.eql(u8, "tempura-corpus", got.name));
        try t_.expect(!std.mem.eql(u8, "tempura-catalog", got.name));
    }

    // Head for head: every form a host preloads resolves through the
    // workspace schema an editor builds, with no `ambiguous_form`.
    var schema = try load(t_.allocator);
    defer schema.deinit();
    for (schema.preloaded.plugins) |plugin| {
        for (plugin.forms) |form| {
            try t_.expect(project.schema.lookupForm(form.name, plugin.name) == .found);
        }
    }
}
