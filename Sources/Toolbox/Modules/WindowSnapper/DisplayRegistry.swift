import AppKit
import CoreGraphics
import Foundation

struct ConnectedDisplay: Equatable, Identifiable, Sendable {
    var id: CGDirectDisplayID { displayID }

    let displayID: CGDirectDisplayID
    let signature: DisplaySignature
    let frameAppKit: CGRect
    let visibleFrameAppKit: CGRect
    let frameAX: CGRect
    let usableAppKit: CGRect
    let usableAX: CGRect
    let safeAreaInsets: SafeAreaInsets
    let isMain: Bool
    let primaryScreenHeight: CGFloat
}

@MainActor
final class DisplayRegistry: ObservableObject {
    static let shared = DisplayRegistry()

    @Published private(set) var connectedDisplays: [ConnectedDisplay] = []
    @Published private(set) var disconnectedSignatureCache: [CGDirectDisplayID: DisplaySignature] = [:]
    @Published private(set) var primaryScreenHeight: CGFloat = 1080

    var onDisplaysReconfigurationBegan: ((_ isRemoved: Bool) -> Void)?
    var onDisplaysReconfigured: (([ConnectedDisplay], [DisplaySignature]) -> Void)?

    private var liveSignatureCache: [CGDirectDisplayID: DisplaySignature] = [:]
    private var knownOnlineDisplayIDs: Set<CGDirectDisplayID> = []
    private var suppressModeEnforcementUntil: Date = .distantPast
    private var isScreenLocked = false
    private var isDisplayAsleep = false
    private var wakeOrUnlockSettleUntil: Date = .distantPast
    private var didAnnounceReconfigForCurrentBurst = false
    private var screenObserver: NSObjectProtocol?
    private var distributedLockObserver: NSObjectProtocol?
    private var distributedUnlockObserver: NSObjectProtocol?
    private var sessionResignObserver: NSObjectProtocol?
    private var sessionBecomeActiveObserver: NSObjectProtocol?
    private var screensSleepObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?
    private var systemWakeObserver: NSObjectProtocol?
    private var hasRegisteredCGCallback = false
    private var pendingDebounceWork: DispatchWorkItem?

    private init() {
        knownOnlineDisplayIDs = Set(Self.onlineDisplayIDs())
        refresh()
    }

