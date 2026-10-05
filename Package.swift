// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GoAffPro",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
    ],
    products: [
        .library(name: "GoAffPro", targets: ["GoAffPro"])
    ],
    targets: [
        .target(
            name: "GoAffPro",
            path: "Sources/GoAffPro"
        ),
        .testTarget(
            name: "GoAffProTests",
            dependencies: ["GoAffPro"],
            path: "Tests/GoAffProTests"
        ),
    ]
)
