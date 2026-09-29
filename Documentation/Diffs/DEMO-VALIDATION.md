# Native demo validation

## Expanded-context state, 2026-09-19

NativeDiffView now exposes getExpandedHunk, getExpandedHunksMap and
setExpandedHunksMap. The map is a Swift value snapshot. Replacement (including
empty maps) updates review layout, survives recycling and invalidates editor
preparation that captured older folds. Incremental expansion saturates at Int
limits. New source identities clear explicit expansion state.

Validation:

- The full concurrent Release run reported 12 issues after five-second wrapping
  deadlines (`/tmp/swift-diffs-expansion-state-release.log`). No demo build was
  running concurrently. These are recorded failures, not a passing full run.
- The affected cases together passed: 8 tests / 4 suites in 0.832 seconds, with
  unchanged source/timeouts (`/tmp/swift-diffs-expansion-wrap-isolated.log`).
- The full sequential Release run passed 477 tests / 99 suites in 56.091 seconds
  (`/tmp/swift-diffs-expansion-state-serial.log`). This establishes sequential
  regression coverage, not performance under the full concurrent workload.
- A subsequently added native-window horizontal-offset regression passed with
  all four expansion tests, including both review overflow cases, in 0.535 s
  (`/tmp/swift-diffs-expansion-horizontal.log`). Library/demo source was unchanged
  after the full run. A zero x offset stayed zero after the accessibility
  expansion handler; an intentional 120-point offset survived clear/restore.
- Demo BUILD SUCCEEDED (`/tmp/swift-diffs-expansion-state-demo.log`). Executable
  SHA-256: `799ea9de607569fa7c0db27bbd118a01b435f54c4c66dffc107cc0de08d084a7`.

Live validation used the separate Compact app. In Patch with collapsed context,
Load full patch contents hydrated 120/121 source lines. The leading 17-line gap
was expanded, saved, collapsed back to its separator, and restored through the
new sidebar controls. The matching separator accessibility actions disappeared
and reappeared with the visible rows. The original application was untouched.

During automation the code viewport became horizontally offset. Scrollbar
setValue calls returned stale-element errors and coordinate horizontal scrolling
did not reliably change the code offset. Its cause is unconfirmed; the native
regression above did not reproduce an expansion-induced horizontal jump. This
check is not a blanket visual/input sign-off.


## Standalone scrolling headers, 2026-09-19

Full Release: 474 tests / 98 suites passed in 21.236 seconds
(`/tmp/swift-diffs-sticky-final-full.log`). Demo BUILD SUCCEEDED
(`/tmp/swift-diffs-sticky-final-demo.log`). The task-owned Compact validation
copy was updated; `/Applications/swift-diffs.app` was untouched. Executable
SHA-256: `a81d1243c266c6956072487be232a8e6984e51f0441914b917c5c7101b78eaa7`.

The live Swift refactor example started in Pierre Light with Sticky header off.
Scrolling hid its filename; enabling the option restored and pinned the filename
without resetting the source position. Further scrolling retained the header.
The expanded 12,004-line JSON example reached the final row with the default
header hidden. Enabling Sticky header and scrolling back through the entire
file showed its pinned filename and first rows. The app remained responsive.
The cold JSON preparation label was 1,840.9 ms; this is not frame latency.
These UI-driven scroll checks do not establish physical momentum/frame pacing
or explain the original crash.

The full suite initially exposed old tests assuming raw NSClipView origins were
always nonnegative. With a scrolling header, the top raw offset is minus the
header inset. Tests now check the supported logical editor offset and native
inset bounds; snapshot tests compare identical presentation modes. The focused
follow-up passed 28 tests before the full pass. Three new standalone tests cover
custom heights, empty documents, mode switches and search/snapshot geometry.


## Resource contracts and collaborator tint, 2026-09-19

Lazy theme registration now retains bundled/Pierre reservations across cleanup;
custom registration before a bundled fallback is requested still wins. Seeded
cache lookup remains separate from direct loader resolution. New regressions
cover these cases and bulk preflight failure. The collaborator selection fill
now uses the upstream 32% alpha mix. Existing overlay/host tests passed (14 tests)
and the fresh wrapped-selection bitmap was inspected.

Full Release validation passed 471 tests in 97 suites in 21.624 seconds
(`/tmp/swift-diffs-resource-contracts-isolated.log`), and the demo built
(`/tmp/swift-diffs-resource-contracts-demo.log`). A preceding full run concurrent
with Xcode compilation hit five-second wrap preparation deadlines and reported
11 issues. The isolated rerun used identical source and timeout values and
passed; contention is a supported explanation, not a proven universal diagnosis.

## Live demo and JSON scrolling, 2026-09-19

A separate copied Release app was used; `/Applications/swift-diffs.app` was not
replaced or restarted. The demo executable used for the following live editor checks has SHA-256
`f9a874f0e06d9ba9027d27e1fa107112f379febf825ee9bf03de48240d5b2577`
(build log `/tmp/swift-diffs-responsive-demo-v3.log`, BUILD SUCCEEDED).

The editor header previously compressed its title and all menus at the default
1,000-point width. Controls now occupy a separate row, with a standard SwiftUI
ViewThatFits fallback to two rows. Live screenshots verified the title, full
menu labels, viewport and footer at the fresh 1,000-by-730 window and the wider
window. A fixed vertical title size caused excessive minimum-height layout
and was removed. Pierre Light remains the startup code theme, including when
macOS uses dark appearance.

In the unified editable-diff demo, actual keyboard selection displayed the
custom selection actions. Uppercase replaced `import` with `IMPORT`; Undo
restored it. Session Save captured the draft, and Restore recovered its source
and selection after a subsequent edit. Inline insertion predictions appeared
as ghost text, Tab inserted ` /* suggested */`, and Undo removed that accepted
suggestion in one operation. These checks supplement the automated lifecycle
coverage; they do not establish all input-method combinations.

The preceding Release binary (SHA-256
`8c8222e8f5340ede6146f1f630c6ad49aa4e89ceea20beed9a7c7c92c28828e0`)
was exercised with the 12,004-line JSON example and expanded context. UI-driven
page-scroll bursts traversed the entire file in split and unified modes,
including repeated top/bottom reversals. The final rows rendered correctly and
the app remained responsive without a crash. The cold preparation label was
1,791.1 ms; this includes diff preparation and is not a scroll-frame timing.
No matching crash report was found. The original reported crash remains
unreproduced and its cause is unknown.

A 30-second native CPU sample overlapped a 60-event scrolling burst
(`/tmp/swift-diffs-json-live-scroll-active-sample.txt`, sample start 18:12:27
+0530; burst 18:12:35–18:12:43). It contains DiffCanvas drawing stacks and
reports a 344.1 MB physical footprint, 489.7 MB peak. These are sampled process
figures, not allocation bounds or frame-rate measurements. An earlier sample
missed the scrolling interval and is not scrolling evidence.

The Animation Hitches instrument failed to finalize its 45-second recording.
Its profiler process reached a 35.9 GB physical footprint while processing
GPUPlugin counters; only that task-owned profiler was terminated and reaped.
The resulting trace is incomplete and supplies no frame metrics. Physical
trackpad/inertia, compositor frame pacing and the original crash remain open
validation gates. App-control launch calls also stalled for several minutes;
those tool delays must not be presented as application startup measurements.

## Resolution source bounds, 2026-09-18

Resolution.swift now validates source slices before constructing Swift ranges,
including negative, oversized and overflowing indices/counts. Line-position and
row-count arithmetic rejects integer overflow with DiffError.invalidHunk.
Source reads also match upstream's control flow: resolving one side does not
read the unused side, context copies additions, deleted blocks read neither
side, and zero-length sides do not dereference sentinel indices.

Scripts/diffs/generate-resolution-validation-oracle.ts executes the local upstream
resolveRegion to produce 24 cases, including seven expected errors. Native
results match those cases; separate Int.min/Int.max regressions throw without
trapping. Error classification is checked, not exact JavaScript error messages.
The full Release suite passed 342 tests in 73 suites
(`/tmp/swift-diffs-resolution-validation-full.log`) and the demo build succeeded
(`/tmp/swift-diffs-resolution-validation-demo.log`).

This addresses malformed resolution metadata. It neither reproduces nor proves
a fix for the user's original JSON scrolling crash; other public metadata
consumers still require their own malformed-input audits.

## Custom conflict actions, 2026-09-18

`DiffConflictActionRenderer` completes the custom conflict-toolbar mode for
NativeDiffView, NativeThemedDiffView, FileDiffView, and ThemedFileDiffView. Hosts
supply parsed `MergeConflictResult.actions`; each visible toolbar receives its
full action metadata and a guarded resolution function. That function forwards
to the existing host resolution callback and rejects stale, removed, hidden, or
offscreen controls. Views are retained while metadata is unchanged and discarded
on document replacement. Exact UTF-16 marker equality prevents stale metadata
when canonically equivalent source strings change.

Toolbar heights use the custom view's preferred size with upstream's 28-point
minimum and 8-point horizontal content padding, including the minimum when a
custom renderer returns nil. Native hosts can invalidate preferred heights
explicitly. Conflict lookup is indexed rather than scanning all conflicts on
each scroll. The demo's Conflict actions picker now includes Custom controls.

Tests cover metadata, resolution forwarding, preferred-size changes, nil
content, renderer reentrancy, SwiftUI forwarding, and bounded mounting across
100 conflicts. The full Release suite passed 340 tests in 72 suites
(`/tmp/swift-diffs-custom-conflict-full.log`). After the final minimum-height and
indexed-lookup refinements, 11 focused tests passed
(`/tmp/swift-diffs-custom-conflict-final.log`) and the Release demo build passed
(`/tmp/swift-diffs-custom-conflict-demo-final.log`). The custom demo controls have
not yet been operated interactively.

## Hidden conflict actions, 2026-09-18

`DiffRenderOptions.mergeConflictActionsType` supports upstream's default and
none modes. None removes the 28-point action toolbar while retaining the start,
separator, and end markers and current/incoming colors. Pointer hit targets,
tracking areas, and accessibility actions disappear with the toolbar. Retained
accessibility handlers now reject hidden, offscreen, or replaced conflict rows.
The demo exposes Default/Hidden choices for its merge-conflict example. Custom
conflict-action rendering remains pending.

Thirty interaction, visual-layout, and row-height tests passed
(`/tmp/swift-diffs-conflict-actions-final.log`); the Release demo build succeeded
(`/tmp/swift-diffs-conflict-actions-demo.log`). The initial test failure was a
mixed CGFloat/Double equality assertion displaying 20 points on both sides;
an explicit numeric conversion and tolerance resolved it. The hidden-toolbar
bitmap `/tmp/swift-diffs-conflict-hidden-actions.png` was visually inspected.
No interactive demo settings were changed.

## Conflict presentation correction, 2026-09-18

A fresh AppKit bitmap exposed word-level highlights within conflict bands.
Upstream `UnresolvedFileHunksRenderer.getOptionsWithDefaults()` forces unified
layout and disables inline diffs. NativeDiffView and DiffRenderPlan now apply
those same overrides whenever merge-conflict marker rows are supplied. Ordinary
diffs still honor the caller's layout and inline-diff options.

The regression requests split/word-alt presentation and verifies its plan and
bitmap equal unified/no-inline presentation. Twelve visual-layout and conflict
tests passed (`/tmp/swift-diffs-conflict-options.log`), and the Release demo build
succeeded (`/tmp/swift-diffs-conflict-options-demo.log`). The freshly generated
`/tmp/swift-diffs-conflict-header-current.png` was visually inspected: blue file
icon, filename, inline resolution actions, green current bands, blue incoming
bands, and marker captions render; the extra word backgrounds are absent.
This is bitmap-render verification, not an interactive conflict-resolution or
physical-scroll validation.

The existing Xcode Debug app was read without changing its selected example or
settings. Its executable had been rebuilt recently; its running version cannot
be inferred solely from its bundle path. It was not restarted.

## Custom hunk separators, 2026-09-18

