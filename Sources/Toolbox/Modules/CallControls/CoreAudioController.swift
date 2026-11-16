import AudioToolbox
import CoreAudio
import CoreMediaIO
import Foundation

struct CameraStatusInfo: Equatable, Sendable {
    let hasCamera: Bool
    let isCameraActive: Bool
    let activeCameraName: String?

    static let empty = CameraStatusInfo(hasCamera: false, isCameraActive: false, activeCameraName: nil)
}

enum AudioTransportType: String, Equatable, Sendable {
    case builtIn
    case bluetooth
    case usb
    case displayPortHDMI
    case airPlay
    case continuity
    case virtual
    case aggregate
    case unknown

    init(coreAudioValue: UInt32) {
        switch coreAudioValue {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeThunderbolt:
            self = .displayPortHDMI
        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            self = .continuity
        case kAudioDeviceTransportTypeVirtual:
            self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            self = .aggregate
        default:
            self = .unknown
        }
    }

    var label: String {
        switch self {
        case .builtIn: return "Built-in"
        case .bluetooth: return "Bluetooth"
        case .usb: return "USB"
        case .displayPortHDMI: return "Display"
        case .airPlay: return "AirPlay"
        case .continuity: return "iPhone"
        case .virtual: return "Virtual"
        case .aggregate: return "Aggregate"
        case .unknown: return "Audio"
        }
    }

    func symbolName(isInput: Bool) -> String {
        switch self {
        case .builtIn:
            return isInput ? "laptopcomputer" : "speaker.wave.2.fill"
        case .bluetooth:
            return "dot.radiowaves.left.and.right"
        case .usb:
            return "cable.connector"
        case .displayPortHDMI:
            return "display"
        case .airPlay:
            return "airplayaudio"
        case .continuity:
            return "iphone"
        case .virtual, .aggregate:
            return "waveform.path"
        case .unknown:
            return isInput ? "mic.fill" : "speaker.wave.2"
        }
    }
}

struct AudioDeviceInfo: Identifiable, Equatable, Sendable {
    var id: String { uid }
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let transport: AudioTransportType
    let inputChannelCount: Int
    let outputChannelCount: Int
    let isDefaultInput: Bool
    let isDefaultOutput: Bool
    let isInputMuted: Bool
    let isOutputMuted: Bool
    let inputVolumeScalar: Float?
    let outputVolumeScalar: Float?
    let supportsHardwareInputMute: Bool

    var hasInput: Bool { inputChannelCount > 0 }
    var hasOutput: Bool { outputChannelCount > 0 }
}

/// CoreAudio HAL property wrapper for device enumeration, default switching,
/// hardware microphone mute (with volume-zero fallback), and live device listeners.
///
/// Strictly operates on CoreAudio HAL properties (`kAudioObjectSystemObject` / `AudioObject*`)
/// without instantiating any `AVAudioEngine` or IOProc, so macOS never triggers the orange
/// microphone-in-use recording indicator.
@MainActor
final class CoreAudioController {
    private struct ListenerToken {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private struct CMIOListenerToken {
        let objectID: CMIOObjectID
        var address: CMIOObjectPropertyAddress
        let block: CMIOObjectPropertyListenerBlock
    }

    var onDevicesChanged: (() -> Void)?
    var onDefaultInputChanged: ((AudioDeviceID) -> Void)?
    var onDefaultOutputChanged: ((AudioDeviceID) -> Void)?
    var onInputMuteOrVolumeChanged: (() -> Void)?
    var onInputStreamActivityChanged: (() -> Void)?
    var onCameraStateChanged: (() -> Void)?

    private nonisolated static let processObjectListSelector: AudioObjectPropertySelector = 0x70727323 // 'prs#'
    private nonisolated static let processIsRunningInputSelector: AudioObjectPropertySelector = 0x70697269 // 'piri'
    private nonisolated static let processBundleIDSelector: AudioObjectPropertySelector = 0x70626964 // 'pbid'

    private var systemListeners: [ListenerToken] = []
    private var inputDeviceListeners: [ListenerToken] = []
    private var processInputListeners: [ListenerToken] = []
    private var cmioSystemListener: CMIOListenerToken?
    private var cmioDeviceListeners: [CMIOListenerToken] = []
    private var observedInputDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)

