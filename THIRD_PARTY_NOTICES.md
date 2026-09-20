# Third-party notices

tempura is CC0-1.0 (`LICENSE`). Nothing in this repository is ported from a
third-party codebase yet; this file is the register that says what may be, from
where, and under which condition, so an entry is added in the same commit as the
code it covers. The table of record is `docs/plans/09-conformance.md`, "License
discipline (the one place it lives)".

| Source | License | Discipline |
|---|---|---|
| Impulse Tracker source and docs (`~/llm/repositories/impulsetracker`) | BSD-3-style (Jeffrey Lim, 2014; `LICENSE.TXT` governs) | portable; the copyright notice is reproduced here with the ported code; the no-endorsement clause applies |
| OpenMPT (`~/llm/repositories/openmpt`) | BSD-3-Clause | portable with attribution: the history-block guard, the SMPTE division rule, the pattern packing scheme and the CP437 table, each with a source comment and an entry here. libopenmpt binaries are test-time assets from brew, pinned by version in `conformance/PINS.md`, never vendored |
| Schism Tracker | GPL-2.0-or-later | **doctrine only, never port code**; behaviour claims cite `file:line` |
| MMA RP-001 and the MIDI 1.0 specification | cited by document and section | the byte tables are restated in the plans' own words, only as far as implementing requires; never reproduced wholesale |
| OpenMPT wiki IT test cases | no explicit license | fetched by a hash-pinned script at test time, never vendored |
| Theatre.js (`~/llm/repositories/theatre`) | Apache-2.0 | cited for its data model in `docs/plans/00-vision-and-scope.md`; nothing ported |
| SJON (`~/Dev/SJON`) | local | sibling path dependency, as pacer consumes it |
| pacer (`~/Dev/pacer`) | CC0-1.0 | `schema/pacer.sjon` is copied verbatim (no attribution required; the provenance is in `CLAUDE.md` and `tools/pacer_schema_drift.sh`); the npm package is a dev-dependency of the wasm parity tests |
| tempura itself | CC0-1.0 | pacer's dedication; decided at E0 |