`HunkSeparators.custom` and `DiffSeparatorRenderer` provide native custom
separator slots for plain, themed, editable, and multi-file diff views. Split
columns receive separate upstream-shaped `HunkData`; their shared row takes the
taller preferred height. Mounted views are retained by slot and metadata and
removed outside the viewport. Expansion closures reject stale, removed, and
unsupported actions. Nil content leaves an empty slot. Preferred-size changes
can be remeasured through `invalidateSeparatorLayout()`.

The demo's separator picker includes a custom SwiftUI-hosted example with the
available expansion controls. Tests cover split metadata, partial expansion,
stale actions, removal, reentrant document replacement, SwiftUI retention,
preferred heights, and bounded mounting in a 100-file review. The full Release
suite passed 333 tests in 71 suites (`/tmp/swift-diffs-custom-separators-full.log`).
A subsequent review-width invalidation correction passed 37 separator,
annotation, and wrapping tests (`/tmp/swift-diffs-custom-separators-resize.log`).
The final Release demo build succeeded
(`/tmp/swift-diffs-custom-separators-demo-final.log`). The demo controls have not
yet been operated interactively; build evidence does not establish visual parity.

## Direct streaming theme parity, 2026-09-18

The direct `FileStream(name:language:theme:)` initializer now derives native
decoration colors and light/dark appearance from its loaded theme instead of
always using the default dark palette. Closing a stream before its first append
also initializes its theme; the nonthrowing close API retains fallback behavior
for theme-loading errors. Explicit palettes supplied through a stream
configuration remain authoritative.

Regression coverage compares streamed and normally prepared files using
github-light, github-dark, pierre-light, and pierre-dark, including partial
chunks, empty chunks, close, and close-before-append. All 12 streaming tests in
four suites passed (`/tmp/swift-diffs-stream-palette-final.log`), and the Release
demo build succeeded (`/tmp/swift-diffs-stream-palette-demo.log`). These checks
did not include an interactive demo run.

## Demo JSON regression, 2026-09-18

`ViewportTests.demoJSONChangesSurviveScrollingAndLayoutSwitches` now reproduces
the demo's 1,141,800-byte JSON fixture with sparse edits every 701 rows. It
performs 384 distant scroll jumps across split/unified and scroll/wrap modes,
collapsed/expanded context, partial expansion, and viewport resizing. Bitmap
painting succeeds and the styled-line cache remains within its 512-line and
262,144-UTF16-unit limits. The test yields between events to allow pending
AppKit and layout tasks to run.

The focused test passed. An initial full run exposed a wrap-test timeout while
the new stress loop monopolized the main actor; yielding between simulated
events resolved that test interference. The subsequent Release suite passed:
328 tests in 70 suites, 18.102 seconds. Log:
`/tmp/swift-diffs-current-full-yield.log`.

No matching app crash report was found in the user or system DiagnosticReports
directories. This regression did not reproduce the reported scrolling crash;
it does not establish a fix or measure physical trackpad scrolling smoothness.
No demo runtime UI check was performed during this pass.

Observed through native UI automation on 2026-09-14 using the Release app at
`/tmp/swift-diffs-demo/Build/Products/Release/swift-diffs.app`.

## Verified in the running app

- Swift refactor: split syntax highlighting and inline changes rendered.
- Controlled selection: Accept on release selected additions lines 5–8. The
  accessibility selected text matched those four source lines.
- Switching to Reject proposals and dragging over additions lines 15–18 retained
  lines 5–8. The status reported rejection, accessibility still returned the
  accepted text, and the screenshot retained the original selection highlight.
- Large JSON: the app reported 12,004 lines per side and 3,482.3 ms preparation.
  Expand unchanged displayed the full document. A 20-page scroll reached around
  line 1,051, a subsequent 240-page scroll reached the bottom (scroll value 1),
  and a 260-page reverse scroll returned to the top (scroll value 0). Screenshots
  at all three positions showed populated, aligned split columns.

## Limitations and issues found

- These are input/output observations, not a frame-time trace. They do not prove
  sustained fast scrolling is free of dropped frames or transient blank rows.
- Cold JSON preparation remains far above the requested performance target.
- Follow-up layout fix: header text now uses unconstrained text measurement;
  the rebuilt Swift refactor screenshot showed the full filename and both change
  counts. A wider sidebar and footer background removed the visible control/text
  overlap. The selection picker's selected value still truncates at minimum width.
- Unified/wrapped layouts, other examples, theme changes, editor flows, and
  window resizing still need a complete on-screen pass.

## Reported disappearance during JSON scrolling

The user reported the demo disappearing while scrolling. macOS recorded the
demo process exiting normally at 21:39:58 (`termination reported by launchd
(0, 0, 0)`), matching the agent's quit/reopen step for the layout build. No demo
crash report was found. The reopened process survived additional vertical and
horizontal scrolling. This supports an intentional restart as the explanation;
it is not proof that all scrolling paths are crash-free. Leave the user's open
demo running during further source work.

## Cold preparation breakdown

The Release `LargeJSONPerformanceTests` run after adding stage instrumentation
measured 1,141,800 bytes: 3,511.38 ms preparation, comprising 16.82 ms setup,
1,738.71 ms old-side tokens, 1,755.18 ms new-side tokens, and 0.66 ms inline diff.
Warm preparation was 6.32 ms. Destination paints measured 8.53–11.05 ms in the
offscreen test. Full tokenization dominates cold preparation; the inline diff
algorithm is not the bottleneck in this fixture. Token-stage measurements include
source assembly and token-cache operations. These timings do not measure FPS.

After preparation-local 64-line chunk reuse, the same isolated Release benchmark
measured 2,052.32 ms cold preparation: 16.84 ms setup, 1,794.59 ms old tokens,
240.22 ms new tokens, and 0.67 ms inline diff. Warm preparation was 6.93 ms.
Reuse requires identical UTF-16 source and equivalent incoming Shiki grammar
state, and applies only to large complete same-language non-editor comparisons.
Direct full-Shiki comparisons cover changed multiline comments, shifted lines,
Unicode and CRLF, including final grammar state. The full suite passed 135 tests
in 43 suites. The user's running demo was not rebuilt/restarted with this change.

Additional shared-chunk parity checks passed for TypeScript template strings,
JavaScript embedded in HTML and Markdown, Bash heredocs, and Python multiline
strings. Fifteen variants compare every token and the final grammar state to an
independent full Shiki call, including closing delimiters at chunk boundaries,
CRLF, and over-limit lines. A moved-block case verifies reuse after a 64-line
insertion with exact rebased UTF-16 offsets. Arbitrary insertions that realign
chunk boundaries remain correct but may require tokenizing all affected chunks.

The preparation-local chunk cache is limited to 64 MiB of estimated retained
storage and four grammar contexts per source block. Budget exhaustion stops new
entries, not highlighting. Tests verify identical tokens with zero, negligible,
and partially useful budgets. The bounded-cache JSON benchmark remained at
2,068.39 ms cold preparation and 6.59 ms warm preparation. This estimate does not
constitute a bound on total process memory or Shiki's internal grammar storage.

### Selection integration build (September 14)

Release demo build succeeded using separate DerivedData at
`/tmp/swift-diffs-validation-build`; the previously running demo was neither
replaced nor relaunched. The only reported warning was skipped App Intents
metadata extraction because there is no AppIntents dependency. The current
Release library suite passed 144 tests in 44 suites (5.283 seconds). This
verifies compilation and automated behavior after selection style retention
and source-span copying changes; it is not visual or sustained scrolling
validation of this newly built executable.

### Selection lookup measurement

Release test `manyHunkLookupBenchmark` checks 10,000 source-line queries over
2,000 separated partial-patch hunks against the original linear mapping.
Every result matched. This run measured 2.695 ms for indexed lookup versus
192.753 ms for linear lookup (about 71 times faster for this workload).
All six line-index tests passed. These are aggregate lookup timings, not
scrolling frame times; rendering, layout, and event delivery are excluded.

### Measured annotation integration suite

After sparse row geometry, measured annotation heights, nil-row collapse,
renderer identity, and measurement caching, the full Release suite passed
156 tests in 45 suites (5.278 seconds). The existing 1,141,800-byte JSON test
reported 2,520.52 ms cold highlighting and 6.94 ms warm preparation. Five
offscreen destination paints ranged from 8.75 to 9.31 ms. These samples do
not establish sustained scrolling FPS, and cold preparation remains far above
30 ms. The run's cold stages were setup 196.36 ms, old tokens 2,072.51 ms,
new tokens 251.07 ms, and inline diff 0.58 ms.

### Preview-first megabyte benchmark

The Release preview test used 1,164,009 bytes of JSON with identical old/new
sources. It measured parsing at 56.09 ms, theme-correct preview preparation at
75.59 ms, and the first offscreen paint at 2.22 ms. Total elapsed time including
window creation and layout was 173.35 ms. The canvas drew fewer than 50 rows
and retained fewer than 100 styled lines. Both preview tests passed, including
scroll/selection preservation when full highlighting replaces the preview.
This preview has no syntax tokens or inline word spans; it does not establish
30 ms cold fully-highlighted display, physical first-frame latency, or scrolling
FPS. The demo Release build includes preview-first standard single-theme loading
but was not launched over the user's existing running demo.

### Identical-source parsing fast path

Exact UTF-8 equality now reuses one source-line array and skips comparison
normalization and edit-frontier work. Metadata/header processing remains shared.
The full Release suite passed 158 tests in 46 suites. An isolated run of the
same 1,164,009-byte preview benchmark measured parsing 5.94 ms, preview preparation
15.85 ms, paint 2.90 ms, and total including window creation/layout 125.91 ms.
The earlier 56.09 ms parse sample was from concurrent preview tests, so it is
not a controlled speedup ratio. This fast path applies to identical contents,
including pure renames, rather than the changed-file JSON workload.

### Annotation theme scroll anchor

The focused AnnotationTests suite passes all 10 tests. The theme-transition regression now checks the current clip-view position immediately after both dark-to-light and light-to-dark changes, before an explicit scroll request, and separately verifies that scrolling back to the same source line retains its destination. This covers an offscreen 120-point annotation in unwrapped mode. It does not establish wrapped transition behavior or physical scrolling frame times.

### September 15 validation limitation

The annotation integration demo rebuild stopped before compilation because Xcode reports unaccepted license agreements (`xcodebuild` exit 69). The subsequent demo source fix retains completion annotations when publishing the accepted document; this change has not been compiled or exercised. Earlier build results do not validate this latest demo state.

### Resumed validation after Xcode setup

Xcode readiness was restored. The full Release suite passed 170 tests across 47 suites, including all 6,910 annotation fixtures comparing mapped comments, exact UTF-16 text, undo, and redo. The stronger oracle exposed and verified a correction to low-level line-ending preservation; attached editor commands continue normalizing input. The prior license blocker is resolved. Physical scrolling and full feature parity remain unverified.

### Repeated large JSON jump stress

A 1,337,782-byte JSON document completed 256 alternating distant viewport jumps with bitmap painting. Measured median 7.11 ms, p95 8.11 ms, maximum 34.29 ms for scroll plus paint in this isolated run. Every jump stayed below 100 styled lines, at or below 512 cached lines, and at or below 262,144 cached UTF-16 units. The worst sample exceeds a 60 Hz frame interval; this offscreen benchmark does not prove jank-free physical scrolling or compositor frame times.

## Annotation metadata integration validation (2026-09-15)

The full Release suite passed **187 tests in 50 suites** in 6.709 seconds after integrating typed annotation metadata, strict primitive metadata equality, file annotation helpers, and annotation lifecycle regressions. The separate Release demo build also succeeded with signing disabled; it was not launched or substituted for the existing running demo.

In this full-suite run, the 1,337,782-byte JSON stress test completed 256 distant scroll-and-bitmap-paint jumps with bounded caches: median 7.286 ms, p95 7.754 ms, maximum 8.846 ms. These are hidden-window bitmap measurements, not compositor frame times or physical scrolling proof. The separate 1,141,800-byte JSON benchmark still measured cold highlighting at 2,214.722 ms (warm highlighting 6.937 ms). Thus the requested near-30 ms experience is not established for cold full syntax highlighting. The previously observed 34 ms scroll-test outlier has not been explained by these newer runs.

