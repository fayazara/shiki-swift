# Upstream export module audit

Source: supplied @pierre/diffs 1.4.2 checkout. This inventory records the root re-export modules, not verified behavioral parity. Named exports, subpath exports, overloads, and cross-feature behavior still require review.

| Root re-export module | Audit status |
| --- | --- |
| `./components/CodeView` | Native presentation, bounded file mounting, custom annotations, and retained measured heights exist. Configurable CodeViewLayout now drives top/bottom padding, inter-file gap, scroll targets, total extent, wrapped-plan replacement, expansion and measurement updates. Full method/options mapping pending. |
| `./components/File` | Reviewed native props, callbacks and component operations in COMPONENT-CONTRACTS.md; inherited base options remain separately tracked. |
| `./components/FileDiff` | Reviewed native props, callbacks and component operations in COMPONENT-CONTRACTS.md; inherited base options remain separately tracked. |
| `./components/FileStream` | Native actor FileStream appends/closes into stable-identity HighlightedDiff snapshots. Direct and configured light/dark palettes, custom languages/themes, concurrent append/close, and closed-stream rejection are tested. The demo renders snapshots through FileView. Full upstream component method/options mapping remains pending. |
| `./components/UnresolvedFile` | NativeUnresolvedFileView now owns UnresolvedFileState, immediate marker/source updates, async highlighting, automatic/controlled action modes, pure resolution, stale-action rejection, and reusable cleanup. Existing NativeDiffView/FileDiffView and themed adapters still accept host-owned markers and actions. Native component lifecycle tests cover source replacement and late results. UnresolvedFileView supplies a SwiftUI coordinator retaining resolutions across display updates and source echoes, and the demo uses it. Full upstream lifecycle/event parity and interactive verification remain pending. |
| `./components/VirtualizedFile` | Native presentation exists; full method/options mapping pending |
| `./components/VirtualizedFileDiff` | Native presentation exists; full method/options mapping pending |
| `./components/Virtualizer` | Native presentation exists; full method/options mapping pending |
| `./constants` | Native defaults match line height 20, header height 44 at default font metrics, context threshold 1, tokenizeMaxLineLength 1,000, tokenizeMaxLength 100,000, Pierre themes, and CodeViewLayout 8/8/8. Verified against constants.ts and renderer defaults; the two tokenization limits are distinct. Other exported constants still require individual disposition. |
| `./highlighter/languages/areLanguagesAttached` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/languages/attachResolvedLanguages` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/languages/cleanUpResolvedLanguages` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/languages/constants` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/languages/getResolvedLanguages` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/languages/getResolvedOrResolveLanguage` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/languages/hasResolvedLanguages` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/languages/registerCustomLanguage` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/languages/resolveLanguage` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/languages/resolveLanguages` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/shared_highlighter` | Partial: shared actor, getSharedHighlighter, isHighlighterLoaded, settings-aware getHighlighterIfLoaded, and concurrent preload exist. Disposal releases the engine and caches while preserving registered sources; stale asynchronous attachment is cancelled using lifecycle generations. Explicit loading/null state helpers and engine preference mapping remain unmapped. |
| `./highlighter/themes/areThemesAttached` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/attachResolvedThemes` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/cleanUpResolvedThemes` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/constants` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/getResolvedOrResolveTheme` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/getResolvedThemes` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/hasResolvedThemes` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/registerCustomCSSVariableTheme` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/registerCustomTheme` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/resolveTheme` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./highlighter/themes/resolveThemes` | Reviewed native adaptation; see RESOURCE-RESOLVER-CONTRACTS.md for per-export cache, registration, attachment, concurrency and platform contracts. |
| `./managers/InteractionManager` | Native DiffInteractionHandlers and DiffCanvas implement line/token click and hover, controlled selection, selection styling, default/custom gutter controls, and stale/reentrant callback guards. DiffInteractions.swift and InteractionTests cover these paths. Split padding selection and complete method/options parity remain unverified. |
| `./managers/ResizeManager` | Partial native mapping: viewport layout recalculates column geometry; paired annotations share the maximum measured height, width changes invalidate measurements, and removed views are detached. Mounted annotation frame-size changes automatically invalidate cached measurements; position-only changes and layout-owned sizing are ignored. Intrinsic-size-only content changes still require `invalidateAnnotationLayout()` rather than a complete ResizeObserver equivalent. DOM CSS-variable apply/measure modes have no exported native counterpart. |
| `./managers/ScrollSyncManager` | Native adaptation: one NSScrollView owns both columns; painting, token geometry, and hit testing use the same horizontal offset. No paired DOM listeners or 300 ms suppression timer is necessary. Forward/backward split-column token geometry regression passes; trackpad momentum/frame pacing remains unverified. |
| `./managers/UniversalRenderingManager` | Pending semantic mapping |
| `./renderers/DiffHunksRenderer` | Native adaptation spans DiffHighlighter.prepare, DiffRenderPlan, DiffWrapLayout, and DiffCanvas. Inline spans, context expansion, custom separators, EOF markers, and conflict rendering have regression coverage. The token-wrapper switch maps to native token interaction geometry (see Token transformer native adaptation below). Public HTML/AST output and complete renderer method/options parity remain unmapped. |
| `./renderers/FileRenderer` | Native preparation plus NativeFileView/FileView adapt highlighted single-file presentation, annotations, gutters, and headers. The token-wrapper switch maps to native token boundaries and geometry; HTML output and full public renderer method/options mapping remain pending. |
| `./shiki-stream` | `ShikiStreamTokenizer` maps stable/unstable buffers, recall counts, enqueue, close, clear and clone. Clones share a synchronized stable buffer as upstream does, while pending text and grammar state branch; clear detaches only that branch. FileStream owns its tokenizer state on the same actor so append/close snapshots cannot interleave. `CodeToTokenTransformStream` adapts an AsyncSequence of chunks into token/recall events, with pull-based consumption, final flush, errors and cancellation tested. Each iterator owns its tokenizer rather than exposing a DOM TransformStream's readable/writable endpoints. StreamTokenizerConfiguration now forwards native TokenizeWithThemeOptions through tokenizers, clones, FileStream and AsyncSequence transforms. Registered resources and options are tested; JavaScript-only Shiki option semantics still need explicit disposition. |
| `./sprite` | DiffSymbol.swift contains AppKit vector paths generated from upstream sprite.ts by Scripts/diffs/generate-native-symbols.py, used by headers, expansion and gutter controls. The sprite string/SVG API has no public native counterpart; visual behavior is partially verified. |
| `./utils/annotationHelpers` | Implemented with FileLineAnnotation and EditorAnnotation.file/diff preserving shape independently of rendered side. Empty collections satisfy both predicates; nonempty collections inspect only the first element. renderedAnnotation adapts to existing native APIs while retaining IDs, text, line positions, and metadata identity. Native file editor completion now exposes side-less fileAnnotations/originalFileAnnotations with isFile, alongside the shared rendered arrays. Session currentFileAnnotations and review-item fileAnnotations preserve shape and metadata identity; 23 attached-editor tests pass, including install/discard/removal and source-line movement (`/tmp/swift-diffs-file-annotation-completion.log`). Upstream explicitly requires homogeneous collections (`LineAnnotation[] | DiffLineAnnotation[]`); mixed shapes are not a promised editor input contract. Native file sessions accept explicit replacements through setFileAnnotations, and diff sessions reject that file-specific operation. |
| `./utils/areDiffLineAnnotationsEqual` | Native helper compares line, side, and strict metadata; object identity plus explicit primitive metadata. Focused regression coverage in AnnotationEqualityTests. |
| `./utils/areDiffRenderOptionsEqual` | Implemented over RenderDiffOptions: exact themes, transformer flag, tokenization limit, inline mode, and inline length limit. Dedicated input records preserve numeric NaN/signed-zero semantics; native token boundaries are retained independently of the HTML wrapper flag. |
| `./utils/areDiffTargetsEqual` | Implemented using retained DiffTarget wrappers around value metadata. Exact UTF-16 cache keys take precedence; otherwise wrapper identity, including nil/nil. Release tests cover equal content with distinct identity, absent/empty keys, and Unicode spelling. Existing view revision IDs remain their separate native lifecycle. |
| `./utils/areFileRenderOptionsEqual` | Implemented over RenderFileOptions: compares only exact theme selection, useTokenTransformer, and tokenizeMaxLineLength. Focused Release tests cover exact Unicode names, transformer changes, NaN, and signed zero. |
| `./utils/areFilesEqual` | Public native helper compares cache key, contents, name, and language using exact UTF-16; ignores header as upstream does. Tests cover nil, each field, header exclusion, and canonical Unicode differences. |
| `./utils/areHunkDataEqual` | HunkData.swift preserves all upstream fields, exact slot-name code units, and absent-versus-disabled expansion flags. DiffSeparatorRenderer now integrates visible custom slots into native, themed, editable, and multi-file views; metadata retention and stale action tests exist. |
| `./utils/areLineAnnotationsEqual` | Native helper compares line and strict metadata, excluding native ID/text fields. Focused regression coverage in AnnotationEqualityTests. |
| `./utils/areObjectsEqual` | Pending semantic mapping |
| `./utils/areOptionsEqual` | Pending semantic mapping |
| `./utils/arePrePropertiesEqual` | Pending semantic mapping |
| `./utils/areRenderRangesEqual` | Optional native range equality compares all four fields; focused nil and per-field regressions. |
| `./utils/areSelectionsEqual` | Public optional LineSelection comparison preserves endpoint direction and explicit endSide. Public initializer retains supplied values; native gesture construction omits matching endSide as upstream InteractionManager does. |
| `./utils/areThemesEqual` | Public helper over DiffThemeSelection preserves single/adaptive form distinction and exact UTF-16 comparison of names. Focused nil, field, form, and Unicode regressions; render options continue using their existing theme APIs. |
| `./utils/areVirtualWindowSpecsEqual` | Optional native window equality compares top and bottom; focused nil and coordinate regressions. |
| `./utils/areWorkerStatsEqual` | Pending semantic mapping |
| `./utils/cleanLastNewline` | Native Models.swift; exhaustive short CR/LF/combining-mark strings checked against UTF-16 rules |
| `./utils/cloneFileDiffMetadata` | Native FileDiffMetadata, Hunk, and HunkContent use Swift value semantics with copy-on-write arrays/strings; assigning a value provides independent mutation. No same-named clone helper is exported. A field-by-field clone contract audit remains pending. |
| `./utils/createAnnotationElement` | Pending semantic mapping |
| `./utils/createAnnotationWrapperNode` | Pending semantic mapping |
| `./utils/createEmptyRowBuffer` | Native DiffCanvas.drawEmptyCell draws a cached 8-by-8 diagonal tile in the code area and a separate neutral gutter. This adapts visual behavior, not the HAST constructor API. Broader pixel parity remains unverified. |
| `./utils/createFileHeaderElement` | Native DiffHeaderView supplies upstream vector symbols, filename/counts, retained custom slots, custom replacement headers, and measured heights. HeaderTests cover layout/lifecycle. HAST element construction is not exposed. |
| `./utils/createGutterUtilityContentNode` | Native default gutter control and DiffGutterRenderer/FileGutterRenderer/CodeViewGutterRenderer provide default/custom content. Live target, retained control, and callback regressions exist. DOM node return values have no native equivalent. |
| `./utils/createGutterUtilityElement` | Native DiffCanvas mounts one retained gutter utility and updates its visible target; selection, hover, drag, and stale target handling are tested. DOM wrapper API is not exported. |
| `./utils/createNoNewlineElement` | Native EOF metadata rows: affected split column, striped empty partner, per-side unified placement, context/change styling, plain upstream label at 60% opacity. Row ordering and estimates covered by NoNewlineLayoutTests. |
| `./utils/createPreElement` | Pending semantic mapping |
| `./utils/createRowNodes` | Pending semantic mapping |
| `./utils/createSeparator` | Native line-info, line-info-basic, metadata, simple, and custom modes exist. Row-height estimates, source-faithful visibility, directional actions, custom per-column metadata and measurement are covered by UpstreamVisualLayoutTests and SeparatorRendererTests. No HAST constructor is exported. |
| `./utils/createSpanNodeFromToken` | Pending semantic mapping |
| `./utils/createStyleElement` | Pending semantic mapping |
| `./utils/createTransformerWithState` | Pending semantic mapping |
| `./utils/createUnsafeCSSStyleNode` | Pending semantic mapping |
| `./utils/createWindowFromScrollPosition` | Public native helper; seven finite boundary cases checked against executing local upstream, including fractional positions, overscroll, short documents, and fit-perfectly mode. Integrated into NativeCodeView mounting; SwiftUI CodeView exposes overscrollSize and the multi-file demo has a neighboring-file preparation toggle. A 1,000-file regression verifies bounded mounting and position preservation. |
| `./utils/cssWrappers` | Pending semantic mapping |
| `./utils/detachString` | Pending semantic mapping |
| `./utils/diffAcceptRejectHunk` | Resolution.swift exposes diffAcceptRejectHunk, including optional changeIndex and partial-patch behavior. ResolutionParityTests compare upstream-generated fixtures; malformed metadata and complete error parity still require audit. |
| `./utils/formatCSSVariablePrefix` | Implemented exact global/token prefixes with CSSVariablePrefixType. Import/export utility only; no CSS cascade implied. |
| `./utils/getFiletypeFromFileName` | Native Languages.swift; cached regex captures use UTF-16, tested custom override/version and compound-extension precedence, including combining marks; complete filename corpus pending |
| `./utils/getHighlighterOptions` | Pending semantic mapping |
| `./utils/getHighlighterThemeStyles` | Pending semantic mapping |
| `./utils/getHunkSeparatorSlotName` | HunkData.swift exports getHunkSeparatorSlotName with type/index-based upstream naming; used by the custom separator mount cache. HunkDataTests cover metadata. |
| `./utils/getIconForType` | Native DiffHeaderView chooses generated DiffSymbol artwork by file/change type. No public same-named SVG-symbol-name helper exists; public API disposition remains pending. |
| `./utils/getLineAnnotationName` | Pending semantic mapping |
| `./utils/getLineEndingType` | Native Streaming.swift; exhaustive short CR/LF/combining-mark strings checked against UTF-16 rules |
| `./utils/getLineNodes` | Pending semantic mapping |
| `./utils/getOrCreateCodeNode` | Pending semantic mapping |
| `./utils/getSingularPatch` | Streaming.swift exports getSingularPatch and rejects results other than one patch containing one file. Complete upstream error-message/input-edge parity remains unverified. |
| `./utils/getThemes` | Pending semantic mapping |
| `./utils/getTotalLineCountFromHunks` | Native PatchUtilities.swift; prefix/UTF-16 and last-hunk boundary tests |
| `./utils/hast_utils` | Pending semantic mapping |
| `./utils/hydratePartialDiff` | Value-returning clone and `inout` merge overloads using `LoadedDiffFiles`; pure rename preserves geometry. Both modes match 328 upstream-generated fixtures, including 14 rejections. Native validation additionally rejects truncated loaded files atomically; required new-file presence is enforced by the Swift API. |
| `./utils/isDefaultRenderRange` | Pending semantic mapping |
| `./utils/isWorkerContext` | Pending semantic mapping |
| `./utils/lineAnnotationIdentity` | Pending semantic mapping |
| `./utils/parseDiffDecorations` | Pending semantic mapping |
| `./utils/parseDiffFromFile` | DiffAlgorithm.swift exposes parseDiffFromFile with DiffOptions and jsdiff-compatible sequence/header behavior. FileDiffParityTests and generated diff/options fixtures cover substantial input cases; not a blanket proof of all edge cases. |
| `./utils/parseLineType` | Native PatchUtilities.swift; prefix/UTF-16 and last-hunk boundary tests |
| `./utils/parsePatchFiles` | PatchParser.swift exposes parsePatchFiles, processPatch, and processFile, with strict/tolerant modes and cache-key prefixes. PatchParityTests compare upstream-generated fixtures. Complete malformed-patch/error parity remains pending. |
| `./utils/prefersReducedMotion` | ReducedMotion.swift maps the helper to NSWorkspace.accessibilityDisplayShouldReduceMotion. NativeCodeView uses it to bypass smooth animation; the preference itself remains OS-owned. |
| `./utils/prerenderHTMLIfNecessary` | Pending semantic mapping |
| `./utils/processLine` | Pending semantic mapping |
| `./utils/renderDiffWithHighlighter` | Pending semantic mapping |
| `./utils/renderFileWithHighlighter` | Pending semantic mapping |
| `./utils/resolveConflict` | MergeConflicts.swift exposes resolveConflict using parsed MergeConflictDiffAction; UnresolvedFileState installs source changes. ConflictParityTests cover upstream conflict-resolution fixtures. Complete component callback/lifecycle parity remains pending. |
| `./utils/resolveRegion` | Resolution.swift exposes resolveRegion and indexesToDelete, preserving remaining hunk structure. ResolutionParityTests and conflict-resolution fixtures cover normal/partial cases. Malformed metadata and complete error parity remain unverified. |
| `./utils/setLanguageOverride` | Native Languages.swift overloads inspected; value-copy language override |
| `./utils/setWrapperNodeProps` | Pending semantic mapping |
| `./utils/trimPatchContext` | TrimPatchContext.swift exports the native implementation. PatchParityTests compare trim-oracle.json produced from upstream; further fuzz/error coverage is not implied. |
| `./types` | Pending semantic mapping |

