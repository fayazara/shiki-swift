# ShikiDiffs

A native macOS port of Pierre's `@pierre/diffs`, using **Swift, AppKit, CoreText,
and ShikiSwift**. No web view,
JavaScript runtime, or hosted service is used by the library.

The port is being checked against the supplied **@pierre/diffs 1.4.2** source.
See [the parity record](PARITY.md) for implemented behavior,
verification, and remaining work. Full 1:1 parity is not yet claimed.

## Where it lives

ShikiDiffs is the `ShikiDiffs` product of the ShikiSwift package (it was
developed separately as `swift-diffs` and moved in; history before the move
lives in that repository). Add it next to the other products:

```swift
.product(name: "ShikiDiffs", package: "shiki-swift")
```

Its views are AppKit and require macOS; the rest of the package still supports
macOS 13+, iOS, tvOS, watchOS and visionOS. On macOS 13, review smooth
scrolling is driven by a timer instead of a display link. The ShikiSwift demo
app (`shiki-swift.xcodeproj`) shows the diff views under **Diffs**.

## Use the library

```swift
import AppKit
import ShikiDiffs

let highlighter = DiffHighlighter()
let prepared = try await highlighter.prepare(
    oldFile: FileContents(name: "Example.swift", contents: "let value = 1\n"),
    newFile: FileContents(name: "Example.swift", contents: "let value = 2\n")
)

// Main actor:
let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
view.render(prepared)
```

For SwiftUI, use `FileDiffView(document: prepared)`. `FileView` displays a
highlighted single file (prepare with identical old/new contents), `CodeView`
displays a multi-file review, and `EditorView` supplies native text editing.
`NativeCodeView` and `NativeEditor` are their AppKit entry points.

The standalone `EditorView` accepts `highlighter:` to reuse registered resources.
AppKit callers can use `NativeEditor(frame:highlighter:)` and replace its
`highlighter` property later. Switching highlighters preserves the editor's
text, selection and undo history; canceled older loads cannot replace the new
theme or report stale errors. Passing nil to the SwiftUI wrapper restores its
retained default highlighter.

`DiffEditSession` provides the retained diff-region model for an editing host.
It keeps reverted regions visible during the session, remaps expanded context
when regions merge, and restores ordinary hunks on completion. It requires full
file contents. Use it independently on an editing actor, or attach native input
directly to `NativeDiffView`:

```swift
// Main actor; retain this editor for the editing session.
let editor = try view.beginEditing(highlighter: highlighter)
editor.onEditComplete = { result in
    // Save result.newFile / result.fileDiff in your host application.
    return true // Accept the completed diff.
}
try await editor.complete(.install) // Or .discard to restore the external diff.
```

`EditableFileDiffView(document:isEditing:onEditComplete:)` is the SwiftUI host.
The addition column accepts native key events, composition text, selection,
copy/paste and undo/redo. A missing completion handler restores the external
diff. The **Editable diff** demo exposes apply/discard controls. Input updates
the piece table immediately; background work rebuilds regions and syntax colors.

To retain a draft after completing or closing its editor, supply `editStateKey:`
to `beginEditing` or `EditableFileDiffView`. Reusing that key restores text,
undo/redo, annotations, selection and the saved viewport. File and diff keys
have separate namespaces. `EditStateManager.shared` keeps at most 100 dormant
sessions per namespace; use `setCapacity`, `clear` or `clearAll` to manage them.
Active keys cannot be claimed twice or cleared. A custom manager can isolate
retention to a window or workspace. Retention is memory-only.

```swift
let review = NativeCodeView(frame: .zero)
review.getEditStateKey = { "workspace-review-" + $0.id }
review.createEditor = { host, item, key in
    try host.beginEditing(highlighter: highlighter, editStateKey: key)
}
review.onItemEditComplete = { completion, item, editor in .accept }
try review.setItems([CodeViewItem(id: "example", document: prepared, edit: true)])
```

`CodeViewItem.edit` activates the factory only when the item is expanded and
mounted. Collapse and virtualization suspend an active session. Setting `edit`
to false completes it; completion defaults to rejection. `onItemEditChange`
reports local and external text changes with the owning item. Accepted prepared
results are published through `onItemsChange`. Removed items are never
reinserted by completion. `waitForPendingEdits()` awaits asynchronous teardown.

Attached editors accept `setMarkers([Marker])` for diagnostics and
`setCarets([EditorCaret])` for externally owned collaborator selections. Marker
positions are zero-based UTF-16 ranges. Diagnostics use theme colors and wavy
underlines; hovering opens a native popover, with `renderMarkerPopover` for
custom AppKit content. External carets follow text edits and undo/redo without
changing the local selection. `EditableFileDiffView` forwards `markers:`,
`carets:` and `renderMarkerPopover:`. The Editable diff demo has both toggles.

`await editor.waitForRendering()` waits for syntax and wrapped layout. For a
read-only view, `await view.waitForLayout()` waits only for the current wrapping
work; neither method measures compositor frame delivery.

Attached editors support multiple carets through Option-click/drag, Command-D,
and `setSelections(_:)`. Typing, IME input, clipboard, line commands and undo
operate across selections. Continuous typing/deletion coalesces into one undo
step; the native editor defaults to 100 undo groups, configurable with
`beginEditing(historyMaxEntries:)`. `getViewState()` /
`setViewState(_:)` restore selections and scroll coordinates. Custom keymaps use
upstream shortcut strings:

```swift
editor.keymap = .init([.init(platform: .mac, bindings: ["cmd+d": .copyLineDown])])
editor.breakUndoCoalescing()
```

See [editor input contracts](EDITOR-INPUT.md) for history snapshots,
clipboard ordering, native adaptations and remaining editor work.

Replacing an active editor's source updates its draft and diff baseline.
Same-file text replacements are undoable; changing the filename or language
resets history. Re-rendering an unchanged external source preserves local edits.
Offscreen review editors receive replacements without mounting their view.

```swift
var session = try DiffEditSession(diff: prepared.diff)
// Source rows are zero-based and include their line terminators.
try session.updateLines([0: "let value = 3\n"])
// For structural edits, pass the current editor rows (including its empty caret row).
try session.replaceAdditionLines(["let value = 3\n", "let other = 4\n", ""])
try session.finish()
let editedDiff = session.diff
```

`DiffOptions` controls generation: `context` (default 4, or `.max` for the full
file), `ignoreWhitespace`, and `stripTrailingCr`. Comparisons use JavaScript's
whitespace set; the returned source lines keep their original whitespace and
line endings. The demo exposes these comparison controls.

`headerOptions` also preserves the upstream intermediate-patch behavior.
Omitting file headers omits metadata names; omitting every available preamble
line causes upstream to consume the first hunk as its header bucket. Defaults
retain all headers. Asynchronous callers can use `DiffHighlighter.prepare`.

```swift
var options = DiffRenderOptions()
options.diffStyle = .unified
options.theme = "pierre-light"
options.expandUnchanged = true

let prepared = try await highlighter.prepare(
    oldFile: oldFile, newFile: newFile, options: options
)
let content = FileDiffView(
    document: prepared,
    options: options,
    annotations: [LineAnnotation(lineNumber: 5, text: "Review this change.")]
)
```

Pass the same highlighting options to preparation and presentation. Changes to
theme, inline diff mode, or tokenization limits require new preparation. Layout,
font, indicators, line numbers, and context expansion are presentation options.
Annotations use one-based source line numbers and retain their identity and side
in the render plan. Line zero places an annotation above the first file row;
new/deleted files omit annotations for their absent side. Split presentation
aligns the two sides' annotation stacks; unified presentation orders deletions
before additions. Default text annotations use fixed-height rows. Custom AppKit annotation views
use measured heights and are mounted only near the viewport, including in multi-file reviews.
Keep prepared documents stable during unrelated SwiftUI updates; they preserve
scroll and selection. `sourceID` identifies the document and `id` its prepared
revision. Streaming snapshots retain the source identity across revisions.

