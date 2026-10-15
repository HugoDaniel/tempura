# Verification — T2 final real-browser QA (task-t2-browser-final)

Date: 2026-10-15. Verifier: browser-tester subagent (no source edits, no server start, no shell).

Targets (both served by the pre-existing workspace-root static origin on :8087; the browser
reached `localhost` directly, so the `127.0.0.1` alternate origin was NOT needed):

- TEMPURA  `http://localhost:8087/tempura/.agent/control/t2-browser/index.html`
- CONSUMER `http://localhost:8087/animader/animader/.agent/control/t2-evidence/browser/index.html`

Engines: Chromium (`playwright` MCP) and WebKit (`playwright-webkit` MCP, UA
`...AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Safari/605.1.15`), serial, each at
desktop 1280x900 and mobile 390x844, each viewport a fresh navigation (each load re-fetches all
artifacts with `cache: 'no-store'`). Engine unable to run: none — both engines ran both pages.

## 1. Result matrix (engine / viewport / page / cases)

| Engine | Viewport | Page | cases | Result |
|---|---|---|---|---|
| Chromium | 1280x900 | TEMPURA | 8 | 8 pass, 0 fail |
| Chromium | 390x844 | TEMPURA | 8 | 8 pass, 0 fail |
| WebKit | 1280x900 | TEMPURA | 8 | 8 pass, 0 fail |
| WebKit | 390x844 | TEMPURA | 8 | 8 pass, 0 fail |
| Chromium | 1280x900 | CONSUMER | 4 | 4 pass, 0 fail |
| Chromium | 390x844 | CONSUMER | 4 | 4 pass, 0 fail |
| WebKit | 1280x900 | CONSUMER | 4 | 4 pass, 0 fail |
| WebKit | 390x844 | CONSUMER | 4 | 4 pass, 0 fail |

Titles: `T2 browser verification — ALL GREEN` and `T2 composed consumer — ALL GREEN` in all eight
runs. No case failed anywhere; no case was skipped or absent. Same case identities at desktop and
mobile on both engines (verified by reading `window.__T2_RESULTS__` /
`window.__T2_CONSUMER_RESULTS__`, not the title).

## 2. TEMPURA — raw summary block text (in-page, Chromium 1280x900)

```
oracle self-check : ok — ok 20f@25 = 1bar; ok frame 1 NTSC floors to 7 695 367;
                    ok frame 25 NTSC exact at 192 384 192; ok frame 5 film exact at 48 096 048;
                    ok frame 1 film floors to 9 619 209
cases            : 8 total, 8 pass, 0 fail
wasm sha256      : 8014cc8a6ff4e194bc24cec19a7970bc224372e0174b6ab5a45720aa93f3c33b
abi version      : 1
ALL GREEN
```

`window.__T2_RESULTS__` (BigInt-safe stringify) — `wasm.url` =
`http://localhost:8087/tempura/npm/tempura/tempura.wasm` (the URL actually fetched for
instantiation), `sha256` = `8014cc8a…f3c33b`, `passed: 8`, `failed: 0`,
`oracle` = all five pins `true`. Per-case `ok`, `error` and `diagnostics` from that JSON:

- A frames-25 exact — ok, error null, diagnostics `[]`; 9 checks green incl.
  `20f onset tick 184504320`, `length 100f tick 922521600`, `frame_inexact 0`, `at(0.8) tick 184504320`.
- B frames-ntsc — ok, error null, diagnostics = **2 x {severity:"warning", code:90}**,
  identities position(start 147,end 149)+duration(start 155,end 157); `1f` floors to `7695367`,
  `25f` = `192384192`, `atTick(192384192).bar = 1`, `.subTicks = 7879872`.
- C missing :fps — ok, error null, diagnostics = **1 x {severity:"error", code:91}**,
  message "this document declares no :fps, so a frame position cannot resolve";
  load refused (`ok false`), `onsets 0`, zero code-90.
- D frames-film — ok, error null, diagnostics = **2 x {severity:"warning", code:90}**
  (position+duration); `1f` → `9619209`, `5f` → `48096048` exact.
