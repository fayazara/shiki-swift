import Testing
import Foundation
@testable import ShikiDiffs

@Suite struct FileHeightIndexTests {
    @Test func measuredHeightsAndDistantLookup() {
        var index = FileHeightIndex(), heights: [CGFloat] = []
        for file in 0..<10000 {
            let height = CGFloat(88 + file % 37)
            heights.append(height); index.append(height)
        }
        for file in stride(from: 9999, through: 0, by: -71) {
            heights[file] += CGFloat(file % 113)
            index.update(file, height: heights[file])
        }
        var offset: CGFloat = 0
        for file in heights.indices {
            #expect(index[file] == offset)
            #expect(index.file(at: offset) == file)
            #expect(index.file(at: offset + heights[file] - 0.5) == file)
            offset += heights[file]
        }
        #expect(index.last == offset)
        #expect(index.file(at: -10) == 0)
        #expect(index.file(at: offset + 100) == heights.count - 1)
    }
}