Evidence logs: `/tmp/swift-diffs-metadata-full.log` and `/tmp/swift-diffs-metadata-demo.log`. Logs are temporary local artifacts. Full upstream feature parity, comprehensive visible demo validation, and physical fast-scrolling verification remain open.

## Separator integration validation (2026-09-15)

Release integration passed 199 tests across 54 suites in 6.661 seconds. The separate Release demo build succeeded with signing disabled. Neither build success nor these hidden-window tests establish visible demo fidelity.

Line-info separators now expose individual direction targets and Expand all. Click coverage verifies leading-gap expansion toward the hunk, removal of the remaining gap via Expand all, and noninteractive simple/metadata styles. Action ordering and original-range chunking have source-backed model coverage. Custom separator views, accessible controls, unknown-length partial gaps, narrow-width layouts, and comprehensive middle/trailing click coverage remain open.

The 1,337,782-byte JSON stress case completed 256 scroll/bitmap jumps with median 6.529 ms, p95 7.324 ms, maximum 9.369 ms. The distinct changed-JSON benchmark still took 2,380.274 ms for cold highlighting, so cold full syntax does not meet the requested 30 ms experience. These full-suite timings are not isolated before/after measurements or compositor FPS. Temporary logs: `/tmp/swift-diffs-separator-full.log`, `/tmp/swift-diffs-separator-demo.log`.

### Multi-file custom cards

The Multi-file review now exposes **Annotations → Custom annotation cards** and passes the retained renderer to `CodeView`. Release demo build succeeded (`/tmp/swift-diffs-multifile-demo.log`). Manual validation remains pending: enable both toggles, scroll between distant files and back, then test split/unified and wrap/scroll with narrow and wide windows. Check that cards remain within their columns and that file boundaries do not overlap or jump. The Mac was still locked during the latest native UI check; no visual validation is claimed.

### Appending review files

Multi-file review now includes **Add 20 files** and a file count. New files receive distinct Module paths; requests cancel on preparation-key changes/disappearance and reject stale source/request identities. Release build succeeded (`/tmp/swift-diffs-append-demo.log`). The latest UI attempt still reported a locked Mac. Manual check: enable custom annotation cards, enter any editable custom control supplied by a host, append while positioned in an existing file, then repeat with wrap enabled. Programmatic control-retention regressions pass for both overflow modes; the demo currently uses static review cards, so editable-control state is covered by the AppKit test rather than this UI.

Live follow-up: the already-running demo became accessible. Large JSON · 1 MB was selected with Expand unchanged enabled, split layout, Scroll overflow and Pierre Light. CUA issued downward 25/150-page, upward 100-page, downward 200-page and upward 300-page scroll commands. The vertical scrollbar reached 1 and returned to 0; the final screenshot showed the first JSON lines rendered correctly and the app remained responsive. This did not reproduce the reported crash. These discrete automation commands do not measure frame pacing or prove physical trackpad momentum is jank-free. The process was already running and was not relaunched against the latest navigation changes.

Current Release demo rebuilt successfully (`/tmp/swift-diffs-current-demo-build.log`) and relaunched through CUA. Multi-file review showed 60 files. Enabled review header/footer; header text appeared above Module0. Activated the visible Add 20 files button; sidebar count became 80. Scrolled to the bottom and visually verified Module79 and the review footer, with scrollbar value 1. No crash occurred. The accessibility row did not activate Add 20 files; clicking the visible button did. Found a static 60-file subtitle after append and changed it to use the actual count; that final text change awaits rebuild/runtime verification.

The dynamic file-count subtitle compiled successfully in Release (`/tmp/swift-diffs-demo-count-build.log`). The already-running process predates this final text-only fix, so the corrected subtitle has compile evidence only.

ID-based SwiftUI review validation: Release build passed (`/tmp/swift-diffs-item-demo.log`), old demo quit and new binary launched through CUA. Opened Multi-file review, clicked Add 20 files, and verified both sidebar and subtitle changed from 60 to 80. Scrolled to bottom; Module79 was exposed and vertical scrollbar reached 1. No crash occurred. This also runtime-verifies the prior dynamic subtitle fix.

Review editor end-to-end validation: Release build passed (`/tmp/swift-diffs-review-edit-demo.log`) and new binary launched. Opened Multi-file review, clicked Edit first file, typed `// Review edit verified` plus newline into the focused native editor. Scrolled down to scrollbar 1, clicked Save edit while the edited item was offscreen, then scrolled back up. AX verified the saved comment in Module0 and controls returned to Edit first file. No crash occurred. This verifies controller access, suspension, completion, SwiftUI write-back and remounting together. Discard, IME and physical trackpad frame pacing remain separate checks.

Offscreen discard verified in the running Release demo: Module0 initially contained the saved `// Review edit verified` comment. Clicked Edit first file, typed `// Discard verification` plus newline, scrolled to the bottom (vertical scrollbar 1), clicked Discard, and returned to the top. AX confirmed the saved comment remained and the discarded comment was absent; controls returned to Edit first file. No crash occurred. This verifies the discard branch with a previously saved revision, not just a pristine fixture.

Demo completion lifecycle fix: completion tasks now have explicit task/request state. Example switches and view disappearance cancel pending completion and reset editing controls; preparation changes cancel an in-flight save. Late tasks only clear state or publish errors when their request is still current. Cancellation errors are suppressed. The existing view teardown handles retired editor sessions. Live switching during completion still needs verification.

Current Release verification after review/editor/reconciliation changes: isolated sustainedMegabyteJSONJumpsKeepCachesBounded passed 256 jumps over 1,337,782 UTF-8 bytes. Scroll-plus-bitmap times: median 6.562 ms, p95 7.018 ms, max 10.235 ms; worst sample was initial bitmap capture (10.232 ms), with 4.073 ms canvas draw. Styled lines stayed below 100, cached lines <=512 and cached UTF-16 units <=262144. Log: `/tmp/swift-diffs-current-json-stress.log`; samples: `/tmp/swift-diffs-json-scroll-samples.csv`. This is bitmap rendering timing, not display FPS or momentum/frame-pacing proof. A subsequent full Release run passed all 237 tests in 54 suites in 7.323 seconds (`/tmp/swift-diffs-current-full.log`).

### Mixed review runtime check — 2026-09-15

Relaunched the Release app built in `/tmp/swift-diffs-validation-build` after
`/tmp/swift-diffs-mixed-demo.log` reported BUILD SUCCEEDED. The multi-file review
showed 60 items. Scrolling to Module4 visibly showed one highlighted source
column, no change counts, and all 29 lines, between split diff items Module3
and Module5. Clicking Add 20 files changed the count to 80. A 250-page downward
scroll reached scrollbar value 1 and displayed Module79 as a single file below
Module78's split diff. The app remained responsive through these actions.
This verifies mixed presentation and append reachability; it does not measure
frame pacing or reproduce the previously reported 1 MB JSON scrolling crash.

### Interrupted completion validation recovered — 2026-09-18

The interrupted full Release test invocation finished on September 15:
`/tmp/swift-diffs-completion-full.log` reports 241 tests in 54 suites passed in
8.255 seconds. The current DiffEditor and parameterized completion regression
files predate that result. Both explicit discard and host-rejected installation
verify that the callback receives edited source without initializing a dedicated
syntax engine. Reset/reuse is included in this full run. This is test evidence,
not a new on-screen or frame-pacing measurement.

### Current large-JSON Release stress — 2026-09-18

Ran `sustainedMegabyteJSONJumpsKeepCachesBounded` alone against the current
library. For 1,337,782 UTF-8 bytes and 256 alternating distant jumps, scroll plus
bitmap capture measured median 6.547 ms, p95 7.447 ms, maximum 11.154 ms.
The slowest sample was the first: scroll 0.007 ms, bitmap capture 11.147 ms,
with 4.780 ms recorded inside the canvas draw. Every step retained at most 512
styled lines and 262,144 UTF-16 units, and styled fewer than 100 lines per draw.
The test passed in 3.491 seconds. Log: /tmp/swift-diffs-json-current.log;
per-step samples: /tmp/swift-diffs-json-scroll-samples.csv (overwritten on rerun).
This measures synchronous rendering into an AppKit bitmap, not compositor frame
pacing, trackpad momentum, full-file preparation latency, or the reported crash.

### Scrolled document replacement regression — 2026-09-18

No swift-diffs/diffs/Shiki-named report was found in the user or system standard
DiagnosticReports folders. This absence does not establish that no crash occurred.
Added a Release AppKit regression alternating 48 times between a >1 MB JSON
source scrolled near distant rows and short/empty JSON revisions. Each replacement
is laid out and bitmap-rendered, checking displayed revision, nonnegative scroll
position, and bounded styled-line caches. The focused run passed; log:
/tmp/swift-diffs-replacement-scroll.log. The reported manual scrolling crash is
still not reproduced and this test does not emulate trackpad momentum events.

### Stable-ID selection controls — 2026-09-18

The Release demo build passed (/tmp/swift-diffs-selection-demo.log). Added Select
last file and Clear controls to the multi-file example, disabled while editing.
Live UI validation: Select last file revealed Module59 and visibly highlighted
its first line. Add 20 files changed the count to 80; Select last file then
revealed Module79 with its first line highlighted. Screenshots showed the selected
line centered in the review viewport with adjacent split-diff content above it.

### Custom annotation appearance — 2026-09-18

Live verification of side-less file comments exposed dark text on dark custom
cards when system appearance was light and code theme was Pierre Dark. The
canvas now sets its inherited AppKit appearance from the prepared palette's
isLight value. After rebuilding and relaunching, the highlighted-file example
with Annotations and Custom annotation cards enabled visibly showed readable
light text for the above-file comment and both comments after line 5. The outer
app remained light. Build: /tmp/swift-diffs-annotation-appearance.log.
Two attempts to switch to Pierre Light were interrupted by the UI automation
reporting an app state change; light-theme transition verification remains open.

Annotation appearance regression: an AppKit window fixed to Aqua renders file
comments through dark → light → dark prepared themes. The test verifies inherited
comment appearance follows each theme, explicitly Aqua comment views remain Aqua,
and the window remains Aqua. All five AnnotationShapeTests passed in Release
(0.137 seconds; /tmp/swift-diffs-annotation-appearance-tests.log). This validates
native appearance propagation; it supplements the dark-theme screenshot check
without claiming a successful live light-theme menu interaction.

### Full annotation integration validation — 2026-09-18

All 254 tests in 57 suites passed in Release after the annotation model,
file-host overloads, comparison helpers, and theme-aware canvas appearance
changes (10.284 seconds; /tmp/swift-diffs-annotation-full.log). This includes
existing rendering/interaction/editor regressions plus the new dark/light
appearance propagation checks. The full-suite concurrent performance samples
are not a replacement for isolated benchmarks. Native editor completion still
returns side-tagged annotations, teardown completion notifications remain open,
and real display frame pacing plus the reported scrolling crash are unresolved.
# Split-column horizontal synchronization

The Release regression `ViewportTests.splitColumnsShareHorizontalTokenGeometry` passed (1 test, 0.100 s; `/tmp/swift-diffs-scroll-sync.log`). It checks nonempty visible token rectangles on both sides at offsets 0, 400, 2000, 400, and 0, with equal widths and vertical positions and half-viewport horizontal separation. This verifies the shared-scroll geometry adaptation of upstream `ScrollSyncManager`; it does not reproduce physical trackpad momentum or resolve the reported JSON scrolling crash.
# Annotation resize contract audit

Compared the full upstream `managers/ResizeManager.ts` with native annotation measurement and invalidation. Release `AnnotationTests` passed: 31 tests, 0.330 s (`/tmp/swift-diffs-resize-audit.log`). Coverage includes paired heights after viewport resizing, explicit dynamic-height refresh preserving mounted controls and scroll anchors, and reentrant removal/replacement. Automatic child-size observation remains a parity gap: custom content must currently call `invalidateAnnotationLayout()`. These tests do not establish an equivalent automatic notification contract.
# Automatic annotation frame resizing

