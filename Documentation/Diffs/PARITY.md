# Upstream parity record

Reference: the supplied `@pierre/diffs` **1.4.2** source snapshot. Its individual
source hashes are recorded in `upstream-manifest.json`. The snapshot has no Git
metadata. Tests execute that source with Bun to generate reference output; the
shipped Swift library has no JavaScript runtime.

This is an actively developed native port. **Complete 1:1 parity is not yet
verified.** The table distinguishes exact data comparisons from native behavior
checks. An AppKit counterpart is not automatically proof of every web behavior.

## Implemented and checked

| Upstream area | Native implementation | Evidence |
| --- | --- | --- |
| File, patch, hunk, content and conflict metadata | Codable Swift value types | Exact decoded structural comparisons |
| Patch parsing, multi-file and multi-commit parsing | `PatchParser.swift` | 32 upstream fixtures, including a large real patch, Unicode, CRLF, EOF markers, quoted paths, binary metadata, malformed count recovery |
| Patch context trimming | `trimPatchContext` | 124 upstream output comparisons, including zero-context ranges |
| File-to-file diff generation | `DiffAlgorithm.swift` | 312 file-pair fixtures using pinned jsdiff 9; 6,561 exhaustive sequence pairs against an independent minimum-edit oracle |
| Generation options and Unicode whitespace | `DiffOptions`, `PatchHeaderOptions` | 608 upstream cases covering context, whitespace, CRLF normalization and all header combinations; full-context overflow and editor-session checks |
| Change-block realignment | `Alignment.swift` | Included in patch and generated-file fixtures |
| Partial hydration | `hydratePartialDiff` | Geometry and cache-key checks; explicit full-file inputs |
| Asynchronous partial-file loading | `NativeDiffView.loadDiffFiles`, `FileDiffView` | Request deduplication, stale-completion rejection, retry, source identity preservation and off-main hydration/highlighting |
| Accept/reject/both and region resolution | `Resolution.swift` | 63 upstream hunk resolution cases |
| Inline word, word-alt, character, none | `inlineDiff` | 1,688 jsdiff/upstream span cases, including non-Latin scripts, combining marks, emoji and limits |
| Merge conflict parsing and resolution | `MergeConflicts.swift` | 33 parser fixtures and 60 individual resolution cases, including diff3 and large inputs |
| Incremental unresolved file state | `UnresolvedFileState` | Preserves marker text and stable conflict identities; updates subsequent source coordinates |
| Syntax highlighting | Native Shiki package, reusable `DiffHighlighter` actor | Bundled Pierre themes, language inference, custom registrations, per-line and document limits |
| Automatic appearance and theme colors | `ThemedDiff`, `NativeThemedDiffView`, `ThemedFileDiffView` | Precomputed light/dark variants preserve scroll/selection; native Lab interpolation and alpha checks; inspected rendered colors |
| Token caching | Actor-owned bounded LRU | Exact source/theme/limit keys, invalidation and eviction checks; 128 MiB estimated default budget, 64-entry cap |
| Incremental editor syntax | `prepareForEditing`, sparse TextMate state checkpoints | Exact comparison with full native Shiki tokens/offsets across replacement, insertion, deletion, comment and heredoc edits; separate 8-document / 64 MiB estimated cache |
| Split/unified rendering | AppKit/CoreText `NativeDiffView` | Hidden-window render and selection checks; inspected image output |
| Text annotation placement | Side-aware `DiffRow.annotations`, line-zero file annotations, aligned split stacks | Native checks for identity/order, absent file sides, collapsed state, wrapping, variable-height custom views, editor tracking and per-file default annotations; custom multi-file views remain |
| Header render hooks | `DiffHeaderRenderers` on native, themed, editable and multi-file diff views; `FileHeaderRenderers` on file/streaming views | Native tests for slot ordering, metadata alongside counts, custom-mode suppression including nil, view removal, height restoration, appearance changes, attached editing, original file metadata and atomic streaming callback updates, lazy multi-file mounting and measured header extents and width-dependent custom-height changes; demo modes provided |
| Line click and pointer hover hooks | `DiffInteractionHandlers` across diff adapters; `FileInteractionHandlers` for single files | Native event dispatch checks for gutter precedence/fallback, side/type/geometry, modifiers, drag suppression and non-code rows, file metadata, adapter forwarding and source replacement and pointer enter/leave transitions, stationary clip scrolling and dragging; cross-file hover transfer and canvas retention during header updates; lazy viewport-clipped token rectangles |
| Hover highlight modes | `lineHoverHighlight` on diff/file interaction handlers | Disabled/number/line/both, callback-free tracking, source-backed Lab mixing; pixel-region tests and exit clearing; selection composes below hover with distinct gutter/code strengths; attached editor active-line layering uses theme background/border metadata and retains gutter treatment during text selection; terminal caret rows share the pipeline with pixel checks for caret versus text selection; wrapped active borders omit internal horizontal seams; split-column and complex-script combinations remain |
| Token clicks and hover | Original Shiki token index, UTF-16 ranges, ECMAScript whitespace option | Native checks for original-token boundaries, long-line lookup, callback order, gutter/padding exclusion, whitespace opt-in, token/line transition ordering and token-only tracking, and one-megabyte repeated-hover cache reuse and styled-font hits before first paint; wrapped geometry, bidi disjoint rectangles, composed clusters and stale-revision rejection; full complex shaping parity remains |
| Context expansion | `DiffRenderPlan` and native separator actions | Collapsed/full context tests, both expansion directions and overlap deduplication |
| Wrapped rendering | `DiffWrapLayout` background actor | UTF-16 fragment reconstruction, inspected render, viewport width and multi-file heights |
| Virtualized single-file scrolling | Direct physical row indexing; bounded styled-line cache | Destination-jump paint checks on 20,000-line Swift and 1.14 MB JSON |
| Virtualized multi-file scrolling | `NativeCodeView` | 1,000-file destination mounting and 100-file wrapped geometry checks |
| Line and character selection | Native hit testing, gutter selection, keyboard and copy | Mouse selection, multi-line copy, grapheme keyboard movement and retained selection tests |
| File streaming | `FileStream`, `ShikiStreamTokenizer` actors | Incomplete-line recalls, continued grammar state and stable document identity |
| Text document editing model | UTF-16 piece table, incremental line index, inverse edits | 300 random edits, 150 fragmented batches against flat-string/reference indexes, 30,000-edit apply/undo benchmark, atomic edit batches, undo/redo |
| Frozen diff regions during editing | `EditSessionHunks.swift`, `DiffEditSession` | 150 upstream utility sessions / 780 steps, plus the same sessions through the renderer's empty/blank dispatch; exact hunks, region remapping, expansion anchors and final recomputation |
| Native editor | NSTextView with noncontiguous TextKit and visible syntax attributes | Native edit, selection, undo and wrapping checks |
| Attached diff editor | `DiffEditor`, `NativeDiffView.beginEditing`, `EditableFileDiffView` | AppKit key dispatch, marked-text undo, source selection, caret coordinates, empty/trailing rows, fold skipping, wrapped-row movement, goal columns, indentation undo, latest-input and completion checks |
| Editor cursor and indentation commands | `EditorSelection.swift`, attached AppKit key bindings | 20,664 upstream navigation cases, 270 deletion ranges and 1,344 indentation cases, including fold/wrap geometry and Unicode whitespace |
| Editor line operations and comments | `EditorLineCommands.swift`, `EditorComments.swift`, native shortcuts | 1,715 upstream line command cases; 6,420 line/block comment cases and 32 language defaults; native keyboard, selection and undo checks |
| Multiple local selections and view state | `MultipleSelections.swift`, `DiffEditor`, virtualized CoreText overlays | 512 upstream merges + 259 replacements; Option-drag, Command-D, clipboard, IME, undo and scroll restoration; inspected secondary-caret bitmap |
| Keyboard customization | `EditorKeymap`, `performCommand` | Every upstream command resolves, platform/later-group precedence, physical-key fallback and native event execution |
| Editor host customization | `EditorClipboard.swift`, `EditorWidgets.swift`, `DiffEditor`, virtualized canvas | Async read cancellation, paired paste, live/expired contexts, native mouse drag, split placement, 500-caret virtualization and reentrant renderers; demo Widgets menu |
| Predictive editing | Bounded requests/history, cancellable providers, ghost previews, eager/subtle modes | Source-derived helper comparisons, lifecycle/undo tests, inspected native bitmaps and demo controls (EDIT-PREDICTION.md); full interactive sign-off remains |
| Initial editor state | `EditorInitialState`, `DiffEditor.getEditState`, AppKit/SwiftUI attachment | Independent value snapshots; undo/redo, IME, partial fields, identity reset, keyed precedence, folds and viewport covered by native integration tests |
| Document convenience and replay APIs | `TextDocument` checked access and `undoResult`/`redoResult` | UTF-16 bounds, CRLF, surrogate access and interaction-history flag covered; Swift string and checked-line adaptations documented |
| Coalescing and bounded history | `EditStack`, `TextDocument`, native undo bridge | 38 upstream histories / 2,782 operations; configurable group cap, full IME undo units, annotation replay, callback undo and value snapshot transfer |
| Editor clipboard and directed history | `EditorClipboard.swift`, `DiffEditor` | 816 upstream clipboard/cut cases; native whole-line and read-only cut checks; backward selections survive undo, redo and composition cancellation |
| Search matching and replacement text | `EditorSearch.swift`, standalone native ECMAScript regex engine | 3,456 upstream search/replacement cases; UTF-16 regex behavior, whole-word boundaries, nonempty-match cap; native bridge sanitizer checks |
| Search replacement transactions | `DiffEditor.replaceAll` | Background preparation, shared regex/line buffers, stale-result rejection, cancellation, CRLF-aware selection mapping and one-batch undo/redo |
| Native find/replace bar | `DiffEditorSearch`, `DiffSearchBar`, viewport match indexes | Query/mode controls, navigation, hidden-match reveal, replacement undo, keyboard dispatch, 400-point layout, rapid typing, stale-session ownership, composition-safe cancellation, invalid replacement ranges and inspected offscreen rendering |
| Demo | Xcode app in this package repository | Release build; 15 example categories and display controls |

