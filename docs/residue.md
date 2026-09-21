# The residue

What a `.mid` or a `.it` written by tempura carries **besides** the music, restated
for implementers of other readers. Everything here is a byte layout or a rule over
one; the source of truth is `src/residue/records.zig` (the envelope, the record
bodies, the four hashes), `src/residue/smf.zig` and `src/residue/it.zig` (the
carriers), and `src/residue/reconcile.zig` (what a reader does with what it found).
This document restates those headers; where the two disagree, the source is right
and this file is a bug.

The payload formats **freeze at E3**. The envelope's `ver` byte versions the
envelope, not the essence's own encoding.

## The idea in one line

The SJON document is the truth; a `.mid` or a `.it` is a subset of it; whatever the
file cannot say rides in the file's own metadata, so the file alone is the document,
and a DAW or a tracker opens the file as if nothing were there.

Three things ride:

1. **The essence** — the document's timeline tier (every root that is not part of
   the `midi/` or `it/` dump of the carrying file) as SJON **Binary IR**, printed
   and parsed in `full` mode so comments, blank lines and authored spellings
   survive. The carrying `(anchor …)` is replaced by a marker, `:file "self"`,
   because a file cannot name its own path, size or digest.
2. **Lane records**, one per *rendered* native lane: the lane's name, the native
   address it was rendered to, a SHA-256 over the events written there, and the
   easing hints of a rendered curve.
3. **The conductor record**: one SHA-256 over the file's whole timing context.

The essence is authoritative for everything the file cannot say. The records exist
so that a foreign edit is detected per lane and for the conductor, never per file.

## The envelope

Every payload, in either carrier, begins with the same eight bytes:

```
7D 74 65 6D  ver  kind  seq  total  <body>
```

| off | size | field |
| --- | --- | --- |
| 0 | 4 | `7D 't' 'e' 'm'` — the manufacturer id reserved for non-commercial use, then tempura's tag |
| 4 | 1 | `ver`, the envelope version. This build writes and reads `1` |
| 5 | 1 | `kind` |
| 6 | 1 | `seq`, counting from 0 |
| 7 | 1 | `total`, at least 1 |

`7D` is shared by every non-commercial project, which is why the three-byte tag
follows it. A payload under `7D` whose next three bytes are not `tem` belongs to
somebody else and is never touched.

`kind`:

| value | meaning |
| --- | --- |
| `01` | the essence |
| `02` | a lane record |
| `03` | the conductor record |
| `04` | **reserved** for midivia's easing-hint body. tempura never writes one and never consumes one |

Any other `kind` is nobody's that this build knows; a reader steps over it and
leaves it in the file.

`seq` / `total` number the parts of one body split across several payloads. A
record is always `seq = 0`, `total = 1`; only the essence is ever split. `total` is
a `u8`, so a body rides in at most 255 parts.

**A split body is all or none.** A missing part, a part whose `total` disagrees with
the others, or a repeated `seq` means the whole body is discarded and the reader
takes the no-residue path with `residue_corrupt`. Half an essence is not a shorter
essence; it is Binary IR that would decode as garbage.

## The SMF carrier

One sequencer-specific meta event per payload:

```
FF 7F <len VLQ> 7D 74 65 6D ver kind seq total <body>
```

RP-001 reserves `FF 7F` for exactly this and requires readers to skip what they do
not know. The meta event's own length delimits the body, so the envelope carries no
length of its own.

**Placement.** The essence's parts and the conductor record sit at tick 0 of track 0
— the conductor track, and in a format-0 file the only track — before any other
event at that tick. A lane record sits at tick 0 of the track its address names
(1-based, as the file counts tracks). A record naming a track the file has not got,
or an IT address in a `.mid`, rides on track 0; the address in the *body* is what a
reader acts on, and the placement is a courtesy to a DAW's track view. tempura's
canonical writer stable-sorts by tick, so first in the track's event list is first
in the file.

**Splitting.** A meta event's VLQ admits `0x0FFF_FFFF` bytes, but sequencers cap one
far lower, so the writer bounds a single event's body (65535 by default) and cuts
the essence into `total` consecutive parts. An essence longer than `255 ×` that
bound is not written at all, and `residue_partial` says so.

**What a reader consumes.** The payloads never appear in a dump's `midi/` tier: a
dump takes them out and rebuilds the timeline tier from them. What stays in the
file, verbatim: a `7F` payload without the `7D 74 65 6D` tag, a `kind 04`, and any
payload whose `ver` is not the reader's — a newer tempura's essence is kept where it
is, unparsed, and reported as `residue_version`.

