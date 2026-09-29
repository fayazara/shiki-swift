#if os(macOS)
import AppKit

private final class MixKey: NSObject {
    let background: NSColor, color: NSColor
    let fraction: CGFloat
    init(_ background: NSColor, _ color: NSColor, _ fraction: CGFloat) { self.background = background; self.color = color; self.fraction = fraction }
    override var hash: Int { var h = Hasher(); h.combine(background.hash); h.combine(color.hash); h.combine(fraction); return h.finalize() }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MixKey else { return false }
        return background.isEqual(other.background) && color.isEqual(other.color) && fraction == other.fraction
    }
}
private final class MixCache: @unchecked Sendable {
    static let shared = MixCache()
    let values = NSCache<MixKey, NSColor>()
    private init() { values.countLimit = 512 }
}
extension NSColor {
    /// Equivalent interpolation space to upstream color-mix(in lab, ...).
    /// CoreGraphics/ColorSync performs sRGB <-> D50 Lab profile conversion.
    static func diffLabMix(_ background: NSColor, _ color: NSColor, fraction: CGFloat) -> NSColor {
        let weight = min(1, max(0, fraction))
        let key = MixKey(background, color, weight)
        if let cached = MixCache.shared.values.object(forKey: key) { return cached }
        guard let space = CGColorSpace(name: CGColorSpace.genericLab),
              let a = background.cgColor.converted(to: space, intent: .relativeColorimetric, options: nil)?.components,
              let b = color.cgColor.converted(to: space, intent: .relativeColorimetric, options: nil)?.components,
              a.count == 4, b.count == 4 else { return background.blended(withFraction: weight, of: color) ?? background }
        let alpha = a[3] * (1 - weight) + b[3] * weight
        guard alpha > 0 else { return .clear }
        var mixed = (0..<3).map { (a[$0] * a[3] * (1 - weight) + b[$0] * b[3] * weight) / alpha }
        mixed.append(alpha)
        guard let result = CGColor(colorSpace: space, components: mixed),
              let rgb = result.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric, options: nil),
              let value = NSColor(cgColor: rgb) else { return background }
        MixCache.shared.values.setObject(value, forKey: key)
        return value
    }
}

#endif
