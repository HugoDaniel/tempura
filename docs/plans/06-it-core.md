# 06 — The IT Core: Timing Subset, Pass-Through and the Walk

Status: Active — 2026-09-19. Part of the [tempura plan set](README.md). Owns **P101**
(`src/itf/`) and the IT half of **P102** (`src/doc/bridge_it.zig`). Copied and adapted from
the it set's [03](../../../specs-llm/plans/it/03-binary-model.md) (the binary model),
[04](../../../specs-llm/plans/it/04-reader.md) (reader tables), [05](../../../specs-llm/plans/it/05-writer.md)
(canonical layout, pattern packing) and the timeline section of [06](../../../specs-llm/plans/it/06-player.md);
the design is batida's, the implementation of this subset lands here first. Every ITTECH and
OpenMPT citation below is the it set's, verified by that set on 2026-08-27; the clones are not
checked out on this machine (README). The canonical writer's layout **freezes at E1**.

## Scope line

tempura reads and writes the parts of an Impulse Tracker module that carry **time**: the
header's timing and option fields, the order list, every pattern's rows, the song message
(the residue's second carrier, [04](04-residue.md)), and the timing effects' semantics
through a walk of the order list — and the MIDI macro configuration, which a document spells
slot by slot (`(it/midi …)`) because a tracker's `Zxx` cells mean nothing without it. Everything
else is **opaque and sacred**: instrument bodies,
sample headers and sample data, the edit history and foreign chunks are
regions with an offset and a length, referenced by `(bin :at :len)` against the anchor (it 03),
copied verbatim by the writer, never decoded. No codec, no envelope semantics, no
fingerprint quirk matrix beyond what timing needs. batida owns the rest (it 04–07).

## The binary model (it 03, verbatim in spirit)

The document is a structural view over the `.it`; bulk bytes never leave the file. The
`(anchor :id :kind it :file :size :sha256)` form ([02](02-timeline-schema.md)) is it 03's
`(source …)`: every `(bin :at :len)` is meaningful only against that exact file, verified by
size and digest before any offset is honoured. Offsets and lengths print in hex (`:at 0x8728`,
SJON 1.2.0), the it set's 2026-08-25 decision. `Module` holds each opaque region as
`{offset, len}` plus its descriptor; the writer copies slices. The toolchain never mutates the
anchor: building onto the anchor path is `--in-place` only (read everything, write a temp,
rename).

| Region | tempura | it set |
|---|---|---|
| header 192 B | **materialised** fields (below); the rest preserved | materialised |
| orders | materialised: `(it/orders 0 1 2 skip 3 end)` | same |
| patterns | materialised as `(it/pattern N :rows R (row r (ev ch note :ins :vol :fx)))`; `--patterns=bin` keeps refs | same |
| song message | materialised as a string; the residue's tail is split off ([04](04-residue.md)) | materialised |
| instruments | **opaque**: `(it/instrument N :name "…" :raw (bin :at :len 554))` | materialised fields |
| sample headers and data | **opaque**: `(it/sample N :name "…" :raw (bin :at :len 80) (data :bits :enc (bin :at :len)))` with the data extent computed | header materialised, data a ref |
| MIDI config 4896 B | materialised as `(it/midi (macro sf0 "F0F000z") …)`, one `macro` per non-empty slot, omitted when the block is IT's default (until 2026-09-21 it was omitted ALWAYS, and a build zero-filled it — the final review's D5) | same |
| edit history | ref via `(it/edit-history (bin …))`, `--preserve-history` | same |
| foreign trailing chunks | `--preserve-foreign` → `(it/foreign :tag "STPM" (bin …))`; the `TMPU` chunk is tempura's own and never shown as foreign | same |

`:raw` is one key tempura adds to the hosted `it` manifest's `instrument` and `sample` forms
(an opaque-body spelling), filed to the it set as an ask at E0 ([11](11-demos-and-milestones.md)).
A document that spells a materialised instrument field (`:nna`, an envelope) is valid against
the hosted manifest and `it_field_not_materialized` at build until `--full` exists
([02](02-timeline-schema.md)).

## Header (192 bytes) — the fields tempura reads and writes

Offsets per ITTECH.TXT, restated by it 04:

