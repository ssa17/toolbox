import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// Single HID `UserKeyMapping` entry (`HIDKeyboardModifierMappingSrc` -> `HIDKeyboardModifierMappingDst`).
struct HIDKeyMappingEntry: Equatable, Hashable, Sendable {
    let src: UInt64
    let dst: UInt64
}

/// Detected pre-existing or macOS Modifier Keys remapping targeting Caps Lock.
struct ExternalCapsLockConflict: Equatable, Sendable {
    let destinationUsage: UInt64
    let description: String
}

/// In-process IOKit HID remapper that maps Caps Lock (`0x700000039`) to `F18` (`0x70000006D`)
/// while preserving any user-defined mappings and restoring them unconditionally on teardown.
final class CapsLockRemapper: @unchecked Sendable {
    static let hidCapsLockUsage: UInt64 = 0x700000039
    static let hidF18Usage: UInt64 = 0x70000006D
    static let userKeyMappingKey = kIOHIDUserKeyUsageMapKey
    static let mappingSrcKey = kIOHIDKeyboardModifierMappingSrcKey
    static let mappingDstKey = kIOHIDKeyboardModifierMappingDstKey

    private let lock = NSLock()
    private var preToolboxMappingsByServiceID: [String: [HIDKeyMappingEntry]] = [:]
    private var hidManager: IOHIDManager?
    private var isActive = false
    var onKeyboardAttached: (() -> Void)?

    deinit {
        stopKeyboardAttachWatcher()
    }

    // MARK: - Pure Mapping Helpers

    static func isCapsLockUsage(_ usage: UInt64) -> Bool {
        usage == hidCapsLockUsage || (usage & 0xFFFF_FFFF) == 0x39
    }

    static func isToolboxHyperEntry(_ entry: HIDKeyMappingEntry) -> Bool {
        entry.src == hidCapsLockUsage && entry.dst == hidF18Usage
    }

    static func detectExternalCapsLockMapping(in entries: [HIDKeyMappingEntry]) -> ExternalCapsLockConflict? {
        for entry in entries where isCapsLockUsage(entry.src) && !isToolboxHyperEntry(entry) {
            let dstName = humanReadableHIDUsageName(entry.dst)
            return ExternalCapsLockConflict(
                destinationUsage: entry.dst,
                description: "Caps Lock is currently remapped to \(dstName). Set System Settings → Keyboard → Modifier Keys → Caps Lock to “Caps Lock” so Hyper Key can receive raw presses."
            )
        }
        return nil
    }

    static func mergingHyperKeyMapping(into existing: [HIDKeyMappingEntry]) -> [HIDKeyMappingEntry] {
        var filtered = existing.filter { !isToolboxHyperEntry($0) && !isCapsLockUsage($0.src) }
        filtered.append(HIDKeyMappingEntry(src: hidCapsLockUsage, dst: hidF18Usage))
        return filtered
    }

    static func removingHyperKeyMapping(from current: [HIDKeyMappingEntry]) -> [HIDKeyMappingEntry] {
        current.filter { !isToolboxHyperEntry($0) }
    }

    static func humanReadableHIDUsageName(_ usage: UInt64) -> String {
        let normalized: UInt64 = (usage & 0xFFFF_0000_0000) == 0 && usage > 0
            ? (0x700000000 | usage)
            : usage
        switch normalized {
        case 0x0, 0x700000000, 0xFFFFFFFF:
            return "No Action"
        case 0x700000029:
            return "Escape"
        case 0x700000039:
            return "Caps Lock"
        case 0x7000000E0, 0x7000000E4:
            return "Control"
        case 0x7000000E1, 0x7000000E5:
            return "Shift"
        case 0x7000000E2, 0x7000000E6:
            return "Option"
        case 0x7000000E3, 0x7000000E7:
            return "Command"
        case 0x70000006D:
            return "F18"
        case 0xFF00000003, 0x100000003:
            return "Globe / Fn"
        default:
            return String(format: "0x%llX", usage)
        }
    }

    // MARK: - Live IOKit Operations

    @discardableResult
    func applyRemap() -> (applied: Bool, externalWarning: String?) {
        let nativeOverride = detectNativeModifierKeysOverride()
        guard !PermissionsManager.isRunningInDiagnosticMode else {
            return (false, nativeOverride)
        }

        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = keyboardServices(for: client)
        var anyApplied = false
        var externalWarning = nativeOverride

        for service in services {
            let serviceID = registryIdentifier(for: service)
            let currentEntries = readMappings(from: service)
            let cleanPreExisting = Self.removingHyperKeyMapping(from: currentEntries)

            lock.lock()
            if preToolboxMappingsByServiceID[serviceID] == nil {
                preToolboxMappingsByServiceID[serviceID] = cleanPreExisting
            }
            lock.unlock()

            if externalWarning == nil,
               let conflict = Self.detectExternalCapsLockMapping(in: cleanPreExisting) {
                externalWarning = conflict.description
            }

            let targetEntries = Self.mergingHyperKeyMapping(into: cleanPreExisting)
            if currentEntries != targetEntries {
                if writeMappings(targetEntries, to: service) {
                    anyApplied = true
                }
            } else {
                anyApplied = true
            }
        }

        lock.lock()
        isActive = anyApplied
        lock.unlock()

        startKeyboardAttachWatcherIfNeeded()
        return (anyApplied, externalWarning)
    }