## The IT carriers

Two, graded by survival: a tracker's re-save keeps the message and drops the
trailing chunk.

### 1. The `TMPU` chunk

After all IT data — after the last sample's bytes, where OpenMPT and Schism put
their own extensions. IT and every player load by parapointers and never read past
the last region they are pointed at, so the bytes are invisible to them.

```
'T' 'M' 'P' 'U'   len u32 LE   <payload[len]>
```

The payload is a record list, end to end, in this order: the essence, every lane
record, the conductor record. Nothing is written for a payload that is not there.
Because a chunk supplies no per-record delimiter of its own, each record inside it
carries its length after the envelope:

```
7D 74 65 6D  ver  kind  seq  total  len u32 LE  <body[len]>
```

— the same eight bytes, then four more. A reader that does not know a `ver` or a
`kind` can still step over the record by its length, which is what the length is
for. A record is never split here: the chunk has room.

A chunk whose framing does not hold — a head that is not the magic, a length that
runs past the chunk, a trailing fragment — is `residue_corrupt`. A chunk that parses
but holds nothing readable counts as absent; a chunk holding only records of a
`ver` this build does not read is a newer tempura's, and is left alone with
`residue_version`.

### 2. The message tail

Inside the song message (`MsgLgth` u16 at header `0x36`, `MsgOffset` u32 at
`0x38`). The message is a first-class field, so every tracker keeps it.

After the human message — separated from it by IT's own newline, a single CR, unless
the message already ends in one — comes the line

```
;; tempura
```

then the **addressed summary** as SJON text, one form per line, CR-terminated. The
marker counts only at the start of a line, so a song text that mentions
`;; tempura` in a sentence is still all human, and the separating CR is what keeps
the marker at a line start. A message with no human text at all is the tail alone.

What the summary carries, in this order:

| form | what it says |
| --- | --- |
| `(timeline …)` | `:title`, `:length`, `:end loop`, `:conductor` — never dropped |
| `(anchor :id … :kind … :file "self")` | the carrying anchor as the marker, so every `:from` below names something — never dropped |
| `(section …)` | `:name`, `:at`, `:dur` |
| `(cue …)` | `:name`, `:at` |
| `(lane …)` | the DECLARATION only: `:name`, `:kind`, `:target` when it differs from the name, `:from <anchor>` with the binding address, `:range`, and the `:query` / `:expr` source text, which is a declaration and not content |
| `(control …)` | every pass-through pacer control, verbatim but for its newlines |

No native content, no phrases, no records, no hashes. A dump from the tail alone
rebuilds the shape of the piece and nothing of what the file already holds.

**ASCII by construction.** OpenMPT transcodes the message (CP437 or Windows-1252 to
Unicode and back), so a byte outside printable ASCII would not survive a round trip
through a tracker. SJON has no escape for a non-ASCII byte, so the tail spells any
byte outside `0x20 … 0x7E` as `%XX`, upper-case hex — and `%` itself as `%25`, which
is what makes the spelling reversible. `%` is a legal SJON identifier character, so
a symbol survives the same treatment as a string. A name that needed the escape is
reported `it_message_encoding_lossy`.

**Newlines are CR**, IT's own. A reader turns CR (and CRLF) back into the LF a
parser reads, and undoes the `%XX` escaping, by the rule above: every `%` followed
by two hex digits in a tail is an escape and nothing else; a `%` that is not is kept
as it stands.

**4096 bytes.** What does not fit is dropped whole forms at a time — never half a
form — and `residue_tail_truncated` names how many sections, cues, lanes and
controls fell off. The `(timeline …)` and `(anchor …)` lines are written first and
are never dropped.

A `.it` written by tempura carries both carriers. A `.it` re-saved by a tracker
keeps the tail.

## The record bodies

Little-endian throughout, no padding, no alignment.

### `kind 02` — a lane record

| off | size | field |
| --- | --- | --- |
| 0 | 32 | `hash` — SHA-256 over the rendered events, below |
| 32 | 8 | `address` — the native address, below |
| 40 | 2 | `name_len` u16 |
| 42 | 2 | `segments` u16 — how many follow |
| 44 | `name_len` | the lane's name, UTF-8 |
| … | | `segments` × `{ at i64, ease_len u16, ease[ease_len] }` |

