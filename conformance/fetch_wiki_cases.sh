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
# Exit status: 0 when every pinned row is on disk and verified (a row
# whose pin is still `TODO` is inert and does not fail), 1 when a
# download failed, a digest did not match, or nothing could verify one.
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

# The header above, as help. The range is derived rather than numbered —
# `1d` drops the shebang and `/^[^#]/,$d` stops at the first line that is
# not a comment — so it cannot drift when the header grows.
usage() {
    sed -e '1d' -e '/^[^#]/,$d' -e 's/^#\{1,\} \{0,1\}//' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list) list_only=1 ;;
        --out) shift; out="$1" ;;
        -h|--help) usage; exit 0 ;;
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

# The loop reads from a HERE-DOCUMENT and not from a pipe, deliberately:
# on the right of a pipe it would run in a subshell and every tally and
# every `status=1` below would be thrown away when it ended — the script
# would then report a digest mismatch and still exit 0.
status=0
pending=0
fetched=0

while IFS='|' read -r name url want; do
    [ -n "$name" ] || continue

    if [ "$list_only" -eq 1 ]; then
        printf '%-24s %-56s %s\n' "$name" "$url" "$want"
        continue
    fi

    if [ "$url" = "TODO" ] || [ "$want" = "TODO" ]; then
        echo "wiki-cases: $name — pin not filled in (see conformance/PINS.md); skipped"
        pending=$((pending + 1))
        continue
    fi

    mkdir -p "$out"
    dest="$out/$name"

    if [ -f "$dest" ]; then
        got=$(sha_of "$dest")
        if [ "$got" = "$want" ]; then
            echo "wiki-cases: $name — already here and pinned"
            fetched=$((fetched + 1))
            continue
        fi
        echo "wiki-cases: $name — on disk with the wrong digest, refetching" >&2
        rm -f "$dest"
    fi

    if [ -z "$fetcher" ]; then
        echo "wiki-cases: $name — neither curl nor wget is installed" >&2
        status=1
        continue
    fi

    tmp="$dest.part"
    ok=1
    if [ "$fetcher" = "curl" ]; then
        curl -fsSL "$url" -o "$tmp" || ok=0
    else
        wget -q -O "$tmp" "$url" || ok=0
    fi
    if [ "$ok" -eq 0 ]; then
        echo "wiki-cases: $name — download failed" >&2
        rm -f "$tmp"
        status=1
        continue
    fi

    got=$(sha_of "$tmp")
    if [ -z "$got" ]; then
        echo "wiki-cases: $name — no sha256 tool (shasum / sha256sum); refusing an unverified file" >&2
        rm -f "$tmp"
        status=1
        continue
    fi
    if [ "$got" != "$want" ]; then
        echo "wiki-cases: $name — DIGEST MISMATCH" >&2
        echo "  want $want" >&2
        echo "  got  $got" >&2
        rm -f "$tmp"
        status=1
        continue
    fi

    mv "$tmp" "$dest"
    echo "wiki-cases: $name — fetched and verified"
    fetched=$((fetched + 1))
done <<EOF
$CASES
EOF

if [ "$list_only" -eq 1 ]; then
    exit 0
fi

if [ "$status" -ne 0 ]; then
    echo "wiki-cases: FAILED — a download or a digest did not hold; nothing unverified was kept" >&2
    exit 1
fi

if [ "$fetched" -gt 0 ]; then
    echo "wiki-cases: done — $fetched verified in $out (ignored by conformance/.gitignore; nothing fetched is committed)"
else
    echo "wiki-cases: done — nothing to fetch; $pending row(s) still need a pin in conformance/PINS.md"
fi
exit 0
