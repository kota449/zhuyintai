// SPDX-License-Identifier: Apache-2.0
// swift-tools-version: 6.0
// 「更新檢查」獨立套件：只負責通知，不下載、不安裝。
import PackageDescription

let package = Package(
    name: "UpdateCheck",
    defaultLocalization: "zh-Hant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UpdateCheck", targets: ["UpdateCheck"])
    ],
    targets: [
        .target(name: "UpdateCheck"),
        .testTarget(
            name: "UpdateCheckTests",
            dependencies: ["UpdateCheck"]
        ),
    ]
)