A segment is one rendered curve segment as a **hint**: `at` is the tick of the
keyframe that *ends* the segment, and `ease` is the `:ease` source text that shaped
it, verbatim. That is all a record keeps of a curve's shape; the values live in the
essence and in the file's own steps.

The body must be consumed exactly. A short read, a field out of its domain and a
trailing byte nobody reads are all `residue_corrupt`. A writer truncates a name or
an easing longer than a `u16` rather than refusing: the record is a hint beside a
hash.

### `kind 03` — the conductor record

The 32 hash bytes, and nothing else. A body of any other length is not a conductor
record.

### The address, 8 bytes

| off | size | smf (`tag 0`) | it (`tag 1`) |
| --- | --- | --- | --- |
| 0 | 1 | `0` | `1` |
| 1 | 2 | `track` u16, 1-based file order | `channel` u8 at +1, then a `0` |
| 3 | 1 | `ch`, 0-based | `column` (`FF` none, else `vol` 0 / `pan` 1 / `fx` 2) |
| 4 | 1 | `key` (`FF` none) | `fx` letter, ASCII, `0` none |
| 5 | 1 | `curve` (`FF` none, else `cc` 0 / `cc14` 1 / `bend` 2 / `pressure` 3 / `velocity` 4) | `0` |
| 6 | 1 | the `cc` number, or the MSB of a `cc14` pair | `0` |
| 7 | 1 | the LSB of a `cc14` pair | `0` |

Domains are checked on the way in: an SMF `ch` above 15, a `key` or a `cc` above
127, a `curve` tag above 4, an IT `channel` above 63 or a `column` tag above 2 all
mean the eight bytes are not tempura's and the record is corrupt. Bytes a variant
does not use are written as `0` and ignored on the way back, so the eight bytes do
not round-trip bit for bit — an address does.

## The hashes

SHA-256, over **events in tempura ticks** and never over bytes. That is the whole
point: a `write ∘ read` of the file cannot move a hash — running-status choices,
delta-time spellings and byte order are not in it — and neither can a `division`
rescale that keeps the music, because every position goes through the file's
division before it is hashed. A `division` change *under unchanged ticks* moves
every event on the grid, and the hash says so.

Two conversions, both exact integer arithmetic:

* **SMF**: `tick = round(smf_tick × 46 126 080 / ppq)`, ties to even, clamped to
  `±2^53`. `46 126 080` is tempura's ticks per quarter note (`docs/grid.md`); `ppq`
  is the file's division, or its SMPTE conversion `frames · subframes / 2`, or 96
  when the file states none (a zero division). The intermediate product is computed
  in 128 bits, so the clamp is on the result and never on an overflow.
* **IT**: `tick = it_tick × 1 921 920`, saturating at `i64`'s maximum rather than
  wrapping, so a walk that ran away is still hashable.

Each hash starts with an ASCII domain tag ending in `\n`, so two layouts can never
be fed the same bytes, and the tag carries the layout's own version. Integers are
little-endian; `bytes` are fed raw.

### `tmpu/lane/smf/1\n` — a rendered SMF lane

The tag, then

