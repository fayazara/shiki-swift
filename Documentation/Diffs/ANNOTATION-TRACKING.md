# Editor annotation tracking contract

Source audit: local upstream `src/editor/lineAnnotations.ts`, `src/utils/editSessionAnnotations.ts`, and `src/components/FileDiff.ts`.

The native editor now maps annotation positions after mutations and retains before/after snapshots for undo and redo. Completion exposes current and original annotations. Full tracking parity remains unproven, particularly complete UI lifecycle and composition combinations.

## Required mapping semantics

- Deletion-side annotations and file-level annotations (line number zero or below) stay fixed.
- An insertion at column zero moves an annotation on that line past the inserted line breaks. An insertion inside the same line leaves it attached to that line.
- An annotation following a replacement shifts by that replacement's line delta.
- When deletion spans lines, an annotation on a fully deleted line is removed. A partially retained first line survives when the replacement starts after column zero. The end line survives unless deletion reaches the document end.
- Mapping applies each constituent change in order. A batch with net zero line delta can still move or delete annotations.
- A moved annotation retains its source identity. Native `LineAnnotation.id` can provide this identity without the upstream object-identity registry.

## Session ownership

Upstream editing sessions distinguish the external annotations, the most recently provided annotations, and the current mapped annotations. Repassing an already held array is ignored; a new supplied array replaces session annotations using current edited line numbers. Completion must expose the current annotations with the resulting diff. The Swift adapter compares values against external, provided, and current annotations to recognize refreshes. `DiffEditor.setAnnotations` explicitly replaces comments even when values repeat; the native regression verifies refresh stability and replacement. This is a documented adaptation of JavaScript array identity.

## Implementation prerequisite

`TextDocumentChange.changedLineChanges` now preserves per-edit line spans, character positions, and document-end flags, including undo and redo. `applyDocumentChangeToLineAnnotations` implements the source mapper for these records. Four focused tests pass for net-zero batches, old-side/file-level preservation, identity and payload preservation, insertion columns, CRLF EOF metadata, and metadata history. The mapper is integrated into typing, command edits, and indentation. A generated oracle compares 6,910 single-edit and two-edit cases against the actual local upstream implementation, covering LF/CRLF, Unicode, EOF, and equal-offset batches. All cases pass. It exposed and led to fixes for same-offset range ordering and insertions inside surrogate pairs.

Upstream `Editor.ts` records before/after annotation snapshots using `setLastUndoLineAnnotations` and prefers those snapshots during history replay. The native editor now retains equivalent before/after snapshots, including composition cancellation state. Its lifecycle regression verifies removal and undo/redo restoration of a comment. Broader IME and command-batch history tests remain required.

Validation must cover beginning/middle/end insertions, partial versus complete line deletion, deletion to EOF, CRLF, net-zero multi-edit batches, fixed old-side/file annotations, undo/redo, IME composition, session annotation replacement, completion payloads, and view identity after movement. Compare results against the upstream mapper using generated fixtures.

## Batch text validation

The 6,910-case oracle now also records the actual upstream result text. Native assertions compare exact UTF-16 output, restoration of the original text on undo, and output on redo. All 6,910 cases now pass these additional assertions. They exposed a line-ending mismatch: the low-level text model must preserve supplied line endings, while attached editor command inputs normalize to the document EOL. That boundary is corrected. The full Release suite passed 170 tests across 47 suites after the fix.

## Metadata and renderer lifecycle

`LineAnnotationMetadata` preserves identity for arbitrary Sendable application payloads. The explicit primitive initializer instead implements JavaScript strict equality for null, booleans, numbers, and exact UTF-16 strings; absent metadata differs from null. The upstream equality helpers compare line/metadata and, for diff annotations, side. Native IDs and display text remain additional fields in the full native annotation equality used for renderer invalidation.

Release regressions verify that a reused metadata wrapper retains the mounted custom view, replacing metadata refreshes the view even with unchanged annotation ID/text, and undo plus accepted completion preserve the original metadata object. The full integration run passed 187 tests in 50 suites. These checks supplement rather than replace the outstanding broader lifecycle and composition requirements above.