Mounted custom annotation frame-size changes now invalidate cached measurements and schedule native layout automatically. Position-only changes and layout-owned frame writes do not trigger extra measurements. The new regression grows and shrinks a mounted annotation without explicit invalidation and verifies the following source line moves to the correct Y coordinate. All 32 Release `AnnotationTests` passed in 0.331 s (`/tmp/swift-diffs-auto-resize.log`), including existing bounded measurement and reentrant lifecycle checks. Intrinsic-size-only changes still require explicit invalidation; full ResizeObserver parity remains open.
# Full validation after automatic annotation frame observation

The full Release suite passed: 259 tests in 57 suites, 9.720 s (`/tmp/swift-diffs-current-full.log`). The Xcode Release demo build succeeded (`/tmp/swift-diffs-resize-demo.log`). Relaunched that build, loaded Large JSON, enabled Expand unchanged, and scrolled down 200 pages twice then up 400 pages. Accessibility reported vertical scroll fractions 0.7299, 1, then 0; the app remained responsive without an observed crash. The demo reported preparation at 1812.8 ms for 12,004 lines, not a 30 ms full-preparation result. These are automated discrete scroll actions, not physical trackpad momentum or measured display frame pacing. No matching diff crash report was found in either standard DiagnosticReports directory; the user's original crash remains unresolved.
# Isolated large-file preparation profile

Release `megabyteJSONPreparationAndDestinationPaint` passed in isolation (`/tmp/swift-diffs-preparation-profile.log`): 1,141,800 source bytes, total cold preparation 1792.48 ms, highlighted preparation 1745.69 ms, cached preparation 6.36 ms. Stage breakdown: setup 19.61 ms, old-side tokens 1553.89 ms, new-side tokens 171.27 ms, inline differences 0.92 ms. Five synchronous destination scroll-and-bitmap samples ranged from 9.13 to 13.80 ms; these are not display frame timings.

The independent direct-versus-chunked token equivalence test passed (`/tmp/swift-diffs-token-profile.log`): 1,117,782 bytes, direct Shiki 1243.53 ms, chunked Shiki 1253.93 ms. Full initial tokenization dominates this workload; removing the chunk path would not remove that cost and would discard cancellation checkpoints and grammar-state-checked cross-side reuse. The sibling Shiki virtualized view accepts a prepared `TokensResult` and bounds text layout, so its rendering speed should not be equated with full initial tokenization speed. Future preparation work should target progressive availability and tokenization cost while preserving exact grammar state, rather than replacing cancellation-safe chunks with one blocking whole-source call.
# Deferred review selection

Added `CodeViewLineSelection`, `setSelectedLines`, and `getSelectedLines` for retaining absent item IDs until the next item reconciliation. Release `VirtualWindowTests` passed: 28 tests in 0.528 s (`/tmp/swift-diffs-deferred-selection.log`). New coverage verifies arrival of a target, actual selected text, distinct composed/decomposed Unicode IDs, clearing a still-absent target, explicit clear, and reset. Review-level missing-target notification remains a separate API gap.
# Deferred selection when switching review APIs

Replacing an ID-based review with different documents through `render([HighlightedDiff])` now clears any deferred item-ID selection along with the item identity maps. The extended deferred selection regression passed in Release (0.064 s; `/tmp/swift-diffs-selection-array.log`). Source inspection also confirmed upstream review selection callbacks cover item rename and selection removal during reconciliation, beyond per-file selection callbacks; those review-level notifications remain to be implemented.
# Review-level selection notifications

`NativeCodeView.onSelectedLinesChange` now reports native item selection callbacks, selected-item renames, and cleared selections after item reconciliation, including still-missing deferred targets. Notifications occur after review reconciliation; a host can replace items in the removal callback. Release `VirtualWindowTests` passed: 29 tests in 0.531 s (`/tmp/swift-diffs-selection-events.log`). The new regression verifies one event per selection/rename/removal, silent deferred requests, and a reentrant replacement surviving the callback. This supersedes earlier notes that review-level missing-target notifications were unmapped. SwiftUI convenience wiring and full controlled-selection parity still require separate review.
# SwiftUI review selection callback

`CodeView(items:..., onSelectedLinesChange:)` now forwards the latest callback before item reconciliation. Native dismantling clears this callback alongside item-change callbacks and scroll subscriptions. The Xcode Release demo build passed (`/tmp/swift-diffs-selection-wrapper.log`), verifying the wrapper and existing demo call sites compile. This is compile evidence; runtime closure replacement through SwiftUI has not yet been separately exercised.
# Live SwiftUI review selection feedback

The demo now displays file/side/line feedback from `CodeView.onSelectedLinesChange`, scheduling state updates on the main actor and rejecting events for superseded preparation keys. Release demo build passed (`/tmp/swift-diffs-selection-demo-feedback.log`). Relaunched the build, opened Multi-file review, clicked Select last file, and observed the Module59 header plus footer `Service.swift · additions · lines 1–1`. Clicking Clear changed the footer to `Selection cleared`. This exercises callback delivery across the SwiftUI update caused by the first event; it does not yet exercise changing callback ownership to a distinct host.
# Item position lookup and selection integration

The complete Release suite after selection callbacks and SwiftUI wiring passed: 261 tests in 57 suites, 10.044 s (`/tmp/swift-diffs-selection-full.log`). Subsequently added `NativeCodeView.getTopForItem`, returning the logical top including review padding/header without mounting or scrolling. Its focused Release regression passed in 0.066 s (`/tmp/swift-diffs-item-top.log`), covering a 100-item review, missing IDs, rename, and unchanged mounted count/scroll position. Wrapped-item positions remain current estimates until measurement settles.
# Mounted review snapshots

Added `CodeViewRenderedItem` and `NativeCodeView.getRenderedItems()` as a native adaptation of upstream mounted-item inspection. A focused Release regression passed in 0.076 s (`/tmp/swift-diffs-rendered-items.log`): a 100-item review reports only the mounted viewport, distant scrolling changes the snapshot, single-file identity is preserved, rename is reflected in new snapshots, old snapshots retain their captured IDs, and reset returns no mounted items. Native `version` is the prepared document UUID, not the upstream caller-supplied version field; the native view serves as the instance rather than a DOM element.
# Smooth-scroll spring foundation

Ported upstream CodeView's closed-form critically damped spring step and `SmoothScrollSettings` defaults (omega 0.015/ms, position tolerance 0.5 points, velocity tolerance 0.05 points/ms). Three Release numerical tests passed (`/tmp/swift-diffs-scroll-spring.log`): irregular intervals agree with a single analytic step, retargeting preserves motion, a long frame gap settles, and anchor correction with a backward timestamp avoids negative-time integration. This is the numerical foundation only: no AppKit frame driver, user-interruption behavior, or animated navigation has been connected yet. Smooth-scroll parity remains incomplete.
# Native smooth-offset driver

Connected the upstream spring to an AppKit display link through `scrollTo(top:behavior:)`. A weak target avoids retaining the review through the display link. Wheel input, external bounds changes, reset, and window detachment cancel animations; an animation revision protects targets issued reentrantly during a final-frame scroll notification. Five spring/native-driver tests passed in 0.109 s, and the complete Release suite passed with 268 tests in 58 suites in 10.202 s (`/tmp/swift-diffs-scroll-driver.log`, `/tmp/swift-diffs-scroll-driver-full.log`). Native tests manually advance frame timestamps; actual display-link cadence, visual smoothness, and physical wheel/momentum interruption remain unverified. Item/range target integration and resize-anchor rebasing are still open; current external layout changes cancel rather than rebase the animation.
# Scroll navigation supersession

Accepted file/line navigation now explicitly cancels an in-flight smooth offset animation, including nearest alignment that requires no bounds change and line navigation deferred for wrapping. Invalid targets leave the animation intact. Five Release spring/native-driver tests passed in 0.107 s (`/tmp/swift-diffs-scroll-supersession.log`); the added assertions verify nearest navigation stays stationary when an old frame arrives, invalid file indices preserve the animation, and valid file navigation cancels it.
# Smooth file targets

Added smooth behavior to file-index navigation and `scrollToItem` for exact caller IDs. Frames resolve the destination from the retained source identity, using a validated cached index in the normal case. The target survives renaming; removing it cancels rather than targeting the next file at that index. Six Release spring/native tests passed in 0.102 s (`/tmp/swift-diffs-smooth-item.log`). This uses manually advanced frame timestamps; real display cadence remains unverified, and layout-triggered cancellation remains until anchor rebasing is implemented.
# Live display-link navigation and font picker

The Release demo now has Glide to first/last controls. In the running rebuilt app, Glide to last progressed to scroll fraction 0.9828 and settled with Module59 visible at the document bottom; Glide to first passed fraction 0.0584 and settled at Module0. Starting another glide and immediately sending an upward scroll input interrupted it at fraction 0.4359; a subsequent screenshot still showed Module25/26 rather than the destination. This verifies the live display-link path and automated scroll interruption, not physical trackpad momentum or measured display frame pacing.

The user-requested Code font dropdown enumerates installed fixed-pitch fonts. Its menu included Berkeley Mono, Geist Mono, Menlo, Monaco, Courier New, Andale Mono, and PT Mono faces on this machine. Selecting Berkeley Mono Regular updated both the menu value and rendered diff text. The native standalone editor now also applies `options.fontName`, not only size. Release demo build passed (`/tmp/swift-diffs-font-picker.log`).
# Spring settings changed during animation

Invalid smooth-scroll settings now cancel an active display link immediately without moving the viewport. This closes a native lifecycle issue where changing omega to zero during motion could leave the animation active indefinitely. Six Release scroll tests passed in 0.108 s (`/tmp/swift-diffs-scroll-settings.log`), including changes to zero/negative/NaN omega, negative position tolerance, and infinite velocity tolerance, plus a later frame proving the viewport stays finite and stationary. Invalid settings on a new navigation continue to use the existing instant fallback.
# Virtual-window snapshot

Added `NativeCodeView.getWindowSpecs()` returning the last window used for mounted-file reconciliation, including overscroll. It reads stored state without measuring, mounting, or scrolling. A focused Release regression passed in 0.086 s (`/tmp/swift-diffs-window-snapshot.log`), verifying exact top/bottom bounds at a distant file with 200 points of overscroll, unchanged position/mount count, and an empty window after reset. The pre-existing upstream window-calculation port remains the source of these bounds.
# Animated line and range navigation

Line/range APIs now accept smooth behavior. Targets retain source identity, endpoint rows, alignment, offset, and document/layout revision; frames reuse measured row heights without rebuilding the render plan. Pending wrapped navigation carries its behavior through resolution. Seven Release scroll tests passed (0.125 s), including four alignments for a reversed range against instant destinations and no initial jump (`/tmp/swift-diffs-smooth-range.log`). All 32 existing virtual-window tests passed (0.571 s; `/tmp/swift-diffs-range-navigation.log`), including queued wrapped navigation. Smooth deferred wrapping still needs a dedicated runtime case. Revision changes cancel rather than rebase range animations; collapsed-line target expansion remains a separate gap.
# Deferred smooth wrapping regression

The dedicated Release regression `deferredWrappedRangeKeepsSmoothBehaviorAndLatestTarget` passed in 0.178 s (`/tmp/swift-diffs-smooth-wrapped.log`). It queues two smooth targets during wrapped-layout preparation, changes the window width, verifies the latest cross-side reversed range starts an animation after preparation, manually advances to settlement, and compares the result with instant navigation. Mounting remains bounded to at most two files. This closes the deferred smooth-wrapping test gap noted above; continuous resizing during an active animation and real display cadence remain separate concerns.

# Address Sanitizer scrolling investigation

The Release tests were rebuilt with `--sanitize address` in `/tmp/swift-diffs-asan-build` and run with `--filter ViewportTests`. Seven matching tests across three suites passed in 15.241 seconds with no Address Sanitizer diagnostics (`/tmp/swift-diffs-asan-viewport.log`). This includes 256 distant jumps through 1,337,782 bytes of JSON, repeated large-to-short/empty document replacement, bounded horizontal shaping, selection retention, and destination-file mounting. These are instrumented test executions, not demo runtime or physical trackpad tests; their timings must not be used as normal rendering benchmarks. No matching crash report was found in the user or system DiagnosticReports directories. The user's scrolling crash remains unresolved.

