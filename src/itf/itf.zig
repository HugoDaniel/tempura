//! `src/itf/` — the Impulse Tracker core: `.it` bytes ⇄ `Module`.
//!
//! The part aggregator (plan 01, "One file per responsibility, one
//! aggregator per part"): it re-exports the part's files and forces their
//! inline tests, so `zig build test -Dtest-root=src/itf/itf.zig` runs the
//! whole subtree.
//!
//! The IT core reads and writes the parts of a module that carry TIME —
//! the header's timing fields, the orders, every pattern's rows, the song
//! message — and treats everything else as sacred opaque REGIONS
//! (`{off, len}` into the anchor's bytes): instrument bodies, sample
//! headers and data, the MIDI configuration, the edit history, foreign
//! trailing chunks. Nothing opaque is ever decoded; the writer copies the
//! bytes (plan 06, "Scope line").
//!
//! Imports `std` and `../Diag.zig` and nothing else, for ever (plan 01,
//! "Layering rule").

const std = @import("std");

/// The value model: `Module` and everything it holds, plus `Builder` for
/// constructing one without bytes and the CP437 ⇄ UTF-8 transcoders.
pub const model = @import("Module.zig");

/// Where an opaque region ends: sample-data extents, the edit-history
/// guard, MIDI-config detection.
pub const regions = @import("regions.zig");

/// `.it` bytes → `Module` + `SourceMap` + diagnostics.
pub const read = @import("read.zig");

/// ITTECH's pattern packing, both directions.
pub const pattern = @import("pattern.zig");

/// `Module` → `.it` bytes in plan 06's canonical layout.
pub const write = @import("write.zig");

// The names a consumer reaches for most, lifted to the part's namespace.
pub const Module = model.Module;
pub const Builder = model.Builder;
pub const Header = model.Header;
pub const Pattern = model.Pattern;
pub const Cell = model.Cell;
pub const Region = model.Region;
pub const Sample = model.Sample;
pub const Opaque = model.Opaque;
pub const Foreign = model.Foreign;

test {
    _ = model;
    _ = regions;
    _ = read;
    _ = pattern;
    _ = write;
}
