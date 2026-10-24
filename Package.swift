// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FlutterRunbar",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "FlutterRunbar", targets: ["FlutterRunbar"])],
    targets: [
        .target(name: "RunbarProcess"),
        .target(name: "RunbarCore", dependencies: ["RunbarProcess"]),
        .executableTarget(name: "FlutterRunbar", dependencies: ["RunbarCore"]),
        .testTarget(name: "RunbarCoreTests", dependencies: ["RunbarCore"])
    ],
    swiftLanguageModes: [.v5]
)
