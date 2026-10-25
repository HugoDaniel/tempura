# Conformance checklist — the manual gates

The gates no local oracle can assert. They gate **tags, not commits**
(`docs/plans/09-conformance.md`, "CI shape" and "Risks"): a run is recorded here
with the tool, its version, the date and the outcome, and an unrun gate stays
**UNMEASURED** rather than being assumed green.

Everything automatable is elsewhere and is not repeated here: `tools/zt verify`
(tests, the golden corpus native and wasm, generated-docs drift, the pacer-copy
drift), `tools/zt fuzz` (the never-panic harnesses of `src/fuzz.zig`) and the
oracle matrix `conformance/conform.sh` (libopenmpt and midicsv over the corpus
fixtures, skipping with a reason when a tool is absent).

**Status on 2026-09-21: every gate below is UNMEASURED.** No run has been recorded.
The authoring machine has none of the tools installed (`conformance/PINS.md`), and
no DAW, tracker or DOSBox session has been performed.

**Status on 2026-10-25 (0.1.0 candidate):** libopenmpt 0.8.9 and Schism Tracker
20260524 were installed and used for loads and playback of a built `.it`. No
re-save survival result, no Impulse Tracker 2.14/DOSBox run and no DAW import
exist, so section A is PARTIAL, section B is UNMEASURED and the residue survival
columns that need a re-save stay unmeasured. The commands and logs are under
`docs/plans/evidence/release-0.1.0/gate/`.

---

## A. A built `.it` loads and plays, with the residue attached

Run at E0 and at every tag, in each of three players.

### Procedure

1. Build a fixture with residue:
   `tools/zt run -- build corpus/render-it/doc.sjon --kind it -o /tmp/gate.it`
   (any native corpus document will do; prefer one with a tempo map, a section, a
   cue and at least one rendered lane, so every payload is present).
2. Confirm the residue is really there before loading it anywhere:
   `tools/zt run -- check-residue /tmp/gate.it` — it must report the essence, one
   record per rendered lane, the conductor record, and a message tail.
3. Load `/tmp/gate.it` in the player. Record: does it load without a warning, does
   the song text show the `;; tempura` tail, does it play, and is the tempo and
   pattern content what the document says.
4. Re-save from the player to a **new** file. Do not overwrite the original.
5. Re-read the saved file: `tools/zt run -- dump saved.it` and
   `tools/zt run -- check-residue saved.it`. Record which payloads survived.
6. Write the outcome into the survival table in section C and the load result here.

### Results

| Player | Version | Date | Loads | Tail visible | Plays as built | Outcome |
| --- | --- | --- | --- | --- | --- | --- |
| libopenmpt (`openmpt123`) | 0.8.9 | 2026-10-25 | yes, `--probe`/`--info` clean | yes, `;; tempura` tail in `--info --message` | yes, `--batch -o gate.wav` rendered 2,557,914 bytes | PARTIAL — load and play; no re-save |
| Schism Tracker | 20260524 | 2026-10-25 | yes, headless load (`--headless --play --diskwrite`) | not observed headless | yes, rendered 1,157,290-byte WAV | PARTIAL — load and play; no re-save |
| OpenMPT | — | — | — | — | — | UNMEASURED |
| Impulse Tracker 2.14 (DOSBox) | — | — | — | — | — | UNMEASURED |

For IT 2.14: run under DOSBox, mount the directory holding the file, load it in the
tracker, look at the song message screen for the tail, and play. Record the DOSBox
version beside IT's. The risk this gate exists for is stated in
`docs/plans/04-residue.md`: a strict loader that treats the trailing `TMPU` chunk as
corruption would force the essence into the message instead.

---

## B. A built `.mid` opens in each DAW

Run at E0 and at every tag, in each DAW the author uses.

### Procedure

1. Build a fixture with residue:
   `tools/zt run -- build corpus/render-smf/doc.sjon --kind mid -o /tmp/gate.mid`
2. `tools/zt run -- check-residue /tmp/gate.mid` — confirm the payloads.
3. Import into the DAW. Record: does it import without an error, are the tracks,
   the tempo map and the notes what the document says, and does the DAW complain
   about the `FF 7F` events (it must not — RP-001 tells every reader to skip them).
