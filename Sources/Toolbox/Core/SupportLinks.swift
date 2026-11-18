import AppKit
import Foundation
import SwiftUI

/// Centralized donation, sponsorship, and community URLs for Toolbox.
enum SupportLinks {
    static let githubSponsors = URL(string: "https://github.com/sponsors/ssa17")!
    static let koFi = URL(string: "https://ko-fi.com/ssa17")!
    static let githubRepo = URL(string: "https://github.com/ssa17/toolbox")!
    static let githubIssues = URL(string: "https://github.com/ssa17/toolbox/issues")!

    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Persists local, privacy-friendly Support page interactions (high-fives and honor-system supporter badge).
@MainActor
final class SupportState: ObservableObject {
    static let shared = SupportState()

    private static let highFiveKey = "toolbox.support.highFiveCount"
    private static let supporterKey = "toolbox.support.isSupporterUnlocked"

    @Published private(set) var highFiveCount: Int
    @Published private(set) var isSupporterUnlocked: Bool

    private let userDefaults: UserDefaults?

    init(userDefaults: UserDefaults? = .standard) {
        self.userDefaults = userDefaults
        self.highFiveCount = max(0, userDefaults?.integer(forKey: Self.highFiveKey) ?? 0)
        self.isSupporterUnlocked = userDefaults?.bool(forKey: Self.supporterKey) ?? false
    }

    @discardableResult
    func sendHighFive() -> Int {
        highFiveCount += 1
        userDefaults?.set(highFiveCount, forKey: Self.highFiveKey)
        return highFiveCount
    }

    func toggleSupporterBadge() {
        isSupporterUnlocked.toggle()
        userDefaults?.set(isSupporterUnlocked, forKey: Self.supporterKey)
    }

    /// Playful milestone copy shown after tapping High-Five.
    var highFiveStatusMessage: String? {
        guard highFiveCount > 0 else { return nil }
        switch highFiveCount {
        case 1:
            return "High-five caught! Zero telemetry, maximum good vibes."
        case 2...4:
            return "\(highFiveCount)× combo! Your Dock icons approve."
        case 5...9:
            return "\(highFiveCount)× combo! Official Toolbox hype squad."
        case 10...24:
            return "\(highFiveCount)× combo! Bugs fear your enthusiasm."
        default:
            return "\(highFiveCount)× combo! Legendary supporter energy."
        }
    }
}
