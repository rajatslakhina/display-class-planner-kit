// swift-tools-version: 6.0
import PackageDescription

// Platforms: only iOS is declared, because iOS Simulator is the only Apple
// platform this package's CI actually builds (see the companion demo repo's
// macos-15 job). Declaring platforms CI never exercises is a claim, not a fact.
// Linux has no `platforms:` entry to declare — SwiftPM ignores the array there,
// and the Linux job builds and tests the core module directly.
let package = Package(
    name: "display-class-planner-kit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DisplayClassPlanner", targets: ["DisplayClassPlanner"]),
        .library(name: "DisplayClassPlannerUI", targets: ["DisplayClassPlannerUI"]),
    ],
    targets: [
        .target(name: "DisplayClassPlanner"),
        .target(
            name: "DisplayClassPlannerUI",
            dependencies: ["DisplayClassPlanner"]
        ),
        .testTarget(
            name: "DisplayClassPlannerTests",
            dependencies: ["DisplayClassPlanner"]
        ),
    ]
)
