import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// On-disk store for copied clipboard images.
///
/// Files are written synchronously (callers should invoke from `Task.detached`)
/// into a dedicated directory. Full images are normalized to PNG and stored as
/// `<uuid>.png`; thumbnails are `<uuid>-thumb.png` (max dimension 240 px).
/// All writes are atomic and clean up partial files on failure.
final class ClipboardImageStore: @unchecked Sendable {
    private let directoryURL: URL
    private let thumbnailCache = NSCache<NSString, NSImage>()

    private static let thumbnailMaxDimension: CGFloat = 240

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    // MARK: - Saving

    func saveImage(data: Data) throws -> ClipboardImageMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw StoreError.undecodableImage
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StoreError.undecodableImage
        }
        return try saveImage(cgImage)
    }

    func saveImage(_ image: CGImage) throws -> ClipboardImageMetadata {
        // Ensure directory exists with owner-only permissions.
        try ensureDirectory()

        let width = image.width
        let height = image.height
        guard width > 0 && height > 0 else {
            throw StoreError.undecodableImage
        }

        let uuid = UUID().uuidString
        let fullFilename = "\(uuid).png"
        let thumbFilename = "\(uuid)-thumb.png"
        let fullURL = directoryURL.appendingPathComponent(fullFilename)
        let thumbURL = directoryURL.appendingPathComponent(thumbFilename)

        // Normalize full image to PNG.
        guard let fullPNGData = pngData(from: image) else {
            throw StoreError.encodeFailed
        }

        // Thumbnail: 240 px max dimension.
        let thumbData: Data?
        do {
            thumbData = try thumbnailData(fromPNGData: fullPNGData, maxDimension: Self.thumbnailMaxDimension)
        } catch {
            // Thumbnail failure is non-fatal; fall back to resizing via bitmap.
            thumbData = pngData(from: resizedCopy(image, maxDimension: Self.thumbnailMaxDimension) ?? image)
        }
        guard let thumbData, !thumbData.isEmpty else {
            try? FileManager.default.removeItem(at: fullURL)
            throw StoreError.thumbnailFailed
        }

        let sha = SHA256.hash(data: fullPNGData)
        let shaHex = sha.map { String(format: "%02x", $0) }.joined()

        do {
            try writeAtomic(fullPNGData, to: fullURL)
            try writeAtomic(thumbData, to: thumbURL)
        } catch {
            try? FileManager.default.removeItem(at: fullURL)
            try? FileManager.default.removeItem(at: thumbURL)
            throw error
        }

        return ClipboardImageMetadata(
            filename: fullFilename,
            thumbnailFilename: thumbFilename,
            sha256: shaHex,
            pixelWidth: width,
            pixelHeight: height,
            byteSize: fullPNGData.count
        )
    }

    // MARK: - Deletion

    func deleteImage(_ metadata: ClipboardImageMetadata) {
        let fullURL = fullImageURL(for: metadata)
        let thumbURL = thumbnailURL(for: metadata)
        try? FileManager.default.removeItem(at: fullURL)
        try? FileManager.default.removeItem(at: thumbURL)
        thumbnailCache.removeObject(forKey: metadata.thumbnailFilename as NSString)
    }

    // MARK: - URLs

    func fullImageURL(for metadata: ClipboardImageMetadata) -> URL {
        directoryURL.appendingPathComponent(metadata.filename)
    }

    func thumbnailURL(for metadata: ClipboardImageMetadata) -> URL {
        directoryURL.appendingPathComponent(metadata.thumbnailFilename)
    }

    // MARK: - Loading

    func fullImage(for metadata: ClipboardImageMetadata) -> NSImage? {
        let url = fullImageURL(for: metadata)
        return NSImage(contentsOf: url)
    }

    func thumbnail(for metadata: ClipboardImageMetadata) -> NSImage? {
        let key = metadata.thumbnailFilename as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        let url = thumbnailURL(for: metadata)
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Maintenance

    func sweepOrphanedFiles(referencedFilenames: Set<String>) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directoryURL.path) else {
            return
        }
        for name in contents {
            let full = directoryURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if !referencedFilenames.contains(name) {
                try? fm.removeItem(at: full)
                thumbnailCache.removeObject(forKey: name as NSString)
            }
        }
    }

    func diskUsage() -> Int64 {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directoryURL.path) else {
            return 0
        }
        var total: Int64 = 0
        for name in contents {
            let full = directoryURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if let attrs = try? fm.attributesOfItem(atPath: full.path),
               let size = attrs[.size] as? Int64 {
                total += size
            } else if let size = (try? fm.attributesOfItem(atPath: full.path))?[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    // MARK: - Private helpers

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
        // Enforce owner-only permissions even if directory already existed.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private func resizedCopy(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let maxDim = max(width, height)
        guard maxDim > maxDimension else { return image }
        let scale = maxDimension / maxDim
        let newWidth = max(1, Int((width * scale).rounded()))
        let newHeight = max(1, Int((height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    private func thumbnailData(fromPNGData sourceData: Data, maxDimension: CGFloat) throws -> Data? {
        // Reuse the normalized full PNG so each capture is encoded only once at full size.
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceThumbnailMaxPixelSize as String: Int(maxDimension),
                    kCGImageSourceCreateThumbnailFromImageAlways as String: true
                ] as CFDictionary
              ) else {
            return nil
        }
        return pngData(from: thumb)
    }

    private func writeAtomic(_ data: Data, to url: URL) throws {
        // Filenames are unique UUIDs. Set owner-only permissions on a sibling temporary
        // file before renaming it into place, so the final path never has looser permissions.
        let temporaryURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    enum StoreError: Error {
        case undecodableImage
        case encodeFailed
        case thumbnailFailed
    }
}
