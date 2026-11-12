// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FlutterRunbar",
    platforms: [.macOS("26.0")],
    products: [.library(name: "RunbarCore", targets: ["RunbarCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "RunbarProcess"),
        .target(name: "RunbarCore", dependencies: ["RunbarProcess", "CSQLite"]),
        .testTarget(name: "RunbarCoreTests", dependencies: ["RunbarCore"])
    ],
    swiftLanguageModes: [.v5]
)
