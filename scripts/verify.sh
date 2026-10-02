#!/bin/bash
# The LT Capture test suite (plan.md "## Stage 1", target.md amendments A1 and A7).
#
#   bash scripts/verify.sh --step N   run one step (1 to 5), one foreground call each
#   bash scripts/verify.sh --summary  total the five results for the current HEAD
#   bash scripts/verify.sh            run steps 1 to 5, then the summary
#
# Steps: 1 host swift build and test of LTCaptureCore, 2 simulator build-for-testing
# plus Info.plist and Swift version checks, 3 unsigned generic iOS device build,
# 4 simulator test, 5 guards.
#
# Exit codes of a step: 0 PASS, 1 FAIL, 3 NOT RUN, 4 TIMED OUT (run it again, the build resumes).
# Exit codes of --summary: 0 when all five passed on this HEAD with a clean tree,
# 1 on any FAIL or TIMED OUT, 3 otherwise. Exit 3 is never green.
#
# bash 3.2 only. No deletion or renaming commands: results are overwritten with >,
# and build/ is git-ignored.

set -u

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

RESULTS=build/verify
mkdir -p "$RESULTS"

MIN_FREE_KB=${VERIFY_MIN_FREE_KB:-$((10 * 1024 * 1024))}   # 10 GB. The override exists to test the check.
ALARM_S=${VERIFY_ALARM_S:-540}          # under the agent's 600 s foreground cap. Override only to test.
PROJECT=LTCapture.xcodeproj
SCHEME=LTCapture
DD=build/dd
SPM=build/spm
# SwiftPM compiles Package.swift under sandbox-exec, and swift-frontend runs macro plugins
# (#Preview, @Observable) under it too. sandbox-exec cannot nest inside the agent sandbox
# ("sandbox-exec: sandbox_apply: Operation not permitted", proved in stage 1), so every
# xcodebuild call carries both flags. They change nothing in the built app, and Xcode on
# A normal Terminal login needs neither.
XB_FLAGS=(-IDEPackageSupportDisableManifestSandbox=YES 'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox')

head_hash() { git rev-parse HEAD 2>/dev/null || echo none; }
tree_dirty() { if [ -n "$(git status --porcelain 2>/dev/null)" ]; then echo 1; else echo 0; fi; }

# write_result STEP RESULT SECONDS
write_result() {
    {
        echo "result=$2"
        echo "head=$(head_hash)"
        echo "dirty=$(tree_dirty)"
        echo "seconds=$3"
    } > "$RESULTS/step-$1.result"
}

# run_long LOG CMD...: runs CMD under a perl alarm, appending output to LOG.
# Returns the command's exit code, or 142 when the alarm killed it.
run_long() {
    local log=$1
    shift
    echo "+ $*" >> "$log"
    perl -e 'alarm shift; exec @ARGV' "$ALARM_S" "$@" >> "$log" 2>&1
}

disk_ok() {
    local free_kb
    free_kb=$(df -k / | awk 'NR==2 {print $4}')
    if [ -z "$free_kb" ] || [ "$free_kb" -lt "$MIN_FREE_KB" ]; then
        echo "disk: $((${free_kb:-0} / 1024 / 1024)) GB free on /, the suite needs 10 GB"
        return 1
    fi
    return 0
}

# finish STEP RC NAME LOG START: prints the one line, writes the result, exits.
finish() {
    local step=$1 rc=$2 name=$3 log=$4 start=$5
    local secs=$((SECONDS - start))
    case "$rc" in
        0)   echo "PASS step $step $name (${secs}s)"; write_result "$step" PASS "$secs"; exit 0 ;;
        3)   write_result "$step" "NOT RUN" "$secs"; exit 3 ;;
        142) echo "TIMED OUT step $step $name after ${secs}s: run it again, the build resumes (log $log)"
             write_result "$step" "TIMED OUT" "$secs"; exit 4 ;;
        *)   echo "---- last 40 lines of $log"
             tail -n 40 "$log"
             echo "FAIL step $step $name (${secs}s, exit $rc, log $log)"
             write_result "$step" FAIL "$secs"; exit 1 ;;
    esac
}

