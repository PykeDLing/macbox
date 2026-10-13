// swift-tools-version: 6.2
// 用于在 Xcode 中打开项目和运行测试（swift test）；命令行构建 App 请用 ./build.sh（直接调用 swiftc，编译选项与这里一致）
import PackageDescription

let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "MacBox",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "MacBox", path: "Sources/MacBox", swiftSettings: settings),
        .testTarget(name: "MacBoxTests", dependencies: ["MacBox"], path: "Tests/MacBoxTests", swiftSettings: settings),
    ]
)
