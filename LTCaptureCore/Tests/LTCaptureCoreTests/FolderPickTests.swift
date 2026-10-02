import Foundation
import Testing
@testable import LTCaptureCore

/// The folder pick (plan F4): the name check, the target that outlives `isPresented`, and what the
/// setup screen enables.
struct FolderPickTests {
    @Test func lastComponentIgnoresTrailingSlashes() {
        #expect(FolderName.lastComponent(of: "/a/b/life-tracker-inbox") == "life-tracker-inbox")
        #expect(FolderName.lastComponent(of: "/a/b/life-tracker-inbox/") == "life-tracker-inbox")
        #expect(FolderName.lastComponent(of: "/a/b/life-tracker-inbox//") == "life-tracker-inbox")
        #expect(FolderName.lastComponent(of: "life-tracker-inbox") == "life-tracker-inbox")
        #expect(FolderName.lastComponent(of: "/") == "")
        #expect(FolderName.lastComponent(of: "") == "")
    }

    @Test func aPickedDirectoryURLMatches() {
        let plain = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/life-tracker-inbox")
        let dir = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/life-tracker-inbox/", isDirectory: true)
        let dotted = URL(fileURLWithPath: "/tmp/x/../life-tracker-inbox/./", isDirectory: true)
        for url in [plain, dir, dotted] {
            #expect(FolderName.matches(url, expected: "life-tracker-inbox"), "\(url)")
            #expect(FolderName.name(of: url) == "life-tracker-inbox")
        }
        #expect(FolderName.matches(URL(string: "file:///iCloud/Life-Tracker-Inbox/")!, expected: "life-tracker-inbox"))
    }

    @Test func theWrongFolderDoesNotMatch() {
        #expect(!FolderName.matches(URL(fileURLWithPath: "/iCloud/life-tracker-out/"), expected: "life-tracker-inbox"))
        #expect(!FolderName.matches(URL(fileURLWithPath: "/iCloud/life-tracker-inbox/audio/"), expected: "life-tracker-inbox"))
        #expect(!FolderName.matches(URL(fileURLWithPath: "/iCloud/"), expected: "life-tracker-inbox"))
        #expect(!FolderName.matches("life-tracker-inbox 2", expected: "life-tracker-inbox"))
    }

    @Test func theTargetSurvivesTheBindingAndIsTakenOnce() {
        var r = PickRequest<String>()
        #expect(r.take() == nil)
        r.begin("inbox")
        // The binding goes false here, before the completion: the request is untouched by it.
        #expect(r.target == "inbox")
        #expect(r.take() == "inbox")
        #expect(r.take() == nil)
        r.begin("inbox")
        r.begin("out")
        #expect(r.take() == "out")
    }

    @Test func nothingIsEnabledBeforeTheInbox() {
        for out in [BookmarkState.notPicked, .ready, .pickAgain] {
            for inbox in [BookmarkState.notPicked, .pickAgain] {
                let g = OnboardingGate(inbox: inbox, out: out)
                #expect(!g.canStart && !g.canPickOut && !g.canSkipOut)
            }
        }
    }

    @Test func theInboxAloneEnablesPickOutSkipAndStart() {
        for inbox in [BookmarkState.ready, .needsResave] {
            let g = OnboardingGate(inbox: inbox, out: .notPicked)
            #expect(g.inboxDone && g.canPickOut && g.canStart && g.canSkipOut)
            #expect(g.startTitle == "Skip the receipt folder and start")
        }
    }

    @Test func aFailedOutPickNeverBlocksTheStart() {
        let g = OnboardingGate(inbox: .ready, out: .pickAgain)
        #expect(g.canStart && g.canSkipOut && !g.outDone)
        #expect(g.startTitle == "Skip the receipt folder and start")
    }

    @Test func bothPickedSaysStart() {
        let g = OnboardingGate(inbox: .ready, out: .ready)
        #expect(g.canStart && !g.canSkipOut && g.outDone)
        #expect(g.startTitle == "Start")
    }
}
