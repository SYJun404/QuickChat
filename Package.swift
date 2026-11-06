// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QuickChat",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned below 1.16.0: later versions contain #Preview macros, which fail to
        // compile with Command Line Tools alone (the previews plugin ships only in Xcode).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0"),
        .package(url: "https://github.com/CoreOffice/CoreXLSX", from: "0.14.0"),
        .package(url: "https://github.com/JohnSundell/Splash", from: "0.16.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "QuickChat",
            dependencies: ["KeyboardShortcuts", "CoreXLSX", "Splash", "SwiftMath", "QuickChatBundleShim", "PopSvg"],
            path: "Sources/QuickChat"
        ),
        .target(
            name: "PopSvg",
            resources: [
                .copy("edit.svg"), .copy("history.svg"), .copy("pin.svg"),
                .copy("reasoning.svg"), .copy("copy.svg"), .copy("copy-check.svg"),
                .copy("fork.svg"), .copy("retry.svg"), .copy("Edit-prompt.svg"),
            ]
        ),
        // Objective-C: the Bundle.module redirect for the assembled .app (see the .m).
        .target(name: "QuickChatBundleShim", path: "Sources/QuickChatBundleShim"),
    ]
)