Named source inventories for all package entry points are now in `upstream-api-inventory.json` (see NAMED-API-AUDIT.md); native contract mapping remains pending for: `edit`, `react`, `ssr`, `worker`, `worker/worker.js`, and `worker/worker-portable.js`. Root Shiki re-export `codeToHtml` requires an explicit native-platform disposition. `createCSSVariablesTheme` now returns the raw Shiki theme with CSS expressions; `createResolvedCSSVariablesTheme` supplies the separate AppKit color adapter (see registration row above).

Current completion gates are tracked in COMPLETION-CHECKLIST.md. The historical notes below record earlier work and may describe gaps closed by the current module table; neither a mapped row nor a passing fixture suite proves full 1:1 parity.

## Cache and registration audit

`DiffHighlighter.prepare` resolves each side's language before looking up tokens.
Both normal token keys and incremental editor keys contain the resolved language.
A mapping change therefore chooses a different cache entry; explicit `FileContents.lang`
continues to take precedence. The CustomLanguageTests regression checks text → Swift →
text on the same actor and an explicit Swift override after the mapping changes.
`registerLanguage` and `registerTheme` call `clearCache`, which clears token entries
and incremental editor documents. Replacement-grammar and replacement-theme behavior
still needs direct regression coverage.

Language loader registration, shared loading, failure retry and reserved names now have
native APIs and lifecycle tests. Theme loader registration is also implemented with normalized colors and name
validation. Resolved/attached state inspection and cleanup are implemented; LazyLanguageTests and LazyThemeTests cover their separate lifecycles. Registration is owned by each native
highlighter; extension mappings remain process-wide.

