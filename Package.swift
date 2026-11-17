// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UnderTheRug",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "UnderTheRug",
            path: "Sources/UnderTheRug"
        )
    ]
)
