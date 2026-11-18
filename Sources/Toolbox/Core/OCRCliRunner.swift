import AppKit
import CoreGraphics
import Foundation

/// Headless OCR developer modes (`Toolbox --ocr-file <path>` / `Toolbox --ocr-capture`).
///
/// Runs the exact same on-device engine path the Screen OCR module uses (load → prepare →
/// Vision recognize) and prints a diagnostic summary to stdout. Built for diagnosing
/// "no text found" without needing the interactive crosshair:
///
/// - `--ocr-file <path>` — OCR any existing image file.
/// - `--ocr-capture` — non-interactive full-main-screen capture via `screencapture -x`
///   (runs under Toolbox's own Screen Recording TCC identity, i.e. exactly what the
///   live hotkey flow would see), then OCRs the result.
///
/// Isolated like `--self-test`: no UI, no user config mutation, no clipboard writes.
/// Exit codes: 0 = text or QR found, 1 = empty/failed, 2 = usage error.
@MainActor
enum OCRCliRunner {
    static func runFile(path: String?) -> Int32 {
        guard let path, !path.isEmpty else {
            print("usage: Toolbox --ocr-file <image-path>")
            return 2
        }
        guard FileManager.default.fileExists(atPath: path) else {
            print("--ocr-file: file not found: \(path)")
            return 2
        }
        return recognizePath(URL(fileURLWithPath: path))
    }

    static func runCapture() -> Int32 {
        let granted = ScreenCapturePermission.isGranted
        print("Screen Recording permission: \(granted ? "granted" : "NOT granted (capture will likely come back black)")")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-ocr-cli-\(UUID().uuidString).png")
        try? FileManager.default.removeItem(at: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x = no shutter sound; no -i = full main-screen capture, no crosshair.
        process.arguments = ["-x", url.path]
        do {
            try process.run()
        } catch {
            print("Could not start /usr/sbin/screencapture: \(error)")
            try? FileManager.default.removeItem(at: url)
            return 1
        }
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: url) }

        guard process.terminationStatus == 0 else {
            print("screencapture exited with status \(process.terminationStatus)")
            return 1
        }
        return recognizePath(url)
    }

    private static func recognizePath(_ url: URL) -> Int32 {
        let load = ScreenOCREngine.loadCapturedImage(at: url)
        guard let image = load.image else {
            print("Could not decode \(url.lastPathComponent) (kind: \(load.kind), \(load.failureMessage ?? ""))")
            return 1
        }

        let prepared = ScreenOCREngine.prepareImage(image)
        print("Image: \(image.width)x\(image.height)" +
            (prepared === image ? "" : " -> 2x upscaled to \(prepared.width)x\(prepared.height)"))

        let result = ScreenOCREngine.recognize(
            in: prepared,
            preserveLineBreaks: true,
            detectBarcodes: true
        )

        print("Vision: \(result.textObservationCount) text observation(s), \(result.qrPayloads.count) barcode payload(s), near-black \(result.blackFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a")\(result.engineError.map { " · engine error: \($0)" } ?? "")")

        if result.isEmpty {
            print("Result: EMPTY" + (result.looksBlank
                ? " (image is near-black — check Screen Recording permission, or the selection was a blank/black area)"
                : " (no text detected)"))
            return 1
        }

        print("Result: \(result.lineCount) line(s)")
        print(result.clipboardString)
        return 0
    }
}