    func startObserving() {
        knownOnlineDisplayIDs = Set(Self.onlineDisplayIDs())
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard !self.isScreenLocked && !self.isDisplayAsleep else { return }
                    self.scheduleDebouncedRefresh(
                        delay: Self.debounceDelay(inUnlockSettleWindow: Date() < self.wakeOrUnlockSettleUntil)
                    )
                }
            }
        }

        let distributedCenter = DistributedNotificationCenter.default()
        if distributedLockObserver == nil {
            distributedLockObserver = distributedCenter.addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionInactiveOrSleep(isLock: true)
                }
            }
        }
        if distributedUnlockObserver == nil {
            distributedUnlockObserver = distributedCenter.addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionActiveOrWake(isLock: true)
                }
            }
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        if sessionResignObserver == nil {
            sessionResignObserver = wsCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionInactiveOrSleep(isLock: true)
                }
            }
        }
        if sessionBecomeActiveObserver == nil {
            sessionBecomeActiveObserver = wsCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionActiveOrWake(isLock: true)
                }
            }
        }
        if screensSleepObserver == nil {
            screensSleepObserver = wsCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionInactiveOrSleep(isLock: false)
                }
            }
        }
        if screensWakeObserver == nil {
            screensWakeObserver = wsCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionActiveOrWake(isLock: false)
                }
            }
        }
        if systemWakeObserver == nil {
            systemWakeObserver = wsCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionActiveOrWake(isLock: false)
                }
            }
        }

        if !hasRegisteredCGCallback {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            CGDisplayRegisterReconfigurationCallback(Self.displayReconfigCallback, selfPtr)
            hasRegisteredCGCallback = true
        }
        refresh()
    }

    func stopObserving() {
        pendingDebounceWork?.cancel()
        pendingDebounceWork = nil
        isScreenLocked = false
        isDisplayAsleep = false
        didAnnounceReconfigForCurrentBurst = false
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        let distributedCenter = DistributedNotificationCenter.default()
        if let distributedLockObserver {
            distributedCenter.removeObserver(distributedLockObserver)
            self.distributedLockObserver = nil
        }
        if let distributedUnlockObserver {
            distributedCenter.removeObserver(distributedUnlockObserver)
            self.distributedUnlockObserver = nil
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let sessionResignObserver {
            wsCenter.removeObserver(sessionResignObserver)
            self.sessionResignObserver = nil
        }
        if let sessionBecomeActiveObserver {
            wsCenter.removeObserver(sessionBecomeActiveObserver)
            self.sessionBecomeActiveObserver = nil
        }
        if let screensSleepObserver {
            wsCenter.removeObserver(screensSleepObserver)
            self.screensSleepObserver = nil
        }
        if let screensWakeObserver {
            wsCenter.removeObserver(screensWakeObserver)
            self.screensWakeObserver = nil
        }
        if let systemWakeObserver {
            wsCenter.removeObserver(systemWakeObserver)
            self.systemWakeObserver = nil
        }
        if hasRegisteredCGCallback {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigCallback, selfPtr)
            hasRegisteredCGCallback = false
        }
    }

    private func handleSessionInactiveOrSleep(isLock: Bool) {
        if isLock {
            isScreenLocked = true
        } else {
            isDisplayAsleep = true
        }
        pendingDebounceWork?.cancel()
        pendingDebounceWork = nil
        didAnnounceReconfigForCurrentBurst = false
    }

    nonisolated static func nextLockSleepStateOnActiveOrWake(
        isScreenLocked: Bool,
        isDisplayAsleep: Bool,
        isLockEvent: Bool
    ) -> (isScreenLocked: Bool, isDisplayAsleep: Bool, shouldScheduleReconcile: Bool) {
        let nextLocked = isLockEvent ? false : isScreenLocked
        // Unlocking or activating the session proves the display is awake,
        // even if macOS did not deliver screensDidWakeNotification (e.g. clamshell wake).
        let nextAsleep = false
        return (nextLocked, nextAsleep, !nextLocked && !nextAsleep)
    }

    private func handleSessionActiveOrWake(isLock: Bool) {
        let next = Self.nextLockSleepStateOnActiveOrWake(
            isScreenLocked: isScreenLocked,
            isDisplayAsleep: isDisplayAsleep,
            isLockEvent: isLock
        )
        isScreenLocked = next.isScreenLocked
        isDisplayAsleep = next.isDisplayAsleep
        wakeOrUnlockSettleUntil = Date().addingTimeInterval(2.5)
        if next.shouldScheduleReconcile {
            scheduleDebouncedRefresh(delay: 1.5)
        }
    }

    nonisolated static func debounceDelay(inUnlockSettleWindow: Bool) -> TimeInterval {
        inUnlockSettleWindow ? 1.5 : 1.0
    }

    nonisolated static func shouldAnnounceReconfigurationBegan(
        flags: CGDisplayChangeSummaryFlags,
        isScreenLocked: Bool,
        isDisplayAsleep: Bool,
        inUnlockSettleWindow: Bool
    ) -> (announce: Bool, isRemoved: Bool) {
        guard !isScreenLocked,
              !isDisplayAsleep,
              !inUnlockSettleWindow,
              !flags.contains(.beginConfigurationFlag) else {
            return (false, false)
        }
        let isRemoved = flags.contains(.removeFlag)
        let isAdded = flags.contains(.addFlag)
        guard isAdded || isRemoved else {
            return (false, false)
        }
        return (true, isRemoved)
    }

    private static let displayReconfigCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let registry = Unmanaged<DisplayRegistry>.fromOpaque(userInfo).takeUnretainedValue()
        let rawFlags = flags.rawValue
        Task { @MainActor in
            registry.handleCGReconfiguration(displayID: displayID, flags: CGDisplayChangeSummaryFlags(rawValue: rawFlags))
        }
    }

    private func handleCGReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        if flags.contains(.beginConfigurationFlag) {
            pendingDebounceWork?.cancel()
            pendingDebounceWork = nil
            if let existing = liveSignatureCache[displayID] {
                disconnectedSignatureCache[displayID] = existing
            }
            return
        }
        if flags.contains(.removeFlag), let existing = liveSignatureCache[displayID] {
            disconnectedSignatureCache[displayID] = existing
        }
        guard !isScreenLocked && !isDisplayAsleep else {
            return
        }
        let decision = Self.shouldAnnounceReconfigurationBegan(
            flags: flags,
            isScreenLocked: isScreenLocked,
            isDisplayAsleep: isDisplayAsleep,
            inUnlockSettleWindow: Date() < wakeOrUnlockSettleUntil
        )
        if decision.announce && !didAnnounceReconfigForCurrentBurst {
            didAnnounceReconfigForCurrentBurst = true
            onDisplaysReconfigurationBegan?(decision.isRemoved)
        }
        scheduleDebouncedRefresh(
            delay: Self.debounceDelay(inUnlockSettleWindow: Date() < wakeOrUnlockSettleUntil)
        )
    }

    private func scheduleDebouncedRefresh(delay: TimeInterval = 1.0) {
        pendingDebounceWork?.cancel()
        let previousSignatures = connectedDisplays.map(\.signature)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.isScreenLocked && !self.isDisplayAsleep else { return }
                self.didAnnounceReconfigForCurrentBurst = false
                let currentOnline = Set(Self.onlineDisplayIDs())
                guard !currentOnline.isEmpty else { return }
                let newlyConnected = currentOnline.subtracting(self.knownOnlineDisplayIDs)
                self.knownOnlineDisplayIDs = currentOnline

                if !newlyConnected.isEmpty,
                   currentOnline.count >= 2,
                   Date() >= self.suppressModeEnforcementUntil,
                   !PermissionsManager.isRunningInDiagnosticMode {
                    let fullCfg = ConfigManager.shared.config
                    if fullCfg.general.appEnabled,
                       fullCfg.windowSnapper.enabled,
                       fullCfg.windowSnapper.displayConnectMode != .systemDefault {
                        let changed = self.applyDisplayConnectMode(fullCfg.windowSnapper.displayConnectMode)
                        if changed {
                            self.suppressModeEnforcementUntil = Date().addingTimeInterval(2.5)
                            return
                        }
                    }
                }

                self.refresh()
                guard !self.connectedDisplays.isEmpty else { return }
                self.onDisplaysReconfigured?(self.connectedDisplays, previousSignatures)
            }
        }
        pendingDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    nonisolated static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else {
            return []
        }
        return Array(ids.prefix(Int(count)))
    }

    @discardableResult
    func applyDisplayConnectMode(_ mode: DisplayConnectMode) -> Bool {
        guard !PermissionsManager.isRunningInDiagnosticMode else { return false }
        let online = Self.onlineDisplayIDs()
        guard online.count >= 2 else { return false }

        switch mode {
        case .systemDefault:
            return false

        case .alwaysExtend:
            let mirrored = online.filter { id in
                CGDisplayIsInMirrorSet(id) != 0 && CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
            }
            guard !mirrored.isEmpty else { return false }
            var configRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configRef) == .success, let cfg = configRef else {
                return false
            }
            for id in mirrored {
                CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
            }
            let result = CGCompleteDisplayConfiguration(cfg, .permanently)
            if result == .success {
                DeveloperEventLog.shared.record(.windowSnapper, "Extended \(mirrored.count) mirrored display(s)")
                return true
            }
            return false

        case .alwaysMirror:
            let masterID = online.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
            let targets = online.filter { id in
                id != masterID && CGDisplayMirrorsDisplay(id) != masterID
            }
            guard !targets.isEmpty else { return false }
            var configRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configRef) == .success, let cfg = configRef else {
                return false
            }
            for id in targets {
                CGConfigureDisplayMirrorOfDisplay(cfg, id, masterID)
            }
            let result = CGCompleteDisplayConfiguration(cfg, .permanently)
            if result == .success {
                DeveloperEventLog.shared.record(.windowSnapper, "Mirrored \(targets.count) display(s) to primary")
                return true
            }
            return false
        }
    }

    func refresh(gaps: GapConfig = ConfigManager.shared.config.windowSnapper.gaps) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            connectedDisplays = []
            return
        }

        let primaryScreen = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
        let primaryHeight = primaryScreen?.frame.height ?? 1080
        self.primaryScreenHeight = primaryHeight

        let sm = SnapGeometry.currentStageManagerState()
        let stageManagerActive = gaps.respectStageManagerStrip && sm.stripVisible

        struct RawScreenEntry {
            let screen: NSScreen
            let displayID: CGDirectDisplayID
            let isMain: Bool
        }

        let entries: [RawScreenEntry] = screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(num.uint32Value)
            let isMain = (screen === primaryScreen) || (CGDisplayIsMain(displayID) != 0)
            return RawScreenEntry(screen: screen, displayID: displayID, isMain: isMain)
        }
        .sorted { lhs, rhs in
            if abs(lhs.screen.frame.minX - rhs.screen.frame.minX) > 1 {
                return lhs.screen.frame.minX < rhs.screen.frame.minX
            }
            return lhs.screen.frame.minY < rhs.screen.frame.minY
        }

        var nextConnected: [ConnectedDisplay] = []
        var nextLiveCache: [CGDirectDisplayID: DisplaySignature] = [:]

        for (index, entry) in entries.enumerated() {
            let sig = Self.buildSignature(
                displayID: entry.displayID,
                localizedName: entry.screen.localizedName,
                arrangementIndex: index
            )
            nextLiveCache[entry.displayID] = sig

            let safeInsets = SafeAreaInsets(nsEdgeInsets: entry.screen.safeAreaInsets)
            let usableAppKit = SnapGeometry.usableAppKitRect(
                screenFrame: entry.screen.frame,
                visibleFrame: entry.screen.visibleFrame,
                safeAreaInsets: safeInsets,
                stageManagerActive: stageManagerActive,
                stageManagerEdge: sm.edge,
                stageManagerReservePoints: CGFloat(gaps.stageManagerReservePoints)
            )
            let usableAX = SnapGeometry.appKitToAX(usableAppKit, primaryScreenHeight: primaryHeight)
            let frameAX = SnapGeometry.appKitToAX(entry.screen.frame, primaryScreenHeight: primaryHeight)

            nextConnected.append(ConnectedDisplay(
                displayID: entry.displayID,
                signature: sig,
                frameAppKit: entry.screen.frame,
                visibleFrameAppKit: entry.screen.visibleFrame,
                frameAX: frameAX,
                usableAppKit: usableAppKit,
                usableAX: usableAX,
                safeAreaInsets: safeInsets,
                isMain: entry.isMain,
                primaryScreenHeight: primaryHeight
            ))
        }

        // Cache any previously connected displays that disappeared since the last refresh.
        let activeIDs = Set(nextLiveCache.keys)
        for (oldID, oldSig) in liveSignatureCache where !activeIDs.contains(oldID) {
            disconnectedSignatureCache[oldID] = oldSig
        }
        for activeID in activeIDs {
            disconnectedSignatureCache.removeValue(forKey: activeID)
        }

        liveSignatureCache = nextLiveCache
        connectedDisplays = nextConnected
    }

    static func buildSignature(
        displayID: CGDirectDisplayID,
        localizedName: String,
        arrangementIndex: Int
    ) -> DisplaySignature {
        var uuidString = ""
        if let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let cfUUID = unmanagedUUID.takeRetainedValue()
            if let str = CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String? {
                uuidString = str
            }
        }
        return DisplaySignature(
            uuidString: uuidString,
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            localizedName: localizedName.isEmpty ? "Display \(arrangementIndex + 1)" : localizedName,
            arrangementIndex: arrangementIndex
        )
    }

    // MARK: - Pure Matching & Resolution

    /// Resolves `saved` against `candidates`:
    /// 1. Unique exact UUID match first.
    /// 2. If UUID collides (e.g. identical Apple Silicon monitors) or does not match, match by
    ///    hardware tuple `(vendorNumber, modelNumber, serialNumber)` preferring the same `arrangementIndex`,
    ///    then closest `arrangementIndex`.
    /// 3. Fallback to `(vendorNumber, modelNumber)` + `arrangementIndex` when hardware serial is blank/0.
    static func matchDisplay(
        for saved: DisplaySignature,
        among candidates: [DisplaySignature]
    ) -> DisplaySignature? {
        guard !candidates.isEmpty else { return nil }

        if !saved.uuidString.isEmpty {
            let uuidMatches = candidates.filter {
                $0.uuidString.caseInsensitiveCompare(saved.uuidString) == .orderedSame
            }
            if uuidMatches.count == 1 {
                return uuidMatches[0]
            }
            if uuidMatches.count > 1 {
                if let exactSlot = uuidMatches.first(where: { $0.arrangementIndex == saved.arrangementIndex }) {
                    return exactSlot
                }
                return uuidMatches.min {
                    abs($0.arrangementIndex - saved.arrangementIndex) < abs($1.arrangementIndex - saved.arrangementIndex)
                }
            }
        }

        if saved.vendorNumber != 0 || saved.modelNumber != 0 {
            let hardwareMatches = candidates.filter {
                $0.vendorNumber == saved.vendorNumber
                    && $0.modelNumber == saved.modelNumber
                    && $0.serialNumber == saved.serialNumber
            }
            if let exactSlot = hardwareMatches.first(where: { $0.arrangementIndex == saved.arrangementIndex }) {
                return exactSlot
            }
            if let closest = hardwareMatches.min(by: {
                abs($0.arrangementIndex - saved.arrangementIndex) < abs($1.arrangementIndex - saved.arrangementIndex)
            }) {
                return closest
            }

            let modelMatches = candidates.filter {
                $0.vendorNumber == saved.vendorNumber && $0.modelNumber == saved.modelNumber
            }
            if let exactSlot = modelMatches.first(where: { $0.arrangementIndex == saved.arrangementIndex }) {
                return exactSlot
            }
            if let closest = modelMatches.min(by: {
                abs($0.arrangementIndex - saved.arrangementIndex) < abs($1.arrangementIndex - saved.arrangementIndex)
            }) {
                return closest
            }
        }

        return nil
    }

    static func layout(
        for display: DisplaySignature,
        in layouts: [DisplayLayoutConfig],
        overrides: [DisplayLayoutConfig] = []
    ) -> DisplayLayoutConfig? {
        if let overrideMatch = matchLayout(for: display, in: overrides) {
            return overrideMatch
        }
        return matchLayout(for: display, in: layouts)
    }

    private static func matchLayout(
        for display: DisplaySignature,
        in layouts: [DisplayLayoutConfig]
    ) -> DisplayLayoutConfig? {
        guard !layouts.isEmpty else { return nil }
        let layoutSignatures = layouts.map(\.display)
        guard let matchedSig = matchDisplay(for: display, among: layoutSignatures) else {
            return nil
        }
        return layouts.first { $0.display == matchedSig }
    }

    nonisolated static func assignLogicalRoles(
        for displays: [ConnectedDisplay],
        swapExternalDisplays: Bool = false
    ) -> [ProfileDisplayRole: ConnectedDisplay] {
        guard !displays.isEmpty else { return [:] }
        let main = displays.first(where: \.isMain) ?? displays[0]
        var externals = displays.filter { $0.displayID != main.displayID }
        if swapExternalDisplays && externals.count >= 2 {
            externals.swapAt(0, 1)
        }
        var result: [ProfileDisplayRole: ConnectedDisplay] = [.main: main]
        if externals.count >= 1 {
            result[.external1] = externals[0]
        }
        if externals.count >= 2 {
            result[.external2] = externals[1]
        }
        return result
    }

    nonisolated static func role(
        for display: ConnectedDisplay,
        in displays: [ConnectedDisplay],
        swapExternalDisplays: Bool = false
    ) -> ProfileDisplayRole? {
        let roles = assignLogicalRoles(for: displays, swapExternalDisplays: swapExternalDisplays)
        return roles.first(where: { $0.value.displayID == display.displayID })?.key
    }

    static func topologiesMatch(
        bound: [DisplaySignature],
        connected: [DisplaySignature]
    ) -> Bool {
        guard !bound.isEmpty, bound.count == connected.count else { return false }
        var remaining = connected
        for sig in bound {
            guard let matched = matchDisplay(for: sig, among: remaining),
                  let idx = remaining.firstIndex(of: matched) else {
                return false
            }
            remaining.remove(at: idx)
        }
        return true
    }

    func display(containingAXPoint point: CGPoint) -> ConnectedDisplay? {
        connectedDisplays.first { $0.frameAX.contains(point) }
            ?? connectedDisplays.first(where: \.isMain)
            ?? connectedDisplays.first
    }

    func display(containingAXRect rect: CGRect) -> ConnectedDisplay? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let byCenter = connectedDisplays.first(where: { $0.frameAX.contains(center) }) {
            return byCenter
        }
        var best: ConnectedDisplay?
        var bestArea: CGFloat = 0
        for display in connectedDisplays {
            let intersection = display.frameAX.intersection(rect)
            if !intersection.isNull {
                let area = intersection.width * intersection.height
                if area > bestArea {
                    bestArea = area
                    best = display
                }
            }
        }
        return best ?? connectedDisplays.first(where: \.isMain) ?? connectedDisplays.first
    }

    func mainDisplay() -> ConnectedDisplay? {
        connectedDisplays.first(where: \.isMain) ?? connectedDisplays.first
    }

    func adjacentDisplay(from current: ConnectedDisplay, direction: Int) -> ConnectedDisplay? {
        guard connectedDisplays.count > 1,
              let idx = connectedDisplays.firstIndex(where: { $0.displayID == current.displayID }) else {
            return nil
        }
        let nextIndex = (idx + direction + connectedDisplays.count) % connectedDisplays.count
        return connectedDisplays[nextIndex]
    }

    func cachedDisconnectedSignature(for displayID: CGDirectDisplayID) -> DisplaySignature? {
        disconnectedSignatureCache[displayID]
    }
}