Language attachment now validates requested names/aliases before batch registration; tests include an alias referencing a second returned grammar, missing aliases, and empty results.

Late-injection coverage: warm normal and incremental editor caches, attach a grammar targeting an already registered language, then verify both paths use the injected token. Broad language cache invalidation is intentional until dependency-aware invalidation exists.

Demo coverage: Custom language exercises extension-mapped lazy grammar registration through the normal diff flow. Release build verified; on-screen interaction remains part of the demo validation pass.

## CodeView method-level findings

The supplied `components/CodeView.ts` exposes ID-based get/update/rename/add/remove/set item methods, editor access, review header/footer rendering, selection getters/clear, scroll targets, scroll subscriptions, rendered-item inspection and lifecycle reset/cleanup. NativeCodeView currently exposes array rendering, index-based scroll/selection, headers per file, custom annotations and layout. These are not yet full method parity. The native array renderer now preserves visible views when appending unchanged unwrapped files; ID-based item management and mixed file/diff/editor items remain outstanding. Review-level header/footer NSViews are now exposed with measured heights and explicit invalidation; callback/portal forms are adapted to retained native views. Settled wrapped appends now reuse prefix plans and retain mounted prefix views. An annotation test appends 99 files and retains an edited NSTextField and its parent view without rerendering it (29 Release annotation tests passed, `/tmp/swift-diffs-review-append.log`). Empty-to-empty header staging now skips invalidation, so the default SwiftUI update sequence can use this append path. The regression stages empty headers before both renders and preserves the same edited control (`/tmp/swift-diffs-swiftui-append.log`). Custom header staging and appends during unfinished wrapping still use the fallback path; a live SwiftUI interaction is not yet verified.