## Defaults and native adaptations

Split layout, bars, word-alt inline changes, line-info separators, scrolling
overflow, 1,000-character token/inline limits, 100,000-line document token limit,
and 100-line expansion batches follow the supplied implementation. The actual
renderer defaults collapsed-context threshold to **1**, although a type comment
says 2. File diff generation defaults to four context lines.

Line numbers in diff models are one-based; source array indexes and
`TextPosition` values are zero-based. Character offsets use UTF-16. Empty sides
may have a hydrated hunk index of -1, matching upstream; zero-count slices must
not dereference that index. JavaScript source equality is preserved for diffing
even when Swift considers composed and decomposed Unicode strings equivalent.

DOM nodes, HTML/HAST output, CSS injection, React hooks, SSR, web components and
browser worker transport are platform-specific APIs. AppKit views, CoreText
drawing, SwiftUI adapters and actors provide the corresponding native surfaces.
Their names and signatures intentionally use Swift conventions.

## Remaining parity work

- Finish an export-by-export audit, including parser strict-mode and file-metadata
  edge cases. Generation now exposes the typed nonabortable data options: context,
  ignoreWhitespace, stripTrailingCr and headerOptions. Actors provide asynchronous
  preparation in place of JavaScript's callback transport.
- Gutter selection opt-in/default and disabling during drag are covered; start/change/end/committed callbacks and single-line click-to-clear are covered; controlled proposals, ignored proposals, host acceptance and clearing are tested. Shift-click anchoring follows the upstream directed-range rule, including cross-side endpoint changes and eight same-side forward/reverse cases. Cross-side dragging, unified-order copy, keyboard endpoint movement, and split-column pixel restoration are covered. Default selection highlighting spans both split columns using logical row indexes, including same-side endpoints. Escape cancellation suppresses subsequent drag updates and completion callbacks. Programmatic highlight-side and line-number-only overrides are implemented on NativeDiffView and retained by NativeCodeView across file unmount/remount. Pixel checks verify both gutters remain highlighted while code backgrounds stay unchanged; style-only writes do not commit a new range and changed mouse selections reset overrides. FileDiffView exposes styling for its host-owned selection binding, with demo controls and a verified Release build; physical interaction with these new controls remains unverified. Selection of padding rows and broader cancellation/reentrancy remain. Callback-driven document replacement is guarded at selection start/change, click-to-clear, and end/commit; same-document mutation cases remain under audit.
- Custom AppKit annotation views now mount only in the viewport, measure intrinsic/fitting heights, share the taller split-side height, and update code geometry through a sparse row-height index. Tests cover 1,000 annotations, renderer/document replacement callbacks, tall-row scrolling and click rectangles, ignoring code selection inside annotation rows, restoring default spacing, dynamic height refresh without view recreation, and paired annotation shrinking after resize. FileDiffView now accepts an identity-retained DiffAnnotationRenderer, and the demo has custom SwiftUI-hosted comment cards; Release build verified. Installing wrap plans at two widths preserves measured annotation placement and the next source-line scroll destination in tests. Tests now retain custom controls and draft text across syntax replacement, source-row movement, explicit wrapped plans, and asynchronous native-window resizing at three widths. Offscreen width invalidation, automatic content invalidation, custom multi-file annotation views, and physical interaction/scrolling remain unverified or incomplete. The multi-file adapter supports default per-file annotation rows in both unwrapped and wrapped geometry. Custom gutter renderers, constrained header sizing, and remaining event callbacks also remain. Configurable review sticky headers are implemented, with measured-height scroll-target compensation and custom-header boundary clipping regressions.
- Extend automatic partial-file loading and appearance variants across the
  entire multi-file/editor/streaming surface, including combined hydration and
  theme changes. Single-diff loading and adaptive presentation are implemented.
