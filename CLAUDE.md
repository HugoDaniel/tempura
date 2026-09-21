# tempura — Project Conventions

tempura is a Zig 0.16 timeline core: one SJON document, `(timeline …)`, is the
authoritative arrangement of a piece in musical time, and `.mid` and `.it` files
are read as values and written back deterministically around it. It is a PURE
FUNCTION from documents and files to values, text and bytes — no clock, no loop,
nothing played. It does not evaluate a value at time `t`; it exports the pacer
score that does. Same inputs ⇒ byte-identical outputs, native and wasm32.

tempura sits in a constellation: it consumes **SJON** (parser, validator, `Expr`,
the `Pattern` tick core, `Edit` — a sibling path dependency), and feeds **pacer**
(the deterministic playback kernel) the score text it plays. Its hosts are the
`tempura` CLI, `npm/tempura` around `tempura.wasm`, expansible-player's payload
kind and animader's piece format. pstudio is NOT a host (ruled 2026-09-20). The
plan set is `docs/plans/` — read `README.md` there first, and
`11-demos-and-milestones.md` when picking up work: its status board and decision
log are the ledger.

## Every build goes through `tools/zt`

`tools/zt <verb>`, never `zig build` and never `zig test`. It is a `mkdir` lock
that serialises compilation machine-wide and caps the job count (`ZT_JOBS`,
default 4). Several parallel Debug test builds exhaust this machine's memory,
which is the incident that created the script. If it prints `waiting`, wait.

## Conventions inherited from pacer (`~/Dev/pacer/CLAUDE.md`, plan 01)

**Allocators.** Every public entry point takes `gpa: std.mem.Allocator` and returns
an owned struct with arena-backed `.deinit()`; the struct never retains the
caller's GPA. Bind with `var`, `defer .deinit()`. The long-form memory model lives
in `src/root.zig`'s `//!` header — read it once.

**Error sets.** Explicit `pub const Error = error{ … }` per module. Validation
FAILURES are not errors: they are `Diag.Diagnostic`s with spans on a successfully
returned value (collection over abort, the SJON discipline). User input is never
asserted on — `std.debug.assert` is for internal invariants only.

**Determinism.** One documented seam per conversion, integer tick math everywhere
else, overflow as a diagnostic and never a wrap. No `@sin`, `@exp` or libm in any
value path. No output order that depends on hash-map iteration.

**Commits.** One logical change each, `type(scope): summary — detail`. One phase
per context window; the plan's progress log is the only carry-forward.

**Code style.** SJON's: `//!` module headers describing role and invariants; `///`
on public APIs with ownership and lifetime notes; `comptime { std.debug.assert(
@sizeOf(T) == …); }` layout pins as build breaks; Zig 0.16 containers
(`var list: std.ArrayList(T) = .empty; try list.append(gpa, x);`). `zig fmt` clean.

## The wire-stable surfaces, frozen at E3

Four surfaces are APPEND-ONLY from E3 on. A change to any of them is a change to
somebody else's parser, so the rule is the same in all four: add at the end,
never reorder, retype or remove.

1. **`Diag.Code`** (`src/Diag.zig`, `enum(u16)`). A code's ORDINAL is the wire —
   the `'TPDG'` blob carries numbers and the corpus goldens spell codes by
   ordinal. Append at the end. `src/Diag.zig` also holds `code_order`, the
   ordinal pin table, which a test walks.
