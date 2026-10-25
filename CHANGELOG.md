# Changelog

## 0.1.0 — first release candidate (2026-10-25)

tempura is the family's timeline core: one SJON document, `(timeline …)`, is the
authoritative arrangement of a piece in musical time, and `.mid` / `.it` files
are read as values and written back deterministically around it. It is a pure
function; it never plays anything. It exports the pacer score that does.

This is the first release. It reaches the E3 freeze; E4 and E5 are not part of
it.

### Surfaces

- **CLI** — `tempura <verb> FILE`: `dump`, `build`, `export`, `validate`,
  `inspect`, `timeline`, `export-score`, `inline`, `edit`, `at`,
  `check-residue`. Exit `0` clean, `1` input errors, `2` usage, `3` resource
  failure. `--help` is the option list.
- **Zig** — the public module (`src/root.zig`, imported as `tempura`) with the
  document, time, SMF, IT, edit, export and residue parts. Minimum Zig 0.16.0.
- **wasm / npm** — `tempura.wasm` (wasm32-freestanding, `ReleaseSmall`,
  `rdynamic`) and the ESM package `tempura` with generated TypeScript
  declarations. Node 20 or newer. Subpaths: `tempura`, `tempura/ops`,
  `tempura/blobs`, `tempura/tempura.wasm`.

The four frozen surfaces are unchanged from E3 and remain append-only:
`Diag.Code` ordinals, the residue payloads, the three wasm blobs (`'TPTL'`,
`'TPPH'`, `'TPDG'`), and the `tpr_*` export set.

### Dependency

SJON **1.5.0**, pinned by immutable archive at its peeled commit
`eb63b3fc4765795062943b5c731aa9bba36264ce`:

```
https://git.hugodaniel.com/releases/sjon/archive/eb63b3fc4765795062943b5c731aa9bba36264ce.tar.gz
sha256 package hash: sjon-1.5.0-QUbZyz2SdgClKGQFDvenzv0dXMEtBXbqxzsWEmQLmV12
```

A clean clone needs no `../SJON` checkout. Consumed with `plugin-exec = false`.

### Verification for this candidate

`tools/zt verify` passes: 1024/1024 Zig tests, 137/137 `node --test` tests with
zero skips, all 87 corpus cases, the CLI goldens, generated-docs drift, schema
drift, the wasm size budget (1,416,572 bytes against the 1,491,224-byte
ceiling), and the landing and position-map proofs. `tools/zt audit-diagnostics`
reports 91/92 codes covered, 1 pending, 0 missing. `tools/zt fuzz` passes
887/887 tests. See `docs/plans/evidence/release-0.1.0/`.

### Known limits

- **Conformance oracle:** with `openmpt123` 0.8.9 every committed `.it` case
  loads; with `midicsv` 1.1 every committed `.mid` case round-trips except
  `smf-smpte`, whose SMPTE division `csvmidi` refuses (an oracle limitation —
  tempura reads SMPTE per OpenMPT's rule and never writes it). The OpenMPT wiki
  IT cases are not fetched because their pins in
  `conformance/fetch_wiki_cases.sh` are still `TODO`.
- **Manual tag gates:** `conformance/CHECKLIST.md` has measured loads and
  playback for libopenmpt and Schism Tracker, but no tracker or DAW re-save
  survival result, no Impulse Tracker 2.14/DOSBox run, and no DAW import run.
  Residue survival remains measured, never promised.
- **`smf-smpte`:** reading is covered; SMPTE is converted to an equivalent
  PPQ and the writer never emits SMPTE.
- **Query and formula lanes** are not representable in a `.mid` or `.it`; they
  ride in the residue alone (`residue_only`).
- E4/E5 work (studio pane, transport display, payload kind beyond the reserved
  `TMPU`, pattern-by-section, vector lanes, the page, the musicians' leg) is
  not included.

### Licence

CC0-1.0. Third-party provenance is in `THIRD_PARTY_NOTICES.md`.
