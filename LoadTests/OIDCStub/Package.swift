// swift-tools-version:6.0
import PackageDescription

// Load-test identity provider. Not part of the application build.
let package = Package(
    name: "OIDCStub",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.2"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "OIDCStub",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "JWTKit", package: "jwt-kit"),
            ]
        ),
    ]
)
