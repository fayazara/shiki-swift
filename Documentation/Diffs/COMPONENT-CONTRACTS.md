# Native component contract map

Reference: the supplied @pierre/diffs 1.4.2 checkout. This maps public component
operations to native entry points. A native adaptation does not promise browser
DOM, HTML, CSS or React output. Editor gaps are listed explicitly below.

## File and diff presentation

| Upstream operation | Native entry point / adaptation |
| --- | --- |
| File / FileDiff construction and setup | NativeFileView / NativeDiffView; their NSView is the container |
| render with file or diff | DiffHighlighter.prepare followed by render(HighlightedDiff); explicit actor preparation separates expensive work from AppKit presentation |
| setOptions, setLineAnnotations, rerender | Same-named methods; native prepared views preserve source identity and require a newly prepared document for new syntax themes |
| setThemeType, onThemeChange | NativeThemedDiffView / ThemedFileDiffView own adaptive light/dark preparation; prepared views accept an explicitly selected theme |
| hydrate, updateRenderCache, primeHighlightCache | Prepare and retain HighlightedDiff, then render it; DiffHighlighter owns bounded token caches. There is no prerendered HTML or DOM-adoption operation |
| setSelectedLines / getHoveredLine | selectLines / getHoveredLine; the file wrapper supplies side-less events |
| getLineIndex | FileDiffMetadata selectionLineIndex and lineIndexes utilities |
| expandHunk / handleExpandHunk | NativeDiffView.expandHunk with native direction and count |
| getExpandedHunk / getExpandedHunksMap / setExpandedHunksMap | NativeDiffView value snapshots and atomic full-map replacement; retains editor/review ownership |
| isLineRenderable / getNearestRenderableLine / revealLine | Direct NativeDiffView and NativeUnresolvedFileView methods |
| getCodeScrollLeft / setCodeScrollLeft | Public scrollView.contentView bounds and scroll(to:); both columns share one native scroller |
| setEditorActiveLine | NativeDiffView, NativeFileView and NativeUnresolvedFileView expose setEditorActiveLine independently of selected ranges; side and lineNumberOnly are preserved |
| flushManagers | AppKit layoutSubtreeIfNeeded / displayIfNeeded; asynchronous editor work is awaited with waitForRendering |
| cleanUp / recycle | NativeDiffView.cleanUp(recycle:), NativeFileView.cleanUp; editor suspension is distinct from teardown |
| applyDocumentChange / finalizeEditSessionHunks | DiffEditor input methods, DiffEditSession and complete; callers do not mutate a renderer-owned DOM cache |
| emitEditChange / editor attachment methods | DiffEditor.onChange and beginEditing/resumeEditing; review ownership is handled by NativeCodeView |
| annotation slot names | Stable native annotation IDs and identity-bearing renderers replace HTML slot strings |
| renderPlaceholder / virtualizedSetup | NativeCodeView estimates height and mounts only the viewport; standalone views render visible rows directly |
| LoadedCustomComponent / string instance ID / type tag | Swift concrete type and object identity; no custom-element registration side effect |

### File/FileDiff exported props and callback types

`FileRenderProps` maps to NativeFileView.render(document:file:options:annotations:).
`FileDiffRenderBaseProps` and `FileDiffRenderProps` map to
NativeDiffView.render with a HighlightedDiff prepared from metadata or old/new
FileContents. Swift does not expose the union of DOM container props:

- `fileContainer` and `containerWrapper` are the host NSView and its parent.
- `renderRange` comes from the clip view's visible bounds; native callers scroll
  or resize the viewport rather than requesting an inconsistent manual DOM slice.
- `forceRender` is rerender/display invalidation; `deferManagers` maps to AppKit's
  layout/display transaction. There is no manager-flush Boolean on render.
- `preventEmit` is not a native render flag. Hosts own their typed callbacks and
  can suppress forwarding; `onPostRender` reports native mount/update/unmount.
- `FileHydrateProps` / `FileDiffHydrationProps` install a prepared native value.
  They do not accept HTML, adopt a DOM tree, or insert CSS/style nodes.

`FileOptions` / `FileDiffOptions` are split between DiffRenderOptions, native
interaction handlers and identity-bearing header/annotation/gutter/separator
renderers. Their inherited BaseCodeOptions/BaseDiffOptions types are tracked
separately in the named audit. The `disableErrorHandling` switch is replaced by
throwing preparation plus explicit async error callbacks; there is no implicit
DOM error element. Custom separators use DiffSeparatorRenderer, including nil
content and guarded expansion, instead of an HTMLElement/DocumentFragment.

`FileEditChangeHandler` / `FileDiffEditChangeHandler` use DiffEditor.onChange.
`FileEditCompleteHandler` / `FileDiffEditCompleteHandler` use onEditComplete and
DiffEditCompletion, with file/diff context preserved by the editor's type and
completion fields. NativeFileView exposes its shared editor host through
`diffView.beginEditing`; native file access/selection/scroll geometry also routes
through that host. Native completion modes are explicit and async when accepted
content needs highlighting. Managed reviews default to reject; direct callers
choose an install/discard mode. This differs from the source component's
synchronous accept/reject callback and frozen event wrapper.

