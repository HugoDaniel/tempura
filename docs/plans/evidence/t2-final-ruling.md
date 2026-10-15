# T2 final ruling — every finding verified and ruled, no tracked edits

Senior ruling pass (GLM), 2026-10-15. Scope per `.agent/control/task-t2-final-rule.md`:
verify and rule every numbered finding of
`.agent/control/runs/t2-final-independent-review.log` plus the integration
collision and the stale vendored wasm; NO tracked file was edited, no gate
re-run, no golden regenerated, no commit made in any repository (nothing
tracked changed; scratch lives under `.agent/control/t2-final-rule/` and logs
under `.agent/control/runs/t2-final-rule-*.log`). Trees: tempura `4bcc193`
(clean except preexisting untracked `zig-pkg/`), animader `284f66d` (clean),
pacer `5f28aaa`, pngine `741ce92b` — all as the brief stated.

Evidence base: the whole review log; the sibling consumer report
(`animader/animader/.agent/control/report-t2-consumer-evidence.md`); direct
source reads; `git show`/`git log -S` for every cited commit; and fresh
runnable probes — exact BigInt oracle (`t2-final-rule/oracle.mjs`) and the
production CLI on obs (`zig-out/bin/tempura at`, built 2026-10-15 20:15,
after the tip commit 19:46; the control plane's fresh verify build). The
reviewer had run nothing; every numeric claim below was re-derived here.

GitNexus coverage: UNAVAILABLE — no `.gitnexus/`, no runner, no `gitnexus`
binary on this host (checked directly; consistent with the task note and the
prior fix ruling). All evidence is source, git and execution; no graph query
was consulted or refreshed.

Machine note for every later digest on this host: the Linux-side `sha256sum`
is BROKEN — it prints the empty-input digest `e3b0c442…855` for real files
(reproduced on `zig-out/bin/animader.wasm`, 1 176 208 bytes whose true digest
`01d06d18…` both openssl on Linux and obs confirm). Use
`/home/agent/worktrees/animader-init/t2-shim/sha256sum` or openssl.

## Premises of the brief, corrected by this pass

1. The review log's line references for finding 3 are diff-relative, not
   file lines: the live sites are `schema/tempura.sjon:336` (the `:fps` key
   description) and `docs/timeline-language.md:30` (the generated table row);
   `docs/timeline-language.md:297` is a `phrase-ref` section and says nothing
   about `:fps`. Substance unchanged — both live surfaces carry the false
   "prints nothing" sentence.
2. The reviewer's finding-1 repair suggestion (`shift > 121` cutoff) is
   itself defective and is REJECTED (proof in the finding-1 section). The
   finding is confirmed; the suggested fix is not the fix.
3. Everything else in the brief checked out: tips, digests, commit lists,
   the red/green counts, the two failure families on the animader side, and
   the CLI binary's freshness.

---

## Finding 1 — `tiny` cutoff misplaces schema-legal literals. CONFIRMED, REPRODUCED. FIX NOW (tempura owner, next stage worker).

### The reproduced failure (production CLI, obs, `.agent/control/runs/t2-final-rule-cli.log`)

Fixture `.agent/control/t2-final-rule/tiny.sjon`: `(timeline :fps [1 100])`,
`(tempo-point :at 0q :us 1)`, `(meter-point :at 0bar :sig [4 4])`, two notes
`0.000000000000002f`-durations. One tick is `1/46126080 s ≈ 2.17e-14 s`; the
literal is `2e-15` frames `= 2e-13 s = 9.225216` ticks (exact BigInt oracle;
control plane's `Fraction` agrees — floors 9).

| question | CLI answer | truth | verdict |
|---|---|---|---|
| `at --pos 0.000000000000002f` | `(at :tick 0 …)` + "lands between ticks" note | tick 9, inexact | **WRONG by 9 ticks** |
| `at --seconds 2e-13` (same instant, the clock) | `(at :tick 9 …)` | tick 9 | right — the two routes DISAGREE on one instant |
| `at --pos 5e-15f` (shift 100 seam) | tick 23 | 23.063 → 23 | right (the exact path works at shift ≤ 100) |
| `at --pos 1e-30f` | tick 0 | 4.6e-15 ticks → 0 | right (genuinely tiny) |
| `at --pos 1q` on a note `:at 1q :dur 2e-15f` | NO `(sounding …)` line | span 9 ticks, sounding at onset (frames-25 control shows a nonzero-dur note IS listed at its onset tick) | **anchored duration collapsed to span 0** |

Exit codes 0 with `frame_inexact` warnings on the durations — the load
believes it placed them; nothing is noisy about the 9-tick error. That is
the worst shape: silent misplacement inside the schema's legal extremes.

### Root cause (verified in source)

`TimeMap.frameParts` (`src/time/TimeMap.zig:350`) marks `tiny = shift > 100`
and `exactLanding` (:384) then answers the anchor with `exact = false`. The
cutoff's real job is an i128 guard — `r_den = num << shift`
(:417-418) — but `tiny` is consumed as a SEMANTIC claim ("instant under
2^-76 s", doc comment :321-323), which is false: shift > 100 only bounds the
literal to `< 2^-48` frames; the instant is `n · den / num` seconds, and with
the schema-legal `den` up to 16 777 215 (`schema/tempura.sjon:131`) and `:us`
down to 1 (`:108`) that is up to ~2^-24 s ≈ 2.2e6 ticks. The doc comment's
stated proof is unsound; no unit test or corpus case exercises shift > 100
with a large `den/num` (oracle: the band where the current cutoff is wrong is
`shift > 100 AND p·den·TICK_US ≥ num·2^shift·us`; the reviewer's `[1 100]`
fixture sits inside it).

### The reviewer's `shift > 121` fix is REJECTED

`r_den = num << shift` must fit i128: with schema `num` up to 16 777 215
(< 2^24), `num << 121` reaches 2^145 — it wraps (or is an invalid shift
amount for i128, which takes u7) for every `num > 2^6` at shift 121. Oracle
table (`t2-final-rule-oracle.log`): worst-case `num<<shift` fits i128 only
through shift 103; shift 104 already overflows. The reviewer's bound is safe
only for `num = 1`, i.e. it trades a misclassification bug for a silent
wrap/panic on a wider schema-legal band. Also rejected on principle (per the
brief): any static `shift` threshold is a tolerance, and the correct
statement is exact.

### The sound fix — a clean reduction, no tolerance, no fallback

Replace the flag with TWO exact statements, both provable from bounds already
in the code's own envelope comment (:302-314):

Let `r_num = p · den · TICK_US_I` (< 2^53·2^24·2^46 = 2^123, always fits),
`r_den = num · 2^shift`, `B = us_a · num` where `us_a` is the ANCHOR
segment's whole `us` (≤ 2^36 · 2^24 = 2^60, fits). "Tiny" is exactly
"instant strictly inside the anchor's own tick": `r_num/r_den < us_a`, i.e.

1. **Arm A (shift too wide to hold):** if `shift ≥ 127`, or
   `shift + bits(num) > 127` (i128 cannot hold `num << shift`), then
   `r_den > 2^127 > r_num` (r_num < 2^123), so `r < 1 ≤ us_a`: tiny. This
   arm turns the old overflow guard into a PROOF instead of a threshold.
2. **Arm B (exact compare, no products):** otherwise
   `r_num < B·2^shift ⟺ (r_num >> shift) < B` (floor-shift identity for
   positive integers; `shift ≤ 126` makes the i128 shift legal). Tiny iff
   that holds. `p == 0` stays the earlier `anchor/exact` return (:383).

In the non-tiny case `r_den = num·2^shift ≤ r_num/us_a ≤ r_num < 2^123`,
so `exactFloor`'s existing arithmetic proceeds unchanged with `r_den` now
PROVEN to fit — no widening, no f64 fallback, no classification weakening.
Seat the test at the top of `exactFloor` (it already has `a_seg`; return
`.{ .tick = anchor, .exact = false }`), keeping `exactLanding`'s ceiling
pre-check first; a tiny instant can never be past the grid (it is within one
tick of a valid anchor), so the order is safe. Segment crossings: an instant
`< us_a` from the anchor stays before `t_i + (anchor+1−origin)·us_a` — before
the next segment's origin too — so the floor is the anchor regardless of
where the next tick's segment starts; the test needs no segment special case.
Subnormals (shift 1074) and zeros fall out of arm A / the `p == 0` return.
The `huge` arm (e > 74) is untouched.

Secondary hardening in the same function (same proof family, cheap): the
walk's `dt + r_num` (:433) can in principle wrap when `d ≥ 0` and
`d·r_den` is just under 2^127; make the comparison overflow-free —
`reached = if (ov != 0) d > 0 else if (dt >= 0) true else dt >= -r_num` —
sign-identical to the current intent. Not the reproduced bug; prescribe as
part of the same edit so the envelope comment stays honest.

### Boundary tests to add (red first — the probes above ARE the red evidence)

Unit pins in `src/time/TimeMap.zig` beside the existing frame pins
(~:2400-2500), on an integral map `[1 100]` / `:us 1`:

- `tickFromLiteral(.f 2e-15)` from 0 → `.inexact 9` (RED today: anchor 0).
- duration `0.000000000000002f` from anchor `1q` (tick 46 126 080) →
  `.inexact 9` (RED today: 0 — the collapse).
- `5e-15f` → `.inexact 23` (GREEN today — pins the seam so the fix cannot
  over-widen tiny).
- `1e-30f` and a denormal `5e-324f` → anchor, `.inexact` (GREEN today —
  genuine tiny stays tiny).
- extremes: `:fps [1 16777215]` / `:us 16777215` near the r_num ceiling; a
  `num = 16777215` (odd, ~2^24) literal with shift-class ≥ 104 → arm-A tiny
  (would overflow r_den); a nonzero anchor on the LAST tick of a segment
  with the instant < 1 tick (crossing-adjacent) → anchor.

Then a corpus case `frames-tiny` in the fix stage (native + wasm parity),
mirroring `frames-25`, pinning the two durations' ticks and the
`frame_inexact` diags — the CLI transcript above is the expected shape.

Files: `src/time/TimeMap.zig` only (frameParts/exactLanding/exactFloor, doc
comments :316-323 and :381-384 rewritten to the real statements). No schema,
no docs, no corpus change required by the arithmetic itself.

---

## Finding 2 — plan 11's correction falsely says T1 "remains an ask". CONFIRMED against git. FIX NOW (docs-only commit, tempura owner).

Verified: T1 ruled 2026-10-04 (`docs/plans/08-export.md:314`); built
2026-10-08 by tempura `f2e8c43`, `6fd8d44`, `fcf2cc1`, `4732aab`, `ee21c33`
(all `git show -s` dated 2026-10-08; `--map`, `'TPMP'`, `tpr_exportScoreMap`
all in the tree at tip); consumed the same day by animader `7e14dfa`,
`e3d16a1`, `ec66db9`, `2634aa7`, `88a370c` (all dated 2026-10-08;
`anm_piece_score_map`, npm `scoreMap`, `positions.test.js`), recorded in
animader's own stance `docs/07-road.md:91`. The false sentence is
`docs/plans/11-demos-and-milestones.md:528` ("T1, the source map, remains an
ask") with the LOCAL/not-published sentences at :529-530, which are true of
T2 only. (The tip commit `4bcc193`'s message repeats the error; commit
messages are history and stand.)

Fix: inside the existing dated 2026-10-15 parenthetical, amend the T1
sentence with its own date, preserving every frozen entry around it. Precise
content for the worker: *T1 is BUILT and consumed — ruled 2026-10-04
([08](08-export.md)), built 2026-10-08 (`f2e8c43`..`ee21c33`: `export-score
--map`, the `'TPMP'` sidecar, `tpr_exportScoreMap`), consumed by animader's
piece boundary the same day (`7e14dfa`..`88a370c`, `anm_piece_score_map`,
[07 sibling road]); the LOCAL/not-published sentences stand for T2 only.*
Files: `docs/plans/11-demos-and-milestones.md` alone.

## Finding 3 — "prints nothing" is false in two spec surfaces. CONFIRMED (sites corrected). FIX NOW (schema + regenerated doc).

The rate prints in the header (`toSjon`'s rate-alone test pins
`:fps 25`; `Doc.eql` compares `frame_rate`), so the sentence is wrong at
`schema/tempura.sjon:336` and in the GENERATED `docs/timeline-language.md:30`
(the review's `:297` is a diff-relative reference; no such sentence lives
there). Fix: edit the schema description only — replace "Declaring a rate
without writing an `f` position is harmless and prints nothing" with the
review's wording "changes no position's spelling; the header keeps `:fps`"
(plan 02's dated row already says it right) — then regenerate with
`obs sh -c 'cd …/tempura && tools/zt docs'` (the `docs` step,
`build.zig:595-599`, renders the doc from the schema). NEVER hand-edit
`docs/timeline-language.md`. Files: `schema/tempura.sjon` +
`docs/timeline-language.md` (regenerated), one commit.

## Finding 4 — stale/incorrect comments. CONFIRMED. FIX NOW (same trivial-comment commit as finding 5's sentence).

- `src/time/TimeMap.zig:962`: "tick 19 37 29 536" → "tick 193 729 536"
  (digit grouping; the value is `193 729 536`, as the corpus and
  `frameDuration`'s own test attest).
- `src/time/TimeMap.zig:3223-3225`: "`spellDuration` never writes `f` (the
  printer's frame branch is phase 3)" — false since `frameSpan` shipped;
  `spellDuration` calls it at :1009. Replacement stating the true property:
  the frame branch exists and writes `f` only when both ends read back
  EXACTLY (`frameSpan`'s own rule), so a spelling this property round-trips
  never resolves `.inexact`; the fixtures here carry no declared rate, so
  `f` cannot appear in this test at all.

## Finding 5 — `pub fn frameLine` has no production caller. RULED: KEEP `pub`, DOCUMENT. No removal.

`frameLine` (`TimeMap.zig:486`) is called only by tests in its own file; its
twin `isBarLine` (:695) IS production (`ops_native.zig:1695`, `spellDuration`
:1010, `spell` :1105) and needs `pub` cross-file. `frameLine` is the
frame seam's read-back POLICY stated as a host-queryable oracle ("is this
tick on a frame line of the declared rate") — the integer twin the printer's
private `writableFrame` implements decimally. Removing `pub` is an API
surface change the brief forbids without approval, and the function is the
natural host companion to `isBarLine` for any future query surface. Fix: one
doc-comment sentence at :469-485 stating the fact plainly — no in-crate
production caller today; retained deliberately as the public frame-line
oracle the tests pin (the `isBarLine` twin). Same commit as finding 4.

---

## Integration collision — `frame-rate` declared by both tempura and animader. RULED: tempura renames its kind; owning-repo correction, single stage worker.

### Inventory (recursive across the workspace's schemas; `grep --include='*.sjon'` over tempura, animader, pacer, pngine, SJON, canto, audzio, domocracy, expansible-player, laranjuice, mixing-document, mistura, wgslender, zlug)

| site | what | claimant / date |
|---|---|---|
| tempura `schema/tempura.sjon:139` | `(value-kind :name frame-rate …)` union | **tempura `c6f72b2`, 2026-10-15** (new in T2) |
| tempura `schema/tempura.sjon:128,134,137,142` | helpers `frame-rate-scalar`, `frame-rate-pair`, their refs, the union's `:alternatives` | same commit |
| tempura `schema/tempura.sjon:335` | `(key :name fps :type frame-rate …)` | same commit |
| tempura generated `docs/timeline-language.md:30,251,257,263,267` | rendered from the schema | regenerates |
| tempura `docs/plans/02-timeline-schema.md:72` | prose naming the manifest's `frame-rate` kind | frozen plan; needs a dated note after the rename |
| animader `schema/world.sjon:49` | `(value-kind :name frame-rate …)` scalar 1..1000 | **animader `ff6c57d`, 2026-10-07** (the established claimant) |
| animader `schema/world.sjon:227` | `(form :name frame-clock :positional frame-rate …)` | same commit |
| SJON `conformance/cases/digit-leading-member-hyphenated/document.sjon:18,26` | a self-contained conformance fixture that declares its own `frame-rate` | SJON's own test corpus; loads alone; NOT a composition claimant — unaffected, note only |
| everything else (pacer, pngine, canto, audzio, …; animader bridge/machine/piece/session.sjon; tempura it/midi/pacer/catalog/corpus.sjon; all `src/**`; all npm JS) | no occurrence | — |

No animader Zig/JS source references the kind name — it is manifest data
only; the four red `Piece.zig` preload tests (`src/Piece.zig:1479,1519,1947,
2345`) assert a clean aggregate and print the ambiguity from the loaded
manifests. Renaming tempura's kind therefore needs ZERO animader changes.

### Semantics (SJON `docs/plugin-model-v1.md`, "2026-10-06, second note")

"The seat of a collision is the kind's name, not the spelling of one
reference" — qualifying one side's references does not discharge the name,
and "a composition is clean only when the name has one claimant"; the
available fixes are the qualified spelling where a reference is editable, or
the movable claimant renaming to a distinct name; "declaring the colliding
name confers no priority". Family precedents: pngine renamed
`stage-section` → `draw-stage-section` when pacer claimed the name (canto's
collision lane went red, re-pin followed); audzio's `param` is qualified
`audio/param` for the aggregate case. This matches the brief's constraint:
owning-repo correction, NOT qualification in the caller, no namespace shim,
no validator weakening.

### Decision, by the semantic test (age and cost only corroborate)

- Semantic concept: the two kinds are NOT the same concept. animader's is
  the family's generic paint-clock rate ("frames per second, 1..1000; paint
  n at t = n/F") consumed by the committed `frame-clock` world form;
  tempura's is ONE HEADER SLOT's type — the timeline document's `:fps`
  value, integer or exact rational, for the `f` position unit. The bare name
  states animader's concept; tempura's own manifest already names slot
  types by their domain (`timeline-end`, `anchor-ref`), so the distinct name
  states tempura's concept BETTER than the colliding one does.
- Age: animader 2026-10-07 vs tempura 2026-10-15 — animader is the
  established claimant (tiebreak only).
- Cost: tempura's rename costs one manifest edit + regenerated docs + one
  dated plan note; animader's would churn a committed form, world documents,
  tests and docs across a repo this task must not touch.

**Ruling: tempura renames its union kind `frame-rate` → `timeline-frame-rate`**
(unclaimed anywhere in the family — verified by grep over every workspace
`*.sjon`; also checked `timeline-fps`). The helpers `frame-rate-scalar` and
`frame-rate-pair` STAY (each has exactly one claimant — tempura — and their
names state their own concepts; renaming them churns docs for zero
collision discharge; minimal-repair principle). Edits:
`schema/tempura.sjon:139` (`:name timeline-frame-rate`) and `:335`
(`:type timeline-frame-rate`); regenerate
`docs/timeline-language.md` (`tools/zt docs`); a dated note in plan 02
beside the :fps row recording the rename and why (the collision, animader's
prior claim, the plugin-model note) — plan 02's frozen prose stands. NO
animader tracked change; no qualified spellings introduced anywhere.

### Durable regression so an internal-only green cannot miss the repeat

The gap: tempura landed T2 with every tempura gate green while the
composition broke — the collision is only visible when BOTH manifests load
together. Ruling, minimal location (both halves):

1. **tempura (the declaring repo) gains a real composed-manifest check with
   absent-sibling skip**: a verify-leg step (Zig test or script, worker's
   choice matching repo idiom) that, when `../animader/animader/schema`
   exists, loads tempura's manifest bundle TOGETHER with the sibling
   manifests through the real SJON aggregate (the same
   `ambiguous_element_kind`/`unknown_element_kind` preload walk the runtime
   runs — `runAggregateValidators`' kind-ref validator) and asserts zero
   `.aggregate` diagnostics; when the sibling is absent it prints a loud
   SKIP line and passes WITH NO equality claim — the exact shape of
   tempura's own `tools/pacer_schema_drift.sh:29-32` ("copy trusted") and
   canto's collision lane. This is the "real composed manifests" test; a
   text-scan name overlap is the weaker fallback if the worker cannot reach
   the SJON host from that step, and must then say so in its output.
2. **animader's existing tests stay the consumer-side enforcement** — the
   four Piece.zig preload tests and the piece corpus already went red on
   exactly this and need no addition.

Skip semantics with evidence: mirror `pacer_schema_drift.sh`'s precedent
verbatim in spirit — sibling present → hard red on any cross-plugin kind-name
overlap among loaded manifests; absent → one printed line, exit 0, no
"verified" wording.

Sequencing (one worker, distinct stage, after the comment/docs commits):
rename → `tools/zt docs` → sibling-collision step → `tools/zt verify` →
rebuild animader wasm on obs (`zig build wasm`) → `sh player/sync.sh` (below)
→ animader `zig build verify` green (the four Piece tests and the link guard
both discharge) → commit tempura only. The animader-side green is
VERIFICATION, not an animader edit.

---

## Stale vendored player wasm — sync PERMITTED in shape, DEFERRED until after the rename. No tracked change either way.

`examples/hello/player/sync.sh` (read in full): it `rm -rf`'s and rewrites
ONLY `examples/hello/player/vendor/` — gitignored (`examples/hello/.gitignore:3`
`player/vendor/`, `git check-ignore` confirms) — copies pngine/pacer npm
files, `npm/animader/src` glue and `zig-out/bin/animader.wasm`, and writes
`vendor/provenance.txt` with the sha256. It NEVER touches a tracked file:
`vendor.pin` (tracked) is written by hand at re-pin time, not by the script,
and the pinned siblings are unchanged (pngine `741ce92b`, pacer `5f28aaa`
both still match), so NO pin change is warranted — the dependencies did not
move, only tempura's code inside animader's own build did.

Concrete command (the defaults `$HOME/Dev/{pngine,pacer}` do NOT exist on
this machine — verified — so the overrides are required; node exists on obs,
v22.23.2, and the artifact lives there):

```
obs sh -c 'cd /home/agent/worktrees/animader-init/animader/animader && \
  PNGINE_NPM=/home/agent/worktrees/animader-init/pngine/npm/pngine \
  PACER_NPM=/home/agent/worktrees/animader-init/pacer/npm/pacer \
  sh examples/hello/player/sync.sh'
```

Probe result (before advising): the script touches no tracked file; the only
writes are under the ignored `vendor/`. Digests: verify with
`t2-shim/sha256sum` or openssl — the Linux `sha256sum` is broken on this
host (see machine note).

ORDERING RULING: do not sync the CURRENT artifact. The fresh build
(`01d06d18…`, present and byte-identical on both sides) embeds the colliding
`frame-rate` declarations; syncing it would turn the link guard green while
shipping a player whose `(frame-clock …)` worlds are broken (`:ok false`,
`anm_piece_score` throwing — the consumer report's A/B). Sync once, after
the rename stage's rebuild, so one sync discharges both the guard and the
page. If the owner wants the guard green sooner regardless, the sync above
is provenance-clean and reversible (re-run after the rename) — an owner
decision, flagged.

---

## Handoff to the stage worker (tempura repo only, distinct commits)

1. **Commit A (finding 1):** `src/time/TimeMap.zig` — two-arm exact tiny
   test per above, doc comments rewritten, `dt + r_num` sign-safe compare,
   the new unit pins (list above; write them FIRST and confirm red on
   `2e-15`/duration cases, green on the seam/tiny controls). Verify:
   `obs sh -c 'cd …/tempura && tools/zt test -Dtest-root=time/TimeMap.zig'`
   then the full `tools/zt verify` (27-step gate; the CLI-golden step needs
   the t2-shim PATH the control plane prescribed — shell/hash environment
   only, as already established). Then the `frames-tiny` corpus case with
   `--update` under the corpus runner, native + wasm parity, per the
   frames-25 shape.
2. **Commit B (findings 2,3,4,5):** plan 11 T1 amendment; schema `:fps`
   description + `tools/zt docs` regenerated doc; the two TimeMap comment
   fixes + the `frameLine` doc sentence. Verify: `tools/zt docs` idempotent
   diff, `tools/zt test`, gate.
3. **Commit C (collision):** the rename + regenerated docs + plan 02 dated
   note + the sibling-collision verify leg with absent-skip. Verify:
   `tools/zt verify`; then the animader-side green sequence (rebuild wasm,
   sync vendor with the env overrides, `zig build verify` on obs) as
   verification only — no animader tracked edit, no deploy, no publish.
4. Every command foregrounded and waited; no detached processes; all
   commits before finishing.

## Limits of this pass

- No gates re-run (control plane's fresh results relied on as briefed:
  tempura 1015/1015, npm 136/136, animader red 4+1); probes here were
  bounded CLI/oracle runs only.
- The wasm/npm surface was not driven for finding 1 (the CLI is the same
  `tickFromLiteral` resolution path the wasm host calls; the unit pins and
  corpus parity in commit A cover the wasm leg).
- The review log's "wasm parity 47/48" commit-message oddity was not
  re-derived (no corpus regen allowed); the control plane's corpus green
  supersedes it.
- GitNexus unavailable (wrapper absent, verified); no graph evidence used or
  claimed.
- animader's tree was read, never written; the only files created live under
  tempura `.agent/` (scratch + logs), which is untracked control-plane
  territory.
