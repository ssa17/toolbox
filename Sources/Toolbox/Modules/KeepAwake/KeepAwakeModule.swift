import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import SwiftUI

struct MacPowerSleepInfo: Equatable, Sendable {
    var activeDisplaySleepMinutes: Int?
    var acDisplaySleepMinutes: Int?
    var batteryDisplaySleepMinutes: Int?

    var summaryText: String {
        if let active = activeDisplaySleepMinutes {
            if active == 0 {
                return "Display sleep is currently set to Never (0 min)"
            }
            var details: [String] = ["Current: \(active) min"]
            if let ac = acDisplaySleepMinutes { details.append("AC: \(ac == 0 ? "Never" : "\(ac)m")") }
            if let bat = batteryDisplaySleepMinutes { details.append("Battery: \(bat == 0 ? "Never" : "\(bat)m")") }
            return details.joined(separator: " · ")
        }
        return "Could not read pmset display sleep"
    }
}

@MainActor
final class KeepAwakeModule: ToolboxModule, ObservableObject {
    let id = "keep_awake"
    let name = "Keep Awake"
    let tagline = "Reads your Mac's display sleep timer and nudges or holds an assertion just in time."
    let aboutSummary = "Keeps your Mac awake during long builds, downloads, or presentations. Smart Mouse Jiggle reads your Mac's actual display sleep timeout via pmset and gently nudges the cursor 1px just before the screen would turn off, never interfering while you're actively working."
    let featureTips = [
        "Use 'Smart Mouse Jiggle' if corporate screen-lock policies or Slack/Teams ignore standard sleep assertions.",
        "Use 'Power Assertion' when you want zero cursor movement while preventing idle sleep.",
        "Toggle anytime with your shortcut or from the Status Bar menu."
    ]
    let symbolName = "bolt.circle"
    let accentColor = Color.orange
    let category: ModuleCategory = .system
    let requiresAccessibility = false
    let accessibilityReason = "No Accessibility permission required."

    @Published private(set) var isRunning = false
    @Published private(set) var isAwakeActive = false
    @Published private(set) var expiresAt: Date?
    @Published private(set) var powerInfo = MacPowerSleepInfo()
    @Published private(set) var currentIdleSeconds: Int = 0
    @Published private(set) var nextJiggleInSeconds: Int?
    @Published private(set) var jiggleCount: Int = 0

    let hotKeyName = "keep_awake.toggle"
    private var config = KeepAwakeConfig()
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var expiryTimer: Timer?
    private var jiggleMonitorTimer: Timer?
    private var didHandleInitialLaunch = false

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.keepAwake.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.keepAwake.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        config.keepAwake.shortcut.isEmpty ? nil : config.keepAwake.shortcut.displayString
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !config.keepAwake.enabled { return "Disabled" }
        if !config.general.appEnabled { return "Paused" }
        if isAwakeActive {
            if let expiresAt {
                let mins = max(1, Int(ceil(expiresAt.timeIntervalSinceNow / 60)))
                return "Awake (\(mins)m)"
            }
            return "Awake (∞)"
        }
        return "Standby"
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.keepAwake
        refreshMacSleepSettings()