| order | bytes |
| --- | --- |
| 1 | `track` u16 (0-based index into the file's tracks) |
| 2 | `ch` u8 |

then, for every event of that track whose kind carries a channel and whose channel
is `ch`, in the track's own order (tick order, ties in file order):

| order | bytes |
| --- | --- |
| 1 | `kind` u8 — the `smf.Kind` ordinal |
| 2 | the tempura tick, i64 |
| 3 | `n` u8 — how many data bytes follow |
| 4 | `n` data bytes, in WIRE order |

The data bytes are the channel message's own: `key, vel` for a note on or off,
`key, val` for polyphonic pressure, `num, val` for a controller, `num` for a program
change, `val` for channel pressure, and **LSB then MSB** for a pitch bend, exactly
as the file spells it. A track index past the end of the file hashes the address and
no events — an empty lane, not an error.

### `tmpu/cond/smf/1\n` — the SMF conductor

The tag, then

| order | bytes |
| --- | --- |
| 1 | `format` u8 |
| 2 | the division's **class** u8: `0` pulses per quarter, `1` SMPTE |

The division's *value* is deliberately absent: it is a unit, and the ticks below are
already converted through it.

Then, for **every track in file order** and every event of that track in order whose
kind is `set_tempo`, `time_signature`, `marker` or `cue_point` (every track: a tempo
event on track 3 conducts):

| order | bytes |
| --- | --- |
| 1 | `kind` u8 |
| 2 | the tempura tick, i64 |
| 3 | `us` u32 for a tempo; `nn dd cc bb` for a meter; `len` u32 then the text for a marker or a cue point |

### `tmpu/lane/it/1\n` — a rendered IT lane

The tag, then the address, pinned:

| order | bytes |
| --- | --- |
| 1 | `channels.len` u32 |
| 2 | the channel bytes, in the order given |
| 3 | `patterns.len` u32 |
| 4 | the pattern numbers, u16 each, in the order given |

Then, for every row the walk **played**, in play order, whose pattern is in
`patterns`, and for each channel of `channels` in the order given, a non-empty cell
contributes:

| order | bytes |
| --- | --- |
| 1 | the tempura tick, i64 — the row's start tick times `1 921 920` |
| 2 | `channel` u8 |
| 3 | `note`, `ins`, `vol`, `fx`, `param` — one byte each |

A pattern played twice contributes twice, at its two ticks: the hash is over what
*sounds*, which is what a tracker edits. A row whose pattern is past the module's
pattern list, a row past the pattern's height, a pattern whose cell grid is short
and a channel above 63 all contribute nothing.

**The scope, stated precisely** (this is the open question plan 04 left for this
document). A lane record's address names one IT channel. The hash is computed with

* `channels` = that one channel, and
* `patterns` = **every pattern the timing walk played**, ascending and deduplicated
  — not the patterns the lane's clip structure happened to touch.

The walk is `itf.walk.derive` over the module as it reads now, with its default
options; `patterns` is built by scanning its row map in play order, keeping each
pattern number the first time it appears, then sorting ascending. Both the build
that writes the record and the dump that checks it derive the list the same way from
the same file, so a second implementation needs the walk and nothing else.

Two things this scope is **not**, because plan 04's open question left both open:
it is not the set of patterns the lane's clip structure touched — a lane whose
clips cover one pattern still hashes every pattern the walk played — and it carries
**no order entries**. The order list is in the *conductor* hash, where a change to
it belongs: reordering a song is conducting, not editing a lane.

The
`note`/`ins`/`vol`/`fx`/`param` bytes are tempura's cell values, which are ITTECH's
on-disk values with the note sentinels normalised (on-disk `254` cut, `255` off,
`120 … 253` all fade) and a command byte above 26 read as no effect with a zero
parameter.

### `tmpu/cond/it/1\n` — the IT conductor

The tag, then

| order | bytes |
| --- | --- |
| 1 | the **effective** initial speed u8 — the loader's value, so a zero in the file hashes as IT's 6 |
| 2 | the **effective** initial tempo u8 — a value under 31 hashes as IT's 31 |
| 3 | `highlight_minor` u8 |
| 4 | `highlight_major` u8 |
| 5 | `n` u32 — the order list's length with its trailing `FF` end markers removed |
| 6 | `n` order bytes |

Then every `Axx` and `Txx` cell of every pattern, in pattern, row, channel order:

| order | bytes |
| --- | --- |
| 1 | `pattern` u16 |
| 2 | `row` u16 |
| 3 | `channel` u8 |
| 4 | `fx` u8 — ITTECH's command number, `letter - '@'`, so `A` is 1 and `T` is 20 |
| 5 | `param` u8 |

Positions are **pattern coordinates** here and not ticks, because these cells are
what the tick grid is derived *from*. Trimming the end markers is the canonical
writer's normalisation, so a re-save cannot move the hash.

## Reconciliation: the five rules

What a reader does after the format core has read the file and built the `midi/` or
`it/` tier. The rules are applied in this order.

1. **No residue.** Derive a skeleton timeline tier: one bound `notes` lane per used
   address, one bound `curve` lane per controller lane (SMF) or channel column (IT)
   with more than one value, cues from SMF markers and cue points (from IT order
   boundaries on request), and `:conductor` set to the anchor. No diagnostics; the
   document opens with `; skeleton: derived, no residue found`.

2. **Residue, version understood.** Restore the essence as the timeline tier, then
   ask the hashes whether the file and the residue were written together.

   *The conductor record first.* Hash the file's timing context as it reads now. On
   a **match** the document's own `tempo-point`s, `meter-point`s and `cue`s are
   restored and the file's tempo events are marked consumed: the document conducts,
   as it did when it was built. On a **mismatch** somebody edited the tempo, the
   meter or a marker in the DAW or tracker: the file wins, the document is restored
   *with* `:conductor` set to the anchor and *without* its own points and cues, and
   `residue_stale` names the losses — the authored `:qpm` spelling among them.

   *Then one lane record at a time.* Hash the file's events at the recorded address
   as they read now.
   * **Hash matches**: the native events are tempura's own rendering. The lane is
     restored as a native lane from the essence, and its address is **consumed** —
     the rendered events are *not* also imported as a bound lane.
   * **Hash differs**: somebody edited the rendered events. The native events win
     for what they can say: the lane becomes a **bound** lane at that address,
     keeping its name, target, range and, for a curve, the easing hints the file's
     own steps confirm — a hint the steps contradict is dropped with
     `ease_hint_mismatch`. The exact native content from the essence is discarded
     with `residue_stale`, which names the lane, the address and what it cost
     (values beyond 7 bits, clip structure, transposition).

3. **A version newer than the reader.** The payloads stay where they are, unparsed:
   plain `sequencer-specific` events in a `.mid`, the opaque `TMPU` region in a
   `.it`. The skeleton is derived with `residue_version`, and a later build keeps
   them and writes no residue of its own unless forced (`residue_newer_kept`) — so
   an older tempura never shadows a newer one's essence with a stale copy. Both the
   envelope's `ver` and the essence's own Binary IR wire version take this branch.

4. **Corrupt or truncated.** Bad Binary IR, a split body with a part missing, a hash
   field of the wrong length, a chunk whose framing does not hold: the skeleton is
   derived with `residue_corrupt` naming the payload. Records that arrived with no
   essence to restore are the same damage under another name and take the same
   branch — a build writes the essence first and the records beside it, so one
   without the other is a torn residue, never a small one.

5. **Both IT carriers.** The chunk wins when it is present and readable. The tail is
   used when the chunk is absent, corrupt, empty or of a version the reader does not
   know, with `residue_partial` naming what the tail lacks: it carries no native
   content and no records, so no hash check runs and every rendered lane stays
   bound.

The rule in one line: **the file's native content is the truth for what the file can
say; the residue is the truth for what it cannot; the hash says whether the two were
written together.** It is deterministic (same bytes ⇒ same document), explainable
(every loss is a named diagnostic), and it never lies (a stale essence is never
restored over edited music).

A dump reports which rule produced its timeline tier, and a document whose tier was
INFERRED rather than restored says so in its first line — four reasons, four lines:

| rule | the document's first line |
| --- | --- |
| 1, no residue | `; skeleton: derived, no residue found` |
| 3, a newer version | `; skeleton: derived, the residue is a newer version and was left in the file` |
| 4, corrupt | `; skeleton: derived, the residue would not decode` |
| 5, the tail alone | `; partial: the IT message tail alone — the shape of the piece, none of its content` |

Rule 2 writes no such line: the document that comes out is the document that went
in.

## Where the residue is silent

Three limits, stated so nobody has to find them.

* **The SMF conductor's division rule has a blind spot at the origin.** Tick 0 maps
  to tempura tick 0 under every division, so a conductor whose only timing events
  sit at tick 0 — one `set-tempo` and one `time-signature`, the common case —
  hashes the same after a `division` change under unchanged ticks. The division's
  *class* is in the hash, so pulses-per-quarter ⇄ SMPTE is still caught; a
  ppq → ppq change with nothing past tick 0 is not. Nothing in that file moved
  either, which is why the blind spot is tolerable rather than merely unavoidable.

* **An SMF lane hash is over the whole `(track, ch)` pair**, not over the narrower
  address the record may carry. Two lanes bound to one channel — one by `:key 36`,
  one by `:cc 74` — share a hash, so an edit to either moves both. That is
  deliberate: the record's question is "were these events written by tempura", and a
  DAW edits a channel, not a controller. It means a stale verdict can name a lane
  whose own bytes nobody touched.

* **An IT lane is one record per channel used.** The address names a channel, not a
  pattern range, and the hash spans every pattern the walk played. Two lanes
  rendered onto one IT channel share a hash for the same reason, and a change
  anywhere the walk goes moves it.

Beyond the hashes: a carrier's **survival** through a foreign tool is measured, never
promised. The `TMPU` chunk is not expected to survive a tracker's re-save; the
message tail is. `conformance/CHECKLIST.md` holds the table this is recorded in.