- E rate alone — ok, error null, diagnostics `[]`; header keeps `:fps 25`, text minus ` :fps 25`
  byte-identical, both 'TPTL' derivations agree tick for tick.
- F edits — ok, error null, diagnostics `[]`; tempo segment 1 tick `369008640`, `us 400000`;
  meter `[3 4]` at `184504320`; note still `:at 20f`; onset unchanged `184504320`; zero code-90.
- G frames-tiny 2e-15f — ok, error null, diagnostics = **3 x {severity:"warning", code:90}**
  identities duration+position+duration; oracle `2e-15f = 9.225216 t → 9`; `at(2e-13) = 9`;
  `at(1e-6) = 46126080`; `at(1e-6 + 2e-13) = 46126089`.
- H frames-tiny seam 5e-15f — ok, error null, diagnostics = **2 x {severity:"warning", code:90}**
  identities position+duration; oracle `5e-15f = 23.06304 t → 23`; seam places tick `23`
  (not anchor 0); `at(5e-13) = 23`; `at(2e-6 + 5e-13) = 92252183`.

## 3. CONSUMER — raw summary block text (in-page, WebKit 1280x900)

```
oracle self-check : ok — ok tps(qpm300) = 230630400; ok one frame at 25fps = 9225216;
                    ok 20f = 184504320 = 1bar; ok 20f sits on pacer tick 720720 exactly;
                    ok NTSC 1f floors to 7695367; ok NTSC 25f is tick-exact at 192384192;
                    ok floored NTSC 1f -> pacer 30060; ok exact NTSC 25f -> pacer 751501 (a quarter tick up)
cases            : 4 total, 4 pass, 0 fail
animader wasm    : 00f923da8e5a46b3fa2ca49e3b82aba44efc61fd6ae35f84339170836f373262 (vendored === zig-out)
pacer wasm       : 45e16cce6b78c99950147dfb97dbd6d78683b86dab61d2b3e9a61a2c982467cb
hello program    : 16781 bytes pngb (needs kernels/hash.wgsl, kernels/simplex.wgsl, kernels/curl.wgsl, kernels/ember.wgsl, bake/spans.bin)
ALL GREEN
```

`window.__T2_CONSUMER_RESULTS__.artifacts` — every entry is the FETCH used to instantiate
(`crypto.subtle` digest of the fetched bytes, `cache:'no-store'`):

| key | url | bytes | sha256 |
|---|---|---|---|
| animaderVendor | /animader/animader/examples/hello/player/vendor/animader/animader.wasm | 1176321 | 00f923da8e5a46b3fa2ca49e3b82aba44efc61fd6ae35f84339170836f373262 |
| animaderZigOut | /animader/animader/zig-out/bin/animader.wasm | 1176321 | 00f923da8e5a46b3fa2ca49e3b82aba44efc61fd6ae35f84339170836f373262 |
| pacerWasm | /pacer/npm/pacer/pacer.wasm | 661334 | 45e16cce6b78c99950147dfb97dbd6d78683b86dab61d2b3e9a61a2c982467cb |
| pngineCompiler | /pngine/npm/pngine/wasm/pngine-compiler.wasm | 2134288 | ae3e5054b7a7dbc44f941676de686136bbfe568bbc4b17b420cd56bdde65b95c |
| helloProgram | /animader/animader/examples/hello/program.sjon | 16781 | (no digest field) |

