//! tempura — the timeline as a value.
//!
//! One SJON document, `(timeline …)`, is the authoritative arrangement of
//! a piece in musical time. Around it: the tick grid and the `TimeMap` for
//! three kinds of conductor, the `.mid` and `.it` cores that read and
//! write those files as values, the residue that carries what a file
//! cannot say, the edit engine, and the exporters that hand pacer a score.
//!
//! tempura is a PURE FUNCTION from documents and files to values, text and
//! bytes. It never reads a clock, never owns a loop, never plays anything:
//! it does not evaluate a value at time `t` — it produces the pacer score
//! that does. Same inputs ⇒ byte-identical outputs, native and wasm32.
//!
//! Memory model follows pacer's, which follows SJON's (see SJON
//! `src/root.zig`): every public entry point takes `gpa: std.mem.Allocator`
//! and returns an owned struct with arena-backed `.deinit()`; the struct
//! never retains the caller's GPA. Validation failures are `Diag`
//! diagnostics with spans on a successfully returned value — collection
//! over abort — never errors, and user input is never asserted on.

const std = @import("std");
const sjon = @import("sjon");

/// Package version. Mirrors `build.zig.zon`, and the test below is what
/// keeps the two spellings from drifting.
pub const version = "0.1.0";

/// The one diagnostic vocabulary: codes, severities, spans, and the
/// arena-backed collector every producer fills.
pub const Diag = @import("Diag.zig");

/// The timeline vocabulary, preloaded: the four composed manifests every
/// document is validated against, and the harness bundle beside them.
pub const Schema = @import("Schema.zig");

/// The SMF core (P100): `Sequence`, the bounded reader with its `SourceMap`,
/// the canonical writer. Pure Zig, no SJON.
pub const smf = @import("smf/smf.zig");

/// The IT core (P101): `Module`, regions, patterns, the canonical writer and
/// the timing walk. Pure Zig, no SJON.
pub const itf = @import("itf/itf.zig");

/// The time model (P103): the grid, positions and their spellings, the
/// tempo and meter maps.
pub const time = @import("time/time.zig");

test {
    _ = Diag;
    _ = Schema;
    _ = smf;
    _ = itf;
    _ = time;
}

test "version: src/root.zig and build.zig.zon spell the same version" {
    // Two hand-written spellings of one number; the npm package will be a
    // third. `build.zig` hands the repo root in as an ABSOLUTE path, so
    // this does not depend on where `zig build` was invoked from.
    const gpa = std.testing.allocator;
    const repo_root = @import("build_options").repo_root;

    const path = try std.fs.path.join(gpa, &.{ repo_root, "build.zig.zon" });
    defer gpa.free(path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(64 * 1024));
    defer gpa.free(manifest);

    const key = ".version = \"";
    const at = std.mem.indexOf(u8, manifest, key) orelse return error.ManifestHasNoVersion;
    const rest = manifest[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.ManifestVersionUnterminated;

    try std.testing.expectEqualStrings(rest[0..end], version);
}

test "build graph: the sjon path dependency and every schema import are wired" {
    // This repo's parts all plug into the same two seams, and neither is
    // visible to a type checker: SJON arrives as a sibling PATH dependency
    // built `plugin-exec = false`, and the five manifests arrive as
    // anonymous imports so they are readable with no filesystem (wasm32).
    // A renamed import or a moved manifest breaks every part at once, so
    // it fails here first, on the root, with one line to read.
    try std.testing.expectEqual(@as(i64, 0), @rem(sjon.Pattern.PPC, 16));
    try std.testing.expectEqual(@as(f64, 1.0), sjon.trig.exp64(0.0));

    inline for (.{
        "tempura_schema",
        "midi_schema",
        "it_schema",
        "pacer_schema",
        "corpus_schema",
    }) |name| {
        try std.testing.expect(@embedFile(name).len > 0);
    }
}
