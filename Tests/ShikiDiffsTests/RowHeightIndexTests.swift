import Foundation
import Testing
@testable import ShikiDiffs

struct RowHeightIndexTests {
    @Test func sparseMeasurementsMatchExplicitRowGeometry() {
        var index = RowHeightIndex(rowCount: 1000, lineHeight: 20, variableRows: [0, 7, 81, 999])
        var heights = Array(repeating: CGFloat(20), count: 1000)
        for (row, height) in [(0, 75), (81, 180), (7, 1), (999, 45), (81, 30)] {
            index.setHeight(CGFloat(height), for: row); heights[row] = CGFloat(height)
            var y: CGFloat = 0
            for number in heights.indices {
                #expect(index.origin(of: number) == y)
                #expect(index.height(of: number) == heights[number])
                #expect(index.row(at: y) == number)
                #expect(index.row(at: y + heights[number] - 0.25) == number)
                y += heights[number]
            }
            #expect(index.totalHeight == y)
            #expect(index.row(at: y) == 999)
        }
    }
    @Test func zeroHeightRowsDoNotCaptureBoundaryHits() {
        var index = RowHeightIndex(rowCount: 5, lineHeight: 20, variableRows: [0, 1, 3])
        for row in [0, 1, 3] { index.setHeight(0, for: row) }
        #expect(index.totalHeight == 40)
        #expect(index.row(at: 0) == 2)
        #expect(index.row(at: 19.9) == 2)
        #expect(index.row(at: 20) == 4)
        #expect(index.origin(of: 4) == 20)
    }
    @Test func uniformMillionLineGeometryAndInvalidMeasurements() {
        var index = RowHeightIndex(rowCount: 1_000_000, lineHeight: 20)
        index.setHeight(500, for: 42)
        #expect(index.totalHeight == 20_000_000)
        #expect(index.row(at: 19_999_980) == 999_999)
        #expect(index.row(at: -1) == 0)
        #expect(index.origin(of: -1) == 0)
        let empty = RowHeightIndex(rowCount: 0, lineHeight: 20)
        #expect(empty.totalHeight == 0 && empty.row(at: 100) == 0)
    }
}
