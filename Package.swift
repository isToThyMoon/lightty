// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lightty",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 应用内更新（appcast 源指向 GitHub Releases，EdDSA 签名校验）
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // 预构建的 libghostty；由 scripts/sync-ghosttykit.sh 从 vendor 产物同步而来
        // （SwiftPM 要求 lib 前缀命名，vendor 原件不符合）
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        // 任务数据层：纯逻辑，无 AppKit 依赖
        .target(name: "LighttyCore"),
        .testTarget(name: "LighttyCoreTests", dependencies: ["LighttyCore"]),
        .executableTarget(
            name: "lightty",
            dependencies: [
                "GhosttyKit", "LighttyCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.process("Resources")],
            linkerSettings: [
                // 静态库自身不携带链接信息，必须显式补齐（清单来自对归档 nm -u 的实测）
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
                .linkedFramework("GameController"),
            ]
        ),
    ]
)
