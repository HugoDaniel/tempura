# T2 confirm-review verdict — the exact tail, with dated annotations

Source: `.agent/control/runs/t2-confirm-review.log` (2026-10-15), the independent
confirm review of the final-corrections wave — a git-ignored control-plane
original, copied here because [03](../03-time-model.md)'s final entry cites its
verdict. The block between the two markers is byte-exact, from the verdict heading
to the end of the log; the reviewer session's tool chatter above that heading is
not copied.

-----8<----- verbatim from here
# T2 final corrections — confirm review verdict (tip `3345301`)

**Verdict: MERGE-WORTHY.** All five numbered findings and the animader `frame-rate` collision are closed as ruled; the fixes are the prescribed ones, re-derived independently from source; one new LOW latent defect found in the test helper (below). No CRITICAL/HIGH/MEDIUM findings.

## Re-derivation of the numerical fix (finding 1)

- **`frameTiny` proof** (`src/time/TimeMap.zig:430-435`): Arm A — `shift ≥ 127 or shift + num_bits > 127` with `num_bits = 32 - clz(num)`: then `r_den = num·2^shift ≥ 2^(shift+num_bits−1) ≥ 2^127`, unrepresentable in i128 and `> r_num < 2^123` (p < 2^53, den < 2^24, TICK_US = 46126080e6 < 2^46), so `r < 1 ≤ us_a` — tiny, correctly. Boundary strictness verified: `shift + num_bits = 127` falls to arm B with `num < 2^num_bits` so `r_den < 2^127` fits. Arm B — the floor-shift identity `r_num < B·2^s ⟺ r_num>>s < B` re-proven for positive integers; shift ≤ 126 there so both `@intCast` shift amounts are legal u7; `held = us_a·num ≤ 2^36·2^32 = 2^68` fits even for hand-built u32 num. Non-tiny ⇒ `r_den ≤ r_num/us_a < 2^123`, so line 465's `num << shift` is proven safe.
- **Guard order**: `huge` (e > 74) still precedes `p << e` (:348-349); `p == 0` → anchor/exact before the tiny test (:386); ceiling pre-check still precedes `exactFloor` (:394-398) — the ruled order.
- **Threshold classification**: strictness is right — `r == us_a` exactly is NOT tiny and resolves to tick anchor+1 exact; verified that for genuinely-tiny literals the old full walk also answered anchor+inexact, so no old behavior moves (consistent with "no preexisting golden moved").
- **Segment crossing**: the skip-the-walk argument holds (next segment's origin is ≥ us_a past `anchor_num`, monotone `t_i`); the crossing test (:2702) re-derived: anchor 999, instant 1008.225 µs-units → tick 1000, span 1, inexact; 1e-16f → span 0. ✓
- **Sign-split compare** (:485): `dt ≥ 0 → true`, else `dt ≥ -r_num` is sign-identical to `dt + r_num ≥ 0`; overflow arm `d > 0` unchanged. The edge test (:2793) re-derived: dt at i=1 = 4.4e15·2^75 ≈ 0.977·2^127 fits, dt + r_num ≈ 1.008·2^127 overflows — red under the old code as a Debug panic, green now. ✓
- **Oracle arithmetic** re-derived bit-exact: 2e-15f at [1 100]/us 1 = 9.225216 ticks → inexact 9; 5e-15f (shift 100 seam) → 23; 1e-30f/5e-324f → arm A anchor; [1 16777215]/us 16777215, 1e-11f → 461.2608 → 461; num = 16777215 with shift 103/104 straddles arm B/A exactly as commented; 0x1p127 → tick_overflow. Corpus `frames-tiny` golden agrees: `(at … :tick 9 :sub 9)`, dump `9t` spans, 4 diags (1 position + 3 duration), bars 26 / last-start 4612608000, loop-secs = 1e-4 s. ✓
- **No weakening**: old frame pins untouched; only a comment and a blank line changed in preexisting tests.

## Collision + composed-manifest guard

- Rename applied exactly as ruled: `schema/tempura.sjon:139,335` → `timeline-frame-rate`; helpers `frame-rate-scalar/-pair` kept; generated `docs/timeline-language.md` carries the rename (:263) and the corrected `:fps` sentence (:30) matching the schema text; plan 02's dated note and plan 11's dated T1 correction present; README 87 = 87 case dirs + `.gitkeep` confirmed.
- The guard is real: `Schema.loadSourcesUnchecked` → `sjon.Host.preloadSchema` → `runAggregateValidators` → `validateKindRefs`, which emits `ambiguous_element_kind` for cross-plugin kind claims (SJON `Schema.zig:1385,1474`, corpus-locked per `Host.zig:1029`). Sibling checkout exists at `../animader/animader` with 5 manifests and `frame-rate` at `world.sjon:49`, so the test composes for real here. **Mutation robustness (structural)**: restoring `:name frame-rate` puts two claimants on `timeline`'s `:fps :type` and `frame-clock`'s `:positional` → diagnostics > 0 → red. Skip path: null → loud line + `SkipZigTest`, pinned by the bogus-override test; empty `schema/` → `EmptySiblingSchemaDir` fails; wrong override never falls back. Wiring: `schema_tests.zig` reached via `Schema.zig`'s test block ← `src/root.zig`; `TEMPURA_ANIMADER` read at the build border (`build.zig:110-115`), empty = unset; count claims internally consistent (1015+7=1022, 136+1=137, 86+1=87).
- frameLine doc (:539-544), `193 729 536` (:1021), spellDuration comment (:3493-3498) all as ruled.

## Findings

1. **LOW — `animaderManifests` errdefer frees uninitialized entries** (`src/schema_tests.zig:871-887`). `sources` is allocated uninitialized; if `path.join`/`readFileAlloc`/`dupeZ` errors at iteration k, `errdefer { for (sources) |s| gpa.free(s); … }` frees entries k..n−1, which are undefined pointers — UB on the error path (OOM, FileTooBig >8 MiB, mid-read deletion). Test-helper cold path only; fix is a filled-count prefix free. Not blocking.
2. **Observation (not a defect)**: `openDir` catch-all (:843) treats any open error (e.g. AccessDenied) as "absent" and the printed line says "not found". Loud either way, and within the ruling's prescribed skip semantics.

## Prior findings disposition

1 (tiny cutoff) — **closed**, two-arm exact test as ruled, reviewer's `shift>121` stays rejected. 2 (plan 11 T1) — **closed**, dated superseding correction. 3 ("prints nothing") — **closed**, schema + regenerated doc. 4 (stale comments) — **closed**. 5 (frameLine) — **closed** per ruling (pub kept, documented). Collision — **closed** (rename + real composed-manifest guard). Vendored-player sync — correctly left deferred to the next task, stated in plan 03.

## Explicitly unverified (control plane's, per the task; I ran nothing — read-only)

All gate executions: `zig build test` 1022/1022, corpus 87/87 including frames-tiny's `:bytes`/`:sha256` and diag byte spans (host `sha256sum` broken per the ruling's machine note), wasm parity incl. frames-tiny (`corpus.test.js` auto-discovers — structural ✓), npm 137/137, lint, wasm size 1 417 077 B, `tools/zt docs` idempotency, the rename mutation red/green, and the CLI-golden leg via the t2-shim. Worker claims were treated as claims; everything above the line is from source I read and arithmetic I re-derived. GitNexus: unavailable per the task note — no graph evidence used.
-----8<----- verbatim to here

