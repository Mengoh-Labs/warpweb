// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "warpweb", platforms: [.macOS(.v14)], products: [.executable(name: "warpweb", targets: ["warpweb"])], targets: [
    .target(name: "WarpWebCore"),
    .target(name: "CWarpWeb", linkerSettings: [.linkedLibrary("z")]),
    .executableTarget(name: "warpweb", dependencies: ["WarpWebCore", "CWarpWeb"], resources: [.copy("Resources")]),
    .testTarget(name: "WarpWebCoreTests", dependencies: ["WarpWebCore", "CWarpWeb"])
])
