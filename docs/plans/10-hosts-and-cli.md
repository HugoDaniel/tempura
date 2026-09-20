# 10 — Hosts and CLI

Status: Active — 2026-09-19. Part of the [tempura plan set](README.md). Owns **P108**
(`src/cli/`, `wasm/`, `npm/tempura/`), the pstudio integration and the expansible-player
payload kind. The wasm exports **freeze at E3**.

## The `tempura` CLI

| Verb | Contract |
|---|---|
| `dump song.{mid,it} [-o doc.sjon]` | file → document: the `midi/` or `it/` tier inline, the timeline tier from the residue or derived ([04](04-residue.md)); `--spans` adds byte offsets as comments; `--patterns=bin`, `--preserve-foreign`, `--preserve-history` (it 03); `--cues` emits a cue per played order |
| `build doc.sjon [-o song.{mid,it}]` | document → file, kind from `-o`'s extension or `--kind`; renders native lanes and attaches the residue ([08](08-export.md), [04](04-residue.md)); `--format 0`, `--ppq N [--round]`, `--no-running-status` (05); `--compress` is refused (no codec; pass-through only), `--loose`, `--in-place` (06); `--no-residue` for a file that carries nothing |
| `validate doc.sjon` | schema + host checks (anchors, addresses, cross-refs, the walk's diagnostics) with spans; exit code for CI; SJON's diagnostic output shape |
| `inspect song.{mid,it}` | the annotated offset map (chunks or regions, events or patterns, running status, SMPTE conversion, the residue's location) |
| `timeline doc.sjon [-o map.sjon]` | the `TimeMap` as data: tempo segments, meters, bars, sections, cues, per-lane onsets, length, loop point; `--json` for the studio's shape |
| `export-score doc.sjon [-o s.score.sjon]` | the pacer skeleton (08): `--velocity`, `--ease linear`, `--eps`, `--no-hints`, `--tempo-eps`, `--max-keys-per-track`, `--section-markers` |
| `export doc.sjon --kind mid\|it [-o …]` | the rendered native view without the residue (`build --no-residue`), for a file that will only ever be played |
| `inline doc.sjon [--anchor id]` | dumps a by-reference anchor's tiers into the document so its content becomes editable (07, "Bound content"); writes the document back with layout preserved |
| `edit doc.sjon --op '<json>' [--dry-run]` | plans and applies one operation (07); `--dry-run` prints the actions; `--select` takes the selection spelling |
| `at doc.sjon --seconds 12.5 \| --pos 17bar` | one `Playhead` answer, decoded: tick, bar, beat, sections, cues, sounding notes, the tracker position under an IT conductor |
| `timing doc.sjon` | `TimingData` as JSON, the studio provider's payload |
| `check-residue song.{mid,it}` | reports what the file carries (essence version, lane records and their hash verdicts, IT chunk and tail), the survival measurement's tool |

`.sjon` inputs go through P102; `.mid` and `.it` inputs skip SJON until the bridge builds the
tier ([01](01-part-map.md)). Everything honours `NO_COLOR`, writes diagnostics to stderr and
artifacts to stdout or `-o`.

## Wasm exports

`tempura.wasm` (freestanding, ReleaseSmall) exposes the table below. Three exports ship at
E2 for the studio provider (`tpr_loadFile`, `tpr_timing`, `tpr_at`) and are provisional
until E3; the whole set is append-only from E3, with the diagnostic-code enum:

| Export | Role |
|---|---|
| `tpr_abiVersion`, `tpr_docCap`, `tpr_fileCap` | the handshake, pacer's shape |
| `tpr_load(len) → status` | a document's text at `tpr_docPtr`; validates before unload (pacer's `drv_load` rule); anchors by reference are unresolved in wasm (no filesystem) and reported `anchor_unavailable`, so a browser host inlines first |
| `tpr_loadFile(kind, len) → status` | `.mid` or `.it` bytes at `tpr_filePtr`; the dump happens in wasm and `tpr_text()` returns the document |
| `tpr_attachAnchor(len) → status` | the bytes of the loaded document's `(anchor …)` at `tpr_filePtr`, checked against its `:size` and `:sha256`, so `(bin …)` refs and bound lanes resolve in a fresh instance; an inline `it/` dump still needs this for its `:raw` and `data` regions, so a saved document plus its file always reloads and rebuilds |
| `tpr_text() → len` | the current document as canonical text at `tpr_textPtr` |
| `tpr_timeline() → len` | `'TPTL'`: the `TimeMap` as a packed blob (segments, meters, bars, sections, cues, lane index), pacer's `'PACM'` framing with a TLV section stream |
| `tpr_at(seconds) → len`, `tpr_atTick(tick) → len` | `'TPPH'`: one `Playhead` record (tick, bar, beat, sub, section ids, prev and next cue, the IT order/row) |
| `tpr_snap(tick, grid, swing) → tick` | the snapping helper |
| `tpr_plan(len) → len` | an operation as JSON at `tpr_opPtr` → actions as JSON at `tpr_outPtr` |
| `tpr_apply(len) → status` | actions as JSON → the document re-loaded; `tpr_text()` reads it back |
| `tpr_exportScore(flags) → len` | pacer score text at `tpr_outPtr` |
| `tpr_timing() → len` | `TimingData` as JSON text |
| `tpr_build(kind) → len` | the file bytes at `tpr_outPtr`, residue attached |
| `tpr_diagLen/Ptr` | diagnostics, pacer's `'PACD'` layout with tempura's code enum (`'TPDG'`) |

The wasm budget: both format cores, the bridges, the time model, the edit engine, the
exporters, the residue, and SJON's parser, validator, printer, `Edit` and Binary IR. The E3
gate pins the size at what it measures and `verify` fails on growth past it (pngine's
budget discipline).

## The npm package

`npm/tempura`: ESM-only JSDoc-typed JS with generated `.d.ts`, Biome, `node --test`, the pacer
package's shape (`pacer/CLAUDE.md`, "npm package"). Exports: `.` (`Tempura` around the wasm:
`load(wasm, text | bytes)`, `timeline()`, `at(seconds)`, `plan(op)`, `apply(actions)`,
`exportScore()`, `timing()`, `build(kind)`), `./ops` (typed builders for the operation JSON),
`./blobs` (the `'TPTL'`, `'TPPH'`, `'TPDG'` decoders, one `DataView` pass each). Published to
the self-hosted Gitea registry like pacer; the version is spelled in `package.json`,
`build.zig.zon` and `src/root.zig` with a lockstep test.

