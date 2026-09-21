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
| Two assertions per function, positive and negative space, paired at write and read (rule 5) | **near zero**: 3,800-line `fromSjon` has none, `reconcile` none, `ops_native` none, `ops_bound` none; the ones that exist are in `TimeMap`, `Module`, `Sequence`, `TprAbi`, `wasm_entry` | **adopted at the seams, not per function** — `CLAUDE.md` forbids asserting on user input, so the discipline lands as one `invariants()` per core VALUE (`TimeMap`, `Derived`, `Doc`, `Sequence`, `Module`, `Diag.List`) called at the write side (the end of the constructor) and at the read side (the entry of each consumer), plus pre- and post-conditions in the leaf math (`Pos`, `Grid`, `vlq`, `TprAbi`). Never on a byte a reader has not yet diagnosed — in `ReleaseSmall` a violated assertion is undefined behaviour — and the never-panic fuzz gate (`tools/zt fuzz`) is what proves that line was not crossed |
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

What each `invariants()` asserts, as the wave established it against the code rather than
as this plan first guessed. Every clause is a property OUR code establishes, never one the
input promised: a reader that meets a bad byte diagnoses and drops it, and the value it
returns satisfies these anyway. Where a producer other than the reader (a `Builder`, the
bridge, the residue's rebuild) may legitimately hand in less, the reader's stronger promise
is a separate POSTCONDITION asserted at the end of the reader only.

`std.debug.assert` costs nothing in `ReleaseSmall`, but it does not vanish: a violated
assertion there is undefined behaviour, an optimiser hint, not a trap. That — more than
Debug's panic — is why no clause may be reachable from a host's input, and why `tools/zt
fuzz` drives arbitrary bytes and text through every reader and, since this wave, through
`derive`, the playhead and the score exporter too.

- **`TimeMap`** — at least one segment, the first at tick 0; segment ticks strictly
  ascending and `≤ Grid.MAX_TICK`; `start_sec` and the integral origins non-decreasing;
  `tps` positive (it may be `+inf` for a `:qpm` near f64's ceiling, so not "finite"); meters
  likewise, `n` in 1..64 and `d` a power of two ≤ 32; `bars[0] == 0`, strictly ascending,
  `len ≤ MAX_BARS`; `loop_secs ≥ 0` when the length is. Plan 12's "`us` non-decreasing"
  was wrong — a tempo map may slow down. Queries assert their ANSWER, not their argument:
  `tpr_atTick` hands a host's i64 straight in.
- **`Derived`** — the map's invariants; every lane table sorted the way `Playhead`
  searches it; native content inside `[0, MAX_TICK]`, bound content within `|tick| ≤
  MAX_TICK` (an inline SMF dump keeps a negative `:at`, with `at_not_monotone`).
- **`Doc`** — every span runs forward; every keyframe's `ncomp` in 1..4; every note's and
  section's `dur ≥ 0`; a phrase's lanes carry no binding; a native `:cc` never beside a
  binding and only `.cc` or `.cc14`; a bound SMF address names a channel. NOT asserted:
  `repeat ≥ 1` and distinct anchor ids — the loader keeps both with a diagnostic.
- **`Sequence`** — every pool run and foreign chunk lies inside the pool, for every
  producer. The reader's postconditions add: ticks non-negative and non-decreasing,
  channel 0..15, channel data bytes < 0x80, the source map parallel to the sequence.
  `status`/`fromStatus` is a comptime check. NOT asserted: `division` non-zero — the reader
  keeps a zero or absent division with a diagnostic.
- **`Module`** — every pattern's cell grid dense, `rows × 64`, for every producer. The
  reader's postconditions add: counts within its caps, 1..1024 rows, a note a pitch or one
  of the four sentinels, `fx ≤ 26`, a 4896-byte MIDI configuration, every mapped region
  inside the file. NOT asserted: that an order names a pattern (the walk guards), rows
  1..200 (the reader accepts 1024 with a warning), the raw ins/vol/param domains.
- **`Diag.List`** — every span `start ≤ end`, asserted at the write side in `add` and at
  the read side in `invariantsOf`; every code's ordinal one `code_order` pins. The span
  clause went in only after the IT reader stopped producing inverted truncation spans.
- **`Plan`** (the edit engine's) — a refusal has no actions and an error diagnostic, an
  accepted plan has none; the summary counts every action once; every action is one JSON
  object; asserted where a plan is finished and where one is applied.

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

- **A `tools/zt lint` verb** that fails on a function over 70 lines or a line over 100
  columns outside the two exemptions (a test's name, a raw `\\` line of test data), so the
  rules are gates rather than reviews. Written in Zig, per the set's "scripts in Zig" rule.
  The tree now passes both, so the verb can land green.
- **Two test fixtures over 70 lines**, `reconcile.zig`'s `kitCase` (103) and `itCase` (89),
  exempt as fixture builders; one seam each if the lint verb is made to count them.
- **`tpr_build` builds a document that loaded with errors**, where the CLI's `build`
  refuses. The renderer no longer traps on what such a document holds (the `[4 17]` fix), so
  this is parity, not safety: a host gets bytes the CLI would have refused. A ruling for
  plan 10 — refuse with a diagnostic, or keep building and say so.
- **`doc/bridge_smf.zig`'s `sniffSequencerSpecific` restates `smf/read`'s `7D 'tem'` /
  `7D 'pau'` sniffing**; the two can drift. One owner, in `smf/`.
- **`smf/smf.zig` does not re-export `Note`**, so the bridge spells it
  `@FieldType(smf.Payload, "note")`.
- **Property tests** driven by `std.testing.random_seed`: `simplify.budget` over a random
  monotone curve (the kept keys are a subsequence and every dropped key lies within `eps` of
  its chord) and `Pos.spell ∘ parse`.

## Progress log

- 2026-09-21 — Audit done against `ed0e059`; the table above is its verdict. The wave
  started with task 1.
- 2026-09-21 — **The wave landed on `main`** (`36bbfb7..` — 72 commits): task 1 by hand,
  tasks 2–7 by one agent per part in its own worktree, each branch rebased and fast-forwarded
  behind `tools/zt verify`, then the cross-part read sides, the border splits, the column
  wrap and these docs. Measured against the audit:

  | Rule | Before | After |
  |---|---|---|
  | functions over 70 lines | 55 (20 over 100) | 2, both test fixtures |
  | lines over 100 columns | 857 | 63, all exempt (14 test names, 49 raw test-data lines) |
  | bare `a` allocators in production code | 67 | 0 |
  | unbounded recursion in a value path | 1 (`simplify.divide`) | 0 |
  | `catch unreachable` without its proof | 43 | 0 (24 remain, each proven) |
  | `invariants()` on core values | 0 | 7 (`TimeMap`, `Derived`, `Doc`, `Sequence`, `Module`, `Diag.List`, `Plan`) |
  | allocating entry points with an OOM sweep | 0 | every one in the table's list |

  The wasm went from 1,391,784 bytes (93% of its frozen ceiling) to 1,381,255 (92%); the
  corpus, the CLI goldens, the fixtures and the four wire surfaces are byte-identical.

  **What the discipline found — fifteen defects in shipped code, each fixed with a test:**

  - *Traps on a document.* `(tempo-point :at 0q :qpm 1e-30)` plus a second point overflowed
    the integer tempo accumulator and trapped `fromSource` itself (`4f6fbd0`). A meter the
    map refuses, `[4 17]`, still reached `Grid.beatTicks` in the IT renderer through
    `tpr_build`: a panic natively, undefined behaviour in the wasm (`80d21e7`). A `:qpm
    1e300` the reader keeps overflowed `@intFromFloat` to i128 in the score's bpm spelling
    (`e6d3986`) — found by proving a `catch unreachable` beside it.
  - *Wrong answers.* `:dur 0s` at an interior tick resolved to −1 (`3156300`). A tempo or
    meter point past the grid ceiling was kept and let a later query leave i64 (`8269f59`).
    The IT reader produced inverted spans for a truncated file whose header declared an
    offset past its end (`bced3dc`).
  - *Memory, found by the `FailingAllocator` sweeps.* `fromSource` leaked every inline tier
    on a failure after `readTiers`; `readMeterPoints` leaked its working map; `dumpSmf` and
    `dumpIt` freed the tier text twice; `encodeLanes` leaked a lane body (`8e34cd0`, four
    fixes). `residue/it.tail` freed its line twice (`d5d7535`). The edit engine's
    `Plan.Builder` leaked a pathed action's scratch text and freed a root action's twice
    (`9ffefc8`); `apply` dropped a parsed action (`368cc69`); an inserted phrase's inner
    lane text was lost (`625389d`); `locate.whereOfRow` leaked its step list on a null
    return.

  One NEW assertion was narrowed before it shipped: a window's `span ≥ 0` holds in beats
  mode and not in seconds mode, where a non-finite wall clock rounds to tick 0 (`bc77ad3`).
  That is the rule working — an assertion is written only where the code establishes it.

## The second wave (2026-09-21, `9eda67a` onward)

The ask came again the same day, and the tree was re-read against the set with fresh eyes. The
first wave's table did not survive contact with a mechanical reading: `itf/write.writePattern`
had grown back to 100 lines, `build.zig`'s `build` was 482 (never measured — it is not under
`src/`), `doc/Resolver.zig` still read the filesystem from inside the core (the audit's "IO at the
borders: met" was wrong), and three read-only reviews of the parts found undefined behaviour
reachable from a host's input in fourteen places the fuzz gate never drives. A rule a reviewer
has to remember drifts, so this wave makes the rules a gate first and fixes what the gate and the
reviews found second.

### The gate: `tools/zt lint`

`tools/lint.zig` parses every `.zig` file under `src/` and `tools/`, and `build.zig`, with
`std.zig.Ast`, and fails on: a function over 70 lines (a `test` body is exempt, a fixture
builder is not); a line over 100 columns (codepoints — a test's name and a raw `\\` line are
exempt); an allocator not named `gpa`/`arena`; a `catch unreachable` with no proof comment (test
code uses `try`); a `while (true)` whose comment names no bound; recursion whose doc comment does
not name SJON's `MAX_PARSE_DEPTH`; a filesystem, clock, process, thread, print or process-wide
allocator in the core; a container-level `var` in the core; a managed `std` container; a `pub
fn`/`export fn` without `///`. "Test code" includes a helper only tests reach, found by name
reference to a fixed point, so the tree needs no test banner convention and no allowlist.

First reading, at `9c787a9` (after `build.zig` was decomposed): **156 findings** — 129 `pub_doc`,
12 `fn_length`, 7 `allocator_name`, 2 `unreachable_proof`, 2 `core_io` (`Resolver.Fs`), 2
`managed_container` (`itf/walk`'s `AutoHashMap`), 1 `loop_bound`, 1 `recursion`. The verb joins
`verify` when the tree reads clean.

### The reviews' findings, by part

Category 1 is undefined behaviour in `ReleaseSmall` (the wasm): an overflow, a failing
`@intCast`, an `unreachable` or an assertion a host's bytes, document or JSON can reach. Each is
fixed with a test that drives the input, and joins the fuzz gate's seeds.

**A — the format cores, the exporter, the residue** (`smf/`, `itf/`, `export/`, `residue/`)

- Undefined behaviour: `reconcile.addressOf` (`:channel -2^63`, `:track 70000` from a message
  tail); `Module.Builder.finish`'s `ord_num` narrowing (65,536 orders); `smf/write`'s `at - last`
  (a saturated negative `:at`); `render_it`'s polyphony count narrowed to u16 (and O(n²));
  `render_smf`'s track number narrowed to u16; `export/pos.nearest(+inf)` driving a negative span
  into `spellSeconds`' assertion; `'@' + fx` on a builder-seated `fx ≥ 192`.
- Wrong answers: a `:qpm 2` set-tempo truncated to 24 bits silently (4.5 qpm, no diagnostic);
  `render_it.slotAt` counting inexact cuts that are later dropped; both renderers' conductors
  reading the raw `doc.tempo` rather than the map (a refused `:qpm -5` is still written);
  `reconcile` spelling `:fx "\""` unescaped; `render_smf.conductorTrack`'s weaker meter test;
  `smf/read`'s `@truncate` hiding format 256; `residue/it`'s `:query`/`:expr` not `%XX`-escaped.
- One owner: the `7D 't' 'e' 'm'` residue head in five places and `sniffSequencerSpecific` a
  copy of `smf/read`'s (`smf/Sequence.zig` owns both; `smf.zig` re-exports `Note` too);
  `copyEvent` twice; the address-key spelling three times (drifted); `easeAt` copied to dodge an
  import cycle (a std-only `src/Easing.zig`); `sceneName`; the 7-bit quantizer.
- Pure leaves: `records.reassemble` (`partsSize` + `join`), `Emit.scaled` (`rescale`),
  `writePattern` (`padShort`), `Tailer.escaped` (`needsEscape`), `slotAt` (`slotOf`).
- Memory: `pattern.unpack`/`pack` into the module's arena rather than a gpa copy; the score
  exporter's scratch in a scratch arena; `renderSmf`/`renderIt` check `base.invariants()`.

**B — the document, time and edit layers** (`doc/`, `time/`, `edit/`)

- Undefined behaviour: `Playhead.snap` near `maxInt(i64)` (`tpr_snap`); a non-finite float
  printed as `inf` into an edit action that `apply` then meets as `unreachable` (`revalue` with
  `1e39`); `Op`'s `clamp(x - 1)` on `minInt(i64)`; `parseNoteName`'s octave arithmetic
  (`"C300000000"`); `bridge_smf`'s pairing subtractions on a saturated `:at`; `ops_bound`'s
  retime sum and `:bend`'s `val - 8192`; `skeleton.smfTier`'s track number narrowed to u16 (a
  65,536-chunk `.mid`).
- Wrong answers and one owner: the conductor tables and the default `:length` derived THREE times
  (`finalMap`, `mapOf`, `derive.conduct`), and they disagree on a document whose conductor anchor
  is absent but which carries its own tempo — the edit engine and the playhead then read two
  different maps; the clip window formula four times (`:repeat 0` diverges); `insertMeter` and
  `insertTempo` accepting what the map then refuses; three narrowing helpers with different
  out-of-range rules (one `doc/narrow.zig`).
- Pure leaves: `ops_bound.cellMove` (`cellLanding`), the wall-clock `insertTempo`
  (`wallClockMoves`), `bridge_it.Printer.volume` (`volSpelling`).
- Memory: `pipeline`'s `Dumped`, `Report` and `Built` keep a `gpa` field to free one slice each
  — the struct-never-retains-the-GPA rule; the ownership `///` on the public producers.

**C — the borders** (`cli/`, `wasm_entry.zig`, `TprAbi.zig`, `corpus_runner.zig`, `tools/`)

- Undefined behaviour: `TprAbi.writeName`'s assertion and `@intCast` on a name over 65,535 bytes
  (a 70,000-byte cue name through `tpr_timeline`); `Refusal.of` mapping OOM to `unreachable` in a
  public function.
- IO at the borders: `doc/Resolver.zig`'s `Fs` store moves out of the core to a border file; the
  inline verb's computation (tier text, root index, the insert plan) moves into the core, so a
  wasm host can call what the CLI calls.
- Wrong answers: a zero-length `tpr_*` answer leaving the previous call's `'TPDG'` report in
  place; `samePath` swallowing OOM into "not the anchor" (and `-o` then overwrites it);
  `findFixture` treating every read error as "not here"; `planInsert` leaking its plan on the
  refusal path; `timeline --json` writing a bare `inf`.
- One owner: `Diag.Severity.word`, the magic sniff, `rung1Of` in `renderBuild`, `verbName`.

**Across the borders, last** (after A, B and C land): the ease hints `tpr_exportScore` drops
(the CLI's and the wasm's scores differ for a stale curve lane); one `edit.planJson` for the
three hosts; the fuzz gate gains `snap`, `encodeTimeline`, `pipeline.build` and `edit.apply` of
accepted action lists, with a seed per defect above; `lint` joins `verify`.

### Filed, not fixed — rulings for Hugo

- **Snapping has two implementations that disagree** (`Playhead.snap` behind `tpr_snap`, and
  `edit/Snap` behind quantize and nudge): the first swings odd bars on a bar grid and rounds half
  to even, the second never swings, truncates, and clamps to ±step rather than ±(step−1). One
  owner in `time/` is the fix, but which behaviour is right is a ruling, and the snap goldens
  move with it.
- **A host may build, plan and apply over a document that loaded with errors** where the CLI
  refuses (`tpr_build`, and now `tpr_plan`/`tpr_apply` through `blocksEdit`): refuse with a
  diagnostic, or keep going and say so. The first wave's follow-up, widened.
- **`tools/*.sh` stay shell.** The set says scripts are Zig; `tools/zt` is the lock around every
  `zig` invocation and cannot be one, and the other five are glue shared with pacer's family, so
  porting them is a family decision. `tools/lint.zig` is Zig, as new tooling is.
