#!/usr/bin/env python3
"""Is this .m4a complete? A structural check that decodes nothing.

    python3 tools/m4acheck.py FILE [--bytes N]

Prints `PASS <summary>` (exit 0) or `FAIL <code> <reason>` (exit 1). Any error inside the check
itself is `FAIL crash <type>: <message>` with exit 3, never a traceback: a file the check cannot
read is a bad file, and one bad file may cost that item, never the run.

Why. An audio note arrives through iCloud, and a file read before its upload or download has
finished can be short. `afconvert` alone is not proof: it decodes what it finds and may exit 0
on a file cut inside the audio data . So the dictation
loop takes a note only when BOTH gates pass: this box check, and `afconvert` to 16 kHz WAV with
exit 0. Then, when the sidecar gives `bytes`, the size must match exactly (docs/PROTOCOL.md).

The check:
- level 1: the top-level boxes tile the file exactly, with `ftyp`, `moov` and `mdat` present;
- no fragments (`mvex`, `moof`) and no 64-bit chunk offsets (`co64`): a phone voice note is
  neither, so either means a file this loop was not built for;
- level 2, for every track: `stsz`, `stsc` and `stco` are present and well formed, there is at
  least one sample, the chunk table maps every sample exactly once, and every chunk lies wholly
  inside an `mdat`;
- no sample is all zero bytes, and no run of ZERO_RUN zero bytes sits inside the sample data: a
  file that was cut and padded back to its full size with zeros (a sparse placeholder) keeps
  every box size right and fails here. AAC frames are compressed and never hold such a run.

Stdlib only. Compiles under 3.9.
"""

from __future__ import annotations

import struct
import sys

# `udta` is left out on purpose: it is metadata, QuickTime allows a 32-bit zero terminator
# inside it that is not a box, and nothing in it bears on whether the audio is whole.
CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"edts", b"dinf", b"mvex", b"moof", b"traf"}
ZERO_RUN = 64
EXIT_PASS, EXIT_FAIL, EXIT_CRASH = 0, 1, 3


class Bad(Exception):
    """A structural defect: (code, reason)."""

    def __init__(self, code: str, reason: str):
        super().__init__(f"{code} {reason}")
        self.code, self.reason = code, reason


def boxes(buf: bytes, start: int, end: int):
    """Yield (type, offset, size, header_len) for the boxes tiling [start, end)."""
    off = start
    while off < end:
        if end - off < 8:
            raise Bad("truncated", f"{end - off} trailing byte(s) at {off}")
        size, typ = struct.unpack(">I4s", buf[off:off + 8])
        hl = 8
        if size == 1:
            if end - off < 16:
                raise Bad("truncated", f"short 64-bit box size at {off}")
            size = struct.unpack(">Q", buf[off + 8:off + 16])[0]
            hl = 16
        elif size == 0:
            size = end - off                # "extends to the end of the file"
        if size < hl or off + size > end:
            raise Bad("truncated", f"box {typ.decode('latin-1')!r} at {off} size {size} overruns {end}")
        yield typ, off, size, hl
        off += size


def walk(buf: bytes, start: int, end: int, path: tuple, out: list) -> list:
    """Every box as (type, offset, size, header_len, parents)."""
    for typ, off, size, hl in boxes(buf, start, end):
        out.append((typ, off, size, hl, path))
        if typ in CONTAINERS:
            walk(buf, off + hl, off + size, path + ((typ, off),), out)
    return out


def _u32s(buf: bytes, at: int, n: int, end: int, what: str) -> tuple:
    if n < 0 or at + 4 * n > end:
        raise Bad("bad-table", f"{what} claims {n} entries, more than its box holds")
    return struct.unpack(f">{n}I", buf[at:at + 4 * n]) if n else ()


def _table(buf: bytes, box: tuple, what: str) -> tuple:
    """(payload start after version/flags, box end)."""
    _t, off, size, hl, _p = box
    p, end = off + hl, off + size
    if end - p < 8:
        raise Bad("bad-table", f"{what} box too short ({size} bytes)")
    return p + 4, end


