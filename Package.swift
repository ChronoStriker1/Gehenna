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
    .library(
      name: "GehennaCore",
      targets: ["GehennaCore"]
    ),
    .library(
      name: "GehennaDaemonShared",
      targets: ["GehennaDaemonShared"]
    ),
    .executable(
      name: "GehennaDaemon",
      targets: ["GehennaDaemon"]
    ),
    .executable(
      name: "GehennaApp",
      targets: ["GehennaApp"]
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
    .target(
      name: "GehennaCore"
    ),
    .target(
      name: "GehennaDaemonShared",
      dependencies: ["GehennaHID", "GehennaCore"]
    ),
    .executableTarget(
      name: "GehennaDaemon",
      dependencies: ["GehennaDaemonShared"]
    ),
    .executableTarget(
      name: "GehennaApp",
      dependencies: ["GehennaCore", "GehennaDaemonShared"]
    ),
    .executableTarget(
      name: "GehennaCLI",
      dependencies: ["GehennaHID", "GehennaCore"]
    ),
    .testTarget(
      name: "GehennaTests",
      dependencies: ["GehennaHID", "GehennaCore"]
    )
  ]
)