NativeCodeView exposes line and range navigation by item ID or file index, with instant or smooth behavior. It resolves the destination plan without mounting intervening files; pending wrapped layouts defer valid requests. Hidden lines in full-file context gaps target their separator without expanding it, matching `VirtualizedFileDiff.getLinePosition` and `CodeView.getRangeScrollPosition`. Separator metadata includes both source ranges and accounts for partial expansion. Missing endpoints still reject navigation. The regression covers leading/trailing gaps, both sides, reversed ranges, smooth targets, unchanged document extent, and partially expanded gap metadata. All 273 Release tests in 58 suites passed (`/tmp/swift-diffs-hidden-scroll-full.log`). Fully collapsed file navigation now resolves to the zero-height header boundary without expanding, including positive out-of-bounds line numbers, matching upstream. Diff items without hunks remain unresolved; single-file items accept any positive target. Expanded single-file targets clamp beyond EOF to the final logical line, preserving its full wrapped span; empty files resolve to the zero-height header boundary. The 11-test scrolling suite passes, including wrapped deferred targets, smooth EOF targets, side-independent file ranges, and exact empty-file geometry (`/tmp/swift-diffs-file-scroll.log`). Parsed-patch hidden targets now resolve from separator source-coordinate ranges, including unequal old/new line numbers after insertions. Split and unified regressions cover leading and inter-hunk gaps, cross-side smooth range targets, and rejection beyond the final known hunk. Review sticky headers now have an explicit opt-in, with measured-height compensation for line/range start and nearest navigation. Absolute-position sticky compensation now follows upstream clamping order; unwrapped viewport/chrome layout preserves animation velocity and rebases its current position by anchor corrections. Wrapped reflow pauses integration, retains source-line targets, and remaps them after the latest layout completes; stale document revisions cancel range targets. Continuous live resize and display pacing still need runtime validation.

Line navigation accepts `align: CodeViewScrollAlignment` (start/center/end/nearest) and `offset:` using the upstream alignment formulas, including nearest no-op behavior and center-to-start fallback for tall targets. Wrapped lines use their full row span. Alignment, smooth range targets, and deferred wrapping are covered by the current scrolling regression suite. Line/range and absolute-position sticky-header compensation are implemented; file targets bypass position compensation to avoid applying it twice.

Deferred line targets now survive pending/superseded wrapping and resolve only against the final layout. The latest valid request wins; invalid requests do not discard it, and replacing the review clears stale targets. Tests cover width replacement, a later line target, an invalid file jump and replacement with an empty/new review. All 220 Release tests in 54 suites passed in 6.674 seconds (`/tmp/swift-diffs-deferred-line-full.log`).

NativeCodeView now exposes `scrollToRange(_:inFileAt:align:offset:)`, using the union of both endpoint line spans as upstream does. Reversed and cross-side endpoints are supported; valid ranges use the existing deferred wrapping target path. Missing endpoints leave the viewport unchanged. Focused Release navigation validation is recorded in `/tmp/swift-diffs-range-navigation.log`; live scrolling and full scroll-target parity remain unverified.

