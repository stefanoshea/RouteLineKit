// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RouteLineKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "RouteLineKit", targets: ["RouteLineKit"])],
    targets: [
        .target(name: "RouteLineKit"),
        .testTarget(name: "RouteLineKitTests", dependencies: ["RouteLineKit"])
    ]
)
