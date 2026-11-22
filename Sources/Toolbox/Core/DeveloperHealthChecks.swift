import AppKit
import Darwin
import Foundation
import Security
import ServiceManagement

/// Severity level for live Developer Tools health checks.
enum HealthCheckSeverity: String, Sendable {
    case pass
    case warning
    case fail

    var label: String {
        switch self {
        case .pass: return "Pass"
        case .warning: return "Warning"
        case .fail: return "Fail"
        }
    }
}

/// Single concrete diagnostic check result produced by `DeveloperHealthCheckRunner`.
struct HealthCheckItem: Identifiable, Sendable {
    let id: String
    let title: String
    let category: String
    let severity: HealthCheckSeverity
    let summary: String
    let detail: String?
}

/// Result of pinging the configured `SUFeedURL` Sparkle appcast XML.
struct AppcastProbeResult: Sendable {
    let urlString: String
    let httpStatus: Int?
    let latestVersion: String?
    let isNewerThanCurrent: Bool
    let itemCount: Int
    let checkedAt: Date
    let errorMessage: String?
}

/// Result of running macOS Gatekeeper (`spctl --assess`) on demand.
struct GatekeeperProbeResult: Sendable {
    let accepted: Bool
    let sourceLabel: String
    let rawOutput: String
    let checkedAt: Date
}

/// Detailed macOS code signing, Hardened Runtime, CDHash, requirement, and entitlement inspection.
struct CodeSigningInspection: Sendable {
    let isValid: Bool
    let summary: String
    let signingIdentifier: String
    let teamIdentifier: String?
    let cdHashHex: String?
    let isHardenedRuntime: Bool
    let isAdHoc: Bool
    let authorityChain: [String]
    let signedTimestamp: Date?
    let designatedRequirement: String?
    let entitlements: [String: String]
    let isSandboxed: Bool
}

/// Immutable snapshot of live Toolbox runtime diagnostics for inspection and bug reports.
struct RuntimeDiagnosticsSnapshot: Sendable {
    static let processStartDate = Date()

    struct ModuleEntry: Identifiable, Sendable {
        let id: String
        let name: String
        let isEnabled: Bool
        let isRunning: Bool
        let status: String
    }

    let version: String
    let buildNumber: String
    let bundleIdentifier: String
    let bundlePath: String
    let executablePath: String
    let isBundledApp: Bool
    let signing: CodeSigningInspection
    var codeSigningSummary: String { signing.summary }
    var isSignatureValid: Bool { signing.isValid }
    let hasQuarantineAttribute: Bool
    let isAppTranslocated: Bool
    let hasCodeResourcesFile: Bool
    let sparkleFrameworkVersion: String?
    let sparklePublicKeySummary: String?
    let hasUpdaterHelperApp: Bool
    let isSparkleAvailable: Bool
    let sparkleFeedURL: String?
    let lastUpdateCheckAt: Date?
    let configPath: String
    let configFileSizeBytes: Int64?
    let configModifiedAt: Date?
    let isConfigIsolated: Bool
    let pid: Int32
    let architectureSummary: String
    let macOSVersion: String
    let physicalMemoryFormatted: String
    let uptimeSeconds: TimeInterval
    let activationPolicyLabel: String
    let isLSUIElement: Bool
    let runningInstancesCount: Int
    let loginItemStatusLabel: String
    let actualAccessibilityGranted: Bool
    let simulatedAccessibilityOverride: Bool?
    let appEnabled: Bool
    let hotkeyErrorCount: Int
    let hotkeyErrors: [String: String]
    let clipboardEntryCount: Int
    let pinnedClipboardCount: Int
    let scrollObservedCount: Int
    let scrollInvertedCount: Int
    let customCommandsCount: Int
    let modules: [ModuleEntry]