        if config.enabled {
            if !isRunning { start() } else { registerHotKey() }
            if !didHandleInitialLaunch {
                didHandleInitialLaunch = true
                if config.activeOnLaunch {
                    activate(minutes: config.defaultDurationMinutes)
                }
            } else if isAwakeActive {
                // Re-apply strategy changes live
                applyActiveStrategy()
            }
        } else {
            if isRunning { stop() }
        }
    }

    func start() {
        guard !isRunning else { return }
        registerHotKey()
        refreshMacSleepSettings()
        isRunning = true
    }

    func stop() {
        HotKeyManager.shared.unregister(name: hotKeyName)
        deactivate()
        isRunning = false
    }

    func toggle(showToast: Bool = true) {
        if isAwakeActive {
            deactivate()
            if showToast {
                HUDToast.shared.show(title: "Keep Awake Off", symbol: "bolt.slash", tint: .secondary)
            }
        } else {
            activate(minutes: config.defaultDurationMinutes)
            if showToast {
                let dur = config.defaultDurationMinutes > 0 ? "\(config.defaultDurationMinutes)m" : "∞"
                HUDToast.shared.show(title: "Keep Awake On (\(dur))", symbol: "bolt.fill", tint: .orange)
            }
        }
    }

    func activate(minutes: Int) {
        deactivate()
        refreshMacSleepSettings()

        isAwakeActive = true
        jiggleCount = 0
        applyActiveStrategy()

        if minutes > 0 {
            let target = Date().addingTimeInterval(TimeInterval(minutes * 60))
            expiresAt = target
            expiryTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.deactivate()
                }
            }
        } else {
            expiresAt = nil
        }
        ModuleRegistry.shared.notifyChanged()
    }

    func deactivate() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        jiggleMonitorTimer?.invalidate()
        jiggleMonitorTimer = nil
        expiresAt = nil
        nextJiggleInSeconds = nil
        currentIdleSeconds = 0

        releaseAssertion()
        if isAwakeActive {
            isAwakeActive = false
            ModuleRegistry.shared.notifyChanged()
        }
    }

    func refreshMacSleepSettings() {
        Task.detached(priority: .utility) {
            let currentOut = Self.runPmset(["-g"])
            let customOut = Self.runPmset(["-g", "custom"])
            let parsed = Self.parsePmset(currentOutput: currentOut, customOutput: customOut)
            await MainActor.run {
                self.powerInfo = parsed
            }
        }
    }

    nonisolated static func parsePmset(currentOutput: String, customOutput: String) -> MacPowerSleepInfo {
        var info = MacPowerSleepInfo()

        for line in currentOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("displaysleep"),
               let val = extractLeadingInt(from: trimmed.dropFirst("displaysleep".count)) {
                info.activeDisplaySleepMinutes = val
            }
        }

        enum Section { case none, battery, ac }
        var section: Section = .none
        for line in customOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Battery Power:") {
                section = .battery
            } else if trimmed.hasPrefix("AC Power:") {
                section = .ac
            } else if trimmed.hasPrefix("displaysleep"),
                      let val = extractLeadingInt(from: trimmed.dropFirst("displaysleep".count)) {
                switch section {
                case .battery: info.batteryDisplaySleepMinutes = val
                case .ac: info.acDisplaySleepMinutes = val
                case .none: break
                }
            }
        }
        return info
    }

    private nonisolated static func extractLeadingInt(from slice: Substring) -> Int? {
        let parts = slice.trimmingCharacters(in: .whitespaces).split(whereSeparator: { !$0.isNumber })
        guard let first = parts.first else { return nil }
        return Int(first)
    }

    private nonisolated static func runPmset(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(KeepAwakeSettingsView(module: self))
    }

    private func applyActiveStrategy() {
        releaseAssertion()
        jiggleMonitorTimer?.invalidate()
        jiggleMonitorTimer = nil

        switch config.strategy {
        case .powerAssertion:
            acquireAssertion()
            nextJiggleInSeconds = nil
        case .smartMouseJiggle:
            startSmartJiggleMonitor()
        case .both:
            acquireAssertion()
            startSmartJiggleMonitor()
        }
    }

    private func acquireAssertion() {
        let assertionType: CFString = config.preventDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
            : kIOPMAssertionTypePreventUserIdleSystemSleep as CFString

        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Toolbox Keep Awake" as CFString,
            &id
        )

        if status == kIOReturnSuccess {
            assertionID = id
            hasAssertion = true
            DeveloperEventLog.shared.record(
                .keepAwake,
                "IOPMAssertion acquired",
                detail: config.preventDisplaySleep ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
            )
        } else {
            NSLog("Toolbox: IOPMAssertionCreateWithName failed with \(status)")
        }
    }

    private func releaseAssertion() {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            hasAssertion = false
            assertionID = 0
            DeveloperEventLog.shared.record(.keepAwake, "IOPMAssertion released")
        }
    }

    private func startSmartJiggleMonitor() {
        jiggleMonitorTimer?.invalidate()
        tickSmartJiggle()
        jiggleMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickSmartJiggle()
            }
        }
    }

    private func tickSmartJiggle() {
        let idle = Self.userIdleSeconds()
        currentIdleSeconds = Int(idle)

        let thresholdSeconds = effectiveJiggleThresholdSeconds()
        let remaining = max(0, Int(ceil(Double(thresholdSeconds) - idle)))
        nextJiggleInSeconds = remaining

        if idle >= Double(thresholdSeconds) {
            performTinyMouseJiggle()
            jiggleCount += 1
            currentIdleSeconds = 0
            nextJiggleInSeconds = thresholdSeconds
            DeveloperEventLog.shared.record(.keepAwake, "Smart mouse jiggle triggered", detail: "count: \(jiggleCount)")
        }
    }

    func effectiveJiggleThresholdSeconds() -> Int {
        let lead = max(5, config.jiggleLeadSeconds)
        if let mins = powerInfo.activeDisplaySleepMinutes, mins > 0 {
            let sleepSecs = mins * 60
            return max(15, sleepSecs - lead)
        }
        return max(15, config.fallbackJiggleIntervalSeconds)
    }

    private nonisolated static func userIdleSeconds() -> TimeInterval {
        let eventTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        let times = eventTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }
        return times.min() ?? 0
    }

    private func performTinyMouseJiggle() {
        guard let currentPos = CGEvent(source: nil)?.location else { return }
        let nudged = CGPoint(x: currentPos.x + 1, y: currentPos.y)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: nudged, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: currentPos, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func registerHotKey() {
        HotKeyManager.shared.register(name: hotKeyName, shortcut: config.shortcut) { [weak self] in
            self?.toggle()
        }
    }
}