All four digests equal the disk pins in the task brief exactly; vendored === zig-out (the link
guard's rule re-proven over HTTP). A page that failed the digest guard would refuse to run.

Oracle: all eight pins `true`. Cases (per-case `ok`/`error`/check counts from the JSON):
A frames25 — ok, error null, 14 checks; B framesntsc — ok, error null, 14 checks;
C frame-clock — ok, error null, 3 checks; D missing :fps — ok, error null, 4 checks.
Key numerical checks corroborating the brief: score slices floor onto pacer ticks
`0,720720,0,720720` (A) and `0,751501,30060,751501` (B); warmth track exactly
`f32(0.9) = 0.8999999761581421` at pacer tick 720720 / 751501 and under it one tick before;
tally A/B "no rounded positions" vs "3 rounded positions + 1 rounded duration" (warning class);
floored NTSC 1f lane entry begins exactly at pacer tick 30060 (count 1→2); frame exact
1001/1200 s floors to 751500, NOT the event tick 751501; `eval(double 0.8)` exact and
`−1 ulp` before it; routed+folded heat write answers `0.6000000238418579` (last-word rule);
C identity load clean with `scoreMap` state `identity+null`; D `frame_rate_missing` refusal,
empty digest, `score()` throws `animader: anm_piece_score failed: diagnosed load`.

## 4. Console

- TEMPURA / Chromium: 1 error — `Failed to load resource: 404 (File not found) @
  http://localhost:8087/favicon.ico`. Class = **network/API (benign, non-functional)**:
  the browser's automatic favicon probe; the fixture never requests it and no case depends on it.
- TEMPURA / WebKit: 0 messages at warning-or-worse (0 errors, 0 warnings).
- CONSUMER / Chromium and WebKit: 0 errors, 0 warnings. Four `[LOG]` lines (info) in each:
  `frames25 score 508 bytes sha256 40711b86…`, `framesntsc score 571 bytes sha256 dc89af09…`,
  `framesntsc tally: positions: 3 rounded (max 0.0000013875013875013875b), durations: 1 rounded
  (max 0.000002775002775002775b); onsets: 0 aggregated`, `frameclock score 523 bytes sha256 3fe8e3ac…`.
- Uncaught exceptions / rejected promises: none observed in either engine.

## 5. Network

- TEMPURA: 6 requests, all `200 OK` — index.html, main.js, npm/tempura/src/{index,ops,blobs}.js,
  npm/tempura/tempura.wasm. No other origin contacted.
- CONSUMER: 23 requests, all `200 OK` — the four modules + lane.js, the four wasm artifacts,
  the four piece/program .sjon documents, program.sjon, the four kernels/*.wgsl and bake/spans.bin.
  The deliberate "missing :fps" case is an in-page diagnosed load (code 91), **not** a network error
  — case D's document (`frames25.piece.sjon` reused) fetched 200 and the refusal is a wasm diagnostic.

## 6. Screenshots (paths are server-local to this worktree)

`.agent/screenshots/t2-final/`

- `tempura-chromium-desktop-1280x900.png` (full page; shows fetched url/bytes/sha256, 8 PASS cards, 8/0 summary, ALL GREEN)
- `tempura-chromium-mobile-390x844.png`
- `tempura-webkit-desktop-1280x900.png`
- `tempura-webkit-mobile-390x844.png`
- `consumer-chromium-desktop-1280x900.png`
- `consumer-chromium-mobile-390x844.png`
- `consumer-webkit-desktop-1280x900.png` (full page; shows all four artifact url/bytes/sha256 lines, 4 PASS cards, 4/0 summary, ALL GREEN)
- `consumer-webkit-mobile-390x844.png`

Rendered content inspected by reading two of them back (tempura-chromium-desktop and
consumer-webkit-desktop) — both show the real per-check expected/actual lines, not just a banner.

## 7. Layout / accessibility

- No horizontal overflow at 390x844 on either page (`document.documentElement.scrollWidth <=
  innerWidth`; `hScroll: false` in all four mobile runs). No clipping/overlap seen in the
  full-page mobile screenshots.
- Accessibility tree reachable and meaningful, not just visual: each page exposes an
  `h1` (page title), per-case `PASS` text nodes plus a `<code>` element carrying the case name,
  check lines as text, a per-case `<details>` group ("diagnostics + raw record"), and an
  `h2 "Summary"` landmark with the summary text. No unlabeled interactive control was needed by
  this flow (the fixtures are read-only; the only interaction is the browser's own auto favicon
  fetch). No accessibility failure found; no interactive element was exercised because none is
  required by the flow.

## 8. Graphics surfaces

Not applicable — these two fixtures render no canvas/WebGL/WebGPU and claim none (the task states
"no WebGPU rendering claimed"). The consumer exercises the pngine compiler, uniform routing and
pacer values on the CPU path; "motion is NOT expected" per the task, so no video/motion check was
run. No context/device-loss surface exists here.

## 9. Findings by class

- functional failure: none.
- JavaScript/runtime error: none.
- network/API failure: none affecting the flow; one benign `favicon.ico` 404 (Chromium TEMPURA load only), see §4.
- accessibility problem: none found.
- layout/visual suspicion: none found.

Artifact identity: the hashes/bytes reported come from the fetch that instantiated each engine and
match the task's disk pins exactly, so no "green against the wrong build" mismatch exists.

## 10. Explicitly NOT verified

- I did **not** run `sha256sum`/`python3 hashlib` on the served tree (shell is denied to this role
  and the task forbids shell curl/localhost checks). Artifact identity rests on the in-page
  `crypto.subtle` digests above matching the task-supplied disk pins.
- I did **not** re-run the native/npm/corpus test counts (1024/1024, 137/137, 87, 403/403, 112/112)
  or the copy-cp gates — those are control-plane context, not browser results.
- I did **not** expand the "diagnostics + raw record" `<details>` widgets by clicking; I read the
  same record directly from `window.__T2_RESULTS__` / `window.__T2_CONSUMER_RESULTS__`.
- I did **not** test any other browser engine, viewport, or the alternate `127.0.0.1` origin
  (unnecessary — `localhost` resolved for the browser on every run).
- I did **not** verify motion/animation, canvas sizing, shader compilation or device-loss handling —
  no such surface exists in these fixtures.
- I did **not** make any repo/source change, commit, build, deploy or design judgement.

---

# Addendum — T2 design/interaction acceptance verdict (2026-10-15)

A separate, fresh read-only design-acceptance session reviewed this evidence (report,
screenshots, detector output) and re-checked both live pages with Playwright (tempura:
8/8, all five oracle pins true, no horizontal scroll; consumer: 4/4, all eight oracle
pins true, no horizontal scroll). **Verdict: PASS — accept.** No BLOCKER or IMPORTANT
findings; two OPTIONAL fixture-level nits (benign favicon 404, mid-token wrapping of
long monospace lines at 390px). Full verdict with scope-checklist grounding and
unverified list is appended to `.agent/control/task-t2-design-acceptance.md`.

---

# Copy note (2026-10-16, the docs-only close — not part of the report above)

Everything above the rule is a byte-identical copy of the control-plane original
`.agent/verification.md`, written 2026-10-15 and committed here as T2's browser
evidence. Three things the copy cannot say for itself:

- **Line references, run paths and URLs are as measured** on 2026-10-15, against
  tempura `2a72105` and animader `284f66d` ([03](../03-time-model.md)'s dated final
  entry is the record of record). The `.agent/` tree is git-ignored (repo
  `info/exclude`), so every control-plane path in the report is a pointer into an
  uncommitted original, not an artifact that ships with this file.
- **The eight screenshots live only in the ignored `.agent/screenshots/t2-final/`**
  and are deliberately not committed with this record.
- **One correction, dated, beside the quote:** the design-acceptance control log
  (`t2-design-acceptance.log`) concludes with the phrase "T1 frame-clock consumer",
  which conflates two unrelated things and is wrong. T1 is tempura's source-map
  export (`export-score --map`, the `'TPMP'` sidecar, `tpr_exportScoreMap`) — built
  and consumed 2026-10-08, and proven live by the composed consumer probe's
  `scoreMap`/`'TPMP'` span checks. "Frame-clock" is animader's existing world
  provider, whose part in this matrix is a clean identity load (`scoreMap` state
  `identity+null`); its provider EXECUTION remains unimplemented, as before. The
  report copied above does not contain the phrase; this note exists so nobody
  propagates it from the ignored log later.
