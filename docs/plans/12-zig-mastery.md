# 12 — Zig Mastery: the audit and its rulings

The house discipline tempura is held to, beyond `CLAUDE.md`'s conventions, is the Zig mastery
set at `~/llm/mastery/zig/` (`00-INDEX.md` and its ten documents, verified against zig 0.16.0
and TigerBeetle on 2026-05-06). This plan is the audit of the tree against that set, dated
2026-09-21, the rulings on what is adopted and what is declined with the reason, and the
progress log of the wave that applied it. `tools/zt verify` was green before the wave and is
the verdict after every task: the corpus goldens make every change byte-identical or visible.

## What the set asks, and where tempura stood (2026-09-21, `ed0e059`)

| Rule (source) | Standing before the wave | Ruling |
|---|---|---|
| `//!` header on every file; `///` on public APIs with ownership and lifetime (DOCUMENTATION) | every one of the 80 files has a `//!` header; the public entry points carry `///` | met — kept |
| `gpa` / `arena` over `allocator`; the name says whether `deinit` is owed (ZIG_MASTERY, Naming) | 250 `gpa`, 1 `arena`, **67 `a`** — most of the `a`s ARE arenas (`.a = arena.allocator()` in `fromSjon`, `reconcile`, `Op`, `render_*`, `itf/walk`, `itf/write`, `TimeMap.derive`, `derive`, `locate`, `skeleton`, `score`, `Cli`) and a few are caller-owned GPAs (`Diags.LineIndex.build`, `reconcile.addressKeysInto`) | **adopted** — `a` becomes `arena` where it is one and `gpa` where the caller frees; a name that says nothing is the one thing the rule forbids |
| Every public entry point takes `gpa` and returns an owned struct with arena-backed `deinit`; the struct never retains the caller's GPA (`CLAUDE.md`, pacer plan 01) | met: the `gpa: Allocator` fields that exist are on transient WORKERS (`Reader`, `Writer`, `Run`, `Tailer`) that die inside the call, never on a returned value | met — kept; the OOM sweeps below are what PROVE the `errdefer` discipline behind it |
| No recursion (ZIG_MASTERY, NASA-10 rule 1) | one unbounded recursion in a value path: `export/simplify.divide`, Ramer–Douglas–Peucker over a curve lane's keys, depth up to the key count on a wasm stack; tree walks over an SJON `Ast.Tree` (`edit/value.node`, the corpus runner's `jsonOfNode`) recurse to the tree's depth, which SJON's parser bounds at `MAX_PARSE_DEPTH = 1024` | **adopted** for `divide` (an explicit stack, bounded by the key count); the SJON-tree walks are ACCEPTED as bounded by the substrate and say so in their doc comments |
| Every loop has an upper bound (rule 2) | six `while (true)` in the core: `smf/vlq.read` (bounded by `MAX_LEN` inside the body), `itf/walk.run` (the `seen` set), `TimeMap.barTable` (`MAX_BARS` via the diagnostic), `edit/Plan` (the action list's own length), `doc/Value.passthroughEql` (the token count), `export/pos` (`MAX_FRAC_DIGITS`) | **adopted** — a constant bound becomes `for (0..bound)` with the doctrine's `else unreachable`; an input-length bound stays a `while` and names its bound in a comment |
| Two assertions per function, positive and negative space, paired at write and read (rule 5) | **near zero**: 3,800-line `fromSjon` has none, `reconcile` none, `ops_native` none, `ops_bound` none; the ones that exist are in `TimeMap`, `Module`, `Sequence`, `TprAbi`, `wasm_entry` | **adopted at the seams, not per function** — `CLAUDE.md` forbids asserting on user input, so the discipline lands as one `invariants()` per core VALUE (`TimeMap`, `Derived`, `Doc`, `Sequence`, `Module`, `Diag.List`) called at the write side (the end of the constructor) and at the read side (the entry of each consumer), plus pre- and post-conditions in the leaf math (`Pos`, `Grid`, `vlq`, `TprAbi`). Never on a byte a reader has not yet diagnosed; the never-panic fuzz gate (`tools/zt fuzz`) is what proves that line was not crossed |
| Functions ≤ 70 lines, push `if`s up and `for`s down, leaf functions pure (rule 6) | **55 functions over 70 lines, 20 of them over 100**: `Args.parse` 237, `timeline.writeJson` 217, `reconcile.emit` 193, `Op.op` 190, `fromSjon.walk` 188, `smf/read.track` 166, `ops_bound.materialize` 159, `pipeline.buildIt` 141, `fromSjon.readLane` 136, `readBinding` 125, `itf/write.run` 121, `bridge_smf.event` 120, `ops_bound.smfLane` 111, `corpus_runner.renderSmfCase` 110, `pipeline.buildSmf` 109, `corpus_runner.parseHarness` 109, `residue/smf.attach` 105, `reconcile.kitCase` 103, `itf/pattern.unpack` 101, `ops_native.moveInLane` 101 | **adopted**: every production function over 100 lines is decomposed in this wave — the parent keeps the control flow and the helpers become pure leaves that compute and return; the 70–100 band is decomposed where the seam is obvious and otherwise logged below as the follow-up. Test bodies and fixture builders are not functions in this sense |
| 100 columns, `zig fmt` clean (Formatting) | `zig fmt` clean; **857 lines over 100 columns**, 423 of them production code, 2 comments | **adopted** — wrapped, mechanically where a trailing comma lets `zig fmt` do it and by `++` where a string literal is the long thing. The two long comments are re-flowed |
| No `catch unreachable` without proof (rule 8) | 43 sites: 38 are `std.fmt.bufPrint` of a bounded number into a buffer sized for its widest spelling, 1 is `utf8Encode` of a table codepoint, 4 are test fixtures allocating from an arena | **adopted** — every production site keeps the `catch unreachable` and STATES its proof in the line above (the buffer's width against the widest value); the test fixtures use `try` |
| `FailingAllocator` sweeps on every allocating entry point (TESTING) | none | **adopted** — one sweep per public entry point that allocates: `fromSource`, `toSjon.print`, `TimeMap.derive`, `derive.derive`, `smf.read`/`write`, `itf.read`/`write`, `exportScore`, `renderSmf`, `renderIt`, `reconcile`, `residue.smf.attach`/`detach`, `residue.it.chunk`/`parseChunk`/`tail`, `Op.fromJson`, `Plan.fromActionsJson`, `apply`. Each proves the call returns `error.OutOfMemory` cleanly at every allocation index with no leak (`testing.allocator`) and succeeds once the index is past the last allocation |
| Explicit error sets per module (`CLAUDE.md`) | met, with 12 `!T` public signatures: 9 are `writer: anytype` spellers whose error IS the writer's, 3 are CLI test helpers (`invoke`, `invokeEnv`, `repoPath`) | accepted — an `anytype` writer's error set cannot be spelled; the helpers are test-only |
| Explicitly-sized integers, `usize` only for slice indexing (rule 3) | 63 signatures carry a `usize`; every one read is a slice index, a byte offset or a count of slice elements | accepted — the rule's own exception; no churn |
| Static allocation, no `alloc` after `init` (rule 4) | tempura is a pure function per call: each call allocates into an arena the result owns; the wasm entry's zones are static and no allocator crosses the boundary | accepted as the pure-function form of the rule — a per-call arena is the border, and nothing is retained between calls |
| `snake_case` functions (Naming) | camelCase, the Zig standard library's, SJON's and pacer's spelling | declined — `CLAUDE.md` binds the code style to SJON's; a family-wide rename is not tempura's call |
| Every `if` has an `else`; `else if` chains become nested trees (Control flow) | not followed | declined — house style across the family; not a correctness rule |
| `MultiArrayList` nodes, labeled-switch lexers, `StaticStringMap` keywords (LEXER_PARSER) | tempura owns no parser: SJON's tree is the substrate; the two token scanners it does own (`Value.Tokens`, `Plan.ActionReader`) are under sixty lines each | not applicable |
| io_uring, state machines with `defer self.invariants()`, quorum bitsets (IO_URING, STATE_MACHINES) | no I/O in the core, no long-lived state; `itf/walk` is a state machine over a finite module and `tpr_*` a static-zone handshake | the `invariants()` idiom is taken (above); the rest does not apply to a pure function |
| Build: enum-literal `.name`, `.fingerprint`, `.minimum_zig_version`, `root_module`, version check, wasm flags (BUILD, WASM) | all present (`build.zig.zon`, `build.zig`'s `comptime` check, `entry = .disabled`, `rdynamic`, `link_libc = false`) | met — kept |
| IO at the borders (the user's ask) | the core (`smf/`, `itf/`, `doc/`, `time/`, `edit/`, `export/`, `residue/`) reaches no filesystem, clock, process or thread outside `test` blocks; `std.Io.Writer` there is the formatting sink over a caller's buffer, not I/O. The borders are `cli/`, `corpus_runner.zig`, `tools/`, `wasm_entry.zig` (static zones) | met — kept, and now STATED in `CLAUDE.md` so a reader knows where the line is |

## The invariants, value by value

What each `invariants()` asserts. Every clause is a property OUR code establishes, never one
the input promised: a reader that meets a bad byte diagnoses and drops it, and the value it
returns satisfies these anyway. `std.debug.assert` compiles out of `ReleaseSmall`, so the
wasm pays nothing; Debug tests and the fuzz gate pay once per construction and once per
consumer entry, never per query.

- **`TimeMap`** — `segments.len ≥ 1`, `segments[0].tick == 0`, ticks strictly ascending and
  ≤ `Grid.MAX_TICK`, every `tps` finite and positive, `us` non-decreasing; `meters` likewise
  with `n ≥ 1`, `d` a power of two; `bars[0] == 0`, strictly ascending, `len ≤ MAX_BARS`;
  `loop_secs ≥ 0`. Queries assert their own `tick` is in `[0, MAX_TICK]` and their result is
  finite.
- **`Derived`** — the map's invariants; every lane table sorted by `at`, every onset and
  keyframe tick inside `[0, MAX_TICK]`.
- **`Doc`** — every span has `start ≤ end`; every keyframe's `ncomp` is `1..4`; every note's
  `dur ≥ 0`; every clip's `repeat ≥ 1`; `anchors` ids distinct; a phrase's lanes carry no
  binding.
- **`Sequence`** — `division` non-zero; every track's events in non-decreasing absolute tick;
  every channel event's data bytes < `0x80`; a `Kind` with a `status()` has one that
  `fromStatus` maps back.
- **`Module`** — `orders.len ≤ 256`, every pattern index an order names is a pattern or the
  two markers; every pattern `1..200` rows and `≤ 64` channels; every cell's note, instrument,
  volume and effect inside IT's byte domains.
- **`Diag.List`** — every span `start ≤ end`; every code's ordinal inside `code_order`.

## The tasks

The wave ran as one context window per part, in parallel worktrees, each part's branch merged
onto `main` with `tools/zt verify` after every merge; the cross-cutting passes (the column
wrap, the docs) ran last on `main`. Each task is one commit shape:
`refactor(<part>): …` for a decomposition or a rename, `test(<part>): …` for a sweep,
`fix(<part>): …` where a sweep or an invariant found something real.

1. **`export/simplify`** — `divide` on an explicit stack: a `[lo, hi]` frame array sized by
   the key count, LEFT pushed last so it pops first and the split order is unchanged; the
   goldens with curve lanes prove the bytes did not move.
2. **`time/`** — `TimeMap.invariants()` and `Derived.invariants()`, called at the end of
   `derive` and the entry of `Playhead.at`/`atTick`, `exportScore`, `toSjon.print`;
   `barTable`'s loop bounded by `MAX_BARS`; `a` → `arena`; `derive.bound` and `conduct` and
   `TimeMap.meterTable` decomposed; sweeps on both `derive`s.
3. **`smf/` and `itf/`** — `Sequence.invariants()`, `Module.invariants()` at the end of both
   `read`s and the entry of both `write`s; `vlq.read` as a `for (0..MAX_LEN)`; `a` → `arena`;
   `read.track`, `write.event`, `itf/write.run`, `pattern.unpack`/`pack`, `walk.run`
   decomposed; sweeps on all four entry points; `Module.zig`'s `utf8Encode` proof.
4. **`doc/`** — `Doc.invariants()` at the end of `fromSource` and the entry of `print`,
   `pipeline.build`; `a` → `arena`; `fromSjon.walk`, `readLane`, `readBinding`,
   `smfConductor`, `pipeline.buildIt`/`buildSmf`/`dumpIt`/`dumpSmf`, `bridge_smf.event`
   (both), `pairNotes`, `Value.eql` decomposed; the `bufPrint` proofs; sweeps on
   `fromSource`, `print`, `dump`, `build`.
5. **`edit/`** — `Op.op` (one reader per operation name), `newOf`, `ops_bound.materialize`,
   `smfLane`, `moveCells`, `moveEvents`, `relocateCells`, `ops_native.moveInLane`, `rename`,
   `stretch`, `duplicate`, `Select.resolve` decomposed; `a` → `arena`; `Doc.invariants()` at
   the entry of `planWith`; `value.node`'s bound stated; sweeps on `fromJson`,
   `fromActionsJson`, `apply`.
6. **`export/` and `residue/`** — `reconcile.emit`, `bindLane`, `restore`, `residue/smf.attach`,
   `detach`, `residue/it.lane`, `parseChunk`, `lanes.curve` decomposed; `pos`'s loop as a
   `for`; `a` → `arena`; the `bufPrint` proofs; sweeps on `exportScore`, `renderSmf`,
   `renderIt`, `reconcile`, `attach`, `detach`, `chunk`, `parseChunk`, `tail`.
7. **`cli/` and the roots** — `Args.parse` table-driven (one row per flag: name, the verbs
   that take it, whether it takes a value, the setter), `timeline.writeJson` one helper per
   section, `TprAbi.encodeTimeline` one helper per section, the corpus runner's
   `renderSmfCase`, `renderItCase`, `parseHarness` decomposed; `a` → `arena`/`gpa`.
8. **The column wrap** — every line over 100 columns, tree-wide, then `zig fmt --check`.
9. **The docs** — this plan's log, plan 11's decision log, `README.md`'s index, `CLAUDE.md`'s
   new "Zig mastery" section (the seams, the invariants, the IO border, the 70-line and
   100-column rules as gates a reviewer applies).

## Follow-ups (not in this wave)

- The 70–100-line band that was not decomposed here (`smf/read.run` 81, `itf/walk.readRow`
  78, `residue/it.lane` 87, `fuzz.checkRecords` 73, and the corpus runner's `main` 89,
  `renderDocDirective` 87, `itDifference` 84): each is one seam away.
- A `tools/zt lint` verb that fails on a function over 70 lines or a line over 100 columns,
  so the two rules are gates rather than reviews. Written in Zig, per the set's "scripts in
  Zig" rule, once the tree is clean enough that it would pass.
- `std.testing.random_seed`-driven property tests for `simplify.budget` (a random monotone
  curve: the budgeted keys are a subsequence and every dropped key is within `eps` of the
  chord) and for `Pos.spell ∘ parse`.

## Progress log

- 2026-09-21 — Audit done against `ed0e059`; the table above is its verdict. The wave
  started with task 1.