| Off | Size | Field | tempura |
|---|---|---|---|
| 0x00 | 4 | `"IMPM"` | reject otherwise |
| 0x04 | 26 | song name | `:title` |
| 0x1E | 2 | highlight minor / major | `(it/timing :highlight [minor major])`; the IT conductor's default meter ([03](03-time-model.md)) |
| 0x20–0x26 | 2×4 | OrdNum, InsNum, SmpNum, PatNum | counts; validated against spec maxima with diagnostics |
| 0x28 | 2 | Cwt/v | recorded; policy below |
| 0x2A | 2 | Cmwt | recorded; `< 0x200` marks old-format instruments (opaque either way) |
| 0x2C | 2 | Flags | `(it/options …)` 1:1 (stereo, vol0-opt, instrument mode, linear slides, old effects, compat Gxx, MIDI pitch ctl, embedded MIDI cfg) |
| 0x2E | 2 | Special | b0 message, b1 edit history, b2 highlight valid, b3 MIDI cfg; the it set's guard for a flagged-but-absent history block is ported (`Load_it.cpp:642-690`) |
| 0x30–0x35 | 6 | GV, MV, IS, IT, Sep, PWD | `IS` = initial speed (default 6 if 0), `IT` = initial tempo (floor 31, `Load_it.cpp:557`): the walk's initial state; the others `(it/options …)` |
| 0x36 / 0x38 | 2 / 4 | MsgLgth, MsgOffset | the message; CR newlines, NUL-terminated, LF autodetected (`Load_it.cpp:750-753`) |
| 0x3C | 4 | reserved | preserved as `:reserved N` when non-zero |
| 0x40 / 0x80 | 64 / 64 | channel pan / vol | `(it/channels (ch N :pan :vol :muted :surround))`; 0xFF = unused slot |
| 0xC0 | OrdNum | orders | 254 skip, 255 end |
| then | 4 × counts | parapointers | region map; `minPtr` for the history guard |

The reader is bounded everywhere; a malformed file yields diagnostics plus a best-effort
`Module`, never a crash (`zig build fuzz`).

## Patterns

Per pattern: `u16 packed_len`, `u16 rows` (32–200 strict; 1–1024 accepted with a diagnostic),
4 pad bytes, the packed stream; parapointer 0 is an empty 64-row pattern (synthesised, never
sought). Unpacking is ITTECH's algorithm as it 04 restates it (mask byte per channel with
`0x80` marking a new mask, per-channel caches for note / instrument / volume-pan / command +
param, `0x00` ending a row); command bytes 27–31 read as no effect with a diagnostic; the
volume-column byte table (0–64 vol, 65–124 the slide families, 128–192 pan, 193–202 tone
porta, 203–212 vibrato) decodes to `:vol` numbers or codes. Packing is it 05's two-cache scheme
(`Load_it.cpp:1755-1977`), `packed_len` back-patched, the 64 KB ceiling a diagnostic naming
the rows to split. `unpack(pack(rows)) == rows` and `pack` re-packs identically are property
tests.

The cell spelling is batida's: `(ev 3 "C-5" :ins 2 :vol 64 :fx "SD1")`, note strings
`"C-0"…"B-9"` or `off` / `cut` / `fade`, `:vol` 0–64 or a code, `:fx` a letter plus two hex
digits (it 02).

## Sample data extents (for pass-through only)

