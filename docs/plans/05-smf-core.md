# 05 — The SMF Core: Reader, Writer and the `midi/` Bridge

Status: Active — 2026-09-19. Part of the [tempura plan set](README.md). Owns **P100**
(`src/smf/`) and the SMF half of **P102** (`src/doc/bridge_smf.zig`). Copied and adapted from
the midi set's [03](../../../specs-llm/plans/midi/03-smf-format.md) and the bridge half of its
[02](../../../specs-llm/plans/midi/02-smf-schema.md); the design is midivia's, the
implementation lands here first. The canonical writer's layout **freezes at E1**.

A Standard MIDI File (SMF) is a sequence of chunks: one `MThd` header and one or more `MTrk`
tracks. Each track is a byte stream of `(delta-time, event)` pairs where delta-time is a
variable-length quantity (VLQ) in ticks and an event is a MIDI channel message, a system
exclusive message, or a meta event. The normative text is the MMA's *Standard MIDI Files 1.0*
(RP-001, 1996); the byte tables below restate what the reader and writer implement so that the
plan stands alone. OpenMPT's loader (`~/llm/repositories/openmpt/soundlib/Load_mid.cpp`,
BSD-3) is the reference implementation for the robustness rules (cited at the midi set's pin
`6ef84997`; not checked out on this machine on 2026-09-19); Schism's `fmt/mid.c` (GPL-2) is
read for cross-checking only.

## Chunks

```
MThd  length=6  format u16be  ntrks u16be  division u16be
MTrk  length    <delta event>*   ...ends with FF 2F 00 (end-of-track)
```

