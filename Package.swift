import PackageDescription

let package = Package(
  name: "kai",
  dependencies: [
    .Package(url: "https://github.com/vapor/console.git", majorVersion: 1),
    .Package(url: "https://github.com/trill-lang/LLVMSwift.git", majorVersion: 0, minor: 1),
  ]
)
