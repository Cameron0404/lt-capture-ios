# Capture protocol: what a phone must write for the Mac to take it

Version 1. This is the file protocol between a producer (this app, or an iPhone shortcut) and the
Mac side that files the notes. The Mac side in the author's own setup is a private life tracker,
so it is described here by behaviour only. Two of its checks ship in this repo: `tools/m4acheck.py`
(the box check below) and `tools/header_ts.py` (the text-note header line).

Anything that writes files into iCloud Drive in the shape below is a producer. The Mac never
deletes a capture. Every file it takes is moved to a `processed/` folder and stays there.

## Folders

All in iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/` on a Mac).

| Folder | What goes there | Who writes it |
|---|---|---|
| `life-tracker-inbox/` | text notes | the phone |
| `life-tracker-inbox/audio/` | audio notes and their sidecars | the phone |
| `life-tracker-inbox/processed/` | text notes the Mac has taken | the Mac |
| `life-tracker-inbox/audio/processed/` | audio notes and sidecars the Mac has taken or kept | the Mac |
| `life-tracker-out/captures.json` | the receipt: what the Mac did with each capture | the Mac |

Audio has its own subfolder so that it is never mistaken for an attachment to a text note.

Files whose names start with `.` are never read. That covers iCloud's `.name.icloud`
placeholders and a producer's own temporary files, so a producer can write `.name.part` and
rename it when complete.

## Text notes

**Suffix.** `.txt`, `.md`, or no suffix. UTF-8.

**Name.** Both forms are accepted, and the name carries no meaning beyond the test prefix.

| Form | Example |
|---|---|
| Shortcuts' default | `Dictation - 1 Jan 2027 at 09:00.txt` |
| Seconds resolution | `dictation-2026-10-12-073015.txt` |

The second form is preferred, so two notes in one minute do not clash. A name beginning
`zz-test` marks a test: the Mac stamps it `test: true` and acts on nothing it asks for.

**Content.** An optional first line holding the moment spoken, `yyyy-MM-dd HH:mm` (seconds and
a `T` separator are also read) in the Mac side's own time zone (Europe/Paris for the reference
Mac), then the words verbatim. Without the header line the file's
modification time is used, which is the upload time, not the time spoken.

## Audio notes

**Format.** M4A holding AAC, suffix `.m4a`, nothing else. Other audio formats are not read.

**Name.** `YYYY-MM-DD-HHMMSS-NNNN.m4a`, the local time recording started and four digits that
make the name unique within a second, for example `2026-10-12-073015-4821.m4a`. The Mac does
not parse the name, so any `.m4a` not starting with `.` is taken, but a producer should write
this form.

**Length.** At most 600 seconds. Longer audio is kept and not transcribed.

### The sidecar

Beside each note, a JSON object with the same stem: `2026-10-12-073015-4821.json` for
`2026-10-12-073015-4821.m4a`. The Mac pairs the two by stem, then checks `audio_file`.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `audio_file` | string | yes | the note's file name as saved. If it is not the name the Mac found, the note is held for the owner with the reason `name mismatch`. |
| `capture_id` | string | yes | the producer's own id for the capture (a UUID is fine). Echoed in `captures.json` so the producer can match the receipt. |
| `spoken_at` | string | yes | ISO 8601 with offset, the moment recording started: `2026-10-12T07:30:15+02:00`. |
| `bytes` | number or string | yes | the note's size in bytes. Everything but digits is stripped first. The Mac's copy must be exactly this size. |
| `self_only` | boolean | no, default `true` | `true` says the recording holds the owner's voice only. `false` means kept, never transcribed. |
| `test` | boolean | no | a test capture. |
| `client_transcript` | string | no | the phone's own transcript, quoted beside the Mac's. |
| `mac_transcribe` | boolean | no, default `true` | `false` with a non-empty `client_transcript` means the phone's text is used and the Mac transcribes nothing. |
| `duration_s` | number | no | accepted and not used: the Mac measures the length itself. |

Write order: the audio first, then the sidecar. Neither write is a commit marker, because
iCloud may deliver them in either order and a file may arrive before its last byte does. The
completeness gates below are what decide.

### The two completeness gates

A note is taken only when both gates pass on the Mac's own copy:

1. **The box check.** `python3 tools/m4acheck.py FILE` prints `PASS ...`. It refuses a file cut
   short at any point, an empty sample table, zero-padded audio data, a fragmented file
   (`mvex`/`moof`), `co64` and a bad `stsc`. It accepts both layouts, index (`moov`) first or last.
2. **The decode.** `afconvert -f WAVE -d LEI16@16000` to a 16 kHz WAV exits 0.

Then, when `bytes` is given, the copy's size must equal it. A note that fails is left where it
is and tried again with a growing gap, and after eight failed tries it is marked failed.

### Orphans

- **Audio with no sidecar.** The Mac waits 300 s for the sidecar to sync, then takes the note
  alone with every sidecar default.
- **Sidecar with no audio.** Not read and not moved until its note arrives.

## Consent

A producer that records only its owner writes `self_only: true`. One that may record other
people writes `self_only: false`, and the Mac keeps that audio without transcribing it. The
Mac cannot check what is in a recording and does not try.

## The receipt: `life-tracker-out/captures.json`

Written by the Mac after every capture it handles, replaced whole with an atomic rename, so a
reader never sees half a file. The example below is invented.

```json
{
 "mac_seen_at": "2026-10-12T07:31:02+02:00",
 "captures": [
  {"name": "2026-10-12-073015-4821.m4a", "capture_id": "5B0E...", "status": "filed",
   "filed_as": "Book the bike service as reminder",
   "first_seen_at": "2026-10-12T07:30:40+02:00", "at": "2026-10-12T07:31:02+02:00"}
 ]
}
```

- `captures` holds the last 20, oldest first, one entry per file name.
- `status` is one of `filed`, `failed`, `waiting-audio-off`, `needs-cam` (the last means the
  Mac wants its owner to look, and the name is the Mac side's own).
- `capture_id` is present when the sidecar gave one. Text notes have none.
- `mac_seen_at` moves on every write, so a producer can tell a Mac that is asleep from one that
  has not reached its note yet.

The receipt is a courtesy. An unwritable folder is logged by the Mac and never stops a note.

## What a good app producer does

1. Record AAC into an `.m4a`, at most 600 s, and stop at the cap.
2. Write to a hidden name first (`.2026-10-12-073015-4821.m4a.part` in `audio/`), then rename
   to the final name. Write the sidecar the same way, after the audio.
3. Fill `audio_file`, `capture_id`, `spoken_at` and `bytes` from the file as written.
4. Send the phone's own transcript, if any, as `client_transcript`.
5. Show the capture as sent when the rename succeeds, and as filed only when
   `captures.json` has an entry with its `capture_id` and status `filed`.
6. Write text notes to the top folder as `dictation-yyyy-MM-dd-HHmmss.txt` with the time line
   first.