step1() {
    local log=$RESULTS/step-1.log start=$SECONDS rc run
    : > "$log"
    disk_ok || finish 1 1 "host swift test" "$log" "$start"
    # A fresh folder per run for the tests' artefacts (plan Stage 2), so nothing is ever deleted.
    run=$ROOT/build/host-artefacts/run-$(date +%Y%m%d-%H%M%S)
    mkdir -p "$run"
    # --disable-sandbox: SwiftPM's sandbox-exec cannot nest inside the agent sandbox (plan P1).
    run_long "$log" xcrun swift build --disable-sandbox --build-tests \
        --package-path LTCaptureCore --scratch-path "$SPM"
    rc=$?
    [ $rc -ne 0 ] && finish 1 $rc "host swift build" "$log" "$start"
    LTCAP_ARTEFACTS=$run run_long "$log" xcrun swift test --disable-sandbox --skip-build \
        --package-path LTCaptureCore --scratch-path "$SPM"
    rc=$?
    # Inside the agent sandbox the Audio Component registrar is out of reach and no AAC codec
    # exists (found in build-2). When that sentinel is the run's one issue, the encode tests could
    # not run, which is NOT RUN like a missing simulator runtime, not a code failure. The Mac's
    # checks still run on the text and JSON artefacts, and a failure there is still a FAIL.
    if [ $rc -ne 0 ] && grep -q "LTCAP-NO-AAC-CODEC" "$log" \
        && grep -qE "^.? ?Test run with [0-9]+ tests? in [0-9]+ suites? failed .* with 1 issue\.$" "$log"; then
        run_long "$log" bash scripts/check_artefacts.sh "build/host-artefacts/$(basename "$run")"
        rc=$?
        [ $rc -ne 0 ] && finish 1 $rc "host swift test (no AAC codec) and artefact checks" "$log" "$start"
        echo "NOT RUN step 1 encode tests: no AAC codec in this process (agent sandbox); other host tests and artefact checks passed, run it in Terminal"
        finish 1 3 "host swift test" "$log" "$start"
    fi
    [ $rc -ne 0 ] && finish 1 $rc "host swift test" "$log" "$start"
    # The Mac's own checks on every file the tests wrote (F12).
    run_long "$log" bash scripts/check_artefacts.sh "build/host-artefacts/$(basename "$run")"
    rc=$?
    finish 1 $rc "host swift test and artefact checks" "$log" "$start"
}

step2() {
    local log=$RESULTS/step-2.log start=$SECONDS rc app
    : > "$log"
    disk_ok || finish 2 1 "simulator build" "$log" "$start"
    run_long "$log" xcodebuild "${XB_FLAGS[@]}" build-for-testing -project "$PROJECT" -scheme "$SCHEME" \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD"
    rc=$?
    [ $rc -ne 0 ] && finish 2 $rc "simulator build" "$log" "$start"
    app=$DD/Build/Products/Debug-iphonesimulator/LTCapture.app
    if ! plutil -extract NSMicrophoneUsageDescription raw -expect string "$app/Info.plist" >> "$log" 2>&1; then
        echo "Info.plist: NSMicrophoneUsageDescription missing or not a string" >> "$log"
        finish 2 1 "simulator build (Info.plist microphone key)" "$log" "$start"
    fi
    if ! plutil -extract UIBackgroundModes json -o - "$app/Info.plist" 2>> "$log" | grep -q '"audio"'; then
        echo "Info.plist: UIBackgroundModes does not contain audio" >> "$log"
        finish 2 1 "simulator build (Info.plist background audio)" "$log" "$start"
    fi
    # The scheme prints one block per target. Read only the app target's block.
    if ! xcodebuild "${XB_FLAGS[@]}" -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" 2>> "$log" \
        | awk '/^Build settings for / { app = ($0 ~ /target LTCapture:$/) } app' \
        | grep -qE '^ *SWIFT_VERSION = 6(\.0)?$'; then
        echo "build settings: SWIFT_VERSION is not 6 for the LTCapture target" >> "$log"
        finish 2 1 "simulator build (SWIFT_VERSION)" "$log" "$start"
    fi
    finish 2 0 "simulator build, Info.plist keys, Swift 6" "$log" "$start"
}

step3() {
    local log=$RESULTS/step-3.log start=$SECONDS rc
    : > "$log"
    disk_ok || finish 3 1 "unsigned device build" "$log" "$start"
    run_long "$log" xcodebuild "${XB_FLAGS[@]}" build -project "$PROJECT" -scheme "$SCHEME" \
        -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath "$DD"
    rc=$?
    finish 3 $rc "unsigned device build" "$log" "$start"
}

