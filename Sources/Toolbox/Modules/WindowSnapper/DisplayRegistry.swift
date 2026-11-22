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

    var onDisplaysReconfigured: (([ConnectedDisplay], [DisplaySignature]) -> Void)?

    private var liveSignatureCache: [CGDirectDisplayID: DisplaySignature] = [:]
    private var screenObserver: NSObjectProtocol?
    private var hasRegisteredCGCallback = false
    private var pendingDebounceWork: DispatchWorkItem?

    private init() {
        refresh()
    }

    func startObserving() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleDebouncedRefresh()
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
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if hasRegisteredCGCallback {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigCallback, selfPtr)
            hasRegisteredCGCallback = false
        }
    }

    private static let displayReconfigCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let registry = Unmanaged<DisplayRegistry>.fromOpaque(userInfo).takeUnretainedValue()
        let isBegin = flags.contains(.beginConfigurationFlag)
        let isRemoved = flags.contains(.removeFlag)
        Task { @MainActor in
            registry.handleCGReconfiguration(displayID: displayID, isBegin: isBegin, isRemoved: isRemoved)
        }
    }

    private func handleCGReconfiguration(displayID: CGDirectDisplayID, isBegin: Bool, isRemoved: Bool) {
        if isBegin {
            if let existing = liveSignatureCache[displayID] {
                disconnectedSignatureCache[displayID] = existing
            }
            return
        }
        if isRemoved, let existing = liveSignatureCache[displayID] {
            disconnectedSignatureCache[displayID] = existing
        }
        scheduleDebouncedRefresh()
    }

    private func scheduleDebouncedRefresh() {
        pendingDebounceWork?.cancel()
        let previousSignatures = connectedDisplays.map(\.signature)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.onDisplaysReconfigured?(self.connectedDisplays, previousSignatures)
            }
        }
        pendingDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
