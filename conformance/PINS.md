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
| `libopenmpt` / `openmpt123` | the `.it` oracle: `openmpt123 --info` reports duration, tempo and channel names | **unpinned** | no |
| `midicsv` / `csvmidi` | the `.mid` oracle: a file as one CSV row per event, and back | **unpinned** | no |
| DOSBox | hosts Impulse Tracker 2.14 for the manual gate | **unpinned** | no |

**None of the three is installed on the authoring machine on 2026-09-21** (checked
with `command -v`), so every version above is **unpinned**: writing one would be
writing a number nobody read.

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
