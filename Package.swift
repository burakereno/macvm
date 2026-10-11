// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacVM",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MacVM", targets: ["MacVM"]),
        .executable(name: "MacVMRunner", targets: ["MacVMRunner"])
    ],
    targets: [
        .target(name: "MacVMCore"),
        .executableTarget(name: "MacVM", dependencies: ["MacVMCore"]),
        .executableTarget(name: "MacVMRunner", dependencies: ["MacVMCore"]),
        .testTarget(name: "MacVMCoreTests", dependencies: ["MacVMCore"])
    ],
    swiftLanguageModes: [.v5]
)
