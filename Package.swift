// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "KakaoToLinear",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "KakaoLinearCore", targets: ["KakaoLinearCore"]),
    .executable(name: "kakao-linear", targets: ["KakaoLinearCLI"]),
    .executable(name: "KakaoLinearApp", targets: ["KakaoLinearApp"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/sqlcipher/SQLCipher.swift.git",
      exact: "4.10.0"
    ),
    .package(
      url: "https://github.com/krzyzanowskim/CryptoSwift.git",
      exact: "1.10.0"
    ),
    // macOS 자동 업데이트 프레임워크(Sparkle) — GitHub Releases appcast 기반.
    .package(
      url: "https://github.com/sparkle-project/Sparkle.git",
      from: "2.6.0"
    ),
  ],
  targets: [
    .target(
      name: "KakaoLinearCore",
      dependencies: [
        .product(name: "SQLCipher", package: "SQLCipher.swift"),
        .product(name: "CryptoSwift", package: "CryptoSwift"),
      ]
    ),
    .executableTarget(
      name: "KakaoLinearCLI",
      dependencies: ["KakaoLinearCore"]
    ),
    .executableTarget(
      name: "KakaoLinearApp",
      dependencies: [
        "KakaoLinearCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ]
    ),
    .testTarget(
      name: "KakaoLinearCoreTests",
      dependencies: ["KakaoLinearCore"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "KakaoLinearCLITests",
      dependencies: ["KakaoLinearCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