4. Export a **new** `.mid` from the DAW without editing anything.
5. `dump` and `check-residue` the export. Record which payloads survived.
6. Write the outcome into the survival table in section C.

### Results

| DAW | Version | Date | Imports | Music as built | Outcome |
| --- | --- | --- | --- | --- | --- |
| — | — | — | — | — | UNMEASURED |

The DAW list is the author's own and is filled in the first time this gate is run.
DAW exports are **personal fixtures**: they are realism checks logged by hash and
outcome, never committed (`docs/plans/09-conformance.md`, "The measured, not
gated").

---

## C. Residue survival — the measured, never gated

For each tool and version: load a file tempura wrote, re-save or re-export without
editing, re-read, and count the payloads that came back. This table is the log
`docs/plans/04-residue.md` calls "Survival is measured, never promised"; the dated
summary is copied into that document's progress log at each tag.

Count each payload class independently. `check-residue` reports them by name.

| Tool | Version | Date | Kind | Essence | Lane records | Conductor record | `TMPU` chunk | Message tail | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| libopenmpt (`openmpt123`) | 0.8.9 | 2026-10-25 | .it | n/a | n/a | n/a | — | — | n/a — the tool never writes a file |
| Schism Tracker | 20260524 | 2026-10-25 | .it | — | — | — | — | — | UNMEASURED — headless playback only, no re-save |
| OpenMPT | — | — | .it | — | — | — | — | — | UNMEASURED |
| Schism Tracker | — | — | .it | — | — | — | — | — | UNMEASURED |
| Impulse Tracker 2.14 | — | — | .it | — | — | — | — | — | UNMEASURED |
| libopenmpt (`openmpt123`) | — | — | .it | n/a | n/a | n/a | — | — | UNMEASURED |
| *(DAW 1)* | — | — | .mid | — | — | — | n/a | n/a | UNMEASURED |
| *(DAW 2)* | — | — | .mid | — | — | — | n/a | n/a | UNMEASURED |

Cell values: `kept`, `dropped`, `mangled` (present but no longer parsing),
`n/a` (the payload class does not exist for that kind or that tool never writes a
file), or `—` for unmeasured.

**What a "dropped" verdict means.** Nothing breaks. The design is total: a file
whose residue is gone takes reconciliation rule 1 and dumps as a derived skeleton
(`docs/residue.md`). What narrows is the promise — from "one file holds everything"
to "one file tempura wrote holds everything". The expectation stated in plan 04 is
that a foreign tracker re-save drops the `TMPU` chunk and keeps the message tail,
because the message is a first-class field and trailing bytes are not.

---

## D. Invisibility — the residue changes nothing a foreign reader sees

Automatable in part (`conformance/conform.sh` runs the libopenmpt half over the
corpus); the DAW half is manual and belongs to gate B.

### Procedure

1. Build the same document twice, once with the residue and once without it
   (`tools/zt run -- build … --no-residue`, or the `export` verb, which never
   attaches one).
2. `openmpt123 --info` both `.it` files. Duration, tempo and channel names must be
   equal; the durations within one IT tick.
3. For `.mid`: `midicsv` both files, strip the `7D 74 65 6D` sequencer-specific rows
   from the residue-bearing CSV, and diff. The remainder must be identical.

| Check | Date | Outcome |
| --- | --- | --- |
| `.it` with and without residue report the same duration, tempo and names | 2026-10-25 | PASS — `openmpt123 --info` key fields identical for `corpus/render-it` with residue and `export` without |
| `.mid` with and without residue hold the same events | 2026-10-25 | PASS — `midicsv` rows identical after stripping every `Sequencer_specific` row from the residue-bearing CSV |

---

## How to record a run

Edit the table in place: replace the `—` cells with the version, the date
(`YYYY-MM-DD`) and the outcome, and replace `UNMEASURED` with `PASS`, `FAIL` or
`PARTIAL`. A `FAIL` or a `PARTIAL` needs one line under the table saying what
happened, with the file it happened to. Never delete an old row: append a new one,
so the log reads as a history per tool and version.
