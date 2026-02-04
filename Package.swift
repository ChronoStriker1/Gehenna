// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Gehenna",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "GehennaHID",
      targets: ["GehennaHID"]
    ),
    .executable(
      name: "GehennaCLI",
      targets: ["GehennaCLI"]
    )
  ],
  targets: [
    .target(
      name: "GehennaHID"
    ),
    .executableTarget(
      name: "GehennaCLI",
      dependencies: ["GehennaHID"]
    ),
    .testTarget(
      name: "GehennaTests",
      dependencies: ["GehennaHID"]
    )
  ]
)
