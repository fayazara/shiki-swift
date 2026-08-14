import Foundation
import XCTest
@testable import ShikiCore

final class OnigurumaParityTests: XCTestCase {
    func testMatchesAllRecordedShikiWASMScannerResults() throws {
        let fixtureURLs = try XCTUnwrap(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: nil
            )
        ).filter { $0.lastPathComponent.hasSuffix(".wasm.json") }
        XCTAssertEqual(fixtureURLs.count, 9)

        let decoder = JSONDecoder()
        var checkedCaseCount = 0

        for fixtureURL in fixtureURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let cases = try decoder.decode(
                [ScannerFixture].self,
                from: Data(contentsOf: fixtureURL)
            )

            for fixture in cases {
                let scanner = try OnigScanner(patterns: fixture.patterns)
                let actual = try scanner.findNextMatchSync(
                    fixture.arguments.input,
                    startPosition: fixture.arguments.startPosition,
                    options: OnigFindOptions(rawValue: UInt32(fixture.arguments.options))
                )

                XCTAssertEqual(
                    actual?.index,
                    fixture.result?.index,
                    "Pattern mismatch for \(fixture.id) in \(fixtureURL.lastPathComponent)"
                )
                XCTAssertEqual(
                    actual?.captureIndices,
                    fixture.result?.captureIndices,
                    "Capture mismatch for \(fixture.id) in \(fixtureURL.lastPathComponent)"
                )
                checkedCaseCount += 1
            }
        }

        XCTAssertEqual(checkedCaseCount, 254)
    }
}

private struct ScannerFixture: Decodable {
    let id: String
    let patterns: [String]
    let arguments: ScannerArguments
    let result: ScannerResult?

    private enum CodingKeys: String, CodingKey {
        case id
        case patterns
        case arguments = "args"
        case result
    }
}

private struct ScannerArguments: Decodable {
    let input: String
    let startPosition: Int
    let options: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        input = try container.decode(String.self)
        startPosition = try container.decode(Int.self)
        options = try container.decode(Int.self)
    }
}

private struct ScannerResult: Decodable {
    let index: Int
    let captureIndices: [OnigCaptureIndex]
}

extension OnigCaptureIndex: Decodable {
    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            start: try container.decode(Int.self, forKey: .start),
            end: try container.decode(Int.self, forKey: .end)
        )
    }
}
