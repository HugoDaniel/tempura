# 04 — The Residue: a Timeline Inside a `.mid` or a `.it`

Status: Draft — 2026-09-19. Part of the [tempura plan set](README.md). Owns **P104**
(`src/residue/`). The payload formats **freeze at E3**.

The user's idea, stated once: **the SJON document is the truth; a `.mid` or a `.it` is a
subset of it; whatever the file cannot say rides in the file's own metadata, so the file
alone is the document, and a DAW or a tracker opens the file as if nothing were there.** The
midi set proved the mechanism on one 25-byte payload (an easing hint in a sequencer-specific
meta event, midi 03 and decision 14). This doc generalises it to the whole timeline tier, in
both formats, with one reconciliation rule and a measured survival story.

## What the residue is

Three things, packed by `Residue.pack(Doc)`:

1. **The essence**: the timeline tier of the document, that is every root that is not part of
   the `midi/` or `it/` dump of the carrying file, serialised as SJON **Binary IR** (wire
   format v5, versioned and corpus-gated, `SJON/docs/DESIGN.md`), with the `(anchor …)` of the
   carrying file replaced by a marker (`:file` is the file itself). Binary IR rather than text
   because it is the substrate's wire-stable encoding, it is compact, and it round-trips
   losslessly. Comments survive: the packer uses `.full` mode, which keeps trivia and spans
   (`docs/LANGUAGE.md` §10.5), and the corpus pins it.
