import AppKit
import CoreGraphics
import Foundation
import SwiftUI

private final class TapStartState: @unchecked Sendable {
    var succeeded = false
}

/// A session-level event tap that inverts scroll wheel events for one device class
/// (mouse or trackpad) so the two point in opposite directions.
///
/// macOS applies a single system-wide scroll direction to every pointing device, so
/// System Settings cannot express "trackpad one way, mouse the other". Instead of
/// touching the system setting, this inverts deltas at the event layer, which works
/// on any macOS version and with any mouse.
///
/// Device class is determined per event: `kCGScrollWheelEventIsContinuous` is
/// non-zero for pixel-based (high resolution) scrolling, i.e. the trackpad and
/// high-resolution mice such as the Magic Mouse, and zero for line-based
/// (notch-per-step) scrolling, i.e. classic mouse wheels.
final class ScrollInversionTap: @unchecked Sendable {
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()

    private var target: ScrollTarget = .mouse
    private var invertedTotal: Int = 0
    private var observedTotal: Int = 0
    private var lastObservedIsTrackpad: Bool?
    private var lastInvertedIsTrackpad: Bool?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?

    /// The scroll delta representations and how they interlock (verified against the
    /// CoreGraphics event model):
    /// - The line based fields (DeltaAxis1/2) are the MASTER: setting one re-derives the
    ///   fixed point and pixel mirrors from the line count, overwriting their values.
    /// - The fixed point (16.16) and pixel based fields have no cross side effects.
    /// - The raw/accelerated fields cannot be written through this API at all.
    ///
    /// Real events: line based (classic mouse wheels) carry their true value in the line
    /// fields; pixel based (trackpad, high resolution mice) carry their true value in the
    /// pixel fields, with only a coarse derivative in the line fields.
    private static let lineBasedFields: [CGEventField] = [
        .scrollWheelEventFixedPtDeltaAxis1,
        .scrollWheelEventFixedPtDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1,
        .scrollWheelEventPointDeltaAxis2,
        .scrollWheelEventDeltaAxis1,   // master: must be set last
        .scrollWheelEventDeltaAxis2,   // master: must be set last
    ]
    private static let pixelBasedFields: [CGEventField] = [
        .scrollWheelEventFixedPtDeltaAxis1,
        .scrollWheelEventFixedPtDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1,
        .scrollWheelEventPointDeltaAxis2,
        // Deliberately no line based fields here: on a pixel based event the line
        // fields are only coarse derivatives, and setting one would re-derive the
        // pixel mirrors from the line count, destroying the high resolution value.
    ]

    deinit {
        uninstall()
    }

    @discardableResult
    func install() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        uninstallLocked()

        let readySem = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        let startState = TapStartState()

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            guard let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<ScrollInversionTap>.fromOpaque(userInfo).takeUnretainedValue()
                    return owner.handle(type: type, event: event)
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
        thread.name = "app.toolbox.scroll-inversion-tap"
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
        let (currentTap, currentSource, currentRL, currentThread, exitSem) = withLock {
            let values = (tap, runLoopSource, backgroundRunLoop, tapThread, tapExitSemaphore)
            tap = nil
            runLoopSource = nil
            backgroundRunLoop = nil
            tapThread = nil
            tapExitSemaphore = nil
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
    }

    func setTarget(_ newTarget: ScrollTarget) {
        withLock { self.target = newTarget }
    }

    func resetStats() {
        withLock {
            invertedTotal = 0
            observedTotal = 0
            lastObservedIsTrackpad = nil
            lastInvertedIsTrackpad = nil
        }
    }

    var isInstalled: Bool {
        withLock { self.tap != nil }
    }

    internal var runsOnDedicatedBackgroundRunLoopForTesting: Bool {
        withLock {
            guard let rl = backgroundRunLoop, let thread = tapThread else { return false }
            return !thread.isMainThread && rl !== CFRunLoopGetMain()
        }
    }

    var eventsInverted: Int {
        withLock { invertedTotal }
    }

    var eventsObserved: Int {
        withLock { observedTotal }
    }

    /// The device class of the most recently observed scroll event (inverted or not).
    var lastObservedClass: ScrollTarget? {
        withLock { lastObservedIsTrackpad.map { $0 ? .trackpad : .mouse } }
    }

    /// The device class of the most recently inverted event (nil if none yet).
    var lastInvertedClass: ScrollTarget? {
        withLock { lastInvertedIsTrackpad.map { $0 ? .trackpad : .mouse } }
    }

    /// Runs on the dedicated background tap thread's CFRunLoop for every scroll wheel event.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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
        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }
        _ = processScrollWheelEvent(event)
        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    internal func processScrollWheelEvent(_ event: CGEvent) -> Bool {
        let isTrackpad = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let targetNow = withLock {
            observedTotal += 1
            lastObservedIsTrackpad = isTrackpad
            return target
        }

        guard Self.applyInversion(to: event, target: targetNow) else {
            return false
        }

        withLock {
            invertedTotal += 1
            lastInvertedIsTrackpad = isTrackpad
        }
        return true
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Inverts the scroll deltas on the event when it belongs to the target device
    /// class. Returns true when the event was inverted.
    static func applyInversion(to event: CGEvent, target: ScrollTarget) -> Bool {
        let isTrackpad = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        guard isTrackpad == (target == .trackpad) else {
            return false
        }
        let fields = isTrackpad ? pixelBasedFields : lineBasedFields
        for field in fields {
            let value = event.getIntegerValueField(field)
            if value != 0 {
                event.setIntegerValueField(field, value: -value)
            }
        }
        return true
    }
}
