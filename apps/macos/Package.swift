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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
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
            dependencies: ["JarvisCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [
                .process("Resources/MenuBarIconTemplate.png"),
                .process("Resources/MenuBarIconTemplate@2x.png"),
                .copy("Resources/GlassVoiceOrbStudy"),
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
