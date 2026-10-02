#!/bin/bash
# Checks README.md against the project (plan.md "## Stage 6", F28 F84).
#
#   bash scripts/check_readme.sh             check the README of this repo
#   bash scripts/check_readme.sh --selftest  break a copy in several ways and prove each is caught
#
# README_ROOT=<dir> checks another tree (used by the selftest and by guards.sh).
# Fails unless every section heading exists in order, every repo path the README names in
# backticks exists, the numbers in "## Settings and numbers" match the Swift constants,
# Config/Signing.xcconfig is named, and "3 apps", "Developer Mode" and "7 days" appear.
# bash 3.2 only. Never deletes or renames anything: the selftest edits fresh mktemp copies.

set -u

HEADINGS="What the app does and does not do
Before you start
Signing: free or paid
Install on your iPhone
Every 7 days (free team only)
First use
Settings and numbers
Where your audio lives and how to delete it
Consent
Before you switch team
Device checks
Going back
For developers"

# const FILE NAME: prints the number a Swift constant or default argument is set to.
const() {
    grep -oE "$2(: [A-Za-z]+ =|:| =) -?[0-9.]+" "$1" | head -1 | grep -oE -- '-?[0-9.]+$' | sed 's/\.0$//'
}

check_tree() {
    local root=$1 fails=0 readme line last=0 n hits p
    readme="$root/README.md"
    if [ ! -f "$readme" ]; then echo "FAIL README.md missing"; return 1; fi

    # 1. Every heading, as a "## " line, in the plan's order.
    while IFS= read -r h; do
        n=$(grep -nxF "## $h" "$readme" | head -1 | cut -d: -f1)
        if [ -z "$n" ]; then echo "FAIL heading missing: ## $h"; fails=$((fails + 1))
        elif [ "$n" -le "$last" ]; then echo "FAIL heading out of order: ## $h"; fails=$((fails + 1))
        else last=$n; fi
    done <<EOF
$HEADINGS
EOF
    [ $fails -eq 0 ] && echo "ok   all 13 headings, in order"

    # 2. Every repo path in backticks exists. Only names under the repo's own top folders count,
    # so life tracker paths and build/ output are not judged here.
    hits=""
    for p in $(grep -oE '`[^` ]+`' "$readme" | tr -d '`' | sort -u); do
        case "$p" in
            LTCapture/*|LTCaptureCore/*|LTCaptureTests/*|LTCapture.xcodeproj*|Config/*|scripts/*|README.md)
                [ -e "$root/$p" ] || hits="$hits $p" ;;
        esac
    done
    if [ -n "$hits" ]; then echo "FAIL paths named but missing:$hits"; fails=$((fails + 1)); else echo "ok   every repo path named exists"; fi

    # 3. The numbers table matches the constants.
    local audio="$root/LTCaptureCore/Sources/LTCaptureCore/Audio/AudioSettings.swift"
    local silence="$root/LTCaptureCore/Sources/LTCaptureCore/Capture/SilenceDetector.swift"
    local retention="$root/LTCaptureCore/Sources/LTCaptureCore/Receipt/Retention.swift"
    local rate
    rate=$(const "$audio" sampleRate)
    hits=""
    want() {   # want "LABEL" VALUE UNIT
        if [ -z "$2" ]; then hits="$hits [$1: constant not found]"
        elif ! grep -qxF "| $1 | $2 $3 |" "$readme"; then hits="$hits [$1 should be $2 $3]"; fi
    }
    want "Sample rate" "$([ -n "$rate" ] && echo $((rate / 1000)))" kHz
    want "Recording limit" "$(const "$audio" recordSeconds)" s
    want "Stop after you go quiet" "$(const "$silence" armedStopSeconds)" s
    want "Warning buzz before that stop" "$(const "$silence" armedWarnSeconds)" s
    want "Stop after a short start then quiet" "$(const "$silence" unarmedStopSeconds)" s
    want "Stop when nothing is heard at all" "$(const "$silence" nothingHeardStopSeconds)" s
    want "Never arms before" "$(const "$silence" armNotBeforeSeconds)" s
    want "Voice needed to arm" "$(const "$silence" armAfterVoicedSeconds)" s
    want "Quietest sound counted as voice" "$(const "$silence" voicedMinDB)" dBFS
    want "Voice must be above the room by" "$(const "$silence" voicedAboveFloorDB)" dB
    want "Outbox keeps a sent note for" "$(const "$retention" keepDays)" days
    if [ -n "$hits" ]; then echo "FAIL numbers differ from the code:$hits"; fails=$((fails + 1)); else echo "ok   11 numbers match the Swift constants"; fi

    # 4. The phrases the plan requires (F29, F84).
    hits=""
    for p in "Config/Signing.xcconfig" "3 apps" "Developer Mode" "7 days"; do
        grep -qF "$p" "$readme" || hits="$hits [$p]"
    done
    if [ -n "$hits" ]; then echo "FAIL required words missing:$hits"; fails=$((fails + 1)); else echo "ok   Config/Signing.xcconfig, 3 apps, Developer Mode, 7 days"; fi

    if [ $fails -gt 0 ]; then echo "check_readme: $fails failed"; return 1; fi
    echo "check_readme: all passed"
    return 0
}

copy_tree() {
    local src=$1 dst
    dst=$(mktemp -d "${TMPDIR:-/tmp}/ltcap-readme.XXXXXX") || return 1
    (cd "$src" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "$dst"
    echo "$dst"
}

selftest() {
    local src=$1 tmp missed=0
    tmp=$(copy_tree "$src")
    if (check_tree "$tmp" > /dev/null); then echo "ok   clean copy passes"
    else echo "FAIL the clean copy does not pass, so no break can be judged"; return 1; fi

    # breaks NAME SED-SCRIPT [FILE]: applies the edit to a fresh copy and expects a failure.
    breaks() {
        tmp=$(copy_tree "$src")
        sed -i '' "$2" "$tmp/${3:-README.md}"
        if (check_tree "$tmp" > /dev/null); then echo "MISSED $1"; missed=$((missed + 1)); else echo "caught $1"; fi
    }

    breaks "heading removed" '/^## Consent$/d'
    breaks "headings swapped" 's/^## Going back$/## Device checks TMP/; s/^## Device checks$/## Going back/; s/^## Device checks TMP$/## Device checks/'
    breaks "path that does not exist" 's/`scripts\/verify.sh`/`scripts\/verify-gone.sh`/'
    breaks "number changed in the README" 's/^| Stop after you go quiet | 20 s |$/| Stop after you go quiet | 25 s |/'
    breaks "constant changed in the code" 's/armedStopSeconds: TimeInterval = 20/armedStopSeconds: TimeInterval = 22/' \
        LTCaptureCore/Sources/LTCaptureCore/Capture/SilenceDetector.swift
    breaks "3 apps dropped" 's/3 apps/three apps/g'

    if [ $missed -gt 0 ]; then echo "selftest: $missed break(s) missed"; return 1; fi
    echo "selftest: all 6 breaks caught"
    return 0
}

ROOT=${README_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}

case "${1:-}" in
    --selftest) selftest "$ROOT" ;;
    "") check_tree "$ROOT" ;;
    *) echo "usage: $0 [--selftest]"; exit 2 ;;
esac
