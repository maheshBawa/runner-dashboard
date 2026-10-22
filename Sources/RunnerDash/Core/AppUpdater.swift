import Sparkle
import SwiftUI

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

/// Sparkle checks the appcast (SUFeedURL, signed with SUPublicEDKey) every hour. A scheduled find shows as the
/// "Update available" banner rather than a window popping up over your work; "Update now" hands over to Sparkle's
/// window, which shows the download and install progress, then relaunches.
final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var available: String?  // version a scheduled check found, until Sparkle's window takes over
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // A bare test binary has no Info.plist to read the feed from.
        controller = SPUStandardUpdaterController(startingUpdater: Bundle.main.bundleIdentifier != nil, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)  // a menu bar app's windows open behind the frontmost app otherwise
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { available = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { available = nil }

    func standardUserDriverWillFinishUpdateSession() { available = nil }
}