def track_chunks(buf: bytes, stbl: list) -> tuple:
    """(samples, [(chunk_start, chunk_end, [sample sizes])]) for one sample table."""
    by = {}
    for b in stbl:
        by.setdefault(b[0], []).append(b)
    if b"co64" in by:
        raise Bad("co64", "64-bit chunk offsets, not a phone voice note")
    for need in (b"stsz", b"stsc", b"stco"):
        if len(by.get(need, [])) != 1:
            raise Bad("bad-table", f"{len(by.get(need, []))} {need.decode()} box(es) in one track")
    p, end = _table(buf, by[b"stsz"][0], "stsz")
    if end - p < 8:
        raise Bad("bad-table", "stsz too short")
    fixed, count = struct.unpack(">II", buf[p:p + 8])
    if count == 0:
        raise Bad("empty", "the track has no samples")
    sizes = [fixed] * count if fixed else list(_u32s(buf, p + 8, count, end, "stsz"))
    p, end = _table(buf, by[b"stco"][0], "stco")
    ncho = struct.unpack(">I", buf[p:p + 4])[0]
    chunks = _u32s(buf, p + 4, ncho, end, "stco")
    if not chunks:
        raise Bad("empty", "the chunk offset table is empty")
    p, end = _table(buf, by[b"stsc"][0], "stsc")
    ne = struct.unpack(">I", buf[p:p + 4])[0]
    flat = _u32s(buf, p + 4, 3 * ne, end, "stsc")
    ents = [flat[i:i + 3] for i in range(0, len(flat), 3)]
    if not ents or ents[0][0] != 1:
        raise Bad("bad-stsc", "the sample-to-chunk table does not start at chunk 1")
    for a, b in zip(ents, ents[1:]):
        if b[0] <= a[0]:
            raise Bad("bad-stsc", "sample-to-chunk entries out of order")
    if any(e[1] == 0 for e in ents) or ents[-1][0] > len(chunks):
        raise Bad("bad-stsc", "a chunk with no samples, or an entry past the last chunk")
    out, si, ei = [], 0, 0
    for ci, cofs in enumerate(chunks, 1):
        while ei + 1 < len(ents) and ents[ei + 1][0] <= ci:
            ei += 1
        spc = ents[ei][1]
        if si + spc > count:
            raise Bad("bad-stsc", f"chunk {ci} runs past the {count} samples")
        these = sizes[si:si + spc]
        si += spc
        out.append((cofs, cofs + sum(these), these))
    if si != count:
        raise Bad("bad-stsc", f"the chunks hold {si} samples, the size table {count}")
    return count, out


def check(path: str, want_bytes: int | None = None) -> tuple:
    """(True, summary) or (False, "<code> <reason>"). Raises only on a bug in this function;
    `main` turns that into exit 3."""
    with open(path, "rb") as fh:
        buf = fh.read()
    n = len(buf)
    try:
        if want_bytes is not None and n != want_bytes:
            raise Bad("size", f"{n} bytes, the sidecar says {want_bytes}")
        top = [(t, o, s) for t, o, s, _ in boxes(buf, 0, n)]
        types = [t for t, _, _ in top]
        for need in (b"ftyp", b"moov", b"mdat"):
            if need not in types:
                raise Bad("missing", f"no {need.decode()} box (top level {[t.decode('latin-1') for t in types]})")
        tree = walk(buf, 0, n, (), [])
        if any(t in (b"mvex", b"moof") for t, *_ in tree):
            raise Bad("fragmented", "a fragmented movie (mvex/moof)")
        mdats = [(o + 8, o + s) for t, o, s in top if t == b"mdat"]
        stbls = [(o, p) for t, o, s, h, p in tree if t == b"stbl"]
        if not stbls:
            raise Bad("missing", "no sample table")
        total = 0
        for so, _p in stbls:
            kids = [b for b in tree if b[4] and b[4][-1] == (b"stbl", so)]
            count, chunks = track_chunks(buf, kids)
            total += count
            for ci, (a, b, these) in enumerate(chunks, 1):
                if not any(lo <= a and b <= hi for lo, hi in mdats):
                    raise Bad("truncated", f"chunk {ci} [{a},{b}) is outside every mdat (file {n})")
                if b - a >= ZERO_RUN and buf.find(b"\0" * ZERO_RUN, a, b) != -1:
                    raise Bad("zero-padded", f"a run of {ZERO_RUN} zero bytes inside chunk {ci}")
                s = a
                for size in these:
                    if size and buf.count(0, s, s + size) == size:
                        raise Bad("zero-padded", f"an all-zero sample in chunk {ci}")
                    s += size
        return True, f"top={[t.decode('latin-1') for t in types]} samples={total} bytes={n}"
    except Bad as e:
        return False, f"{e.code} {e.reason}"


def main(argv: list) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    want = None
    try:
        if "--bytes" in argv:
            want = int(argv[argv.index("--bytes") + 1])
        ok, why = check(argv[0], want)
    except Exception as exc:  # noqa: BLE001 - no crash escapes, it is a FAIL with its own exit
        print(f"FAIL crash {type(exc).__name__}: {str(exc)[:200]}")
        return EXIT_CRASH
    print(("PASS " if ok else "FAIL ") + why)
    return EXIT_PASS if ok else EXIT_FAIL


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
