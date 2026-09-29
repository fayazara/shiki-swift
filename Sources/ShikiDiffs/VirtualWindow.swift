#if os(macOS)
import Foundation

public struct VirtualWindowSpecs: Equatable, Sendable {
    public var top: Double
    public var bottom: Double
    public init(top: Double, bottom: Double) { self.top = top; self.bottom = bottom }
}

/// Matches upstream window coordinates; inputs and output use logical points.
public func createWindowFromScrollPosition(
    scrollTop: Double, height: Double, scrollHeight: Double,
    fitPerfectly: Bool = false, fitPerfectlyOverscroll: Double = 0,
    overscrollSize: Double
) -> VirtualWindowSpecs {
    let windowHeight = height + overscrollSize * 2
    let effectiveHeight = fitPerfectly ? height + fitPerfectlyOverscroll * 2 : windowHeight
    let extent = max(scrollHeight, effectiveHeight)
    if windowHeight >= extent || fitPerfectly {
        let top = max(scrollTop - fitPerfectlyOverscroll, 0)
        let bottom = min(scrollTop + effectiveHeight, extent)
        return .init(top: top, bottom: max(bottom, top))
    }
    let center = scrollTop + height / 2
    let rawTop = center - windowHeight / 2
    let top = floor(max(rawTop, 0))
    return .init(top: top, bottom: ceil(max(min(rawTop + windowHeight, extent), top)))
}

public func areVirtualWindowSpecsEqual(_ lhs: VirtualWindowSpecs?, _ rhs: VirtualWindowSpecs?) -> Bool {
    lhs == rhs
}

public func areRenderRangesEqual(_ lhs: DiffRenderRange?, _ rhs: DiffRenderRange?) -> Bool {
    lhs == rhs
}

#endif