Range target lookup now scans rows once without allocating endpoint index arrays. A deferred reversed cross-side range regression changes width before wrapping completes, checks the full final endpoint height with end alignment, and ensures an invalid subsequent range does not discard the valid pending target. All 222 Release tests in 54 suites passed in 6.924 seconds (`/tmp/swift-diffs-range-full.log`).

Scroll observation: NativeCodeView exposes `scrollTop` and `subscribeToScroll`, returning an idempotent cancellation closure that weakly references the view. Subscribers receive native clip-bounds changes and the review instance; subscription itself does not fire an initial event. Notifications use a key snapshot so listeners can remove registrations while dispatching. Selection audit: upstream retains one review-level selected range (`getSelectedLines` / `clearSelectedLines`), whereas native selections are currently retained per file. Whole-review selection ownership remains a parity gap; adding getters alone would not close it.

Scroll subscription validation: 11 Release window tests passed (`/tmp/swift-diffs-scroll-observation.log`). Coverage verifies no initial delivery, programmatic navigation coordinates, independent/idempotent cancellation, sender identity and view deallocation after draining AppKit autoreleases even while cancellation closures remain retained.

Review selection ownership now clears prior file selections when a new file is selected, including offscreen retained state. `selectedLines` exposes the active index and range; `clearSelectedLines(notify:)` clears it. Mounted callbacks ignore replaced views and suppress recursive ownership changes while clearing the previous view. The index-based API is still distinct from upstream item IDs, and item-update selection preservation remains part of that outstanding work. Focused window regressions cover mounted-to-offscreen movement, remounting, clearing and child-view selection changes.

Array review reconciliation now remaps retained selection, expansion and scroll anchors by unique HighlightedDiff sourceID when files move or surrounding files change. Render invalidation and append eligibility compare source IDs as well as render IDs. Ambiguous repeated sources retain positional compatibility when the file sequence matches; source identity remains distinct from the outstanding explicit upstream item-ID API. Remapping uses grouping and a destination set rather than repeated linear destination scans.

Explicit prepared-diff item API: CodeViewItem carries a caller-owned String ID, HighlightedDiff and annotations. NativeCodeView exposes getItem/setItems/addItem(s)/updateItem/removeItem/updateItemID and range navigation by ID, plus selectedItemLines. IDs compare exact UTF-16 sequences. Duplicate sets/appends throw before state mutation; missing update/removal returns false. Renaming preserves logical source identity without rerendering. Item reconciliation disables filename fallback, so removing a selected ID cannot transfer its selection to a different item with the same filename. Calling the array render API with different content exits item mode. Mixed plain-file/editor item variants, instance retention on arbitrary reconciliation, item-specific options, editor lifecycle and full callback parity remain outstanding.

Pending item navigation is now carried across setItems using the previous caller-owned item ID. Renaming updates that identity before reconciliation; a moved target is requeued against its new index and final wrapping width. A navigation revision prevents restoration from replacing a newer request issued during callbacks. Missing target IDs are not restored. The regression combines 100 items, a queued end-aligned range with offset, rename, replacement/reordering and width change before wrapping settles.

Mixed prepared file/diff review foundation: CodeViewItem optionally carries original FileContents. Like NativeFileView, file items require a prepared single-file document and use unified, fully expanded rendering with original file header metadata. Per-item options now drive row counts, line targets, mounted rendering and asynchronous wrap widths. File-kind/metadata changes invalidate presentation even if prepared IDs are unchanged. File-specific interaction/header callback adapters, editor sessions and raw-input preparation remain outstanding; this is not full mixed-item API parity.

Mixed review file callbacks: NativeCodeView now exposes FileHeaderRenderers and FileInteractionHandlers, adapting original FileContents for mounted file items while diff items keep their diff handlers. Callback replacement refreshes mounted views; offscreen programmatic selection uses the appropriate file/diff callback. Review hover tracking accounts for both handler families. SwiftUI item input, embedded editor lifecycle and full upstream per-item callback context remain outstanding.

SwiftUI CodeView accepts ID-based items, file header/interaction callbacks and an optional onItemError callback. Invalid duplicate updates preserve the prior review. Empty file-header staging skips invalidation to preserve append reuse. The demo multi-file review now uses item IDs derived from its unique module paths and places annotations on each item. Mixed-file example content, embedded editor sessions and remaining root/subpath parity are still outstanding.

Editor virtualization foundation: DiffEditor.suspend cancels pending presentation and detaches its viewport while retaining text, selection, annotations, search session and undo history. NativeDiffView.resumeEditing reattaches only an active suspended session with the same logical source. Offscreen edits remain in the text model and resume schedules current rendering. A regression caught NativeDiffView ignoring sourceID-only changes; render/hydration invalidation now checks both prepared and source IDs. Review-level editor records, completion while suspended, external item synchronization and IME/runtime validation remain outstanding.

Review editor lifecycle foundation: beginEditingItem mounts the requested item and starts an addition-side DiffEditor; getEditor returns its active session by exact item ID. Sessions are retained by logical source separately from views, suspend on viewport removal, reattach on remount, survive ID renaming and retire on item removal. Completion/install propagation into review items, suspended completion, edited-file metrics during wrapping, full file editor semantics and demo controls remain outstanding.

Review completion: completeEditingItem installs accepted prepared edits and mapped annotations into the item record, updating original file contents for file items; discard preserves the previous record. DiffEditor.complete now supports suspension and checks a completion generation plus attachment identity before/after callbacks. Review-managed sessions default to accepting explicit install completion; custom completion handlers can reject it. Item/session identity is rechecked after awaiting so removed/replaced records are not overwritten. Call completeEditingItem for managed review persistence; direct editor.complete does not reconcile the parent record. Controlled SwiftUI item write-back and demo completion controls remain outstanding.

SwiftUI completion integration: CodeViewController weakly exposes the current native view. NativeCodeView.onItemsChange publishes accepted completion revisions; the SwiftUI wrapper forwards it, and the demo updates its owned documents after a preparation-key check. The demo provides Edit first file, Save edit and Discard controls. A live offscreen save/remount verified persisted text. Full controlled item/editor option semantics and broader parity remain outstanding.

