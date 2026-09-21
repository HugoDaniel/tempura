# E0 — the carriers

E0 asked three questions it could only answer by measuring: are the
residue carriers invisible to the players that matter, does a DAW keep a
sequencer-specific event through a re-export, and does a real piece have
a timeline tier worth carrying.

**None of the three is measured. All three are recorded here as
UNMEASURED with the procedure kept.** The reason is the machine, not the
design: no `openmpt123`, no `midicsv`, no OpenMPT, no Schism, no DOSBox,
no DAW, and the impulsos piece is not on this disk. Nothing was assumed
green and nothing was guessed. `conformance/PINS.md` records what is
absent and at which version it would be pinned.

What IS measured is everything a machine with no tools can measure: the
two carriers are written and read back by tempura itself over 78 corpus
cases (`tools/zt corpus`), the never-panic harnesses run both readers and
both residue unpackers over arbitrary bytes (`tools/zt fuzz`), and the
oracle matrix runs and says what it could not run (`tools/zt conform`).

```
$ tools/zt conform
conform: it/libopenmpt — skipped: openmpt123 not installed
conform: smf/midicsv — skipped: midicsv not installed
conform: it/wiki-cases — skipped: nothing fetched (conformance/fetch_wiki_cases.sh)
```

The procedure for every gate below is `conformance/CHECKLIST.md`, which
is the file to edit when a run happens. The tables here are that file's
summary at the shape plan 04 asks for; the log of record is the
checklist, and the dated summary is copied into
`docs/plans/04-residue.md`'s progress log at each tag.

## Table 1 — the `.it` carriers through three trackers

Plan 11 E0 step 3, first half: take three wild `.it` modules, append a
`TMPU` chunk and a message tail by hand, load each in libopenmpt,
OpenMPT, Schism and IT 2.14 under DOSBox, and record whether it loads,
whether the duration is unchanged, whether the message is shown, and
whether a re-save keeps the tail and drops the chunk.

| Player | Version | Date | Loads | Duration unchanged | Message shown | Re-save keeps tail | Re-save keeps chunk | Outcome |
|---|---|---|---|---|---|---|---|---|
| libopenmpt (`openmpt123`) | — | — | — | — | n/a | n/a | n/a | UNMEASURED |
| OpenMPT | — | — | — | — | — | — | — | UNMEASURED |
| Schism Tracker | — | — | — | — | — | — | — | UNMEASURED |
| Impulse Tracker 2.14 (DOSBox) | — | — | — | — | — | — | — | UNMEASURED |

Procedure: `conformance/CHECKLIST.md` sections A (loads and plays), C
(survival per payload) and D (invisibility). The three wild modules are
not committed and never will be — foreign fixtures are personal (plan
09). A file built from a shipped example does the same job:

```
zig-out/bin/tempura build examples/tracker/piece.sjon --kind it -o /tmp/gate.it
zig-out/bin/tempura check-residue /tmp/gate.it
```

The expectation plan 04 states, still unmeasured: a foreign tracker
re-save keeps the message tail, because the message is a first-class
field, and drops the `TMPU` chunk, because trailing bytes are not. If a
loader instead treats the trailing chunk as corruption, the fallback is
the essence inside the message, which plan 04 records and does not design
further.

## Table 2 — the SMF carrier through each DAW

Plan 11 E0 step 3, second half: take one export from each DAW the author
uses, insert a `7D 'tem'` sequencer-specific event at tick 0 of track 0,
reopen it in the DAW, re-export, and record what survives.

| DAW | Version | Date | Opens | Event kept | Length capped | Reordered | Outcome |
|---|---|---|---|---|---|---|---|
| *(DAW 1)* | — | — | — | — | — | — | UNMEASURED |
| *(DAW 2)* | — | — | — | — | — | — | UNMEASURED |

Procedure: `conformance/CHECKLIST.md` sections B and C. The risk this
table exists for is in plan 04: a sequencer that drops or reorders
sequencer-specific events, or caps their length, narrows the promise from
"one file holds everything" to "one file tempura wrote holds
everything". Nothing breaks either way — a file whose residue is gone
takes reconciliation rule 1 and dumps as a derived skeleton, which
`demos/e1-two-files-one-document/` shows working.

The essence is already split across as many events as it needs
(`docs/residue.md`, the `seq`/`total` fields), so a per-event length cap
is survivable by construction. Whether any DAW imposes one is what this
table is for.

## The impulsos measure

Plan 11 E0 step 5 asks for the piece at `~/Dev/2026_impulse` — its
`live.score.sjon` and its WGSL `const B_*` knobs — to be read and every
beat-level fact classified as (a) structure a `section` or `cue` carries,
(b) an event or a step a bound lane carries, or (c) a curve or a formula
only pacer's tier says. The three counts were to decide whether the
ladder stands or E1–E2 ship as the two format cores plus the exporter.

**UNMEASURED: the piece is not on this machine.** No count was
estimated and no conclusion was drawn from it. The ladder was built out
anyway, on the strength of the design rather than of the census, which is
the honest statement of what happened.

The knob census — 48 `const B_*` knobs on 2026-08-28 per midi 10 — is
**UNMEASURED here** for the same reason. The number is quoted from the
midi set's own note, not counted in this repo.

If the piece becomes available, the measure is three `grep` passes and a
table, and it belongs in this file with its date.

## What E0 did close

| E0 item | Status |
|---|---|
| repo from pacer's build graph, `verify` green on zero features | done |
| SMF reader spike, IT header/orders/patterns spike, the grid table | done, and superseded by the full cores |
| the carrier check (tables 1 and 2) | UNMEASURED |
| the walk spike, `export-score` of `impulse-04.it` into the studio | UNMEASURED — no piece, and pstudio is not a host |
| the measure (impulsos) | UNMEASURED |
| name, license, milestone letter | done: tempura, CC0-1.0, E |
