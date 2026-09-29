# Shared data contracts

Reviewed against `src/types.ts` in the supplied source and the native declarations
listed in native-api-dispositions.json. The table covers these named records and
enums only; inherited rendering options and unlisted DOM/renderer/worker types
remain separate audit work.

| Upstream exports | Native representation |
| --- | --- |
| FileContents | FileContents: name, contents, lang, header and cacheKey; optional properties use nil |
| ChangeTypes | ChangeType preserves change/rename-pure/rename-changed/new/deleted raw values |
| ParsedPatch | ParsedPatch preserves optional patchMetadata and ordered files |
| ContextContent, ChangeContent | HunkContent uses a context/change discriminator and retains source counts and indices; Codable emits only fields for that case |
| Hunk, FileDiffMetadata | Same-named value records preserve the source fields, line counts, hunk offsets, EOF flags, partial state, object IDs, modes, cache key and optional editSessionDirty |
| DiffFileInput, MaybeDiffFileInput | DiffHighlighter.prepare(oldFile:newFile:) accepts optional sides and rejects both nil; prepare(metadata) is the separate already-parsed input path |
| FileDiffLoadedChangedFiles, FileDiffLoadedPureRenamedFile, FileDiffLoadedFiles | LoadedDiffFiles has an optional oldFile and required newFile; hydratePartialDiff validates compatibility with changed/pure-rename metadata |
| FileDiffContentsLoader | DiffContentsLoader is a Sendable async throwing closure returning LoadedDiffFiles |
| AnnotationSide, SelectionSide | DiffSide preserves deletions/additions |
| CodeColumnType | CodeColumnType preserves unified/additions/deletions |
| DiffIndicators | DiffIndicators preserves classic/bars/none |
| LineDiffTypes | LineDiffType preserves word-alt/word/char/none; wordAlt is the Swift case spelling |
| HunkSeparators | HunkSeparators preserves simple/metadata/line-info/line-info-basic/custom; custom content uses a separate renderer |
| ExpansionDirections | ExpansionDirection has up/down/both |
| HunkExpansionRegion | HunkExpansionRegion retains fromStart/fromEnd |
| HunkData | HunkData retains slotName, hunkIndex, lines, lineCountKnown, column type and optional expandable flags |
| RenderRange | DiffRenderRange retains startingLine, totalLines, bufferBefore and bufferAfter |
| VirtualWindowSpecs, RenderWindow | VirtualWindowSpecs retains top/bottom logical coordinates |
| SelectedLineRange | LineSelection uses startLine/endLine for start/end, retaining side, direction and optional endSide |
| DiffAcceptRejectHunkType, DiffAcceptRejectHunkConfig | diffAcceptRejectHunk arguments use DiffResolution.additions for accept, deletions for reject, both for both, and optional changeIndex |
| MergeConflictResolution, ConflictResolverTypes | DiffResolution.deletions selects current, additions selects incoming, both selects both |
| MergeConflictRegion | MergeConflictRegion preserves conflict and marker indices/numbers, including optional base markers |
| MergeConflictMarkerRow, MergeConflictMarkerRowType | MergeConflictMarkerRow and its Kind retain marker-start/base/separator/end raw values and row metadata |
| ThemesType, ThemeTypes | DiffThemeNames and DiffThemeAppearance preserve light/dark names and system/light/dark appearance |
| DiffsThemeNames, SupportedLanguages | String names support bundled and custom resources; reserved text/ansi language behavior is enforced by the resolver |
| SmoothScrollSettings | SmoothScrollSettings preserves omega, positionEpsilon and velocityEpsilon; durations/velocity use the source millisecond convention |
| PostRenderPhase | PostRenderPhase preserves mount/update/unmount |

Swift records use value semantics and copy-on-write collections. They do not
reproduce arbitrary extra JavaScript object properties, undefined, prototype
mutation or object identity. Optional metadata has explicit nil representation.
Raw source strings and line terminators are preserved; the source-compatible
areFilesEqual/areThemesEqual/selection helpers provide their documented exact
comparisons rather than treating JavaScript reference equality as Swift value
equality. Line/column source units remain UTF-16 where the source uses them.

Patch, diff, conflict, resolution and hydration fixtures decode source-generated
JSON into these values and compare native results. CoreTests, HydrationTests,
ResolutionValidationTests, HunkDataTests, SelectionTests, ThemeEqualityTests and
ScrollSpringTests cover the related algorithms. This is structural/behavioral
contract evidence for those fixtures, not a claim that every exported type or
all malformed metadata has been exhaustively verified.
