# 14 — SJON 1.5.0 and Tempura's first release

Status: **Execution in progress (2026-10-25).** Written 2026-10-25 against Tempura
`98957cbf9069ab5c22bb9fd9bab1b29e42ae8ebc`.

The goal is a reproducible Tempura release using a published SJON version at
least 1.5.0, with a working Zig dependency and an installable npm package. The
proposed Tempura version is **0.1.0**, already spelled in the sources. Confirm
availability again before publishing. If a different version is chosen, record
the decision here and update every version spelling together.

R0, R1 and R2 executed and recorded; R3 is PARTIAL (loads and playback measured,
no tracker or DAW re-save); R4 is prepared; R5 is not executed — the registry has
no authenticated session on this machine and the manual tag gates are open.

This plan covers dependency migration, packaging, verification, release notes,
tagging and publication. The unfinished E4/E5 work is not implicitly part of this
release. Release notes must describe what actually ships and the remaining
integration limits. Preserve the append-only contracts in `CLAUDE.md`: diagnostic
ordinals, residue payloads, wasm blobs and exported ABI.

## Baseline observations — 2026-10-25

These are audit observations, not acceptance evidence for the eventual release.
Repeat the checks on the pinned dependency and final candidate. They were
superseded by the execution evidence below; they are kept as the pre-change
record.

| Surface | Observed result |
| --- | --- |
| Tempura version | `build.zig.zon`, `src/root.zig` and `npm/tempura/package.json` say 0.1.0. |
| SJON dependency | `build.zig.zon` uses `../SJON`; this follows a local checkout rather than a release pin. |
| Local SJON | HEAD `97e12f39d9e63d028aa9b124660cc4cfed4cc726`, manifest version 1.5.0. This is not the published release snapshot. |
| Published SJON | `git ls-remote --tags https://git.hugodaniel.com/releases/sjon.git 'v1.5*'` found `v1.5.0`, peeled commit `eb63b3fc4765795062943b5c731aa9bba36264ce`. No claim that 1.5.0 is the newest release. |
| Zig | 0.16.0. |
| `tools/zt verify` | Exit 0 against local SJON HEAD. Node: 137 tests passed, zero skipped. Corpus: 87 cases, zero failures. CLI goldens, generated docs, schema drift and wasm budget passed. |
| Verify output caveat | Native test output included a `sibling-compose` skip with `TEMPURA_ANIMADER=no-such-animader-checkout` and a `failed command` line despite overall exit 0. Determine whether this is the deliberate missing-checkout test; preserve the output and verify the positive composition check separately before claiming consumer coverage. |
| Wasm size | 1,416,572 bytes; ceiling 1,491,224 bytes. |
| npm lint | Fails Biome formatting in `npm/tempura/test/map.test.js`. |
| npm typecheck | Four errors: missing `PositionMap` type and missing declarations for `tpr_mapCap`, `tpr_exportScoreMap`, `tpr_mapPtr`. Declaration generation is therefore blocked. |
| npm pack preview | `npm pack --dry-run --ignore-scripts` succeeds, but the preview has no generated `types/` files. This bypassed lifecycle scripts and does not establish publishability. |
| Existing publication | `git ls-remote --tags origin` returned no tags. `npm view tempura version --registry=https://git.hugodaniel.com/api/packages/hugo/npm/` returned 404; this can also mean insufficient access. |
| Manual checks | `conformance/CHECKLIST.md` still marks tracker playback and DAW import checks UNMEASURED. |

The initial audit changed no tracked files. Its complete console logs were not
persisted in the repository; the observations above need fresh execution evidence.

## Checkpoints

Do these in order. Leave a checkbox open until its acceptance checks have evidence.
Record exact commits and commands, exit codes, skips and artifact hashes in the
execution ledger below. A local build, a packed installation and a published
installation are separate results.

### R0 — choose and pin the dependency

- [x] Recheck published SJON releases. Default to 1.5.0; select a newer stable
  release only after reviewing its changelog and compatibility impact.
