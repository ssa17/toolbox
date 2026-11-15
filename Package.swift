// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sparkleDir = "\(packageDir)/vendor/sparkle"

let package = Package(
    name: "Toolbox",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Toolbox", targets: ["Toolbox"])
    ],
    targets: [
        .executableTarget(
            name: "Toolbox",
            path: "Sources/Toolbox",
            swiftSettings: [
                .unsafeFlags(["-F", sparkleDir])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags([
                    "-F", sparkleDir,
                    "-framework", "Sparkle",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        )
    ]
)