SwiftUI lifecycle: CodeView.dismantleNSView now disconnects its weak controller, clears completion/scroll callbacks, cancels pending wrapping, retires active or suspended editor sessions and empties mounted content. Controller detachment checks view identity, so delayed teardown of an old view cannot disconnect a newer one. This is SwiftUI teardown integration, not yet the full upstream reset/cleanup public API contract.

Composition suspension audit: upstream editor.cleanUp(recycle) retains its document/history/carets while removing the DOM input surface; browser composition events are not an AppKit IME contract. Native suspension finalizes marked text with unmarkText, retaining the composed text as one undo action. Added NSTextInputClient regressions for multiple marked replacements, CRLF preservation, caret restoration, undo/redo after reattachment, and cancellation before suspension. These are programmatic input-client checks; a real input-method candidate window remains unverified.

Unwrapped review reconciliation now retains mounted views whose logical source, prepared revision, annotations and options are unchanged, provided header/presentation callbacks have not invalidated them. Retained measured heights seed the new offset index and callbacks are rebound to destination indices. This preserves custom annotation control state during reorder and avoids editor suspension for retained views. Wrapping or changed presentations still use reconstruction; arbitrary wrapped reconciliation is not yet equivalent to upstream instance retention.

Settled wrapped pure reorders now permute existing file plans and retain mounted views when all sources/revisions/annotations/options are unchanged and no editor session is active. The generation key is updated to the new ordering without rerunning wrapping. The annotation-control reorder regression now covers both scroll and wrap modes and checks no new wrapping request after reorder. Changed items, unfinished wraps, active editors and broader mixed presentation changes retain the reconstruction path.

Reconciliation also remaps unchanged offscreen measured annotation heights and header heights. Width-mismatched annotation measurements are not reused. New file offsets use retained measurements before scroll-anchor restoration, avoiding loss of a tall offscreen row when earlier files reorder. Regression covers a 120-point annotation, a jump to file90 and a swap of earlier files in scroll and settled-wrap modes, with bounded mounted views.

Shared-highlighter audit: upstream getSharedHighlighter lazily initializes one engine, then attaches requested resources; getHighlighterIfLoaded checks initialization and optional attachment settings without loading. Native DiffHighlighter now exposes shared/getSharedHighlighter, isHighlighterLoaded and an actor-isolated getHighlighterIfLoaded using its existing attachment registries. Native engine construction is synchronous inside the actor, so the upstream JavaScript engine-promise state has no direct native equivalent. Concurrent resource preload and disposal are implemented. Disposal preserves registrations, clears resolved/attached state and caches, and cancels stale preparation/preload attachment after suspended loaders return. Pending language resolutions may still populate the grammar cache, matching upstream cleanup. A theme-disposal regression holds the first loader open, explicitly reloads the theme on a fresh engine, then releases the stale loader: old preload, preparation, and preview operations all cancel without damaging the fresh attachment. All six lazy-theme tests passed (`/tmp/swift-diffs-disposal-theme.log`). Preferred-engine selection and explicit loading/null state helpers remain unmapped.

Preload scheduling now starts independent language/theme loader tasks together, attaches cached resolutions immediately, deduplicates language requests and skips text/ansi grammars. Pending language and theme groups attach and warm independently; first errors use the existing Promise.all-style collector without cancelling shared loader tasks. A barrier regression requires both custom languages and a custom theme to start before any loader completes, avoiding timing-only concurrency assertions.

NativeCodeView now exposes reset() for clearing items, selection, expansions,
managed editors, pending navigation/wrapped layout, and scroll position while
retaining host configuration and subscriptions. SwiftUI dismantling uses this
path after disconnecting its controller and callbacks. The focused lifecycle
suite covers reset with an offscreen editor and reusing the same IDs afterward.
Upstream CodeView.reset also fires item edit-completion callbacks for discarded
sessions; native editor abandonment still omits these callbacks. Public cleanup
and this completion-event contract remain incomplete.

Discarded and host-rejected attached edit completions no longer prepare syntax
tokens for the rejected result. Completion still finalizes the edited diff and
passes its source and annotations to the callback. Accepted installations prepare
syntax afterward and recheck session identity before installing. A regression
completes a suspended Swift edit with discard, verifies the edited completion
payload, and confirms its dedicated syntax engine was never initialized. This
optimization does not yet add removal/reset completion callbacks.

Completion reentrancy regression (2026-09-18): the completion callback can remove
its own review item or reset the entire review and return acceptance. Both paths
must end with DiffEditorError.detached, one callback, zero item write-backs, no
installed prepared result, and no mounted or retained item. Both parameterized
cases pass in the 22-test VirtualWindowTests Release run (0.487 seconds;
/tmp/swift-diffs-reentrant-completion.log). This verifies the existing generation
and item-identity guards across callback-driven removal, not the still-missing
completion notification when removal itself initiates session teardown.

Offscreen completion now checks the original prepared revision before writing
back into its review item. Previously, a completion callback could update that
same ID with a new prepared document while the suspended editor had no native
attachment to invalidate; the completed edit would then overwrite the host's
replacement. The review now removes the completed session record and throws
detached while preserving the newer item, without emitting onItemsChange.
The regression replaces the item inside the callback with its editor offscreen
and verifies the replacement ID and zero write-back notifications.

The offscreen completion replacement guard also compares annotations and file
metadata, which can change independently of the prepared document ID. The
parameterized regression now covers a replacement document, a new host comment,
and a switch to file presentation using the original document. Each preserves
the host's item without stale write-back. VirtualWindowTests passes all 23 tests
(three replacement arguments), 0.503 seconds, in
/tmp/swift-diffs-completion-metadata.log.

### Integration validation — 2026-09-18

Full current Release suite: 245 tests in 54 suites passed in 10.303 seconds
(/tmp/swift-diffs-review-current-full.log), including stable-ID selection,
completion callback reentrancy, host revision/comment/file replacement protection,
and large-document replacement during distant scrolling. The demo Release build
and live last-item selection were separately verified. These checks do not close
the remaining root/subpath contract audit, teardown notification semantics,
custom separator/gutter APIs, or real display-frame pacing requirements.