- [x] Record the selected version, release repository, tag, peeled commit and
  immutable archive URL. Fetch it with Zig and record the resulting package hash.
- [x] Replace the sibling `.path` in `build.zig.zon` with `.url` and `.hash`.
  Keep `plugin-exec = false` for native and wasm dependency instances.
- [x] Update current setup documentation that requires `../SJON`. Preserve dated
  historical pins in old plans; annotate superseding decisions where needed.
- [x] Audit tests and scripts for assumptions about a sibling SJON CLI or wasm.
  Supply the selected release's artifacts for required checks, or document and
  record the explicit prerequisite. Do not accidentally test a different SJON.

Acceptance: a clean checkout resolves SJON without `../SJON`, and recorded
dependency metadata identifies the exact published source used for the build.

### R1 — repair npm packaging and build entry points

- [x] Format `test/map.test.js` with the existing formatter.
- [x] Define/export the public position-map JSDoc types and complete
  `TempuraExports` against the actual wasm signatures. Check the resulting public
  declarations against the runtime API.
- [x] Update npm scripts that invoke `zig build` directly to respect `tools/zt`.
  Check subprocess builds in pacer too; follow that repository's build conventions.
- [x] Make the test prerequisites repeatable: pin/record pacer source and package
  version, build its wasm, and prevent a stale sibling artifact from satisfying
  the landing proof. Keep development-only dependencies out of runtime installs.
- [x] Run `npm run lint`, `npm run typecheck` and `npm run build:types` in
  `npm/tempura`; require exit 0 for all three.

Acceptance: declaration generation succeeds, advertised type exports exist, and
the documented build/test commands run through the required build wrappers.

### R2 — validate clean builds and packed consumers

- [x] Run `tools/zt verify` with the pinned SJON. Retain its complete log and
  investigate failures or unexpected skips. Ensure the Node suite, native/wasm
  corpus parity, landing proof and SJON position-map proof actually execute.
- [x] Run the positive sibling composition check with the intended animader
  checkout; record its commit and result independently of missing-checkout tests.
- [x] Run `tools/zt audit-diagnostics`, `tools/zt fuzz` and `tools/zt conform`;
  record the fuzz scope/duration and every unavailable oracle or skipped case.
  Install or provision required tools before calling their coverage complete.
- [x] Audit `build.zig.zon`'s `.paths`: it currently includes only build files,
  `src/` and `schema/`, while the build graph references `tools/`, examples and
  corpus assets. Decide which files distributed consumers need and verify it by
  consuming an actual Zig package archive from a separate minimal project.
- [x] Build the CLI and wasm from a clean checkout with the pinned dependency.
  Record the toolchain, commands, target and optimization mode.
- [x] Run `npm pack` with lifecycle scripts enabled after fixing their build
  entry points. Inspect the tarball for JavaScript, wasm, all declared `.d.ts`
  entry points, README and license; exclude workspace-only dependencies.
- [x] Install the tarball in a temporary project outside the workspace. Check
  package/subpath imports, compile a TypeScript consumer, resolve and load wasm,
  then exercise a timeline, edit, score export with position map, and `.mid`/`.it`
  round trips. Compare deterministic results with the native CLI where applicable.

Acceptance: the gate passes on the pinned source, clean Zig and npm consumers
work without ambient sibling resolution, and any unavailable coverage is named
explicitly. Review golden diffs if regeneration is necessary; never hand-edit them
or raise the wasm ceiling simply to make the gate pass.

The `sibling-compose` caveat is the deliberate missing-checkout test
(`src/schema_tests.zig`, "an absent animader checkout is a loud skip"). The
positive leg ran separately with `TEMPURA_ANIMADER=../animader/animader`
(animader `98ff06e`): 163/163 tests passed, including the nine-plugin
composition.

### R3 — complete the manual tag checks

