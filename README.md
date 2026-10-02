# LT Capture (iOS)

LT Capture records a voice note on an iPhone and drops it into an iCloud Drive inbox, where a Mac picks it up and files it. Each note on screen then shows what the Mac actually did with it, read back from a receipt file the Mac writes.

By Cameron Mills. Designed and directed by me, with the code and its checks written by Claude Code agents to my specification. It is the phone end of my personal life tracker, a set of agents and scripts on my Mac.

Status: in progress. The app builds and its tests pass on the Mac, but it has not yet been installed on a phone, so the device checks below have not been run.

## What it is and why

My life tracker already took voice notes from iPhone shortcuts, and a shortcut can send the same audio file and sidecar. What the shortcuts lack is silence stop, surviving calls and interruptions, a safe resend, and the status of every note on screen. I wanted a recorder whose screen shows what actually happened to each note, rather than one that says "sent" and leaves me to guess.

The phone is a producer in a written file protocol, not a client of a server. The format is in `docs/PROTOCOL.md`: an AAC `.m4a` with a JSON sidecar in `life-tracker-inbox/audio/`, text notes in `life-tracker-inbox/`, and `life-tracker-out/captures.json` read back as the receipt. Any Mac-side program that follows that protocol can sit on the other end. Mine is private, so this repo ships the app and the two Mac-side checks it is tested against, in `tools/`.

## Architecture

The code is in two parts.

- `LTCaptureCore/` is a Swift package holding all the logic, tested on the Mac with no phone and no microphone. Recording is a pure state machine fed by presses, the audio session, a silence detector, the encoder, delivery and the app's own life cycle.
- `LTCapture/` is the SwiftUI app around it, and `LTCaptureTests/` holds its tests.

Delivery copies both files under hidden `.part` names that the Mac ignores, renames the audio, then the sidecar, then checks the size against the sidecar. The Mac side does not deduplicate, so the app resends a note only when neither the inbox nor its processed folder holds it and both listings were read. A status comes from the receipt first and from the file's location second, so a note is never called filed just from where it sits.

`tools/m4acheck.py` is the Mac's structural check of an `.m4a` (stdlib Python, no decoding), and `tools/header_ts.py` holds the text-note header pattern. `scripts/check_artefacts.sh` runs both over the files the host tests write.

## Requirements

- A Mac with Xcode 26 or later (the package uses Swift tools 6.2, and it was built with Xcode 27.0). The Command Line Tools alone are too old, so point `DEVELOPER_DIR` at Xcode.
- About 20 GB of free disk for the iOS simulator runtime and the first device connection.
- An iPhone on iOS 26 or later. To check, open Settings, General, About and read iOS Version.
- An Apple ID for signing, free or paid (see Signing below).
- Python 3.9 or later on the Mac, for `tools/m4acheck.py`.
- A program on the Mac that follows `docs/PROTOCOL.md`, if you want notes filed rather than just delivered. Without one, notes reach iCloud Drive and stay at "not taken yet".

## Setup, step by step

1. Clone this repo and open a Terminal in it.
2. Run the core tests to check the toolchain: `cd LTCaptureCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`. Expect 108 tests in 15 suites to pass.
3. Choose signing, free or paid (the section below). About 2 minutes.
4. Edit `Config/Signing.xcconfig` with your own team ID and bundle prefix.
5. Install on your iPhone (below). About 30 minutes the first time.
6. In iCloud Drive, create the folders `life-tracker-inbox`, `life-tracker-inbox/audio` and `life-tracker-out`. The app checks the names, so keep them exactly as written.
7. First use: pick the two folders, allow the microphone, send three test notes. About 10 minutes.
8. Run the device checks. About 30 minutes.
9. Optionally, move the iPhone's Action button to the app's action "Record a note". Do this only once both folders are picked, because the button records even while the setup screen is showing.

## Configuration

Signing is the only configuration file: `Config/Signing.xcconfig`, with `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX`. Keep your edit local. `scripts/guards.sh` refuses a committed team ID.