The writer must know where each opaque region ends, and the extent is dispatched on the
sample's encoding, never assumed from the compression flag alone. Plain PCM (`Flg` b3 clear,
`Cvt` not `0xFF`): `Length × bytes-per-frame × channels` (split stereo: left block then right).
ModPlug ADPCM (`Cvt == 0xFF`, 8-bit only, it 04's "trivially decodable" hack): `16 + ⌈Length
/ 2⌉` bytes per channel, the 16-byte nibble table then the packed nibbles (the layout the
pinned `SampleIO.cpp` reads; not checked out here, re-verified at E0). Compressed (`Flg` b3):
walk the block headers (`u16 compressed_size` + payload) per channel until the frame count is
satisfied (it 04's rule); truncation is recorded, not fatal, and the truncated length is what
the ref keeps. Nothing is decoded; the `:bits` and `:enc` on `(data …)` are copied from the
flags so the document reads truthfully.

## The canonical writer (it 05, freezes at E1)

```
0x0000  header (192 B)
0x00C0  orders (trimmed + exactly one trailing 255, min length 2)
        parapointers: instruments ×4, samples ×4, patterns ×4  (back-patched)
        [edit history: only when preserving]
        [MIDI config: only when non-default or the flags require it]
        [message: CR newlines, NUL-terminated; the residue tail last]
        instruments: 554 B each, copied from :raw
        sample headers: 80 B each, copied from :raw with SamplePointer back-patched
        patterns: 8 B header + packed data each; empty → parapointer 0
        sample data: in sample-index order, copied
        [foreign chunks, verbatim, in original order]
        [TMPU chunk: 'TMPU' u32 len payload]                 ← the residue (04)
```

Header policy: a module read from an anchor keeps its `Cwt/v`, `Cmwt` and `reserved` (tempura
changed only what the document changed); a module tempura authored from a native timeline
writes `Cwt/v = 0xB800 | version` (the it set claims nibble `0xB`, unclaimed in OpenMPT's
table, for batida with `0xB000 | version`; tempura takes the upper half of that nibble's
range, filed to the it set at E0) and `Cmwt = 0x0214`. Strict clamps are it 05's (64
channels, 200 patterns, rows 32–200 with a `C00` break for shorter, 99 instruments and
samples, tempo 32–255, speed 1–255), `--loose` lifts them to OpenMPT's itEx bounds.
Same document, same bytes, every platform (09).

## The message and its encoding

IT text is CP437; documents are UTF-8. The reader transcodes CP437 → UTF-8 and the writer the
reverse with lossy-mapping diagnostics (the it set takes OpenMPT's `CharsetTableCP437`, BSD).
The residue tail ([04](04-residue.md)) is ASCII by construction, so it survives both
directions and OpenMPT's own Windows-1252 assumption for ModPlug-saved files.

## The timing walk (`itf/walk.zig`)

it 06's `Timeline.derive` with the audio chain off: the order walk with every timing-affecting
effect, over `Module` and nothing else, all integers. Output, the `RowMap`: for every played
`(order, row)` its start in IT ticks and its tick count; the tempo in force at every tick
(one segment per change, so a `T0x`/`T1x` slide yields a segment per tick); the note onsets
per channel with their cells; the total tick count; the loop point. [03](03-time-model.md)
turns IT ticks into tempura ticks (`× 1 921 920`) and tempo into `qpm`.

State: `speed` (ticks per row), `tempo`, `tick_count`, `row_count` (pattern-delay counter),
`frame_delay` (`S6x`), `process_row`, `process_order`, `break_row`, per-channel pattern-loop
state, and the per-channel **effect memories** the timing effects recall: `mem_tempo` (`T00`
recalls the last `Txx` on that channel) and `mem_special` (`S00` recalls the last `Sxx`,
it 06's table). Per tick, Schism's `csf_process_tick` shape as it 06 restates it
(`sndmix.c:949`, doctrine only):

1. `--tick_count > 0` → a non-row tick: apply `T0x` (tempo down by x) / `T1x` (tempo up by
   x) slides, clamped 32–255.
2. else reload `tick_count = speed + frame_delay`, clear `frame_delay`; `--row_count > 0` →
   the row repeats (`SEx` row delay: row effects are **not** reprocessed); else advance
   `process_row`, and at end of pattern walk the order list: `254` skipped, `255` (or the end)
   → the song ends and loops (the loop point); honour a pending `Bxx` (jump to order,
   handled inline) and `Cxx` (break to row, deferred; loses to a pending `SBx` on the same
   row). Read the row's cells; process the tick-0 effects that touch time: `Axx` sets speed
   (0 keeps it), `Txx ≥ 0x20` sets tempo, `S6x` adds frame delay, `SEx` sets `row_count`
   (leftmost channel wins), `SBx` (`SB0` marks, `SBx` loops x times from the mark; a loop
   in progress wins over `Cxx`), `SDx` note delay (the onset lands at row start + `x` ticks,
   the cell's note sounding late, the IT bug it 06 keeps; `SD0` behaves as `SD1`, and a delay
   of `x ≥` the row's tick count suppresses the onset altogether, the note never sounding on
   that row, both per OpenMPT's IT handling as the second review cites `Snd_fx.cpp`, not
   checked out here and re-verified at E1). `T00` and `S00` read their memories before any of
   the above applies.
3. Record the row's start tick and the onsets.

Termination: the walk ends at the first `(order, row)` revisited with an identical timing
state (speed, tempo, loop counters, effect memories), which is the loop point; a `Bxx` backwards with a
changed state continues until the state repeats or a cap of 2^20 rows trips `walk_runaway`.
`--loops N` and `--max-rows` bound it for the CLI.

Beats accumulate as `ticks / 24` (IT's BPM is defined over 24 ticks per beat, it 06); a
`qpm` segment is the tempo value; a speed change moves rows, not beats.

## Bound lanes over a module (`src/doc/bridge_it.zig`)

A `notes` lane with `:from song :channel c` derives notes from channel `c`'s cells along the
`RowMap`: a cell with a note 0..119 starts a note at the row's start tick (plus `SDx`
ticks); it ends at the next cell on the channel that carries a note, `off`, `cut` or `fade`,
or at the walk's end. Velocity is `round(vol × 127 / 64)` (floor 1) when the volume column
sets a volume, else 127, a stated convention (instrument default volumes are opaque). `:key`
is the IT note number (C-5 = 60, the same number as MIDI's C4, so `"C4"` and `"C-5"` name one
key). A `curve` lane reads one column: `:column vol` the set-volume values (0..64 → 0..1),
`:column pan` the `pXX` codes and `Xxx` effects (0..64 → 0..1, `Xxx` 0..255 → 0..1), `:column
fx :fx "Z"` the parameter byte of every `Z` command (0..255 → 0..1), each at its row's tick,
`hold` between rows.

Orders are the arrangement: a dump with `--cues` emits one `(cue :name "order N — pattern P"
:at …)` per played order (it 09's anchor idiom). The walk's `orderRowAt(tick)` is what the
studio shows as the tracker position ([03](03-time-model.md)).

## Phases (P101 + the IT half of P102)

1. **Header, orders, parapointers, regions (RED first).** Load: nothing (the tables above).
   Reds: a hand-built minimal module from an in-test writer parses; the history-block guard;
   the MIDI config detection; message CR/LF; every region's extent including a compressed
   sample's block walk, a truncated one, and a 16-frame ADPCM sample spanning 24 bytes;
   parapointer 0 patterns; fuzz never panics.
   Green: `itf/read.zig`, `itf/regions.zig`, `itf/Module.zig`. Gate: test + fuzz.
2. **Patterns.** Reds: unpack of hand-packed rows including mask reuse and command bytes
   27–31; pack round-trip property; the 64 KB diagnostic. Green: `itf/pattern.zig`. Gate: test.
3. **Writer + pass-through.** Reds: the canonical layout byte by byte on the minimal module;
   `build(dump(f))` byte-equal on the T0 wild modules (it 10's gate); pass-through regions
   byte-equal; the `TMPU` chunk last; message tail placement; `--in-place` refusal. Green:
   `itf/write.zig`. Gate: test + the byte-equality gate.
4. **The walk.** Reds: hand-computed row maps for: constant speed and tempo; `Axx` mid-song;
   `Txx` set and `T00` recalling it on the same channel only; `T0x` slide (one segment per
   tick); `S6x` and `S00` recalling it; `SEx` (effects not reprocessed); `Bxx` forward and
   backward; `Cxx` and `SBx` on one row (loop wins); `SDx` onsets including `SD0` as `SD1`
   and `x ≥ speed` suppressing the note; `+++` and `---`; the loop point with memories in
   the state; `walk_runaway`. Green: `itf/walk.zig`. Gate: test + corpus.
5. **The bridge.** Reds: it 02's example dumps to itself (qualified `it/`); opaque records
   with `:raw`; bound notes with `SDx`, `off`, `cut`; curve columns; `--cues`. Green:
   `doc/bridge_it.zig`. Gate: test + corpus.

## Risks / open questions

- **Old-format instruments and rare encodings** (Cmwt < 0x200, ADPCM `Cvt == 0xFF`, TX-Wave)
  are opaque here and pass through untouched; the only thing tempura needs from them is a
  correct extent, which the header count and the 554-byte record give. A compressed sample
  whose block walk disagrees with its header is recorded and passed through at the walked
  length, the it set's rule.
- **Which effects are "timing"** is a closed list above. `Q` retrig and `SCx` note cut change
  what sounds, not when rows start; they are not walked. If a wild module's row map depends
  on an effect outside the list, the list grows with a corpus case.
- **Shared patterns.** One pattern played twice yields two clips of one content in the
  timeline's view; a bound lane's derived notes appear twice with different ticks, correctly.
  Editing one occurrence edits both ([07](07-edit-engine.md)'s `edit_pattern_shared`).
- **Velocity from the volume column** is a convention, not IT semantics (the effective volume
  involves instrument and sample volumes tempura does not read). It is what a pacer trigger
  lane's sibling velocity track receives, documented as such in the generated docs.
