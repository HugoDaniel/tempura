# E4 — the packed payload

Nothing is built here yet, and the reason is a dependency outside this
repo. The `TMPU` payload kind is the tempura document — SJON text, or
Binary IR with a flag — riding inside a packed piece beside the `PACR`
score it was exported from, so a `.png` carrying `PNGB` + `PACR` + `TMPU`
keeps a piece's arrangement next to the thing that plays it and a studio
can reopen the arrangement rather than decompile the score. The kind is
**reserved** in expansible-player 02's registry (`docs/payload-kinds.md`)
and has **no handler in v1**, deliberately: the tiny player conducts from
`PACR` and never needs a timeline, so the payload costs a runtime nothing
and buys an editor everything. It is registered when **expansible-player
X1** assigns the envelope, which has not happened, so the demo this
directory is for — one packed `.png` with all three payloads — waits on
that and on nothing in tempura. Plan 11's other E4 items are dropped
rather than pending: pstudio is not a host (ruled 2026-09-20), so the
timeline pane, the transport display and `demos/e4-studio/` are gone, and
the 0.1.0 tag is the user's signal to give.

**2026-09-29.** The reservation above is tempura's alone: expansible-player 02's
kind registry ("the whole inventory", read at `~/llm` `23ef69d`) lists `PACR`,
`ITMD` and eleven others and no `TMPU`, and the set never names tempura, so the
cross-set ask is still to file. X1 ships the `PNGB`, `PNGF`, `SNTU` and `META`
handlers; the `score` handler that would sit beside this payload is checkpoint
05.C3 at X4. The interim host is plan 13's `demos/e5-stage/` page.
