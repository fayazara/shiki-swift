# Focused equality helper contracts

Compared with the named functions in the supplied `src/utils` sources. Native
Swift types rule out missing required fields and invalid side/enum values; this
is not support for arbitrary malformed JavaScript objects.

| Public source helper | Native implementation and checked fields | Evidence |
| --- | --- | --- |
| areDiffLineAnnotationsEqual | FileAnnotations.swift: line number, side, metadata; excludes native display text and ID. | AnnotationEqualityTests |
| areLineAnnotationsEqual | FileAnnotations.swift and AnnotationShape.swift: line number and metadata, for both native annotation forms. Primitive metadata has strict type/number/UTF-16 semantics; reference metadata retains identity. | AnnotationEqualityTests, AnnotationShapeTests |
| areHunkDataEqual | HunkData.swift: exact UTF-16 slot name, index, lines, known-count flag, column type and optional expansion flags. | HunkDataTests.everyUpstreamFieldParticipates |
| areRenderRangesEqual | VirtualWindow.swift: optional equality includes starting line, count and both buffers. Native coordinates are Int. | VirtualWindowTests.optionalEqualityIncludesEveryCoordinate |
| areSelectionsEqual | Selection.swift: both endpoints, side and explicit optional endSide; backwards ranges remain backwards. | SelectionTests.preservesExplicitEndSideAndDirection |
| areVirtualWindowSpecsEqual | VirtualWindow.swift: optional top/bottom equality using Double, including ordinary NaN inequality. | VirtualWindowTests.optionalEqualityIncludesEveryCoordinate |
| areThemesEqual | ThemeEquality.swift: distinguishes absent, single and adaptive forms; compares exact UTF-16 theme names. | ThemeEqualityTests |
| areFileRenderOptionsEqual | RenderOptionEquality.swift: theme, transformer flag and Double per-line limit. | RenderOptionEqualityTests |
| areDiffRenderOptionsEqual | Same, plus line diff type and Double inline length limit. | RenderOptionEqualityTests |

These highlighting-option records retain source comparison fields separately
from DiffRenderOptions, which controls actual native rendering. The transformer
flag is not an HTML output implementation. Generic object/option comparison,
pre-node properties and worker statistics remain separate contracts.
