#!/usr/bin/env bash
# Audit `Diag.Code` test coverage. Adapted from pacer's script of the same
# name (pacer 0.2.0, 63cd0ed), pointed at tempura's one diagnostic enum.
#
# For every variant of the `Code` enum in src/Diag.zig, confirm at least
# one `test "..." { }` body references it by name as a Zig enum literal
# (`.<name>`). We accept ONLY test-block bodies:
#
#   * Production switch arms (`.tick_overflow => …`) reference the code
#     but are not test coverage.
#   * The enum definition itself lives in Diag.zig, so a whole-file grep
#     would self-satisfy every variant — we extract test bodies.
#   * Corpus goldens carry NUMERIC codes, never names, so they cannot
#     satisfy this check either.
#
# Output: per-code status, plus an OK/FAIL summary. Exit 0 on full
# coverage, 1 if any variant has no reference.
#
# Usage: tools/audit_diagnostic_coverage.sh

set -e
cd "$(dirname "$0")/.."

SRC="src/Diag.zig"
if [ ! -f "$SRC" ]; then
    echo "audit_diagnostic_coverage.sh: $SRC not found" >&2
    exit 1
fi

# Pull variants from the `pub const Code = enum(u16) { ... };` block.
codes=$(awk '/pub const Code = enum\(u16\) \{/,/^\};/' "$SRC" \
    | grep -E '^[[:space:]]+[a-z_0-9]+,$' \
    | sed 's/^[[:space:]]*//;s/,$//')

if [ -z "$codes" ]; then
    echo "audit_diagnostic_coverage.sh: no Code variants found in $SRC" >&2
    exit 1
fi

# Materialize the bodies of every `test "..." { ... }` block across src/.
# Zig style puts tests at top level, so the closing `}` sits at column 0.
# The whole tree is walked: a code raised by a part is tested by that
# part's own files, not by Diag.zig.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
while read -r f; do
    awk '
        /^test ".*" \{/ { in_test = 1 }
        in_test { print }
        in_test && /^\}$/ { in_test = 0 }
    ' "$f" >> "$tmp"
done < <(find src -name '*.zig' -type f)

missing=0
total=0
covered=0

for code in $codes; do
    total=$((total + 1))
    # Enum-literal usage inside a test body: `.tick_overflow` with a
    # trailing non-identifier character (so `.residue_only` does not also
    # match `.residue_only_x`).
    if grep -qE "\.${code}([^a-zA-Z0-9_]|$)" "$tmp"; then
        printf "  ok      %s\n" "$code"
        covered=$((covered + 1))
    else
        printf "  MISSING %s\n" "$code"
        missing=$((missing + 1))
    fi
done

echo
printf "Covered: %d/%d  Missing: %d\n" "$covered" "$total" "$missing"

if [ "$missing" -gt 0 ]; then
    exit 1
fi