## pstudio integration (in pstudio, sequenced here)

pstudio consumes pacer as a `file:` sibling and syncs `pacer.wasm` into `editor/public/`
(`pstudio/scripts/sync-wasm.mjs`, per the midi set; not on this machine). tempura follows the
same route: a `file:../../tempura/npm/tempura` dependency, `tempura.wasm` synced beside
`pacer.wasm`, the same hardlink-versus-glue hazard documented in the same place.

Three touch points, each behind the house pure/edge split (decisions in `lib/`, Svelte dumb):

1. **The exact provider** (E2): `tempuraProvider` in `lib/score/timing-provider.ts`,
   `available()` true when `tempura.wasm` loads, `analyze(bytes)` calling `tpr_loadFile` then
   `tpr_timing`, accepting `.it` and `.mid`. This is pacer's `plans/it/03-exact-import.md`
   Phase 3 with tempura in batida's slot: the same seam, the same red (a Txx fixture the
   approx provider gets wrong), auto-preferred over `approx-ts` when available. Phase 4's
   approx-versus-exact comparison line and the capacity pins follow.
2. **The timeline pane** (E4): pacer plan 07 draws keys from `'PACM'` anchors and writes back
   through spans, with the score text as the authority. With tempura the studio gains a
   second model: a `(timeline …)` document beside the score, `'TPTL'` for the strip (lanes,
   sections, cues, the bar grid under a real meter map, the tracker's order/row from
   `tpr_at`), operations through `tpr_plan`/`tpr_apply`, and `tpr_exportScore` regenerating
   the score's tempura-owned region. **Two authorities is the studio's design question**, not
   tempura's: the plan of record is a `;; tempura` fenced region in the score (pacer plan 10
   Phase 3's `;;` template-block discipline) that the studio regenerates and the author does
   not edit, with everything outside the fence hand-authored and passed through. It is filed
   as a studio plan at E4 with this outline; tempura's contract is the exports above.
