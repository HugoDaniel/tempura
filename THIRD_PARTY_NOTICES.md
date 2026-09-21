# Third-party notices

tempura is CC0-1.0 (`LICENSE`). This file is the per-item register of what was
actually taken from a third-party work, what was taken from it, where it landed, and
which condition that carries. An entry is added in the same commit as the code it
covers. The policy table of record is `docs/plans/09-conformance.md`, "License
discipline (the one place it lives)"; this file is the ledger that policy produces.

Paths are spelled as the plan set spells them: `~/Dev/X` and `~/llm/X`, which on
the authoring machine are `~/Development/X` and `~/Development/specs-llm/X`.

Three rules govern everything below:

* **BSD-3 work is portable with attribution.** Each port carries a source comment
  naming the file and line it came from, and an entry here.
* **GPL work is doctrine only.** Schism Tracker is read to settle a behaviour
  question when the specification and OpenMPT disagree. Nothing is ported; each
  consultation is a comment citing file and line.
* **Specifications are restated, never reproduced.** The byte tables in the plans
  and in `src/` are the minimal restatement needed to implement, in tempura's own
  words.

---

## OpenMPT — BSD-3-Clause

Upstream: `~/llm/repositories/openmpt` (pinned at `6ef84997`; the checkout
is empty on this machine, so the line citations below are inherited from the it and
midi plan sets' 2026-08-27 verification and carry that date).

### What was ported

| What | Where it landed | Cited source |
| --- | --- | --- |
| The CP437 → Unicode table for the upper half (`CharsetTableCP437`, itself generated from Unicode's `CP437.TXT`) | `src/itf/Module.zig`, `cp437_high` | `src/mpt/string_transcode/transcode.hpp:134` |
| The IT pattern packing / unpacking scheme — the per-channel mask cache, the repeat bits, the note-sentinel mapping | `src/itf/pattern.zig` | `Load_it.cpp:1755-1977` |
| The edit-history block guard: the block is honoured only when it fits under the lowest non-zero parapointer | `src/itf/regions.zig` (`MinPointer`, `editHistory`) | `Load_it.cpp:642-690` |
| The SMPTE division rule: `frames · subframes / 2` as the pulses-per-quarter a SMPTE file converts to, and 96 as the grid for a zero division | `src/smf/Sequence.zig` (`Division`), `src/smf/read.zig` | `Load_mid.cpp:661-669` |
| The `RIFF`/`RMID` wrapper rule: an SMF found inside a RIFF container is read from the container | `src/smf/read.zig` | `Load_mid.cpp:587-613` |
| The IT reader's and writer's clamps, the "itEx" bounds a tolerant loader accepts: 240 patterns, 239 in the wild, the `--loose` write bounds | `src/itf/read.zig`, `src/itf/write.zig`, `src/doc/bridge_it.zig` | `Load_it.cpp` (it 04 / it 05's restatement) |
| The reader's tolerance rules: the CRLF pair in a song message read as one newline; command bytes 27–31 read as no effect; the `Cwtv`/`Cmwt` reading at `Load_it.cpp:557` | `src/doc/bridge_it.zig`, `src/itf/pattern.zig`, `src/itf/Module.zig` | `Load_it.cpp:750-753`, `Load_it.cpp:557` |
| The volume-column sample-offset extension (bytes 223–232), read with a diagnostic and dropped on write | `src/doc/bridge_it.zig` | OpenMPT's volume-column extension table |
| The trailing extension-chunk tags a foreign `.it` may carry (`STPM`, `XTPM`), preserved opaque | `src/itf/Module.zig` (`Foreign`) | OpenMPT's IT extensions |
| Row-tick behaviour cited while implementing the walk: `GetNumTicksOnCurrentRow()`, the `SD0`-as-`SD1` rule, the pattern-loop start on row 0 | `src/itf/walk.zig` | OpenMPT's `Snd_fx.cpp` behaviour, per plan 06 |
| `libopenmpt` as the `.it` oracle | test time only, from Homebrew, pinned in `conformance/PINS.md` | never vendored, never linked into tempura |

### Required notice

OpenMPT is distributed under the 3-clause BSD licence. The licence requires that
the copyright notice, the list of conditions and the following disclaimer be
reproduced in the documentation of a work that redistributes portions of it in
binary or source form:

> Copyright (c) OpenMPT Project Developers and Contributors.
> All rights reserved.
>
> Redistribution and use in source and binary forms, with or without modification,
> are permitted provided that the following conditions are met:
>
> 1. Redistributions of source code must retain the above copyright notice, this
>    list of conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright notice, this
>    list of conditions and the following disclaimer in the documentation and/or
>    other materials provided with the distribution.
> 3. Neither the name of the author nor the names of its contributors may be used
>    to endorse or promote products derived from this software without specific
>    prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
> ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
> WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
> DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
> ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
> (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
> OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
> THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
> NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
> IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

> **Unpinned, 2026-09-21.** The copyright line above names the holder as the plan
> set names the project, not as `LICENSE.txt` in the upstream tree spells it: the
> `openmpt` checkout is empty on this machine, so the exact holder wording and the
> year range could not be read. Replace the first line with upstream's verbatim
> copyright line — and only that line — on the first tag cut from a machine that has
> the checkout.

---

## Impulse Tracker (source and documentation) — BSD-3-style, Jeffrey Lim, 2014

Upstream: `~/llm/repositories/impulsetracker` (pinned at `9fcee05b`; empty
on this machine, so the tables below are inherited from the it set's 2026-08-27
verification). The in-tree `LICENSE.TXT` governs; the repository README still says
"license pending" and the licence text never uses the word "BSD", but its three
clauses are BSD's, with the older "name of the author" wording of the
no-endorsement clause.

### What was taken

`ReleaseDocumentation/ITTECH.TXT` is the normative format specification. Its tables
are restated — as offsets and sizes in tempura's own words, not as prose copied —
in the files below.

A source comment of the form `it 04 §"Pattern unpacking"` cites the **it plan set**
(`~/llm/plans/it/`), which is this family's own restatement of ITTECH and is where
the 2026-08-27 verification date comes from; it is not a third-party work and is not
reproduced here. `ITTECH.TXT` itself is the authority behind it.

| What | Where |
| --- | --- |
| The 192-byte Impulse Header's field offsets, the 554-byte instrument and 80-byte sample record sizes, the sample header's field offsets, the `Special` bit meanings | `src/itf/Module.zig` (`hdr`, `smp`, `header_size`, `instrument_size`, `sample_header_size`, `special`) |
| The pattern packing mask algorithm, the on-disk note sentinels (254 cut, 255 off, 120–253 fade), the command numbering `cmd = letter - '@'`, the 0–31 command range | `src/itf/pattern.zig`, `src/itf/Module.zig` |
| The timing effects and their semantics, by command number | `src/itf/walk.zig`, `src/export/render_it.zig`, `src/residue/records.zig` |
| The order list, the parapointer arrays, the edit-history and MIDI-configuration layout, the 4896-byte `ITMIDI.CFG` default | `src/itf/read.zig`, `src/itf/regions.zig` |
| The header's timing fields and the loader's effective speed / tempo floors | `src/itf/Module.zig` (`Header.effectiveSpeed`, `effectiveTempo`) |
| Fixture material built from the tables | `tools/gen_fixtures.zig` |

### Required notice

> Copyright (c) 2014, Jeffrey Lim.
> All rights reserved.
>
> Redistribution and use in source and binary forms, with or without modification,
> are permitted provided that the following conditions are met:
>
> 1. Redistributions of source code must retain the above copyright notice, this
>    list of conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright notice, this
>    list of conditions and the following disclaimer in the documentation and/or
>    other materials provided with the distribution.
> 3. The name of the author may not be used to endorse or promote products derived
>    from this software without specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
> WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
> MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
> SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
> EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
> OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
> INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
> STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
> OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
> DAMAGE.

The no-endorsement clause is noted and observed: neither Jeffrey Lim's name nor
Impulse Tracker's is used to endorse or promote tempura.

> **Unpinned, 2026-09-21.** The holder and the year are the plan sets' ("Jeffrey
> Lim, 2014", `docs/plans/09-conformance.md` and the it set's 01 and 09); the clause
> wording above is the standard three-clause text with the older "name of the
> author" phrasing the it set describes. `LICENSE.TXT` itself could not be read on
> this machine. Replace this block with upstream's verbatim text on the first tag
> cut from a machine that has the checkout.

---

## Schism Tracker — GPL-2.0-or-later — doctrine only, nothing ported

No line of Schism Tracker is in this repository, and none may be. It is read to
settle a behaviour question when ITTECH and OpenMPT disagree or are silent, and each
consultation is a comment in the source. The rules cited so far:

| Rule | Where it is cited |
| --- | --- |
| A note fade is written as the on-disk byte 246 (ITTECH gives all of 120–253 to the fade; Schism picks 246) | `src/itf/pattern.zig`, `src/itf/Module.zig` |
| Old Schism set the edit-history `Special` bit and wrote no block, so a flagged block that would overlap the first region anyone points at is read as absent | `src/itf/regions.zig`, `src/itf/read.zig` |
| `MAX_SAMPLES` as the practical sample-count bound a reader should accept (236) | `src/itf/read.zig` |

Schism's `fmt/it.c`, `player/*.c` and `fmt/mid.c` are the files read. Behaviour
claims cite `file:line`; nothing is copied, adapted or translated.

---

## MMA RP-001 and the MIDI 1.0 Specification — cited, restated

The Standard MIDI Files 1.0 specification (MMA RP-001) and the MIDI 1.0
Specification are cited by document and section. Their byte tables are restated in
`docs/plans/05-smf-core.md` and implemented in `src/smf/`: the chunk framing, the
header's `format` / `ntrks` / `division`, the variable-length quantity's 1–4 groups
and `0x0FFF_FFFF` ceiling, the channel-message and meta-event tables, running
status, and the `FF 7F` sequencer-specific slot that `src/residue/smf.zig` uses with
the `7D` non-commercial manufacturer id. Nothing is reproduced wholesale; no part of
either specification's text ships in this repository.

---

## OpenMPT wiki IT test cases — no explicit licence

The purpose-built modules at `https://wiki.openmpt.org/Development:_Test_Cases/IT`
are **never vendored**. `conformance/fetch_wiki_cases.sh` downloads them only when
run explicitly and verifies a sha256 pin per file; the pins live in
`conformance/PINS.md`. Nothing downloaded is committed.

---

## pacer — CC0-1.0

Upstream: `~/Dev/pacer`, 0.2.0 at `63cd0ed`. CC0 waives every condition, so nothing
here is required; the provenance is recorded because a copy whose origin is unnamed
is a copy nobody can update.

| What | Where |
| --- | --- |
| `schema/pacer.sjon`, the score manifest, copied verbatim on 2026-09-20 | drift-gated by `tools/pacer_schema_drift.sh` against the sibling checkout |
| The diagnostic-coverage audit script, adapted to tempura's one `Code` enum | `tools/audit_diagnostic_coverage.sh` |
| The fuzz harness shape — a corpus on a plain invocation, Smith-generated inputs under the instrumented fuzzer, invariants that hold for arbitrary input | `src/fuzz.zig` |
| The conventions: allocator-in, arena-backed owned value out, `pub const Error`, diagnostics-with-spans instead of errors, the golden-corpus discipline | throughout; stated in `src/root.zig`'s header and `CLAUDE.md` |
| The npm package, as a dev-dependency of the wasm parity tests | `npm/tempura` |

---

## SJON — local

Upstream: `~/Dev/SJON`, 1.4.2 at `5c9a0a33`. A sibling **path dependency**, built
with `plugin-exec = false`; nothing is copied into this tree. tempura's documents,
its Binary IR essence (wire format v5) and its schema validation are all SJON's.

---

## Theatre.js — Apache-2.0 — cited, nothing ported

Read for its data model and cited in `docs/plans/00-vision-and-scope.md`'s ledger.
No code, no table and no asset was taken.

---

## midicsv / csvmidi — public domain (John Walker)

The `.mid` oracle. Installed from Homebrew at test time, pinned by version in
`conformance/PINS.md`, never vendored and never linked into tempura.

---

## tempura itself — CC0-1.0

`LICENSE` is the CC0 1.0 Universal dedication, pacer's, decided at E0. No
attribution is required to use anything in this repository — except for the ported
material above, which keeps the licence it came with.
