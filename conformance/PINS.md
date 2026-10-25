# Pins — the test-time tools and the fetched assets

Nothing in this file is vendored. The oracles are installed from Homebrew at test
time and the wiki cases are downloaded by a script that verifies a hash; neither
ever enters a commit (`docs/plans/09-conformance.md`, "License discipline").

Pinning is by **version for a tool** and by **sha256 for a file**. A tool whose
version differs from the pin still runs — `conformance/conform.sh` reports the
version it found — but a differing version is a reason to re-read a toleranced
comparison before believing it. A file whose hash differs from the pin is refused.

## Tools

| Tool | Role | Pinned version | Present here? |
| --- | --- | --- | --- |
| `libopenmpt` / `openmpt123` | the `.it` oracle: `openmpt123 --info` reports duration, tempo and channel names | `0.8.9` (`openmpt123 v0.8.9, libopenmpt 0.8.9+r25652.pkg`) | yes, 2026-10-25 |
| `midicsv` / `csvmidi` | the `.mid` oracle: a file as one CSV row per event, and back | `1.1` (Homebrew formula) | yes, 2026-10-25 |
| Schism Tracker | the second tracker for the manual load/play gate | `20260524` (upstream macOS build, headless `--diskwrite`) | yes, 2026-10-25 |
| DOSBox | hosts Impulse Tracker 2.14 for the manual gate | **unpinned** | no |

On **2026-10-25** `libopenmpt`, `midicsv` and Schism were installed and exercised
for the 0.1.0 candidate; DOSBox and Impulse Tracker 2.14 were not. The
`midicsv` row's version is Homebrew's formula version because the tool prints no
version banner of its own (`midicsv -h` is an illegal option).

Install:

```sh
brew install libopenmpt     # openmpt123
brew install midicsv        # midicsv, csvmidi
brew install dosbox-x       # or dosbox
```

Then record the versions here, replacing **unpinned**, in the form the tool prints:

```sh
openmpt123 --version | head -1
midicsv -h 2>&1 | head -1
```

`libopenmpt` is **not** the `.mid` oracle: its `ReadMID` is compiled into tracker
and fuzzing builds only and returns false in the library
(`Load_mid.cpp:1416` at the plan set's pin). midicsv is.

## OpenMPT wiki IT test cases

Source page: `https://wiki.openmpt.org/Development:_Test_Cases/IT`. Each case is a
purpose-built `.it` that isolates one behaviour, with a documented pass/fail
description. They carry **no explicit licence**, so they are fetched by
`conformance/fetch_wiki_cases.sh` — which downloads only when run explicitly —
and never committed.

The timing subset is the one tempura's walk is judged against
(`docs/plans/09-conformance.md`, "the IT walk is a player's walk"). The cases the
plan set names by name are below; the rest of the timing subset is added as the walk
reaches each corner.

| Case | What it isolates | Download URL | sha256 |
| --- | --- | --- | --- |
| `PatternLoop` | `SBx` pattern loop, its start row and its interaction with `Cxx` | TODO | TODO |
| `PatternDelays` | `SEx` row delay and `S6x` frame delay | TODO | TODO |
| `TempoSlide` | `T0x` / `T1x` tempo slides across rows and orders | TODO | TODO |

**The URLs and the hashes are TODO on purpose.** The plan set names these three
cases but not the files' download URLs or their bytes, and the OpenMPT wiki is not
reachable from the authoring environment, so writing either would be inventing it.
To fill the table: open the page above, take each case's file link and its file
name, download once, and run

```sh
shasum -a 256 <file>
```

putting the URL and the digest in the row. `conformance/fetch_wiki_cases.sh` refuses
to download a row whose pin is still `TODO`, so an unfilled row is inert rather than
unsafe.

## Foreign fixtures

Personal, never committed (`docs/plans/09-conformance.md`, "Foreign fixtures are
personal"): one `.mid` export from each DAW the author uses, OpenMPT's `mod2midi` of
`impulse-04.it`, and wild `.it` modules of different provenance. They are realism
checks logged by hash and outcome in `conformance/CHECKLIST.md`, not inputs to any
automated gate.

| Fixture | Provenance | sha256 | Last read | Outcome |
| --- | --- | --- | --- | --- |
| — | — | — | — | UNMEASURED |
