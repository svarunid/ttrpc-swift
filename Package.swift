// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ttrpc-swift",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "TTRPC", targets: ["TTRPCClient", "TTRPCServer"]),
        .library(name: "TTRPCCore", targets: ["TTRPCCore"]),
        .library(name: "TTRPCProtobuf", targets: ["TTRPCProtobuf"]),
        .library(name: "TTRPCNIOTransport", targets: ["TTRPCNIOTransport"]),
        .library(name: "TTRPCClient", targets: ["TTRPCClient"]),
        .library(name: "TTRPCServer", targets: ["TTRPCServer"]),
        .executable(name: "protoc-gen-swift-ttrpc", targets: ["protoc-gen-swift-ttrpc"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.1"),
    ],
    targets: [
        // MARK: - Core protocol types
        .target(
            name: "TTRPCCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),

        // MARK: - Protobuf serialization
        .target(
            name: "TTRPCProtobuf",
            dependencies: [
                "TTRPCCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),

        // MARK: - NIO transport layer
        .target(
            name: "TTRPCNIOTransport",
            dependencies: [
                "TTRPCCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),

        // MARK: - Client
        .target(
            name: "TTRPCClient",
            dependencies: [
                "TTRPCCore",
                "TTRPCProtobuf",
                "TTRPCNIOTransport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),

        // MARK: - Server
        .target(
            name: "TTRPCServer",
            dependencies: [
                "TTRPCCore",
                "TTRPCProtobuf",
                "TTRPCNIOTransport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),

        // MARK: - Code generation
        .executableTarget(
            name: "protoc-gen-swift-ttrpc",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "TTRPCCoreTests",
            dependencies: [
                "TTRPCCore",
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "TTRPCNIOTransportTests",
            dependencies: [
                "TTRPCNIOTransport",
                "TTRPCCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "TTRPCIntegrationTests",
            dependencies: [
                "TTRPCClient",
                "TTRPCServer",
                "TTRPCCore",
                "TTRPCProtobuf",
                "TTRPCNIOTransport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