`NativeDiffView.headerRenderers`, `NativeThemedDiffView.headerRenderers`, and the
`headerRenderers:` argument on `FileDiffView`, `ThemedFileDiffView` and
`EditableFileDiffView` accept `DiffHeaderRenderers`. The prefix and filename suffix flank the
filename; metadata follows the built-in change counts. Each callback receives
the current `FileDiffMetadata` and returns an AppKit view or nil. Supplying
`renderCustomHeader` replaces the whole header and suppresses the other callbacks,
even if it returns nil. Custom content uses its intrinsic/fitting size (or explicit
frame size); the viewport reserves that height. These are render callbacks, so
call `reloadHeader()` after changing captured state in a native host. Return
separate view instances for separate hosts. The demo's Header picker exercises
both customization modes. `NativeCodeView` and `CodeView` accept the same diff header renderers. They create
header views only while mounting viewport files, using estimated heights for
unvisited files and retaining measured heights as they scroll away. A Fenwick
index updates offsets and locates distant files in logarithmic time. Review headers
can scroll away or pin with `stickyHeaders`; constrained slot sizing remains on
the parity checklist.
Full custom header views receive the available width before intrinsic/fitting
height measurement; resizing can grow or shrink their reserved height. The demo's
custom review header wraps its text to exercise this behavior. Theme changes and attached
editor updates re-evaluate the hooks with current diff metadata.

`NativeFileView` and `FileView` use `FileHeaderRenderers`, whose callbacks receive
`FileContents`; their default headers omit diff counts. Pass `file:` alongside
the prepared document to retain its original header, language and cache key.
Without that argument, the view reconstructs a file from the prepared additions
once per document revision. This supports streaming snapshots without joining
all source lines on unrelated UI updates. File metadata and callbacks are installed
with the same revision, avoiding callbacks against the previous stream snapshot.
The demo supports both file header
customization modes.

For automatic appearance changes, prepare both variants on the actor:

```swift
let variants = try await highlighter.prepareThemes(oldFile: oldFile, newFile: newFile)
let adaptive = ThemedFileDiffView(document: variants)
```

`NativeThemedDiffView` is the AppKit counterpart. Its `themeAppearance` defaults
to `.system`, with `.light` and `.dark` overrides. Theme switches reuse prepared
tokens and preserve selection and scrolling. `DiffThemeNames` accepts custom
light/dark names registered on the highlighter. Preparing both variants costs
more up front than preparing one explicit theme.

### Reviews with stable item identities

Prepare documents on a retained highlighter, then update the native review on
the main actor. The shared instance can preload the grammars and themes needed
by several views:

```swift
let highlighter = try await DiffHighlighter.getSharedHighlighter(
    languages: ["swift"], themes: ["pierre-dark"]
)
// Main actor; `prepared` is a HighlightedDiff prepared as above.
let review = NativeCodeView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
try review.setItems([CodeViewItem(id: "example", document: prepared)])
try review.addItem(CodeViewItem(id: "second", document: anotherPreparedDiff))
review.scrollToFile(at: 1)
```

IDs belong to the host and must be unique by exact UTF-16 spelling. Duplicate
IDs throw before replacing the existing review. Keep IDs stable when updating or
reordering items; `updateItem`, `removeItem`, and `updateItemID(_:to:)` provide
individual mutations. `getItem` reads the current item, and `selectedItemLines`
reports selection with its item ID. `scrollToRange(_:inItem:align:offset:behavior:)`
accepts one-based source lines and start, center, end, or nearest alignment.
For single-file items, targets beyond EOF clamp to the last logical line (including
its wrapped rows), and an empty file targets the boundary below its header.
Hidden context in full-file diffs and parsed patches targets its separator without
expanding or fetching omitted text.
Fully collapsed files target the zero-height boundary below their header, without
expanding. As upstream does, collapsed single-file items accept any positive line
number; collapsed diff items require at least one hunk to resolve a target.
Pass `behavior: .smooth` for display-link-driven scrolling. Review headers scroll
away by default; set `stickyHeaders: true` on `CodeView` (or the native view's
property) to pin them. Line/range start and nearest alignment account for the
pinned header's measured height. Absolute offsets also account for sticky headers
when within the scrollable range; offsets outside that range clamp directly to
the document boundary. Unwrapped animations preserve velocity across viewport
resizing and review-header height changes. Wrapped animations pause while the
new row plan is prepared, then remap retained source-line targets and resume with
their velocity preserved. User scrolling cancels them even while reflow is pending.
Replacing the document still cancels stale range targets.

A `CodeViewItem` with `file:` uses single-file presentation and file-specific
header/interaction callbacks. Its document must already be prepared from that
file (identical old/new contents); supplying `file:` does not convert an arbitrary
diff into a highlighted file. Omit `file:` for an ordinary diff item.

Use the review's completion method to persist attached edits into its item model:

```swift
// Main actor:
let editor = try review.beginEditingItem("example", highlighter: highlighter)
// Native input now edits the additions side.
let result = try await review.completeEditingItem("example", mode: .install)
// Persist result.newFile in the application's storage as appropriate.
```

`.discard` restores the external revision. Managed review editors accept completion
by default; an explicit `editor.onEditComplete` handler can reject installation.
Scrolling an editor offscreen suspends its view while retaining text and undo
history. Completion can run while it is offscreen. Call `completeEditingItem`
instead of calling `editor.complete` directly so the review's retained item is
updated too. Removing the item abandons its editor.

For SwiftUI, keep the item array in host state and write accepted edits back:

```swift
@MainActor
struct ReviewScreen: View {
    @State var items: [CodeViewItem]
    @State private var controller = CodeViewController()

    var body: some View {
        CodeView(
            items: items,
            onItemError: { error in print(error) },
            controller: controller,
            onItemsChange: { items = $0 }
        )
    }
}
```

Import `SwiftUI` and `ShikiDiffs` in this host. `controller.view` is available
while the native view is attached; use it for navigation and managed editing.
`onItemsChange` reports accepted managed edit completion, not every imperative
item mutation. For host-driven additions, removals, and reordering, update the
SwiftUI state array. SwiftUI teardown disconnects the controller, cancels pending
layout work, and abandons managed editors. Keep annotation renderers and custom
header/footer views stable across unrelated state updates.

### Patches and hunk resolution

```swift
let commits = try parsePatchFiles(patchText, cacheKeyPrefix: "commit-id", throwOnError: true)
let diff = commits[0].files[0]
let prepared = try await highlighter.prepare(diff)
let accepted = try diffAcceptRejectHunk(diff, hunkIndex: 0, resolution: .additions)
```

Parsed patches retain only supplied lines. They cannot expand omitted context.
`hydratePartialDiff(_:oldFile:newFile:)` installs full contents. File generation
supports either side being absent; passing both as `nil` is an error.

`NativeDiffView.loadDiffFiles` and `FileDiffView(loadDiffFiles:)` accept an async
closure returning `LoadedDiffFiles`. Changed patches need both sides; pure
renames need a nil old side. Hydration and highlighting run on an actor. Late
responses for replaced documents are discarded, and repeated renders do not
duplicate a pending load. `onFilesLoaded`, `onFileLoadError`, `fileLoadError`, and
`retryLoadingFiles()` expose the lifecycle. Set `loadHighlighter` before rendering
when loading needs your custom theme/language registrations.

The demo exposes **Load full patch contents** on the patch example and
**Follow macOS appearance** on the ordinary diff examples.

`trimPatchContext(_:contextSize:)` reduces patch context while retaining range
coordinates. `expandHunk(_:lines:direction:)` expands from either end of an
unchanged region. `selectText(_:)` accepts source line / UTF-16 column endpoints;
gutter dragging continues to select complete lines.

`parseMergeConflictDiffFromFile` preserves current/base/incoming structural
anchors. `resolveConflict` resolves a selected conflict. `TextDocument` exposes
UTF-16 positions, atomic edit batches, incremental line indexing, search, and
inverse-edit undo/redo for application models.

Use `UnresolvedFileState` when resolving several conflicts: it updates the
unresolved source, remaining marker positions, and stable conflict identities
after each resolution, in any order.

### Streaming

```swift
let stream = FileStream(name: "Generated.swift", language: "swift")
let first = try await stream.append("let greeting = ")
let second = try await stream.append("\"Hello\"\n")
let final = await stream.close()
```