    /// Tracks previous input volumes per device UID when using volume-zero fallback mute.
    private var savedVolumeBeforeFallbackMute: [String: Float] = [:]

    deinit {
        // Property listener removal requires AudioObjectRemovePropertyListenerBlock;
        // callers should call stopObserving() before release.
    }

    func startObserving() {
        stopObserving()

        addSystemListener(selector: kAudioHardwarePropertyDevices) { [weak self] in
            self?.attachInputDeviceListeners(for: Self.defaultInputDeviceID())
            self?.onDevicesChanged?()
        }

        addSystemListener(selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            let newID = Self.defaultInputDeviceID()
            self?.attachInputDeviceListeners(for: newID)
            self?.onDefaultInputChanged?(newID)
        }

        addSystemListener(selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            let newID = Self.defaultOutputDeviceID()
            self?.onDefaultOutputChanged?(newID)
        }

        if Self.hasSystemProcessObjectList() {
            addSystemListener(selector: Self.processObjectListSelector) { [weak self] in
                self?.refreshProcessInputListeners()
                self?.onInputStreamActivityChanged?()
            }
            refreshProcessInputListeners()
        }

        attachInputDeviceListeners(for: Self.defaultInputDeviceID())
        startObservingCameras()
    }

    func stopObserving() {
        for var token in systemListeners {
            AudioObjectRemovePropertyListenerBlock(
                token.objectID,
                &token.address,
                DispatchQueue.main,
                token.block
            )
        }
        systemListeners.removeAll()
        removeInputDeviceListeners()
        removeProcessInputListeners()
        stopObservingCameras()
    }

    private func removeInputDeviceListeners() {
        for var token in inputDeviceListeners {
            AudioObjectRemovePropertyListenerBlock(
                token.objectID,
                &token.address,
                DispatchQueue.main,
                token.block
            )
        }
        inputDeviceListeners.removeAll()
        observedInputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    }

    private func removeProcessInputListeners() {
        for var token in processInputListeners {
            AudioObjectRemovePropertyListenerBlock(
                token.objectID,
                &token.address,
                DispatchQueue.main,
                token.block
            )
        }
        processInputListeners.removeAll()
    }

