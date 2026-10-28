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
        .executableTarget(
            name: "Loupe",
            dependencies: ["LoupeCore", "LoupeObjC"],
            path: "Sources/Loupe",
            exclude: ["Resources", "Info.plist"],
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("Quartz"), .linkedFramework("PDFKit"),
                .linkedFramework("AVKit"), .linkedFramework("AVFoundation"), .linkedFramework("WebKit"),
                .linkedFramework("CoreText"), .linkedFramework("OpenGL"), .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "LoupeCoreTests",
            dependencies: ["LoupeCore"],
            path: "Tests/LoupeCoreTests"
        )
    ]
)
