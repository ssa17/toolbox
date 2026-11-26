import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

private final class SwitcherSCWindowBox: @unchecked Sendable {
    let windowNumber: Int
    let scWindow: SCWindow
    let pixelWidth: Int
    let pixelHeight: Int

    init(windowNumber: Int, scWindow: SCWindow, pixelWidth: Int, pixelHeight: Int) {
        self.windowNumber = windowNumber
        self.scWindow = scWindow
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

private final class SwitcherCGImageBox: @unchecked Sendable {
    let cgImage: CGImage

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

/// Captures optional live window thumbnails via `ScreenCaptureKit` only when the user enables
/// thumbnails and Screen Recording permission is already granted (zero unexpected OS prompts).
@MainActor
final class WindowThumbnailProvider {
    private struct CacheEntry {
        let image: NSImage
        let capturedAt: Date
    }

    private static let cacheTTLSeconds: TimeInterval = 15
    private static let maxCachedThumbnails = 48
    private static let maxCaptureWindows = 20

    private var cache: [Int: CacheEntry] = [:]
    private var captureTask: Task<Void, Never>?
    private var activeGeneration: UInt64 = 0

    nonisolated static func scaledThumbnailSize(
        for windowSize: CGSize,
        maxWidth: Int = 320,
        maxHeight: Int = 200
    ) -> (width: Int, height: Int) {
        let w = max(1.0, Double(windowSize.width))
        let h = max(1.0, Double(windowSize.height))
        let scale = min(Double(maxWidth) / w, Double(maxHeight) / h, 1.0)
        let rawW = max(64, Int((w * scale).rounded()))
        let rawH = max(64, Int((h * scale).rounded()))
        let evenW = max(64, rawW - (rawW % 2))
        let evenH = max(64, rawH - (rawH % 2))
        return (min(maxWidth, evenW), min(maxHeight, evenH))
    }

    func cachedThumbnails(for windowNumbers: [Int], now: Date = Date()) -> [Int: NSImage] {
        var result: [Int: NSImage] = [:]
        for num in windowNumbers {
            if let entry = cache[num], now.timeIntervalSince(entry.capturedAt) <= Self.cacheTTLSeconds {
                result[num] = entry.image
            }
        }
        return result
    }

    func invalidateCache() {
        cache.removeAll()
    }

    func cancelActiveCapture() {
        activeGeneration &+= 1
        captureTask?.cancel()
        captureTask = nil
    }

    func captureThumbnails(
        for windowNumbers: [Int],
        showThumbnails: Bool,
        permissionGranted: Bool? = nil,
        onUpdate: @escaping @MainActor (Int, NSImage) -> Void
    ) {
        cancelActiveCapture()
        guard showThumbnails else { return }

        let hasPermission = permissionGranted ?? ScreenCapturePermission.isGranted
        guard hasPermission else { return }

        let now = Date()
        let uniqueNumbers = Array(NSOrderedSet(array: windowNumbers).array.compactMap { $0 as? Int }.prefix(Self.maxCaptureWindows))
        let uncachedOrStale = uniqueNumbers.filter { winNum in
            guard let entry = cache[winNum] else { return true }
            return now.timeIntervalSince(entry.capturedAt) > Self.cacheTTLSeconds
        }
        guard !uncachedOrStale.isEmpty else { return }

        let generation = activeGeneration
        let targetIDs = Set(uncachedOrStale.map { CGWindowID($0) })

        captureTask = Task { [weak self] in
            let captured = await Self.captureBatchThumbnails(targetIDs: targetIDs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.activeGeneration == generation else { return }
                let capturedAt = Date()
                for (winNum, box) in captured {
                    let nsImage = NSImage(
                        cgImage: box.cgImage,
                        size: NSSize(width: box.cgImage.width, height: box.cgImage.height)
                    )
                    self.storeInCache(nsImage, for: winNum, capturedAt: capturedAt)
                    onUpdate(winNum, nsImage)
                }
            }
        }
    }

    private func storeInCache(_ image: NSImage, for windowNumber: Int, capturedAt: Date) {
        cache[windowNumber] = CacheEntry(image: image, capturedAt: capturedAt)
        if cache.count > Self.maxCachedThumbnails {
            let sortedKeys = cache
                .sorted { $0.value.capturedAt < $1.value.capturedAt }
                .prefix(cache.count - Self.maxCachedThumbnails)
                .map(\.key)
            for key in sortedKeys {
                cache.removeValue(forKey: key)
            }
        }
    }

    nonisolated private static func captureBatchThumbnails(
        targetIDs: Set<CGWindowID>
    ) async -> [Int: SwitcherCGImageBox] {
        guard !targetIDs.isEmpty else { return [:] }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            return [:]
        }

        var boxes: [SwitcherSCWindowBox] = []
        boxes.reserveCapacity(targetIDs.count)

        for scWin in content.windows where targetIDs.contains(scWin.windowID) {
            let bounds = scWin.frame
            guard bounds.width >= 50, bounds.height >= 50 else { continue }
            let scaled = scaledThumbnailSize(for: bounds.size)
            boxes.append(
                SwitcherSCWindowBox(
                    windowNumber: Int(scWin.windowID),
                    scWindow: scWin,
                    pixelWidth: scaled.width,
                    pixelHeight: scaled.height
                )
            )
        }

        guard !boxes.isEmpty else { return [:] }

        var captured: [Int: SwitcherCGImageBox] = [:]
        let batchSize = 4
        var cursor = 0

        while cursor < boxes.count {
            if Task.isCancelled { break }
            let end = min(boxes.count, cursor + batchSize)
            let slice = Array(boxes[cursor..<end])
            cursor = end

            await withTaskGroup(of: (Int, SwitcherCGImageBox?).self) { group in
                for box in slice {
                    group.addTask {
                        let filter = SCContentFilter(desktopIndependentWindow: box.scWindow)
                        let streamConfig = SCStreamConfiguration()
                        streamConfig.width = size_t(box.pixelWidth)
                        streamConfig.height = size_t(box.pixelHeight)
                        streamConfig.scalesToFit = true
                        streamConfig.preservesAspectRatio = true
                        streamConfig.showsCursor = false
                        streamConfig.ignoreShadowsSingleWindow = true

                        guard let cgImage = try? await SCScreenshotManager.captureImage(
                            contentFilter: filter,
                            configuration: streamConfig
                        ) else {
                            return (box.windowNumber, nil)
                        }
                        return (box.windowNumber, SwitcherCGImageBox(cgImage))
                    }
                }
                for await (winNum, imageBox) in group {
                    if let imageBox {
                        captured[winNum] = imageBox
                    }
                }
            }
        }

        return captured
    }
}
