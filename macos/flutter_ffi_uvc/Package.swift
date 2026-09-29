// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "flutter_ffi_uvc",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "flutter-ffi-uvc", targets: ["flutter_ffi_uvc"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "flutter_ffi_uvc",
            dependencies: [],
            cSettings: [
                .headerSearchPath("include/flutter_ffi_uvc")
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("IOKit"),
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
