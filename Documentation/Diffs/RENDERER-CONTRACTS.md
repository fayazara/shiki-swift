# Renderer contract review

Source: `src/renderers/FileRenderer.ts` and `DiffHunksRenderer.ts` from the
supplied checkout. Native rendering is split between DiffHighlighter,
DiffRenderPlan and NativeDiffView/CoreText. This is a partial renderer map;
the extension hooks listed below remain concrete work.

| Source methods / state | Native surface |
| --- | --- |
| constructor, options, setOptions, mergeOptions, getEffectiveCodeOptions | DiffHighlighter and native view construction; DiffRenderOptions is an explicit value. Mutate a copy and setOptions to merge selected fields. BASE-OPTIONS-CONTRACTS.md maps individual options and native engine/HTML differences. |
| fileCache / diffCache, getFileForNextRender / getDiffForNextRender | NativeFileView.file and NativeDiffView.displayedDocument represent installed presentation. Actor preparation returns HighlightedDiff; editors and owned conflict/stream views separately track pending source and installed output. |
| setLineAnnotations | Native view setters and identity-bearing annotation renderer. File and diff annotation forms preserve side and metadata. |
| expandHunk, getExpandedHunk, getExpandedHunksMap, setExpandedHunksMap | Direct NativeDiffView methods. Map reads return Swift value snapshots rather than a live mutable Map. A replacement updates layout, review offsets and pending editor rendering. Empty maps collapse explicit expansions. New source identities reset view-owned expansions. |
| beginEditSession, endEditSession, editorRenderReady, applyDocumentChange | DiffEditor attachment, suspension/resumption, completion and waitForRendering; DiffEditSession owns frozen hunk updates. Native token geometry does not need an HTML-transformer readiness gate. |
| getOrCreateLineCache, getLineCount | FileContents source split into prepared FileDiffMetadata line arrays; copying arrays shares storage through Swift copy-on-write. |
| renderFile, renderDiff, asyncRender | DiffHighlighter.prepare / preparePreview and NativeFileView/NativeDiffView.render. Preparation errors throw; async owners guard stale results. Main-thread presentation does not secretly block on highlighting. |
| initializeHighlighter, refreshHighlightedResult, onHighlightSuccess, onHighlightError | DiffHighlighter.preload/prepare; host task completion or error callbacks. Worker-message callbacks are not public native entry points. |
| hydrate, updateRenderCache, clearRenderCache | Install a prepared HighlightedDiff and rerender or clear native preparation caches. No adoption or direct mutation of browser AST caches. |
| renderCodeAST, renderFullAST, renderFullHTML, renderPartialHTML | Native rows/CoreText and NSView content. No HTML or HAST output compatibility. |
| recycle, cleanUp | Native view cleanup with editor-state suspension where requested; NativeCodeView retains per-item state across new mounted views. The highlighter's cache/resource lifecycle is separate. |
| annotationSlotName and onRenderUpdate constructor callbacks | Stable annotation IDs/native view renderers; onPostRender provides native presentation phases. |

## Missing renderer extension surface

The source DiffHunksRenderer has protected `getUnifiedLineDecoration`,
`getSplitLineDecoration`, `getUnifiedInjectedRowsForLine` and
`getSplitInjectedRowsForLine` hooks, described by exported decoration/placement
records. Native conflict markers, annotation rows and custom gutter views cover
the built-in use cases, but hosts cannot yet supply arbitrary before/after rows
or per-source-row gutter/content decoration through an equivalent typed hook.
Existing built-in output is not proof that this extension surface is implemented.

Acceptance requires native callbacks with source/hunk/side coordinates,
variable-height before/after content, correct split alignment, viewport-bounded
mounting, stale/reentrant callback guards and matching hit testing/scroll extent.
HTML properties should map to typed native appearance/view inputs rather than
pretending to execute CSS. Keep this gap open until implemented and demonstrated.

ExpansionStateTests verify snapshot isolation, explicit clearing, extreme count
handling, source replacement, an edit in flight, and review unmount/remount in
scroll and wrap modes. Existing header, annotation, viewport and editing suites
cover the built-in paths; they do not validate the missing extension hooks.