Display snapshots with `FileView`. Only the incomplete final line is
re-tokenized. `ShikiStreamTokenizer` exposes stable/unstable tokens and recalls
for lower-level consumers.

For registered custom themes or languages, resolve a shared configuration first:

```swift
let configuration = try await highlighter.streamConfiguration(
    language: "swift", theme: "my-custom-theme",
    options: .init(tokenizeMaxLineLength: 1_000)
)
let stream = FileStream(name: "Generated.swift", configuration: configuration)
```

The same configuration works with `ShikiStreamTokenizer(configuration:)` and
`CodeToTokenTransformStream(chunks, configuration:)`. It retains the resolved
engine and palette, so disposing the factory does not invalidate existing
streams. Lazy loaders are resolved before the configuration is returned.
`options` accepts native Shiki's `TokenizeWithThemeOptions`, including explanation
mode, color replacements, line-length/time limits and initial grammar context.
Those values apply to each chunk and are preserved by tokenizer clones.

Wrap an `AsyncSequence<String>` with
`CodeToTokenTransformStream(chunks, language: "swift", allowRecalls: true)`
to consume token events with `for try await`. Append `.token` values; on
`.recall(count)`, remove that many previously emitted tokens before applying
the following replacements. Recalls default to disabled, which emits only
completed lines and flushes the final incomplete line when the input ends.
The adapter reads the next chunk only after the current output is consumed;
errors and cancellation terminate iteration without flushing pending text.
Each iterator owns its tokenizer. The tokenizer retains stable token history,
so this limits queued output rather than total document memory.

In the demo, select **Streaming code** and use **Streaming mode** to switch
between file snapshots, token recalls, and tokenizer branches. The recall mode
can hide incomplete tokens; the branch mode shows two continuations of the
same comment. **Replay** starts either example again.

### Importing an editor snapshot

```swift
let snapshot = editor.getEditState()
let restored = try otherView.beginEditing(
    highlighter: highlighter,
    initialState: EditorInitialState(snapshot)
)
```

Snapshots preserve the draft, undo/redo, selections, annotations, diff baseline,
folds and viewport independently of the original editor. Use partial
`EditorInitialState(type:document:editor:)` values to supply only selected fields.
Known filename/language changes reset unkeyed state; a supplied `editStateKey`
preserves the saved identity. `EditableFileDiffView(initialState:onEditorAttached:)`
provides the same attachment-time import and access to the live editor.
The demo's **Editable diff → Session** menu saves and restores snapshots.
See [editor input contracts](EDITOR-INPUT.md) for history ownership
and document replay/access adaptations.

### Predictive edits

Attach a Sendable async `EditPredictProvider` through `editor.editPrediction`,
`beginEditing(editPrediction:)` or `EditableFileDiffView(editPrediction:)`.
Requests contain a bounded excerpt and edit history; responses use absolute
UTF-16 document positions. Include/exclude globs or ECMAScript regex patterns
filter paths. Cancellation and stale-result checks protect the live document.

The demo's **Editable diff → Predictions** menu provides local insertion,
multiline, replacement and deletion examples. **Tab** accepts a visible preview;
**Escape** dismisses. Enable **Subtle** and press **Option** to reveal or hide it.
Multiline ghosts reserve space in both columns and reuse the virtualized canvas.
See [predictive editing](EDIT-PREDICTION.md) for bounds, provider
ownership and validation details.

## Performance architecture

- Parsing, diff generation, and highlighting can run on `DiffHighlighter`, a
  dedicated actor that owns and reuses the synchronous Shiki engine.
- The read-only viewport uses direct row lookup and paints visible rows only.
  Large jumps never style or lay out intervening lines.
- Styled CoreText lines are bounded by **512 entries and 262,144 UTF-16 units**.
- Syntax token reuse has a configurable **128 MiB estimated budget** and 64-entry
  cap. `DiffHighlighter(cacheCapacityBytes:)`, `cacheStatistics`, and `clearCache()`
  expose that lifecycle.
- A separate **64 MiB estimated-content budget** retains compatible 64-line
  grammar chunks for the most recently prepared eligible file/configuration.
  Least-recently-used chunks are evicted when the pool fills, so new revisions
  can still enter the cache without growing it.
  This speeds up small source changes even when the unchanged side hits the
  whole-document cache. Configure `sharedChunkCacheCapacityBytes:` on
  `DiffHighlighter` (zero disables chunk caching); `sharedChunkReusedLines` and
  `sharedChunkCachedBytes` expose its accounting. `clearCache()` and resource
  invalidation clear both caches. These budgets are not process RSS limits.
- Both split columns share scrolling. Long lines scroll horizontally while
  both columns remain visible.
- `NativeCodeView` uses file prefix offsets and mounts only visible files.
- Wrapping is computed on a background actor; scrolling still uses direct
  physical-row lookup. Set `options.overflow = .wrap`.
- The standalone editor uses noncontiguous TextKit layout and viewport-only syntax attributes.
- The attached diff editor uses AppKit text input with the same virtualized
  CoreText canvas. A plain session render precedes debounced background syntax
  highlighting; superseded presentation jobs cannot replace the latest text.
- Attached editing supports wrapped-row and fold-skipping arrow movement, shift
  selection, word/line deletion, Tab/Shift-Tab, Command-bracket indentation and
  indentation-preserving newlines. `DiffEditor.tabSize` defaults to two spaces.
  Option-Up/Down moves lines; adding Shift copies them. Command-Return inserts
  an indented blank line. Command-/ toggles line comments; Shift-Option-A toggles
  block comments. `performLineCommand`, `toggleComment` and
  `languageCommentConfig` expose these behaviors to custom hosts. Copy/cut with
  a collapsed caret operates on its whole logical line. Cutting selected deleted
  text copies it without editing. Undo and redo retain selection direction.
- Editor syntax uses sparse grammar checkpoints and reuses an unchanged suffix
  only after complete TextMate state convergence. `prepareForEditing(_:session:)`
  and `releaseEditingSession(_:)` expose this path to other editing hosts. The
  separate cache holds at most eight side-documents / 64 MiB of estimated data;
  `editorHighlightStatistics` reports tokenized/reused lines and cache accounting.
- The document model uses a piece table and rescans edited line regions, with
  inverse edits for undo; it does not copy the original file per keystroke. Large
  edit batches traverse the piece list once and rebuild the line index once.
  Piece-offset indexes make reads across fragmented buffers logarithmic to locate.
- `DiffEditSession` indexes immutable old lines once. Balanced unmatched line
  replacements retain their hunk structure; structural changes use a canonical
  diff and persistent old-side regions. Run structural work on your editing actor.

Source strings, token arrays, and row models are retained in full. Virtualizing
layout does not make full-document tokenization free. Long ASCII lines in a
fixed-pitch font shape only a horizontal fragment. Complex-script lines and
proportional fonts still require full-line CoreText shaping.

In the initial local Release check of a 20,000-line Swift diff at 1100 × 650,
distant jumps including offscreen painting took approximately **4–6 ms**. Both
file versions took approximately **1.3–1.4 seconds** to prepare cold. These are
instrumented local timings, not display FPS or a guarantee for other documents.

The demo's **1.14 MB JSON** took about **3.7–3.9 s cold** for diffing and both
highlights, **6–8 ms with cached tokens**, and **8–10 ms** for destination-jump
painting. Preparation and visible rendering are separate costs.

## Verify

```sh
Scripts/diffs/test.sh --no-parallel
```

The complete AppKit suite is run sequentially: concurrent full-suite runs have
hit five-second wrapping preparation deadlines. This flag preserves those
deadlines and the explicit concurrency exercised within individual tests.
The load-related failures remain recorded in Documentation/DEMO-VALIDATION.md.

The suite includes source-generated patch, file-pair, hunk-resolution, and merge
conflict fixtures; an independent exhaustive shortest-edit check; randomized
piece-table/line-index checks; and hidden-window AppKit scrolling/editing checks.
The viewport check writes a render to `/tmp/shiki-diffs-viewport.png` and prints
scroll/paint timings. It measures offscreen painting, not physical display frames.