# Review sticky header option

Review headers now scroll away by default, matching upstream opt-in behavior. `stickyHeaders` is exposed by the native view and both SwiftUI initializers, with a demo checkbox. Line/range start and nearest alignment account for measured header height; smooth range destinations use the same compensation. The full Release suite passed 277 tests in 58 suites in 10.342 seconds (`/tmp/swift-diffs-sticky-headers.log`), including exact scroll coordinates, header viewport geometry, switching modes, and disabled headers. Release demo build passed (`/tmp/swift-diffs-sticky-demo.log`). In the running demo, scrolling 0.4 pages with the option off removed Module0’s header from view; enabling it at that position displayed Module0’s pinned header while Module1’s header remained at its file boundary. This confirms the toggle visually. Subsequent regressions below check custom-header boundary clipping and absolute-position compensation.

# Absolute sticky scroll targets

`scrollTo(top:behavior:)` now subtracts the destination file header height for in-range sticky targets. Out-of-range requests clamp directly to the boundary, preserving upstream’s distinction between an exact bottom target and a target beyond the bottom. File and range navigation use a private resolved-coordinate path, avoiding duplicate header offsets. All 14 scrolling tests passed in 0.336 seconds (`/tmp/swift-diffs-sticky-position.log`), covering instant/smooth positions, exact/beyond-bottom targets, negative positions, disabled headers, and smooth file navigation. This change has test evidence; the running demo still uses the prior sticky-header build.

# Custom sticky header boundaries

`customReviewHeadersClipAtBothFileBoundaries` passed in 0.081 seconds (`/tmp/swift-diffs-sticky-boundaries.log`). With a 120-point custom header, it verifies 70 points remain after scrolling 50 points in ordinary mode; sticky mode restores the full header; source-line navigation accounts for its measured height. When only 30 points of the file remain, the pinned header clips to those 30 points, its code viewport is zero height, and the next file begins after the configured gap. This is native geometry evidence, not a new live screenshot or display-pacing measurement. No production change was needed for these cases.

# Live wrapped animation and viewport width change

The latest Release demo build passed (`/tmp/swift-diffs-reflow-demo.log`) and was reopened. Multi-file review was switched to Wrap. During Glide to last, hiding the sidebar visibly widened the code viewport; the subsequent AX snapshot showed an intermediate scroll fraction of 0.9601947745. A later snapshot reached 1 with Module59 visible at the bottom. After restoring the sidebar, Glide to first followed immediately by downward scroll input stopped at fraction 0.5028283553 with Module30 visible; a subsequent full AX snapshot retained exactly that fraction. No crash was observed. Corner and divider drag attempts did not visibly resize the window, so they are not counted as resize validation. This verifies a live viewport-width change and interruption in wrapped mode; continuous window-edge resizing, source-range navigation in the demo, physical trackpad momentum, and measured display FPS remain unverified.

# Upstream visual treatment and interactive geometry

The September 18 UI pass ports striped deletion bars, solid 4pt addition bars,
cached diagonal buffer fills, rounded expansion bars, desktop stacked expansion
arrows, upstream boundary spacing, themed conflict bands, per-region inline
resolution controls, and the default header status/count treatment.

The final full Release suite passed 290 tests across 59 suites in 10.962 seconds
(`/tmp/swift-diffs-ui-edges.log`). This includes narrow/wide expansion click
regions, hidden-context navigation without extent changes, source-identity review
navigation, and resolving the second conflict independently. The final Release
Xcode demo build succeeded (`/tmp/swift-diffs-ui-edges-demo.log`).

Live inspection of the rebuilt demo confirmed dark-mode split hatching and the
modified-file header icon; a later read-only observation showed the light-mode
large-JSON expansion bar while the user was using the demo. The latest stacked
expansion and conflict surfaces were inspected from native AppKit bitmap fixtures
(`/tmp/swift-diffs-separator-600.png`, `/tmp/swift-diffs-conflict-visual.png`). The
running user demo was left alone after subsequent builds, so the last count-width
and boundary-spacing refinements require its next launch. No pixel-diff comparison
with the browser or physical momentum/FPS measurement was performed. This does
not establish full visual/API parity or resolve the earlier reported crash.

# Decoration hover independent of source-line callbacks

Expansion and conflict controls now install native hover tracking independently
of optional source-line/token hover callbacks. The canvas hit-tests the physical
row and its control rectangles; decoration repaint is requested only when the
hovered control changes. Expansion text underlines, expansion arrows brighten,
and conflict actions use green/current, blue/incoming, or foreground/both hover
colors. The neutral separators between conflict links are outside their hit areas.

The focused Release run passed 24 tests in three suites in 0.692 seconds
(`/tmp/swift-diffs-control-hover.log`). New bitmap regressions verify visible hover
feedback without line callbacks, restoration on pointer exit, and removal of the
tracking area when the same view receives a plain document. Existing interaction
regressions pass, including stationary pointer refresh and handler replacement.
The Release demo build succeeded (`/tmp/swift-diffs-control-hover-demo.log`). The
running user demo was not restarted. These tests do not verify physical pointer
frame pacing or establish full keyboard/VoiceOver parity.

# Upstream status and expansion vectors

Seven symbols are generated from upstream `src/sprite.ts` into cached native
paths. `python3 Scripts/diffs/generate-native-symbols.py /path/to/diffs/src/sprite.ts
--check` confirms the generated output matches the supplied source. The focused
Release run passed 31 tests across five suites in 0.701 seconds
(`/tmp/swift-diffs-native-symbols.log`), covering native symbol painting plus
header, expansion, conflict, and hover interactions. The Release demo build
succeeded (`/tmp/swift-diffs-native-symbols-demo.log`).

The native bitmap contact sheet `/tmp/swift-diffs-native-symbols.png` was visually
inspected: file-code, modified, added, deleted, moved, expand-up, expand-all, and
expand-down render with distinct upstream shapes and expected orientation. This
is native artifact inspection, not a browser pixel-diff comparison. No new
`swift-diffs` crash report was found in either standard DiagnosticReports folder.
The running user demo was not restarted.

# Header typography and review estimates

Default headers now use the upstream `lineHeight + 24` minimum and configured
font size. Change counts use the selected code font, including their separator
spacing. Tall prefix/suffix/metadata views grow the header to their height
without the previously invented 18pt vertical padding. Custom-header callbacks
retain their own measured height and presence semantics.

The focused Release run passed 26 tests across three suites in 0.694 seconds
(`/tmp/swift-diffs-header-typography.log`), including font/line-height changes,
count width, an 80pt prefix, and distant navigation through 100 files with stable
extents before and after destination mounting. The Release demo build succeeded
(`/tmp/swift-diffs-header-typography-demo.log`). These are AppKit geometry and
interaction tests; the running user demo was not restarted for live inspection.

# Retained header resize observation

Custom header and header slot frame-size changes now trigger remeasurement
without replacing the document or rerunning renderer callbacks. Tests cover
single-file resizing, detached observers, explicit intrinsic-size invalidation,
and review code-row anchoring with bounded mounts across 100 files. The focused
header/annotation/scroll run passed 59 tests in three suites in 0.836 seconds
(`/tmp/swift-diffs-header-resize.log`). The complete Release suite passed 295
tests in 60 suites in 10.889 seconds (`/tmp/swift-diffs-header-resize-full.log`).
The Release demo build succeeded (`/tmp/swift-diffs-header-resize-demo.log`).
The running user demo was not restarted; this does not resolve the earlier
physical scrolling crash or establish measured trackpad frame pacing.

# Retained gutter controls

The focused Release gutter/interaction/selection run passed 29 tests in six
suites in 0.650 seconds (`/tmp/swift-diffs-gutter.log`). Tests cover one retained
control following hover without line callbacks, reverse selection endpoint
priority, leaving the canvas, distant scroll hiding/restoration, nil renderers,
reentrant renderer replacement, document replacement, and hidden line numbers.
The full Release run passed 297 tests in 61 suites in 10.669 seconds
(`/tmp/swift-diffs-gutter-full.log`). The demo build succeeded
(`/tmp/swift-diffs-gutter-demo.log`). Its optional gutter target popover has not
been live-inspected; the current user demo was not restarted. This does not
establish physical trackpad pacing or resolve the previously reported crash.

# Gutter controls across native and SwiftUI adapters

The complete Release run passed 300 tests in 61 suites in 10.669 seconds
(`/tmp/swift-diffs-gutter-adapters-full.log`). Added regressions cover retained
controls across file/theme updates, side-less file targets, review item rename
and reorder, stale getter rejection after unmounting, bounded mounts over 100
items, renderer removal, and a renderer resetting the review during mounting.
The initial focused run exposed unnecessary control recreation for mixed
file/diff reordering; the metadata comparison now follows item identity and the
full rerun passes. The demo Release build succeeded
(`/tmp/swift-diffs-gutter-adapters-demo.log`). File, streaming, themed, and review
examples now offer the gutter utility toggle. These new demo paths have not been
live-inspected; the running app was left untouched. The reported scrolling crash
and physical frame pacing remain unverified.

# Built-in gutter action and explicit enabling

The complete Release suite passed 301 tests in 61 suites in 10.633 seconds
(`/tmp/swift-diffs-gutter-action-full.log`). The new native mouse-event regression
starts from a reversed selection, drags across columns, verifies the final range
and action/end/committed callback order while the action clears host selection,
and replaces the document during another drag to reject stale events. Existing
custom-control tests verify explicit enable state, retention during enabling,
and expired getters after replacement. The upstream sprite generation check
passes with the added plus icon. The final demo build succeeded
(`/tmp/swift-diffs-gutter-action-final-demo.log`). The running demo was not
restarted; actual keyboard/trackpad behavior and the previously reported scrolling
crash remain unverified.

# Editable diff gutter controls

EditableFileDiffView now forwards a retained DiffGutterRenderer, and the editable
diff demo offers the built-in and custom modes. The focused Release gutter and
attached-editor run passed 31 tests in two suites in 4.974 seconds
(`/tmp/swift-diffs-editor-gutter-final.log`). The new regression verifies that an
edit-collapsed target stays hidden, expanding its actual context reveals the
control at the correct source line, and the same control survives subsequent
text replacement and installed completion. The initial failed expectation had
incorrectly assumed that source line was visible; its viewport was valid and the
render plan confirmed the collapsed context. No visibility workaround was added.
The demo build succeeded (`/tmp/swift-diffs-editor-gutter-demo.log`). These are
AppKit regression checks, not live demo inspection. No matching swift-diffs/Shiki
crash reports were found in either standard DiagnosticReports directory during
this turn; the scrolling crash remains unresolved.

# Repeated large JSON preparation

Measured the existing 1,141,800-byte JSON benchmark with one additional name edit.
Before retention, that edit took 1557.515 ms after the unchanged side hit its
whole-document cache (`/tmp/swift-diffs-json-edit-baseline.log`). With retained
compatible chunks, an isolated rerun took 31.178 ms; cold highlighting remained
1753.600 ms, fully cached highlighting 6.426 ms, and five destination bitmap
paints ranged from 9.764 to 12.994 ms
(`/tmp/swift-diffs-json-retention-isolated.log`). These are single local runs,
not a statistical guarantee or a physical scrolling/frame-pacing measurement.

The highlighter now retains the most recent eligible file/configuration's chunks
under a separate configurable 64 MiB estimated-content budget. Exact source and
grammar-state checks remain required; changing file/configuration replaces the
pool, and clear/resource invalidation releases it. Tests compare reused tokens
with independent highlighting and cover theme/limit changes, zero capacity, and
cache clearing. The focused run passed 11 tests in four suites in 3.135 seconds
(`/tmp/swift-diffs-json-retention.log`). The full Release suite passed 303 tests
in 61 suites in 10.722 seconds (`/tmp/swift-diffs-json-retention-full.log`). The
demo build succeeded (`/tmp/swift-diffs-json-retention-demo.log`). The running
app was not restarted; the reported scrolling crash is still unresolved.

# Token chunk cache saturation