    @MainActor
    static func capture() -> RuntimeDiagnosticsSnapshot {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let buildNumber = (info?["CFBundleVersion"] as? String) ?? version
        let bundleID = Bundle.main.bundleIdentifier ?? "(none)"
        let bundlePath = Bundle.main.bundlePath
        let executablePath = Bundle.main.executablePath ?? "(unknown)"
        let isBundled = bundlePath.hasSuffix(".app")
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let pubKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let signing = inspectCodeSignature()

        let fm = FileManager.default
        let codeResourcesPath = Bundle.main.bundleURL.appendingPathComponent("Contents/_CodeSignature/CodeResources").path
        let sparkleInfoURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Resources/Info.plist")
        let updaterHelperPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Updater.app").path
        let sparklePlist = NSDictionary(contentsOf: sparkleInfoURL) as? [String: Any]
        let sparkleVersion = sparklePlist?["CFBundleShortVersionString"] as? String
        let sparkleKeySummary: String? = {
            guard let pubKey, !pubKey.isEmpty else { return nil }
            return "Ed25519 (\(pubKey.count) chars · \(pubKey.prefix(8))…)"
        }()

        let configManager = ConfigManager.shared
        let configOverride = !(ProcessInfo.processInfo.environment["TOOLBOX_CONFIG_DIR"] ?? "").isEmpty
        let configAttrs = try? fm.attributesOfItem(atPath: configManager.configURL.path)
        let configSize = (configAttrs?[.size] as? NSNumber)?.int64Value
        let configModDate = configAttrs?[.modificationDate] as? Date

        let permissions = PermissionsManager.shared
        let updateManager = UpdateManager.shared
        let hotKeys = HotKeyManager.shared
        let registry = ModuleRegistry.shared

        let moduleEntries = registry.modules.map { module in
            ModuleEntry(
                id: module.id,
                name: module.name,
                isEnabled: module.isEnabled(in: configManager.config),
                isRunning: module.isRunning,
                status: module.statusText(
                    in: configManager.config,
                    accessibilityGranted: permissions.actualAccessibilityGranted
                )
            )
        }

        let policyLabel: String = {
            switch NSApp.activationPolicy() {
            case .regular: return "Regular (Dock + Menu Bar)"
            case .accessory: return "Accessory (Menu Bar Only)"
            case .prohibited: return "Prohibited"
            @unknown default: return "Unknown"
            }
        }()

        let loginLabel: String = {
            switch SMAppService.mainApp.status {
            case .enabled: return "Enabled"
            case .notRegistered: return "Not Registered"
            case .requiresApproval: return "Requires Approval in System Settings"
            case .notFound: return isBundled ? "Not Found" : "Unavailable Outside .app"
            @unknown default: return "Unknown"
            }
        }()

        let runningCount = Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).count
        } ?? 1

        let memFormatter = ByteCountFormatter()
        memFormatter.countStyle = .memory

        let clipboardEntries = registry.clipboard.entries
        let pinnedCount = clipboardEntries.filter(\.isPinned).count

        return RuntimeDiagnosticsSnapshot(
            version: version,
            buildNumber: buildNumber,
            bundleIdentifier: bundleID,
            bundlePath: bundlePath,
            executablePath: executablePath,
            isBundledApp: isBundled,
            signing: signing,
            hasQuarantineAttribute: hasQuarantineXattr(atPath: bundlePath),
            isAppTranslocated: bundlePath.contains("/AppTranslocation/"),
            hasCodeResourcesFile: fm.fileExists(atPath: codeResourcesPath),
            sparkleFrameworkVersion: sparkleVersion,
            sparklePublicKeySummary: sparkleKeySummary,
            hasUpdaterHelperApp: fm.fileExists(atPath: updaterHelperPath),
            isSparkleAvailable: updateManager.isSparkleAvailable,
            sparkleFeedURL: feedURL,
            lastUpdateCheckAt: updateManager.lastCheckedAt,
            configPath: configManager.configURL.path,
            configFileSizeBytes: configSize,
            configModifiedAt: configModDate,
            isConfigIsolated: configOverride,
            pid: ProcessInfo.processInfo.processIdentifier,
            architectureSummary: currentArchitectureSummary(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryFormatted: memFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory)),
            uptimeSeconds: max(0, Date().timeIntervalSince(processStartDate)),
            activationPolicyLabel: policyLabel,
            isLSUIElement: (info?["LSUIElement"] as? Bool) ?? false,
            runningInstancesCount: runningCount,
            loginItemStatusLabel: loginLabel,
            actualAccessibilityGranted: permissions.actualAccessibilityGranted,
            simulatedAccessibilityOverride: permissions.simulatedAccessibilityGranted,
            appEnabled: configManager.config.general.appEnabled,
            hotkeyErrorCount: hotKeys.registrationErrors.count,
            hotkeyErrors: hotKeys.registrationErrors,
            clipboardEntryCount: clipboardEntries.count,
            pinnedClipboardCount: pinnedCount,
            scrollObservedCount: registry.scrollDirection.eventsObserved,
            scrollInvertedCount: registry.scrollDirection.eventsInverted,
            customCommandsCount: configManager.config.customCommands.commands.count,
            modules: moduleEntries
        )
    }

    static func currentArchitectureSummary() -> String {
        #if arch(arm64)
        return "arm64 (Apple Silicon Native)"
        #elseif arch(x86_64)
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 {
            return "x86_64 (Rosetta 2)"
        }
        return "x86_64 (Intel Native)"
        #else
        return "Unknown"
        #endif
    }

    static func hasQuarantineXattr(atPath path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    static func inspectCodeSignature() -> CodeSigningInspection {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return CodeSigningInspection(
                isValid: false,
                summary: "Unable to inspect process code signature",
                signingIdentifier: "unknown",
                teamIdentifier: nil,
                cdHashHex: nil,
                isHardenedRuntime: false,
                isAdHoc: false,
                authorityChain: [],
                signedTimestamp: nil,
                designatedRequirement: nil,
                entitlements: [:],
                isSandboxed: false
            )
        }

        let validStatus = SecCodeCheckValidity(code, SecCSFlags(), nil)
        let isValid = (validStatus == errSecSuccess)

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return CodeSigningInspection(
                isValid: isValid,
                summary: isValid ? "Signed (valid)" : "Signature check failed (\(validStatus))",
                signingIdentifier: "unknown",
                teamIdentifier: nil,
                cdHashHex: nil,
                isHardenedRuntime: false,
                isAdHoc: false,
                authorityChain: [],
                signedTimestamp: nil,
                designatedRequirement: nil,
                entitlements: [:],
                isSandboxed: false
            )
        }

        var infoCF: CFDictionary?
        let infoFlags = SecCSFlags(
            rawValue: kSecCSSigningInformation | kSecCSRequirementInformation | kSecCSDynamicInformation
        )
        let infoStatus = SecCodeCopySigningInformation(staticCode, infoFlags, &infoCF)
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
            return CodeSigningInspection(
                isValid: isValid,
                summary: isValid ? "Signed (valid)" : "Invalid signature (\(validStatus))",
                signingIdentifier: "unknown",
                teamIdentifier: nil,
                cdHashHex: nil,
                isHardenedRuntime: false,
                isAdHoc: false,
                authorityChain: [],
                signedTimestamp: nil,
                designatedRequirement: nil,
                entitlements: [:],
                isSandboxed: false
            )
        }

        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let signingID = (info[kSecCodeInfoIdentifier as String] as? String) ?? "unknown"
        let flagsRaw = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isHardened = (flagsRaw & UInt32(SecCodeSignatureFlags.runtime.rawValue)) != 0
        let isAdHoc = (flagsRaw & UInt32(SecCodeSignatureFlags.adhoc.rawValue)) != 0

        let cdHashHex = (info[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }
            .joined()

        let certChain: [String] = (info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? [])
            .compactMap { SecCertificateCopySubjectSummary($0) as String? }

        let signedTimestamp = info[kSecCodeInfoTimestamp as String] as? Date

        var drString: String?
        if let drObj = info[kSecCodeInfoDesignatedRequirement as String] {
            let dr = unsafeBitCast(drObj as AnyObject, to: SecRequirement.self)
            var drCF: CFString?
            if SecRequirementCopyString(dr, [], &drCF) == errSecSuccess, let str = drCF as String? {
                drString = str
            }
        }

        let rawEntitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        var entitlements: [String: String] = [:]
        for (key, value) in rawEntitlements {
            if let boolNum = value as? Bool {
                entitlements[key] = boolNum ? "true" : "false"
            } else {
                entitlements[key] = String(describing: value)
            }
        }
        let isSandboxed = (rawEntitlements["com.apple.security.app-sandbox"] as? Bool) ?? false

        let summary: String = {
            if let teamID {
                return isValid ? "Developer ID (\(teamID)) · \(signingID)" : "Invalid (\(teamID)) · \(signingID)"
            }
            if isAdHoc {
                return isValid ? "Ad-hoc signed · \(signingID)" : "Invalid ad-hoc (\(validStatus))"
            }
            return isValid ? "Signed · \(signingID)" : "Unsigned / Invalid (\(validStatus))"
        }()

        return CodeSigningInspection(
            isValid: isValid,
            summary: summary,
            signingIdentifier: signingID,
            teamIdentifier: teamID,
            cdHashHex: cdHashHex,
            isHardenedRuntime: isHardened,
            isAdHoc: isAdHoc,
            authorityChain: certChain,
            signedTimestamp: signedTimestamp,
            designatedRequirement: drString,
            entitlements: entitlements,
            isSandboxed: isSandboxed
        )
    }

    static func inspectCurrentCodeSignature() -> (isValid: Bool, summary: String) {
        let info = inspectCodeSignature()
        return (info.isValid, info.summary)
    }

    var formattedUptime: String {
        let total = Int(uptimeSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    func formattedSigningReport() -> String {
        var lines: [String] = [
            "Toolbox Signing & Packaging Details",
            "===================================",
            "Signing Summary: \(signing.summary) [valid=\(signing.isValid)]",
            "Signing ID: \(signing.signingIdentifier)",
            "Team ID: \(signing.teamIdentifier ?? "(none)")",
            "Hardened Runtime: \(signing.isHardenedRuntime ? "Yes" : "No")",
            "Ad-hoc: \(signing.isAdHoc ? "Yes" : "No")",
            "CDHash: \(signing.cdHashHex ?? "(none)")",
            "CodeResources Present: \(hasCodeResourcesFile ? "Yes" : "No")",
            "Quarantine Attribute: \(hasQuarantineAttribute ? "Present" : "Clean")",
            "App Translocation: \(isAppTranslocated ? "Yes (Translocated)" : "No")"
        ]
        if let signedTimestamp = signing.signedTimestamp {
            lines.append("Signed Timestamp: \(signedTimestamp.formatted(date: .abbreviated, time: .shortened))")
        }
        if !signing.authorityChain.isEmpty {
            lines.append("Authority Chain: \(signing.authorityChain.joined(separator: " -> "))")
        }
        if let dr = signing.designatedRequirement {
            lines.append("Designated Requirement: \(dr)")
        }
        if signing.entitlements.isEmpty {
            lines.append("Entitlements: None (unsandboxed direct app)")
        } else {
            lines.append("Entitlements:")
            for key in signing.entitlements.keys.sorted() {
                lines.append("  - \(key): \(signing.entitlements[key] ?? "")")
            }
        }
        lines.append("Sparkle Framework: \(sparkleFrameworkVersion ?? "(not bundled)")")
        lines.append("Sparkle Updater.app: \(hasUpdaterHelperApp ? "Present" : "Missing")")
        lines.append("Sparkle EdDSA Key: \(sparklePublicKeySummary ?? "(missing)")")
        lines.append("SUFeedURL: \(sparkleFeedURL ?? "(not configured)")")
        return lines.joined(separator: "\n")
    }

    func formattedReport(healthChecks: [HealthCheckItem] = []) -> String {
        let sizeText = configFileSizeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "Not yet written"

        var lines: [String] = [
            "Toolbox Diagnostics Report",
            "==========================",
            "Version: v\(version) (build \(buildNumber))",
            "PID / Uptime: \(pid) / \(formattedUptime)",
            "Architecture: \(architectureSummary)",
            "macOS: \(macOSVersion) · RAM: \(physicalMemoryFormatted)",
            "Bundle ID: \(bundleIdentifier)",
            "Bundle Path: \(bundlePath)",
            "Executable: \(executablePath)",
            "Bundled App: \(isBundledApp ? "Yes" : "No") · LSUIElement: \(isLSUIElement ? "Yes" : "No")",
            "Activation Policy: \(activationPolicyLabel) · Running Instances: \(runningInstancesCount)",
            "Login Item (SMAppService): \(loginItemStatusLabel)",
            "Code Signature: \(codeSigningSummary) [valid=\(isSignatureValid)]",
            "Hardened Runtime: \(signing.isHardenedRuntime ? "Enabled" : "Disabled") · Sandboxed: \(signing.isSandboxed ? "Yes" : "No")",
            "CDHash: \(signing.cdHashHex ?? "(none)")",
            "Authority Chain: \(signing.authorityChain.isEmpty ? "(none)" : signing.authorityChain.joined(separator: " -> "))",
            "Quarantine / Translocation: quarantine=\(hasQuarantineAttribute), translocated=\(isAppTranslocated)",
            "Config Path: \(configPath) (\(sizeText))",
            "Isolated Config Env: \(isConfigIsolated ? "Yes" : "No")",
            "Sparkle Available: \(isSparkleAvailable ? "Yes" : "No") · Framework: \(sparkleFrameworkVersion ?? "n/a") · Key: \(sparklePublicKeySummary ?? "missing")",
            "Feed URL: \(sparkleFeedURL ?? "(not configured)")",
            "Accessibility (Live): \(actualAccessibilityGranted ? "Granted" : "Not Granted")",
            "Accessibility (Simulated): \(simulatedAccessibilityOverride.map { $0 ? "Forced Granted" : "Forced Not Granted" } ?? "None")",
            "App Master State: \(appEnabled ? "Active" : "Paused")",
            "Clipboard Buffer: \(clipboardEntryCount) items (\(pinnedClipboardCount) pinned) · Custom Commands: \(customCommandsCount)",
            "Scroll Event Tap: \(scrollObservedCount) observed / \(scrollInvertedCount) inverted",
            "Hotkey Errors: \(hotkeyErrorCount)"
        ]

        if let dr = signing.designatedRequirement {
            lines.append("Designated Requirement: \(dr)")
        }

        if !hotkeyErrors.isEmpty {
            for (name, msg) in hotkeyErrors.sorted(by: { $0.key < $1.key }) {
                lines.append("  - \(name): \(msg)")
            }
        }

        lines.append("Modules:")
        for mod in modules {
            lines.append("  - \(mod.name) [\(mod.id)]: enabled=\(mod.isEnabled), running=\(mod.isRunning), status=\(mod.status)")
        }

        if !healthChecks.isEmpty {
            lines.append("Health Checks:")
            for check in healthChecks {
                lines.append("  - [\(check.severity.label.uppercased())] \(check.title): \(check.summary)")
                if let detail = check.detail, !detail.isEmpty {
                    lines.append("      \(detail)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// Runs non-destructive preflight checks against the live running Toolbox environment.
@MainActor
final class DeveloperHealthCheckRunner: ObservableObject {
    static let shared = DeveloperHealthCheckRunner()

    @Published private(set) var items: [HealthCheckItem] = []
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var appcastProbe: AppcastProbeResult?
    @Published private(set) var isProbingAppcast = false
    @Published private(set) var gatekeeperProbe: GatekeeperProbeResult?
    @Published private(set) var isProbingGatekeeper = false

    private init() {}

    var passCount: Int { items.filter { $0.severity == .pass }.count }
    var warningCount: Int { items.filter { $0.severity == .warning }.count }
    var failCount: Int { items.filter { $0.severity == .fail }.count }

    @discardableResult
    func runAllChecks() -> [HealthCheckItem] {
        let results: [HealthCheckItem] = [
            checkBundleAndSignature(),
            checkSecurityHardeningAndQuarantine(),
            checkSparkleConfiguration(),
            checkConfigIntegrity(),
            checkLoginItemAndAppPolicy(),
            checkShortcutConflicts(),
            checkHotKeyRegistrations(),
            checkAccessibilityAndTaps(),
            checkModuleLifecycleConsistency(),
            checkSimulationAndIsolationState()
        ]
        items = results
        lastRunAt = Date()
        return results
    }

    func probeGatekeeperAssessment() async {
        guard !isProbingGatekeeper else { return }
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            gatekeeperProbe = GatekeeperProbeResult(
                accepted: false,
                sourceLabel: "Unbundled executable",
                rawOutput: "Gatekeeper assessment only applies when running inside a signed .app bundle.",
                checkedAt: Date()
            )
            return
        }

        isProbingGatekeeper = true
        defer { isProbingGatekeeper = false }

        let result = await Task.detached(priority: .utility) { () -> (Int32, String) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
            proc.arguments = ["--assess", "--type", "execute", "--verbose=4", bundlePath]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (proc.terminationStatus, text)
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value

        let accepted = (result.0 == 0)
        let source = Self.parseGatekeeperSource(from: result.1) ?? (accepted ? "accepted" : "rejected (exit \(result.0))")
        gatekeeperProbe = GatekeeperProbeResult(
            accepted: accepted,
            sourceLabel: source,
            rawOutput: result.1.isEmpty ? "exit \(result.0)" : result.1,
            checkedAt: Date()
        )
    }

    nonisolated static func parseGatekeeperSource(from output: String) -> String? {
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = line.range(of: "source=") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    func probeLiveAppcastFeed() async {
        guard !isProbingAppcast else { return }
        isProbingAppcast = true
        defer { isProbingAppcast = false }

        let currentVer = UpdateManager.shared.currentVersion
        guard let feedStr = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feedStr) else {
            appcastProbe = AppcastProbeResult(
                urlString: "(not configured)",
                httpStatus: nil,
                latestVersion: nil,
                isNewerThanCurrent: false,
                itemCount: 0,
                checkedAt: Date(),
                errorMessage: "SUFeedURL is missing in Info.plist (expected when running raw binary outside Toolbox.app)."
            )
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6.0)
        request.setValue("Toolbox-DevTools/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode
            guard let httpStatus, (200..<300).contains(httpStatus) else {
                appcastProbe = AppcastProbeResult(
                    urlString: feedStr,
                    httpStatus: httpStatus,
                    latestVersion: nil,
                    isNewerThanCurrent: false,
                    itemCount: 0,
                    checkedAt: Date(),
                    errorMessage: "HTTP \(httpStatus.map(String.init) ?? "unknown") returned by feed."
                )
                return
            }

            let parsed = Self.parseAppcastVersions(from: data)
            let newest = parsed.max { lhs, rhs in
                !UpdateManager.isNewerVersion(lhs, than: rhs) && lhs != rhs
            }
            let isNewer = newest.map { UpdateManager.isNewerVersion($0, than: currentVer) } ?? false
            appcastProbe = AppcastProbeResult(
                urlString: feedStr,
                httpStatus: httpStatus,
                latestVersion: newest,
                isNewerThanCurrent: isNewer,
                itemCount: parsed.count,
                checkedAt: Date(),
                errorMessage: parsed.isEmpty ? "Feed reachable, but no <item> version entries were parsed." : nil
            )
        } catch {
            appcastProbe = AppcastProbeResult(
                urlString: feedStr,
                httpStatus: nil,
                latestVersion: nil,
                isNewerThanCurrent: false,
                itemCount: 0,
                checkedAt: Date(),
                errorMessage: error.localizedDescription
            )
        }
    }

    static func parseAppcastVersions(from data: Data) -> [String] {
        guard let doc = try? XMLDocument(data: data, options: []),
              let items = try? doc.nodes(forXPath: "//item") else {
            return []
        }

        var versions: [String] = []
        for case let element as XMLElement in items {
            let shortVer = (try? element.nodes(forXPath: "*[local-name()='shortVersionString']"))?.first?.stringValue
                ?? element.elements(forName: "enclosure").first?.attribute(forName: "sparkle:shortVersionString")?.stringValue
            let rawVer = (try? element.nodes(forXPath: "*[local-name()='version']"))?.first?.stringValue
                ?? element.elements(forName: "enclosure").first?.attribute(forName: "sparkle:version")?.stringValue
            let resolved = (shortVer?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (rawVer?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            if let resolved {
                versions.append(resolved)
            }
        }
        return versions
    }

    // MARK: - Individual Checks

    private func checkBundleAndSignature() -> HealthCheckItem {
        let isApp = Bundle.main.bundlePath.hasSuffix(".app")
        let signing = RuntimeDiagnosticsSnapshot.inspectCurrentCodeSignature()

        if isApp && signing.isValid {
            return HealthCheckItem(
                id: "bundle_signature",
                title: "Bundle & Code Signature",
                category: "Packaging",
                severity: .pass,
                summary: signing.summary,
                detail: Bundle.main.bundlePath
            )
        }
        if !signing.isValid {
            return HealthCheckItem(
                id: "bundle_signature",
                title: "Bundle & Code Signature",
                category: "Packaging",
                severity: .fail,
                summary: signing.summary,
                detail: "Re-sign via ./scripts/build-app.sh so TCC permissions and Sparkle stay bound."
            )
        }
        return HealthCheckItem(
            id: "bundle_signature",
            title: "Bundle & Code Signature",
            category: "Packaging",
            severity: .warning,
            summary: "Running raw binary outside .app bundle",
            detail: "\(signing.summary) · Launch ./build/Toolbox.app for full bundle features."
        )
    }

    private func checkSparkleConfiguration() -> HealthCheckItem {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let pubKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let isApp = Bundle.main.bundlePath.hasSuffix(".app")

        if !isApp {
            return HealthCheckItem(
                id: "sparkle_config",
                title: "Sparkle Updater Config",
                category: "Updates",
                severity: .warning,
                summary: "Sparkle disabled outside Toolbox.app",
                detail: "SUFeedURL and Sparkle.framework require the packaged .app bundle."
            )
        }

        let fm = FileManager.default
        let frameworkPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework").path
        let updaterHelperPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Updater.app").path
        let hasFramework = fm.fileExists(atPath: frameworkPath)
        let hasHelper = fm.fileExists(atPath: updaterHelperPath)
        let hasValidFeed = (feedURL?.hasPrefix("https://") == true)
        let hasPubKey = !(pubKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasFramework && hasHelper && hasValidFeed && hasPubKey && UpdateManager.shared.isSparkleAvailable {
            return HealthCheckItem(
                id: "sparkle_config",
                title: "Sparkle Updater Config",
                category: "Updates",
                severity: .pass,
                summary: "Sparkle active with HTTPS appcast & EdDSA key",
                detail: feedURL
            )
        }

        var missing: [String] = []
        if !hasFramework { missing.append("Sparkle.framework") }
        if !hasHelper { missing.append("Updater.app") }
        if !hasValidFeed { missing.append("HTTPS SUFeedURL") }
        if !hasPubKey { missing.append("SUPublicEDKey") }
        if !UpdateManager.shared.isSparkleAvailable { missing.append("SPUUpdater.start()") }

        return HealthCheckItem(
            id: "sparkle_config",
            title: "Sparkle Updater Config",
            category: "Updates",
            severity: .fail,
            summary: "Missing/inactive: \(missing.joined(separator: ", "))",
            detail: feedURL
        )
    }

    private func checkConfigIntegrity() -> HealthCheckItem {
        let cm = ConfigManager.shared
        if let err = cm.lastConfigError {
            return HealthCheckItem(
                id: "config_integrity",
                title: "Config File & Schema",
                category: "Storage",
                severity: .fail,
                summary: err,
                detail: cm.configURL.path
            )
        }

        do {
            let data = try JSONEncoder().encode(cm.config)
            let decoded = try JSONDecoder().decode(ToolboxConfig.self, from: data)
            let roundTripOK = (decoded == cm.config)
            let writable = FileManager.default.isWritableFile(atPath: cm.configURL.deletingLastPathComponent().path)
            if roundTripOK && writable {
                return HealthCheckItem(
                    id: "config_integrity",
                    title: "Config File & Schema",
                    category: "Storage",
                    severity: .pass,
                    summary: "Schema v\(cm.config.schemaVersion) valid & writable",
                    detail: cm.configURL.path
                )
            }
            return HealthCheckItem(
                id: "config_integrity",
                title: "Config File & Schema",
                category: "Storage",
                severity: .warning,
                summary: writable ? "Round-trip equality mismatch" : "Config directory not writable",
                detail: cm.configURL.path
            )
        } catch {
            return HealthCheckItem(
                id: "config_integrity",
                title: "Config File & Schema",
                category: "Storage",
                severity: .fail,
                summary: "Serialization failed: \(error.localizedDescription)",
                detail: cm.configURL.path
            )
        }
    }

    private func checkShortcutConflicts() -> HealthCheckItem {
        let cfg = ConfigManager.shared.config
        let hk = HotKeyManager.shared
        var candidates: [(sourceID: String, label: String, spec: ShortcutSpec)] = []

        if !cfg.dockMinimize.shortcut.isEmpty {
            candidates.append(("dock_minimize", "Dock Click to Minimize", cfg.dockMinimize.shortcut))
        }
        if cfg.clipboard.enabled && !cfg.clipboard.shortcut.isEmpty {
            candidates.append(("clipboard", "Clipboard History", cfg.clipboard.shortcut))
        }
        if cfg.portKiller.enabled && !cfg.portKiller.shortcut.isEmpty {
            candidates.append(("port_killer", "Port Killer", cfg.portKiller.shortcut))
        }
        if cfg.keepAwake.enabled && !cfg.keepAwake.shortcut.isEmpty {
            candidates.append(("keep_awake", "Keep Awake", cfg.keepAwake.shortcut))
        }
        if !cfg.scrollDirection.shortcut.isEmpty {
            candidates.append(("scroll_direction", "Scroll Direction", cfg.scrollDirection.shortcut))
        }
        if cfg.callControls.enabled {
            if !cfg.callControls.micShortcut.isEmpty {
                candidates.append(("call_controls.mic", "Call Controls (Mic)", cfg.callControls.micShortcut))
            }
            if !cfg.callControls.videoShortcut.isEmpty {
                candidates.append(("call_controls.video", "Call Controls (Video)", cfg.callControls.videoShortcut))
            }
            if !cfg.callControls.osMuteShortcut.isEmpty {
                candidates.append(("call_controls.os_mute", "Call Controls (OS Mute)", cfg.callControls.osMuteShortcut))
            }
            if !cfg.callControls.cycleOutputShortcut.isEmpty {
                candidates.append(("call_controls.cycle_output", "Call Controls (Cycle Output)", cfg.callControls.cycleOutputShortcut))
            }
        }
        if cfg.customCommands.enabled {
            for cmd in cfg.customCommands.commands where cmd.enabled && !cmd.shortcut.isEmpty {
                candidates.append(("custom_command.\(cmd.id)", "Command '\(cmd.name)'", cmd.shortcut))
            }
        }
        if cfg.windowSnapper.enabled {
            for entry in cfg.windowSnapper.allShortcutEntries(
                includeHotKeys: cfg.windowSnapper.keyboardSnappingEnabled,
                includeProfilesAndZones: true
            ) {
                candidates.append((entry.sourceID, entry.label, entry.shortcut))
            }
        }

        var issues: [String] = []
        for entry in candidates {
            if let inApp = hk.inAppConflictDescription(for: entry.spec, excludingSourceID: entry.sourceID, in: cfg) {
                issues.append("\(entry.label): \(inApp)")
            } else if let sys = hk.systemOrMenuConflictDescription(for: entry.spec) {
                issues.append("\(entry.label): \(sys)")
            }
        }

        if issues.isEmpty {
            return HealthCheckItem(
                id: "shortcut_conflicts",
                title: "Shortcut Conflict Audit",
                category: "Shortcuts",
                severity: .pass,
                summary: "Checked \(candidates.count) active shortcut(s); no conflicts found",
                detail: nil
            )
        }

        return HealthCheckItem(
            id: "shortcut_conflicts",
            title: "Shortcut Conflict Audit",
            category: "Shortcuts",
            severity: .warning,
            summary: "\(issues.count) shortcut conflict(s) detected",
            detail: issues.joined(separator: " | ")
        )
    }

    private func checkHotKeyRegistrations() -> HealthCheckItem {
        let cfg = ConfigManager.shared.config
        let hk = HotKeyManager.shared

        if !hk.registrationErrors.isEmpty {
            let summary = hk.registrationErrors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
            return HealthCheckItem(
                id: "hotkey_registration",
                title: "Global HotKey Registrations",
                category: "Shortcuts",
                severity: .fail,
                summary: "\(hk.registrationErrors.count) hotkey(s) failed to register",
                detail: summary
            )
        }

        guard cfg.general.appEnabled else {
            return HealthCheckItem(
                id: "hotkey_registration",
                title: "Global HotKey Registrations",
                category: "Shortcuts",
                severity: .pass,
                summary: "App paused; hotkeys cleanly disarmed",
                detail: nil
            )
        }

        var expectedNames: [String] = []
        if !cfg.dockMinimize.shortcut.isEmpty { expectedNames.append(ModuleRegistry.shared.dockMinimize.hotKeyName) }
        if cfg.clipboard.enabled && !cfg.clipboard.shortcut.isEmpty { expectedNames.append(ModuleRegistry.shared.clipboard.hotKeyName) }
        if cfg.portKiller.enabled && !cfg.portKiller.shortcut.isEmpty { expectedNames.append(ModuleRegistry.shared.portKiller.hotKeyName) }
        if cfg.keepAwake.enabled && !cfg.keepAwake.shortcut.isEmpty { expectedNames.append(ModuleRegistry.shared.keepAwake.hotKeyName) }
        if !cfg.scrollDirection.shortcut.isEmpty { expectedNames.append(ModuleRegistry.shared.scrollDirection.hotKeyName) }
        if cfg.callControls.enabled {
            if !cfg.callControls.osMuteShortcut.isEmpty { expectedNames.append(ModuleRegistry.shared.callControls.osMuteHotKeyName) }
            if !cfg.callControls.cycleOutputShortcut.isEmpty { expectedNames.append(ModuleRegistry.shared.callControls.cycleOutputHotKeyName) }
        }
        if cfg.customCommands.enabled {
            for cmd in cfg.customCommands.commands where cmd.enabled && !cmd.shortcut.isEmpty {
                expectedNames.append("custom_command.\(cmd.id)")
            }
        }
        if cfg.windowSnapper.enabled {
            for entry in cfg.windowSnapper.allShortcutEntries(
                includeHotKeys: cfg.windowSnapper.keyboardSnappingEnabled,
                includeProfilesAndZones: true
            ) {
                expectedNames.append(entry.sourceID)
            }
        }

        let missing = expectedNames.filter { !hk.isRegistered(name: $0) }
        if missing.isEmpty {
            return HealthCheckItem(
                id: "hotkey_registration",
                title: "Global HotKey Registrations",
                category: "Shortcuts",
                severity: .pass,
                summary: "All \(expectedNames.count) active Carbon hotkey(s) registered",
                detail: nil
            )
        }

        return HealthCheckItem(
            id: "hotkey_registration",
            title: "Global HotKey Registrations",
            category: "Shortcuts",
            severity: .fail,
            summary: "Missing registration for: \(missing.joined(separator: ", "))",
            detail: "Try reloading the affected module or toggling Toolbox Active."
        )
    }

    private func checkAccessibilityAndTaps() -> HealthCheckItem {
        let perms = PermissionsManager.shared
        let cfg = ConfigManager.shared.config
        let actual = perms.actualAccessibilityGranted
        let dockErr = ModuleRegistry.shared.dockMinimize.lastError

        if let dockErr, !dockErr.isEmpty {
            return HealthCheckItem(
                id: "accessibility_taps",
                title: "Accessibility & Event Taps",
                category: "Permissions",
                severity: .fail,
                summary: "Dock Minimize event tap error",
                detail: dockErr
            )
        }

        let axDependentEnabled = ModuleRegistry.shared.modules.filter {
            $0.requiresAccessibility && $0.isEnabled(in: cfg)
        }

        if actual {
            return HealthCheckItem(
                id: "accessibility_taps",
                title: "Accessibility & Event Taps",
                category: "Permissions",
                severity: .pass,
                summary: "Accessibility granted; \(axDependentEnabled.count) event-tap module(s) enabled",
                detail: nil
            )
        }

        if axDependentEnabled.isEmpty {
            return HealthCheckItem(
                id: "accessibility_taps",
                title: "Accessibility & Event Taps",
                category: "Permissions",
                severity: .pass,
                summary: "Accessibility not granted (no Accessibility-gated modules enabled)",
                detail: nil
            )
        }

        let names = axDependentEnabled.map(\.name).joined(separator: ", ")
        return HealthCheckItem(
            id: "accessibility_taps",
            title: "Accessibility & Event Taps",
            category: "Permissions",
            severity: .warning,
            summary: "Accessibility missing for: \(names)",
            detail: "Grant Accessibility in System Settings or Settings & About to activate taps."
        )
    }

    static func moduleLifecycleMismatch(
        for mod: any ToolboxModule,
        config: ToolboxConfig,
        actualAX: Bool
    ) -> String? {
        if !mod.supportsEnableToggle {
            // On-demand modules (e.g. Keyboard Lock) are intentionally idle (`isRunning == false`)
            // unless actively triggered, and must never stay running while paused or missing Accessibility.
            let canRun = config.general.appEnabled && (!mod.requiresAccessibility || actualAX)
            if mod.isRunning && !canRun {
                return "\(mod.name) (expected running=false, actual=true)"
            }
            return nil
        }
        let requiresLiveAXToRun = (mod.id == "dock_minimize")
        let shouldRun = config.general.appEnabled
            && mod.isEnabled(in: config)
            && (!requiresLiveAXToRun || actualAX)
        if shouldRun != mod.isRunning {
            return "\(mod.name) (expected running=\(shouldRun), actual=\(mod.isRunning))"
        }
        return nil
    }

    private func checkModuleLifecycleConsistency() -> HealthCheckItem {
        let cfg = ConfigManager.shared.config
        let actualAX = PermissionsManager.isProcessTrusted()
        let modules = ModuleRegistry.shared.modules

        let mismatches = modules.compactMap {
            Self.moduleLifecycleMismatch(for: $0, config: cfg, actualAX: actualAX)
        }

        if mismatches.isEmpty {
            let runningCount = modules.filter(\.isRunning).count
            let onDemandIdleCount = modules.filter { !$0.supportsEnableToggle && !$0.isRunning }.count
            let summary = onDemandIdleCount > 0
                ? "All \(modules.count) modules consistent (\(runningCount) running, \(onDemandIdleCount) on-demand)"
                : "All \(modules.count) modules consistent (\(runningCount) running)"
            return HealthCheckItem(
                id: "module_lifecycle",
                title: "Module Lifecycle Consistency",
                category: "Runtime",
                severity: .pass,
                summary: summary,
                detail: nil
            )
        }

        return HealthCheckItem(
            id: "module_lifecycle",
            title: "Module Lifecycle Consistency",
            category: "Runtime",
            severity: .fail,
            summary: "\(mismatches.count) module state mismatch(es)",
            detail: mismatches.joined(separator: "; ")
        )
    }

    private func checkSimulationAndIsolationState() -> HealthCheckItem {
        let devMode = DeveloperModeManager.shared
        let isIsolatedEnv = !(ProcessInfo.processInfo.environment["TOOLBOX_CONFIG_DIR"] ?? "").isEmpty

        var notes: [String] = []
        if UpdateManager.shared.isSimulatingState { notes.append("Update UI simulated") }
        if PermissionsManager.shared.simulatedAccessibilityGranted != nil { notes.append("Accessibility UI simulated") }
        if isIsolatedEnv { notes.append("TOOLBOX_CONFIG_DIR active") }
        if DeveloperModeManager.isLaunchFlagEnabled { notes.append("--dev/TOOLBOX_DEV active") }

        if notes.isEmpty && !devMode.hasActiveSimulation {
            return HealthCheckItem(
                id: "simulation_guard",
                title: "Simulation & Environment Guard",
                category: "Environment",
                severity: .pass,
                summary: "Clean live state (no active overrides)",
                detail: nil
            )
        }

        return HealthCheckItem(
            id: "simulation_guard",
            title: "Simulation & Environment Guard",
            category: "Environment",
            severity: .warning,
            summary: notes.joined(separator: " · "),
            detail: "Reset simulations before verifying real-world behavior."
        )
    }

    private func checkSecurityHardeningAndQuarantine() -> HealthCheckItem {
        let isApp = Bundle.main.bundlePath.hasSuffix(".app")
        let signing = RuntimeDiagnosticsSnapshot.inspectCodeSignature()
        let translocated = Bundle.main.bundlePath.contains("/AppTranslocation/")
        let quarantined = RuntimeDiagnosticsSnapshot.hasQuarantineXattr(atPath: Bundle.main.bundlePath)
        let hasResources = FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/_CodeSignature/CodeResources").path
        )

        if translocated {
            return HealthCheckItem(
                id: "security_hardening",
                title: "Hardened Runtime & Translocation",
                category: "Security",
                severity: .fail,
                summary: "Running under macOS App Translocation",
                detail: "Move Toolbox.app to /Applications before testing Sparkle self-updates or Accessibility TCC."
            )
        }

        if !isApp {
            return HealthCheckItem(
                id: "security_hardening",
                title: "Hardened Runtime & Translocation",
                category: "Security",
                severity: .warning,
                summary: "Unbundled binary (no _CodeSignature / Hardened Runtime)",
                detail: signing.isHardenedRuntime ? "Hardened Runtime enabled" : "Run from ./build/Toolbox.app"
            )
        }

        var warnings: [String] = []
        if !signing.isHardenedRuntime {
            warnings.append("Hardened Runtime off (--fast dev build)")
        }
        if quarantined {
            warnings.append("com.apple.quarantine xattr present")
        }
        if !hasResources {
            warnings.append("Missing _CodeSignature/CodeResources")
        }

        if warnings.isEmpty {
            return HealthCheckItem(
                id: "security_hardening",
                title: "Hardened Runtime & Translocation",
                category: "Security",
                severity: .pass,
                summary: "Hardened Runtime enabled · Clean (not quarantined or translocated)",
                detail: signing.cdHashHex.map { "CDHash: \($0)" }
            )
        }

        return HealthCheckItem(
            id: "security_hardening",
            title: "Hardened Runtime & Translocation",
            category: "Security",
            severity: .warning,
            summary: warnings.joined(separator: " · "),
            detail: signing.isHardenedRuntime
                ? "Notarized builds remove quarantine once accepted."
                : "Use ./scripts/build-app.sh --notarize for Hardened Runtime & notarization."
        )
    }

    private func checkLoginItemAndAppPolicy() -> HealthCheckItem {
        let cfg = ConfigManager.shared.config.general
        let expectedPolicy: NSApplication.ActivationPolicy = cfg.showInDock ? .regular : .accessory
        let policyMatches = (NSApp.activationPolicy() == expectedPolicy)

        let instances = Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).count
        } ?? 1

        let loginStatus = SMAppService.mainApp.status
        let isBundled = Bundle.main.bundlePath.hasSuffix(".app")

        var warnings: [String] = []
        if instances > 1 {
            warnings.append("\(instances) running Toolbox instances detected")
        }
        if !policyMatches {
            warnings.append("Activation policy out of sync with Show in Dock preference")
        }
        if isBundled && cfg.launchAtLogin && loginStatus != .enabled {
            warnings.append("Launch at Login configured on, but SMAppService status is \(loginStatus == .requiresApproval ? "Requires Approval" : "Not Enabled")")
        }

        if warnings.isEmpty {
            let policyStr = cfg.showInDock ? "Regular (Dock)" : "Accessory (Menu Bar)"
            let loginStr = (loginStatus == .enabled) ? "Login Item On" : "Login Item Off"
            return HealthCheckItem(
                id: "login_app_policy",
                title: "Instance, Dock Policy & Login Item",
                category: "Process",
                severity: .pass,
                summary: "Single instance · \(policyStr) · \(loginStr)",
                detail: nil
            )
        }

        return HealthCheckItem(
            id: "login_app_policy",
            title: "Instance, Dock Policy & Login Item",
            category: "Process",
            severity: instances > 1 ? .fail : .warning,
            summary: warnings.joined(separator: " · "),
            detail: "PID \(ProcessInfo.processInfo.processIdentifier) · Check General settings or System Settings → Login Items."
        )
    }
}
