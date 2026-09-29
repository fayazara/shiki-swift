#if os(macOS)
/// Highlighting inputs from upstream RenderFileOptions, separate from viewport layout.
/// The web transformer flag describes HTML token wrappers. Native pointer and
/// editor geometry always retain original token boundaries directly; this record
/// preserves the upstream flag for option comparison, without generating HTML.
public struct RenderFileOptions: Sendable {
    public var theme: DiffThemeSelection
    public var useTokenTransformer: Bool
    public var tokenizeMaxLineLength: Double
    public init(theme: DiffThemeSelection, useTokenTransformer: Bool, tokenizeMaxLineLength: Double) {
        self.theme = theme; self.useTokenTransformer = useTokenTransformer
        self.tokenizeMaxLineLength = tokenizeMaxLineLength
    }
}

/// Highlighting and inline-diff inputs from upstream RenderDiffOptions.
public struct RenderDiffOptions: Sendable {
    public var theme: DiffThemeSelection
    public var useTokenTransformer: Bool
    public var tokenizeMaxLineLength: Double
    public var lineDiffType: LineDiffType
    public var maxLineDiffLength: Double
    public init(theme: DiffThemeSelection, useTokenTransformer: Bool, tokenizeMaxLineLength: Double,
                lineDiffType: LineDiffType, maxLineDiffLength: Double) {
        self.theme = theme; self.useTokenTransformer = useTokenTransformer
        self.tokenizeMaxLineLength = tokenizeMaxLineLength
        self.lineDiffType = lineDiffType; self.maxLineDiffLength = maxLineDiffLength
    }
}

public func areFileRenderOptionsEqual(_ lhs: RenderFileOptions, _ rhs: RenderFileOptions) -> Bool {
    areThemesEqual(lhs.theme, rhs.theme) && lhs.useTokenTransformer == rhs.useTokenTransformer &&
        lhs.tokenizeMaxLineLength == rhs.tokenizeMaxLineLength
}

public func areDiffRenderOptionsEqual(_ lhs: RenderDiffOptions, _ rhs: RenderDiffOptions) -> Bool {
    areThemesEqual(lhs.theme, rhs.theme) && lhs.useTokenTransformer == rhs.useTokenTransformer &&
        lhs.tokenizeMaxLineLength == rhs.tokenizeMaxLineLength && lhs.lineDiffType == rhs.lineDiffType &&
        lhs.maxLineDiffLength == rhs.maxLineDiffLength
}

#endif
