// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacVM",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MacVM", targets: ["MacVM"]),
        .executable(name: "MacVMRunner", targets: ["MacVMRunner"]),
        .executable(name: "MacVMGuest", targets: ["MacVMGuest"]),
        .executable(name: "MacVMWindowsPrototype", targets: ["MacVMWindowsPrototype"])
    ],
    targets: [
        .target(name: "MacVMCore"),
        .target(name: "GuestControl"),
        .target(name: "MacVMUI", dependencies: ["MacVMCore"]),
        .target(name: "MacVMUpdate", dependencies: ["MacVMCore"]),
        .executableTarget(name: "MacVM", dependencies: ["MacVMCore", "MacVMUI", "MacVMUpdate", "WindowsPrototypeCore"]),
        .executableTarget(name: "MacVMRunner", dependencies: ["MacVMCore", "GuestControl", "MacVMUI", "WindowsPrototypeCore"]),
        .executableTarget(name: "MacVMGuest", dependencies: ["GuestControl"]),
        .target(name: "WindowsPrototypeCore", dependencies: ["MacVMCore"]),
        .executableTarget(name: "MacVMWindowsPrototype", dependencies: ["WindowsPrototypeCore", "MacVMUI"]),
        .testTarget(name: "WindowsPrototypeTests", dependencies: ["WindowsPrototypeCore"]),
        .testTarget(name: "MacVMCoreTests", dependencies: ["MacVMCore", "GuestControl", "MacVMUpdate"])
    ],
    swiftLanguageModes: [.v5]
)
