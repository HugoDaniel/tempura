#!/usr/bin/env bash
# Size budget for `tempura.wasm` — pngine's budget discipline, which plan
# 10 names as this artifact's gate: "the E3 gate pins the size at what it
# measures and `verify` fails on growth past it".
#
# The ceiling below is FROZEN: it is what the artifact measured when the
# whole export surface landed, plus ten per cent of headroom. The point is
# not to be exact, it is to make a step change visible — a new dependency,
# an accidentally-retained debug table, a `std` facility that drags half of
# `std.fmt` in — while ordinary work still fits.
#
# Raising it is a deliberate, reviewed edit of this file with the reason in
# the commit message, never a reflex. Lowering it after a real shrink is
# free and welcome.
#
#   measured: 1 355 643 bytes (2026-09-21, the E3 export surface: both
#             format cores, the bridges, the time model, the edit engine
#             — including `Plan.fromActionsJson`, which `tpr_apply`'s
#             action-list spelling needs — the exporters, the residue,
#             and SJON's parser / validator / printer / Edit / Binary IR)
#   ceiling:  1 491 224 bytes (measured + 10 %)
#
# The number was re-measured once the whole surface was in: the first
# reading (1 344 540) predated the action-list reader that plan 10's
# `tpr_apply` row requires, so the ceiling it implied was not the one
# this artifact freezes at.
#
# Usage: tools/wasm_budget.sh [path/to/tempura.wasm]
#        `zig build wasm` first — this script measures, it never builds.

set -e
cd "$(dirname "$0")/.."

CEILING=1491224
WASM="${1:-zig-out/bin/tempura.wasm}"

if [ ! -f "$WASM" ]; then
    echo "wasm-budget: $WASM not found — run \`zig build wasm\` first" >&2
    exit 1
fi

# `wc -c` on a file is portable and exact; `stat` is not (BSD and GNU
# spell its flags differently).
SIZE=$(wc -c <"$WASM" | tr -d ' ')

# Percent of the ceiling, in integer arithmetic — no `bc` dependency.
PCT=$((SIZE * 100 / CEILING))

if [ "$SIZE" -le "$CEILING" ]; then
    echo "wasm-budget: ok — $WASM is $SIZE bytes, ${PCT}% of the $CEILING-byte ceiling"
    exit 0
fi

echo >&2
echo "wasm-budget: FAIL — $WASM is $SIZE bytes, over the $CEILING-byte ceiling by $((SIZE - CEILING))." >&2
echo >&2
echo "The ceiling is the size the artifact was frozen at plus ten per cent (see the header)." >&2
echo "Find what grew — \`zig build wasm\` then a section dump, or git bisect the size — before" >&2
echo "touching the number. If the growth is genuinely earned, raise CEILING in this file in its" >&2
echo "own commit and say in the message what bought the bytes." >&2
exit 1
