import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Snapshot of the focused Accessibility element and its enclosing Finder window.
/// Used to guarantee Toolbox never intercepts shortcuts while typing, renaming,
/// searching, or interacting with modal sheets/dialogs.
struct FinderFocusContext: Equatable, Sendable {
    let focusedRole: String?
    let focusedSubrole: String?
    let windowRole: String?
    let windowSubrole: String?
    let isWindowModal: Bool
    let hasAttachedSheet: Bool
    let isInSheetHierarchy: Bool
    let axLookupFailed: Bool

    static let empty = FinderFocusContext(
        focusedRole: nil,
        focusedSubrole: nil,
        windowRole: nil,
        windowSubrole: nil,
        isWindowModal: false,
        hasAttachedSheet: false,
        isInSheetHierarchy: false,
        axLookupFailed: false
    )

    static let browserItemFocused = FinderFocusContext(
        focusedRole: "AXOutline",
        focusedSubrole: nil,
        windowRole: "AXWindow",
        windowSubrole: "AXStandardWindow",
        isWindowModal: false,
        hasAttachedSheet: false,
        isInSheetHierarchy: false,
        axLookupFailed: false
    )

    private static let textInputRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXSecureTextField"
    ]

    private static let textInputSubroles: Set<String> = [
        "AXSearchField",
        "AXSecureTextField"
    ]

    private static let interactiveControlRoles: Set<String> = [
        "AXButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXMenu",
        "AXMenuItem",
        "AXSheet",
        "AXPopover",
        "AXSlider",
        "AXDisclosureTriangle",
        "AXTabGroup"
    ]

    private static let modalOrFloatingWindowSubroles: Set<String> = [
        "AXDialog",
        "AXSystemDialog",
        "AXSheet",
        "AXFloatingWindow",
        "AXSystemFloatingWindow"
    ]

    var isTextInputFocused: Bool {
        if let focusedRole, Self.textInputRoles.contains(focusedRole) {
            return true
        }
        if let focusedSubrole, Self.textInputSubroles.contains(focusedSubrole) {
            return true
        }
        return false
    }

    var isInteractiveControlFocused: Bool {
        if let focusedRole, Self.interactiveControlRoles.contains(focusedRole) {
            return true
        }
        return false
    }

    var isModalOrNonBrowserWindow: Bool {
        if isWindowModal || hasAttachedSheet || isInSheetHierarchy {
            return true
        }
        if windowRole == "AXSheet" || windowRole == "AXPopover" {
            return true
        }
        if let windowSubrole, Self.modalOrFloatingWindowSubroles.contains(windowSubrole) {
            return true
        }
        return false
    }

    /// Returns `true` when Finder shortcuts must pass through untouched.
    /// - Parameter forNavigation: `true` for `Return` / `F2`, which must also yield to
    ///   dialogs, floating inspector windows (e.g., Get Info), and focused buttons/controls.
    func shouldBlockFinderShortcut(forNavigation: Bool) -> Bool {
        if axLookupFailed || isTextInputFocused || isInSheetHierarchy || hasAttachedSheet || isWindowModal {
            return true
        }
        if windowRole == "AXSheet" || windowRole == "AXPopover" {
            return true
        }
        if forNavigation {
            return isModalOrNonBrowserWindow || isInteractiveControlFocused
        }
        return false
    }
}

/// Pure state machine tracking armed `⌘ X` cut-and-paste operations in Finder.
struct FinderCutStateMachine: Equatable, Sendable {
    private(set) var armedChangeCount: Int? = nil
    private(set) var armedItemCount: Int = 0

    var isArmed: Bool {
        armedChangeCount != nil && armedItemCount > 0
    }

    mutating func arm(changeCount: Int, itemCount: Int) {
        guard itemCount > 0 else {
            disarm()
            return
        }
        armedChangeCount = changeCount
        armedItemCount = itemCount
    }

    mutating func disarm() {
        armedChangeCount = nil
        armedItemCount = 0
    }

    /// Disarms cut state if the system pasteboard changed outside Finder Enhancer.
    /// Returns `true` when a previously armed state was cleared.
    @discardableResult
    mutating func reconcile(currentChangeCount: Int) -> Bool {
        guard isArmed, armedChangeCount != currentChangeCount else {
            return false
        }
        disarm()
        return true
    }