- `format`: 0 = one track holding everything; 1 = several tracks played together, the first
  conventionally carrying tempo and meter; 2 = independent sequences. All three are read and
  written; the timeline derivation accepts 0 and 1 and refuses 2 with `smf_format2` (a format
  2 file's tracks are not simultaneous).
- `ntrks` must match the `MTrk` count; a mismatch is a diagnostic with the header's span and
  the walk continues over the chunks present (SJON's collection over abort; OpenMPT refuses a
  file whose `MTrk` count falls short, `Load_mid.cpp:684`).
- `division`: bit 15 clear ⇒ bits 0–14 are pulses per quarter note (PPQ, 1..32767). Bit 15
  set ⇒ SMPTE: bits 8–14 hold the negative frame rate (−24, −25, −29 for 30 drop, −30) and
  bits 0–7 the ticks per frame. The reader converts SMPTE to an equivalent PPQ the way OpenMPT
  does (`Load_mid.cpp:661-669`: `frames · subframes / 2`, 96 as the fallback for a zero
  division) and records the conversion in the `SourceMap`; the writer never emits SMPTE
  division. OpenMPT calls that rule an approximation (`Load_mid.cpp:664`): it is exact only
  at 120 BPM, because SMPTE ticks are wall-clock and do not follow tempo. So the SMF conductor
  of a SMPTE file is one segment at 120 quarter notes per minute over the converted PPQ, which
  reproduces every tick's wall-clock time exactly, and the file's `set-tempo` events are kept
  in the dump but ignored for timing with `smpte_tempo_ignored` ([03](03-time-model.md)).
  On the way OUT — the canonical writer and the `midi/` dump, both of which put the file on
  its converted PPQ — every `set-tempo` is spelled as 500 000 µs, the tempo the conversion
  assumed (`Division.tempoOnGrid`, the one seam beside `pulsesPerQuarter`; 2026-09-21): a
  tempo copied verbatim onto that grid would conduct it, and a `build` of the dump would
  change the clock the reader had promised to keep. The `Sequence` value stays as read; the
  rewrite is the emitters', and the dump's `; smpte …` note counts the events it rewrote.
- Unknown chunk types are skipped by length and preserved in the `SourceMap` as foreign
  regions (RP-001 requires readers to skip them). `RIFF`-wrapped files (`.rmi`) are unwrapped
  when the outer chunk is `RIFF` / `RMID` (`Load_mid.cpp:587-613`).

## Delta times and running status

- A VLQ is 1..4 bytes, big-endian 7-bit groups, high bit set on every byte but the last; the
  maximum is `0x0FFFFFFF`. A fifth continuation byte is `vlq_too_long` at that byte's offset.
- Running status: a data byte (< 0x80) where a status byte is expected reuses the last channel
  status. System common and real-time bytes do not update running status; meta and sysex
  events cancel it in the file (RP-001 disallows running status across them; the reader
  tolerates it the way OpenMPT does, `Load_mid.cpp:867`, and records a warning).
- The `Sequence` stores **absolute** ticks per event (`i64`, the sum of deltas), so document
  authors never write deltas and the writer re-derives them. Absolute ticks are non-decreasing
  within a track by construction.

## Events

Channel messages (status high nibble, channel in the low nibble, data bytes 7-bit):

| Status | Event | Data | `Sequence` form |
|---|---|---|---|
| `8n` | note off | key, velocity | `note_off{ch,key,vel}` |
| `9n` | note on (velocity 0 is a note off on the wire; stored as-is, interpreted by the bridge's note pairing) | key, velocity | `note_on{ch,key,vel}` |
| `An` | polyphonic key pressure | key, pressure | `poly_pressure{ch,key,val}` |
| `Bn` | control change (0–119 controllers; 120–127 channel mode messages, stored the same way) | controller, value | `control_change{ch,num,val}` |
| `Cn` | program change | program | `program_change{ch,num}` |
| `Dn` | channel pressure | pressure | `channel_pressure{ch,val}` |
| `En` | pitch bend, 14-bit, LSB first, centre 8192 | lsb, msb | `pitch_bend{ch,value 0..16383}` |

System exclusive and escape:

| Status | Event | Layout |
|---|---|---|
| `F0` | sysex | `F0 <len VLQ> <bytes…>`; the bytes normally end with `F7`; a message may be split across several `F7` continuation events |
| `F7` | escape / continuation | `F7 <len VLQ> <bytes…>`; also used to embed arbitrary bytes in a file |

The payload is stored verbatim (including a trailing `F7` when present) so rung 1 of the
ladder holds without a rewriter.

Meta events, `FF <type> <len VLQ> <bytes>`:

| Type | Name (RP-001) | Payload | Notes |
|---|---|---|---|
| `00` | Sequence Number | u16be | at tick 0 |
| `01` | Text Event | text | encoding unspecified by the standard; stored as bytes, shown as UTF-8 when valid, `:bytes` hex otherwise |
| `02` | Copyright Notice | text | |
| `03` | Sequence/Track Name | text | a bound lane's default label |
| `04` | Instrument Name | text | |
| `05` | Lyric | text | |
| `06` | Marker | text | dumps to a `cue` ([04](04-residue.md), skeleton rule) |
| `07` | Cue Point | text | dumps to a `cue` |
| `08` | Program Name | text | RP-019 |
| `09` | Device Name | text | RP-019 |
| `20` | MIDI Channel Prefix | u8 | |
| `21` | MIDI Port | u8 | widespread, not in RP-001; read and written |
| `2F` | End of Track | none | required last event of every track; a missing one is `end_of_track_missing` and the writer always emits it |
| `51` | Set Tempo | u24be microseconds per quarter note | 0 is refused (`Load_mid.cpp:835-837`); the SMF conductor's `us_i` ([03](03-time-model.md)) |
| `54` | SMPTE Offset | hr mn se fr ff | stored, unused |
| `58` | Time Signature | nn dd cc bb | numerator, denominator as a power of two, clocks per click, 32nds per quarter; the SMF conductor's meter |
| `59` | Key Signature | sf mi | |
| `7F` | Sequencer Specific | bytes | stored verbatim; two payload families are parsed: tempura's residue records (`7D 'tem'`, [04](04-residue.md)) and midivia's easing hint (`7D 'pau'`, midi 03, read as an easing source for bound curve lanes) |
| other | unknown | bytes | stored as `meta{type, bytes}`, round-tripped verbatim |

Text lengths above the declared chunk length, a VLQ that runs past the track, a chunk length
past the end of the file: each is a diagnostic at the byte offset, and the reader keeps what
it parsed up to that point. Bytes **inside** a length-delimited payload (meta, sysex, escape)
are arbitrary and are never inspected for status bits: `FF 51 03 07 A1 20` is 120 BPM and its
`A1` has the high bit set. (midi 03 lists "a status byte in a meta payload" as a diagnostic;
that would refuse most tempo events and is recorded as a correction in
[11](11-demos-and-milestones.md).) The reader never panics on arbitrary input; `zig build
fuzz` holds that line.

## `Sequence`

```zig
pub const Sequence = struct {
    format: u8,                 // 0, 1, 2
    division: Division,         // .ppq(u15) | .smpte(fps, tpf) as read; ppq() gives the grid
    tracks: []Track,            // in file order
    foreign: []ForeignChunk,    // preserved unknown chunks (type + bytes)
};
pub const Track = struct { events: []Event };
pub const Event = struct { at: i64, kind: Kind, payload: Payload };  // absolute SMF ticks
```

`Kind` is an append-only enum mirroring the tables above, plus `ease_hint` and
`tempura_residue` (with the record kind of [04](04-residue.md)) for the parsed `7F`
payloads. Payload bytes live in one arena-backed byte
pool per `Sequence`; `Event` holds offsets, so an event is a fixed-size value and a track is a
flat slice. The layout is pinned with comptime asserts as pacer pins its blobs. `SourceMap`
records each chunk's offset and length, each event's byte offset, running-status reuse, SMPTE
conversion, and foreign regions; `tempura inspect` prints it.

## The canonical writer (freezes at E1)

- Header `format` and `division` as given; `ntrks` from the track count.
- Per track: events sorted by absolute tick with a **stable** sort (document order breaks
  ties); deltas re-derived. The residue's placement rule ([04](04-residue.md)) relies on this:
  an essence event authored first at tick 0 stays first.
- Running status **used** for consecutive channel messages of the same status on the same
  channel, reset after every meta or sysex event. Note-off is written as `8n`, never as `9n`
  with velocity 0, unless the `Sequence` says `note_on{vel 0}` (stored as read).
- Every track ends with exactly one `FF 2F 00`; a `Sequence` whose track lacks it gets one at
  the last event's tick; a mid-track end-of-track is `end_of_track_early` at build time.
- Meta text is written as the stored bytes; VLQ lengths are minimal.
- Options: `--no-running-status`, `--format 0` (merge tracks by tick, stable, tempo track
  first), `--ppq N` (rescale ticks with exact rational arithmetic; a tick that does not land
  is `ppq_rescale_inexact`, refusing rather than rounding unless `--round`).

With these rules `write(read(bytes)) == bytes` for any file the writer produced (rung 1), and
`read(write(read(bytes)))` equals `read(bytes)` event by event for any readable file (rung 2).

## The `midi/` bridge (`src/doc/bridge_smf.zig`)

`toSjon(Sequence, SourceMap, opts) → forms` emits one `(midi/smf :format :division)` root and
one `(midi/mtrk …)` per track, one form per event, exactly as midi 02 specifies (heads are
RP-001's names in kebab-case; `:ch` is 1..16 in text and 0..15 on the wire; `:at` is the
absolute SMF tick; byte payloads are hex strings, text payloads SJON strings when valid UTF-8).
`fromSjon` is the inverse and checks `at_not_monotone`, `end_of_track_missing`,
`end_of_track_early`, the 7-bit and 14-bit ranges and `set-tempo :us` 1..16 777 215. A
document may spell the tier bare when unambiguous or qualified always; the printer qualifies
(`midi/…`) inside an inline dump so a reader sees which tier a form belongs to.

**Note pairing for bound lanes.** A bound `notes` lane reads the `mtrk` at `:track` and pairs
`note-on` (velocity > 0) with the next `note-off` or `note-on` velocity 0 on the same channel
and key; a second `note-on` on a held key ends the first at that tick (retrigger, midi 04's
rule) and the pairing is recorded once as `note_retrigger` (a warning); a `note-off` with no
`note-on` is counted, never a diagnostic (DAWs export such files). A note with no off ends at
the track's end-of-track. The result is `Playhead.sounding`'s input and `export-score`'s onset
list; nothing is written back unless the lane is edited inline ([07](07-edit-engine.md)).

**Curve lanes.** A bound `curve` lane over `:cc N` reads control changes on `(track, ch,
num)`; `:cc [msb lsb]` pairs them with the MSB-only rule (midi 04); `:bend` reads pitch bend
over 0..16383 with centre 8192; `:pressure` channel pressure; `:velocity` the paired notes'
velocities at their onsets. Values are normalised to 0..1 (bend to −1..1) and scaled by
`:range` at export. Easing per segment is `hold` unless a midivia `ease-hint` or a tempura
lane record supplies one, verified against the steps ([08](08-export.md)).

## Phases (P100 + the SMF half of P102)

1. **Reader spike (RED first).** Load: nothing. Reds: a hand-built two-track fixture from an
   in-test byte writer parses to the expected `Sequence`; VLQ edge cases (`0x00`, `0x7F`,
   `0x81 0x00`, `0xFF 0xFF 0xFF 0x7F`, a five-byte value); running status across note-ons;
   note-on velocity 0 stored as `note_on`; `FF 51 03 07 A1 20` parses as 500 000 µs and a
   sysex with bytes ≥ `0x80` inside parses whole; SMPTE division converts to OpenMPT's PPQ
   and a SMPTE file's tempo events are recorded as ignored; an
   unknown chunk is skipped and recorded; a truncated track yields a diagnostic and the parsed
   prefix; `7D 'tem'` and `7D 'pau'` payloads parse typed and a Yamaha one stays bytes.
   Green: `smf/read.zig`, `smf/vlq.zig`, `smf/Sequence.zig`. Gate: `zig build test`.
2. **Writer + fixed point.** Reds: the canonical rules above, one test each; `write ∘ read`
   fixed point on every committed canonical fixture; event-exact round-trip on the foreign
   fixtures ([09](09-conformance.md)). Green: `smf/write.zig`. Gate: test + fuzz.
3. **The bridge.** Reds: midi 02's example dumps to the exact text (qualified); `fromSjon ∘
   toSjon` is the identity on `Sequence`; note pairing with retriggers and orphan offs; the
   14-bit pair with MSB only. Green: `doc/bridge_smf.zig`. Gate: test.
4. **`inspect`.** Reds: golden text of the annotated offset dump for the two-track fixture.
   Green: `cli/inspect.zig` (the SMF half). Gate: CLI goldens.

## Risks / open questions

- **Text encoding.** The standard says nothing; DAWs write Latin-1, UTF-8 or Shift-JIS.
  Storing bytes and rendering UTF-8 when valid is lossless; whether the dump should carry an
  `:encoding` hint is the midi set's open N1 decision and stays theirs; tempura follows.
- **Huge files.** A `Sequence` is whole-file. A 100 000-event export is a few megabytes and
  fine; streaming is a non-goal.
