// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Loupe",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Loupe", targets: ["Loupe"])
    ],
    targets: [
        .systemLibrary(name: "CArchive", path: "Sources/CArchive"),
        .target(name: "LoupeObjC", path: "Sources/LoupeObjC"),
        .target(
            name: "LoupeCore",
            dependencies: ["CArchive"],
            path: "Sources/LoupeCore"
        ),
        .target(
            name: "LoupeApp",
            dependencies: ["LoupeCore", "LoupeObjC"],
            path: "Sources/LoupeApp",
            exclude: ["Resources", "Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("Quartz"), .linkedFramework("PDFKit"),
                .linkedFramework("AVKit"), .linkedFramework("AVFoundation"), .linkedFramework("WebKit"),
                .linkedFramework("CoreText"), .linkedFramework("OpenGL"), .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                .linkedFramework("QuickLookThumbnailing"), .linkedFramework("Vision"),
            ]
        ),
        .executableTarget(
            name: "Loupe",
            dependencies: ["LoupeApp"],
            path: "Sources/Loupe"
        ),
        .testTarget(
            name: "LoupeAppTests",
            dependencies: ["LoupeApp", "LoupeCore"],
            path: "Tests/LoupeAppTests"
        ),
        .testTarget(
            name: "LoupeCoreTests",
            dependencies: ["LoupeCore"],
            path: "Tests/LoupeCoreTests"
        ),
    ]
)