    /// Evaluates whether an incoming `⌘ V` should execute Finder's native Move (`⌥ ⌘ V`).
    /// Always disarms cut state after evaluation so a subsequent `⌘ V` passes through normally.
    mutating func evaluatePaste(currentChangeCount: Int, hasFileURLs: Bool) -> Bool {
        guard isArmed,
              armedChangeCount == currentChangeCount,
              hasFileURLs else {
            disarm()
            return false
        }
        disarm()
        return true
    }
}

enum FinderKeyDecision: Equatable, Sendable {
    case passThrough
    case swallowOnly
    case cutToCopy
    case pasteAsMove
    case disarmAndPassThrough
    case openSelected
    case renameSelected
}

private final class FinderTapStartState: @unchecked Sendable {
    var succeeded = false
}

/// Finder-scoped `CGEventTap` running on a dedicated background `Thread` + `CFRunLoop`.
/// Translates `⌘ X` → `⌘ C` + armed move state, `⌘ V` (when armed) → `⌥ ⌘ V`,
/// `Return` → `⌘ O`, and `F2` → `Return`, guarded by Accessibility text-input & modal checks.
final class FinderKeyInterceptor: @unchecked Sendable {
    static let syntheticEventTag: Int64 = 0x544C4258 // 'TLBX'
    static let finderBundleID = "com.apple.finder"
    static let relevantModifierMask: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskControl,
        .maskShift
    ]
    private static let axTimeoutSeconds: Float = 0.15
    private static let cutPollIntervalMs = 15
    private static let maxCutPollAttempts = 30 // ~450 ms total

    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()
    private let actionQueue = DispatchQueue(
        label: "app.toolbox.finder-enhancer-actions",
        qos: .userInteractive
    )

    private var config = FinderEnhancerConfig()
    private var frontmostBundleID: String?
    private var frontmostPID: pid_t?
    private var cutState = FinderCutStateMachine()
    private var cutPollGeneration: UInt64 = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?

    var onCutArmed: (@MainActor @Sendable (Int) -> Void)?
    var onCutDisarmed: (@MainActor @Sendable () -> Void)?
    var onCutMoveExecuted: (@MainActor @Sendable () -> Void)?
    var onReturnOpenExecuted: (@MainActor @Sendable () -> Void)?
    var onF2RenameExecuted: (@MainActor @Sendable () -> Void)?

    deinit {
        uninstall()
    }

    var isInstalled: Bool {
        withLock { tap != nil }
    }

    var isCutArmed: Bool {
        withLock { cutState.isArmed }
    }

    var armedCutItemCount: Int {
        withLock { cutState.armedItemCount }
    }

    internal var runsOnDedicatedBackgroundRunLoopForTesting: Bool {
        withLock {
            guard let rl = backgroundRunLoop, let thread = tapThread else { return false }
            return !thread.isMainThread && rl !== CFRunLoopGetMain()
        }
    }

    func updateConfig(_ newConfig: FinderEnhancerConfig) {
        var shouldNotifyDisarm = false
        withLock {
            config = newConfig
            if !newConfig.enableCutAndPaste && cutState.isArmed {
                cutState.disarm()
                cutPollGeneration &+= 1
                shouldNotifyDisarm = true
            }
        }
        if shouldNotifyDisarm {
            notifyDisarmedOnMain()
        }
    }

    func updateFrontmostApplication(bundleID: String?, pid: pid_t?) {
        withLock {
            frontmostBundleID = bundleID
            frontmostPID = pid
        }
    }

    func disarmCutState() {
        var wasArmed = false
        withLock {
            cutPollGeneration &+= 1
            wasArmed = cutState.isArmed
            cutState.disarm()
        }
        if wasArmed {
            notifyDisarmedOnMain()
        }
    }

    func reconcilePasteboard(currentChangeCount: Int) {
        let didDisarm = withLock {
            cutState.reconcile(currentChangeCount: currentChangeCount)
        }
        if didDisarm {
            notifyDisarmedOnMain()
        }
    }

    @discardableResult
    func install() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        uninstallLocked()

        let readySem = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        let startState = FinderTapStartState()

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            guard let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<FinderKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                    return owner.handleTapEvent(type: type, event: event)
                },
                userInfo: selfPtr
            ) else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let rl = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)

            self.withLock {
                self.tap = newTap
                self.runLoopSource = source
                self.backgroundRunLoop = rl
            }

            startState.succeeded = true
            readySem.signal()
            CFRunLoopRun()
            exitSem.signal()
        }
        thread.name = "app.toolbox.finder-enhancer-tap"
        thread.qualityOfService = .userInteractive

        withLock {
            self.tapThread = thread
            self.tapExitSemaphore = exitSem
        }
        thread.start()
        readySem.wait()

        if !startState.succeeded {
            _ = exitSem.wait(timeout: .now() + 0.5)
            withLock {
                self.tapThread = nil
                self.tapExitSemaphore = nil
            }
        }
        return startState.succeeded
    }

    func uninstall() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        uninstallLocked()
    }

    private func uninstallLocked() {
        let (currentTap, currentSource, currentRL, currentThread, exitSem, hadCut) = withLock {
            let values = (tap, runLoopSource, backgroundRunLoop, tapThread, tapExitSemaphore, cutState.isArmed)
            tap = nil
            runLoopSource = nil
            backgroundRunLoop = nil
            tapThread = nil
            tapExitSemaphore = nil
            cutPollGeneration &+= 1
            cutState.disarm()
            return values
        }

        if let currentTap {
            CGEvent.tapEnable(tap: currentTap, enable: false)
            if let currentRL, let currentSource {
                CFRunLoopRemoveSource(currentRL, currentSource, .commonModes)
            }
            CFMachPortInvalidate(currentTap)
        }
        if let currentRL {
            CFRunLoopStop(currentRL)
        }
        if let exitSem, Thread.current !== currentThread {
            _ = exitSem.wait(timeout: .now() + 1.0)
        }
        if hadCut {
            notifyDisarmedOnMain()
        }
    }

    // MARK: - Pure Decision Logic

    static func isCandidateWatchedKey(
        keyCode: UInt16,
        flags: CGEventFlags,
        config: FinderEnhancerConfig,
        isCutArmed: Bool
    ) -> Bool {
        let mods = flags.intersection(relevantModifierMask)

        if config.enableCutAndPaste {
            if keyCode == UInt16(kVK_ANSI_X) && mods == .maskCommand {
                return true
            }
            if isCutArmed && keyCode == UInt16(kVK_ANSI_V) && mods == .maskCommand {
                return true
            }
        }

        if isCutArmed {
            if keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                return true
            }
            if keyCode == UInt16(kVK_ANSI_C) && mods == .maskCommand {
                return true
            }
            if keyCode == UInt16(kVK_ANSI_V) && mods == [.maskCommand, .maskAlternate] {
                return true
            }
        }

        if config.enableReturnToOpen && (keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter)) && mods.isEmpty {
            return true
        }

        if config.enableF2ToRename && keyCode == UInt16(kVK_F2) && mods.isEmpty {
            return true
        }

        return false
    }

    static func decideKeyEvent(
        keyCode: UInt16,
        flags: CGEventFlags,
        isAutoRepeat: Bool,
        userData: Int64,
        frontmostBundleID: String?,
        config: FinderEnhancerConfig,
        focusContext: FinderFocusContext,
        cutState: inout FinderCutStateMachine,
        currentChangeCount: Int,
        pasteboardHasFileURLs: Bool
    ) -> FinderKeyDecision {
        if userData == syntheticEventTag {
            return .passThrough
        }
        guard frontmostBundleID == finderBundleID else {
            return .passThrough
        }

        let mods = flags.intersection(relevantModifierMask)

        // Esc, ⌘C, and manual ⌥⌘V always disarm any pending cut state while passing through.
        if keyCode == UInt16(kVK_Escape) && mods.isEmpty {
            if cutState.isArmed {
                cutState.disarm()
                return .disarmAndPassThrough
            }
            return .passThrough
        }
        if (keyCode == UInt16(kVK_ANSI_C) && mods == .maskCommand)
            || (keyCode == UInt16(kVK_ANSI_V) && mods == [.maskCommand, .maskAlternate]) {
            if cutState.isArmed {
                cutState.disarm()
                return .disarmAndPassThrough
            }
            return .passThrough
        }

        if config.enableCutAndPaste && keyCode == UInt16(kVK_ANSI_X) && mods == .maskCommand {
            if focusContext.shouldBlockFinderShortcut(forNavigation: false) {
                return .passThrough
            }
            if isAutoRepeat {
                return .swallowOnly
            }
            cutState.disarm()
            return .cutToCopy
        }

        if config.enableCutAndPaste && keyCode == UInt16(kVK_ANSI_V) && mods == .maskCommand {
            guard cutState.isArmed else {
                return .passThrough
            }
            if focusContext.shouldBlockFinderShortcut(forNavigation: false) {
                return .passThrough
            }
            if isAutoRepeat {
                return .swallowOnly
            }
            if cutState.evaluatePaste(currentChangeCount: currentChangeCount, hasFileURLs: pasteboardHasFileURLs) {
                return .pasteAsMove
            }
            return .disarmAndPassThrough
        }

        if config.enableReturnToOpen
            && (keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter))
            && mods.isEmpty {
            if focusContext.shouldBlockFinderShortcut(forNavigation: true) {
                return .passThrough
            }
            if isAutoRepeat {
                return .swallowOnly
            }
            return .openSelected
        }

        if config.enableF2ToRename && keyCode == UInt16(kVK_F2) && mods.isEmpty {
            if focusContext.shouldBlockFinderShortcut(forNavigation: true) {
                return .passThrough
            }
            if isAutoRepeat {
                return .swallowOnly
            }
            return .renameSelected
        }

        return .passThrough
    }

    // MARK: - Event Tap Handling

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if PermissionsManager.shouldRearmEventTap(for: type), let current = withLock({ tap }) {
                CGEvent.tapEnable(tap: current, enable: true)
            } else {
                Task { @MainActor in
                    PermissionsManager.shared.refresh()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == Self.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        let (bundleID, pid, currentConfig, armedNow) = withLock {
            (frontmostBundleID, frontmostPID, config, cutState.isArmed)
        }

        guard bundleID == Self.finderBundleID,
              Self.isCandidateWatchedKey(
                  keyCode: keyCode,
                  flags: flags,
                  config: currentConfig,
                  isCutArmed: armedNow
              ) else {
            return Unmanaged.passUnretained(event)
        }

        let mods = flags.intersection(Self.relevantModifierMask)
        let isDisarmOnlyKey = (keyCode == UInt16(kVK_Escape) && mods.isEmpty)
            || (keyCode == UInt16(kVK_ANSI_C) && mods == .maskCommand)
            || (keyCode == UInt16(kVK_ANSI_V) && mods == [.maskCommand, .maskAlternate])

        let focusContext: FinderFocusContext
        if isDisarmOnlyKey {
            focusContext = .empty
        } else {
            focusContext = Self.queryFinderFocusContext(finderPID: pid)
        }

        let isArmedCmdV = armedNow
            && currentConfig.enableCutAndPaste
            && keyCode == UInt16(kVK_ANSI_V)
            && mods == .maskCommand
            && !focusContext.shouldBlockFinderShortcut(forNavigation: false)

        let pasteboardChangeCount: Int
        let pasteboardHasFiles: Bool
        if isArmedCmdV {
            pasteboardChangeCount = NSPasteboard.general.changeCount
            pasteboardHasFiles = NSPasteboard.general.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            )
        } else {
            pasteboardChangeCount = 0
            pasteboardHasFiles = false
        }

        let decision = withLock {
            Self.decideKeyEvent(
                keyCode: keyCode,
                flags: flags,
                isAutoRepeat: isAutoRepeat,
                userData: userData,
                frontmostBundleID: bundleID,
                config: currentConfig,
                focusContext: focusContext,
                cutState: &cutState,
                currentChangeCount: pasteboardChangeCount,
                pasteboardHasFileURLs: pasteboardHasFiles
            )
        }

        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)

        case .swallowOnly:
            return nil

        case .disarmAndPassThrough:
            withLock { cutPollGeneration &+= 1 }
            notifyDisarmedOnMain()
            return Unmanaged.passUnretained(event)

        case .cutToCopy:
            triggerCutToCopy(finderPID: pid)
            return nil

        case .pasteAsMove:
            withLock { cutPollGeneration &+= 1 }
            postSyntheticKey(
                keyCode: CGKeyCode(kVK_ANSI_V),
                flags: [.maskCommand, .maskAlternate],
                targetPID: resolveFinderPID(preferred: pid)
            )
            notifyDisarmedOnMain()
            let callback = onCutMoveExecuted
            if let callback {
                Task { @MainActor in callback() }
            }
            return nil

        case .openSelected:
            postSyntheticKey(
                keyCode: CGKeyCode(kVK_ANSI_O),
                flags: .maskCommand,
                targetPID: resolveFinderPID(preferred: pid)
            )
            let callback = onReturnOpenExecuted
            if let callback {
                Task { @MainActor in callback() }
            }
            return nil

        case .renameSelected:
            postSyntheticKey(
                keyCode: CGKeyCode(kVK_Return),
                flags: [],
                targetPID: resolveFinderPID(preferred: pid)
            )
            let callback = onF2RenameExecuted
            if let callback {
                Task { @MainActor in callback() }
            }
            return nil
        }
    }

    private func resolveFinderPID(preferred: pid_t?) -> pid_t? {
        if let preferred, preferred > 0 {
            return preferred
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID)
            .first(where: { !$0.isTerminated })?
            .processIdentifier
    }

    private func triggerCutToCopy(finderPID: pid_t?) {
        let generation = withLock { () -> UInt64 in
            cutPollGeneration &+= 1
            return cutPollGeneration
        }
        let targetPID = resolveFinderPID(preferred: finderPID)
        let preCopyCount = NSPasteboard.general.changeCount

        postSyntheticKey(
            keyCode: CGKeyCode(kVK_ANSI_C),
            flags: .maskCommand,
            targetPID: targetPID
        ) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.cutPollIntervalMs)) {
                MainActor.assumeIsolated {
                    self?.pollPasteboardAfterCut(
                        preCopyCount: preCopyCount,
                        generation: generation,
                        attempt: 0
                    )
                }
            }
        }
    }

    @MainActor
    private func pollPasteboardAfterCut(preCopyCount: Int, generation: UInt64, attempt: Int) {
        let stillValid = withLock { cutPollGeneration == generation && tap != nil }
        guard stillValid else { return }

        let currentCount = NSPasteboard.general.changeCount
        if currentCount != preCopyCount {
            let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
            let fileCount = urls?.count ?? 0
            if fileCount > 0 {
                withLock {
                    guard cutPollGeneration == generation, tap != nil else { return }
                    cutState.arm(changeCount: currentCount, itemCount: fileCount)
                }
                onCutArmed?(fileCount)
            } else {
                withLock {
                    cutState.disarm()
                }
                onCutDisarmed?()
            }
            return
        }

        if attempt + 1 < Self.maxCutPollAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.cutPollIntervalMs)) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pollPasteboardAfterCut(
                        preCopyCount: preCopyCount,
                        generation: generation,
                        attempt: attempt + 1
                    )
                }
            }
        }
    }

    private func postSyntheticKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        targetPID: pid_t?,
        completion: (@Sendable () -> Void)? = nil
    ) {
        actionQueue.async {
            let source = CGEventSource(stateID: .privateState)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
                down.flags = flags
                up.flags = flags
                down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
                up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
                // Post directly to Finder's process event port when available: `.cghidEventTap`
                // merges live physical HID modifier flags, which causes Finder's alternate
                // `Move Item Here` (`⌥ ⌘ V`) menu item to ignore `.maskAlternate` when only
                // `⌘` is physically held.
                if let targetPID, targetPID > 0 {
                    down.postToPid(targetPID)
                    usleep(12_000)
                    up.postToPid(targetPID)
                } else {
                    down.post(tap: .cghidEventTap)
                    usleep(12_000)
                    up.post(tap: .cghidEventTap)
                }
            }
            completion?()
        }
    }

    private func notifyDisarmedOnMain() {
        let callback = onCutDisarmed
        guard let callback else { return }
        Task { @MainActor in
            callback()
        }
    }

    // MARK: - Accessibility Context Inspection

    static func queryFinderFocusContext(finderPID: pid_t?) -> FinderFocusContext {
        let targetElement: AXUIElement
        if let finderPID, finderPID > 0 {
            targetElement = AXUIElementCreateApplication(finderPID)
        } else {
            targetElement = AXUIElementCreateSystemWide()
        }
        AXUIElementSetMessagingTimeout(targetElement, axTimeoutSeconds)

        var focusedRef: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(
            targetElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        var focusedElement: AXUIElement?
        var axFailed = false
        if focusedErr == .success, let ref = focusedRef {
            focusedElement = (ref as! AXUIElement)
        } else if focusedErr != .noValue && focusedErr != .attributeUnsupported {
            // Fallback to system-wide focused element if app-scoped query couldn't resolve.
            let sysWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(sysWide, axTimeoutSeconds)
            var sysRef: CFTypeRef?
            let sysErr = AXUIElementCopyAttributeValue(
                sysWide,
                kAXFocusedUIElementAttribute as CFString,
                &sysRef
            )
            if sysErr == .success, let ref = sysRef {
                focusedElement = (ref as! AXUIElement)
            } else if sysErr != .noValue && sysErr != .attributeUnsupported {
                axFailed = true
            }
        }

        let focusedRole = focusedElement.flatMap { copyStringAttribute(kAXRoleAttribute, from: $0) }
        let focusedSubrole = focusedElement.flatMap { copyStringAttribute(kAXSubroleAttribute, from: $0) }
        let inSheetHierarchy = focusedElement.map { hasSheetOrPopoverAncestor($0) } ?? false

        var windowElement: AXUIElement?
        if let focusedElement {
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedElement, kAXWindowAttribute as CFString, &winRef) == .success,
               let winRef {
                windowElement = (winRef as! AXUIElement)
            }
        }
        if windowElement == nil, let finderPID, finderPID > 0 {
            let appElem = AXUIElementCreateApplication(finderPID)
            AXUIElementSetMessagingTimeout(appElem, axTimeoutSeconds)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               let winRef {
                windowElement = (winRef as! AXUIElement)
            }
        }

        let windowRole = windowElement.flatMap { copyStringAttribute(kAXRoleAttribute, from: $0) }
        let windowSubrole = windowElement.flatMap { copyStringAttribute(kAXSubroleAttribute, from: $0) }
        let isModal = windowElement.map { copyBoolAttribute(kAXModalAttribute, from: $0) } ?? false
        let hasAttachedSheet = windowElement.map { elementHasAttachedSheet($0) } ?? false

        return FinderFocusContext(
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            windowRole: windowRole,
            windowSubrole: windowSubrole,
            isWindowModal: isModal,
            hasAttachedSheet: hasAttachedSheet,
            isInSheetHierarchy: inSheetHierarchy,
            axLookupFailed: axFailed
        )
    }

    private static func copyStringAttribute(_ attr: String, from element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, axTimeoutSeconds)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copyBoolAttribute(_ attr: String, from element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, axTimeoutSeconds)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
            return false
        }
        if let boolVal = value as? Bool { return boolVal }
        if let numVal = value as? NSNumber { return numVal.boolValue }
        return false
    }

    private static func elementHasAttachedSheet(_ window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, axTimeoutSeconds)
        var sheetsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &sheetsRef) == .success,
              let sheets = sheetsRef as? [AXUIElement] else {
            return false
        }
        return !sheets.isEmpty
    }

    private static func hasSheetOrPopoverAncestor(_ start: AXUIElement) -> Bool {
        var current: AXUIElement? = start
        for _ in 0..<8 {
            guard let elem = current else { break }
            if let role = copyStringAttribute(kAXRoleAttribute, from: elem),
               role == "AXSheet" || role == "AXPopover" {
                return true
            }
            if let subrole = copyStringAttribute(kAXSubroleAttribute, from: elem),
               subrole == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                return true
            }
            AXUIElementSetMessagingTimeout(elem, axTimeoutSeconds)
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(elem, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else {
                break
            }
            current = (parentRef as! AXUIElement)
        }
        return false
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
