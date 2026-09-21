#!/bin/sh
# The oracle matrix: tempura's readers against mature implementations.
#
#   conformance/conform.sh            # every oracle over every corpus fixture
#   conformance/conform.sh --quiet    # one line per oracle, no per-file rows
#
# Two oracles, one per format (docs/plans/09-conformance.md, "Oracles"):
#
#   * libopenmpt's `openmpt123 --info` over every `corpus/*/song.it`
#     — duration, tempo and channel names from a mature `.it` loader.
#   * `midicsv` over every `corpus/*/song.mid`, then `csvmidi` back
#     — the event list as text, and the proof it re-reads.
#
# Neither is installed by this script and neither is vendored. When an
# oracle is missing the script prints `skipped: <tool> not installed` for
# it and **exits 0**: a machine without brew packages is not a failing
# machine, and the nightly job that has them is where the comparison
# actually runs (`docs/plans/09-conformance.md`, "CI shape").
#
# What this script does NOT do: compare against tempura's own reading.
# That comparison is the `conform` build verb's, which has the CLI built
# and can diff `tempura inspect --csv` against midicsv's rows. This is
# the half that only needs the oracles and the fixtures, so it runs on
# its own and says plainly what it could not run.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
quiet=0
status=0

while [ $# -gt 0 ]; do
    case "$1" in
        --quiet) quiet=1 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "conform: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { [ "$quiet" -eq 1 ] || echo "$@"; }

# ---- the .it oracle: libopenmpt ------------------------------------------

if ! command -v openmpt123 >/dev/null 2>&1; then
    echo "conform: it/libopenmpt — skipped: openmpt123 not installed"
else
    version=$(openmpt123 --version 2>/dev/null | head -1 || echo "unknown")
    echo "conform: it/libopenmpt — $version"
    n=0
    bad=0
    for f in "$root"/corpus/*/song.it; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        case_name=$(basename "$(dirname "$f")")
        if info=$(openmpt123 --info "$f" 2>&1); then
            dur=$(printf '%s\n' "$info" | grep -i '^Duration' | head -1 || true)
            say "  ok    $case_name ${dur:+— $dur}"
        else
            bad=$((bad + 1))
            status=1
            echo "  FAIL  $case_name" >&2
            printf '%s\n' "$info" | sed 's/^/        /' >&2
        fi
    done
    echo "conform: it/libopenmpt — $n fixture(s), $bad refused"
fi

# ---- the .mid oracle: midicsv / csvmidi ----------------------------------

if ! command -v midicsv >/dev/null 2>&1; then
    echo "conform: smf/midicsv — skipped: midicsv not installed"
elif ! command -v csvmidi >/dev/null 2>&1; then
    echo "conform: smf/midicsv — skipped: csvmidi not installed"
else
    echo "conform: smf/midicsv — $(midicsv -h 2>&1 | head -1 || echo unknown)"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT INT TERM
    n=0
    bad=0
    for f in "$root"/corpus/*/song.mid; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        case_name=$(basename "$(dirname "$f")")
        if ! midicsv "$f" "$tmp/a.csv" 2>"$tmp/err"; then
            bad=$((bad + 1)); status=1
            echo "  FAIL  $case_name — midicsv refused it" >&2
            sed 's/^/        /' "$tmp/err" >&2
            continue
        fi
        # And back: the CSV must re-read as a file whose own CSV is the
        # same. That is the round trip the oracle can assert on its own.
        if ! csvmidi "$tmp/a.csv" "$tmp/b.mid" 2>"$tmp/err"; then
            bad=$((bad + 1)); status=1
            echo "  FAIL  $case_name — csvmidi refused the CSV" >&2
            sed 's/^/        /' "$tmp/err" >&2
            continue
        fi
        midicsv "$tmp/b.mid" "$tmp/b.csv" 2>/dev/null || true
        if diff -q "$tmp/a.csv" "$tmp/b.csv" >/dev/null 2>&1; then
            rows=$(wc -l < "$tmp/a.csv" | tr -d ' ')
            say "  ok    $case_name — $rows event row(s), round trip identical"
        else
            bad=$((bad + 1)); status=1
            echo "  FAIL  $case_name — the CSV round trip is not identical" >&2
            diff "$tmp/a.csv" "$tmp/b.csv" | head -20 | sed 's/^/        /' >&2
        fi
    done
    echo "conform: smf/midicsv — $n fixture(s), $bad refused"
fi

# ---- the wiki cases ------------------------------------------------------

cases="$root/conformance/wiki-cases"
if [ ! -d "$cases" ] || [ -z "$(ls -A "$cases" 2>/dev/null || true)" ]; then
    echo "conform: it/wiki-cases — skipped: nothing fetched (conformance/fetch_wiki_cases.sh)"
else
    n=$(ls -1 "$cases" | wc -l | tr -d ' ')
    echo "conform: it/wiki-cases — $n case(s) on disk; the walk comparison is the conform build verb's"
fi

if [ "$status" -ne 0 ]; then
    echo "conform: an oracle refused a fixture — see the FAIL rows above" >&2
fi
exit "$status"