See `Scripts/diffs/generate-*-oracle.ts` for reference fixture generation. Those tools
use Bun and the provided upstream tree. Fixtures are stored LZMA-compressed; run
`swift Scripts/diffs/compress-fixtures.swift` after regenerating. File-pair generation additionally uses
the pinned jsdiff 9.0.0 package in `/tmp/shiki-diffs-jsdiff/package`.

Search uses `TextDocument.search(EditorSearchParams(...))` and
`buildSearchReplacementText`. It follows upstream's line-by-line matching,
whole-word separator set and 100,000 nonempty-match cap. The standalone native
ECMAScript regex engine preserves JavaScript regex rules; invalid patterns and
newline-spanning queries return no results. Execution limits throw an error,
and searches cooperate with task cancellation between matching operations.
Run large searches on a background task. `try await editor.replaceAll(params)`
prepares replacements off the main actor and commits one undoable batch. It
rejects stale results if the document changes while preparation is running.
Open the native find bar with Command-F, or find-and-replace with
Option-Command-F. Command-G and Shift-Command-G navigate matches. Custom hosts
can call `editor.openSearch(replacing:)`; its returned `DiffEditorSearch` owns
query options, asynchronous results and replacement actions. Hidden matches are
revealed when navigated to, and visible matches are highlighted on the canvas. `Scripts/diffs/test-regexp-bridge.sh` checks the native bridge with
AddressSanitizer and UndefinedBehaviorSanitizer.

## License

ShikiDiffs adapts @pierre/diffs (Apache-2.0, `LICENSES/pierre-diffs-Apache-2.0.txt`).
Notices for Pierre, jsdiff, QuickJS, the Pierre themes, and Shiki are in the
repository's [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).

### Line click callbacks

Native diff, themed, editable and multi-file views expose `interactionHandlers`
using `DiffInteractionHandlers`; their SwiftUI adapters accept the same argument. `onLineNumberClick` takes precedence for gutter
clicks; without it, `onLineClick` receives those clicks too. The native payload
includes the one-based line number, side, line type, original `NSEvent`, canvas
view, `fileDiff` metadata, and fragment rectangles in that view's coordinates. Drag selections and
annotation/separator rows do not dispatch code-line clicks. The demo reports these events in its status bar. `NativeFileView` and `FileView`
use `FileInteractionHandlers`, with `FileLineClickEvent.file` preserving original
file metadata. Switching to another file during a press cancels its pending click.
`onLineEnter` and `onLineLeave` report pointer transitions with the same payload.
Moving between the gutter and text of the same source line does not re-enter it.
Hover-enabled canvases use one visible-rect tracking area, independent of document
length. Without hover handlers, neither the canvas nor the multi-file host installs
hover tracking; disabling the handlers clears the saved pointer position.
Mounted canvases refresh hover after clip scrolling and layout changes, and
mouse dragging also updates the hovered line. Viewport refreshes reuse the last
pointer event; leaving the canvas clears it. The multi-file review retains that pointer position across canvas mounting,
sending leave before entering the newly visible file. Header-only SwiftUI updates
preserve mounted canvases and their hover state. `onTokenClick` reports the original Shiki token's text and UTF-16 start/end
columns, before the enclosing line callback. Enable `enableTokenInteractionsOnWhitespace`
to include whitespace-only tokens. The normal per-line index cache holds at most 512 lines / 262,144 UTF-16 units,
plus one oversized line index so repeated hover on a long token does not rebuild
it. Pointer hit-testing retains one normalized source line; all these caches reset
when a document is installed. Cached ASCII lengths avoid re-scanning full lines
when calculating horizontal fragments. Metrics expose index/source construction
counts and the oversized index's UTF-16 length. `onTokenEnter` and `onTokenLeave` use the same payload and whitespace setting.
Within a canvas, token transitions occur before line transitions, matching upstream.
Token-only hover handlers enable tracking; stored hover state does not retain the
canvas. Pointer hits and painting share the same styled CoreText line, including before
the first paint, so bold/italic font metrics agree. Token events expose lazy
`visibleRects` in `event.view` coordinates, clipped to the viewport and text column.
Wrapped or bidirectional tokens can return multiple rectangles; events from a
replaced document return an empty array. Geometry uses CoreText caret clusters
and shares the bounded styled-line cache. The demo's Token popovers toggle shows
an AppKit popover anchored to a clicked visible fragment. Full complex-script and
bidirectional hit-testing parity remain on the checklist.

`lineHoverHighlight` on either interaction-handler type accepts `.disabled`
(the default), `.number`, `.line`, or `.both`. It enables native pointer tracking
without requiring callbacks. Hover backgrounds use upstream light/dark Lab mix
strengths, including addition/deletion colors, and follow wrapped source lines.
The demo exposes these modes in its Hover highlight picker. Line selection uses the palette modified color with separate gutter/code Lab
mixes; hover applies above selection and preserves diff indicator bars.
Attached editor active lines use the theme line-highlight background/border
metadata. A nontransparent background enables the upstream semantic 15% Lab
mix; missing backgrounds use a border. Nonempty text selection limits the
active treatment to the caret gutter. Terminal caret rows share this treatment with ordinary rows. Wrapped active borders enclose the source line, without horizontal seams
between fragments; split-column and complex-script combinations remain under audit.

Selected and editor-active line numbers use the upstream selection foreground:
Lab mixing of the modified palette color toward black (35% in light themes) or
white (25% in dark themes), including terminal caret rows.

Register lazy custom grammars on the highlighter that prepares your documents:

```swift
try await highlighter.registerCustomLanguage("my-language", extensionsOrFilenames: ["mine"]) {
    [try JSONDecoder().decode(LanguageRegistration.self, from: grammarData)]
}
```

The loader runs when preparation or `preload(languages:)` first requests the
language. Concurrent requests share a load, successful grammars stay attached,
and a failed load can be retried. Duplicate names keep the first registration;
`text` and `ansi` are reserved. The returned grammar must provide the requested
name or alias. Preparation, hydration, themed preparation, editing preparation,
and preloading are asynchronous actor methods. See the lifecycle APIs below for resolution state, attachment, and cleanup.

`registerCustomTheme(name:loader:)` has the same lazy loading, duplicate-registration,
and retry behavior (Swift call spelling: `registerCustomTheme("name") { ... }`).
Its loader returns a `ShikiTheme`; normalization derives foreground/background
from theme colors, and the resolved name must match the registration. The demo's
Custom · Sea Glass option exercises this path. Custom grammar arrays are attached
as one batch so grammars can reference others returned by the same loader.

`disposeHighlighter()` releases the native engine and token/editor caches while
preserving registered language/theme sources. Prepared documents remain usable.
Call it on `DiffHighlighter.shared` to dispose the shared engine, or on an isolated
instance. A later preparation or preload recreates the engine. Preparations and
preloads awaiting resource loaders when disposal occurs throw `CancellationError`
instead of attaching their results to a new engine. Pending language resolution
can still complete and cache grammar data, matching upstream cleanup semantics.

`cleanUpResolvedThemes()` clears lazy custom-theme attachment state and token/editor
caches, cancels pending loads, and retains the loaders. Late results cannot attach
after cleanup; the next preparation loads again. Already prepared documents keep
their colors and tokens. Bundled asset-cache eviction and separately exposing
resolved versus attached state remain under audit.

Language lifecycle APIs are available on `DiffHighlighter`: `resolveLanguage`,
`getResolvedOrResolveLanguage`, `getResolvedLanguages`, `hasResolvedLanguages`,
`attachResolvedLanguages`, `areLanguagesAttached`, and `cleanUpResolvedLanguages`.
Resolution returns `ResolvedLanguage(name:data:)` without attaching it. Attachment
accepts arrays and validates names/aliases. State queries accept arrays; `text` and
`ansi` count as attached without grammars. Cleanup retains registrations and pending
language loads, matching upstream, and subsequent use resolves/attaches again.
Both bundled languages and eager custom registrations participate in this lifecycle.

