# The tick grid

What a consumer of tempura needs to know about time, restated from
[the time model](plans/03-time-model.md) so nobody has to read a plan document to
use the library. The grid, the position units and the printer's rule **freeze at E1**:
they are a contract, not an implementation detail.

## One number

**`TPQ = 46 126 080` ticks per quarter note.**

```
46 126 080 = 2¹⁰ · 3² · 5 · 7 · 11 · 13 = 64 · PPC
```

`PPC = 720 720` is SJON's per-bar pattern grid, which pacer plays on. Positions are
`i64` ticks with a portable ceiling of **`MAX_TICK = 2^53`** — 195 273 460 quarter
notes, about 27 000 hours at 120 quarter notes per minute. Past it is a
`tick_overflow` diagnostic, never a wrap.

Why per quarter note and not per bar: a bar's length changes with the meter, a
quarter's does not, and both SMF and Impulse Tracker count quarters. Why `64 · PPC`
and not more: `2¹⁰` covers 1024 pulses per quarter and every binary subdivision a DAW
offers; the odd part is SJON's and pacer's, kept whole so the family shares one set of
tuplets; and 2^53 of headroom is still tens of thousands of hours.

## What lands exactly

| Source | Its unit | In tempura ticks | Exact when |
|---|---|---|---|
| SMF, division `PPQ` | `1 / PPQ` quarter | `TPQ / PPQ` | `PPQ` divides `TPQ` |
| Impulse Tracker | one tick, `1 / 24` quarter | `1 921 920` | always; a row of speed `s` is `s · 1 921 920` |
| pacer, meter `[n d]` | one pacer tick, `1 / PPC` bar | one pacer tick is `256 n / d` ticks; a bar is `(256 n / d) · PPC` | a tempura tick is a pacer tick iff it is a multiple of `256 n / d` |
| SJON `PatternQuery`, one cycle | `1 / PPC` cycle | one cycle is one bar: the meter's row above | as pacer's |
| tuplets | `1 / (2^a · 3^b · 5 · 7 · 11 · 13)` of a quarter | integer | `a ≤ 10`, `b ≤ 2` — any DAW's quantise menu |

**SMF divisions that divide `TPQ`** — 24, 48, 96, 120, 192, 240, 384, 480, 960, 1024,
1920, 3840, 7680, 15360 and every other divisor. **Divisions that do not** — 500, 1000,
30720 — land on the nearest tick and are counted in a dump's diagnostics as
`division_inexact`.

A SMPTE division is wall-clock, not musical: it converts through OpenMPT's
`frames · subframes / 2` and the file's `set-tempo` events stop conducting
(`smpte_tempo_ignored`). The canonical SMF writer always emits a pulses-per-quarter
division, so a file read with a SMPTE one is written on the grid it converted to —
and every `set-tempo` on that grid is written as 500 000 µs, the tempo the conversion
assumed (`Division.tempoOnGrid`), because a tempo copied verbatim onto a grid derived
at 120 QPM would conduct it and change the clock. The `midi/` dump spells the same
tier the same way, and its `; smpte …` note counts the events rewritten.

## The pacer divisors

One pacer tick is `256 n / d` tempura ticks for meter `[n d]`. It is an integer for
every meter tempura emits (`d` a power of two, both components 1..16):

| Meter | Divisor | Meter | Divisor |
|---|---|---|---|
| `[4 4]`, `[2 2]`, `[16 16]` | 256 | `[9 8]` | 288 |
| `[3 4]`, `[6 8]` | 192 | `[11 8]` | 352 |
| `[5 4]` | 320 | `[12 8]` | 384 |
| `[7 8]` | 224 | `[13 16]` | 208 |

So a document's positions convert to pacer's by one exact integer division whenever
they sit on pacer's lattice, and `export-score` reports the count and the maximum error
when they do not. At 480 pulses per quarter a 32nd note is tick 60 — *not* on pacer's
grid; on tempura's it is `TPQ / 8 = 5 765 760`, exact, and rounds only at export.
pacer also accepts a `d` that is not a power of two; tempura never emits one
(`export_meter_unsupported`).

## Positions in a document

A `position` is a number with a **required** unit — a bare number is `unit_required`.
Five units:

| Unit | Meaning |
|---|---|
| `q` | quarter notes, decimal |
| `t` | tempura ticks, integer (a fraction is `position_not_integer`) |
| `bar` | bars, decimal, through the meter map |
| `b` | beats from 0 across the meter map, decimal |
| `s` | seconds, decimal, through the tempo map |

`bar` and `b` count **from 0**, as pacer's do. A negative position is
`position_negative`. `s` is forbidden on a tempo point and on a meter point, where it
would be circular.

**Two roundings, and they never meet.** A literal rounds — `q`, `bar` and `b` convert
with one multiply and one round to nearest, ties to even, so a literal always names
the nearest tick. A clock value floors — `s` resolves through the tempo map's
`tick(seconds)`, which floors to the last tick begun. Both of the map's paths floor:
the f64 one, and the exact-integer one a conductor whose tempo points are all `:us`
takes. Each rounding lives in exactly one function, and an `s` literal never reaches
the rounding one.

## The printer's rule

Canonical printing, frozen at E1. A tick prints

1. as `Nbar` when it is a bar line;
2. else as `Nq` when `9009` divides it — `TPQ / 9009 = 5120 = 2¹⁰ · 5`, so `k / TPQ`
   is a terminating decimal exactly when `9009 | k`. The printer emits the shortest
   decimal that round-trips, at most 10 fractional digits;
3. else as `Nt`.

So a dump of quantised material reads as music (`16bar`, `2.5q`) and triplets or freely
played material read as ticks. A hand-written document may use any unit anywhere; only
the printer is constrained.

## Where this is gated

`zig build corpus` — the golden corpus under `corpus/`. Every case pins its input by
hash and its answers byte for byte. The same goldens **will be** re-derived from
`tempura.wasm` at E3 (the wasm half of the corpus, Task 18); that second comparison is
where native-versus-wasm equality gets asserted, and until it lands the native runner is
the only side reading these files.