The retained chunk pool now evicts least-recently-used entries at capacity. The
focused Release run passed 12 tests across four suites in 3.192 seconds
(`/tmp/swift-diffs-chunk-eviction.log`). A new regression fills a two-chunk budget,
refreshes an older entry, verifies that the untouched entry is evicted, and then
runs 27 additional revisions while comparing exact tokens against independent
Shiki output and verifying recent-source reuse and bounded bytes. A source whose
working set exceeds capacity is not guaranteed cache hits on a sequential rescan;
token correctness and bounds still hold. The existing multiline/embedded grammar
and offset-rebasing tests pass. The demo build succeeded
(`/tmp/swift-diffs-chunk-eviction-demo.log`). No running app was restarted, and
this cache test does not verify physical scrolling or resolve the reported crash.

# AppKit wheel event stress and sanitizer

Added WheelScrollTests with a greater-than-1-MB JSON fixture (identical diff sides)
and 12 rapid finger-scroll gestures. It delivers explicit began/changed/ended
wheel phases through the library's NSScrollView, reverses direction, resizes the
viewport, replaces the large document with a tiny document during a gesture,
restores it, paints sampled destinations, and checks finite clip bounds plus the
512-line / 262,144-UTF16-unit styled cache limits. The 288 measured changed events
must produce more than 20 distinct viewport positions, so ignored events cannot
produce a false pass. AppKit's run loop is advanced between delivery steps.

Release execution passed in 4.912 seconds with 51 distinct positions
(`/tmp/swift-diffs-wheel-replay.log`). The Address Sanitizer build passed in
8.519 seconds with 132 positions and no ASan error diagnostics
(`/tmp/swift-diffs-wheel-asan.log`). The test binary was verified to link
libclang_rt.asan_osx_dynamic.dylib. Sanitized timing is not a rendering benchmark.
No product source change or demo restart was needed for this test addition.

Earlier synthetic momentum attempts did not move the viewport sufficiently and
were rejected as invalid tests. Isolated AppKit probes confirmed that this hidden
window setup accepts finger-wheel deltas but ignores the synthetic momentum
deltas. A plain responsive-scrolling probe waited in AppKit's gesture event
monitor; only that scratch process was terminated after sampling it. The final
test is deliberately scoped to accepted finger-scroll events. It is not evidence
of real trackpad momentum, display FPS, or reproduction/resolution of the user's
reported crash. Mixed change/padding rows and asynchronous installation during
real gestures still warrant runtime coverage.
# Hydration API verification and current wheel-test failure

Standalone editor shared-highlighter follow-up: EditorView accepts an optional
highlighter, retains a stable default in its coordinator, and changes the native
editor's engine without replacing the view. The demo passes its registered
highlighter to the standalone editor. Cancellation plus revision checks now
guard stale errors as well as successful preparation. Five focused tests in
three suites pass in 0.211s (`/tmp/swift-diffs-editor-highlighter-final.log`),
including delayed old loads that succeed or fail, retained text/selection/undo,
and actual NSHostingView updates through supplied and default highlighters.

Standalone editor syntax-style follow-up: bold/italic now use actual text-storage
font runs, because AppKit's NSLayoutManager.h explicitly excludes layout-affecting
fonts from temporary drawing attributes. Only differing runs are changed in one
storage transaction; color/background/underline/strikethrough remain temporary.
Tests check combined traits, the selected font family, resizing, and stale-style
removal on theme change. NativeEditor accepts an explicit configured highlighter.
The custom theme fixture did not produce token backgrounds from native Shiki;
this fixture therefore does not prove positive background painting or a
difference from upstream. Full Release validation discovers 325 tests in 69 suites:
324 pass and one asleep-display wheel test skips, in 10.582s
(`/tmp/swift-diffs-editor-styles-full.log`).

Fallback token color follow-up: empty Shiki foreground/background values now
inherit native theme styling instead of invoking AppKit's system text-color
fallback. Strikethrough color follows the same rule. Bitmap comparisons verify
absent/empty/explicit-theme foreground equivalence and distinguish a real color
override. The standalone editor removes the empty-color override and rehighlights
when document/line tokenization limits change. Two focused tests pass in 0.147s
(`/tmp/swift-diffs-fallback-colors.log`). Full Release validation discovers 324
tests in 68 suites: 323 pass, one asleep-display wheel test skips, in 10.848s
(`/tmp/swift-diffs-fallback-full.log`).

Streaming options follow-up: all 11 streaming tests in four suites pass in
0.071s (`/tmp/swift-diffs-stream-options.log`). Direct native Shiki comparison
checks that the configured long-line fallback reaches tokenizer, clone, file
snapshot and transform stream. Grammar-context and scope-explanation output also
matches direct Shiki output. The configuration carries all fields of native
TokenizeWithThemeOptions; it does not claim support for upstream-only options.
The demo now passes its configured line-length limit into each streaming mode.

Streaming configuration follow-up: DiffHighlighter.streamConfiguration resolves
lazy registered language/theme resources and retains their internally locked
Shiki engine plus native palette. Tokenizers, clones, FileStream and transform
streams accept that configuration. Ten focused streaming tests pass in 0.066s,
including custom grammar colors, light palette metadata, shared engine reuse,
and continued use after factory disposal (`/tmp/swift-diffs-stream-config.log`).
The full Release suite discovers 321 tests in 67 suites: 320 pass and the sleeping
display wheel test skips, in 10.723s (`/tmp/swift-diffs-stream-config-full.log`).
All three demo streaming modes now resolve through the demo's registered
highlighter; Release build passes (`/tmp/swift-diffs-stream-config-demo.log`).
The running app was not changed, so interactive custom-theme verification remains.

Streaming demo follow-up: the Streaming code example now offers File snapshots,
Token recalls, and Tokenizer branches. Recall mode uses the public pull-based
transform stream, applies recall events to its rendered tokens, and lets users
toggle incomplete-token emission. Branch mode clones a tokenizer inside a
multiline comment and displays independent continuations, with shared stable
buffer counts. Both modes support replay and cancel through SwiftUI task
identity, with generation checks after suspension. The Release demo build passes
(`/tmp/swift-diffs-stream-lab-demo.log`). These new controls have not been
operated in the running app; it was not relaunched or altered.

Token transform follow-up: nine streaming tests in three suites pass in 0.064s
(`/tmp/swift-diffs-token-transform.log`). Coverage includes recall and stable-only
reconstruction, final-tail flush, no early source reads while a chunk's output
is pending, source failure without flushing incomplete text, and cancellation
before source consumption. The adapter uses AsyncSequence pull semantics; it
does not claim a bounded total history because the tokenizer retains stable
tokens as upstream does.

Tokenizer clone follow-up: direct execution of upstream tokenizer.ts with a
minimal token provider confirms stable-buffer aliasing, independent pending
text and clear detachment. The native clone preserves this behavior with a
locked shared stable buffer and the dependency's internally locked Sendable
highlighter. Five streaming tests pass in 0.057s
(`/tmp/swift-diffs-stream-clone.log`), including simultaneous syntax branches
compared with independently streamed references, cloning before first input
and after close, and prior concurrent FileStream append/close coverage.

Streaming ownership follow-up: FileStream now owns synchronous tokenizer state
within its own actor. Append, close and snapshot creation contain no actor hops
or suspension points. The concurrent-append baseline passed before the change;
the change removes a source-visible reentrancy window rather than claiming a
reproduced data-loss failure. Tests cover 100 concurrent distinct prefixes and
20 close-versus-append rounds, with unchanged post-close snapshots and rejected
late input. The Release suite reports 314 discovered tests in 64 suites:
313 pass, one wheel test skips because the display is asleep, in 10.587s
(`/tmp/swift-diffs-stream-atomic.log`).

EOF warning rendering follow-up: all 312 tests in 64 suites pass in 11.986s
(`/tmp/swift-diffs-no-newline.log`). New cases verify per-side warning order in
unified mode, paired split rows, context versus changed styling, and lazy height
agreement. The rendered `/tmp/swift-diffs-no-newline.png` was visually inspected:
the addition warning occupies the right column with its green background/bar,
and the empty left side uses striped filler. Physical scroll/crash verification
remains separate.

Hydration oracle follow-up: `Scripts/diffs/generate-hydration-oracle.ts` uses the
supplied upstream hydration helper with 312 existing pinned-jsdiff fixture
inputs plus 16 explicit validation/pure-rename cases. Both native modes match
all 328 results, including 14 rejections. Inputs deliberately contain stale
geometry so this checks recomputation, not just preserved metadata. All four
hydration tests pass in 0.022s (`/tmp/swift-diffs-hydration-oracle.log`). These
tests supplement the native truncated-file atomic-failure check; upstream does
not provide that additional bounds validation.

Latest follow-up after separator visibility fixes: all 309 tests in 63 suites
pass in 12.439s (`/tmp/swift-diffs-separator-visibility.log`). The display was
awake at test discovery; the wheel test executes rather than skips and records
288 sampled events across 55 viewport positions. Sampled bitmap paint median
is 3.157ms and maximum 5.490ms in that run. These are paint timings, not frame
pacing measurements. This supports the display-sleep explanation below, but
does not establish physical momentum behavior or resolve the reported crash.

Follow-up: `CGDisplayIsAsleep(CGMainDisplayID())` returns 1 in the failing
environment. A standalone plain AppKit scroll view also ignores both pixel and
line wheel events. The wheel integration test now declares an awake-display
prerequisite using that public CoreGraphics API. Sleeping-display runs report a
skip, while awake-display runs retain the original movement assertion. An awake
rerun and physical scrolling verification remain required; this change does not
establish that the user's crash is fixed.

With that prerequisite, the Release suite finishes successfully in 10.474s:
307 executed tests pass and the wheel integration test is explicitly skipped
(308 discovered tests in 63 suites; `/tmp/swift-diffs-awake-gate.log`). No app
restart, screen wake or session unlock was performed.

The value-returning and inout `LoadedDiffFiles` hydration APIs pass three focused
Release regressions: clone independence, atomic failure and pure-rename geometry
preservation (`/tmp/swift-diffs-hydration.log`).

The subsequent full Release run executes 308 tests in 63 suites but fails one
wheel-movement assertion (`/tmp/swift-diffs-hydration-full.log`). Serial execution
also fails that assertion (`/tmp/swift-diffs-hydration-serial.log`), as does a fresh
isolated wheel run (`/tmp/swift-diffs-hydration-wheel-isolated.log`). The isolated
run records only two viewport positions despite 288 delivered synthetic wheel
events. This supersedes earlier successful wheel runs as current evidence: the
fixture is not reliably exercising scrolling. No movement threshold was weakened,
and neither physical scrolling stability nor the reported crash is resolved.

## CSS-variable theme factory and native adapter — September 18

Ported Shiki v3.13.0's raw factory scope order, string/array scope shapes,
variable defaults, prefix/name handling, and font-style toggle. Seven generated
fixtures compare full raw themes against the tagged upstream factory. Additional
tests cover concrete native color resolution, missing/invalid values, lazy
first-registration-wins behavior, and real Swift keyword highlighting.

The AppKit adapter accepts hex colors and explicit host overrides; it does not
simulate CSS cascade or resolve arbitrary CSS expressions. The demo includes
“Custom · Variable Colors” in its theme picker. Its UI was not operated; the
existing running demo was left untouched.

Focused: `/tmp/swift-diffs-css-themes.log`, 3 tests passed.
Full Release: `/tmp/swift-diffs-css-themes-full.log`, 345 tests in 74 suites
passed in 18.650 seconds. Demo: `/tmp/swift-diffs-css-themes-demo.log`,
BUILD SUCCEEDED. `git diff --check` passed. These checks do not resolve the
reported physical-scrolling crash or establish complete UI/API parity.

## Owned unresolved-file component — September 18

NativeUnresolvedFileView now owns parsed source state, automatic/controlled action
handling, immediate source/marker presentation, asynchronous highlighting, and
cleanup/reuse. Resolution has a separate pure state-returning API for controlled
hosts. Request identities reject stale action callbacks and late highlighting
results. The component forces unified/no-inline rendering after final resolution
as well as while markers remain. Custom view factories can reenter rendering;
request guards protect preparation scheduling across that boundary.