- [ ] Follow sections A and B of `../../conformance/CHECKLIST.md`: tracker load
  and playback, and DAW import. Record tool versions, dates and outcomes there.
  libopenmpt 0.8.9 and Schism Tracker 20260524 measured load and playback;
  OpenMPT GUI, Impulse Tracker 2.14/DOSBox and every DAW import remain unrun.
- [ ] Record re-save/export residue survival separately in section C. Retain
  hashes and outcomes for personal fixtures without committing those files.
  No re-save was performed, so every survival column stays unmeasured.
- [x] Update `conformance/PINS.md` with tool versions actually exercised.

Acceptance: the checklist's tag gates have measured outcomes. Residue survival
remains a measurement rather than a promise that every tool preserves metadata.
If a gate cannot be performed, keep this checkpoint open; any change to the tag
policy needs an explicit dated decision, not an inferred pass.

### R4 — prepare the release candidate

- [ ] Confirm version 0.1.0 is still unused in the intended registry and tag
  namespace. Check authenticated access when distinguishing absence from a 404.
  `npm whoami` against the configured registry answers `ENEEDAUTH`; the 404
  therefore cannot be distinguished from missing access.
- [x] Keep `build.zig.zon`, `src/root.zig`, npm manifest and lockfile versions
  synchronized. Check any other release metadata for drift.
- [x] Write release notes covering the first release's supported CLI, Zig and
  wasm/npm surfaces, selected SJON version, Zig/Node requirements and known limits.
  Update README and milestone status to match the final release state.
- [x] Record the distribution destinations. Current npm configuration is
  `https://git.hugodaniel.com/api/packages/hugo/npm/`; the Git release
  destination is `https://git.hugodaniel.com/hugo/tempura.git`. No native
  binaries are part of the advertised artifacts: the npm tarball carries
  `tempura.wasm`, and the CLI is built from source with `tools/zt cli`.
- [x] Commit the candidate, rerun the applicable gates on that exact source, and
  build final artifacts. Record commit IDs, artifact sizes and SHA-256 hashes.
  Repeat affected checks if source changes after this point.

Acceptance: one identifiable candidate has passing evidence, reviewed notes and
immutable artifacts ready to publish. No unrelated E4/E5 feature is implied.

### R5 — publish and verify the public result

- [ ] Push the release commit and `v0.1.0` tag to the recorded destination.
- [ ] Publish the checked npm package using the configured registry; attach the
  selected artifacts, checksums and release notes to the release record.
- [ ] Query the remote tag and npm metadata; record the resolved commit,
  version, dist-tag and package integrity. Verify they identify this candidate.
- [ ] Install from the registry in a fresh consumer project and repeat the
  import, TypeScript and wasm smoke checks from R2 using the downloaded package.
- [ ] Fetch the published Zig archive in a fresh consumer and build it. Check
  downloads and hashes for any attached native binaries.
- [ ] Mark the plan complete only after the public checks pass. If publication
  succeeds only partly, record what is live and what failed. Do not move a
  published tag or overwrite a published package to hide a mismatch; document
  and prepare a corrective release when needed.

Acceptance: consumers can obtain and use the recorded release through every
advertised distribution channel.

## Execution ledger

Persist logs/reports under `docs/plans/evidence/release-0.1.0/` when execution
starts. Never include credentials. Link each checkpoint to its evidence; store
large binaries separately and record their locations and SHA-256 hashes here.

