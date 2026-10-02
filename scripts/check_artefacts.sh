#!/bin/bash
# Runs the Mac side's own checks on what the host tests wrote.
#
#   bash scripts/check_artefacts.sh [RUN_DIR]
#
# RUN_DIR defaults to the newest build/host-artefacts/run-*/. The script gathers every
# *.entry.json in it into build/host-artefacts/manifest.json, then for each entry:
#   m4a   tools/m4acheck.py FILE --bytes N must PASS or FAIL as the entry expects, and a
#         duration range is measured the Mac's way: afconvert -f WAVE -d LEI16@16000, then
#         round(frames/16000, 1)
#   json  spoken_at parses with datetime.fromisoformat under /usr/bin/python3 and
#         /opt/homebrew/bin/python3, bytes is an int, and the keys are the protocol's
#   txt   line 1 matches HEADER_TS, read from tools/header_ts.py (or the live
#         dictation_intake.py when LTCAP_LIFE_TRACKER is set)
# Exit 0 only when there is at least one entry and every entry behaves as expected.
#
# bash 3.2. Nothing is deleted: decoded WAVs are written beside the artefacts in build/.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# By default the checks use the copies in tools/. Set LTCAP_LIFE_TRACKER to a life
# tracker checkout to check against the live Mac-side scripts there instead.
if [ -n "${LTCAP_LIFE_TRACKER:-}" ]; then
    M4ACHECK="$LTCAP_LIFE_TRACKER/_meta/scripts/m4acheck.py"
    INTAKE="$LTCAP_LIFE_TRACKER/_meta/scripts/dictation_intake.py"
else
    M4ACHECK="$ROOT/tools/m4acheck.py"
    INTAKE="$ROOT/tools/header_ts.py"
fi
cd "$ROOT" || exit 1
BASE=build/host-artefacts

for need in "$M4ACHECK" "$INTAKE"; do
    if [ ! -f "$need" ]; then
        echo "FAIL check_artefacts: the Mac's checker is missing: $need"
        exit 1
    fi
done

RUN=${1:-}
if [ -z "$RUN" ]; then
    RUN=$(ls -d "$BASE"/run-* 2>/dev/null | sort | tail -n 1)
fi
if [ -z "$RUN" ] || [ ! -d "$RUN" ]; then
    echo "FAIL check_artefacts: no run folder under $BASE (run bash scripts/verify.sh --step 1)"
    exit 1
fi

/usr/bin/python3 - "$ROOT/$BASE" "$RUN" "$M4ACHECK" "$INTAKE" <<'PY'
import ast, glob, json, os, re, subprocess, sys

base, run, m4acheck, intake = sys.argv[1:5]
run = os.path.join(os.getcwd(), run) if not os.path.isabs(run) else run

entries = []
for f in sorted(glob.glob(os.path.join(run, "*.entry.json"))):
    with open(f) as fh:
        entries.append(json.load(fh))
with open(os.path.join(base, "manifest.json"), "w") as fh:
    json.dump(entries, fh, indent=1, sort_keys=True)
print(f"manifest: {len(entries)} entries from {os.path.relpath(run, base)}")

# HEADER_TS as the Mac defines it today, not a copy.
src = open(intake).read()
header_ts = None
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "HEADER_TS" for t in node.targets):
        header_ts = re.compile(ast.literal_eval(node.value.args[0]))
if header_ts is None:
    print(f"FAIL check_artefacts: no HEADER_TS in {intake}")
    sys.exit(1)

KEYS = {"audio_file", "capture_id", "spoken_at", "bytes", "self_only", "test", "duration_s"}
REQUIRED = {"audio_file", "capture_id", "spoken_at", "bytes", "self_only"}
PYTHONS = [p for p in ("/usr/bin/python3", "/opt/homebrew/bin/python3") if os.path.exists(p)]

bad = 0
def report(ok, entry, why):
    global bad
    if not ok:
        bad += 1
    print(f"{'ok ' if ok else 'BAD'} {entry['kind']:4} expect {entry['expect']:4} {entry['path']}: {why}")

for e in entries:
    path = os.path.join(base, e["path"])
    kind, expect = e["kind"], e["expect"]
    if not os.path.exists(path):
        report(False, e, "file missing")
        continue
    if kind == "m4a":
        args = ["/usr/bin/python3", m4acheck, path]
        if "bytes" in e:
            args += ["--bytes", str(e["bytes"])]
        p = subprocess.run(args, capture_output=True, text=True)
        verdict = p.stdout.strip()
        got = "pass" if p.returncode == 0 else ("fail" if p.returncode == 1 else "crash")
        if got != expect:
            report(False, e, f"m4acheck exit {p.returncode}: {verdict}")
            continue
        why = f"m4acheck {verdict}"
        if "duration_min" in e or "duration_max" in e:
            # afinfo, not afconvert to WAV: afconvert writes WAVE_FORMAT_EXTENSIBLE (65534) on this
            # macOS, which the system Python 3.9 wave module refuses (verify step 1, 1 Oct 2026).
            d = subprocess.run(["afinfo", path], capture_output=True, text=True)
            m = re.search(r"estimated duration:\s*([0-9.]+)\s*sec", d.stdout)
            if d.returncode != 0 or not m:
                report(False, e, f"afinfo exit {d.returncode}, no estimated duration: {d.stderr.strip()[:200]}")
                continue
            secs = round(float(m.group(1)), 1)
            lo, hi = e.get("duration_min", 0), e.get("duration_max", float("inf"))
            if not (lo <= secs <= hi):
                report(False, e, f"measured {secs} s, wanted {lo} to {hi}")
                continue
            why += f", measured {secs} s"
        if "kbps" in e:
            why += f", {e['kbps']} kbps"
        report(True, e, why)
    elif kind == "json":
        with open(path) as fh:
            obj = json.load(fh)
        problems = []
        if not REQUIRED <= set(obj) or not set(obj) <= KEYS:
            problems.append(f"keys {sorted(obj)}")
        if type(obj.get("bytes")) is not int:
            problems.append(f"bytes is {type(obj.get('bytes')).__name__}")
        if not PYTHONS:
            problems.append("no python3 to parse spoken_at")
        for py in PYTHONS:
            p = subprocess.run([py, "-c", "import sys, datetime; datetime.datetime.fromisoformat(sys.argv[1])",
                                str(obj.get("spoken_at"))], capture_output=True, text=True)
            if p.returncode != 0:
                problems.append(f"{py} refuses spoken_at {obj.get('spoken_at')!r}")
        ok = not problems
        if expect == "fail":
            ok = not ok
        report(ok, e, "; ".join(problems) or f"spoken_at {obj['spoken_at']} parses under {len(PYTHONS)} python(s), bytes int")
    elif kind == "txt":
        with open(path) as fh:
            first = fh.readline().rstrip("\n")
        matched = bool(header_ts.match(first))
        report(matched == (expect == "pass"), e, f"line 1 {first!r} {'matches' if matched else 'does not match'} HEADER_TS")
    else:
        report(False, e, f"unknown kind {kind}")

if not entries:
    print("FAIL check_artefacts: the run folder has no entries")
    sys.exit(1)
print(f"check_artefacts: {len(entries) - bad} of {len(entries)} as expected")
sys.exit(1 if bad else 0)
PY