Five tests cover out-of-order resolutions, state/event payloads, pure controlled
resolution, source replacement while a theme loader is suspended, cleanup/reuse,
callback-driven source replacement, and theme-load failure recovery. The full
Release run `/tmp/swift-diffs-unresolved-view-full.log` passed 350 tests in 75
suites in 18.919 seconds. `/tmp/swift-diffs-unresolved-view-demo.log` reports
BUILD SUCCEEDED. The existing demo still uses its host-owned conflict flow; the
new ownership component is not yet demo-integrated or interactively verified.
The reported scrolling crash remains unresolved.

## SwiftUI conflict ownership and demo integration — September 18

UnresolvedFileView wraps NativeUnresolvedFileView and retains automatic resolutions
across unchanged SwiftUI inputs, font/theme updates, and host echoes of resolved
source. Context-size changes reparse the current source. External replacement
starts a new source identity; dismantling cleans up the native component. The
Merge conflicts demo now uses this wrapper instead of duplicating its own
parse/prepare/resolve flow. Header, annotation, gutter, separator, conflict action,
interaction and controlled-selection settings are forwarded.

The new selection regression exposed that NativeDiffView.selectLines(notify:false)
still calls onSelectionChange. The wrapper suppresses that observer only while
applying an external binding, avoiding feedback to the SwiftUI host. The native
API's existing behavior remains unchanged.

Final full Release validation: `/tmp/swift-diffs-unresolved-swiftui-verified.log`,
353 tests in 75 suites passed in 15.035 seconds. Release demo build:
`/tmp/swift-diffs-unresolved-swiftui-demo-final.log`, BUILD SUCCEEDED.
`git diff --check` passed. Earlier failed runs are superseded by the corrected
selection binding and final run. The running demo was not restarted or operated;
interactive verification and the reported physical-scrolling crash remain open.

## Conflict display updates retain syntax tokens — September 18

NativeUnresolvedFileView now keys syntax preparation by source revision, source
identity, exact UTF-16 theme name, and the two tokenization limits. Font, line
height, wrapping, annotation, and conflict-action display changes reuse the
current document and pending preparation. Async completion reads the latest
layout/annotations rather than the settings captured before a theme load.

Regression coverage checks stable prepared document/token identity for display
changes, invalidation for theme/tokenization changes, and a suspended theme load
whose completion retains later line-height and hidden-action settings. The
accessibility check includes the conflict number in the actual action title.

Final full Release run `/tmp/swift-diffs-conflict-token-reuse-verified.log`:
355 tests in 75 suites passed in 18.621 seconds. Release demo build
`/tmp/swift-diffs-conflict-token-reuse-demo.log`: BUILD SUCCEEDED.
`git diff --check` passed. No interactive demo or physical frame-pacing claim
is made; the reported scrolling crash remains unresolved.

## Preview installation during fast wheel input — September 18

The wheel regression now exercises eight plain → prefix-highlighted → fully
highlighted document transitions during its existing 288 drag-phase events.
Each transition retains source identity and asserts that installing tokens does
not change the clip-view origin. Resize, direction reversal, tiny-document
replacement, bounded caches, and the >20 distinct viewport-position assertion
remain in place.

A separate attempted momentum sequence was not valid movement evidence:
`/tmp/swift-diffs-momentum-preview.log` recorded correct NSEvent momentum phases
but only three viewport positions, failing the unchanged movement assertion.
A standalone plain-NSScrollView comparison stalled inside AppKit's concurrent
scroll event monitor; `/tmp/swift-diffs-momentum-probe-sample.txt` captures the
wait. That diagnostic process was terminated after sampling, and no comparison
result was obtained. The working regression continues to assert drag phase and
empty momentum phase explicitly. Physical and synthetic momentum verification
remain open; no scrolling crash fix is claimed. A fresh filename search found
no matching swift-diffs entry in the user's DiagnosticReports directory.

Final targeted Release run `/tmp/swift-diffs-wheel-preview-verified.log` passed
in 5.237 seconds: 288 drag-phase events, 52 distinct positions, eight preview
transitions, bounded styling caches. Sampled bitmap paint median was 2.935 ms,
maximum 3.452 ms; these are not display frame timings. `git diff --check` passed.
No production Swift or demo code changed in this investigation, so the previous
full-suite and Release demo build evidence remains separate from this new test.

## Classic indicator overlap fix — September 18

The reported strike-through-looking line numbers came from drawing the Classic
minus at a fixed gutter offset occupied by the digits. Classic now follows the
upstream style.css arrangement: indicators start after the number gutter, with
two character advances reserved before code. Line numbers retain their original
alignment. Code drawing, hit testing, and native/multi-file wrap widths use the
same added inset. EOF indicators use the same placement and upstream ASCII '-'.

`/tmp/swift-diffs-classic-indicators.png` was visually inspected at Menlo 20pt:
the deleted-line numbers, minus signs and code occupy distinct columns. The
regression also checks the code hit rectangle against the font-scaled inset.
`/tmp/swift-diffs-classic-fix.log`: 11 tests in 4 suites passed (visual-layout and
wrap suites). `/tmp/swift-diffs-classic-demo.log`: BUILD SUCCEEDED. The existing
running demo was not restarted. `git diff --check` passed.

## Folded-line navigation, 2026-09-18

Added NativeDiffView visibility, directional nearest-line, and reveal methods.
The native metadata implementation matches 12,544 upstream-generated probes,
including zero-length hunks and trailing expansion (which ignores fromEnd).
Three focused tests passed, including AppKit callback/idempotence checks and
malformed trailing metadata errors (`/tmp/swift-diffs-navigation.log`).
The complete Release suite passed 359 tests in 76 suites in 20.274 seconds
(`/tmp/swift-diffs-navigation-full.log`). These checks do not establish physical
scrolling frame pacing or resolve the previously reported demo crash.
The Release demo also built successfully (`/tmp/swift-diffs-navigation-demo.log`).
The running demo was not relaunched or modified during this validation.

## Owned conflict navigation, 2026-09-18

NativeUnresolvedFileView now directly exposes the three inherited folded-line
navigation methods. The new component integration test reveals leading and
trailing context while highlighting is pending, verifies both expansions
survive its completion, then checks explicit source replacement resets folds
and cleanup leaves navigation inert. All 14 conflict-component and navigation
tests passed in 0.440 seconds (`/tmp/swift-diffs-conflict-navigation.log`).
This run compiled the library and tests; the demo was not relaunched.
`UNRESOLVED-FILE-API.md` now records the component's native adaptations and
remaining lifecycle, hydration and inherited-method gaps.

## Presentation lifecycle, 2026-09-18

NativeDiffView now emits PostRenderPhase mount/update/unmount events after
presentation changes and before cleanup. NativeUnresolvedFileView forwards
its own instance, including the plain-to-highlighted transition. DiffView and
UnresolvedFileView expose callbacks and dismantle cleanup to SwiftUI.
Repeated identical renders and repeated cleanup do not duplicate events.
Cleanup cancels loading, clears presentation and either discards or suspends
an attached editor. Reentrant mount/unmount callbacks may replace source or
clean up without an older operation erasing the replacement.

PostRenderTests covers callback order, no-op renders, remount, source replacement
inside callbacks, recursive cleanup, conflict highlighting, cleanup from mount,
and editor discard/recycle with retained text and undo. The complete Release
suite passed 366 tests in 77 suites in 19.803 seconds
(`/tmp/swift-diffs-post-render-full.log`). The Release demo build succeeded
(`/tmp/swift-diffs-post-render-demo.log`); the running demo was not relaunched.
Custom-slot-only updates and multi-file virtualization lifecycle still need
explicit contract review. These events do not measure compositor frame pacing.

## Virtualized presentation cleanup, 2026-09-18

NativeCodeView now calls native presentation cleanup when retiring a mounted
file. The unmount callback can inspect the last document and attached editor;
cleanup then suspends the editor and clears the retired view's document/caches.
Retained rendered-item snapshots no longer keep a retired presentation active.
Editor text and undo survive scrolling away and back.

Removal loops abandon stale work if an unmount callback resets or replaces the
review. Reset also preserves a replacement installed by an unmount callback.
Four VirtualLifecycleTests cover these cases, including reset-time replacement
and unmount-before-editor-suspension ordering. The final full Release suite
passed 370 tests in 78 suites in 20.346 seconds
(`/tmp/swift-diffs-virtual-lifecycle-full.log`). The Release demo build succeeded
(`/tmp/swift-diffs-virtual-lifecycle-demo.log`). No running demo was relaunched.
This verifies cleanup on existing instance callbacks; the shared CodeView
callback option and its full per-item dispatch contract remain unmapped.

## Reentrant review replacement with a reused editor, 2026-09-18

A new integration test reproduced a reconciliation bug: an unmount callback
replaced the review while a second mounted view was being reused. The reused
view was temporarily absent from the mounted map, so nested reconciliation
created another view, failed to attach its still-attached editor, and left that
editor suspended. The baseline regression failed four assertions and observed
one attachment error (`/tmp/swift-diffs-reentrant-reuse-before.log`).

Reconciliation now publishes the reused views before retiring old views and
running their callbacks. Retired views are a separate snapshot; callback-driven
replacements own the mounted map thereafter. Expansion handlers also reject
callbacks from instances no longer mounted at their captured index.
The fixed regression and related suites passed 67 tests in 5.083 seconds
(`/tmp/swift-diffs-reentrant-reuse-fixed.log`). The complete Release suite
passed 371 tests in 78 suites in 20.772 seconds
(`/tmp/swift-diffs-reentrant-reuse-full.log`), and the Release demo build
succeeded (`/tmp/swift-diffs-reentrant-reuse-demo.log`). The running demo was
not relaunched. This is an editor/reconciliation fix, not a reproduction or
resolution of the reported large-JSON scrolling crash.

## Review and component controls, 2026-09-18

Added per-item collapse for mixed file/diff reviews, including scroll/wrap
geometry, collapsed navigation and suspension/resumption of the same editor
with draft/undo retained. Demo controls collapse all, expand all or toggle the
first file. Shared CodeView lifecycle callbacks now deliver item identity and
native instance, follow renames and allow callback-driven review replacement.
They coexist with direct instance callbacks. A focused test caught deferred
mounting after a callback replaced the review; the committed mount pass now
updates the visible set after such replacements. Retiring a view clears its
internal callback snapshot so it does not retain the old prepared document.

Added setOptions, setLineAnnotations and rerender to native diff/file/conflict
components; file views also expose side-less annotation updates and lifecycle
callbacks, with SwiftUI teardown. Prepared views update presentation without
implicitly retokenizing; owned conflict views prepare changed themes.

Review changes passed 377 tests in 80 suites
(`/tmp/swift-diffs-review-controls-full.log`); final component-control changes
passed 380 tests in 81 suites in 14.976 seconds
(`/tmp/swift-diffs-component-controls-full.log`). The Release demo build passed
(`/tmp/swift-diffs-component-controls-demo.log`). The running demo was not
relaunched; new controls are build-verified, not interactively verified.
A fresh DiagnosticReports filename search found no swift-diffs crash report.
The user's original scrolling crash remains unresolved.


## Declarative review editing — September 19

The multi-file sidebar now exposes automatic editing of the first item and
accept/reject completion decisions. `CodeViewItem.edit` plus `createEditor`
creates sessions only for expanded, mounted items. Completion, removal and
collapse have source-identity tests. Full Release suite: 384 tests in 82 suites,
20.425 seconds (`/tmp/swift-diffs-managed-editing-full.log`). Demo Release build
passed (`/tmp/swift-diffs-managed-editing-demo.log`). This is build/test evidence;
the running demo was not restarted or changed.


## Editor retention, overlays and owned streams — September 19

Native review editing now retains keyed drafts/undo/annotations/selection across
completed sessions and handles external text replacements while mounted or
suspended. Active keys are exclusive; dormant file/diff namespaces each default
to 100 entries. Deallocation and retained undo/redo have integration coverage.

Attached editors support diagnostic waves/popovers, theme diagnostic colors,
external selections that remap through edits and history, and atomic public edit
batches. Native bitmap checks exercise narrow wrapped and unwrapped columns.
The first narrow test captured wrapping too early and placed the unwrapped caret
outside the viewport; waitForLayout and a visible test target fixed those checks.
The inspected wrapped artifact is `/tmp/swift-diffs-editor-overlays.png`.

