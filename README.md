# tempura — the timeline as a value

The family's timeline core: a versatile timeline with no UI. One SJON document,
`(timeline …)`, is the authoritative arrangement of a piece in musical time — tempo and meter
maps, sections and cues, lanes of notes and keyframes, pattern queries and formulas, phrases
placed as clips, pacer's controls passed through. One tick grid contains SJON's and pacer's
grid, every DAW's SMF division and Impulse Tracker's tick exactly. A `.mid` and a `.it` are
read as values, 1:1 with the bytes, and written back deterministically; what the timeline says
and the file cannot rides in that file's own metadata slots, so the file alone reconstructs
the document while a DAW or a tracker still opens it as if nothing were there. tempura never
evaluates a value at time `t` — it exports the pacer score that does.

Zig 0.16, CC0-1.0, no runtime dependencies but SJON (sibling path checkout at `../SJON`).
The plans are in [`docs/plans/`](docs/plans/README.md); conventions in `CLAUDE.md`.

| Command | Purpose |
|---|---|
| `zig build test` | all inline tests; `-Dtest-root=<path>` runs one subtree's |
| `zig build verify` | the gate: test + native corpus + the pacer-schema drift check |
| `zig build corpus` | the native golden gate; `-- --update` regenerates |
| `zig build fuzz` | never-panic harnesses (separate from `verify`) |
| `zig build audit-diagnostics` | every `Diag.Code` variant is tested by name |
| `zig build wasm` | `tempura.wasm` (freestanding, ReleaseSmall) |
| `zig build cli` | the native `tempura` binary; `zig build run -- <args>` runs it |
