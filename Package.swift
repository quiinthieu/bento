// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Bento",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "BentoCore", targets: ["BentoCore"]),
        .library(name: "BentoUI", targets: ["BentoUI"]),
        .executable(name: "bentoctx", targets: ["bentoctx"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.4.5"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0")
    ],
    targets: [
        .target(
            name: "BentoCore",
            dependencies: [],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoParsing",
            dependencies: [
                "BentoCore",
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
                .product(name: "Yams", package: "Yams")
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoAdapters",
            dependencies: ["BentoCore", "BentoParsing"],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoScanner",
            dependencies: ["BentoCore", "BentoAdapters"],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoTokenizer",
            dependencies: ["BentoCore"],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoLogIngest",
            dependencies: ["BentoCore", "BentoParsing"],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoMCPProbe",
            dependencies: ["BentoCore"],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoHygiene",
            dependencies: ["BentoCore", "BentoParsing", "BentoTokenizer"],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoStore",
            dependencies: [
                "BentoCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoFixes",
            dependencies: ["BentoCore", "BentoParsing", "BentoStore"],
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoUI",
            dependencies: [
                "BentoCore",
                "BentoScanner",
                "BentoLogIngest",
                "BentoTokenizer",
                "BentoMCPProbe",
                "BentoHygiene",
                "BentoFixes",
                "BentoStore"
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "bentoctx",
            dependencies: [
                "BentoCore",
                "BentoScanner",
                "BentoLogIngest",
                "BentoTokenizer",
                "BentoMCPProbe",
                "BentoHygiene",
                "BentoFixes",
                "BentoStore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/BentoCLI",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "BentoApp",
            dependencies: ["BentoUI"],
            path: "Sources/BentoApp",
            exclude: ["README.md"]
        ),
        .target(
            name: "BentoTestSupport",
            dependencies: ["BentoCore"],
            path: "Tests/BentoTestSupport"
        ),
        .testTarget(
            name: "BentoCoreTests",
            dependencies: ["BentoCore", "BentoTestSupport"],
            exclude: ["__golden__"]
        ),
        .testTarget(
            name: "BentoParsingTests",
            dependencies: ["BentoCore", "BentoParsing", "BentoTestSupport"]
        ),
        .testTarget(
            name: "BentoAdaptersTests",
            dependencies: ["BentoCore", "BentoParsing", "BentoAdapters", "BentoTestSupport"],
            exclude: ["__golden__"]
        ),
        .testTarget(
            name: "BentoStoreTests",
            dependencies: [
                "BentoCore",
                "BentoStore",
                "BentoAdapters",
                "BentoScanner",
                "BentoTestSupport",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "BentoScannerTests",
            dependencies: ["BentoCore", "BentoAdapters", "BentoScanner", "BentoStore", "BentoTestSupport"]
        ),
        .testTarget(
            name: "BentoCLITests",
            dependencies: ["BentoCore", "BentoStore", "BentoScanner", "BentoTestSupport"]
        ),
        .testTarget(
            name: "BentoUITests",
            dependencies: ["BentoCore", "BentoUI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