# Annotations (2026-10-16, appended at the docs-only close)

- **File-line scope is as measured at `3345301`.** Every `:NNN` line reference in
  the verdict was read at that tip; the helper fix that followed (`2a72105`) shifts
  lines in `src/schema_tests.zig` — the LOW finding's file.
- **The LOW finding was fixed AFTER this review**, by `2a72105` ("test(schema):
  animaderManifests error paths free only what they own — filled prefix, owned
  names"), with both defects fail-first: a segfault red for the uninitialized
  prefix free, a `MemoryLeakDetected` red for the owned-name leak, then green;
  full suite 1009/1009 (890 + 119), lint 90 files clean, absence pin 162/163 with
  the one loud skip. Evidence: `.agent/control/report-t2-helper-hygiene.md`
  (ignored control plane).
- **"Vendored-player sync … correctly left deferred" has since been done
  locally**: the hello-player vendor copy re-synced byte-identical to `zig-out`
  (both 1 176 321 B, sha256 `00f923da…`) — a local sync, not a deployment or a
  release.
- **The verdict's "Explicitly unverified" list stands as written.** The gate
  numbers it names were the control plane's at `3345301`; the fresh post-`2a72105`
  control-plane verify is 1024/1024 tests over 25/27 steps, the one failure the
  environmental `cli_golden.sh`, whose sanctioned bash+t2-shim leg is green.
