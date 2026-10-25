# Manual gate evidence — 2026-10-25

Commands ran in `/Users/hugo/Dev/tempura` on macOS 26.12.0 (arm64), Zig 0.16.0.
Files were built by the native CLI from the pinned source:

```sh
zig-out/bin/tempura build corpus/render-it/doc.sjon --kind it -o gate/gate.it
zig-out/bin/tempura build corpus/render-smf/doc.sjon --kind mid -o gate/gate.mid
```

`artifacts.sha256` holds the hashes of the built files. The rendered PCM
(`gate.wav`, `schism-render.wav`) and the frames/CSVs are reproducible from the
commands below; the wav files were removed after hashing to keep the repository
small. Their hashes are in `artifacts.sha256`.

## A — load and play

- libopenmpt 0.8.9: `openmpt123 --probe`, `--info --message`, and
  `--batch -o gate.wav` all exit 0. `--info` reports `it (Impulse Tracker
  2.14)`, `Duration 00:06.559`, 5 channels, and the `;; tempura` message tail.
  Logs: `openmpt-probe.log`, `openmpt-info.log`, `openmpt-play.log`.
- Schism Tracker 20260524 (upstream macOS build, downloaded; not installed):
  `--headless --play --audio-driver=dummy --diskwrite=schism-render.wav` exits 0
  and writes a 1,157,290-byte WAV. Log: `schism-play.log`. The headless run has
  no UI, so the message tail was not observed there; libopenmpt covers it.
- OpenMPT GUI, Impulse Tracker 2.14/DOSBox: **not run** (no GUI or DOSBox on the
  machine). No re-save was performed by any player, so the survival columns stay
  UNMEASURED.

## D — invisibility

- `.it`: `openmpt123 --info` on `gate.it` and `gate-nores.it`; the `Type`,
  `Title`, `Duration` and `Channels` lines are identical (`d-it-*-key.txt`).
- `.mid`: `midicsv` on `gate.mid` and `gate-nores.mid`; after removing every
  `Sequencer_specific` row from the residue-bearing CSV, the two files are
  identical (`d-mid-diff.txt`: 23 rows each).

## Residue before loading

`it-residue.log` and `mid-residue.log` are `check-residue` over the two built
files. Every payload reported there is present and hash-matching before the
players saw the file.
