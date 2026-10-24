// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "EXIFKit",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8)],
    products: [.library(name: "EXIFKit", targets: ["EXIFKit"])],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "EXIFKit"),
        .testTarget(
            name: "EXIFKitTests",
            dependencies: [
                "EXIFKit",
                .product(
                    name: "Hummingbird", package: "hummingbird",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .linux, .visionOS, .macCatalyst])
                ),
                .product(
                    name: "HummingbirdTesting", package: "hummingbird",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .linux, .visionOS, .macCatalyst])
                ),
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
