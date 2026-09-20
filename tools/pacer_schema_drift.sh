#!/usr/bin/env bash
# Drift gate for `schema/pacer.sjon`.
#
# That file is a BYTE-FOR-BYTE copy of the sibling repo's score manifest
# (pacer 0.2.0, commit 63cd0ed, copied 2026-09-20) — tempura emits pacer
# score text and validates what it emits against pacer's own vocabulary,
# so a second spelling of it would drift within a week. Nothing in the
# copy may be edited, not even its header: this script diffs it WHOLE.
#
# `../pacer` is a sibling checkout, not a dependency. When it is absent
# (a fresh clone, CI without the sibling) the copy is TRUSTED and the
# provenance above is what says where it came from — a pass with a note,
# not a failure. When it is present, any difference fails the gate; the
# fix is to re-copy and review, never to hand-edit either side.
#
# Usage: tools/pacer_schema_drift.sh

set -e
cd "$(dirname "$0")/.."

COPY="schema/pacer.sjon"
SIBLING="../pacer/schema/pacer.sjon"

if [ ! -f "$COPY" ]; then
    echo "pacer_schema_drift.sh: $COPY not found" >&2
    exit 1
fi

if [ ! -f "$SIBLING" ]; then
    echo "pacer-schema: no sibling checkout at $SIBLING — copy trusted (pacer 0.2.0, 63cd0ed, copied 2026-09-20)"
    exit 0
fi

if diff -u "$SIBLING" "$COPY"; then
    echo "pacer-schema: ok — $COPY matches $SIBLING byte for byte"
    exit 0
fi

echo >&2
echo "pacer-schema: FAIL — $COPY has drifted from $SIBLING (diff above)." >&2
echo "  Re-copy it whole (\`cp $SIBLING $COPY\`) and review the diff; the copy is verbatim by contract." >&2
exit 1
