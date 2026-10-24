// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FlutterRunbar",
    platforms: [.macOS("26.0")],
    products: [.library(name: "RunbarCore", targets: ["RunbarCore"])],
    targets: [
        .target(name: "RunbarProcess"),
        .target(name: "RunbarCore", dependencies: ["RunbarProcess"]),
        .testTarget(name: "RunbarCoreTests", dependencies: ["RunbarCore"])
    ],
    swiftLanguageModes: [.v5]
)