- Audit wrapped tabs, bidirectional text, variable-width/italic fonts and the
  full native accessibility geometry and selection contract.
- Extend the attached editor's annotation tracking, partial hydration, retained
  session reattachment and external replacement policy. External replacements now update both active and offscreen drafts; same-file
  updates are undoable, while filename/language changes reset history.
- Complete search default-word segmentation parity and remaining focus/input-method
  scenarios. The attached native bar, asynchronous matches, viewport highlights,
  single/all replacement, hidden-match reveal and stale-result rejection are implemented.
  Replacement strings containing isolated surrogate halves are converted to Unicode
  replacement characters by Swift String; raw match offsets retain UTF-16 semantics.
- Native editor word/paragraph navigation is implemented and compared against
  NSTextView, with source-matched Command-Left/Home routing. Full input
  method/candidate-window testing and caret affinity across complex wrapped or
  bidirectional text remain to verify.
- Optimize attached-edit snapshots and viewport updates further. The background
  snapshot still scans current lines; syntax now reuses unchanged prefixes and
  suffixes after full grammar-state convergence. Predictive viewport token updates
  and direct parity with the upstream editor's primitive tokenizer remain.
- Predictive edits, initial editor state transfer, custom selection/caret
  widgets and clipboard-provider callbacks are implemented. See
  EDITOR-INPUT.md, EDIT-PREDICTION.md and EDITOR-HOST-CUSTOMIZATION.md for
  verified behavior and native adaptations. Physical interaction and broader
  editor integration remain to verify.
