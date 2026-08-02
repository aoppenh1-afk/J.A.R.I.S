// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "JarvisMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
        .executable(name: "JarvisApp", targets: ["JarvisApp"]),
        .executable(name: "JarvisDiagnostics", targets: ["JarvisDiagnostics"]),
    ],
    targets: [
        .target(
            name: "ParakeetTDT",
            path: "Vendor/ParakeetTDT/Sources"
        ),
        .target(
            name: "JarvisCore",
            dependencies: ["ParakeetTDT"]
        ),
        .executableTarget(
            name: "JarvisApp",
            dependencies: ["JarvisCore"],
            resources: [
                .process("Resources/MenuBarIconTemplate.png"),
                .process("Resources/MenuBarIconTemplate@2x.png"),
                .copy("Resources/GlassVoiceOrbStudy"),
            ]
        ),
        .executableTarget(
            name: "JarvisDiagnostics",
            dependencies: ["JarvisCore", "ParakeetTDT"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)
