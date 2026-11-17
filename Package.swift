// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClaudyArchive",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClaudyArchive", targets: ["ClaudyArchive"])],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "ConversationCore", dependencies: ["CZlib"]),
        .executableTarget(name: "ClaudyArchive", dependencies: ["ConversationCore"],
                          resources: [.copy("Resources")]),
        .testTarget(name: "ConversationCoreTests", dependencies: ["ConversationCore"])
    ]
)