Theme lifecycle APIs mirror the language APIs: `resolveTheme`,
`getResolvedOrResolveTheme`, `getResolvedThemes`, `hasResolvedThemes`,
`attachResolvedThemes`, and `areThemesAttached`. Attachment accepts resolved objects
or `named:` arrays. `cleanUpResolvedThemes` now clears tracked state for bundled,
custom, and eager themes while preserving registration sources. It does not unload
the native engine's asset storage or invalidate already prepared documents.

`resolveLanguages(_:)` resolves pending grammars concurrently, skips `text`/`ansi`,
and returns cached entries first followed by newly resolved entries in request
order, preserving duplicates. `resolveThemes(_:)` preserves the full input order.
Both resolve without attaching. The first failure returns promptly without
cancelling independent shared loads; successful results retain their required
order. Cleanup while a bulk loader is suspended is covered: languages may
repopulate resolved state after cleanup; stale theme results are rejected, and
subsequent theme requests invoke the retained loader again.

Attaching a language batch clears token and incremental editor caches because a
new grammar may inject rules into an already loaded language. A regression test
warms both caches, attaches a late injection, and verifies the existing language
and editor both render the new token. Theme attachment does not need this broad
reset: theme names separate cache entries. More selective grammar invalidation
would require tracking injection and grammar dependencies.

The demo includes a Custom language example (`policy.reviewdemo`) whose lazy
TextMate loader recognizes review-policy comments, strings, keywords, and numbers.
It uses the normal diff presentation, theme picker, token interactions, and wrapping.

Gutter line selection is opt-in through `DiffInteractionHandlers.enableLineSelection`
or `FileInteractionHandlers.enableLineSelection` (default `false`, matching upstream).
It does not disable gutter click callbacks, programmatic selection, native text
selection, or attached-editor selection. Disabling the option stops an active
read-only gutter drag. The demo enables it by default and exposes a toggle.
Gutter gestures emit `onLineSelectionStart`, distinct-range
`onLineSelectionChange`, `onLineSelectionEnd`, then `onLineSelected` on commit.
Clicking an already selected single line clears it on mouse-up; dragging from it
starts a range instead. Set `controlledSelection: true` to receive proposed
ranges without changing the displayed selection; accept a proposal by calling
`selectLines` from a callback. `LineSelection.endSide` retains the other endpoint
for cross-side ranges. Gutter dragging and Shift-click can cross source sides;
copy returns the included source lines in unified order. Unchanged native files
also support these ranges. Cross-side copy intersects contiguous source spans
without creating a full-file render plan; partial patches omit missing context
and preserve original line endings. Pixel tests cover split selection and
gutter-only styling. Full cancellation/reentrant callback parity and selection
of split padding rows remain under development.

During a controlled gesture, `selectLines` clears the outstanding proposal.
End/commit callbacks then report the host-accepted range, including a range the
host adjusted in response to `onLineSelectionChange`.

Programmatic `selectLines(_:notify:)` emits `onLineSelected` for changed ranges;
repeating the same range does not emit another commit. Use `notify: false` when
accepting a controlled proposal to avoid a second programmatic notification.
`NativeCodeView.selectLines(_:inFileAt:notify:)` follows the same contract, and
restoring retained selection during virtualization is silent.

SwiftUI hosts can pass `selectedLines: $acceptedSelection` to `FileDiffView`.
This is a host-owned input: update that state in `onLineSelected` to accept a
controlled proposal, or leave it unchanged to reject it. The adapter applies
changed values with `notify: false` and leaves unchanged proposals alone during
unrelated SwiftUI updates. The demo's Selection ownership picker exercises
automatic selection, acceptance on release, and rejection on standard diff
examples; other adapters do not yet expose this SwiftUI input.

`NativeDiffView.selectLines` also accepts `activeLineSide` to restrict the
highlight to one source column and `lineNumberOnly` to emphasize only the
gutter. Both default to unrestricted full-row highlighting, matching upstream.
Changing these options for the same range redraws without emitting another
`onLineSelected` callback. A changed mouse selection resets these overrides.

With a host-owned `selectedLines` binding, `FileDiffView` accepts the same
`activeLineSide` and `lineNumberOnly` inputs. Style changes are applied even
when the bound range is unchanged. These inputs apply to the bound selection;
without a binding, mouse selection keeps its native defaults. In the demo,
choose “Accept on release” or “Reject proposals” to expose the “Highlight
columns” and “Highlight gutter only” controls.

Custom AppKit annotations can be supplied through
`NativeDiffView.renderAnnotation`. The callback receives a `LineAnnotation`
and returns an `NSView`, or `nil` to suppress that annotation. A row with no
rendered annotations collapses to zero height.
Only visible annotation views are mounted. Intrinsic height, fitting height,
or the supplied frame height determines the row extent, with a minimum of one
code-line height. Paired split annotations use the taller side. Views can be
recreated after scrolling offscreen, so keep persistent comment state in your
model. After changing a mounted annotation's preferred height, call
`invalidateAnnotationLayout()` to remeasure it without recreating its view.
SwiftUI/demo integration is available as described below; offscreen width
invalidation and physical interaction validation remain in progress.

For SwiftUI, retain a `DiffAnnotationRenderer` (for example in `@State`) and pass
it as `FileDiffView(annotationRenderer:)`. Its object identity preserves mounted
views across unrelated SwiftUI updates; replacing the renderer rebuilds them.
The demo's “Annotations” toggle exposes “Custom annotation cards” for the
standard diff presentation. Those cards use native SwiftUI hosting views inside
the virtualized AppKit annotation rows. The integration compiles in Release;
on-screen verification remains outstanding.

To display source while syntax highlighting is pending, call
`await highlighter.preparePreview(diff, options: options)`, render that result,
then call `await highlighter.prepare(diff, options: options, sourceID:
preview.sourceID)` and render the highlighted result. The preview has theme
colors but no syntax tokens or inline word spans. Reusing its source identity
preserves scroll and selection. This improves time to readable content; it
does not reduce the full tokenization cost. The demo uses this flow for standard
single-theme, read-only diffs and parses their input off the main actor.

`NativeFileView.render` and SwiftUI `FileView` also accept `annotations`.
Set `NativeFileView.annotationRenderer` or pass `FileView(annotationRenderer:)`
to use the same custom views and measured geometry in standalone file/stream
presentations. `NativeFileView.invalidateAnnotationLayout()` forwards dynamic
height refresh to the shared canvas.

`NativeThemedDiffView` and `ThemedFileDiffView` accept the same retained
`annotationRenderer`; the native wrapper also forwards
`invalidateAnnotationLayout()`. The demo exposes custom annotation cards while
following system appearance. This integration builds in Release; annotated
scroll-anchor behavior during theme transitions still needs dedicated validation.

`EditableFileDiffView` also accepts `annotationRenderer: DiffAnnotationRenderer?`. Retain the renderer across SwiftUI updates, as with `FileDiffView`; replacing it rebuilds the mounted annotation views. The demo exposes custom annotation cards in its editable diff example. Annotation movement in response to source edits remains subject to the editor annotation-tracking limitations documented in the parity audit.

During attached editing, `DiffEditor.currentAnnotations` exposes mapped comments and completion supplies both `annotations` and `originalAnnotations`. File presentations additionally expose `currentFileAnnotations`; their completion has `isFile == true`, `fileAnnotations`, and `originalFileAnnotations`, preserving side-less shape, IDs, text, and metadata identity. Diff sessions return nil for those file-specific arrays. Review items expose `fileAnnotations` after accepted completion. Re-rendering with annotations equal to the last external, provided, or current values preserves session positions. Different values replace the session comments using current edited line numbers. Use `editor.setAnnotations(...)` for an explicit replacement even when values match a previously supplied array. In single-file sessions, `try editor.setFileAnnotations(...)` accepts side-less comments directly; it rejects diff sessions. This value-based refresh policy adapts upstream JavaScript array identity to Swift; preserve stable annotation IDs.

`CodeView` and `NativeCodeView.render` accept `annotations: [Int: [LineAnnotation]]`, keyed by zero-based document index. Default annotation rows participate in file-height estimates and asynchronous wrapped layouts. The multi-file demo uses the Annotations toggle to show them. Pass a retained `DiffAnnotationRenderer` through `annotationRenderer:` for custom variable-height annotation views in the multi-file adapter.

