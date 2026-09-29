# 01 — Part Map

Status: Active — 2026-09-19. Part of the [tempura plan set](README.md).

Continues the global part map: geometry-shaders P1–P10, geometry-ops P11–P17, curves P18–P25
and P32, post-fx P26–P31, it P33–P41, audzio P42–P53 and P58–P60, slug P54–P57 and P84,
expansible-player P61–P68, midi P69–P78, font-api P79–P83, gpu-ui P85–P90, xleditor P91–P98.
This set adds **P99–P109** under the same five-field discipline (purpose / public contract /
dependencies / isolated validation / standalone demo). The parts live in **`~/Dev/tempura`**
(cloned empty 2026-09-19; the name is the user's and stands), which depends on SJON as a
sibling path dependency exactly as pacer does (`~/Dev/pacer/build.zig.zon`,
`plugin-exec = false`). Nothing here depends on pngine, batida, midivia, audzio or animader.
pacer is consumed three ways, none of them a Zig import: its **schema file** is copied
verbatim and drift-gated ([02](02-timeline-schema.md)), its **score text** is emitted
([08](08-export.md)), and its **npm package** is a dev-dependency of the tests that prove
every emitted skeleton loads (`file:../../pacer/npm/pacer`, the midi set's idiom, midi 01).

## Layering rule (load-bearing)

The format cores never see SJON. `src/smf/` defines `Sequence` and reads and writes `.mid`
bytes (midi 03). `src/itf/` defines `Module` (the timing subset) and reads and writes `.it`
bytes with pass-through regions (it 03–05). `src/doc/` defines `Doc`, the one timeline
interchange value, and converts `Doc ⇄ SJON tree`, embedding `Sequence` and `Module` as the
document's `midi/` and `it/` tiers. Everything above (`time/`, `edit/`, `export/`, `residue/`)
consumes `Doc` and never bytes or trees. The residue is the one place bytes and `Doc` meet
again, and it meets them through the format cores' metadata slots, never by parsing a file
itself.

```
.mid bytes ⇄ smf/ ⇄ Sequence ─┐
.it  bytes ⇄ itf/ ⇄ Module   ─┤── doc/ ⇄ Doc ⇄ (timeline …) SJON tree (schema-validated)
                               │          │
   residue/ ◄──────────────────┘          ├→ time/   Time.derive → TimeMap → Playhead queries
   (metadata slots in both formats)       ├→ edit/   ops(Doc, args) → SJON edit actions
                                          └→ export/ score text | TimingData | .mid | .it
```

Consequences: `.mid → timeline` and `.it → export-score` build no tree; a `(timeline …)`
document lowers to `Doc` before anything runs; the edit engine returns actions and never
mutates; the exporters read `Doc` and the `TimeMap` and nothing else.

## New parts

| Part | Purpose | Public contract | Deps | Isolated validation | Standalone demo |
|---|---|---|---|---|---|
| **P99 `schema/` + `src/plugin.zig`** | the `tempura` vocabulary, the hosted `midi` and `it` core tiers, the pacer schema copy, catalogs (02) | `schema/tempura.sjon`, `schema/midi.sjon`, `schema/it.sjon`, `schema/pacer.sjon` (copy), `schema/*-catalog.sjon`; comptime `Plugin`s for the Zig host; `sjon-project.sjon` | SJON | catalog ↔ manifest both-ways coverage; validate-with-diagnostics over the doc corpus; the sibling-heads collision test; the pacer-copy drift test (02) | LSP-assisted authoring of a two-lane timeline from scratch |
| **P100 `src/smf/`** | `.mid` in and out (05) | `Sequence`, `read(bytes) → Sequence + SourceMap`, `write(Sequence, opts) → bytes`, `Vlq`, `Division` | none (pure Zig) | layout comptime pins; VLQ property tests; reader fuzz; `write ∘ read` fixed point on canonical files | `tempura inspect song.mid` |
| **P101 `src/itf/`** | `.it` in and out, the timing subset, pass-through regions, the timing walk (06) | `Module`, `read(bytes) → Module + SourceMap`, `write(Module, Resolver, opts) → bytes`, `pattern.{unpack,pack}`, `Walk.derive(Module) → RowMap` | none (pure Zig) | struct-size pins (192/554/80); pattern pack/unpack round-trip; reader fuzz; walk goldens on hand-built modules; pass-through byte-equality | `tempura inspect song.it` |
| **P102 `src/doc/`** | `Doc ⇄ SJON`, anchors and `(bin …)` resolution, the `midi/` and `it/` bridges (02, 05, 06) | `Doc`, `fromSjon(tree, Resolver) → Doc + diags`, `toSjon(Doc, opts) → Tree`, `Resolver` (anchored / external / inline), the canonical printer | SJON, P99, P100, P101 | round-trip gates `fromSjon(toSjon(d)) ≡ d`; the printer's position spellings (03); anchor sha256 refusal | `tempura dump song.it > song.sjon` and back |
| **P103 `src/time/`** | the grid, positions, the `TimeMap` for three conductors, position queries (03) | `Pos`, `TPQ`, `parse/print`, `Time.derive(Doc) → TimeMap`, `TimeMap.{tickFromSeconds, secondsFromTick, barOf, beatOf}`, `Playhead` | P101 (the walk), P102 | boundary-exact conversions; the three conductors on fixtures; grid tables asserted (every SMF PPQ, every pacer meter); overflow refused | `tempura timeline song.sjon` |
| **P104 `src/residue/`** | the metadata hack: essence, lane records, both carriers, reconciliation (04) | `Residue.pack(Doc) → payloads`, `Residue.unpack(payloads, Doc) → Doc + diags`, `smf.attach/detach`, `it.attach/detach` | P100, P101, P102 | essence round-trip byte-exact; the stale-hash reconciliation table; carriers survive the format's own reader; fuzz on unpack | `tempura build doc.sjon -o song.mid && tempura dump song.mid` |
| **P105 `src/edit/`** | timeline operations as SJON edit actions (07) | `Edit.Op` (the operation set), `plan(Doc, op) → []Action + diags`, `Snap`, `Select` | P102, P103 | every op: `apply(plan(d, op)) ≡ expected` on fixtures; layout preservation; determinism of action order; the retime-under-tempo-change table | `tempura edit doc.sjon --quantize 1/16 --lane kick` |
| **P106 `src/export/`** | pacer score text, `TimingData`, rendering to `.mid` and `.it` (08) | `exportScore(Doc, TimeMap, opts) → text`, `timingData(Doc) → TimingData`, `renderSmf(Doc) → Sequence`, `renderIt(Doc, Module?) → Module` | P102, P103, P104 | golden text; every skeleton reloads clean through `pacer.wasm` (node, dev-dep); grid-exactness fixtures; the key budget | `tempura export-score song.sjon` |
| **P107 `conformance/` + `corpus/`** | oracles, goldens, gates (09) | `corpus/<case>/…`, `conformance/harness/`, `zig build corpus`, `zig build conform` | P100–P106 | the harness self-tests on hand-built files | the green/red matrix in CI output |
| **P108 `src/cli/` + `wasm/` + `npm/tempura/`** | the `tempura` multi-tool, the wasm entry, the JS glue, pstudio hooks (10) | subcommands `dump / build / validate / inspect / timeline / export-score / export / inline / edit / at / timing / check-residue`; wasm exports `tpr_*`; `Tempura.load(wasm, text)` | P99–P106 | CLI goldens; node wasm smoke (load + timeline + edit + hash); the npm lockstep tests | itself |
| **P109 `demos/`** | one demo per milestone (11) | `doc.sjon` / `song.{mid,it}` + `README.md` + expected artifact each | all | none | themselves |

Dependency shape: P99 ← P102 → P100, P101; P103 ← P101, P102; P104 ← P100, P101, P102;
P105 ← P102, P103; P106 ← P102, P103, P104; P107 ← P100–P106; P108 ← P99–P106. No cycles.
P100 and P101 have zero SJON dependency and must stay that way; P103's grid arithmetic
(`Pos`, `TPQ`) is a leaf module the format cores may import for tick conversion, and it
depends on nothing.

## Repo layout

```
tempura/
├── build.zig / build.zig.zon         # dep: sjon (path ../SJON, plugin-exec=false)
├── sjon-project.sjon                 # composes the four manifests below for the LSP
├── schema/
│   ├── tempura.sjon                  # the timeline vocabulary (P99)
│   ├── midi.sjon                     # the hosted (smf …) core tier (midi 02, core forms only)
│   ├── it.sjon                       # the hosted (module …) vocabulary (it 02, with its 08-25 amendments)
│   ├── pacer.sjon                    # VERBATIM COPY of ../pacer/schema/pacer.sjon, drift-gated
│   ├── tempura-catalog.sjon          # provenance per form (Theatre / RP-001 / ITTECH / pacer)
│   └── tempura-corpus.sjon           # the corpus harness shape (pacer's pacer-corpus.sjon idiom)
├── src/
│   ├── root.zig                      # public surface; memory-model header (pacer's)
│   ├── plugin.zig                    # the SJON plugins (P99)
│   ├── smf/                          # Sequence, read, write, vlq, division (P100)
│   ├── itf/                          # Module, read, write, pattern, walk, regions (P101)
│   ├── doc/                          # Doc, fromSjon, toSjon, printer, resolver, bridges (P102)
│   ├── time/                         # Pos, TPQ, TimeMap, Playhead (P103)
│   ├── residue/                      # essence, records, smf carrier, it carriers (P104)
│   ├── edit/                         # ops, plan, snap, select (P105)
│   ├── export/                       # score, timing, render_smf, render_it, simplify (P106)
│   ├── cli/                          # main.zig + subcommands (P108)
│   ├── wasm_entry.zig                # tpr_* exports (P108)
│   ├── corpus_runner.zig             # the golden authority, native (P107)
│   └── fuzz.zig
├── corpus/<case>/{doc.sjon|song.mid|song.it, times.sjon, expected.sjon}
├── conformance/                      # oracle harness, pinned fixtures, CHECKLIST.md (P107)
├── npm/tempura/                      # ESM glue (P108)
├── examples/                         # a native piece, a DAW piece, a tracker piece
├── demos/                            # per milestone (P109)
├── docs/
│   ├── plans/                        # this set
│   ├── timeline-language.md          # GENERATED from schema/tempura.sjon (pacer's score-docs verb)
│   ├── residue.md                    # the payload formats, restated for implementers of other readers
│   └── grid.md                       # the tick grid and its tables, restated for consumers
└── LICENSE                           # CC0 (E0 decision)
```

## Build verbs

| Command | Purpose |
|---|---|
| `zig build test` | all inline tests (root.zig forces submodule discovery) |
| `zig build wasm` | `tempura.wasm` (freestanding, ReleaseSmall); budget gate set at E3 |
| `zig build corpus` | native golden gate; `-- --update` regenerates, diff reviewed |
| `zig build conform` | the oracle matrix (09); needs test-time assets, skips with a reason when absent |
| `zig build verify` | test + corpus + `node --test` in `npm/tempura` (wasm parity) + generated-docs drift + the pacer-schema drift check (when `../pacer` exists) |
| `zig build fuzz` | reader, VLQ, pattern unpack, residue unpack never-panic harnesses |
| `zig build audit-diagnostics` | every diagnostic code has a by-name test (pacer's tool, copied) |
| `zig build docs` | regenerate `docs/timeline-language.md` |
| `zig build cli` | the `tempura` binary |

## Conventions inherited from pacer (`~/Dev/pacer/CLAUDE.md`)

Allocators: every public entry point takes a `gpa` and returns an owned struct with arena-backed
`deinit`. Error sets: explicit per module; validation failures are diagnostics with spans, never
errors; user input is never asserted on. Wire surfaces (the residue payloads, the wasm exports,
the diagnostic code enum) are append-only from the tag that freezes them. Commits:
`type(scope): summary — detail`. One phase per context window; the plan's progress log is the
only carry-forward. `docs/timeline-language.md` is generated from the manifest's
`:description`s and drift-gated by `verify`.

## Risks / open questions

- **Four manifests, one project file.** pacer learned that two manifests declaring the same
  head cannot share an LSP project file (`pacer/CLAUDE.md`, "The golden corpus"). The four
  here share no head by construction (02's collision table), and a test loads them through
  `sjon.loadProject` and asserts it. The corpus harness manifest declares a `target` form like
  pacer's and stays out of the project file for the same reason.
  **Correction, 2026-09-21 (Task 19):** the harness manifest declares no `target` form; the
  collision is on `timing`, declared both by the it tier's header section and by the harness
  verb that echoes an IT conductor's walk. It stays out of the project file for that reason,
  which is the same reason with a different head.
- **Two sibling repos, one owner per file.** `itf/` restates a subset of batida's P34 and
  P36, `smf/` restates midivia's P70, and `schema/midi.sjon` and `schema/it.sjon` are the
  sibling sets' manifests: all four are designs from sets whose repos do not exist,
  implemented here first because tempura needs them. When batida or midivia starts, the two
  repos decide one owner per module and per manifest (the it set's layering already makes
  `format/` and `player/Timeline` SJON-free, so either direction is a path dependency, not a
  rewrite; a manifest with two masters would drift in a week). Filed as cross-set notes at
  E0 ([11](11-demos-and-milestones.md)).
- **The pacer schema copy** is a second spelling of pacer's vocabulary. `verify` diffs it
  against the sibling checkout when one exists and fails on drift; without a sibling the copy
  is trusted and the version it was taken from is written in its header comment.

- **Drift, read against the tree on 2026-09-29 (`cfe44a0`).** Claims above that the code
  overtook, left as written because the table is the E0 design: `src/plugin.zig` never
  existed — the schema preloads are `src/Schema.zig`; `TimingData`/`timingData` and
  `export/timing.zig` were dropped with pstudio on 2026-09-20 ([11](11-demos-and-milestones.md),
  ruling 2), so `export/` is score, render_smf, render_it and their helpers; the `timing` verb
  is not one of the CLI's eleven (`src/cli/Args.zig:34-46`: dump, build, validate, inspect,
  timeline, export-score, export, inline, edit, at, check-residue); there is no `wasm/`
  directory (`src/wasm_entry.zig`) and no `conformance/harness/` (the runner is
  `src/corpus_runner.zig`); `TimeMap` has no `beatOf` — the beat is a field of `barOf`'s
  answer (`src/time/TimeMap.zig:299-316`); pacer's dev dependency is
  `file:../../../pacer/npm/pacer`; and `verify` is test + lint + CLI goldens + corpus +
  `node --test` + the wasm budget + the pacer-schema drift check + the docs drift check
  (`build.zig:56-70`; CLAUDE.md's verb table is current, this one is not). The 2026-09-21
  correction under "Four manifests, one project file" was overtaken the same day: the harness
  manifest lost its `timing` verb (`schema/tempura-corpus.sjon:20`), so no head collides and
  the harness stays out of the project file because it is a script, not a document
  (CLAUDE.md, "The schema directory").