3. **The transport display**: `tpr_at(masterClock())` per frame for bar, beat, section and
   the tracker position, replacing the studio's `it-timing` beat math for imported modules
   (pacer plan 06's approximation) with the walk's truth, zero renderer readback (it 09's
   rule).

## Payload kind (expansible-player)

One kind reserved in `docs/payload-kinds.md` (expansible-player 02's registry): `TMPU`, the
tempura document as SJON text (or Binary IR, flagged), the source a `PACR` score was exported
from. **No handler in v1**: the tiny player conducts from `PACR` and never needs the timeline;
a `.png` carrying `PNGB` + `PACR` + `TMPU` keeps the piece's arrangement beside its score so a
studio can reopen it. Registered when expansible-player X1 assigns the envelope.

## Phases (P108)

1. **E1: CLI skeleton + `dump`/`build`/`validate`/`inspect`/`timeline`.** `build` writes no
   residue yet (P104 is E3). Reds: goldens per verb over the fixtures; exit codes;
   diagnostics on stderr. Green: `cli/main.zig` and the verbs. Gate: CLI goldens.
2. **E2: `export-score`, `timing`, `at`, and the first wasm exports.** Reds: goldens;
   `timing --json` equals the wasm's `tpr_timing`; `tpr_loadFile` + `tpr_timing` + `tpr_at`
   through `node --test`. Green: the verbs, a provisional `wasm_entry.zig`. Gate: goldens +
   the pacer reload proof (08) + node.
3. **E2, in pstudio: touch point 1.** Its own phase in pstudio's repo. Gate: editor tests +
   a manual smoke logged here.
4. **E3: `inline`, `edit`, `export`, `check-residue`, `build` with residue.** Reds: layout
   preserved through `inline` and `edit`; `--dry-run` prints the corpus's plan text;
   `check-residue`'s verdict table. Green: the verbs. Gate: goldens + corpus.
5. **E3: the wasm entry, whole, and the npm package.** Reds: every export through
   `node --test`; the caps; blob decoders; the corpus parity walk; the lockstep tests; the
   fresh-instance round trip `loadFile → text → new instance → load + attachAnchor → build`
   byte-equal to the native build, for both kinds. Green: `wasm_entry.zig`, `npm/tempura`.
   Gate: verify + the size budget; the freeze.
6. **E4, in pstudio: touch points 2–3**, each its own phase there. Gate: editor tests + a
   manual smoke logged here.
7. **E4: the payload kind**, after expansible-player X1: the registry row, one packed demo.

## Risks / open questions

- **Two wasm modules in the studio** (pacer's and tempura's) double the sync and skew hazards
  (the midi set's risk, identical). A version line in the Motion tab's status bar keeps it
  visible; `tempura.wasm` is larger than `pacer.wasm` (two format cores, SJON's `Edit`), and
  the budget gate says by how much.
- **Anchors in the browser.** Inlining does not free a document from its file: an inline
  `it/` dump keeps `:raw` and `data` regions as `(bin …)` refs by design (bytes are sacred).
  `tpr_attachAnchor` is therefore part of the frozen E3 surface, not a candidate, and the
  studio keeps the imported file's bytes beside the document; `--patterns=bin` keeps a
  document small when only the timeline tier is being edited.
- **`tpr_loadFile` runs both readers inside the studio's wasm** on every dialog open; a
  pathological file is bounded by `tpr_fileCap`.
