# Base rendering option contracts

Source: `src/types.ts` BaseCodeOptions/BaseDiffOptions and the supplied
FileRenderer, DiffHunksRenderer, File and FileDiff implementations. This maps
these option records, not every renderer method or every derived option type.

| Source option | Native contract |
| --- | --- |
| theme | DiffRenderOptions.theme for a fixed theme; DiffThemeNames and prepareThemes for paired light/dark names. |
| themeType | NativeThemedDiffView.themeAppearance / DiffThemeAppearance; .system follows effective AppKit appearance. |
| disableLineNumbers, overflow, collapsed, disableFileHeader | Same behavior through DiffRenderOptions; overflow uses DiffOverflow.scroll/wrap. |
| stickyHeader | DiffRenderOptions.stickyHeader, false by default. Standalone headers use scroll insets; CodeView owns its separate stickyHeaders setting. |
| disableVirtualizationBuffers | Source suppresses before/after spacer DOM nodes in applyBuffers. Native scroll extents are document frames and row-height indices, with no spacer nodes to emit. This is not an overscan switch and is not exposed as a misleading native option. |
| preferredHighlighter | Native Shiki engine supplied by the port, owned by DiffHighlighter. Browser JavaScript/WASM engine selection has no native selector. |
| useCSSClasses | CoreText consumes concrete token attributes; no class-based HTML serialization or class toggle. |
| useTokenTransformer | Native token spans, wrapped hit-test geometry and source copying preserve interaction boundaries directly; see EXPORT-AUDIT.md. No HTML-wrapper toggle. |
| tokenizeMaxLineLength, tokenizeMaxLength | Same options on DiffRenderOptions; per-line tokenization limit and whole-document line-count cutoff. |
| unsafeCSS | No arbitrary CSS evaluator. Typed DiffRenderOptions, native themes and NSView renderers provide styling/custom content. This intentionally does not claim CSS serialization or cascade compatibility. |
| diffStyle, diffIndicators, disableBackground, hunkSeparators | Same options in DiffRenderOptions. Custom separators use DiffSeparatorRenderer. |
| expandUnchanged, collapsedContextThreshold, expansionLineCount | Same options; threshold default is 1 in the source constant, despite the stale source comment saying 2. |
| lineDiffType, maxLineDiffLength | Same options, including word-alt, word, char and none, with source fixtures in InlineParityTests. |
| loadDiffFiles | NativeDiffView.loadDiffFiles / FileDiffView loader callback. Async hydration installs prepared full contents; failure callback and stale-request guards are explicit. |
| parseDiffOptions | DiffOptions passed separately to parseDiffFromFile or DiffHighlighter.prepare(oldFile:newFile:diffOptions:options:). Prepared patch inputs are not reparsed. |

Evidence: CoreTests, InlineParityTests, HydrationTests, LoadingAndThemeTests,
WrapTests, HeaderTests, StandaloneHeaderTests and ViewportTests. The 474-test
Release run and live header checks are recorded in DEMO-VALIDATION.md. This
mapping documents native API boundaries; it does not assert universal pixel,
input-method or physical scrolling parity.