Annotations accept optional `LineAnnotationMetadata`, an immutable identity-bearing wrapper around any `Sendable` application value. Retrieve typed data with `annotation.metadata?.value(as: Review.self)`. Reuse the metadata object across refreshes; a new wrapper represents new metadata even if its payload has equal fields. Line mapping preserves the same wrapper. The generic initializer models object identity. For JavaScript strict primitive equality, use `LineAnnotationMetadata(primitive: .string("review"))` (also `.number`, `.boolean`, and `.null`). Missing metadata represents undefined and differs from explicit null. Numbers preserve strict comparison, including unequal NaN and equal signed zeros; strings compare exact UTF-16 code units. `areLineAnnotationsEqual` compares line and metadata; `areDiffLineAnnotationsEqual` also compares side. These upstream helpers deliberately exclude native annotation IDs and display text, unlike the complete native annotation equality used for rendering.

`NativeCodeView.overscrollSize` optionally prepares neighboring files within a buffered window (logical points). The default is zero for viewport-only mounting. Setting it back to zero releases neighbors outside the current viewport; nonfinite or negative values behave as zero. The public `createWindowFromScrollPosition` helper preserves upstream window rounding and fit-perfectly behavior, while `areVirtualWindowSpecsEqual` and `areRenderRangesEqual` compare optional coordinate values. The AppKit multi-file view uses this helper to select files; visible file segments still follow the actual viewport.

SwiftUI hosts can pass `CodeView(documents: documents, overscrollSize: 600)`. In the demo’s multi-file example, “Prepare neighboring files” toggles this 600-point buffer. It is disabled by default.

`areThemesEqual` accepts optional `DiffThemeSelection.single(name)` or `.adaptive(DiffThemeNames(...))` values. It matches upstream exact name equality and keeps single-theme and adaptive-pair inputs distinct, even when both pair entries name the same theme. Existing render and highlighter APIs retain their current theme parameters.

Line-info separators provide direction-specific expansion and Expand all. Controls compact to arrows and “All” in narrow viewports; the unchanged-line count is omitted when it cannot fit. Accessibility custom actions are exposed for visible separators. `DiffRow.hunkData(...)` provides metadata for concrete collapsed-context rows, and `getTrailingContextRangeSize(fileDiff:)` validates matching trailing context on both sides. Unknown-length partial gaps expose an unknown line count until their contents loader completes.

For custom collapsed-context content, set `options.hunkSeparators = .custom`
and pass a retained `DiffSeparatorRenderer` as `separatorRenderer:` to
`FileDiffView`, `ThemedFileDiffView`, `EditableFileDiffView`, or `CodeView`.
Their native views expose the same property. The renderer receives `HunkData`
and an expansion function returning whether the action was accepted:

```swift
let separatorRenderer = DiffSeparatorRenderer { hunk, expand in
    NSHostingView(rootView: HStack {
        Text("\(hunk.lines) unchanged lines")
        ForEach(hunk.expansionActions, id: \.rawValue) { action in
            Button(action.rawValue.capitalized) { _ = expand(action) }
        }
    }.padding(8))
}
```

Split views receive separate additions/deletions slots. Their shared row uses
its taller preferred height. Returning nil leaves that slot empty. Only visible
separators mount NSViews; unchanged metadata retains the existing view.
Expansion functions become inert after their slot is replaced or unmounted.
Use the supplied `lineCountKnown` and `expansionActions` for partial-file states.
After changing a custom view's preferred height, call
`invalidateSeparatorLayout()` on the native diff, themed diff, or review view.
The demo's separator picker includes a custom example.


Multi-file reviews accept `layout: CodeViewLayout(paddingTop: 8, paddingBottom: 8, gap: 8)` in both `NativeCodeView.render` and the SwiftUI `CodeView` initializer. These upstream defaults apply spacing only between files, with separate outer padding. Layout changes preserve the current file and its local scroll offset.

For content around the entire review, set `NativeCodeView.reviewHeader` / `reviewFooter`, or pass `reviewHeader:` / `reviewFooter:` to SwiftUI `CodeView`. Retain these NSViews across updates. Their intrinsic/fitting heights contribute to scrolling; call `invalidateReviewChromeLayout()` on the native view after changing content that affects height.

For stable-ID review selection, use `selectLines(_:inItem:notify:activeLineSide:lineNumberOnly:)`,
`selectText(_:inItem:)`, and `selectedText(inItem:)`. These resolve the current
item index without scrolling or mounting an offscreen item. Selection follows
reordering and ID renaming. Unknown IDs return false (or empty copied text) and
leave the current selection unchanged. The existing index-based methods remain
available. Upstream's ability to retain a selection for an absent item ID is not
yet represented by these native methods.

`areDiffTargetsEqual` accepts optional `DiffTarget` reference wrappers. Retain a
wrapper to preserve an unkeyed target's identity; creating another wrapper around
equal `FileDiffMetadata` represents another target. If either target has a cache
key, only exact cache-key equality matters. This helper does not traverse file
contents and does not replace the prepared-document IDs used by native views.

`FileLineAnnotation` represents a side-less file comment. `EditorAnnotation.file`
and `.diff` retain the upstream annotation shape for `isFileAnnotation`,
`isDiffAnnotation`, and their collection counterparts. Empty collections satisfy
both collection predicates; nonempty collections inspect their first element,
as upstream assumes homogeneous input. To pass these values to current native
renderers, map `renderedAnnotation`; file annotations render on additions while
retaining their ID and metadata. File editor sessions and completions expose
side-less `currentFileAnnotations` and `fileAnnotations` arrays in addition to
the shared rendered annotations, including after suspension or removal.

Single-file hosts also accept these comments directly through
`NativeFileView.render(_:file:options:fileAnnotations:)` and
`FileView(document:options:file:headerRenderers:interactionHandlers:fileAnnotations:annotationRenderer:)`.
The distinct `fileAnnotations:` label avoids ambiguity with existing empty
`annotations:` arrays. Custom annotation renderers receive the adapted additions
side with the original comment ID and metadata.

`areLineAnnotationsEqual` accepts either two `FileLineAnnotation` values or two
`LineAnnotation` values. It compares line number and strict metadata equality,
ignoring native comment IDs and display text. When constructing both arguments
inline, spell out one annotation type rather than using two unqualified `.init`
expressions so Swift can choose the overload.

Removing or resetting an actively edited review item now delivers its captured
edited source to `editor.onEditComplete` asynchronously after removal. Returning
true cannot reinstall that removed item. Use `await editor.waitForTeardown()`
when a host needs to wait for this notification. Teardown releases mounted views
immediately; it does not syntax-highlight the discarded result.

For a single-file entry in a mixed review, use
`CodeViewItem(id:document:file:fileAnnotations:)`. The prepared document must
still represent that file's identical old/new contents. The demo uses this
initializer for every fifth review item and ordinary diff annotations for the
other items.

Registry inspection is available with `await highlighter.resolvedLanguages`,
`attachedLanguages`, `resolvedThemes`, and `attachedThemes`. These are value
snapshots of actor-owned state. `registeredCustomLanguageNames` and
`resolvingLanguageNames` expose registered/pending names without exposing loader
closures or task handles. Change state through registration, resolution,
attachment, and cleanup methods; mutating a local snapshot cannot change the actor.
### Deferred review selection

SwiftUI hosts can pass `onSelectedLinesChange` to `CodeView(items:...)`. The wrapper installs the latest closure before reconciling items and clears it when dismantled. AppKit hosts set the same property directly on `NativeCodeView`.

`NativeCodeView.setSelectedLines(CodeViewLineSelection(id:range:))` accepts an item ID before that item is present. `getSelectedLines()` returns that retained request immediately. The next `setItems` reconciliation applies it silently if the exact UTF-16 ID is present, or clears it if absent. `clearSelectedLines()` and `reset()` also clear deferred requests. Use the existing `selectLines(_:inItem:)` when an unknown ID should instead return `false` and preserve the current selection. `onSelectedLinesChange` reports item selection events, selected-item renames, and selection removal during item reconciliation. Deferred requests for unknown IDs do not notify until reconciliation clears a still-missing target; applying an arriving target is silent.
### Inspecting mounted review items