- Complete streaming/custom-language and rendering-cache lifecycle parity,
  including every upstream preload and reset case.
- Validate every demo flow and sustained fast scrolling on the physical display.
  Offscreen image painting does not measure dropped display frames.

## Local performance evidence

Release build, 1100 × 650 AppKit viewport, on the development machine:

| Scenario | Observed time |
| --- | --- |
| 20,000-line Swift diff, cold two-side highlight | Approximately 1.3–1.5 s |
| Swift distant-jump painting | Usually 4–6 ms; a concurrent build run reached 12 ms |
| 1,141,800-byte JSON, cold diff + two-side highlight | Approximately 3.7–3.9 s |
| Same prepared JSON diff, cached token reuse + inline spans | Approximately 6–8 ms |
| JSON distant-jump painting | Approximately 8–10 ms after color/font reuse; earlier runs 11–12 ms |
| 200 balanced line updates in a 50,000-line editing session | Approximately 109 ms total / 0.54 ms per update, excluding highlighting and painting |
| Attached input, 100 edits in a 20,000-line document | Approximately 6 ms of synchronous input work; asynchronous diff/highlight completion measured separately |
| Incremental syntax after one edit in 20,000 Swift lines | Approximately 56 ms; 64 lines tokenized and 39,938 side-lines reused, including UTF-16 offset adjustment |

The styled viewport cache is bounded to 512 entries / 262,144 UTF-16 units.
Prepared source and token arrays remain resident; token cache memory accounting
is an estimate rather than measured process RSS. Long ASCII lines in a fixed-pitch
font use horizontal fragments; complex-script or proportional-font lines still
require full CoreText shaping. Tests assert bounded work and correctness,
not machine-dependent timing thresholds. These results do not establish a
universal 30 ms cold-preparation guarantee.

