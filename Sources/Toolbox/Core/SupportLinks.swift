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

/// Playful, Toolbox-specific causes users can choose when supporting development.
enum SupportFuelTier: String, CaseIterable, Identifiable, Sendable {
    case espresso
    case notarization
    case nextModule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .espresso: return "Bug-Squash Espresso"
        case .notarization: return "Notarization Fund"
        case .nextModule: return "Next Module Lab"
        }
    }

    var badgeText: String {
        switch self {
        case .espresso: return "Quick Boost"
        case .notarization: return "$99/yr Cert"
        case .nextModule: return "New Tools"
        }
    }

    var symbolName: String {
        switch self {
        case .espresso: return "cup.and.saucer.fill"
        case .notarization: return "checkmark.seal.fill"
        case .nextModule: return "wrench.and.screwdriver.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .espresso: return .orange
        case .notarization: return .blue
        case .nextModule: return .purple
        }
    }

    var description: String {
        switch self {
        case .espresso:
            return "Fuels late-night fixes for weird macOS quirks, Dock drags, and focus edge cases."
        case .notarization:
            return "Helps cover the $99/yr Apple Developer ID so every DMG passes Gatekeeper cleanly."
        case .nextModule:
            return "Backs brand-new utilities, Sparkle updates, and keeping Toolbox 100% local & bloat-free."
        }
    }

    var devReaction: String {
        switch self {
        case .espresso:
            return "Developer reaction: +10% focus on stubborn macOS Accessibility edge cases."
        case .notarization:
            return "Developer reaction: Keeps Apple's $99/yr Developer ID happy & warning-free."
        case .nextModule:
            return "Developer reaction: Unlocked 2 AM ideas for the next Toolbox utility."
        }
    }

    var checkoutNote: String {
        switch self {
        case .espresso: return "For late-night bug-squash espresso ☕"
        case .notarization: return "For the Apple Notarization fund 🛡️"
        case .nextModule: return "For the next Toolbox utility ⚡"
        }
    }
}

/// Persists local, privacy-friendly Support page interactions (high-fives and honor-system supporter badge).
@MainActor
final class SupportState: ObservableObject {
    static let shared = SupportState()

    private static let highFiveKey = "toolbox.support.highFiveCount"
    private static let supporterKey = "toolbox.support.isSupporterUnlocked"
    private static let selectedFuelKey = "toolbox.support.selectedFuel"

    @Published private(set) var highFiveCount: Int
    @Published private(set) var isSupporterUnlocked: Bool
    @Published var selectedFuel: SupportFuelTier {
        didSet {
            userDefaults?.set(selectedFuel.rawValue, forKey: Self.selectedFuelKey)
        }
    }

    private let userDefaults: UserDefaults?

    init(userDefaults: UserDefaults? = .standard) {
        self.userDefaults = userDefaults
        self.highFiveCount = max(0, userDefaults?.integer(forKey: Self.highFiveKey) ?? 0)
        self.isSupporterUnlocked = userDefaults?.bool(forKey: Self.supporterKey) ?? false
        if let raw = userDefaults?.string(forKey: Self.selectedFuelKey),
           let tier = SupportFuelTier(rawValue: raw) {
            self.selectedFuel = tier
        } else {
            self.selectedFuel = .espresso
        }
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
