// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "LocalOps",
  defaultLocalization: "zh-Hans",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "LocalOps", targets: ["LocalOpsApp"]),
    .executable(name: "LocalOpsTests", targets: ["LocalOpsTests"]),
    .library(name: "LocalOpsCore", targets: ["LocalOpsCore"]),
    .library(name: "LocalOpsWeb", targets: ["LocalOpsWeb"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/groue/GRDB.swift.git",
      exact: "7.11.1"
    ),
    .package(
      url: "https://github.com/swhitty/FlyingFox.git",
      exact: "0.27.1"
    ),
  ],
  targets: [
    .target(
      name: "LocalOpsCore",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      resources: [
        .process("Resources")
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "LocalOpsWeb",
      dependencies: [
        "LocalOpsCore",
        .product(name: "FlyingFox", package: "FlyingFox"),
        .product(name: "FlyingSocks", package: "FlyingFox"),
      ],
      resources: [
        .process("Resources")
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "LocalOpsApp",
      dependencies: ["LocalOpsCore", "LocalOpsWeb"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "LocalOpsTests",
      dependencies: ["LocalOpsCore", "LocalOpsWeb"],
      path: "tests/LocalOpsTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
