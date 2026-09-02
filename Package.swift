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
        // 壳层测试：目前只覆盖 HookInstaller——它是全仓库唯一改写用户自有文件的
        // 代码，没有回归保护不可接受。该类型刻意不依赖 AppKit，可直接对 fixture 测。
        .testTarget(name: "LighttyTests", dependencies: ["lightty"]),
        // agent hook helper：把 hook 事件翻译成 pane 状态文件。
        // 只链 Foundation + LighttyCore——PreToolUse 每次工具调用都触发，
        // 进程启动开销会直接变成用户 agent 的延迟税，绝不能引入 AppKit / GhosttyKit。
        .executableTarget(name: "lightty-hook", dependencies: ["LighttyCore"]),
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
