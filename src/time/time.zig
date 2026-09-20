//! P103, the time part: the tick grid and the positions that name points
//! on it.
//!
//! The aggregator re-exports the part's files and forces their inline
//! tests, so `zig build test -Dtest-root=src/time/time.zig` runs this
//! subtree alone with exactly the imports the root hands every part.

/// The one integer grid: `TPQ` ticks per quarter note and the exact
/// conversions from SMF divisions, IT ticks and pacer meters onto it.
pub const Grid = @import("Grid.zig");

/// Position literals (`2.5q`, `16bar`, `1t`), the one round-half-even
/// seam, and the printer's spelling rule.
pub const Pos = @import("Pos.zig");

test {
    _ = Grid;
    _ = Pos;
}