    func restorePreToolboxMappings() {
        stopKeyboardAttachWatcher()

        lock.lock()
        let snapshots = preToolboxMappingsByServiceID
        preToolboxMappingsByServiceID.removeAll()
        isActive = false
        lock.unlock()

        guard !PermissionsManager.isRunningInDiagnosticMode else { return }

        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = keyboardServices(for: client)
        for service in services {
            let serviceID = registryIdentifier(for: service)
            if let prior = snapshots[serviceID] {
                _ = writeMappings(prior, to: service)
            } else {
                let current = readMappings(from: service)
                let cleaned = Self.removingHyperKeyMapping(from: current)
                if cleaned != current {
                    _ = writeMappings(cleaned, to: service)
                }
            }
        }
    }

    func cleanupStaleMappingIfNeeded() {
        guard !PermissionsManager.isRunningInDiagnosticMode else { return }

        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        for service in keyboardServices(for: client) {
            let current = readMappings(from: service)
            let cleaned = Self.removingHyperKeyMapping(from: current)
            if cleaned != current {
                _ = writeMappings(cleaned, to: service)
            }
        }
    }

    @discardableResult
    func toggleSystemCapsLockState() -> Bool? {
        guard !PermissionsManager.isRunningInDiagnosticMode else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return nil
        }
        defer { IOServiceClose(connect) }

        var current = false
        guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &current) == KERN_SUCCESS else {
            return nil
        }
        let next = !current
        guard IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), next) == KERN_SUCCESS else {
            return nil
        }
        return next
    }

    func detectNativeModifierKeysOverride() -> String? {
        let prefix = "com.apple.keyboard.modifiermapping."
        guard let keys = CFPreferencesCopyKeyList(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String] else {
            return nil
        }

        for key in keys where key.hasPrefix(prefix) {
            guard let rawArray = CFPreferencesCopyValue(
                key as CFString,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            ) as? [[String: Any]] else {
                continue
            }
            let entries = rawArray.compactMap { parseEntry($0) }
            if let conflict = Self.detectExternalCapsLockMapping(in: entries) {
                return conflict.description
            }
        }
        return nil
    }

    // MARK: - Private IOKit Helpers

    private func keyboardServices(for client: IOHIDEventSystemClient) -> [IOHIDServiceClient] {
        guard let rawServices = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else {
            return []
        }
        var keyboards: [IOHIDServiceClient] = []
        let expectedTypeID = IOHIDServiceClientGetTypeID()
        for item in rawServices {
            guard CFGetTypeID(item) == expectedTypeID else { continue }
            let service = unsafeDowncast(item, to: IOHIDServiceClient.self)
            if IOHIDServiceClientConformsTo(
                service,
                UInt32(kHIDPage_GenericDesktop),
                UInt32(kHIDUsage_GD_Keyboard)
            ) != 0 {
                keyboards.append(service)
            }
        }
        return keyboards
    }

    private func registryIdentifier(for service: IOHIDServiceClient) -> String {
        if let regID = IOHIDServiceClientGetRegistryID(service) as? NSNumber {
            return regID.stringValue
        }
        return String(describing: Unmanaged.passUnretained(service).toOpaque())
    }

    private func readMappings(from service: IOHIDServiceClient) -> [HIDKeyMappingEntry] {
        guard let raw = IOHIDServiceClientCopyProperty(service, Self.userKeyMappingKey as CFString) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { parseEntry($0) }
    }

    private func parseEntry(_ dict: [String: Any]) -> HIDKeyMappingEntry? {
        guard let srcNum = dict[Self.mappingSrcKey] as? NSNumber,
              let dstNum = dict[Self.mappingDstKey] as? NSNumber else {
            return nil
        }
        return HIDKeyMappingEntry(src: srcNum.uint64Value, dst: dstNum.uint64Value)
    }

    private func writeMappings(_ entries: [HIDKeyMappingEntry], to service: IOHIDServiceClient) -> Bool {
        let payload: [[String: NSNumber]] = entries.map { entry in
            [
                Self.mappingSrcKey: NSNumber(value: entry.src),
                Self.mappingDstKey: NSNumber(value: entry.dst)
            ]
        }
        return IOHIDServiceClientSetProperty(
            service,
            Self.userKeyMappingKey as CFString,
            payload as CFArray
        )
    }

    private func startKeyboardAttachWatcherIfNeeded() {
        lock.lock()
        let alreadyStarted = hidManager != nil
        lock.unlock()
        guard !alreadyStarted else { return }

        let setup: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.isActive && self.hidManager == nil
            self.lock.unlock()
            guard active else { return }

            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching: [String: Any] = [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
            ]
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(
                manager,
                { context, _, _, _ in
                    guard let context else { return }
                    let remapper = Unmanaged<CapsLockRemapper>.fromOpaque(context).takeUnretainedValue()
                    remapper.handleKeyboardAttached()
                },
                context
            )
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

            self.lock.lock()
            self.hidManager = manager
            self.lock.unlock()
        }

        if Thread.isMainThread {
            setup()
        } else {
            DispatchQueue.main.async(execute: setup)
        }
    }

    private func stopKeyboardAttachWatcher() {
        lock.lock()
        let manager = hidManager
        hidManager = nil
        lock.unlock()
        guard let manager else { return }

        nonisolated(unsafe) let capturedManager = manager
        let teardown: @Sendable () -> Void = {
            IOHIDManagerRegisterDeviceMatchingCallback(capturedManager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(capturedManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(capturedManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.async(execute: teardown)
        }
    }

    private func handleKeyboardAttached() {
        lock.lock()
        let active = isActive
        lock.unlock()
        guard active else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillActive = self.isActive
            self.lock.unlock()
            guard stillActive else { return }
            _ = self.applyRemap()
            self.onKeyboardAttached?()
        }
    }
}
