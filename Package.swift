// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SeatGauge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SeatGauge", targets: ["SeatGauge"]),
        .executable(name: "seatgauge-cli", targets: ["seatgauge-cli"]),
    ],
    targets: [
        // Foundation only, so every type in it is testable without a screen.
        .target(name: "SeatGaugeCore", path: "Sources/SeatGaugeCore"),
        .executableTarget(name: "SeatGauge", dependencies: ["SeatGaugeCore"], path: "Sources/SeatGauge",
                          swiftSettings: [
                              .defaultIsolation(MainActor.self),
                              .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                              .enableUpcomingFeature("InferIsolatedConformances"),
                          ]),
        .executableTarget(name: "seatgauge-cli", dependencies: ["SeatGaugeCore"], path: "Sources/seatgauge-cli"),
        // What both test targets share: the scripted runner and the fixtures.
        .target(name: "SeatGaugeTestSupport", dependencies: ["SeatGaugeCore"], path: "Tests/Support"),
        .testTarget(name: "SeatGaugeCoreTests", dependencies: ["SeatGaugeCore", "SeatGaugeTestSupport"],
                    path: "Tests/SeatGaugeCoreTests"),
        // Cases that need the app target: a real window, the delegate, the
        // panel's views, and the suites those cases share helpers with.
        .testTarget(name: "SeatGaugeTests", dependencies: ["SeatGaugeCore", "SeatGauge", "SeatGaugeTestSupport"],
                    path: "Tests/SeatGaugeTests"),
    ],
    swiftLanguageModes: [.v6]
)
