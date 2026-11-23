// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PerchFiles",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PerchFiles", targets: ["PerchFiles"])],
    targets: [.systemLibrary(name: "CArchive"), .executableTarget(name: "PerchFiles", dependencies: ["CArchive"])]
)
