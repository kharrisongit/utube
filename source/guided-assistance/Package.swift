// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "GuidedAssistanceCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "KnowledgeCore", targets: ["KnowledgeCore"])],
    targets: [
        .target(name: "KnowledgeCore", path: "Core"),
        .testTarget(name: "KnowledgeCoreTests", dependencies: ["KnowledgeCore"], path: "Tests")
    ]
)