2. **Lane records**: one per **rendered** native lane, that is a lane whose content tempura
   wrote into the file's native events or cells because it had to
   ([08](08-export.md), "Rendering"). A record names the lane, the native address it was
   rendered to (an SMF track and channel; an IT channel set and the pattern set), and a
   **content hash** (SHA-256, SJON's `Sha256Pin` idiom) over the rendered native events as
   tempura wrote them, with every position converted to **tempura ticks** through the file's
   division or row grid: a `.mid` whose `division` was rescaled with its ticks (the music
   unchanged) hashes the same, one whose `division` changed under unchanged ticks (every
   note moved) does not.
3. **The conductor record**: for a native document (no `:conductor`), the hash over the
   file's whole timing context as tempura wrote it: for SMF the header's `format` and
   `division` and every `set-tempo`, `time-signature`, `marker` and `cue-point` event in
   **every** track (a tempo event added on track 3 conducts, midi 04's rule); for IT the
   header's initial speed and tempo, the highlight, the order list and every `Txx`/`Axx`
   cell in every pattern. Positions in tempura ticks, as above.

The essence is authoritative for everything the file cannot say. The lane and conductor
records exist so that a foreign edit to rendered content is detected per lane and for the
conductor, never per file.

## One home

Every piece of content has exactly one home, and the residue never duplicates it:

- **Bound content** (a `notes` or `curve` lane with `:from`) lives in the file's native
  events or cells. The residue carries the lane *declaration* (name, kind, address, target,
  range) inside the essence and nothing of its content.
- **Native content** (notes, keyframes, clips of a lane without `:from`) lives in the
  document. When the document is built into a file, the content is **rendered** into native
  events where the format can hold it (notes → MIDI note pairs or IT cells; keyframes → CC
  steps or IT volume-column values), and the essence keeps the exact native forms too. The
  rendered events are a *view*; the essence is the truth; the lane record's hash says
  whether the view was edited.
- **Unrenderable content** (a `query` or `formula` lane; a keyframe with an easing the
  format cannot sample; a clip whose phrase overlaps an IT pattern boundary) is essence only,
  and the build reports each as `residue_only` (a warning naming the lane) so the author
  knows the DAW will not hear it.

## Reconciliation (the one rule)

On `dump`, after the format core has read the file and the bridge has built the `midi/` or
`it/` tier, `Residue.unpack` finds the payloads and applies, in this order:

1. **No residue**: derive a skeleton timeline tier: one bound `notes` lane per used address
   (an SMF `(track, channel)`, an IT channel with note cells), one bound `curve` lane per
   controller lane with more than one value (SMF) or per channel column with more than one
   value (IT), `cue`s from SMF markers and cue points, `cue`s from IT order boundaries with
   `--cues`, `:conductor` set to the anchor. Diagnostics: none; the header comment says
   `; skeleton: derived, no residue found`.
2. **Residue, version understood**: restore the essence as the timeline tier. Then check the
   **conductor record**, when there is one: hash the file's conductor content as read now;
   on a match the document's own `tempo-point`s, `meter-point`s and `cue`s are restored and
   the file's tempo events are marked consumed (the document conducts, as it did when it
   was built); on a mismatch someone edited the tempo, the meter or a marker in the DAW or
   tracker, the file wins, the document is restored **with** `:conductor` set to the anchor
   and without its own points and cues, and `residue_stale` names them (the authored `:qpm`
   spelling is among the losses it lists). Then for each lane record, hash the native events
   at the recorded address as read now:
   - **hash matches**: the native events are tempura's rendering; the lane is restored as
     native from the essence, and the rendered events are **not** imported as a bound lane
     (the essence marks the address as consumed).
   - **hash differs**: someone edited the rendered events (a DAW quantised the notes, a
     tracker retimed a row). The native events win for what they can say: the lane becomes
     a **bound** lane at that address, keeping its name, target, range and, for a curve, its
     easing per segment as a hint that is verified against the steps and dropped where it
     disagrees (midi 05's `ease_hint_mismatch` rule). The exact native content from the
     essence is discarded with `residue_stale` (a warning naming the lane, the address and
     what was dropped: exact values beyond 7 bits, clip structure, transposition).
3. **Residue, version newer than the reader**: the payloads stay where they are, unparsed
   (in the `midi/` tier as plain `sequencer-specific` hex events; in the `it/` tier as the
   opaque trailing region the writer re-emits), the skeleton is derived with
   `residue_version`, and a later `build` keeps them and writes no residue of its own unless
   `--force-residue` (`residue_newer_kept`), so an older tempura never shadows a newer one's
   essence with a stale copy.
4. **Residue corrupt or truncated** (bad Binary IR, a split body with a missing part, a hash
   field of the wrong length): the skeleton is derived with `residue_corrupt` naming the
   payload; a fuzz harness holds the never-panic line ([09](09-conformance.md)).
5. **Residue in both IT carriers** (the chunk and the message tail, below): the chunk wins
   when present and readable; the message tail is used when the chunk is absent, corrupt or
   truncated, with `residue_partial` naming what the tail lacks (it carries no native content
   and no records, so no hash check runs and every rendered lane stays bound).

The rule in one line: **the file's native content is the truth for what the file can say;
the residue is the truth for what it cannot; the hash says whether the two were written
together.** It is deterministic (same bytes ⇒ same document), explainable (every loss is a
named diagnostic), and it never lies (a stale essence is never restored over edited music).

## The SMF carrier

One sequencer-specific meta event per payload, `FF 7F <len VLQ> <bytes>`, RP-001's slot for
exactly this ("readers must skip"), with the non-commercial manufacturer id and a tag:

```
7D 't' 'e' 'm'  ver=01  kind  seq  total  <body>
```

- `7D` is the manufacturer id reserved for non-commercial use, shared by every such project,
  so the three-byte tag `tem` follows it (midi 03's `7D 'pau'` precedent). A `7F` event
  without `7D 74 65 6D` is someone else's and stays verbatim in the `midi/` tier.
- `ver` is 1; a higher version is rule 3 above (`residue_version`).
- `kind`: `01` essence, `02` lane record, `03` conductor record, `04` reserved for midivia's
  easing hint body so that midivia may adopt this envelope (midi decision 14's payload is
  read as-is under its own `pau` tag regardless).
- `seq` / `total` (u8 each): the essence may be split across consecutive events when a body
  exceeds a size the E0 spike measures per DAW (the VLQ allows `0x0FFFFFFF`; some sequencers
  cap a meta event lower). Records are always one event.
- Placement: the essence and the conductor record at tick 0 of track 0 (the conductor track;
  in a format 0 file the only track), before any other event at that tick; lane records at
  tick 0 of the track they describe. The canonical writer's stable sort keeps the order
  ([05](05-smf-core.md)).
- **The dump consumes them.** They never appear in the `midi/` tier (the hosted manifest
  gains no head for them, so it stays the midi set's); `tempura check-residue` is the
  readable view, and `build` writes fresh payloads from the document. Only a newer version's
  payloads (rule 3) stay visible, as the plain `sequencer-specific` hex events they are.

## The IT carriers

Two, graded by survival:

1. **The trailing chunk**, after all IT data (after the last sample's bytes, where OpenMPT and
   Schism put their own extensions, it 03 and it 05's canonical layout): `'TMPU'` (4-CC)
   `len u32 LE` then a record list in the SMF carrier's `ver kind seq total body` framing:
   the essence, every lane record and the conductor record, one after another. IT and every
   player load by parapointers and never read past the last region they are pointed at.
   tempura's dump consumes the chunk and never shows it (as with the SMF events above); a
   batida reader under `--preserve-foreign` would keep it as `(foreign :tag "TMPU" (bin …))`
   (it 03). Survival through a **foreign re-save** is not expected: IT, Schism and OpenMPT
   write from their in-memory module and drop trailing bytes they did not read, and the E0
   spike measures exactly that ([11](11-demos-and-milestones.md)).
2. **The message tail**, inside the song message (`MsgLgth` u16 at header `0x36`, `MsgOffset`
   u32 at `0x38`, it 04's table): after the human message, a line `;; tempura` followed by the
   **addressed summary** as SJON text: the `timeline` root's keys, every `section` and `cue`,
   every lane's declaration (name, kind, address, target, range, default easing), every
   pass-through `control`. No native content, no phrases, no records. Budget 4096 bytes
   (`residue_tail_truncated` names what fell off; the field's length is a u16, it 04, and
   what IT's own editor accepts is checked at E0 rather than assumed). The message survives every
   tracker's re-save because it is a first-class field; OpenMPT transcodes it (CP437 or
   Windows-1252 to Unicode and back, it 05's risk), so the tail is ASCII-only by construction
   (SJON's canonical printer with `\u{…}`-free strings; names that need more are hex-escaped
   with a diagnostic).

A `.it` written by tempura carries both; a `.it` re-saved by a tracker keeps the tail; a
dump with only the tail rebuilds sections, cues, lane bindings and pass-through controls and
reports `residue_partial` for the rest.

## Fidelity, stated

- **Essence-exact** (rung 3, 00): `dump(build(doc, kind))` reproduces the timeline tier form
  for form when every lane record's hash and the conductor record's hash match and the
  essence is intact. Pinned by the corpus for both kinds ([09](09-conformance.md)).
- **Music-exact under foreign edits**: when a hash differs, the dump's bound lane reproduces
  the file's events exactly (rung 2 of the format core) and the diagnostics list the loss.
- **Survival is measured, never promised**: for each DAW and tracker the user uses, a file
  with residue is loaded, re-saved or re-exported, and re-read; the count of payloads that
  survive per tool and version goes in this doc's progress log (midi 08's discipline).

## Phases (P104)

1. **Essence pack and unpack (RED first).** Load: `SJON/docs/LANGUAGE.md` §10, `src/Binary.zig`
   surface. Reds: pack of the 02 example and unpack back is form-identical; comments survive
   (lossless mode); an anchor becomes the marker and back; a newer version is kept opaque.
   Green: `residue/essence.zig`. Gate: test.
2. **Lane and conductor records and hashing.** Reds: the hash over rendered events is stable
   across a `write ∘ read` of the file (byte order, running status choices do not change it:
   the hash is over the `Sequence`/`Module` events in tempura ticks, not bytes); a
   one-velocity edit changes a lane record's hash; a one-tempo edit, a marker rename, a
   `set-tempo` added on another track, or a `division` change under unchanged ticks changes
   the conductor record's, while a `division` rescale that keeps the music does not. Green:
   `residue/records.zig`. Gate: test.
3. **The SMF carrier.** Reds: attach places events at the right ticks and positions; the
   `midi/` tier shows nothing of them after a dump; a foreign `7F` stays bytes; split essence
   reassembles; detach leaves the `Sequence` event-identical to before attach. Green:
   `residue/smf.zig`. Gate: test + corpus.
4. **The IT carriers.** Reds: the chunk after the last region with essence and every record
   in it; the message tail after the human message with the `;; tempura` line; the 4096
   budget; ASCII escaping; chunk-wins and tail-only paths. Green: `residue/it.zig`. Gate:
   test + corpus.
5. **Reconciliation.** Reds: the five-rule table above, one fixture per rule and per kind,
   the conductor path in both verdicts; `residue_stale` lists exactly the dropped fields; a
   stale curve keeps its easing where the steps agree and loses it where they do not; a
   corrupt essence takes the skeleton path. Green: `residue/reconcile.zig`. Gate: test +
   corpus + `audit-diagnostics`.

## Risks / open questions

- **Carrier survival through DAWs is unknown until measured.** Some sequencers drop or
  reorder sequencer-specific events, some cap their length. The E0 spike takes one export
  from each DAW the user uses and records survival; if none keeps the essence, the design
  still holds (the skeleton path is total) but the "one file holds everything" promise
  narrows to "one file tempura wrote".
- **Trailing bytes in a `.it` may trip a strict loader.** libopenmpt, Schism and IT 2.14 are
  checked at E0; a loader that treats trailing bytes as corruption would force the essence
  into the message (compressed, base64), which is the fallback recorded here and not
  designed further unless needed.
- **The message tail is user-visible.** A tracker shows `;; tempura …` under the song text.
  That is honest and small; the summary is designed to read as a table of contents.
- **Binary IR versions.** SJON's wire format is v5 and versioned; the essence records the
  version it was written with and a reader with an older substrate reports
  `residue_version` (rule 3). tempura's `ver` byte versions the envelope, not the IR.
- **Hash scope for IT rendered lanes.** An IT rendered lane spans several patterns and the
  order list; the hash covers the cells at the lane's channel in the patterns the clip
  structure touched and the order entries in that range, stated precisely in `docs/residue.md`
  at E3 so a second implementation could compute it.

## Progress log

Appended at Task 19 (E3 close). Dated entries only; nothing above this line is
rewritten.

### 2026-09-21 — survival: UNMEASURED, per tool

"Survival is measured, never promised" (above) is unsatisfied. No run has been
recorded, and none was estimated or assumed. The authoring machine has no
`openmpt123`, no `midicsv`, no OpenMPT, no Schism Tracker and no DOSBox, and no
DAW (`conformance/PINS.md` records what is absent and at which version it would be
pinned).

| Tool | Kind | Essence | Lane records | Conductor record | `TMPU` chunk | Message tail | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OpenMPT | .it | — | — | — | — | — | UNMEASURED |
| Schism Tracker | .it | — | — | — | — | — | UNMEASURED |
| Impulse Tracker 2.14 (DOSBox) | .it | — | — | — | — | — | UNMEASURED |
| libopenmpt (`openmpt123`) | .it | n/a | n/a | n/a | — | — | UNMEASURED |
| *(DAW 1)* | .mid | — | — | — | n/a | n/a | UNMEASURED |
| *(DAW 2)* | .mid | — | — | — | n/a | n/a | UNMEASURED |

**The procedure is `conformance/CHECKLIST.md` section C** — load a file tempura
wrote, re-save or re-export without editing, re-read, and count the payloads that
came back, one row per tool and version. Sections A (a built `.it` loads and plays
in three players), B (a built `.mid` opens in each DAW) and D (invisibility: the
same file with and without residue reports the same duration, tempo and names) are
the gates around it, and all four are UNMEASURED on the same date.
`demos/e0-carriers/README.md` carries the summary in E0's own shape, with the two
tables plan 11 step 3 asks for. The E0 impulsos measure (step 5) is UNMEASURED
too: the piece is not on this machine.

What IS measured with no tools installed: both carriers are written and read back
by tempura itself across the golden corpus (seven `residue-*` cases plus every
`examples-*` and `render-*` case), the never-panic harnesses run both residue
unpackers over arbitrary bytes, and `zig build conform` runs and prints a reason
per oracle it could not use.

The design is total either way, which is why this stays a log and not a blocker: a
file whose residue is gone takes rule 1 and dumps as a derived skeleton
(`demos/e1-two-files-one-document/` shows that working on purpose, with
`--no-residue`). What a "dropped" verdict would narrow is the promise — from "one
file holds everything" to "one file tempura wrote holds everything".

### 2026-09-21 — amendment to the "Hash scope for IT rendered lanes" risk

That risk (above) deferred the precise statement to `docs/residue.md` at E3. The
statement is there, and **it names a different scope from the risk's own
sentence**. The code's scope stands; this entry records the divergence rather than
editing the sentence.

The risk says the hash covers the cells at the lane's channel "in the patterns the
clip structure touched and the order entries in that range". The code hashes, for
a lane record whose address names one IT channel:

* `channels` = that one channel, and
* `patterns` = **every pattern the timing walk played**, ascending and
  deduplicated — not the patterns the clip structure happened to touch;
* and **no order entries at all**.

Two reasons, stated in full in `docs/residue.md` ("The scope, stated precisely"):

1. **The clip structure is not an input.** A hash is recomputed from the module
   and the record's address and from nothing else, because `tempura check-residue`
   answers the same question over a file alone, with no schema loaded and the
   essence never restored. A scope depending on a document's clips could not be
   recomputed there, and a hash one of its two readers cannot compute is not a
   hash.
2. **The order entries belong to the conductor.** They are hashed in the conductor
   record. Hashing them in a lane too would make every lane stale on a reorder
   that moved none of its cells, and the point of per-lane records is that a
   foreign edit is detected per lane.

`docs/residue.md` also states the byte layout and one thing the risk does not
mention: the five cell bytes fed to the hash are tempura's remapped values, not
ITTECH's on-disk bytes, so a second implementation must remap before hashing.

### 2026-09-21 — rule 5 and a newer chunk: a divergence to close later

Rule 5 (the carrier a dump reads) lists the tail-wins cases as absent, corrupt or
truncated. The code's `it.choose` also prefers a readable message tail over a
`TMPU` chunk written by a NEWER envelope version, which rule 5 does not name.
`corpus/residue-newer-version/` pins the behaviour. Either the rule gains that
case or `choose` loses it; recorded here rather than decided.

**Decided the same day, by `docs/residue.md`'s wording** ("absent, corrupt, empty
or of a version the reader does not know"): the rule gains the case, and the
essence's own Binary IR wire version is one more version the reader does not know.
`choose` now peeks that header (`essence.newerWire`) and treats an undecodable
essence exactly as a newer envelope — the tail is read, the chunk stays in the
file, `residue_version` says so.

### 2026-09-21 — "consumed" made literal; the wire-version seam (the final review's D1 and D4)

Two defects the final review reproduced, both in this plan's rule 2 and rule 3.

- **Rule 2's "consumed" was a verdict and not an edit.** A restored lane's rendered
  events stayed in the dumped `midi/` or `it/` tier, and `build` of the dump
  rendered the lane again INTO that tier: every note twice, and once more per
  rebuild; the same for the conductor's own events. `reconcile.consumeSmf` and
  `consumeIt` now take the view out of the tier value before it is printed — the
  hash's own scope for a lane, and what `render_smf`'s conductor track and
  `render_it`'s conductor cells write for the conductor — with the tracks kept so
  no `:track` moves, and `render_smf` renders a lane back onto the empty track of
  its own name. `build → dump → build` is a fixed point, byte for byte, in both
  kinds; `docs/residue.md` states the rule. The corpus verdict table carries a
  `(consumed …)` line whenever anything went.
- **A newer WIRE version was detached before it was recognised.** `dumpSmf` took
  every payload of its own envelope version out of the tier and only then let
  `reconcile` discover that the essence would not decode; the document said "left
  in the file" over a tier that no longer held it, and a rebuild wrote its own
  residue over the newer one with no `--force-residue`. The wire version is now
  read off the essence's header (`essence.newerWire`) before the tier is printed,
  `newerSmf` / `newerIt` answer envelope OR wire, `wantsResidue` refuses either,
  and `check-residue` names which.

### 2026-09-21 — a stale lane binds at EVERY channel its records name (the final review's D2)

A native `.mid` lane whose notes name several channels is rendered onto one track
with one lane record PER CHANNEL (a hash is over a `(track, ch)` pair). A DAW edit
to one of those channels made `reconcile.bindLane` rewrite the lane as bound at
the stale record's channel alone, and the other channel's rendered notes stayed
in the tier belonging to no lane — gone from every timeline query and from the
score. "Reconciliation must preserve every address belonging to the lane."

- **An SMF binding names a SET of channels on one track.** `Doc.Address.smf.ch`
  is a `Doc.Channels` (a `u16` mask on the wire, two bytes pinned); `:ch 2` is a
  single and `:ch [1 2]` several. `fromSjon` reads either (an empty vector or a
  repeated channel is `address_invalid`, a vector on a NATIVE lane too — a set
  cannot be a note's default); `toSjon`, the IT tail and `reconcile`'s own
  binding keys print the set the same way; `bridge_smf.pairNotes` / `curveSteps`
  filter by the set and a `PairedNote` carries its own `ch`, which `derive`,
  the renderer and a materialised `(note :ch …)` keep. `schema/tempura.sjon`
  gains `midi-channel-set` and `midi-channels` (the union), mirroring
  `cc-address`.
- **The record wire does not change.** A record still names one channel;
  `encodeAddress` writes a set's `first()` (a build never hands one over — the
  renderer's records are singles), and `decodeAddress` makes a single.
- **Rule 2 over several records.** The lane binds when ANY of its records is
  stale, at the records' track and at the UNION of their channels; every record
  of a binding lane reports `became_bound` with its own `hash_ok`, so the table
  never says a lane was restored native when it was not, and `consumeSmf` —
  which keys on `restored_native` — leaves every channel of a bound lane in the
  tier for it to read. `residue_stale` names the set (`track 2 ch 1,2`).
  `corpus/residue-stale-lane-partial/` pins it; `docs/residue.md` states it.