A separate 800 × 500 hidden-window check using Menlo measured approximately
1.1 ms total for 100 repeated token-hover events on a 1 MiB ASCII line after the
first hit. Counters verified one token-index construction and one normalized
pointer-source construction. This measures event handling, not display FPS.

## Reproduction

Run `Scripts/diffs/test.sh` for Release checks. Open `swift-diffs.xcodeproj` to build
and run the demo. The package currently depends on sibling `../shiki-swift`.
Oracle generators are in `Scripts/diffs/generate-*-oracle.ts`; they need the supplied
upstream tree, Bun, and pinned jsdiff 9.0.0 for generation only. Large fixture
generators additionally use the local Pierre monorepo's original demo fixtures.

Theme-name equality uses exact UTF-16 in both `DiffThemeNames` and `areThemesEqual`, matching upstream comparison. Registration and lookup still use Swift String-keyed registries (including dependency asset lookup); distinct custom names differing only by Unicode normalization are therefore not yet verified end to end. Do not treat the equality tests as registration parity evidence.

## Separator actions and metadata

The native line-info separators now use source-backed `HunkData` and ordered expansion actions. Leading, middle, and trailing direction availability follows upstream; chunking depends on the original context range even after partial expansion. The trailing-context helper compares both file sides, with 5,184 generated upstream cases covering returned sizes and exact mismatch errors.

AppKit click regressions cover leading expansion, all three middle actions at 180- and 600-point widths, Expand all removal of the gap, and noninteractive simple/metadata styles. Hidden-window separator bitmaps were inspected at both widths, exposing and fixing a clipped count label. Visible-only accessibility custom actions reject stale layout/document state and offscreen rows, verified by invoking handlers directly. Cursor regions use the same visible control geometry.

Remaining: custom separator views; unknown-length partial-file gaps; split-column presentation fidelity; full keyboard focus/navigation; live VoiceOver and cursor behavior; physical scrolling and broad demo fidelity. Current controls are painted canvas targets, not individual native button elements. Do not infer these outstanding behaviors from the handler tests or bitmap inspection.

Integration validation: 203 Release tests across 54 suites passed in 6.708 seconds; the separate Release demo build succeeded. Evidence logs: `/tmp/swift-diffs-separator-integration.log` and `/tmp/swift-diffs-separator-integration-demo.log`.

### Multi-file custom annotation integration

`NativeCodeView.annotationRenderer` and `CodeView(..., annotationRenderer:)` now pass a retained `DiffAnnotationRenderer` to mounted file views. Measured annotation content heights contribute to file offsets. A 100-file regression checks an 80-point comment's offset and bounded renderer calls on a jump to file 90. Release validation: 205 tests in 54 suites passed in 6.535 seconds (`/tmp/swift-diffs-multi-custom-full.log`).

This is initial multi-file integration, not complete variable-height parity: measured row geometry retention across unmount/remount, width changes affecting offscreen comments, and source-anchored outer scrolling during variable-height changes still need coverage and implementation. Live fast scrolling and the reported crash remain unverified while the Mac is locked.

Same-width file remounts now retain sparse measured row heights without retaining annotation NSViews. The cache is cleared on document/options/annotation rerender, renderer replacement, and wrapped-plan installation; remounts at another width do not restore it. A regression measures a comment at line 50, jumps to file 90, returns above the offscreen comment, and verifies the next file offset remains unchanged. All 25 Release annotation tests passed (`/tmp/swift-diffs-retained-heights.log`). Width-dependent outer scroll anchoring and offscreen invalidation remain outstanding.

### Direct versus chunked JSON tokenization

A Release comparison on the same 1,117,782-byte JSON source using separate Shiki engines and `github-dark` measured 1.2232 seconds for direct `codeToTokens` and 1.2594 seconds for `SharedTokenChunks`. Every resulting token matched. This single-run comparison isolates chunking overhead from the much larger full-source tokenization cost; it is not the demo's complete preparation latency or a cross-theme performance guarantee. Log: `/tmp/swift-diffs-json-direct-comparison.log`. The 30 ms requirement remains unproven for cold fully highlighted content. Further work should investigate progressive syntax delivery and the Shiki tokenization path rather than assume the rendering viewport or chunk cache causes the cold delay.