Rechecked shared_highlighter.ts named exports against RenderingModel.swift.
The upstream loading state describes an engine-initialization Promise, not asset
loading in general; a native mapping must not report grammar preload as engine
initialization. Upstream disposal awaits the engine, disposes it, clears resolved
language/theme state, and resets the shared instance. A native disposal operation
must account for suspended actor operations before releasing its engine; simply
setting the optional engine to nil would leave existing post-await access unsafe.

Active review teardown notifications (2026-09-18): removing an item or resetting
now suspends and retires its active editor immediately, then finalizes a captured
text/annotation snapshot on the editing actor and invokes onEditComplete on the
main actor. Acceptance cannot install a removed item and onItemsChange is not
emitted. DiffEditor.waitForTeardown awaits this notification. This is asynchronous
native delivery rather than upstream synchronous disposal. Already-inactive
sessions (including an explicit completion in flight) retain their existing
invalidation path; complete-notification semantics for removal before such an
in-flight callback remain to be implemented. All 25 VirtualWindowTests passed
in Release, 0.562 seconds (/tmp/swift-diffs-removal-notification.log).

Completion delivery tracking now distinguishes inactive completion-in-flight from
an already delivered callback. Removal before delivery schedules discarded
notification; removal from within a callback cannot schedule a duplicate.
Generation invalidation still prevents the original completion from installing.
The existing 47 review/attached-editor tests pass (4.955 seconds;
/tmp/swift-diffs-completion-once.log), including callback-triggered removal/reset.
A deterministic regression holding completion before callback delivery is still
needed before claiming the new in-flight-removal path fully verified.

In-flight removal now has a deterministic regression: an internal scheduling seam
holds explicit completion after deactivation but before finalization/callback.
The test removes the item or resets the review, releases completion, and verifies
one notification containing edited text, no item write-back, no mounted content,
and no installed result. This closes the previously unverified pre-callback race
for these paths. All 26 VirtualWindowTests passed, 0.559 seconds, in Release
(/tmp/swift-diffs-inflight-removal.log). Native teardown notification remains
asynchronous, unlike upstream synchronous disposal.

Teardown callback replacement regression: the host reuses a removed item's ID
inside its completion callback. The new item retains its prepared revision and
starts a distinct editor with replacement text; later cleanup does not repeat the
old callback. All 27 review tests pass (0.546 seconds;
/tmp/swift-diffs-teardown-replacement.log). Full Release integration validation
also passes: 257 tests in 57 suites, 10.418 seconds
(/tmp/swift-diffs-teardown-full.log). These checks cover asynchronous native
teardown behavior, not full upstream lifecycle/API parity.

## Token transformer native adaptation

Upstream `createTransformerWithState(useTokenTransformer)` is an HTML representation transform: it preserves original UTF-16 token starts, disables whitespace merging, groups decorated fragments with `wrapTokenFragments`, and inserts a break into empty rows for editor selection. It is not a user-provided token transformation callback. Native `TokenInteractionIndex` retains one span per original Shiki token, separate from inline diff decoration; CoreText geometry supplies wrapped fragments, while copying uses the original source lines. The native renderer therefore preserves those interaction semantics directly, without an HTML-wrapper toggle. `RenderFileOptions`/`RenderDiffOptions` retain the web flag for their source-faithful comparison helpers. Nine Release token interaction/geometry tests passed (`/tmp/swift-diffs-token-boundaries.log`), including real Swift highlighting with whitespace, emoji, combining characters, blank-line copying, decorated-token identity, and wrapped token rectangles. This is a native behavioral adaptation, not HTML output equivalence.

## Upstream visual treatment (September 18)

The native canvas now follows the upstream 4pt change indicators (solid additions,
line-height-adjusted 1pt deletion stripes), 8pt diagonal buffer pattern, and
32pt rounded line-info separator surface with separate expansion targets.
Desktop two-direction controls stack vertically in a 34pt column. Boundary
separators omit the corresponding outer 8pt margin. Sparse row heights and
whole-review estimates include this decoration geometry; navigation keeps the
same extent when previously offscreen files mount. Hatching uses a cached tile.

Unified conflict rows carry conflict identity and current/incoming side through
wrapping. Their markers and code use the upstream green/blue palette treatments,
with 28pt inline action rows. `NativeDiffView.onResolveConflict` and
`FileDiffView(onResolveConflict:)` report `(conflictIndex, DiffResolution)` to the
owner; the demo applies that specific conflict through `UnresolvedFileState`.
Resolution controls are also exposed as accessibility custom actions. Default
file headers use the upstream line-height + 24pt minimum (44pt at the default
line height), a status glyph, and individually colored counts. Header text follows
the configured font size; counts use the selected code font. The modified-status outline is transcribed from upstream `sprite.ts`.

This closes these concrete default-style gaps, not the entire visual/API audit.
Custom separator/gutter slots, automatic intrinsic header changes, and broader
keyboard/VoiceOver parity still require work. Status and expansion icon paths
are now generated from the upstream sprite as documented below. The user's
physical scrolling crash remains unresolved; passing rendering tests does not
prove frame pacing or crash resolution.

Default decoration hover now follows upstream: expansion text underlines, arrows
brighten, and conflict actions use current/incoming/foreground hover colors.
Native tracking is independent of the opt-in line/token callback family and is
removed for presentations with neither decoration controls nor hover callbacks.
Conflict action separators retain their muted color and do not resolve a region
when clicked. Focused bitmap and interaction regressions cover this behavior;
complete keyboard navigation for these controls remains outstanding.


## Native sprite generation

`Scripts/diffs/generate-native-symbols.py` converts the seven default file-status and
expansion symbols from upstream `src/sprite.ts` into cached native paths in
`DiffSymbol.swift`. It preserves each path's winding rule and converts SVG arcs
to cubic segments at generation time. There is no SVG parsing or per-row path
construction during painting. Modified/new/deleted/moved/file-code and the two
expansion glyphs now share the upstream artwork; single-file headers use the
foreground icon color, while changed files retain their status palette color.
The generator's `--check` mode verifies that committed Swift paths reproduce the
current supplied sprite. This closes the previously listed approximate-icon gap.