`NativeCodeView.getRenderedItems()` returns mounted items in review order without mounting offscreen files. Each snapshot contains the `CodeViewItem` and its `NativeDiffView` instance, plus `id`, `isFile`, and `version` (the prepared document's UUID). Query again after scrolling or item updates. Holding a snapshot retains its native view; the value is not a live subscription. This uses native prepared-document revision identity rather than upstream's caller-provided version field.
### Animated review offsets

`NativeCodeView.scrollTo(top:behavior:)` accepts an absolute logical offset with `.instant` (default) or `.smooth`. Smooth navigation uses a macOS display link and the upstream spring defaults. Retargeting keeps velocity. Wheel input, external clip-view changes, reset, and detachment cancel the animation. Without a window it applies the destination immediately. `cancelScrollAnimation()` and `isAnimatingScroll` expose lifecycle control. Line and range navigation also accept `behavior: .smooth`, including start/center/end/nearest alignment and deferred wrapped-layout targets. Document or layout revisions cancel an in-flight range target; resize-anchor rebasing remains incomplete.
Smooth file navigation is available through `scrollToItem(_:behavior:)` and `scrollToFile(at:behavior:)`. The target follows its source identity through renames and stops if removed. Per-frame lookup uses a cached index, checking the source identity before reuse. Layout changes can still cancel the animation; automatic resize-anchor rebasing is not yet implemented.

### Inline conflict resolution

Pass parsed conflict markers to a diff and handle the region-specific
resolution callback. The view draws current/incoming bands and the three inline
accept controls; your owner installs the resolved document:

```swift
FileDiffView(
    document: highlightedConflict,
    options: unifiedOptions,
    markerRows: conflictResult.markerRows,
    onResolveConflict: { conflictIndex, resolution in
        // Resolve this region in your UnresolvedFileState, then re-highlight.
        resolveRegion(conflictIndex, resolution)
    }
)
```

The AppKit equivalent is `NativeDiffView.onResolveConflict`. Action values are
`.deletions` (current), `.additions` (incoming), and `.both`.

When marker rows are present, the renderer forces unified layout and disables
word-level difference highlights, matching upstream unresolved-file rendering.
Set `options.mergeConflictActionsType = .none` to hide the resolution toolbar
while keeping marker text and current/incoming bands. The action row consumes
no height and exposes no pointer or accessibility actions in this mode. Restore
`.default` to show the three controls. The demo's Conflict actions picker
exercises all three modes.

For custom controls, select `.custom`, retain a `DiffConflictActionRenderer`,
and pass it alongside `conflictResult.actions`:

```swift
let conflictRenderer = DiffConflictActionRenderer { action, resolve in
    NSHostingView(rootView: Button("Keep both for conflict \(action.conflictIndex + 1)") {
        _ = resolve(.both)
    }.padding(8))
}

FileDiffView(document: highlightedConflict, options: customConflictOptions,
             markerRows: conflictResult.markerRows,
             onResolveConflict: resolveRegion,
             conflictActionRenderer: conflictRenderer,
             mergeConflictActions: conflictResult.actions)
```

`NativeDiffView`, `NativeThemedDiffView`, and `ThemedFileDiffView` also expose
these properties. Custom controls receive the full `MergeConflictDiffAction`.
Their resolution function forwards to `onResolveConflict` and returns false
when the control has become stale, offscreen, or hidden, or no handler exists.
Only visible controls mount; unchanged action metadata retains the view.
Preferred heights determine the toolbar height, with upstream's 28-point
minimum even for nil custom content. Call `invalidateConflictActionLayout()`
after changing a mounted custom view's preferred height. Supply updated parsed
actions and marker rows after installing a resolved document.

### Custom gutter controls

`NativeDiffView.renderGutterUtility` creates a single retained AppKit control.
Its getter reports the current source line and side when the control acts. The
control follows hover; a line selection instead anchors it at the visually
bottom endpoint. Offscreen targets hide the control without destroying it.

```swift
view.interactionHandlers.enableGutterUtility = true
view.renderGutterUtility = { getHoveredLine in
    MyReviewButton {
        guard let target = getHoveredLine() else { return }
        openReview(line: target.lineNumber, side: target.side)
    }
}
```

`MyReviewButton` and `openReview` represent your own control and action. For
`FileDiffView`, retain a `DiffGutterRenderer` in host state and pass it as
`gutterRenderer:`. The demo's **Gutter utility** toggle enables a control that
shows its target line in a popover. The themed viewer also accepts
`DiffGutterRenderer`. Single-file and streaming views accept `FileGutterRenderer`
whose getter returns a side-less `FileHoveredLine`. Multi-file reviews accept
`CodeViewGutterRenderer`; its getter returns the current item ID, document,
optional original file, line number, and side (nil for single-file items).
Review getters resolve identity at action time across renames/reordering and
return nil after unmounting. `EditableFileDiffView` also accepts a retained
`DiffGutterRenderer`; its control follows the same canvas throughout editing and
completion.

For the built-in plus button, set `enableGutterUtility: true` and provide
`onGutterUtilityClick:` in the interaction handlers without a custom renderer.
Clicking acts on the selected range (or hovered line); dragging extends from its
visually top endpoint, including across diff columns. The action, selection-end,
and selection-committed callbacks receive the same completed range. Custom
controls also require `enableGutterUtility: true`. The demo offers both built-in
actions and an optional custom popover.

### CSS-variable themes

`createCSSVariablesTheme(CSSVariablesThemeOptions(...))` returns Shiki's raw
CSS-variable theme, preserving scope order, CSS fallbacks, and optional font
styles. For AppKit, use `createResolvedCSSVariablesTheme(_:variables:)` or
`await highlighter.registerCustomCSSVariableTheme(name, variableDefaults: values)`.
Defaults use unprefixed role names (`foreground`, `background`, `token-keyword`,
`ansi-red`, etc.); host overrides use fully prefixed keys (`--diffs-token-keyword`
for the registration helper, `--shiki-token-keyword` for factory defaults).

The native adapter requires every referenced role to resolve to a hex color
(`#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA`). It reports missing/invalid values;
it does not evaluate a browser CSS cascade, nested `var()` expressions, or named
CSS colors. Supply updated resolved themes through `registerTheme` when host
appearance changes. Registration is lazy and first-registration-wins, matching
the existing custom-theme loader. Factory font styles default to enabled;
the diffs registration helper defaults to disabled, as upstream does.

### Owned merge-conflict component

`NativeUnresolvedFileView` owns an `UnresolvedFileState` and its native diff view.
Call `try view.render(file: unresolvedFile)` to parse/display the source. Its
built-in and custom conflict actions resolve automatically; observe the resulting
source with `view.behavior = .automatic(onResolve: { file, payload in ... })`.

For controlled behavior, use `.controlled(onAction: { payload, view in ... })`.
`try view.resolveConflict(payload.conflict.conflictIndex, resolution: payload.resolution)`
returns a new state without changing the view; install it with `view.render(state:)`.
The enum prevents registering both mutually exclusive action modes. Customize
headers, gutter utilities, interactions and action renderers through `view.diffView`.

Resolution updates source and marker state immediately, then asynchronously adds
syntax colors using the shared highlighter. `isPreparing`, `preparationError`, and
`onError` expose highlighting progress/failures. A replacement or `cleanUp()`
invalidates old actions and pending results. Cleanup permits subsequent reuse.
Use the existing `FileDiffView` when the host already owns prepared conflict state;
`UnresolvedFileView` supplies the SwiftUI ownership interface.


`UnresolvedFileView(file:options:highlighter:behavior:)` preserves internal
resolutions across SwiftUI refreshes and display-option changes. Echoing the
resolved source back from `onResolve` preserves remaining conflict identities.
Replacing the input file installs a new source; use `.id(resetID)` to reset the
same original input intentionally. A context-size change reparses the current
resolved source. The highlighter is retained for the SwiftUI view's identity;
use a new identity when replacing that dependency. The demo's Merge conflicts
example now uses this wrapper.

The owned conflict component reuses prepared syntax tokens for font, spacing,
wrapping, action-bar, and annotation changes. Layout changes made while a theme
or grammar is loading keep that preparation alive; its result uses the latest
layout. Source revisions, theme names, and tokenization limits invalidate the
preparation. This avoids clearing syntax colors during ordinary display updates.

### Navigating folded context

`NativeDiffView.isLineRenderable(_:)` checks whether a one-based new-file line
is outside collapsed context, independently of whether it is in the viewport.
`getNearestRenderableLine(_:direction:)` finds the nearest renderable line in
`.up` or `.down` direction, returning `nil` when none exists in that direction.
`revealLine(_:)` expands from the closest gap edge through the usual expansion
callback and returns whether it changed the expansion state. It does not scroll:

```swift
try diffView.revealLine(120)
diffView.scrollToLine(120)
```

These methods match upstream's partial-file and phantom document-end line
semantics. Partial files report lines as renderable and cannot be expanded by
`revealLine`; loading missing source remains the file-loading API's job.
Inconsistent full-file trailing metadata throws `TrailingContextMismatch`.

`NativeUnresolvedFileView` exposes the same three navigation methods directly.
Revealed conflict context survives the transition from plain preview to syntax
highlighting. Explicitly replacing its source with `render(file:)` resets folds.

### Presentation lifecycle

`NativeDiffView.onPostRender` receives `(view, phase)` after document renders
and context expansion. `PostRenderPhase` is `.mount`, `.update`, or `.unmount`.
The native view supplies both the rendered container and component instance.
Mount means the first installed presentation, even in an offscreen view;
unchanged document renders do not emit an update. Cleanup emits unmount while
the old document remains inspectable, then cancels pending work and clears it.
A later render mounts again. Call `cleanUp(recycle: true)` to suspend an attached
editor while retaining its text and undo history, or `cleanUp()` to discard it.

`NativeUnresolvedFileView` forwards the same phases with its own instance,
including updates when asynchronous highlighting replaces its plain preview.
Both `FileDiffView` and `UnresolvedFileView` accept `onPostRender` and clean up when
SwiftUI dismantles their native view. Callbacks may synchronously replace the
source or call cleanup; an older render/cleanup cannot overwrite that change.
These are presentation callbacks, not compositor-frame or scroll notifications.

Virtualized review items also unmount when they leave the rendered window.
A callback installed on `getRenderedItems()`'s native instance can inspect its
last document and editor during unmount; cleanup then releases that instance's
presentation. The review retains the editor's text and undo history for a later
mount. A retained rendered-item snapshot may therefore refer to a cleared,
offscreen instance; query `getRenderedItems()` again for the current views.

### Review item controls

`CodeViewItem.collapsed` collapses one file independently. `nil` inherits the
review-wide setting; `false` explicitly opens it. Update an item through
`updateItem` or `setItems`. Collapsing an edited item suspends presentation while
retaining its draft and undo history; expanding it resumes the same editor.
The demo's multi-file review has Collapse all, Expand all and Toggle first file.

`NativeCodeView.onPostRender` and SwiftUI `CodeView(onPostRender:)` receive a
`CodeViewRenderedItem` and lifecycle phase. The payload includes the caller's
item ID, current item metadata and native instance. Renames update callback
identity; unmount identifies the item being retired. Mount callbacks run after
the view has joined the rendered set and can replace the review. Direct
instance callbacks continue to work alongside the shared callback.

### Updating existing components

`NativeDiffView`, `NativeFileView` and `NativeUnresolvedFileView` expose
`setOptions`, `setLineAnnotations` and `rerender`. `NativeFileView` also accepts
side-less comments through `setFileAnnotations`. Configuration updates retain
logical source identity, selection and expansion; forced rerender refreshes
custom content. Conflict controls retain the current resolved source.

Prepared file/diff views update presentation only: changing syntax themes or
languages requires preparing a new `HighlightedDiff`. The owned conflict view
performs its own asynchronous preparation when its theme changes.
`NativeFileView` and SwiftUI `FileView` now expose owned lifecycle callbacks and
cleanup, including the side-less annotation initializer.


## Owned streaming view

`NativeFileStreamView.setup(_:name:configuration:options:)` consumes an
`AsyncThrowingStream<String, Error>` and owns the token stream and native file
presentation. It exposes `onPreRender`, `onPostRender`, `onStreamStart`,
`onStreamWrite`, `onStreamClose` and `onStreamAbort`. Token writes include recalls
for the unfinished line. `cancel()` keeps the last snapshot; `cleanUp()` also
clears it. `waitForCompletion()` waits for the current source and layout.

`FileStreamView` is the SwiftUI wrapper. Change `streamID` when changing the
source or tokenizer configuration; ordinary font/layout updates preserve the
stream. `startingLineIndex` changes displayed labels without changing source
positions. The Managed stream demo starts labels at 42 and provides Stop and
Replay. Streams omit file headers and diff indicators, matching upstream.


### Editor typing, focus and active lines

Attached editors default to matching `()`, `[]` and `{}` outside syntax strings,
comments and regular expressions. Matching is cached on caret changes and bounded
to 1,000 lines / 50,000 UTF-16 characters. While new syntax is pending, stale
matches are hidden. The highlight uses the upstream subtle fill and underline.

```swift
editor.matchBrackets = true
editor.autoSurround = .brackets // .default, .never, .quotes, .languageDefined
editor.focus(.init(preventScroll: true, line: .firstVisible, offset: 24))
editor.focus(.init(line: .number(42), character: 3)) // one-based line
editor.onFocus = { /* native first-responder transition */ }
editor.onBlur = { /* native first-responder transition */ }
editor.blur()
view.setEditorActiveLine(42, options: .init(side: .additions, lineNumberOnly: true))
```

Typing a surround character over selected text preserves the inner selection and
makes one undo step. Explicit replacement ranges and marked-text composition
keep their native replacement semantics. `languageDefined` currently uses the
standard pairs, matching upstream. `EditableFileDiffView` also accepts
`autoSurround` and `matchBrackets`.

### Adaptive streams

```swift
let configuration = try await highlighter.streamConfiguration(
    language: "swift", themes: DiffThemeNames())
streamView.setup(source, name: "Example.swift", configuration: configuration)
streamView.themeAppearance = .dark // .light or .system
```

Each incoming chunk advances both theme tokenizers. Appearance changes select a
cached snapshot without replaying the source, changing token callback identity,
or resetting selection. Token-write callbacks consistently expose light-theme
tokens; `document` is the snapshot currently displayed. SwiftUI `FileStreamView`
accepts `adaptiveConfiguration` and `themeAppearance`; configuration changes still
require a new `streamID`. The demo's Managed stream has an Appearance picker.

### Editor host customization

`editor.clipboard` accepts an asynchronous `EditorClipboardProvider`. Paired
multi-selection paste preserves document order, normalizes newlines and forms
one undo group. Delayed results are discarded after selection/document changes
or session suspension.

Enable `editor.enabledSelectionAction` and set an
`EditorSelectionActionRenderer` to return custom NSView/NSHostingView content
for user-created selections. Its live context reads or replaces the primary
selection, applies edits and closes the widget; expired contexts cannot modify
a newer session. `EditorCaretRenderer` replaces visible collaborator caret bars
with custom native views while the canvas retains their selection highlights.

The same properties are available on `EditableFileDiffView`. The demo's
**Editable diff → Widgets** menu shows selection actions, collaborator labels
and delayed clipboard reads. See [host customization](EDITOR-HOST-CUSTOMIZATION.md)
for sizing, lifecycle and native API details.

### Save and restore expanded context

```swift
let expanded = view.getExpandedHunksMap()
view.setExpandedHunksMap([:])       // Collapse explicit expansions.
view.setExpandedHunksMap(expanded)  // Restore them.
let first = view.getExpandedHunk(0)
```

Maps are Swift value snapshots, indexed by the collapsed region before each
hunk; the trailing region uses the hunk count. Replacing the source resets the
map. The global `expandUnchanged` option still takes precedence. Changes survive
attached-editor preparation and multi-file review recycling. The demo's patch
example exposes Save/Restore/Collapse expanded context after Load full patch
contents is enabled.