`FileDiffType` is represented by the concrete NativeDiffView or
NativeUnresolvedFileView and EditorType; no custom-element type-tag string is
required. Browser line caches (`getOrCreateLineCache`, `updateRenderCache`) are
owned native CoreText/token caches. Hosts prepare reusable HighlightedDiff
values instead of inserting mutable HAST lines. `__` editor attachment/session
methods are native editor ownership operations, not an additional public DOM
extension surface.

Evidence: ComponentControlTests, HeaderTests, AttachedEditorTests,
ReviewLifecycleCallbackTests and HydrationTests exercise native ownership,
selection preservation, teardown, prepared-state installation and partial-source
hydration. This mapping documents platform differences; it does not claim
identical browser return types or complete visual/input verification.

Conflict ownership and inherited differences are detailed in
[UNRESOLVED-FILE-API.md](UNRESOLVED-FILE-API.md).

## Multi-file review

| Upstream operation | Native entry point / adaptation |
| --- | --- |
| setItems, getItem, addItem(s), updateItem, updateItemId, removeItem | NativeCodeView named methods (updateItemID uses Swift capitalization); exact UTF-16 IDs |
| item version | HighlightedDiff.id revision plus stable CodeViewItem.id |
| item collapsed / edit | CodeViewItem.collapsed / edit; collapse preserves an active editor |
| createEditor / getEditStateKey | NativeCodeView factory receives host, item and optional key; forwards key to beginEditing |
| onItemEditChange / onItemEditComplete | Native callbacks include owning item and editor; accepted prepared items publish through onItemsChange after async highlighting |
| retained edit sessions | EditStateManager stores dormant drafts/history, with separate file/diff namespaces and exclusive active keys |
| reset | Clears content and sessions while retaining host configuration and scroll subscriptions |
| scrollTo | scrollTo(top:), scrollToItem, scrollToLine, scrollToRange with alignment, offset and instant/smooth behavior |
| selected line state | getSelectedLines, setSelectedLines, clearSelectedLines, callbacks and controller-backed SwiftUI access |
| getWindowSpecs / subscribeToScroll | Direct native methods; cancellation closure removes each subscription |
| getRenderedItems / getTopForItem | Direct native methods; querying does not mount missing files |
| getContainerElement / getHeaderElement / getFooterElement | NSView host, reviewHeader and reviewFooter |
| slot coordinator and snapshots | Native renderers retain and measure header, annotation, gutter and separator NSViews; no React portal coordinator |
| worker and CSS layout config | DiffHighlighter actor, CodeViewLayout, overscrollSize, stickyHeaders and DiffRenderOptions |
| setOptions / getLocalTopForInstance / getHeight / getScrollHeight / cleanUp | Direct native methods. Local instance offsets require a mounted instance; cleanUp removes subscriptions/chrome but leaves NSView parent ownership intact |

## Streams and rendering helpers

ShikiStreamTokenizer, CodeToTokenTransformStream and FileStream provide native
streaming tokens and prepared snapshots. FileView renders those snapshots.
AsyncSequence/actor cancellation replaces browser stream controllers. NativeFileStreamView and FileStreamView now own the source and expose
pre/post-render and start/write/close/abort callbacks. Replacement cancels the
previous source; failed streams retain their last snapshot. Starting line labels
are configurable; stream configuration changes require a new SwiftUI streamID.
ThemedStreamTokenizerConfiguration prepares both themes. NativeFileStreamView.themeAppearance and FileStreamView.themeAppearance switch cached snapshots without restarting the source; system mode observes AppKit appearance. Token callbacks use the light tokenizer consistently, rather than browser CSS-variable token variants.

DiffRenderPlan/CoreText and DiffHighlighter replace FileRenderer and
DiffHunksRenderer's node-producing and worker-facing methods. HAST/HTML output,
CSS insertion, DOM managers and SSR adoption are browser contracts, not native
return types. Public precomputed-state installation is render(HighlightedDiff).
Detailed renderer operations and the remaining custom row/decoration hook gap are in RENDERER-CONTRACTS.md. Other helper/export dispositions remain in the named audit.

## Remaining editor behavior

Attached native editing now includes declarative ownership, keyed history,
external replacement, diagnostics, external selections, bracket matching, automatic surrounding, focus/blur callbacks and source-line focus options (targeted native tests pass). This does not close the upstream Editor contract:
multiple local selections, view-state controls, custom keymaps and bounded
coalescing history are now implemented (EDITOR-INPUT.md). Predictive providers,
cancellation and ghost presentation are implemented (EDIT-PREDICTION.md).
Custom selection/caret widgets and clipboard-provider callbacks are implemented
with stale-callback guards (EDITOR-HOST-CUSTOMIZATION.md). Initial
state import restores value snapshots through AppKit and SwiftUI, with optional
document/history, selection, viewport, annotation, baseline and fold fields.
AppKit provides focus, clipboard, undo and IME transport; physical candidate-window
and keyboard verification is still required.