step4() {
    local log=$RESULTS/step-4.log start=$SECONDS rc runtimes udid runtime_id devtype
    : > "$log"
    disk_ok || finish 4 1 "simulator test" "$log" "$start"
    runtimes=$(xcrun simctl list runtimes 2>> "$log")
    rc=$?
    echo "$runtimes" >> "$log"
    if [ $rc -ne 0 ] || ! echo "$runtimes" | grep -q "iOS "; then
        echo "NOT RUN step 4 simulator test: no iOS simulator runtime"
        finish 4 3 "simulator test" "$log" "$start"
    fi
    udid=$(xcrun simctl list devices available 2>> "$log" \
        | sed -n 's/^ *iPhone[^(]*(\([0-9A-F-]\{36\}\)).*/\1/p' | head -n 1)
    if [ -z "$udid" ]; then
        # A runtime but no iPhone device yet: make one from the first iPhone type.
        runtime_id=$(echo "$runtimes" | grep "iOS " | sed -n 's/.* - \(com\.apple\.CoreSimulator\.SimRuntime\.[^ ]*\).*/\1/p' | tail -n 1)
        devtype=$(xcrun simctl list devicetypes 2>> "$log" \
            | sed -n 's/^iPhone.*(\(com\.apple\.CoreSimulator\.SimDeviceType\.[^)]*\)).*/\1/p' | tail -n 1)
        udid=$(xcrun simctl create "LT Capture test iPhone" "$devtype" "$runtime_id" 2>> "$log")
    fi
    if [ -z "$udid" ]; then
        echo "no iPhone simulator could be found or made" >> "$log"
        finish 4 1 "simulator test" "$log" "$start"
    fi
    run_long "$log" xcodebuild "${XB_FLAGS[@]}" test -project "$PROJECT" -scheme "$SCHEME" \
        -destination "id=$udid" -derivedDataPath "$DD"
    rc=$?
    finish 4 $rc "simulator test on $udid" "$log" "$start"
}

step5() {
    local log=$RESULTS/step-5.log start=$SECONDS rc
    : > "$log"
    disk_ok || finish 5 1 "guards" "$log" "$start"
    # The selftests run too, so a guard that stops catching its plant fails the suite.
    bash scripts/guards.sh >> "$log" 2>&1 \
        && bash scripts/guards.sh --selftest >> "$log" 2>&1 \
        && bash scripts/check_readme.sh --selftest >> "$log" 2>&1
    rc=$?
    finish 5 $rc "guards and their selftests" "$log" "$start"
}

summary() {
    local head dirty n f result rhead rdirty pass=0 fail=0 notrun=0
    head=$(head_hash)
    dirty=$(tree_dirty)
    for n in 1 2 3 4 5; do
        f=$RESULTS/step-$n.result
        if [ ! -f "$f" ]; then
            echo "step $n: no result"
            notrun=$((notrun + 1))
            continue
        fi
        result=$(sed -n 's/^result=//p' "$f")
        rhead=$(sed -n 's/^head=//p' "$f")
        rdirty=$(sed -n 's/^dirty=//p' "$f")
        if [ "$rhead" != "$head" ] || [ "$rdirty" != 0 ] || [ "$dirty" != 0 ]; then
            echo "step $n: $result, but not on a clean tree at $head, so it does not count"
            notrun=$((notrun + 1))
            continue
        fi
        echo "step $n: $result"
        case "$result" in
            PASS) pass=$((pass + 1)) ;;
            FAIL|"TIMED OUT") fail=$((fail + 1)) ;;
            *) notrun=$((notrun + 1)) ;;
        esac
    done
    echo "verify: $pass pass, $fail fail, $notrun not run at $head"
    [ $fail -gt 0 ] && exit 1
    [ $pass -eq 5 ] && exit 0
    exit 3
}

case "${1:-}" in
    --step)
        case "${2:-}" in
            1) step1 ;; 2) step2 ;; 3) step3 ;; 4) step4 ;; 5) step5 ;;
            *) echo "usage: $0 --step 1|2|3|4|5"; exit 2 ;;
        esac ;;
    --summary) summary ;;
    "")
        for n in 1 2 3 4 5; do
            bash "$0" --step "$n"
        done
        bash "$0" --summary ;;
    *) echo "usage: $0 [--step N | --summary]"; exit 2 ;;
esac