In the app, Settings has two switches ("Stop after silence" and "Mark captures as tests"), the two folders and the date signing lapses. The recording and silence numbers are constants in the Swift package, listed under Settings and numbers.

`scripts/check_artefacts.sh` uses the checks in `tools/` by default. Set `LTCAP_LIFE_TRACKER` to a checkout of a Mac side laid out like mine to check against its live scripts instead.

## Usage

Press the record button, or run the App Shortcut "Record a note", speak, then tap stop, run the shortcut again or go quiet. The note is encoded, copied into `life-tracker-inbox/audio/` with its sidecar, and its row moves from "sent" to "filed" once the Mac's receipt says so. The "Type a note" field sends a text note to `life-tracker-inbox/` instead.

## What the app does and does not do

It records one voice note per press, stops when you tap stop, run the shortcut again, or go quiet, and copies the finished note into iCloud Drive. Each note on the screen shows what the Mac did with it, read from `captures.json`, so you can see "filed" rather than guess. It also has a text field, sent as a text note that the Mac files like a dictation.

Some limits matter on day one:

- **Voice notes may wait on the Mac.** In my setup audio intake is off until I turn it on, and each voice note shows "waiting, audio off" and is kept safely. Text notes file straight away.
- **It is not one gesture from the lock screen.** The App Shortcut "Record a note" opens the app, so on a locked phone expect Face ID first. The count is press, unlock, speak, then stop (tap, press again, or let silence stop it).
- **It does not transcribe.** The Mac side does that for audio.
- **It sends no notifications.** Any "filed" alert has to come from the Mac side.
- **It records your voice only.** There is no mode for recording other people (see Consent).

## Before you start

You need the Mac, Xcode, the free disk and the iPhone from Requirements. Run step 2 of Setup first, because a toolchain problem is far quicker to find there than in a device build. To run the app's own simulator tests you also need the iOS simulator runtime (about 8 GB), which Xcode offers to download under Settings, Components.

## Signing: free or paid

The code is the same either way. Only the upkeep differs.

| Option | Cost | Weekly upkeep | What happens when it lapses |
|---|---|---|---|
| Paid Apple Developer Program | $99 a year | none | nothing, it renews with the membership |
| Free Personal Team | nothing | reconnect and run from Xcode every 7 days, about 5 to 10 minutes (an estimate, not measured) | the app will not open until you run it from Xcode again |

Apple's limits for a free team, from https://developer.apple.com/support/compare-memberships/ (read 30 Sep 2026): up to 3 apps per device, up to 10 App IDs and 3 devices, and provisioning profiles that "expire 7 days from issuance", after which you "rebuild and reinstall". The price is from https://developer.apple.com/programs/ (read the same day).

## Install on your iPhone

1. Open Xcode, then Settings, Accounts, and add your Apple ID with the plus button. A free Apple ID appears as a Personal Team.
2. Open `LTCapture.xcodeproj` from this repo.
3. Edit the two lines of `Config/Signing.xcconfig`. Set `DEVELOPMENT_TEAM` to your 10-character team ID, and `BUNDLE_ID_PREFIX` to any reverse-domain name of your own, such as `uk.co.yourname`. Bundle IDs are unique across all teams, so the example one will be refused. If you cannot find the team ID, choose your team in the Signing and Capabilities tab of the LTCapture target instead, which works as well but changes `LTCapture.xcodeproj/project.pbxproj`, so keep that change out of any commit.
4. Connect the phone by cable, unlock it, and tap Trust when it asks about this computer.
5. Turn on Developer Mode. Apple's steps, from https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device (read 30 Sep 2026): "In the Privacy & Security settings on the device, turn on the Developer Mode switch under Security", tap Restart, then after the restart "swipe up, tap Enable in the dialog, and enter your device passcode". If the switch is missing, connect the phone to Xcode once and look again.
6. In Xcode, choose your iPhone as the run destination and press Run. The first connection copies the phone's debug files to the Mac, which takes several minutes and several GB.
7. If the phone says "Untrusted Developer", open Settings, General, VPN & Device Management, tap your Apple ID under Developer App, and tap Trust. Then open the app again. Developers report this step for free Apple IDs in https://developer.apple.com/forums/thread/685271 (not an Apple answer), so expect it on a free team.