    private func refreshProcessInputListeners() {
        removeProcessInputListeners()
        for processID in Self.processObjectIDs() {
            var addr = AudioObjectPropertyAddress(
                mSelector: Self.processIsRunningInputSelector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(processID, &addr) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.onInputStreamActivityChanged?()
                }
            }
            if AudioObjectAddPropertyListenerBlock(processID, &addr, DispatchQueue.main, block) == noErr {
                processInputListeners.append(ListenerToken(
                    objectID: processID,
                    address: addr,
                    block: block
                ))
            }
        }
    }

    private func addSystemListener(selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            systemListeners.append(ListenerToken(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: address,
                block: block
            ))
        }
    }

    private func attachInputDeviceListeners(for deviceID: AudioDeviceID) {
        guard deviceID != observedInputDeviceID else { return }
        removeInputDeviceListeners()
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
        observedInputDeviceID = deviceID

        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyMute,
            kAudioDevicePropertyVolumeScalar
        ]
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1]

        for selector in selectors {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeInput,
                    mElement: element
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.onInputMuteOrVolumeChanged?()
                    }
                }
                let status = AudioObjectAddPropertyListenerBlock(
                    deviceID,
                    &address,
                    DispatchQueue.main,
                    block
                )
                if status == noErr {
                    inputDeviceListeners.append(ListenerToken(
                        objectID: deviceID,
                        address: address,
                        block: block
                    ))
                }
            }
        }

        // Only observe device-level running state on pure input devices when per-process input
        // tracking is unavailable; on duplex devices (e.g., headsets/USB docks), output alert
        // beeps flip kAudioDevicePropertyDeviceIsRunningSomewhere to 1.
        if !Self.hasSystemProcessObjectList(),
           Self.channelCount(for: deviceID, scope: kAudioObjectPropertyScopeOutput) == 0 {
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(deviceID, &runningAddr) {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.onInputStreamActivityChanged?()
                    }
                }
                if AudioObjectAddPropertyListenerBlock(deviceID, &runningAddr, DispatchQueue.main, block) == noErr {
                    inputDeviceListeners.append(ListenerToken(
                        objectID: deviceID,
                        address: runningAddr,
                        block: block
                    ))
                }
            }
        }
    }

    // MARK: - Device Enumeration

    nonisolated static func defaultInputDeviceID() -> AudioDeviceID {
        readDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    nonisolated static func defaultOutputDeviceID() -> AudioDeviceID {
        readDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    nonisolated static func isDefaultInputRunningSomewhere() -> Bool {
        if hasSystemProcessObjectList() {
            for processID in processObjectIDs() {
                if let runningInput = readUInt32Property(
                    deviceID: processID,
                    selector: processIsRunningInputSelector,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain
                ), runningInput != 0 {
                    return true
                }
            }
            return false
        }

        let deviceID = defaultInputDeviceID()
        guard deviceID != AudioDeviceID(kAudioObjectUnknown),
              channelCount(for: deviceID, scope: kAudioObjectPropertyScopeOutput) == 0 else {
            return false
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    nonisolated static func activeInputProcessBundleIDs() -> Set<String> {
        guard hasSystemProcessObjectList() else { return [] }
        var bundleIDs: Set<String> = []
        for processID in processObjectIDs() {
            guard let runningInput = readUInt32Property(
                deviceID: processID,
                selector: processIsRunningInputSelector,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            ), runningInput != 0 else {
                continue
            }
            if let bid = readStringProperty(deviceID: processID, selector: processBundleIDSelector)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !bid.isEmpty {
                bundleIDs.insert(bid)
            }
        }
        return bundleIDs
    }

    nonisolated static func bundleID(
        _ bundleID: String,
        matchesActiveInputProcessBundleIDs activeBundleIDs: Set<String>
    ) -> Bool {
        guard !bundleID.isEmpty, !activeBundleIDs.isEmpty else { return false }
        let target = bundleID.lowercased()
        let helperPrefix = target + "."
        return activeBundleIDs.contains { procBundle in
            let proc = procBundle.lowercased()
            return proc == target || proc.hasPrefix(helperPrefix)
        }
    }

    private nonisolated static func hasSystemProcessObjectList() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: processObjectListSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address)
    }

    private nonisolated static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: processObjectListSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { rawBuf in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                rawBuf.baseAddress!
            )
        }
        guard status == noErr else { return [] }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    nonisolated static func listDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBytes { rawBuf in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                rawBuf.baseAddress!
            )
        }
        guard status == noErr else { return [] }

        let defaultInput = defaultInputDeviceID()
        let defaultOutput = defaultOutputDeviceID()

        var results: [AudioDeviceInfo] = []
        results.reserveCapacity(deviceIDs.count)

        for deviceID in deviceIDs {
            guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { continue }
            let inputChannels = channelCount(for: deviceID, scope: kAudioObjectPropertyScopeInput)
            let outputChannels = channelCount(for: deviceID, scope: kAudioObjectPropertyScopeOutput)
            guard inputChannels > 0 || outputChannels > 0 else { continue }

            let name = readStringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName) ?? "Audio Device \(deviceID)"
            let uid = readStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "device-\(deviceID)"
            let transportRaw = readUInt32Property(
                deviceID: deviceID,
                selector: kAudioDevicePropertyTransportType,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            ) ?? 0

            let supportsHwInMute = !settableElements(
                deviceID: deviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeInput
            ).isEmpty

            let inputVolume = inputChannels > 0
                ? readVolumeScalar(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
                : nil
            let outputVolume = outputChannels > 0
                ? readVolumeScalar(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
                : nil

            let hwInMuted = inputChannels > 0
                ? (readMuteFlag(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput) ?? false)
                : false
            let effectiveInMuted = hwInMuted || (!supportsHwInMute && (inputVolume ?? 1.0) <= 0.001)
            let hwOutMuted = outputChannels > 0
                ? (readMuteFlag(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput) ?? false)
                : false

            results.append(AudioDeviceInfo(
                deviceID: deviceID,
                uid: uid,
                name: name,
                transport: AudioTransportType(coreAudioValue: transportRaw),
                inputChannelCount: inputChannels,
                outputChannelCount: outputChannels,
                isDefaultInput: deviceID == defaultInput,
                isDefaultOutput: deviceID == defaultOutput,
                isInputMuted: effectiveInMuted,
                isOutputMuted: hwOutMuted,
                inputVolumeScalar: inputVolume,
                outputVolumeScalar: outputVolume,
                supportsHardwareInputMute: supportsHwInMute
            ))
        }

        return results.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Default Device Switching

    @discardableResult
    func setDefaultInputDevice(uid: String) -> Bool {
        guard let device = Self.listDevices().first(where: { $0.uid == uid && $0.hasInput }) else {
            return false
        }
        return setDefaultDevice(device.deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    @discardableResult
    func setDefaultOutputDevice(uid: String) -> Bool {
        guard let device = Self.listDevices().first(where: { $0.uid == uid && $0.hasOutput }) else {
            return false
        }
        return setDefaultDevice(device.deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func setDefaultDevice(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var targetID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &targetID
        )
        return status == noErr
    }

    // MARK: - Mic Mute / Unmute with Volume Fallback

    func currentInputMuteState() -> Bool {
        let deviceID = Self.defaultInputDeviceID()
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { return false }

        if let hwMuted = Self.readMuteFlag(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput) {
            return hwMuted
        }
        if let uid = Self.readStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID),
           savedVolumeBeforeFallbackMute[uid] != nil {
            if let vol = Self.readVolumeScalar(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput), vol <= 0.001 {
                return true
            }
        }
        if let vol = Self.readVolumeScalar(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput) {
            return vol <= 0.001
        }
        return false
    }

    @discardableResult
    func setDefaultInputMuted(_ muted: Bool) -> Bool {
        let deviceID = Self.defaultInputDeviceID()
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { return false }

        let muteElements = Self.settableElements(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeInput
        )

        if !muteElements.isEmpty {
            var anySucceeded = false
            for element in muteElements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: kAudioObjectPropertyScopeInput,
                    mElement: element
                )
                var value: UInt32 = muted ? 1 : 0
                let size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr {
                    anySucceeded = true
                }
            }
            if anySucceeded {
                return true
            }
        }

        // Fallback for USB mics / virtual audio drivers without hardware kAudioDevicePropertyMute
        let volumeElements = Self.settableElements(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeInput
        )
        guard !volumeElements.isEmpty else { return false }

        let uid = Self.readStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "device-\(deviceID)"
        if muted {
            if let currentVol = Self.readVolumeScalar(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput),
               currentVol > 0.001 {
                savedVolumeBeforeFallbackMute[uid] = currentVol
            }
            return Self.writeVolumeScalar(0.0, deviceID: deviceID, scope: kAudioObjectPropertyScopeInput, elements: volumeElements)
        } else {
            let restoreVol = savedVolumeBeforeFallbackMute.removeValue(forKey: uid) ?? 0.85
            return Self.writeVolumeScalar(restoreVol, deviceID: deviceID, scope: kAudioObjectPropertyScopeInput, elements: volumeElements)
        }
    }

    func clearSavedFallbackVolumes() {
        savedVolumeBeforeFallbackMute.removeAll()
    }

    // MARK: - Low-Level CoreAudio Property Helpers

    private nonisolated static func readDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
    }

    private nonisolated static func readStringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let retained = value?.takeRetainedValue() else {
            return nil
        }
        return retained as String
    }

    private nonisolated static func readUInt32Property(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private nonisolated static func readFloat32Property(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private nonisolated static func readMuteFlag(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Bool? {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            if let val = readUInt32Property(
                deviceID: deviceID,
                selector: kAudioDevicePropertyMute,
                scope: scope,
                element: element
            ) {
                return val != 0
            }
        }
        return nil
    }

    private nonisolated static func readVolumeScalar(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Float? {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            if let val = readFloat32Property(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope,
                element: element
            ) {
                return min(max(val, 0.0), 1.0)
            }
        }
        return nil
    }

    private nonisolated static func writeVolumeScalar(
        _ scalar: Float,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        elements: [AudioObjectPropertyElement]
    ) -> Bool {
        var anySucceeded = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: element
            )
            var value = Float32(min(max(scalar, 0.0), 1.0))
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr {
                anySucceeded = true
            }
        }
        return anySucceeded
    }

    private nonisolated static func settableElements(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyElement] {
        var masterAddr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &masterAddr) {
            var isSettable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &masterAddr, &isSettable) == noErr,
               isSettable.boolValue {
                return [kAudioObjectPropertyElementMain]
            }
        }

        var channelElements: [AudioObjectPropertyElement] = []
        for ch: UInt32 in [1, 2] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: ch)
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var isSettable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &addr, &isSettable) == noErr,
               isSettable.boolValue {
                channelElements.append(ch)
            }
        }
        return channelElements
    }

    private nonisolated static func channelCount(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return 0 }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - CoreMediaIO Camera Status Observation

    private func startObservingCameras() {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.attachCameraDeviceListeners()
                self?.onCameraStateChanged?()
            }
        }
        let status = CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            cmioSystemListener = CMIOListenerToken(
                objectID: CMIOObjectID(kCMIOObjectSystemObject),
                address: addr,
                block: block
            )
        }
        attachCameraDeviceListeners()
    }

    private func stopObservingCameras() {
        if var token = cmioSystemListener {
            CMIOObjectRemovePropertyListenerBlock(
                token.objectID,
                &token.address,
                DispatchQueue.main,
                token.block
            )
            cmioSystemListener = nil
        }
        removeCameraDeviceListeners()
    }

    private func removeCameraDeviceListeners() {
        for var token in cmioDeviceListeners {
            CMIOObjectRemovePropertyListenerBlock(
                token.objectID,
                &token.address,
                DispatchQueue.main,
                token.block
            )
        }
        cmioDeviceListeners.removeAll()
    }

    private func attachCameraDeviceListeners() {
        removeCameraDeviceListeners()
        for deviceID in Self.listCMIODeviceIDs() {
            var addr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            guard CMIOObjectHasProperty(deviceID, &addr) else { continue }
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.onCameraStateChanged?()
                }
            }
            if CMIOObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block) == noErr {
                cmioDeviceListeners.append(CMIOListenerToken(
                    objectID: deviceID,
                    address: addr,
                    block: block
                ))
            }
        }
    }

    nonisolated static func currentCameraStatus() -> CameraStatusInfo {
        let deviceIDs = listCMIODeviceIDs()
        guard !deviceIDs.isEmpty else { return .empty }

        var activeNames: [String] = []
        for dev in deviceIDs {
            var runAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            guard CMIOObjectHasProperty(dev, &runAddr) else { continue }
            var running: UInt32 = 0
            var used: UInt32 = 0
            let runSize = UInt32(MemoryLayout<UInt32>.size)
            let status = CMIOObjectGetPropertyData(dev, &runAddr, 0, nil, runSize, &used, &running)
            if status == noErr && running != 0 {
                if let name = readCameraName(deviceID: dev) {
                    activeNames.append(name)
                } else {
                    activeNames.append("Camera")
                }
            }
        }

        return CameraStatusInfo(
            hasCamera: !deviceIDs.isEmpty,
            isCameraActive: !activeNames.isEmpty,
            activeCameraName: activeNames.first
        )
    }

    private nonisolated static func listCMIODeviceIDs() -> [CMIODeviceID] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<CMIODeviceID>.size
        guard count > 0 else { return [] }
        var ids = [CMIODeviceID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else {
            return []
        }
        return ids
    }

    private nonisolated static func readCameraName(deviceID: CMIODeviceID) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(deviceID, &addr) else { return nil }
        var nameRef: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(deviceID, &addr, 0, nil, size, &used, &nameRef) == noErr,
              let cfStr = nameRef?.takeRetainedValue() else {
            return nil
        }
        let trimmed = (cfStr as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