## Streaming resource configuration

Streaming resource integration now uses `StreamTokenizerConfiguration` across
the tokenizer, clone, file snapshot stream and token transform adapter. The
`DiffHighlighter.streamConfiguration` factory resolves registered lazy resources
and checks lifecycle cancellation before returning a retained engine/palette.
Direct configurations may also wrap a caller-provided native Shiki highlighter.
Custom grammar/theme and factory-disposal coverage is in StreamConfigurationTests;
the remainder of upstream CodeToTokensOptions is still under audit. The native
configuration now forwards TokenizeWithThemeOptions unchanged: explanations,
color replacements, line-length/time limits and grammar context. Clone snapshots
preserve these options. Long-line fallback is compared with direct Shiki output
across tokenizer, clone, file snapshot and transform stream; markdown grammar
context plus scope explanations is also compared against direct Shiki output.

## Separator visibility parity

`DiffRenderPlan` now follows upstream `DiffHunksRenderer.pushSeparator` for
simple and metadata styles. Simple separators omit the leading collapsed gap;
metadata separators require the following hunk's `hunkSpecs` and omit the
trailing gap. Row counts and lazy height estimates apply the same visibility
rules, including partially expanded regions. Unknown partial-file context uses
upstream's “More unchanged context may be available” label. Custom separator
callbacks remain outstanding.

## Retained header sizing

Custom headers and prefix/suffix/metadata slots now observe frame-size changes.
Resizing a retained view remeasures the mounted file and updates review offsets
without rerunning its renderer. Layout-owned frame assignments are suppressed
to prevent resize loops, and replacing content detaches its observers. Review
layout preserves the visible code row when a mounted header changes height.
Intrinsic-size-only changes require `NativeDiffView.invalidateHeaderLayout()`;
this remains an explicit native adaptation rather than full DOM ResizeObserver
parity. Header geometry regressions also cover observer teardown and lazy mounts.

## Custom gutter utility control

`NativeDiffView.renderGutterUtility` now accepts a retained native view renderer
with a live line/side getter. One view follows hover or the visually bottom
selection endpoint, hides outside the viewport, and detaches on replacement.
The visible-row search is bounded to the viewport. Renderer reentrancy is guarded.
`FileDiffView` uses identity-stable `DiffGutterRenderer` to avoid rebuilding the
control during unrelated SwiftUI updates. The demo exposes an optional target
popover control in its standard diff viewer. The upstream built-in utility click
API and forwarding through review, file, themed, and editor wrappers remain open;
this is not full InteractionManager parity.


## Gutter adapter coverage

FileView/NativeFileView now adapt the getter to a side-less FileHoveredLine;
ThemedFileDiffView/NativeThemedDiffView retain the same DiffGutterRenderer across
appearance updates. CodeView/NativeCodeView expose CodeViewGutterRenderer with a
live item-aware target (ID, document, optional original file, line, optional side).
Review getters identify the currently mounted view at action time, return nil
when it unmounts, and follow rename/reordering without retaining an obsolete
index. Host hover tracking stays enabled for gutter-only interaction handlers.
Mixed file/diff reordering now compares file metadata by item ID before deciding
whether presentation must rebuild. A renderer resetting the review during mount
abandons the old mounting pass. Demo controls are available for these adapters;
attached-editor wrapper forwarding and upstream default gutter click options
remain pending.

## Built-in gutter action

Interaction handlers now expose `enableGutterUtility` (default false) and
`onGutterUtilityClick`. Explicit enabling is also required for custom controls.
The built-in control uses the upstream plus vector, modified/background theme
colors, 4pt corner radius, line-height sizing, and gutter-edge overlap. It starts
from the visual top of an existing selection, extends across columns on drag,
and reports the completed range before selection-end and selection-committed
callbacks. Callback payloads remain stable if the action changes selection.
Document replacement or disabling during a gesture prevents stale control drag
and completion. Custom getter closures now expire when their renderer is replaced;
enable toggles retain custom content. File adapters forward the action handler.

The demo now offers the built-in action plus an optional custom popover. Full
upstream configuration-error parity (both custom renderer and built-in callback),
keyboard navigation, off-window drag behavior, and physical frame pacing still
need verification; native custom content currently takes precedence if both APIs
are assigned. Attached-editor wrapper forwarding remains pending.


## Editable diff gutter forwarding

EditableFileDiffView now exposes DiffGutterRenderer and retains it by identity in
its coordinator, matching FileDiffView. The editable-diff demo exposes built-in
and custom gutter modes. The same NativeDiffView canvas retains the control as
editor snapshots are highlighted and completion installs the document. Ordinary
text selection/insertion continues through the editor's existing input path.
This closes the previously listed attached-editor wrapper forwarding gap; the
configuration-error, keyboard/off-window gesture, and runtime pacing gaps above
are unchanged.

## Cross-preparation token chunks

Full-source highlighter preparation retains a bounded chunk pool keyed by exact
file names, language, theme, and line limit. Unchanged-side whole-document cache
hits no longer prevent reuse when a subsequent revision changes the other side.
Grammar-state and exact-source validation stay in SharedTokenChunks; partial
patches and editor incremental documents retain their separate paths. The new
sharedChunkCacheCapacityBytes initializer parameter defaults to 64 MiB and is
separate from the 128 MiB whole-document cache. sharedChunkReusedLines and
sharedChunkCachedBytes expose accounting; clearCache/resource invalidation clear
both. Performance evidence and remaining cold-start/runtime limits are recorded
in DEMO-VALIDATION.md.


## Retained chunk eviction

SharedTokenChunks now uses a least-recently-used list instead of ceasing inserts
when full. Lookup and eviction bookkeeping do not scan the entire cache. Each
text bucket retains at most four grammar contexts and refreshes its local order
on use. Estimated content bytes are removed with evicted entries; weak list links
avoid retaining evicted nodes or creating ownership cycles. Repeated revisions
beyond the capacity continue caching their newest chunks, with the same exact
source/grammar-state checks and token-offset rebasing.
