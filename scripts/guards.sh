#!/bin/bash
# House and design guards for LT Capture (plan.md "## Stage 1", "What guards.sh checks",
# and "## Stage 6" for the README check).
#
#   bash scripts/guards.sh             check the repo (tracked files plus new, not-ignored ones)
#   bash scripts/guards.sh --selftest  plant each violation in a copy and prove it is caught
#
# GUARDS_ROOT=<dir> checks another tree (used by the selftest).
# bash 3.2 only. Never deletes or renames anything: the selftest copies into fresh mktemp folders.

set -u

SELF_REL=scripts/guards.sh
# The only binary files allowed, each by exact path, and each must really be a PNG.
BINARY_ALLOW="LTCapture/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

# is_allowed_binary FILE: true when FILE is on the allow-list and is a PNG image.
is_allowed_binary() {
    local a
    for a in $BINARY_ALLOW; do
        if [ "$1" = "$a" ]; then
            case "$(file -b --mime-type "$1")" in image/png) return 0 ;; esac
        fi
    done
    return 1
}

guard_tree() {
    local root=$1 fails=0 f hits
    local dash
    dash=$(printf '\342\200\224')   # U+2014, spelled in octal so this file never holds one

    cd "$root" || return 1
    # Tracked files plus untracked ones that are not ignored, so new work is checked before commit.
    local files
    files=$(git ls-files --cached --others --exclude-standard | sort -u)

    # 1. No em dash in any text file.
    hits=""
    for f in $files; do
        [ -f "$f" ] || continue
        is_allowed_binary "$f" && continue   # compressed image bytes, not text
        if LC_ALL=C grep -q "$dash" "$f" 2>/dev/null; then hits="$hits $f"; fi
    done
    if [ -n "$hits" ]; then echo "FAIL em dash (U+2014) in:$hits"; fails=$((fails + 1)); else echo "ok   no em dash"; fi

    # 2. No binary file, except the app icon on BINARY_ALLOW.
    hits=""
    for f in $files; do
        [ -f "$f" ] || continue
        [ -s "$f" ] || continue   # an empty file reports charset=binary but holds nothing
        is_allowed_binary "$f" && continue
        case "$(file -b --mime "$f")" in
            *charset=binary*) hits="$hits $f" ;;
        esac
    done
    if [ -n "$hits" ]; then echo "FAIL binary file tracked:$hits"; fails=$((fails + 1)); else echo "ok   no binary file"; fi

    # 3. No committed team ID (F29): each developer sets their own in Config/Signing.xcconfig and keeps it local.
    hits=$(grep -nE 'DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*"?[A-Z0-9]{10}"?' \
        Config/Signing.xcconfig LTCapture.xcodeproj/project.pbxproj 2>/dev/null)
    if [ -n "$hits" ]; then echo "FAIL team ID committed: $hits"; fails=$((fails + 1)); else echo "ok   no team ID"; fi

    # 4. No AVAssetWriter, installTap or runtime download in app, core or scripts (F39, F38, F69).
    hits=""
    for f in $files; do
        [ -f "$f" ] || continue
        [ "$f" = "$SELF_REL" ] && continue
        case "$f" in
            LTCapture/*|LTCaptureCore/Sources/*|scripts/*)
                if grep -qE 'AVAssetWriter|installTap|downloadPlatform' "$f"; then hits="$hits $f"; fi ;;
        esac
    done
    if [ -n "$hits" ]; then echo "FAIL forbidden API (AVAssetWriter, installTap, downloadPlatform) in:$hits"; fails=$((fails + 1))
    else echo "ok   no AVAssetWriter, installTap or downloadPlatform"; fi

    # 5. No microphone in tests (F52): tests use synthetic PCM only.
    hits=""
    for f in $files; do
        [ -f "$f" ] || continue
        case "$f" in
            *Tests/*)
                if grep -qE 'AVAudioRecorder|AVAudioSession|AVCaptureDevice' "$f"; then hits="$hits $f"; fi ;;
        esac
    done
    if [ -n "$hits" ]; then echo "FAIL microphone API in tests:$hits"; fails=$((fails + 1))
    else echo "ok   no AVAudioRecorder, AVAudioSession or AVCaptureDevice in tests"; fi

    # 6. The README matches the project (plan.md "## Stage 6", F28, F84).
    if [ ! -f scripts/check_readme.sh ]; then echo "FAIL scripts/check_readme.sh missing"; fails=$((fails + 1))
    elif README_ROOT="$root" bash scripts/check_readme.sh > /dev/null; then echo "ok   README matches the project"
    else echo "FAIL README does not match the project (run bash scripts/check_readme.sh)"; fails=$((fails + 1)); fi

    if [ $fails -gt 0 ]; then echo "guards: $fails failed"; return 1; fi
    echo "guards: all passed"
    return 0
}

# copy_tree SRC: prints a fresh temporary copy of SRC's checked files, as a git repo.
copy_tree() {
    local src=$1 dst
    dst=$(mktemp -d "${TMPDIR:-/tmp}/ltcap-guards.XXXXXX") || return 1
    (cd "$src" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "$dst"
    git -C "$dst" init -q
    echo "$dst"
}

selftest() {
    local src=$1 tmp missed=0 name dash
    dash=$(printf '\342\200\224')

    tmp=$(copy_tree "$src")
    if (guard_tree "$tmp" > /dev/null); then echo "ok   clean copy passes"
    else echo "FAIL the clean copy does not pass, so no plant can be judged"; return 1; fi

    # plant NAME FILE CONTENT: writes CONTENT to FILE in a fresh copy and expects the guards to fail.
    plant() {
        name=$1
        tmp=$(copy_tree "$src")
        mkdir -p "$tmp/$(dirname "$2")"
        printf '%s\n' "$3" >> "$tmp/$2"
        if (guard_tree "$tmp" > /dev/null); then echo "MISSED $name"; missed=$((missed + 1)); else echo "caught $name"; fi
    }

    plant "em dash" notes.md "a note $dash with a dash"
    plant "team ID in xcconfig" Config/Signing.xcconfig "DEVELOPMENT_TEAM = ABCDE12345"
    plant "team ID in project" LTCapture.xcodeproj/project.pbxproj "DEVELOPMENT_TEAM = \"ZX9Y8W7V6U\";"
    plant "AVAssetWriter in app" LTCapture/Planted.swift "let w: AVAssetWriter? = nil"
    plant "installTap in core" LTCaptureCore/Sources/LTCaptureCore/Planted.swift "engine.inputNode.installTap(onBus: 0)"
    plant "downloadPlatform in scripts" scripts/planted.sh "xcodebuild -downloadPlatform iOS"
    plant "AVAudioSession in core tests" LTCaptureCore/Tests/LTCaptureCoreTests/Planted.swift "let s = AVAudioSession.sharedInstance()"
    plant "AVAudioRecorder in app tests" LTCaptureTests/Planted.swift "var r: AVAudioRecorder?"
    plant "AVCaptureDevice in app tests" LTCaptureTests/Planted2.swift "AVCaptureDevice.default(for: .audio)"

    # A binary file needs bytes printf %s cannot carry, so it is planted separately.
    name="binary file"
    tmp=$(copy_tree "$src")
    printf '\000\001\002\003\377\376' > "$tmp/blob.bin"
    if (guard_tree "$tmp" > /dev/null); then echo "MISSED $name"; missed=$((missed + 1)); else echo "caught $name"; fi

    # The icon's allow-list holds only for a real PNG at that exact path.
    name="non-PNG binary at the icon path"
    tmp=$(copy_tree "$src")
    mkdir -p "$tmp/LTCapture/Assets.xcassets/AppIcon.appiconset"
    printf '\000\001\002\003\377\376' > "$tmp/LTCapture/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    if (guard_tree "$tmp" > /dev/null); then echo "MISSED $name"; missed=$((missed + 1)); else echo "caught $name"; fi

    # A README fault is a removal, not an addition, so it is planted with sed.
    name="README heading removed"
    tmp=$(copy_tree "$src")
    sed -i '' '/^## Going back$/d' "$tmp/README.md"
    if (guard_tree "$tmp" > /dev/null); then echo "MISSED $name"; missed=$((missed + 1)); else echo "caught $name"; fi

    if [ $missed -gt 0 ]; then echo "selftest: $missed plant(s) missed"; return 1; fi
    echo "selftest: all 12 plants caught"
    return 0
}

ROOT=${GUARDS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}

case "${1:-}" in
    --selftest) selftest "$ROOT" ;;
    "") guard_tree "$ROOT" ;;
    *) echo "usage: $0 [--selftest]"; exit 2 ;;
esac
