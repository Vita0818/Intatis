// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "SwiftStreamingMarkdown",
  defaultLocalization: "en",
  platforms: [.iOS(.v16), .macOS(.v14)],
  products: [
    .library(
      name: "SwiftStreamingMarkdown",
      targets: ["SwiftStreamingMarkdown"])
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    .package(url: "https://github.com/kostub/iosMath.git", exact: "2.5.0")
  ],
  targets: [
    .target(
      name: "SwiftStreamingMarkdown",
      dependencies: [
        .product(name: "Markdown", package: "swift-markdown"),
        .product(
          name: "iosMath",
          package: "iosMath",
          condition: .when(platforms: [.iOS, .macOS])
        )
      ],
      path: "Sources/MarkdownText",
      resources: [
        .process("Resources/Localizable.xcstrings")
      ]
    ),
    .testTarget(
      name: "SwiftStreamingMarkdownTests",
      dependencies: [
        "SwiftStreamingMarkdown"
      ],
      path: "Tests/MarkdownTextTests")
  ],
  swiftLanguageModes: [.v6]
)