NativeFileStreamView/FileStreamView own input consumption, token-recall callbacks,
pre/post-render and start/close/abort callbacks, replacement and cleanup. Tests
cover late old-source output, callback-driven replacement, failure preservation
and detached-view release. Streams omit headers/indicators; configurable labels
start at 42 in the new Managed stream demo mode.

Final Release suite: 398 tests in 85 suites, 19.857 seconds
(`/tmp/swift-diffs-stream-editor-full.log`). Release demo build passed
(`/tmp/swift-diffs-stream-editor-demo.log`). `git diff --check` passes. This run
made no Git commits and changed no sibling projects. The current repository root
is the swift-diffs directory itself. The running demo was not restarted.
No matching swift-diffs DiagnosticReports file was found. The reported physical
scrolling crash and actual momentum/frame pacing remain unverified.


## Editor typing, focus and adaptive streams — 2026-09-19

Release regression suite: **409 tests, 87 suites, 15.283 seconds, passed**.
Log: `/tmp/swift-diffs-editor-stream-final.log`.
Release demo build: **BUILD SUCCEEDED**.
Log: `/tmp/swift-diffs-editor-stream-final-demo.log`.

New coverage checks adjacent/nested brackets, ignored syntax, exact scan limits,
megabyte-long lines, Unicode surrounding, undo and marked-text replacement;
native first-responder transitions and scroll-preserving source focus; independent
active lines; and light/dark/system changes during and after a stream, including
selection identity and callback reentry. Full, cached, incremental and streaming
file tokens include the same syntax classifications by default. Explicit
stream-tokenizer options remain supported. The prior four file-stream and two
raw-token protocol failures were consistency defects fixed before this final run.

The demo now exposes a Typing menu in Editable diff and an Appearance picker in
Managed stream. Its newly built executable was not launched, and the currently
running demo was not restarted. No new physical trackpad, IME candidate-window,
interactive popover or broad visual-parity sign-off is claimed. A fresh filename
search of DiagnosticReports still found no swift-diffs crash report.

## Multiple carets, keyboard customization and grouped undo — 2026-09-19

Final Release suite: **427 tests in 90 suites passed, 15.182 seconds**, log
`/tmp/swift-diffs-input-final.log`. Final Release demo build succeeded, log
`/tmp/swift-diffs-input-final-demo.log`. The demo was not launched or restarted.
Editable diff lists multi-caret shortcuts and provides a custom Command-D
binding under Typing. Detailed behavior, APIs and adaptations: EDITOR-INPUT.md.

Native tests cover Option-click/drag, Command-D, simultaneous text/IME/deletion,
clipboard ordering, line commands, undo/redo, empty selections, view restoration,
keyed retention, callback replay and configurable history capacity. The inspected
`/tmp/swift-diffs-multiple-carets.png` shows the secondary caret and primary range
using the existing canvas. Upstream-generated fixtures compare 771 selection
cases and 2,775 history operations; history includes actual forward/inverse edits,
versions, selections, coalescing and eviction. An IME regression confirms provisional
text invalidates redo and programmatic replay first commits the composition.

The earlier full Debug run (`/tmp/swift-diffs-multi-history-full-debug.log`) failed
17 timeout/readiness assertions while unoptimized megabyte workloads ran. Focused
Debug input tests and the final complete Release run pass. No timing thresholds
were relaxed. The earlier 426-test Release pass is superseded by the final
427-test run after the IME redo fix.

Final optimized diagnostics: 1,141,800-byte JSON cold highlight 2,311 ms, cached
highlight 6.94 ms, small-edit preparation 35.44 ms. Synthetic 1,337,782-byte JSON
jump/bitmap test: 256 jumps, median 7.44 ms, p95 8.14 ms, maximum 8.70 ms.
The demo JSON fixture also passed 384 jumps across split/unified, scroll/wrap,
and expanded/collapsed layouts. These are automated workload measurements,
not physical scroll frame pacing or proof that the originally reported crash is
fixed. Initial editor-state import, predictive edits, custom editor widgets and
systematic interactive verification remain open.


## Initial editor state and document contracts — 2026-09-19

Final Release suite: **439 tests in 92 suites passed, 15.252 seconds**, log
`/tmp/swift-diffs-state-final.log`. Release demo build succeeded, log
`/tmp/swift-diffs-state-final-demo.log`. The demo was not launched or restarted.
Editable diff → Session now saves a draft snapshot and restores it into a new
editor. AppKit and SwiftUI automated integration covers attachment-time import,
independent undo/redo, partial state, keyed precedence, file/language identity,
annotations, folds, viewport, and a provisional IME snapshot that leaves the
original composition untouched. Developer mutations invalidate stale private
undo metadata before import.

Document contract tests cover checked line access, CRLF, UTF-16 surrogate units,
reversed slices, replay metadata and the updateHistory interaction flag. The
source-generated history fixtures now contain 38 histories / 2,782 operations.
Native adaptations and examples are documented in EDITOR-INPUT.md and README.md.
This completes initial-state import; predictive edits, host customization and
systematic interactive verification remain separate work. Physical scroll frame
pacing and the original reported crash remain unverified.


## Predictive editing data layer — 2026-09-19

Final Release suite: **444 tests in 93 suites passed, 15.394 seconds**, log
`/tmp/swift-diffs-prediction-foundation-release.log`. Release demo build succeeded,
log `/tmp/swift-diffs-prediction-foundation-demo.log`. No demo restart or launch.

The bounded request, hunk history and path-matching helpers now match 211 actual
upstream requests, 1,191 history transactions and 216 glob/ECMAScript cases.
Native checks cover response bounds, stale versions, overlapping edits, surrogate
positions, post-edit caret mapping and rejection of a million-character line
without copying its text. The shared regex bridge now correctly compiles literal
astral characters in non-Unicode mode; plain and regex emoji searches are covered.
The initial fixture run exposed a generator timestamp-accounting error and that
regex defect; both are fixed and superseded by this passing full run.

These helpers do not yet schedule provider requests or show ghost text. Provider
cancellation, preview layout/acceptance and a deterministic demo provider remain
next implementation work, alongside custom editor widgets and runtime checks.


## Predictive editor integration — 2026-09-19

Final Release suite: **453 tests in 94 suites passed, 15.503 seconds**, log
`/tmp/swift-diffs-prediction-integrated-release.log`. Release demo build succeeded,
log `/tmp/swift-diffs-prediction-integrated-demo.log`. The newly built demo was not
launched and the running demo was not restarted.

Editable diff → Predictions now exposes local inline insertion, multiline,
replacement and deletion examples plus subtle mode. Native integration verifies
300 ms scheduling, stale providers that ignore cancellation, suspension/resume,
include/exclude filters, Option reveal, paint-gated Tab acceptance, grouped undo,
rejection when affected source is offscreen, IME cancellation, same-line grouping,
sparse supplemental heights and provider replacement. Existing state-import and
multiple-selection tests also pass with the controller integration.

Inspected bitmap artifacts:
- `/tmp/swift-diffs-prediction-multiline.png`
- `/tmp/swift-diffs-prediction-wrapped.png`
- `/tmp/swift-diffs-prediction-deletion.png`
- `/tmp/swift-diffs-prediction-replacement.png`

The optimized 100,000-character ASCII ghost check performed 16 horizontal jumps
and bitmap captures in 79.76 ms total. This confirms bounded automated work for
that fixture; it is not physical display frame pacing. Full custom-theme/suffix
style verification, combined review/custom-widget scenarios and the originally
reported scrolling crash remain part of the final runtime/visual gate.


### Attached editor host customization — 2026-09-19

Implemented asynchronous clipboard reads with upstream paired-selection MIME
metadata, EOL normalization, grouped undo and stale-input cancellation; live
selection-action contexts with inline native popovers; and virtualized custom
collaborator caret views. Added Editable diff → Widgets controls for selection
actions, diagnostics, collaborator/name labels and a delayed system clipboard.

Nine EditorHostCustomizationTests verify paired/malformed paste, provider and
selection changes, suspend/resume, edit-then-undo, current errors, live/expired
contexts, real native mouse drag, split-column bounds, dynamic sizing, reentrant
renderer replacement and 500-caret virtualization. Together with existing
attached-editor, multi-selection, overlay and prediction tests, **55 tests in
five suites passed in 7.405 seconds**
(`/tmp/swift-diffs-host-integration-debug.log`).

Inspected `/tmp/swift-diffs-selection-action.png` (live uppercase action below
a selected range) and `/tmp/swift-diffs-selection-action-split.png` (a deliberately
oversized custom content view constrained to the additions viewport).

The full Release suite passed **462 tests in 95 suites in 15.598 seconds**
(`/tmp/swift-diffs-host-release.log`). The Release demo build passed after making
the example's pasteboard type initializer explicit
(`/tmp/swift-diffs-host-demo.log`). The updated app was not launched or restarted.
This does not close physical frame pacing, IME candidate UI, all-theme visual
parity, or the original 1 MB scrolling-crash investigation.


### Native navigation and callback completion — 2026-09-19

Added AppKit word/paragraph movement and word-forward deletion across local
selections. Paragraph commands use hard-line geometry; word movement uses
Foundation linguistic boundaries, skips folded lines and preserves extended
selection anchors. Command-Left now matches upstream's indentation/start toggle;
Home/End use visual-line bounds. AppKit continues to own marked-text key events.

Five NativeEditorNavigationTests compare native word/paragraph destinations with
NSTextView across six Unicode/CRLF/whitespace samples and exercise folds, wrapping,
backward/multiple selections, grouped deletion undo, actual Option-Shift-Right
routing and Command-Left/Home. The comparison initially exposed punctuation and
CJK differences in NSAttributedString.nextWord; the final implementation uses
Foundation word enumeration and passes the NSTextView comparisons.

The final callback audit added document-history identity checks around custom
renderer calls. A renderer that mutates the document cannot mount stale caret
or action geometry. A discarded clipboard result also clears pending-read state
when only undo-history metadata changed. These cases are covered by the ten
host-customization tests.

Final full Release suite: **468 tests in 96 suites passed, 21.034 seconds**,
`/tmp/swift-diffs-host-final-release.log`. Final Release demo build succeeded,
`/tmp/swift-diffs-host-final-demo.log`. `git diff --check` passed and all explicit
native-disposition implementation/evidence paths exist. This is the final source
checkpoint for this work; the previous 462/467 runs precede the last callback
guards. The demo has updated shortcut help and Widgets controls, but the running
app was not restarted. Physical input, all-locale/bidirectional navigation,
compositor pacing and the original scrolling-crash investigation remain open.


### Prediction suffix decorations and shared-highlighter mapping — 2026-09-19

Fixed a source-backed rendering gap: upstream clones the rendered suffix after
an insertion, retaining all token styles; native previews previously preserved
foreground/font/underline but omitted backgrounds and strikethrough. The canvas
now retains and paints both decorations on visible ghost fragments. Style
replacement clears them. Captures were inspected at
`/tmp/swift-diffs-prediction-suffix-styles.png` (multiline continuation) and
`/tmp/swift-diffs-prediction-suffix-horizontal.png` (10,000-byte horizontal ghost).

PredictionSuffixStyleTests checks colored background and midline strike pixels,
removal after style replacement, and horizontally cropped runs. Window color
profiles transform raw channel values, so assertions use color dominance after
an explicit RGB conversion instead of byte-exact sRGB thresholds. The focused
style test passed in 0.543 seconds; existing prediction integration tests also
passed during the first run, before the color-measurement correction.

Final full Release suite: **469 tests in 97 suites passed, 20.282 seconds**,
`/tmp/swift-diffs-prediction-suffix-release.log`. Release demo build succeeded,
`/tmp/swift-diffs-prediction-suffix-demo.log`. Shared-highlighter lifecycle exports
were reviewed against the current source and mapped in
SHARED-HIGHLIGHTER-CONTRACTS.md, with explicit actor/engine/ownership adaptations.
No running demo was restarted. These checks do not close the original scrolling
crash or physical/compositor performance and full visual-parity gates.
