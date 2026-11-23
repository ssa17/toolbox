import AppKit
import Foundation
import SwiftUI

/// Centralized donation, sponsorship, and community URLs for Toolbox.
enum SupportLinks {
    static let githubSponsors = URL(string: "https://github.com/sponsors/ssa17")!
    static let koFi = URL(string: "https://ko-fi.com/ssa17")!
    static let githubRepo = URL(string: "https://github.com/ssa17/toolbox")!
    static let githubIssues = URL(string: "https://github.com/ssa17/toolbox/issues")!
    static let githubReleases = URL(string: "https://github.com/ssa17/toolbox/releases")!

    /// GitHub release page for a specific version tag (e.g. v1.6.1).
    static func githubReleaseNotesURL(version: String) -> URL {
        URL(string: "https://github.com/ssa17/toolbox/releases/tag/v\(version)") ?? githubReleases
    }

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
    private var baseDockIcon: NSImage?

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
        if self === SupportState.shared {
            syncDockIconBadge()
        }
    }

    /// Updates the live Dock / App Switcher icon with a custom-tinted Supporter icon and heart badge.
    func syncDockIconBadge() {
        guard !PermissionsManager.isRunningInDiagnosticMode,
              NSApp.activationPolicy() != .prohibited else { return }
        if baseDockIcon == nil {
            baseDockIcon = Self.loadBaseDockIcon()
        }
        guard let base = baseDockIcon else { return }
        NSApp.applicationIconImage = isSupporterUnlocked ? Self.makeSupporterDockIcon(from: base) : base
    }

    private static func loadBaseDockIcon() -> NSImage? {
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icnsImage = NSImage(contentsOf: icnsURL) {
            return icnsImage
        }
        if let named = NSImage(named: NSImage.applicationIconName) {
            return named.copy() as? NSImage
        }
        return NSApp.applicationIconImage?.copy() as? NSImage
    }

    static func makeSupporterDockIcon(from base: NSImage) -> NSImage {
        let pxSize = 512
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxSize,
            pixelsHigh: pxSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return base
        }

        rep.size = NSSize(width: pxSize, height: pxSize)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            base.draw(
                in: NSRect(x: 0, y: 0, width: pxSize, height: pxSize),
                from: NSRect(origin: .zero, size: base.size),
                operation: .copy,
                fraction: 1.0
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.bitmapData {
            let bpr = rep.bytesPerRow
            for y in 0..<pxSize {
                let rowOffset = y * bpr
                for x in 0..<pxSize {
                    let i = rowOffset + x * 4
                    let a = data[i + 3]
                    guard a > 0 else { continue }

                    let r = Double(data[i])
                    let g = Double(data[i + 1])
                    let b = Double(data[i + 2])
                    let alpha = Double(a) / 255.0

                    // Un-premultiply for accurate color classification
                    let ur = min(255.0, r / alpha)
                    let ug = min(255.0, g / alpha)
                    let ub = min(255.0, b / alpha)

                    var nr = ur
                    var ng = ug
                    var nb = ub

                    // Sky-blue Bento accent square -> Supporter Gold (smoothly blended by blueness)
                    let blueDominance = ub - max(ur, ug)
                    if blueDominance > 12 {
                        let t = min(1.0, (blueDominance - 12.0) / 60.0)
                        let targetR = 245.0
                        let targetG = 184.0
                        let targetB = 61.0
                        nr = ur * (1.0 - t) + targetR * t
                        ng = ug * (1.0 - t) + targetG * t
                        nb = ub * (1.0 - t) + targetB * t
                    } else if ur < 130 && ug < 130 && ub < 140 {
                        // Dark slate squircle -> subtle warm obsidian-charcoal Supporter background
                        nr = min(255.0, ur * 1.18 + 4.0)
                        ng = min(255.0, ug * 1.04 + 2.0)
                        nb = max(0.0, ub * 0.86)
                    }

                    data[i] = UInt8(max(0, min(255, Int((nr * alpha).rounded()))))
                    data[i + 1] = UInt8(max(0, min(255, Int((ng * alpha).rounded()))))
                    data[i + 2] = UInt8(max(0, min(255, Int((nb * alpha).rounded()))))
                }
            }
        }

        let canvasSize = NSSize(width: pxSize, height: pxSize)
        let result = NSImage(size: canvasSize)
        result.lockFocus()
        defer { result.unlockFocus() }

        rep.draw(in: NSRect(origin: .zero, size: canvasSize))

        let badgeRect = NSRect(x: 346, y: 28, width: 136, height: 136)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 10
        shadow.set()

        let badgePath = NSBezierPath(ovalIn: badgeRect)
        let gradient = NSGradient(
            starting: NSColor(calibratedRed: 1.0, green: 0.24, blue: 0.52, alpha: 1.0),
            ending: NSColor(calibratedRed: 0.88, green: 0.14, blue: 0.42, alpha: 1.0)
        )
        gradient?.draw(in: badgePath, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.94).setStroke()
        badgePath.lineWidth = 5.5
        badgePath.stroke()

        let symConfig = NSImage.SymbolConfiguration(pointSize: 66, weight: .bold)
        if let heart = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Supporter")?
            .withSymbolConfiguration(symConfig) {
            let tinted = NSImage(size: heart.size)
            tinted.lockFocus()
            NSColor.white.set()
            let r = NSRect(origin: .zero, size: heart.size)
            heart.draw(in: r)
            r.fill(using: .sourceAtop)
            tinted.unlockFocus()

            let drawRect = NSRect(
                x: badgeRect.midX - tinted.size.width / 2,
                y: badgeRect.midY - tinted.size.height / 2 - 2,
                width: tinted.size.width,
                height: tinted.size.height
            )
            tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        return result
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
