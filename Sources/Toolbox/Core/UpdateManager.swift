import AppKit
import Foundation
import Sparkle

@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var isSparkleAvailable = false
    @Published private(set) var statusText = "Automatic checks enabled"
    @Published private(set) var lastCheckedAt: Date?

    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        configureSparkleIfBundled()
    }

    private func configureSparkleIfBundled() {
        // Sparkle requires running from a .app bundle with Info.plist and SUFeedURL.
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            statusText = "Available when running from Toolbox.app"
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = updaterController
        self.isSparkleAvailable = true
    }

    func checkForUpdates() {
        guard let controller else {
            statusText = "Run from Toolbox.app bundle to check for updates"
            return
        }
        statusText = "Checking for updates…"
        lastCheckedAt = Date()
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.statusText = "You're on the latest version"
            self.lastCheckedAt = Date()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.statusText = "Update available: v\(version)"
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.statusText = "Update check unavailable (\(message))"
        }
    }
}
