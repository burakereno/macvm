// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacVM",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MacVM", targets: ["MacVM"]),
        .executable(name: "MacVMRunner", targets: ["MacVMRunner"]),
        .executable(name: "MacVMGuest", targets: ["MacVMGuest"])
    ],
    targets: [
        .target(name: "MacVMCore"),
        .target(name: "GuestControl"),
        .target(name: "MacVMUI"),
        .target(name: "MacVMUpdate", dependencies: ["MacVMCore"]),
        .executableTarget(name: "MacVM", dependencies: ["MacVMCore", "MacVMUI", "MacVMUpdate"]),
        .executableTarget(name: "MacVMRunner", dependencies: ["MacVMCore", "GuestControl", "MacVMUI"]),
        .executableTarget(name: "MacVMGuest", dependencies: ["GuestControl"]),
        .testTarget(name: "MacVMCoreTests", dependencies: ["MacVMCore", "GuestControl", "MacVMUpdate"])
    ],
    swiftLanguageModes: [.v5]
)
