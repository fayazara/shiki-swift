import Testing
@testable import ShikiDiffs

struct RenderOptionEqualityTests {
    @Test func fileOptionsPreserveStrictThemeAndNumberSemantics() {
        let base = RenderFileOptions(theme: .single("é"), useTokenTransformer: true, tokenizeMaxLineLength: 1000)
        #expect(areFileRenderOptionsEqual(base, base))
        var changed = base; changed.theme = .single("e\u{301}")
        #expect(!areFileRenderOptionsEqual(base, changed))
        changed = base; changed.useTokenTransformer = false
        #expect(!areFileRenderOptionsEqual(base, changed))
        changed = base; changed.tokenizeMaxLineLength = .nan
        #expect(!areFileRenderOptionsEqual(changed, changed))
        var negativeZero = base; negativeZero.tokenizeMaxLineLength = -0.0
        changed.tokenizeMaxLineLength = 0
        #expect(areFileRenderOptionsEqual(negativeZero, changed))
    }
    @Test func diffOptionsIncludeBothInlineControls() {
        let base = RenderDiffOptions(theme: .single("pierre-dark"), useTokenTransformer: false,
            tokenizeMaxLineLength: 100_000, lineDiffType: .wordAlt, maxLineDiffLength: 1000)
        #expect(areDiffRenderOptionsEqual(base, base))
        var changed = base; changed.lineDiffType = .char
        #expect(!areDiffRenderOptionsEqual(base, changed))
        changed = base; changed.maxLineDiffLength = 999
        #expect(!areDiffRenderOptionsEqual(base, changed))
        changed = base; changed.tokenizeMaxLineLength = 100
        #expect(!areDiffRenderOptionsEqual(base, changed))
    }
}