| Checkpoint | Status | Commit(s) | Evidence / commands / outcomes |
| --- | --- | --- | --- |
| R0 — SJON pin | done | `4815082` | SJON 1.5.0, `v1.5.0` peeled `eb63b3fc4765795062943b5c731aa9bba36264ce`; archive `https://git.hugodaniel.com/releases/sjon/archive/eb63b3fc4765795062943b5c731aa9bba36264ce.tar.gz`; Zig package hash `sjon-1.5.0-QUbZyz2SdgClKGQFDvenzv0dXMEtBXbqxzsWEmQLmV12`. Clean copy with no `../SJON` and a fresh `ZIG_GLOBAL_CACHE_DIR` built the CLI and both wasm copies (`evidence/release-0.1.0/clean-build.log`, exit 0). |
| R1 — npm repairs | done | `4815082` | `npm run lint`, `typecheck`, `build:types` all exit 0; `types/` exports `PositionMap` and `tpr_mapPtr`/`tpr_mapCap`/`tpr_exportScoreMap`. npm scripts now call `tools/zt`; pacer is built through its own npm scripts from the recorded `pacer-pin.json` (`5face6f`, package 0.1.0, wasm `5a6d5316…`) and the artifact hash is enforced before the landing proof. |
| R2 — automated and packed consumers | done | `4815082` | `tools/zt verify --summary all` exit 0: 30/30 steps, 1024/1024 Zig tests, Node 137/137 with zero skips, corpus 87/87, wasm 1,416,572 bytes of 1,491,224. `audit-diagnostics` 91/92 covered, 1 pending, 0 missing. `fuzz` 887/887 in 156 s. `conform` runs with libopenmpt 0.8.9 and midicsv 1.1; `smf-smpte` is refused by `csvmidi`'s non-SMPTE header (oracle limit); wiki IT cases are unpinned. Zig package archive fetched and consumed by a minimal project (`tempura 0.1.0` printed). npm tarball `783fbdfa…` (530,609 bytes) installed outside the workspace; smoke + `tsc` passed, and both `.mid`/`.it` builds match the native CLI. Logs under `evidence/release-0.1.0/`. |
| R3 — manual tag checks | partial, open | `4815082` | libopenmpt 0.8.9 and Schism 20260524 load and render `gate.it`; `openmpt123 --info --message` shows the `;; tempura` tail. Invisibility: `.it` key fields equal, `.mid` `midicsv` rows equal after stripping `Sequencer_specific`. No re-save, no OpenMPT GUI, no IT 2.14/DOSBox, no DAW import. `conformance/CHECKLIST.md`, `PINS.md` updated; `evidence/release-0.1.0/gate/`. |
| R4 — release candidate | prepared, open | `4815082` | Notes `CHANGELOG.md`; version lockstep 0.1.0 in `build.zig.zon`, `src/root.zig`, npm manifest and lockfile. Final artifacts: CLI `567b72d5…` (9,602,136 B, Debug), wasm `b3827aab…` (1,416,572 B), npm tarball `783fbdfa…` (530,609 B). Registry availability still unconfirmed because `npm whoami` has no auth. |
| R5 — publication and fresh installs | blocked | — | Not executed. `npm whoami --registry=https://git.hugodaniel.com/api/packages/hugo/npm/` returns `ENEEDAUTH`; no tag was pushed and no package was published. The manual R3 gates also stay open. |

For each run record date, OS/architecture, tool versions, Tempura commit, SJON
version/commit/hash, relevant sibling commits, command and working directory,
exit status, skips, log path and artifact hashes. Record publication URLs and
downloaded metadata for R5. Keep baseline observations distinct from final proof.

Run environment for every entry: 2026-10-25, macOS 26.12.0 arm64, Zig 0.16.0,
Node 26.12.0, npm 11.20.0, working directory `/Users/hugo/Dev/tempura`, animader
`98ff06e`, pacer `5face6f`. The `failed command:` line beside the deliberate
`sibling-compose` skip is preserved in the logs and is not a gate failure; the
`--summary all` logs show every step succeeding.

## Decisions and changes

- 2026-10-25: initial plan persisted at the user's request. Proposed release is
  0.1.0 with SJON 1.5.0; execution and publication remain pending. No release
  checkpoint is closed by the preliminary audit alone.
- 2026-10-25: execution started. SJON pinned by immutable commit archive (not
  the movable tag archive). The map proof's SJON wasm is built from that same
  dependency (`tools/zt sjon-wasm`), not read from a sibling checkout. pacer is
  a dev-only test prerequisite pinned by `npm/tempura/pacer-pin.json`; the
  runtime npm package does not depend on it. R5 is left blocked by missing
  registry authentication and the open manual gates rather than inferring a
  pass.
