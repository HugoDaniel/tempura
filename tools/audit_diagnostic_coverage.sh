#!/usr/bin/env bash
# Audit `Diag.Code` test coverage. Adapted from pacer's script of the same
# name (pacer 0.2.0, 63cd0ed), pointed at tempura's one diagnostic enum.
#
# The rule: A CODE THAT IS RAISED MUST BE NAMED BY A TEST. For every
# variant of the `Code` enum in src/Diag.zig we look for it in two places,
# as a Zig enum literal (`.<name>`, so `Diag.Code.<name>` matches too):
#
#   * in the body of some `test "..." { }` across src/     → the test
#     coverage the gate is about;
#   * in the NON-test text of src/ (production code)       → a producer
#     that raises it.
#
# raised + named by a test  → ok
# raised + no test          → MISSING; exit 1. This is the gate.
# not raised yet            → pending, reported and counted, not a failure.
#
# Why `pending` exists here and not in pacer's copy: tempura's enum was
# SEEDED WHOLE at E0 (one shared vocabulary, every code the plans name,
# append-only from there) while the producers land part by part, so most
# codes have no raiser to test yet. `pending` shrinks to zero on its own
# as the parts land — nothing to maintain, and no list of exceptions.
#
# We accept ONLY test-block bodies as coverage:
#
#   * Production switch arms (`.tick_overflow => …`) raise the code, they
#     do not test it — that is exactly the MISSING case.
#   * The enum definition itself lives in Diag.zig, so a whole-file grep
#     would self-satisfy every variant — we extract test bodies.
#   * Corpus goldens carry NUMERIC codes, never names, so they cannot
#     satisfy this check either.
#
# Two files are excluded from the PRODUCTION side (they hold every code's
# name without raising anything, and counting them would make the audit
# demand a test for all 79 at once):
#
#   * src/Diag.zig — the enum and `code_order`, the ordinal pin table;
#     the vocabulary raises no diagnostic. Its TEST bodies still count as
#     coverage.
#   * src/fuzz.zig — a test-only root. Its harness functions sit outside
#     `test` blocks but are test code, not producers.
#
# Output: per-code status, plus an OK/FAIL summary. Exit 0 when nothing is
# missing, 1 otherwise.
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

# Materialize the two corpora. Zig style puts tests at top level, so a
# test body runs from `test "..." {` to the `}` in column 0.
tests_txt=$(mktemp)
prod_txt=$(mktemp)
trap 'rm -f "$tests_txt" "$prod_txt"' EXIT

while read -r f; do
    awk '
        /^test ".*" \{/ { in_test = 1 }
        in_test { print }
        in_test && /^\}$/ { in_test = 0 }
    ' "$f" >> "$tests_txt"

    case "$f" in
        src/Diag.zig | src/fuzz.zig) continue ;;
    esac

    awk '
        /^test ".*" \{/ { in_test = 1 }
        !in_test { print }
        in_test && /^\}$/ { in_test = 0 }
    ' "$f" >> "$prod_txt"
done < <(find src -name '*.zig' -type f)

missing=0
pending=0
covered=0
total=0

for code in $codes; do
    total=$((total + 1))
    # Enum-literal usage: `.tick_overflow` with a trailing non-identifier
    # character, so `.residue_only` does not also match `.residue_only_x`.
    pattern="\.${code}([^a-zA-Z0-9_]|$)"
    if grep -qE "$pattern" "$tests_txt"; then
        printf "  ok      %s\n" "$code"
        covered=$((covered + 1))
    elif grep -qE "$pattern" "$prod_txt"; then
        printf "  MISSING %s — raised in src/, named by no test\n" "$code"
        missing=$((missing + 1))
    else
        printf "  pending %s — no producer raises it yet\n" "$code"
        pending=$((pending + 1))
    fi
done

echo
printf "Covered: %d/%d  Pending: %d  Missing: %d\n" "$covered" "$total" "$pending" "$missing"

if [ "$missing" -gt 0 ]; then
    echo >&2
    echo "audit: a code your code raises has no test that names it." >&2
    echo "  Add \`.<code>\` to an assertion inside a \`test \"...\" { }\` body." >&2
    exit 1
fi
