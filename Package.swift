// swift-tools-version: 6.0

import Foundation
import PackageDescription

/// Linux 上只跑纯逻辑单测：`MOLA_CORE_ONLY=1 swift test`（xtool 交叉编译 iOS 时不要设置）。
let coreOnly = ProcessInfo.processInfo.environment["MOLA_CORE_ONLY"] != nil

/// ld64.lld 只在 macOS / 模拟器目标默认做 ad-hoc 签名。xtool 写入 entitlements（xtool.yml `entitlementsPath`）
/// 的签名步骤不会新增 LC_CODE_SIGNATURE，二进制必须先带一个 ad-hoc 签名，否则报
/// "Can't find free space of LoadCommands for CodeSignature"。
let adhocSign: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-adhoc_codesign"])]

/// 扩展自定义入口（见 Sources/MolaShare/Entry.swift）。`-u` 让入口符号在死代码剔除时作为根保留。
func entry(_ symbol: String) -> [LinkerSetting] {
    [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", symbol, "-Xlinker", "-u", "-Xlinker", symbol])]
}

let appTargets: [Target] = [
    .target(
        name: "MolaStorage",
        dependencies: ["MolaCore"],
        swiftSettings: [.swiftLanguageMode(.v6)],
        linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    .target(
        name: "MolaGPT",
        dependencies: ["MolaCore", "MolaStorage", "MolaActivity", .product(name: "SwiftMath", package: "SwiftMath")],
        swiftSettings: [.swiftLanguageMode(.v6)],
        linkerSettings: adhocSign
        ),
    // 实时活动的共享数据结构（主 App 与 MolaWidgets 共用同一类型）。
    .target(
        name: "MolaActivity",
        swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    // 实时活动 / 灵动岛（Widget 扩展）。
    .target(
        name: "MolaWidgets",
        dependencies: ["MolaActivity"],
        swiftSettings: [.swiftLanguageMode(.v6)],
        linkerSettings: adhocSign + entry("_MolaWidgetsMain")
        ),
    // 分享扩展（xtool.yml `extensions`）。NSItemProvider 回调不是 Sendable，用 Swift 5 语言模式。
    .target(
        name: "MolaShare",
        dependencies: ["MolaCore"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: adhocSign + entry("_MolaShareMain")
        ),
]

// 模块分层（单向依赖）：
//   MolaCore     —— 纯 Foundation：领域模型、Provider 请求构造、SSE 解析、上下文组装。可在 Linux 上 `swift build --target MolaCore` / `swift test`。
//   MolaStorage  —— SQLite3 + Keychain 持久化（仅 Darwin）。
//   MolaGPT      —— SwiftUI App（xtool 要求唯一 library product）。
let package = Package(
    name: "MolaGPT",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // 主 App；xtool.yml 用 `product: MolaGPT` 指定，扩展各自一个 library product。
        .library(
            name: "MolaGPT",
            targets: [coreOnly ? "MolaCore" : "MolaGPT"]
        ),
    ] + (coreOnly ? [] : [
        .library(name: "MolaShare", targets: ["MolaShare"]),
        .library(name: "MolaWidgets", targets: ["MolaWidgets"]),
        // Xcode 工程（Xcode/project.yml）的 App / 扩展 target 直接编译各自源码，依赖下面这些模块。
        .library(name: "MolaCore", targets: ["MolaCore"]),
        .library(name: "MolaStorage", targets: ["MolaStorage"]),
        .library(name: "MolaActivity", targets: ["MolaActivity"]),
    ]),
    dependencies: coreOnly ? [] : [
        // 原生 LaTeX 渲染（CoreText，自带数学字体）
        .package(url: "https://github.com/mgriebling/SwiftMath", exact: "1.7.3"),
    ],
    targets: [
        .target(
            name: "MolaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MolaCoreTests",
            dependencies: ["MolaCore"]
        ),
    ] + (coreOnly ? [] : appTargets)
)
