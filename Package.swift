// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MacDroid", platforms: [.macOS(.v13)],
    products: [.executable(name: "MacDroid", targets: ["MacDroid"])],
    targets: [.target(name: "MacDroidCore"), .executableTarget(name: "MacDroid", dependencies: ["MacDroidCore"]), .executableTarget(name: "MacDroidCheck", dependencies: ["MacDroidCore"], path: "Tests/MacDroidCoreTests")])
