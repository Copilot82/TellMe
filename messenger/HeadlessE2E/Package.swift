// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "TellMeHeadlessE2E",
  platforms: [
    .macOS(.v13),
  ],
  products: [
    .library(
      name: "TellMeHeadlessE2ECore",
      targets: ["TellMeHeadlessE2ECore"]
    ),
    .executable(
      name: "tellme-e2e-bot",
      targets: ["tellme-e2e-bot"]
    ),
  ],
  targets: [
    .target(
      name: "TellMeHeadlessE2ECore"
    ),
    .executableTarget(
      name: "tellme-e2e-bot",
      dependencies: ["TellMeHeadlessE2ECore"]
    ),
    .testTarget(
      name: "TellMeHeadlessE2ECoreTests",
      dependencies: ["TellMeHeadlessE2ECore"]
    ),
  ]
)
