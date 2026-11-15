import AppKit
import Foundation
import Sparkle

extension Notification.Name {
    static let toolboxWillPresentUpdateWindow = Notification.Name("toolbox.willPresentUpdateWindow")
}

/// Manages Sparkle software updates cleanly without intrusive stock dialogs.
///
/// Checking runs inline inside Settings and the menu bar popover using a smooth progress bar.
/// The custom dark update dialog (`ToolboxUpdateWindowController`) is only shown when a newer
/// version is actually found, or when the user chooses to inspect/install a pending update.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    private static let lastCheckedDefaultsKey = "toolbox.lastUpdateCheckAt"
    private static let minimumCheckVisualDuration: TimeInterval = 0.55

    private static var isIsolatedMode: Bool {
        CommandLine.arguments.contains("--self-test")
            || CommandLine.arguments.contains("--snapshot-ui")
            || !(ProcessInfo.processInfo.environment["TOOLBOX_CONFIG_DIR"] ?? "").isEmpty
    }

    @Published private(set) var isSparkleAvailable = false
    @Published private(set) var currentVersion: String
    @Published private(set) var buildNumber: String
    @Published private(set) var isChecking = false
    @Published private(set) var checkProgress: Double = 0.0
    @Published private(set) var pendingUpdateVersion: String?
    @Published private(set) var pendingUpdateSizeBytes: Int64 = 0
    @Published private(set) var pendingReleaseNotesHTML: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastCheckFailed = false
    @Published private(set) var lastCheckError: String?
    @Published private(set) var statusText = "Up to date"

    @Published var automaticallyChecksForUpdates: Bool = true {
        didSet {
            guard !isSyncingAutoCheck else { return }
            updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private var updater: SPUUpdater?
    private var userDriver: ToolboxUserDriver?
    private var isSyncingAutoCheck = false
    private var progressTimer: Timer?
    private var safetyTimer: Timer?
    private var checkStartedAt: Date?
    private var pendingCompletionWork: DispatchWorkItem?
    private var activeCheckCancellation: (() -> Void)?

    internal lazy var updateWindowController = ToolboxUpdateWindowController()

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private override init() {
        let info = Bundle.main.infoDictionary
        self.currentVersion = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        self.buildNumber = (info?["CFBundleVersion"] as? String) ?? "1"
        super.init()

        if !Self.isIsolatedMode {
            self.lastCheckedAt = UserDefaults.standard.object(forKey: Self.lastCheckedDefaultsKey) as? Date
        }

        configureSparkleIfBundled()
    }

    var formattedLastChecked: String {
        formattedLastChecked(relativeTo: Date())
    }

    func formattedLastChecked(relativeTo now: Date) -> String {
        guard let lastCheckedAt else { return "Never" }
        let timeStr = Self.shortTimeFormatter.string(from: lastCheckedAt)
        let elapsed = now.timeIntervalSince(lastCheckedAt)
        if elapsed >= -5 && elapsed < 60 {
            return "Just now (\(timeStr))"
        }
        let cal = Calendar.current
        if cal.isDate(lastCheckedAt, inSameDayAs: now) {
            return "Today at \(timeStr)"
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(lastCheckedAt, inSameDayAs: yesterday) {
            return "Yesterday at \(timeStr)"
        }
        return Self.fullDateFormatter.string(from: lastCheckedAt)
    }

    var formattedPendingSize: String? {
        guard pendingUpdateSizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: pendingUpdateSizeBytes, countStyle: .file)
    }

    private func configureSparkleIfBundled() {
        // Sparkle requires running from a signed/bundled .app with Info.plist and SUFeedURL.
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            statusText = "Available when running from Toolbox.app"
            return
        }

        let driver = ToolboxUserDriver(manager: self)
        let spu = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: self
        )

        do {
            try spu.start()
            self.userDriver = driver
            self.updater = spu
            self.isSparkleAvailable = true
            self.isSyncingAutoCheck = true
            self.automaticallyChecksForUpdates = spu.automaticallyChecksForUpdates
            self.isSyncingAutoCheck = false
            if self.lastCheckedAt == nil, !Self.isIsolatedMode {
                self.lastCheckedAt = spu.lastUpdateCheckDate
            }
        } catch {
            self.lastCheckFailed = true
            self.lastCheckError = error.localizedDescription
            self.statusText = "Updater unavailable: \(error.localizedDescription)"
            NSLog("Toolbox: Sparkle updater failed to start: \(error)")
        }
    }

    /// Starts a silent inline update check (no "Checking…" or "Up to date" modal dialog).
    /// Only opens `ToolboxUpdateWindowController` if a newer update is actually available.
    func checkForUpdates() {
        guard !isChecking else { return }

        guard let updater else {
            lastCheckFailed = true
            lastCheckError = "Available when running from Toolbox.app"
            statusText = "Available in Toolbox.app"
            return
        }

        beginCheckingState()
        updater.checkForUpdates()
    }

    func cancelActiveCheck() {
        activeCheckCancellation?()
        activeCheckCancellation = nil
        resetCheckingTimers()
        isChecking = false
        checkProgress = 0
        statusText = pendingUpdateVersion != nil
            ? "Update available: v\(pendingUpdateVersion!)"
            : (lastCheckedAt != nil ? "Up to date" : "Automatic checks enabled")
    }

    // MARK: - Inline Check Progress State Machine

    fileprivate func beginCheckingStateIfNeeded() {
        if !isChecking {
            beginCheckingState()
        }
    }

    private func beginCheckingState() {
        pendingCompletionWork?.cancel()
        pendingCompletionWork = nil
        resetCheckingTimers()

        checkStartedAt = Date()
        isChecking = true
        lastCheckFailed = false
        lastCheckError = nil
        checkProgress = 0.10
        statusText = "Checking for updates…"

        let progress = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isChecking else { return }
                let next = self.checkProgress + (0.90 - self.checkProgress) * 0.14 + 0.012
                self.checkProgress = min(0.90, next)
            }
        }
        RunLoop.main.add(progress, forMode: .common)
        progressTimer = progress

        let safety = Timer(timeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isChecking else { return }
                self.finishCheckingImmediately(status: "Up to date")
            }
        }
        RunLoop.main.add(safety, forMode: .common)
        safetyTimer = safety
    }

    fileprivate func setActiveCheckCancellation(_ cancellation: @escaping () -> Void) {
        activeCheckCancellation = cancellation
    }

    fileprivate func handleCheckFoundNothing() {
        let now = Date()
        pendingUpdateVersion = nil
        pendingUpdateSizeBytes = 0
        pendingReleaseNotesHTML = nil

        completeCheckWithMinimumDuration(checkedAt: now) { [weak self] in
            guard let self else { return }
            self.lastCheckFailed = false
            self.lastCheckError = nil
            self.recordLastChecked(now)
            self.statusText = "You're on the latest version"
        }
    }

    fileprivate func handleCheckFailed(_ message: String) {
        completeCheckWithMinimumDuration(checkedAt: nil) { [weak self] in
            guard let self else { return }
            self.lastCheckFailed = true
            self.lastCheckError = message
            self.statusText = "Couldn't check for updates"
        }
    }

    fileprivate func handleUpdateFound(
        item: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let available = item.displayVersionString
        guard Self.isNewerVersion(available, than: currentVersion) else {
            reply(.dismiss)
            handleCheckFoundNothing()
            return
        }

        let now = Date()
        recordLastChecked(now)
        lastCheckFailed = false
        lastCheckError = nil
        pendingUpdateVersion = available
        pendingUpdateSizeBytes = Int64(item.contentLength)
        pendingReleaseNotesHTML = item.itemDescription
        statusText = "Update available: v\(available)"

        finishCheckingImmediately(status: "Update available: v\(available)")
        updateWindowController.showUpdateFound(
            item: item,
            currentVersion: currentVersion,
            state: state,
            reply: reply
        )
    }

    fileprivate func handleInstallerChoice(_ choice: SPUUserUpdateChoice) {
        if choice == .install {
            pendingUpdateVersion = nil
        }
    }

    private func completeCheckWithMinimumDuration(checkedAt: Date?, apply: @escaping @MainActor () -> Void) {
        let started = checkStartedAt
        activeCheckCancellation = nil
        progressTimer?.invalidate()
        progressTimer = nil
        safetyTimer?.invalidate()
        safetyTimer = nil

        guard let started, isChecking else {
            checkStartedAt = nil
            checkProgress = 0
            isChecking = false
            apply()
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        let holdRemaining = max(0, Self.minimumCheckVisualDuration - elapsed)

        pendingCompletionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.checkProgress = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self else { return }
                self.checkStartedAt = nil
                self.isChecking = false
                self.checkProgress = 0.0
                apply()
            }
        }
        pendingCompletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdRemaining, execute: work)
    }

    private func finishCheckingImmediately(status: String) {
        pendingCompletionWork?.cancel()
        pendingCompletionWork = nil
        activeCheckCancellation = nil
        resetCheckingTimers()
        isChecking = false
        checkProgress = 0
        statusText = status
    }

    private func resetCheckingTimers() {
        progressTimer?.invalidate()
        progressTimer = nil
        safetyTimer?.invalidate()
        safetyTimer = nil
        checkStartedAt = nil
    }

    private func recordLastChecked(_ date: Date) {
        lastCheckedAt = date
        if !Self.isIsolatedMode {
            UserDefaults.standard.set(date, forKey: Self.lastCheckedDefaultsKey)
        }
    }

    /// True when `candidate` represents a strictly newer version than `current`.
    /// Numeric components are compared numerically ("1.10" > "1.9"). When base versions match,
    /// a plain release supersedes a suffixed prerelease ("1.2" > "1.2-beta").
    static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let cleanCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseCandidate = cleanCandidate.split(separator: "-", maxSplits: 1).first.map(String.init) ?? cleanCandidate
        let baseCurrent = cleanCurrent.split(separator: "-", maxSplits: 1).first.map(String.init) ?? cleanCurrent
        if baseCandidate == baseCurrent {
            return !cleanCandidate.contains("-") && cleanCurrent.contains("-")
        }
        return baseCandidate.compare(baseCurrent, options: .numeric) == .orderedDescending
    }

    // MARK: - Testing & Snapshot Support

    func configureStateForTesting(
        isSparkleAvailable: Bool? = nil,
        isChecking: Bool = false,
        checkProgress: Double = 0.0,
        pendingUpdateVersion: String? = nil,
        pendingUpdateSizeBytes: Int64 = 0,
        lastCheckedAt: Date? = nil,
        lastCheckFailed: Bool = false,
        lastCheckError: String? = nil
    ) {
        resetCheckingTimers()
        pendingCompletionWork?.cancel()
        pendingCompletionWork = nil
        if let isSparkleAvailable {
            self.isSparkleAvailable = isSparkleAvailable
        }
        self.isChecking = isChecking
        self.checkProgress = checkProgress
        self.pendingUpdateVersion = pendingUpdateVersion
        self.pendingUpdateSizeBytes = pendingUpdateSizeBytes
        self.lastCheckedAt = lastCheckedAt
        self.lastCheckFailed = lastCheckFailed
        self.lastCheckError = lastCheckError
        if isChecking {
            self.statusText = "Checking for updates…"
        } else if let pendingUpdateVersion {
            self.statusText = "Update available: v\(pendingUpdateVersion)"
        } else if lastCheckFailed {
            self.statusText = "Couldn't check for updates"
        } else {
            self.statusText = "You're on the latest version"
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateManager: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let size = Int64(item.contentLength)
        let notes = item.itemDescription
        Task { @MainActor in
            guard Self.isNewerVersion(version, than: self.currentVersion) else {
                self.pendingUpdateVersion = nil
                self.handleCheckFoundNothing()
                return
            }
            self.pendingUpdateVersion = version
            self.pendingUpdateSizeBytes = size
            self.pendingReleaseNotesHTML = notes
            self.lastCheckFailed = false
            self.lastCheckError = nil
            self.recordLastChecked(Date())
            self.statusText = "Update available: v\(version)"
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.handleCheckFoundNothing()
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let ns = error as NSError
        let isNoUpdate = ns.domain == SUSparkleErrorDomain && ns.code == Int(SUError.noUpdateError.rawValue)
        let rawReason = ns.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let reason = rawReason.map { SPUNoUpdateFoundReason(rawValue: OSStatus($0.intValue)) }
        let msg = error.localizedDescription
        Task { @MainActor in
            if isNoUpdate && (reason == nil || reason == .onLatestVersion || reason == .onNewerThanLatestVersion || reason == .unknown) {
                self.handleCheckFoundNothing()
            } else {
                self.handleCheckFailed(msg)
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        if ns.domain == SUSparkleErrorDomain,
           let code = SUError(rawValue: OSStatus(ns.code)),
           code == .noUpdateError || code == .installationCanceledError || code == .installationAuthorizeLaterError {
            return
        }
        let msg = error.localizedDescription
        Task { @MainActor in
            self.handleCheckFailed(msg)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            self.handleInstallerChoice(choice)
        }
    }
}

// MARK: - Quiet Custom SPUUserDriver

/// Custom `SPUUserDriver` that keeps update checks silent/inline inside Settings & the menu bar,
/// only presenting `ToolboxUpdateWindowController` when a genuinely newer version is found
/// or while downloading/installing an update.
@MainActor
final class ToolboxUserDriver: NSObject, SPUUserDriver {
    private unowned let manager: UpdateManager

    init(manager: UpdateManager) {
        self.manager = manager
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        manager.updateWindowController.showPermission(reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        manager.setActiveCheckCancellation(cancellation)
        manager.beginCheckingStateIfNeeded()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        manager.handleUpdateFound(item: appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        manager.updateWindowController.showReleaseNotes(downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Keep the inline appcast description or fallback text already rendered.
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        let rawReason = ns.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let reason = rawReason.map { SPUNoUpdateFoundReason(rawValue: OSStatus($0.intValue)) }
        if reason == nil || reason == .onLatestVersion || reason == .onNewerThanLatestVersion || reason == .unknown {
            manager.handleCheckFoundNothing()
        } else {
            manager.handleCheckFailed(error.localizedDescription)
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if manager.updateWindowController.window.isVisible {
            manager.handleCheckFailed(error.localizedDescription)
            manager.updateWindowController.showError(error.localizedDescription, acknowledgement: acknowledgement)
        } else {
            manager.handleCheckFailed(error.localizedDescription)
            acknowledgement()
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        manager.updateWindowController.showDownloadStarted(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        manager.updateWindowController.setExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        manager.updateWindowController.addReceivedBytes(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        manager.updateWindowController.showExtracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        manager.updateWindowController.setExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        manager.updateWindowController.showReady(reply: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        manager.updateWindowController.showInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        manager.updateWindowController.dismiss()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        manager.updateWindowController.dismiss()
    }

    func showUpdateInFocus() {
        guard manager.updateWindowController.window.isVisible else { return }
        manager.updateWindowController.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Custom Dark Update Window

private final class UpdateActionButton: NSButton {
    override func resetCursorRects() {
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

/// Custom dark update dialog shown only when a newer Toolbox version is available or actively installing.
@MainActor
final class ToolboxUpdateWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow

    private let panelBg = NSColor(red: 0.071, green: 0.082, blue: 0.114, alpha: 1)    // #12151d
    private let cardBg = NSColor(red: 0.090, green: 0.106, blue: 0.145, alpha: 1)     // #171b25
    private let borderCol = NSColor(red: 0.137, green: 0.165, blue: 0.220, alpha: 1)  // #232a38
    private let textCol = NSColor(red: 0.910, green: 0.925, blue: 0.957, alpha: 1)    // #e8ecf4
    private let dimCol = NSColor(red: 0.545, green: 0.580, blue: 0.655, alpha: 1)     // #8b94a7
    private let accentBlue = NSColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1) // #3b82f6

    private let badgePill = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let notesCard = NSView()
    private let notesScroll = NSScrollView()
    private let notesTextView = NSTextView()
    private let progressWrap = NSView()
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressFillWidth: NSLayoutConstraint!
    private let progressLabel = NSTextField(labelWithString: "")
    private let secondaryBtn = UpdateActionButton(title: "Later", target: nil, action: nil)
    private let primaryBtn = UpdateActionButton(title: "Update & Relaunch", target: nil, action: nil)

    private var downloadCancel: (() -> Void)?
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var errorAck: (() -> Void)?
    private var permReply: ((SUUpdatePermissionResponse) -> Void)?

    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var isProgrammaticClose = false

    internal var currentTitleForTesting: String { titleLabel.stringValue }
    internal var currentSubtitleForTesting: String { subtitleLabel.stringValue }

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 468, height: 340),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = panelBg
        window.isReleasedWhenClosed = false
        window.center()
        super.init()
        window.delegate = self
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = panelBg.cgColor
        window.contentView = root

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(icon)

        badgePill.wantsLayer = true
        badgePill.layer?.backgroundColor = accentBlue.withAlphaComponent(0.16).cgColor
        badgePill.layer?.borderColor = accentBlue.withAlphaComponent(0.38).cgColor
        badgePill.layer?.borderWidth = 1
        badgePill.layer?.cornerRadius = 9
        badgePill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(badgePill)

        badgeLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        badgeLabel.textColor = NSColor(red: 0.45, green: 0.69, blue: 1.0, alpha: 1.0)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgePill.addSubview(badgeLabel)

        titleLabel.font = .systemFont(ofSize: 15.5, weight: .bold)
        titleLabel.textColor = textCol
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLabel)

        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = dimCol
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(subtitleLabel)

        notesCard.wantsLayer = true
        notesCard.layer?.backgroundColor = cardBg.cgColor
        notesCard.layer?.borderColor = borderCol.cgColor
        notesCard.layer?.borderWidth = 1
        notesCard.layer?.cornerRadius = 10
        notesCard.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(notesCard)

        notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true
        notesScroll.drawsBackground = false
        notesScroll.borderType = .noBorder
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        notesCard.addSubview(notesScroll)

        notesTextView.isEditable = false
        notesTextView.isSelectable = true
        notesTextView.drawsBackground = false
        notesTextView.textContainerInset = NSSize(width: 10, height: 10)
        notesTextView.font = .systemFont(ofSize: 12)
        notesTextView.textColor = textCol
        notesTextView.isVerticallyResizable = true
        notesTextView.isHorizontallyResizable = false
        notesTextView.autoresizingMask = [.width]
        notesTextView.textContainer?.widthTracksTextView = true
        notesScroll.documentView = notesTextView

        progressWrap.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(progressWrap)

        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = cardBg.cgColor
        progressTrack.layer?.borderColor = borderCol.cgColor
        progressTrack.layer?.borderWidth = 1
        progressTrack.layer?.cornerRadius = 4
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressWrap.addSubview(progressTrack)

        progressFill.wantsLayer = true
        progressFill.layer?.backgroundColor = accentBlue.cgColor
        progressFill.layer?.cornerRadius = 3
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        progressFillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        progressLabel.textColor = dimCol
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressWrap.addSubview(progressLabel)

        styleButton(secondaryBtn, primary: false)
        secondaryBtn.target = self
        secondaryBtn.action = #selector(onSecondary)
        root.addSubview(secondaryBtn)

        styleButton(primaryBtn, primary: true)
        primaryBtn.target = self
        primaryBtn.action = #selector(onPrimary)
        root.addSubview(primaryBtn)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),

            badgePill.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            badgePill.topAnchor.constraint(equalTo: icon.topAnchor, constant: -1),

            badgeLabel.leadingAnchor.constraint(equalTo: badgePill.leadingAnchor, constant: 8),
            badgeLabel.trailingAnchor.constraint(equalTo: badgePill.trailingAnchor, constant: -8),
            badgeLabel.topAnchor.constraint(equalTo: badgePill.topAnchor, constant: 2),
            badgeLabel.bottomAnchor.constraint(equalTo: badgePill.bottomAnchor, constant: -2),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            titleLabel.topAnchor.constraint(equalTo: badgePill.bottomAnchor, constant: 4),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            notesCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            notesCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            notesCard.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            notesCard.bottomAnchor.constraint(equalTo: secondaryBtn.topAnchor, constant: -16),

            notesScroll.leadingAnchor.constraint(equalTo: notesCard.leadingAnchor, constant: 4),
            notesScroll.trailingAnchor.constraint(equalTo: notesCard.trailingAnchor, constant: -4),
            notesScroll.topAnchor.constraint(equalTo: notesCard.topAnchor, constant: 4),
            notesScroll.bottomAnchor.constraint(equalTo: notesCard.bottomAnchor, constant: -4),

            progressWrap.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            progressWrap.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            progressWrap.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 20),
            progressWrap.heightAnchor.constraint(equalToConstant: 36),

            progressTrack.leadingAnchor.constraint(equalTo: progressWrap.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: progressWrap.trailingAnchor),
            progressTrack.topAnchor.constraint(equalTo: progressWrap.topAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 8),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressFillWidth,

            progressLabel.leadingAnchor.constraint(equalTo: progressWrap.leadingAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: progressWrap.trailingAnchor),
            progressLabel.topAnchor.constraint(equalTo: progressTrack.bottomAnchor, constant: 8),

            primaryBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            primaryBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            primaryBtn.heightAnchor.constraint(equalToConstant: 32),
            primaryBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 136),

            secondaryBtn.trailingAnchor.constraint(equalTo: primaryBtn.leadingAnchor, constant: -10),
            secondaryBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            secondaryBtn.heightAnchor.constraint(equalToConstant: 32),
            secondaryBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
        ])
    }

    private func styleButton(_ btn: NSButton, primary: Bool) {
        btn.isBordered = false
        btn.wantsLayer = true
        btn.font = .systemFont(ofSize: 12.5, weight: .semibold)
        btn.contentTintColor = primary ? .white : textCol
        btn.layer?.backgroundColor = (primary ? accentBlue : cardBg).cgColor
        btn.layer?.cornerRadius = 8
        if !primary {
            btn.layer?.borderColor = borderCol.cgColor
            btn.layer?.borderWidth = 1
        }
        btn.translatesAutoresizingMaskIntoConstraints = false
    }

    private func resize(width: CGFloat = 468, height: CGFloat) {
        var f = window.frame
        let dy = height - f.height
        f.origin.y -= dy
        f.size.width = width
        f.size.height = height
        window.setFrame(f, display: true, animate: false)
    }

    private func present() {
        NotificationCenter.default.post(name: .toolboxWillPresentUpdateWindow, object: nil)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func clearCallbacks() {
        downloadCancel = nil
        updateReply = nil
        readyReply = nil
        errorAck = nil
        permReply = nil
    }

    private func setNotesPlain(_ text: String) {
        notesTextView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: textCol,
            ]
        ))
    }

    private func setNotesHTML(_ data: Data) {
        if let attr = try? NSMutableAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) {
            let full = NSRange(location: 0, length: attr.length)
            attr.addAttribute(.foregroundColor, value: textCol, range: full)
            attr.enumerateAttribute(.font, in: full) { val, r, _ in
                if let f = val as? NSFont {
                    let isBold = f.fontDescriptor.symbolicTraits.contains(.bold)
                    let sz = max(12, min(14.5, f.pointSize))
                    attr.addAttribute(.font, value: NSFont.systemFont(ofSize: sz, weight: isBold ? .semibold : .regular), range: r)
                }
            }
            notesTextView.textStorage?.setAttributedString(attr)
        }
    }

    // MARK: - States

    func showPermission(reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        clearCallbacks()
        permReply = reply
        badgeLabel.stringValue = "Automatic Updates"
        badgePill.isHidden = false
        titleLabel.stringValue = "Check for Updates Automatically?"
        subtitleLabel.stringValue = "Keeps Toolbox up to date in the background"
        notesCard.isHidden = false
        progressWrap.isHidden = true
        setNotesPlain("Toolbox can check GitHub Releases automatically in the background and show a badge when a newer version is available.")
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Not Now"
        primaryBtn.isHidden = false
        primaryBtn.title = "Enable Checks"
        resize(height: 250)
        present()
    }

    func showUpdateFound(
        item: SUAppcastItem,
        currentVersion: String,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        clearCallbacks()
        updateReply = reply
        let newVer = item.displayVersionString
        let sizeStr = item.contentLength > 0
            ? " · " + ByteCountFormatter.string(fromByteCount: Int64(item.contentLength), countStyle: .file)
            : ""
        badgeLabel.stringValue = "New Update Available"
        badgePill.isHidden = false
        titleLabel.stringValue = "Toolbox v\(newVer) Available"
        subtitleLabel.stringValue = "Current version: v\(currentVersion)\(sizeStr)"
        notesCard.isHidden = false
        progressWrap.isHidden = true

        if let desc = item.itemDescription, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let data = desc.data(using: .utf8), desc.contains("<") {
                setNotesHTML(data)
            } else {
                setNotesPlain(desc)
            }
        } else {
            setNotesPlain("A new signed release of Toolbox is ready to download and install.")
        }

        secondaryBtn.isHidden = false
        secondaryBtn.title = "Later"
        primaryBtn.isHidden = false
        primaryBtn.title = state.stage == .downloaded ? "Install & Relaunch" : "Update & Relaunch"
        resize(height: 344)
        present()
    }

    func populatePreviewAvailable(version: String, currentVersion: String, sizeBytes: Int64, notes: String) {
        clearCallbacks()
        let sizeStr = sizeBytes > 0
            ? " · " + ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
            : ""
        badgeLabel.stringValue = "New Update Available"
        badgePill.isHidden = false
        titleLabel.stringValue = "Toolbox v\(version) Available"
        subtitleLabel.stringValue = "Current version: v\(currentVersion)\(sizeStr)"
        notesCard.isHidden = false
        progressWrap.isHidden = true
        if let data = notes.data(using: .utf8), notes.contains("<") {
            setNotesHTML(data)
        } else {
            setNotesPlain(notes)
        }
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Later"
        primaryBtn.isHidden = false
        primaryBtn.title = "Update & Relaunch"
        updateReply = { [weak self] _ in self?.dismiss() }
        resize(height: 344)
    }

    func showReleaseNotes(_ data: SPUDownloadData) {
        setNotesHTML(data.data)
    }

    func showDownloadStarted(cancellation: @escaping () -> Void) {
        clearCallbacks()
        downloadCancel = cancellation
        expectedBytes = 0
        receivedBytes = 0
        badgeLabel.stringValue = "Downloading"
        badgePill.isHidden = false
        titleLabel.stringValue = "Downloading Update…"
        subtitleLabel.stringValue = "Signature will be verified before installation"
        notesCard.isHidden = true
        progressWrap.isHidden = false
        progressFillWidth.constant = 16
        progressLabel.stringValue = "Starting download…"
        primaryBtn.isHidden = true
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Cancel"
        resize(height: 196)
        present()
    }

    func setExpectedLength(_ len: UInt64) {
        expectedBytes = len
        updateDownloadProgress()
    }

    func addReceivedBytes(_ len: UInt64) {
        receivedBytes += len
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        let trackW = max(1, progressTrack.bounds.width > 0 ? progressTrack.bounds.width : 424)
        if expectedBytes > 0 {
            let frac = min(1.0, Double(receivedBytes) / Double(expectedBytes))
            progressFillWidth.constant = max(8, trackW * frac)
            let got = ByteCountFormatter.string(fromByteCount: Int64(receivedBytes), countStyle: .file)
            let tot = ByteCountFormatter.string(fromByteCount: Int64(expectedBytes), countStyle: .file)
            progressLabel.stringValue = "\(got) of \(tot) (\(Int(frac * 100))%)"
        } else {
            let got = ByteCountFormatter.string(fromByteCount: Int64(receivedBytes), countStyle: .file)
            progressLabel.stringValue = "Downloaded \(got)…"
        }
    }

    func showExtracting() {
        downloadCancel = nil
        badgeLabel.stringValue = "Verifying"
        badgePill.isHidden = false
        titleLabel.stringValue = "Preparing Update…"
        subtitleLabel.stringValue = "Extracting archive and verifying signature"
        progressFillWidth.constant = 0
        progressLabel.stringValue = "Extracting…"
        secondaryBtn.isHidden = true
        primaryBtn.isHidden = true
    }

    func setExtractionProgress(_ progress: Double) {
        let trackW = max(1, progressTrack.bounds.width > 0 ? progressTrack.bounds.width : 424)
        progressFillWidth.constant = max(8, trackW * min(1.0, max(0.0, progress)))
        progressLabel.stringValue = "Extracting… \(Int(progress * 100))%"
    }

    func showReady(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        clearCallbacks()
        readyReply = reply
        badgeLabel.stringValue = "Ready"
        badgePill.isHidden = false
        titleLabel.stringValue = "Ready to Install"
        subtitleLabel.stringValue = "Toolbox will relaunch automatically to complete installation"
        notesCard.isHidden = true
        progressWrap.isHidden = false
        let trackW = max(1, progressTrack.bounds.width > 0 ? progressTrack.bounds.width : 424)
        progressFillWidth.constant = trackW
        progressLabel.stringValue = "Download verified ✓"
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Later"
        primaryBtn.isHidden = false
        primaryBtn.title = "Restart & Update"
        resize(height: 196)
        present()
    }

    func showInstalling() {
        clearCallbacks()
        badgeLabel.stringValue = "Installing"
        badgePill.isHidden = false
        titleLabel.stringValue = "Installing Update…"
        subtitleLabel.stringValue = "Toolbox will reopen in a moment"
        secondaryBtn.isHidden = true
        primaryBtn.isHidden = true
        progressLabel.stringValue = "Applying update…"
    }

    func showError(_ message: String, acknowledgement: @escaping () -> Void) {
        clearCallbacks()
        errorAck = acknowledgement
        badgeLabel.stringValue = "Update Error"
        badgePill.isHidden = false
        titleLabel.stringValue = "Update Couldn't Complete"
        subtitleLabel.stringValue = "Your current version is unchanged"
        notesCard.isHidden = false
        progressWrap.isHidden = true
        setNotesPlain(message)
        secondaryBtn.isHidden = true
        primaryBtn.isHidden = false
        primaryBtn.title = "OK"
        resize(height: 244)
        present()
    }

    func dismiss() {
        clearCallbacks()
        isProgrammaticClose = true
        window.orderOut(nil)
        isProgrammaticClose = false
    }

    @objc private func onPrimary() {
        if let cb = updateReply {
            clearCallbacks()
            cb(.install)
        } else if let cb = readyReply {
            clearCallbacks()
            cb(.install)
        } else if let cb = permReply {
            clearCallbacks()
            cb(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
            dismiss()
        } else if let cb = errorAck {
            clearCallbacks()
            cb()
            dismiss()
        }
    }

    @objc private func onSecondary() {
        if let cb = downloadCancel {
            clearCallbacks()
            cb()
            dismiss()
        } else if let cb = updateReply {
            clearCallbacks()
            cb(.dismiss)
            dismiss()
        } else if let cb = readyReply {
            clearCallbacks()
            cb(.dismiss)
            dismiss()
        } else if let cb = permReply {
            clearCallbacks()
            cb(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
            dismiss()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if isProgrammaticClose { return }
        if let cb = downloadCancel { clearCallbacks(); cb() }
        else if let cb = updateReply { clearCallbacks(); cb(.dismiss) }
        else if let cb = readyReply { clearCallbacks(); cb(.dismiss) }
        else if let cb = permReply { clearCallbacks(); cb(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)) }
        else if let cb = errorAck { clearCallbacks(); cb() }
    }
}