### Bounded highlighted previews

`preparePreview(..., highlightedLineCount:)` optionally highlights a complete source prefix with the real Shiki grammar, capped at 256 lines and 65,536 UTF-16 units per side. Partial patches remain unhighlighted. The default remains zero. The demo publishes plain preview, 64-line highlighted preview, and complete highlighting in sequence with one source identity. Tests verify prefix equality with complete tokens across multiline comments, emoji and CRLF, and skip oversized first lines. Five Release preview tests passed, including two benchmark cases; the Release demo build passed. Logs: `/tmp/swift-diffs-highlighted-preview.log`, `/tmp/swift-diffs-prefix-demo.log`.

This does not establish 30 ms startup: the concurrent test-run observations were 74 ms for plain preparation and 122 ms for prefix preparation, and are not isolated latency measurements. This is prefix delivery, not destination-viewport prioritization; source content below the prefix stays plain until full highlighting finishes. Live visual validation remains pending.

### Unknown trailing partial context

`DiffRenderPlan(..., canHydrateContext: true)` now appends an unknown trailing separator for partial change/rename-changed files using line-info styles, matching upstream `DiffHunksRenderer.ts` conditions. `HunkData` reports zero numeric lines with `lineCountKnown == false` and upward expansion. Native views pass loader availability to ordinary and wrapped plans and render the upstream unknown-context message. New/deleted/pure-rename files and simple/metadata styles do not receive this row. Six separator tests and the full 209-test, 54-suite Release run passed in 6.587 seconds (`/tmp/swift-diffs-unknown-context-full.log`). Live loading interaction and split-column separator presentation still need validation.

The AppKit hydration transition is now covered with a suspended loader: adding the loader displays the unknown trailing row and its accessibility action; completing it with full EOF contents removes both, rejects the retained stale action, and preserves selected text. All five Release loader/theme tests passed (`/tmp/swift-diffs-unknown-context-hydration.log`). This is programmatic AppKit validation, not manual UI or VoiceOver validation. The latest live UI attempt still reported a locked Mac.

### Multi-file layout defaults audit

Current upstream `constants.ts` defines `DEFAULT_CODE_VIEW_LAYOUT` as top padding 8, bottom padding 8, gap 8. `CodeView.ts` applies padding as container margins (1037–1040), starts subsequent files after a gap (1699–1718), and excludes a trailing gap from content extent. Native `CodeView.swift` instead adds 12 points after every file, starts at zero, and imposes a 76-point minimum file height. This is a confirmed parity gap, not an intentional verified adaptation. Correcting it requires one consistent layout model across initial and wrapped offsets, scrollToFile, destination mounting, annotation measurements, expansion callbacks and anchor restoration. Do not change the unrelated 12-point text inset at the wrapping calculation. Native header preferred height is 38; upstream's virtual header estimate is 44, which needs distinction from measured DOM header height before changing the native header itself.

The layout discrepancy above is now corrected through public `CodeViewLayout` on both native render and SwiftUI initializer: defaults 8/8/8, no trailing inter-file gap, no 76-point minimum. Initial and wrapped offsets, scroll destinations, expansion and annotation measurements use the layout. Custom 17/23/11 and 5/7/3 geometry tests cover total extent and preserving the selected file on layout replacement. Existing destination-mounting and hover tests were updated for the smaller files and outer padding. All 211 Release tests in 54 suites passed in 6.493 seconds (`/tmp/swift-diffs-review-layout.log`); the Release demo build succeeded (`/tmp/swift-diffs-review-layout-demo.log`). Native header measurement still uses its current AppKit intrinsic sizing; full header styling and live layout validation remain outstanding.

### Cancellation for identical large files

Complete identical sources with at least 256 lines now tokenize through 64-line grammar-state chunks with a zero-capacity reuse cache. This preserves cancellation checkpoints without allocating a redundant cross-side cache; the complete result is still shared between sides. The five chunk tests passed, including embedded/multiline grammar and megabyte JSON equality with direct Shiki. A warmed-engine test schedules a 30,000-line identical JSON preparation, cancels after 50 ms, and prepares a small replacement; it observed 1.33 ms from cancellation request through replacement completion, with only the replacement in the token cache (`/tmp/swift-diffs-cancel-replace.log`). This single-run scheduling test is not a guaranteed cancellation latency or proof of physical UI responsiveness.

