// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Optional at runtime: Apple's SpeechTranscriber is the default and needs no dependency.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        // Its own target: directly testable, and a cross-platform contract shared with the C# side.
        .target(
            name: "MurmurDictionary",
            path: "Sources/MurmurDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Split out like the dictionary: pure timing logic the app target cannot unit test.
        .target(
            name: "MurmurInput",
            path: "Sources/MurmurInput",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "MurmurDictionary",
                "MurmurInput",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Murmur",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MurmurInputTests",
            dependencies: ["MurmurInput"],
            path: "Tests/MurmurInputTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MurmurDictionaryTests",
            dependencies: ["MurmurDictionary"],
            path: "Tests/MurmurDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