## Every 7 days (free team only)

A free team's profile lasts 7 days. From 36 hours before it lapses the app shows a banner, only while it is open, "LT Capture stops opening" with the date, and it writes `audio/lt-capture-install.txt` into the inbox with the install and expiry dates. Before that date, connect the phone to the Mac, open the project in Xcode and press Run. Notes on the phone are kept, because a reinstall from the same team keeps the app's data. If you miss the date the app will not open, but its notes are still on the phone and are sent after the next Run.

## First use

1. Open the app. It asks for `life-tracker-inbox` first, which is required, then `life-tracker-out`, which is optional. Pick each folder in iCloud Drive. Without the out folder the app still sends, but every note says "receipt folder not picked".
2. Press the record button. iOS asks for the microphone once. Allow it.
3. In Settings, turn on "Mark captures as tests", so each sidecar carries `"test": true`.
4. Send three notes: one text note with "Type a note", and two short voice notes.
5. Watch the statuses change. Text should reach "filed" once the Mac has run.
6. Turn "Mark captures as tests" off again.

What each status means:

| Status | Meaning |
|---|---|
| filed: (name) | the Mac filed it under that name |
| filed, worth a look: (name) | filed, but the Mac wants you to look |
| task failed (the Mac has the note) | the Mac took it but its task failed |
| waiting, audio off | the Mac has it and will transcribe once audio intake is on |
| received | the Mac has an entry in a state the app does not know |
| sent | copied into iCloud Drive in the last 3 minutes |
| not taken yet, is the Mac awake? | still in `audio/` after 3 minutes |
| taken, not yet filed | the Mac moved it to `audio/processed/`, under 45 minutes ago |
| not confirmed, check the vault | taken 45 minutes or more ago with no receipt entry |
| receipt folder not picked | you skipped `life-tracker-out` |
| no receipt yet | `captures.json` does not exist yet |
| unknown, will check again | iCloud Drive could not be listed just now |

Once the receipt has any entry for a note, the app never offers to send it again.

## Settings and numbers

Settings has two switches. "Stop after silence" is on by default, and "Mark captures as tests" is off. Below them are the two folders, where you pick either again, and the date signing lapses. With silence stop on, a note you do not stop yourself ends about 20 seconds after you finish speaking, so press stop (or the Action button again) when you are done.

| Setting | Value |
|---|---|
| Sample rate | 24 kHz |
| Recording limit | 599 s |
| Stop after you go quiet | 20 s |
| Warning buzz before that stop | 15 s |
| Stop after a short start then quiet | 10 s |
| Stop when nothing is heard at all | 30 s |
| Never arms before | 5 s |
| Voice needed to arm | 3 s |
| Quietest sound counted as voice | -55 dBFS |
| Voice must be above the room by | 10 dB |
| Outbox keeps a sent note for | 14 days |

The recording is linear PCM, then encoded to AAC-LC, mono, at 24 kHz and a constrained variable bit rate of 48 kbps nominal, and a note stops at 599 seconds, just under the Mac's 600-second cap. Silence stop listens for 3 seconds of voice, and never in the first 5 seconds, before it arms. Once armed, it buzzes after 15 seconds of quiet (only while the app is on screen) and stops at 20. If some voice was heard but it never armed, it stops 10 seconds after the last voice. If nothing was heard at all, it stops at 30 seconds, keeps the note and asks whether to discard it or keep and send it. A call or other interruption, an audio reset, or a lost microphone ends the note and sends what was recorded. It never resumes by itself.

Measured on the Mac, a 60-second speech-like tone encodes to 245,375 bytes, about 32.7 kbps, so a 10-minute note is about 2.5 MB. The test accepts 24 to 64 kbps for that tone. Real speech varies.

## Where your audio lives and how to delete it

A note can be in four places:

