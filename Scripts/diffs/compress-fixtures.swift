// Compresses regenerated ShikiDiffs oracle fixtures in place:
//   swift Scripts/diffs/compress-fixtures.swift Tests/ShikiDiffsTests/Fixtures
// Each `name.json` becomes `name.json.lzma` (Apple's LZMA, read back by
// Tests/ShikiDiffsTests/FixtureSupport.swift) after a lossless round trip.
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Tests/ShikiDiffsTests/Fixtures")
var total = (raw: 0, packed: 0)
for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    where url.pathExtension == "json" {
    let data = try Data(contentsOf: url)
    let packed = try (data as NSData).compressed(using: .lzma) as Data
    guard try (packed as NSData).decompressed(using: .lzma) as Data == data else {
        fatalError("Round trip failed for \(url.lastPathComponent)")
    }
    try packed.write(to: url.appendingPathExtension("lzma"))
    try FileManager.default.removeItem(at: url)
    total.raw += data.count
    total.packed += packed.count
    print("\(url.lastPathComponent): \(data.count) -> \(packed.count) bytes")
}
print("Total: \(total.raw) -> \(total.packed) bytes")
