#!/bin/sh
# Fetch the OpenMPT wiki IT test cases, hash-pinned.
#
# The cases carry no explicit licence, so they are NEVER vendored: this
# script downloads them into a directory git ignores, only when a human
# runs it, and refuses anything whose sha256 is not the pin.
#
#   conformance/fetch_wiki_cases.sh            # fetch into conformance/wiki-cases/
#   conformance/fetch_wiki_cases.sh --list     # print the table, download nothing
#   conformance/fetch_wiki_cases.sh --out DIR  # fetch somewhere else
#
# Nothing else in the build calls this. `zig build conform` and
# `conformance/conform.sh` use whatever is already on disk and skip with
# a reason when it is not there — a gate never downloads behind anyone's
# back.
#
# The pin table lives below and is mirrored in `conformance/PINS.md`. A
# row whose URL or digest is still `TODO` is INERT: it is listed, it is
# not fetched, and the script says so. Fill it from the wiki page:
#
#   https://wiki.openmpt.org/Development:_Test_Cases/IT
#
# take each case's file link, download once by hand, run
# `shasum -a 256 <file>`, and put the URL and the digest in the row.
set -eu

# name | url | sha256
#
# The three named here are the timing subset the plan set cites
# (docs/plans/09-conformance.md, "the IT walk is a player's walk").
# Add a row as each walk corner gains a case.
CASES='
PatternLoop.it|TODO|TODO
PatternDelays.it|TODO|TODO
TempoSlide.it|TODO|TODO
'

out="$(cd "$(dirname "$0")" && pwd)/wiki-cases"
list_only=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list) list_only=1 ;;
        --out) shift; out="$1" ;;
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "fetch_wiki_cases: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

fetcher=""
if command -v curl >/dev/null 2>&1; then
    fetcher="curl"
elif command -v wget >/dev/null 2>&1; then
    fetcher="wget"
fi

sha_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        echo ""
    fi
}

# The loop below runs in a subshell (it is the right-hand side of a
# pipe), so it keeps no tallies: every outcome is printed as it happens
# and the exit status is the fetch's, not a count's.
printf '%s\n' "$CASES" | while IFS='|' read -r name url want; do
    [ -n "$name" ] || continue

    if [ "$list_only" -eq 1 ]; then
        printf '%-24s %-56s %s\n' "$name" "$url" "$want"
        continue
    fi

    if [ "$url" = "TODO" ] || [ "$want" = "TODO" ]; then
        echo "wiki-cases: $name — pin not filled in (see conformance/PINS.md); skipped"
        continue
    fi

    mkdir -p "$out"
    dest="$out/$name"

    if [ -f "$dest" ]; then
        got=$(sha_of "$dest")
        if [ "$got" = "$want" ]; then
            echo "wiki-cases: $name — already here and pinned"
            continue
        fi
        echo "wiki-cases: $name — on disk with the wrong digest, refetching" >&2
        rm -f "$dest"
    fi

    if [ -z "$fetcher" ]; then
        echo "wiki-cases: $name — neither curl nor wget is installed; skipped" >&2
        continue
    fi

    tmp="$dest.part"
    if [ "$fetcher" = "curl" ]; then
        curl -fsSL "$url" -o "$tmp" || { echo "wiki-cases: $name — download failed" >&2; rm -f "$tmp"; continue; }
    else
        wget -q -O "$tmp" "$url" || { echo "wiki-cases: $name — download failed" >&2; rm -f "$tmp"; continue; }
    fi

    got=$(sha_of "$tmp")
    if [ -z "$got" ]; then
        echo "wiki-cases: $name — no sha256 tool (shasum / sha256sum); refusing an unverified file" >&2
        rm -f "$tmp"
        continue
    fi
    if [ "$got" != "$want" ]; then
        echo "wiki-cases: $name — DIGEST MISMATCH" >&2
        echo "  want $want" >&2
        echo "  got  $got" >&2
        rm -f "$tmp"
        continue
    fi

    mv "$tmp" "$dest"
    echo "wiki-cases: $name — fetched and verified"
done

if [ "$list_only" -eq 1 ]; then
    exit 0
fi

if [ -d "$out" ]; then
    echo "wiki-cases: done — $out (ignored by conformance/.gitignore; nothing fetched is committed)"
else
    echo "wiki-cases: done — nothing to fetch; fill the pins in conformance/PINS.md first"
fi