Multi-file width changes now invalidate retained annotation geometry and reset measured heights on affected mounted files. Only previously measured/mounted files are visited; offscreen annotation views are not created. A regression measures a 160-point card at width 600, resizes while that card is offscreen, verifies the old measurement is discarded, and observes the 80-point height when revealed at width 1000. The current file/row is used to restore the outer position during invalidation; exact pixel anchoring inside a resized variable-height card still needs coverage. All 213 Release tests in 54 suites passed in 6.577 seconds (`/tmp/swift-diffs-annotation-width-full.log`).

Resize anchoring now keeps the pre-resize offset inside the current row until mounted measurements settle, then restores that offset against the new height (clamped only when the row becomes shorter). Explicit file jumps and document renders discard the pending anchor. A real AppKit-window regression starts 50 points inside a custom comment and preserves that position across 600→1000→600 point widths. All 27 Release annotation tests passed (`/tmp/swift-diffs-comment-anchor.log`). Combined asynchronous wrapping with variable-height comment anchoring and physical live scrolling remain unverified.

Asynchronous multi-file wrapping now locates the old row through measured geometry, maps it by source/annotation identity into the replacement plan, then restores the saved in-row offset after measurement. A custom-card test with a long wrapped line before the comment preserves a 50-point offset across 600→1000→600 widths. All 215 Release tests in 54 suites passed in 6.609 seconds (`/tmp/swift-diffs-wrap-integration.log`), and the current Release demo build succeeded (`/tmp/swift-diffs-wrap-integration-demo.log`). These checks cover programmatic AppKit layout; physical scrolling and the original crash remain unverified.

Settled wrapped review appends now retain existing prefix plans, mounted views and sparse measured heights while wrapping only new files. Prefix reuse is restricted to the same width; pending or superseded layouts retain the general rebuild path. The append regression passes for both scroll and wrap overflow, preserving edited comment text, control identity and viewport position after adding 99 files. All 216 Release tests in 54 suites passed in 6.434 seconds (`/tmp/swift-diffs-wrapped-append-full.log`).

Review-level header/footer NSViews now live outside file rows and contribute measured height to file origins and scroll extent, matching the upstream host-height accounting. `invalidateReviewChromeLayout()` requests remeasurement after intrinsic content changes; width changes remeasure automatically. Changing the header height preserves the current file offset, and removing either view detaches it. Both NativeCodeView and SwiftUI CodeView expose the views, and the demo has a review header/footer toggle. Six header tests and all 217 Release tests in 54 suites passed in 6.618 seconds; demo build succeeded (`/tmp/swift-diffs-review-chrome-full.log`, `/tmp/swift-diffs-review-chrome-demo.log`). Live visual validation remains pending.


### Bracket matching, surrounding, focus and adaptive streams

The native editor now matches adjacent brackets outside string/comment/regex
tokens, with upstream limits of 1,000 lines and 50,000 UTF-16 characters. It
caches matches on selection/syntax changes, not during scrolling. Initial and
updated syntax arrives through the existing asynchronous tokenizer; pending
revisions suppress stale bracket highlights. Full, chunked and incremental
highlighting expose token classifications consistently.

Typing the standard opening bracket or quote over selected text retains the
inner selection and records one undo step. `AutoSurround` follows upstream's
five modes, including the current languageDefined/default equivalence. Explicit
NSTextInputClient replacement ranges and marked-text commits retain native
replacement behavior. The demo exposes matching and surrounding in Typing.

Independent `setEditorActiveLine` state now coexists with selected line ranges,
including side and gutter-only options. Native focus supports numeric source
lines, first-visible lines, offsets, preventScroll, blur and focus callbacks.
Automated window checks cover source positioning, fixed-scroll focus and a
callback that suspends the editor. These are not physical keyboard/IME tests.

Adaptive streaming caches light/dark snapshots from one consumed source.
Appearance changes preserve source identity and selected text and do not emit
new stream token events. System appearance uses AppKit. The native adaptation
keeps token callbacks on the light tokenizer; browser CSS-variable token variants
are not its return type. The Managed stream demo exposes an Appearance picker.

Multiple local editor carets, grouped history, predictive edits and complete
view-state/selection-action integration remain open. The original scroll crash
has not been reproduced or tied to a crash report.
