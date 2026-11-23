// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LabelPrint",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CLzma", path: "Sources/CLzma", linkerSettings: [.linkedLibrary("lzma")]),
        .target(name: "LabelCore", dependencies: ["CLzma"], path: "Sources/LabelCore"),
        .executableTarget(name: "LabelPrint", dependencies: ["LabelCore"], path: "Sources/LabelPrint"),
    ]
)
