// swift-tools-version: 6.2
// MotionForge — native Apple-silicon motion graphics & compositing.
//
//   MFCore     C++20  document model, keyframes, evaluation, project files, undo, caches
//   MFRender   Obj-C++ Metal renderer + Objective-C bridge (MFEngine) for Swift
//   MotionForge Swift  SwiftUI/AppKit editor
//   mftests / mfbench / mfcli   test runner, renderer benchmark, headless render/project tool
import PackageDescription

let package = Package(
    name: "MotionForge",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MotionForge", targets: ["MotionForge"]),
        .executable(name: "mftests", targets: ["mftests"]),
        .executable(name: "mfbench", targets: ["mfbench"]),
        .executable(name: "mfcli", targets: ["mfcli"]),
    ],
    targets: [
        .target(
            name: "MFCore",
            cxxSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Wno-unused-parameter"])]
        ),
        .target(
            name: "MFRender",
            dependencies: ["MFCore"],
            cxxSettings: [.unsafeFlags(["-Wall", "-Wno-unused-parameter"])],
            linkerSettings: [
                .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"), .linkedFramework("ImageIO"), .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("CoreText"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("AVFoundation"), .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "MotionForge",
            dependencies: ["MFRender"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .executableTarget(name: "mftests", dependencies: ["MFRender", "MFCore"]),
        .executableTarget(name: "mfbench", dependencies: ["MFRender", "MFCore"]),
        .executableTarget(name: "mfcli", dependencies: ["MFRender", "MFCore"], linkerSettings: [.linkedFramework("CoreText")]),
    ],
    cxxLanguageStandard: .cxx20
)