1. **On the phone**, in the app's outbox (`Library/Application Support/Outbox/`, one folder per note with the recording, the `.m4a`, its sidecar and a state file). It is excluded from iCloud Backup. The app deletes a sent note after 14 days, sooner once the Mac has filed it or finished checking it. Deleting the app deletes the outbox.
2. **In iCloud Drive**, `life-tracker-inbox/audio/`, until the Mac takes it.
3. **In iCloud Drive**, `life-tracker-inbox/audio/processed/` and, for text, `life-tracker-inbox/processed/`. The Mac never deletes these. Delete them by hand in the Files app or Finder when you no longer want them.
4. **Wherever the Mac side files it.** Delete those by hand like any other note.

## Consent

The app is for your own voice only, and every sidecar it writes says `"self_only": true`. It cannot tell your voice from anyone else's, because silence stop only hears levels. So a note left running while other people talk carries on to the 10-minute limit. Stop it yourself when others start talking, and check the recording rules where you are before you record anywhere shared.

## Before you switch team

Moving from a free team to a paid one, or back, makes iOS refuse the new install until you delete the old app, and deleting it deletes the outbox and the folder picks. So before you switch, open the app and let every note reach at least "sent". Then delete the app, change `Config/Signing.xcconfig`, press Run, and pick the two folders again.

## Device checks

Only a real phone can prove these, and none has been run yet. Do them with "Mark captures as tests" on, and note what each status says.

1. Lock the phone for 3 minutes in the middle of a note.
2. Take a call in the middle of a note.
3. Connect or remove AirPods in the middle of a note.
4. Let silence stop a note while the phone is locked.
5. Record in aeroplane mode, then turn it off and watch the note send.
6. Record, reboot the phone before it sends, then open the app.
7. Open `life-tracker-inbox/audio/processed/` in Files and check the note is there after the Mac takes it.
8. Time a full 10-minute note and check the Mac files it rather than keeping it as over 10 minutes.

## Going back

To put a shortcut back on the Action button (iPhone 15 Pro or later): Settings, Action Button, swipe to Shortcut, tap Choose a Shortcut, and pick it. Apple's steps are at https://support.apple.com/guide/shortcuts/run-shortcuts-with-the-action-button-apdfea15680b/ios. The app can stay installed alongside.

## For developers

The suite is `scripts/verify.sh`, run from a git checkout:

```
bash scripts/verify.sh --step 1   # host swift build and test of LTCaptureCore, then scripts/check_artefacts.sh
bash scripts/verify.sh --step 2   # simulator build-for-testing, Info.plist and Swift 6 checks
bash scripts/verify.sh --step 3   # unsigned build for a generic iPhone
bash scripts/verify.sh --step 4   # simulator tests (needs the iOS runtime)
bash scripts/verify.sh --step 5   # scripts/guards.sh, which also runs scripts/check_readme.sh
bash scripts/verify.sh --summary  # totals the five results for the current commit
bash scripts/verify.sh            # all five, then the summary
```

A step exits 0 for PASS, 1 for FAIL, 3 for NOT RUN and 4 for TIMED OUT (run it again, the build resumes). The summary exits 0 only when all five passed on the same commit with a clean tree, 1 on any fail, and 3 otherwise, and 3 is never green. Inside a sandboxed agent process step 1 prints NOT RUN because the AAC codec is hidden, so run it in Terminal. Step 4 prints NOT RUN until the iOS runtime is installed. `bash scripts/guards.sh --selftest` and `bash scripts/check_readme.sh --selftest` prove the checks catch what they should.

Comments in the code cite finding numbers (F12, F41 and so on) from the private build plan the agents worked to. They are kept as provenance, and each comment says what the rule is without needing the plan.

## Limitations

- Not yet installed on a phone. Everything above the device checks is proved on the Mac and in the simulator only.
- It needs a Mac side that follows `docs/PROTOCOL.md` to file anything.
- A free signing team means a reinstall from Xcode every 7 days.
- Silence stop hears levels, not voices.
- Text-note headers are written in Europe/Paris time, because the reference Mac reads them that way. If your Mac side reads another zone, change `HeaderTime.zone` in `LTCaptureCore/Sources/LTCaptureCore/Protocol/TimeFormat.swift`.

## Licence

MIT, see `LICENSE`.
