import Foundation

/// The oracle fixtures are stored LZMA-compressed (about 54 MB of JSON as
/// under 1 MB) because SwiftPM clones this repository in full for every
/// dependent package. This decompresses one into a temporary file, once per
/// test process, and returns its URL.
func fixtureURL(_ name: String) -> URL? {
    FixtureCache.shared.url(for: name)
}

private final class FixtureCache: @unchecked Sendable {
    static let shared = FixtureCache()
    private let lock = NSLock()
    private var urls: [String: URL] = [:]
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShikiDiffsFixtures-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    func url(for name: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = urls[name] { return cached }
        guard let packed = Bundle.module.url(forResource: name, withExtension: "json.lzma", subdirectory: "Fixtures"),
              let compressed = try? Data(contentsOf: packed),
              let json = try? (compressed as NSData).decompressed(using: .lzma) as Data else { return nil }
        let url = directory.appendingPathComponent("\(name).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try json.write(to: url)
        } catch {
            return nil
        }
        urls[name] = url
        return url
    }
}