2. **The residue payloads** (plan 04, `docs/residue.md`). One SMF carrier
   (`7D 't' 'e' 'm'` sequencer-specific events) and two IT carriers (the `TMPU`
   trailing chunk, the message tail). The envelope is
   `tag | ver | kind | seq | total`; this build writes and reads `ver = 1`. Kind
   `01` is the essence, `02` a lane record, `03` the conductor record, and `04`
   is RESERVED for midivia's easing hint — tempura never writes one and never
   consumes one. `docs/residue.md` is the statement another implementation would
   read; when the code and plan 04 disagree, `docs/residue.md` says which stands
   and why (the IT lane hash's scope is the one live divergence).
3. **The three wasm blobs**: `'TPTL'` (the timeline zone,
   `tpr_timelinePtr`/`tpr_timeline`), `'TPPH'` (the playhead zone, `tpr_at` and
   `tpr_atTick`) and `'TPDG'` (the diagnostics zone, `tpr_diagPtr`/`tpr_diagLen`).
   Their layouts are pinned by `TprAbi` and tested natively, so a field added in
   the middle breaks a build rather than a host.
4. **The `tpr_*` export set** (26 exports, `src/wasm_entry.zig`). Static zones,
   no allocator crossing the boundary, a `u32` status per call. Bump
   `tpr_abiVersion` if a contract itself has to change.

## The layering rule (load-bearing, plan 01)

The format cores never see SJON. `src/smf/` defines `Sequence` and reads and writes
`.mid` bytes; `src/itf/` defines `Module` and reads and writes `.it` bytes with
pass-through regions; both are pure Zig with zero SJON dependency and must stay
that way. `src/doc/` defines `Doc`, the one timeline interchange value, and
converts `Doc ⇄ SJON tree`, embedding `Sequence` and `Module` as the document's
`midi/` and `it/` tiers. Everything above — `time/`, `edit/`, `export/`,
`residue/` — consumes `Doc` and never bytes or trees. The residue is the one place
bytes and `Doc` meet again, and it meets them through the format cores' metadata
slots, never by parsing a file itself.

```
.mid bytes ⇄ smf/ ⇄ Sequence ─┐
.it  bytes ⇄ itf/ ⇄ Module   ─┤── doc/ ⇄ Doc ⇄ (timeline …) SJON tree
                               │          │
   residue/ ◄──────────────────┘          ├→ time/   TimeMap, Playhead
                                          ├→ edit/   ops → SJON edit actions
                                          └→ export/ score text | .mid | .it
```

Inside that: `time/Pos`, `time/Grid` and `time/TimeMap` depend only on `Diag` and
are imported BY `doc/` (the printer needs the bar table to spell `Nbar`), while
`time/derive` and `time/Playhead` import `doc/`. The document layer owns the
conductor rules, the default-length rule and the map every other part reads
(`fromSjon.mapOf`) — one owner, never a second derivation.

## One file per responsibility, one aggregator per part

Every part directory carries an aggregator named after it —
`src/time/time.zig`, `src/smf/smf.zig`, `src/doc/doc.zig` — which re-exports that
part's files and forces their tests:

```zig
pub const Pos = @import("Pos.zig");
pub const TimeMap = @import("TimeMap.zig");

test {
    _ = Pos;
    _ = TimeMap;
}
```

`src/root.zig` imports ONE file per part (the aggregator) and lists it in its own
`test {}` block, so `tools/zt test` from the root discovers every inline test in
the repo. `tools/zt test -Dtest-root=time/time.zig` runs one subtree instead,
with the same imports the root gets (`sjon`, `build_options`, the schema
anonymous imports) — a subtree that is green there is green for the same reason it
is green at the root.

The path is **relative to `src/`** (`time/time.zig`, `smf/smf.zig`, `Diag.zig`),
and `build.zig` roots the test module at a generated `_test_root.zig` inside a
copy of `src/` rather than at the aggregator itself. Rooting it at
`src/time/time.zig` would make `src/time/` the module path and every
`@import("../Diag.zig")` "outside module path"; the module root has to stay one
level above the aggregators for a subtree to see what the root sees.

`src/cli/Cli.zig` is a SECOND test root, wired separately. Its files import the
`tempura` MODULE, which inside the core test binary would resolve to a second,
distinct instance; `tools/zt test` runs both roots.

## Build verbs

| Command | Purpose |
|---|---|
| `tools/zt test` | all inline tests (root.zig forces submodule discovery); `-Dtest-root=<path-relative-to-src>` for one subtree |
| `tools/zt verify` | the whole gate: test + the CLI goldens + native corpus + `node --test` + the wasm size budget + the pacer-schema drift check + the generated-docs drift check |
| `tools/zt corpus` | the native golden gate; `-- --update` regenerates, diff reviewed |
| `tools/zt fixtures` | re-derive `corpus/*/song.{mid,it}` from the cores' `Builder`s (the bytes are committed; `git diff` shows drift) |
| `tools/zt landing` | regenerate `npm/tempura/test/fixtures`; `verify` runs the same tool with `--check` |
| `tools/zt fuzz` | never-panic harnesses, separate from `verify` so the gate stays fast |
| `tools/zt conform` | the oracle matrix (libopenmpt, midicsv, the OpenMPT wiki cases). NOT part of `verify`: brew deps and pinned downloads make it a nightly job (plan 09, "CI shape"). Skips with a printed reason per absent tool and exits 0 |
| `tools/zt audit-diagnostics` | `Diag.Code` test coverage |
| `tools/zt wasm` | `tempura.wasm` (wasm32-freestanding, ReleaseSmall, `rdynamic`), and a copy into `npm/tempura/` |
| `tools/zt wasm-budget` | the wasm against its frozen size ceiling |
| `tools/zt cli` | the native `tempura` binary, built against the PUBLIC module |
| `tools/zt run -- <args>` | the CLI without the install path |
| `tools/zt cli-golden` | regenerate the CLI goldens |
| `tools/zt docs` | regenerate `docs/timeline-language.md` from `schema/tempura.sjon`'s own `:description`s; `verify` diffs it |

## The audit's raised/pending rule

`tools/zt audit-diagnostics` asks one question per `Diag.Code` variant: **a code
that is RAISED must be NAMED BY A TEST.** Raised and named is `ok`; raised with no
test is `MISSING` and fails the gate; not raised by any production code yet is
`pending`, reported and counted and not a failure.

`pending` exists because tempura's enum was SEEDED WHOLE at E0 — one shared
vocabulary, every code the plans name — while the producers land part by part. It
shrinks to zero on its own, so there is no exception list to maintain. Only
`test "…" { }` bodies count as coverage: a production switch arm raises a code
rather than testing it, and the corpus goldens carry numeric codes, so neither can
satisfy the check. `src/Diag.zig` and `src/fuzz.zig` are excluded from the
PRODUCTION side (they name every code without raising anything); their test bodies
still count.

## The golden corpus is the authority

`corpus/<case>/` holds one of `doc.sjon`, `song.mid` or `song.it`, plus
`times.sjon` (an ordered script of directives, shaped by
`schema/tempura-corpus.sjon`) and the GENERATED `expected.sjon`. The runner
renders one canonical text per case; `npm/tempura/test/corpus.test.js` re-derives
the same text from `tempura.wasm`. Native green plus wasm green means
byte-identical answers from two hosts.

Three rules, and they are not negotiable:

* **A golden is never hand-edited.** `tools/zt corpus -- --update` regenerates and
  the DIFF is reviewed. A golden edited by hand asserts the bug.
* **A `times.sjon` explains its own case.** Its comments are where a pinned
  oddity is justified — `(rung1 :ok false)` on a foreign fixture, or `(rung3 :ok
  false)` on `examples-native`, are FACTS the harness explains, not failures. The
  verdict is byte-equality with the golden.
* **Every shipped example is a corpus case** (plan 09; pacer 12 D1). The
  `examples-*` cases symlink into `examples/`, so an example that stops compiling
  fails the gate instead of rotting.

Binary fixtures are generated by `tools/gen_fixtures.zig` from the cores' own
builders and COMMITTED; `tools/zt fixtures` regenerates them and `git diff` is the
drift. Foreign fixtures are personal and never committed (plan 09) — a DAW export
or a wild module is logged by hash and outcome.

## The npm package is a gate, not a wrapper

`npm/tempura` is the ESM glue around `tempura.wasm`, and `node --test` there is
part of `tools/zt verify`. It carries four things tempura's own tests cannot:

1. **The corpus parity walk** — the same goldens, re-derived in the wasm.
2. **The landing proof** — a score exported from `examples/native.sjon`, loaded
   through the REAL `pacer.wasm`, every printed position read back as a tick, with
   a mutation test that fails on a one-tick error. tempura cannot catch its model
   of pacer's `mul + floor` drifting from pacer's own; this is where it is read by
   the driver.
3. **The blob decoders** against `'TPTL'`, `'TPPH'` and `'TPDG'`.
4. **A fresh-instance round trip**, compared against the native CLI's bytes.

`tempura.wasm` is copied in by the `wasm` verb, and the node leg depends on that
copy: a gate that read a stale artifact would pass on anything. Both legs of the
generated-docs and landing-fixture scripts go through ONE render for the same
reason — the gate compares what the verb produces. When `node` or
`npm/tempura/node_modules` is missing, the leg announces itself skipped with the
command to fix it; a gate that skips silently is not a gate.

## The schema directory

`schema/tempura.sjon` (the timeline vocabulary), `schema/midi.sjon` and
`schema/it.sjon` (the hosted `(smf …)` and `(module …)` core tiers) and
`schema/tempura-corpus.sjon` (the harness shape) are embedded through the
`tempura_schema` / `midi_schema` / `it_schema` / `corpus_schema` build imports and
PRELOADED once per host (pacer's `Schema.zig` arrangement), so validation works on
wasm32-freestanding with no filesystem and every diagnostic span is a document
coordinate by construction. `src/Schema.zig` owns both preloads: `load` composes
the four timeline manifests into one bundle, `loadCorpus` takes the harness one
ALONE. The harness vocabulary is never composed with the timeline one: a harness
file is an ordered script of verbs and not a document, so a shared schema would
put the harness's own `read` / `write` / `plan` / `snap` / `roundtrip` into a
document's scope and every document form into a `times.sjon`'s. `src/Schema.zig`'s
"never composed" test pins exactly that — those five verbs are unreachable in the
timeline bundle and all five resolve in a composed one. (Until 2026-09-21 the
proof was a COLLISION: both manifests declared a `timing` form. The harness verb
is gone, because nothing ever implemented it; the `it/` tier's still resolves.)
Two bundles, never a shared schema.

`sjon-project.sjon` composes the same four for `sjon-lsp` and the `sjon` CLI, and
a test in `src/Schema.zig` compares its vocabulary against the preloaded one head
for head. `schema/tempura-catalog.sjon` is the provenance catalog — one entry per
tempura form, covered both ways by test — and is self-describing rather than
listed anywhere, so it needs no build import and no project entry.

**`schema/pacer.sjon` is a VERBATIM copy** of `../pacer/schema/pacer.sjon` — pacer
0.2.0, commit `63cd0ed`, copied 2026-09-20. Nothing in it may be edited, not even
its header: `tools/pacer_schema_drift.sh` (folded into `tools/zt verify`) diffs it
whole against the sibling checkout when one exists, and passes with a note when it
does not. To update it, re-copy the file and review the diff.

## Licenses

tempura is CC0-1.0 (`LICENSE`). What may be ported from where, and under which
attribution, is `docs/plans/09-conformance.md`'s "License discipline" table,
restated in `THIRD_PARTY_NOTICES.md` — Schism is doctrine-only and its code is
never ported; the MMA specification is cited, never reproduced beyond the byte
tables needed to implement it.
