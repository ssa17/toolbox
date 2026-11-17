import AppKit
import Foundation

/// Centralized donation and sponsorship URLs for Toolbox.
enum SupportLinks {
    static let githubSponsors = URL(string: "https://github.com/sponsors/ssa17")!
    static let koFi = URL(string: "https://ko-fi.com/ssa17")!

    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
