# Completion audit — 2026-09-19

The original goal remains a 1:1 native Swift/AppKit port of the supplied
@pierre/diffs library, using the local Shiki port, with a feature-complete demo
and responsive large-file scrolling. The goal is **not complete**. This document
distinguishes implemented behavior from missing or insufficient evidence.

## Latest validation checkpoint

2026-09-19: **477 tests in 99 suites passed sequentially** in 56.091 seconds
(`/tmp/swift-diffs-expansion-state-serial.log`). The concurrent full run failed
12 wrapping-deadline assertions; the eight affected tests passed together in
isolation with unchanged deadlines. A later native-window horizontal-offset
regression passed with all four expansion tests; library/demo source was
unchanged after the full run. Demo BUILD SUCCEEDED
(`/tmp/swift-diffs-expansion-state-demo.log`).

Expanded-context map access/replacement and pending-editor state handling are
implemented. Live demo Save/Collapse/Restore controls were verified on hydrated
patch context. The renderer audit identified arbitrary row/decoration hooks as
remaining implementation work; RENDERER-CONTRACTS.md records acceptance criteria.
Nine equality helpers now have explicit field-level dispositions. See
DEMO-VALIDATION.md for runtime scope and the observed horizontal-offset issue.

## Requirements and current evidence

| Requirement | Current evidence | Completion status |
| --- | --- | --- |
| Native macOS library | Package.swift exports ShikiDiffs for macOS 14+, backed by Swift/AppKit/CoreText and the C regex bridge. | Implemented locally. API and cross-feature parity are separate gates. |
| Use the existing native Shiki dependency | Package.swift links ../shiki-swift; DiffHighlighter prepares native tokens; configured streams and editors share registered resources. | Implemented. The package currently requires that sibling checkout. |
| 1:1 upstream behavior and API | EXPORT-AUDIT.md exactly inventories all 108 root re-export modules in the supplied src/index.ts. Diff, patch, inline, hydration, conflict, selection, editor and other fixtures exercise many behaviors. | Unproven. Module presence is not named-export, option, overload, event, error, or lifecycle parity. Named inventories now cover all seven entry points; per-symbol native contract mapping is incomplete. |
| Match upstream UI | Generated upstream vector paths, headers, striped change/empty rows, expandable separators, conflict markers/bands/actions, default/hidden/custom controls, and native theme handling exist. Current conflict bitmaps were inspected. | Partial verification. Cross-theme, font, width, wrapping, input, and accessibility combinations still need a systematic visual/runtime pass. |
| Demo in the same project showing every feature | swift-diffs.xcodeproj and ContentView.swift expose examples and controls; DemoStreamingView covers snapshots, recalls, and cloned tokenizers. Latest Release build succeeded. | Demo exists. Every-feature coverage cannot be proven before the API inventory is complete; selection actions, snapshot restore and inline prediction acceptance are now interactively verified; other combinations remain open. |
| Top performance on roughly 1 MB JSON | The actual 1,141,800-byte demo fixture passed 384 jumps across split/unified, scroll/wrap, expansion and resizing. An independent 1,337,782-byte fixture passed 256 jumps with bounded styled caches. | Partial evidence. Bitmap timings are not display frame pacing or a universal 30 ms preparation guarantee. Cold highlighting, editing, invalidation and larger/long-line workloads need separate budgets. |
| No scrolling jank or lag under fast input | Latest targeted wheel regression delivered 288 drag-phase events, observed 52 positions and eight preview/highlight transitions; bounded cache assertions passed. Synthetic momentum injection failed its movement assertion and is not counted as coverage. | Unproven for physical trackpad momentum, compositor frames, prolonged use and contention. |
| Reported crash while scrolling demo JSON | Expanded tests and live UI-driven whole-file JSON scrolling have not reproduced it; no matching DiagnosticReports entry was found during the recorded investigation. | Unresolved. Do not claim the crash fixed. |
| Retain upstream attribution | LICENSE, THIRD_PARTY_NOTICES.md, upstream-manifest.json, theme notice, and dependency licenses exist. | Artifacts present; this is not a legal review. |

The ordered implementation plan is in IMPLEMENTATION-REMAINING.md. Native
platform boundaries are recorded in NATIVE-PLATFORM-CONTRACTS.md.

## Remaining implementation and audit work

1. Map **named** exports and option/method/event contracts to native APIs. The
   generated upstream-api-inventory.json covers all seven package entry points
   and 513 unique names; NAMED-API-AUDIT.md records parser checks and limits.
   Per-symbol native dispositions remain unreviewed. Record an explicit native adaptation
   for browser-only objects rather than counting an absent DOM object as either
   implemented or automatically irrelevant. Check public component lifecycles,
   not only low-level functions.
2. Verify broader theme combinations and native appearance updates. CSS-variable
   theme creation now matches seven Shiki v3.13.0 fixtures; lazy registration and
   highlighting pass focused tests. The explicit native adapter resolves hex
   colors from host values/defaults rather than implementing a browser cascade.
   The upstream `useTokenTransformer` flag is already mapped to native token
   boundaries, hit testing, wrapped geometry, and source-based copying; see
   EXPORT-AUDIT.md, "Token transformer native adaptation". It is an HTML wrapper
   switch, not a user-supplied transformation callback. HTML/AST output and the
   remaining public renderer methods still require explicit API disposition.
3. Finish unresolved-file component API/lifecycle parity and interactive verification.
   NativeUnresolvedFileView now owns parsing, automatic or controlled action
   dispatch, source updates, highlighting, and cleanup. Tests cover out-of-order
   resolutions, stale handlers, source replacement during preparation, and reuse.
   UnresolvedFileView now provides SwiftUI ownership and is used by the demo.
   UNRESOLVED-FILE-API.md maps owned and inherited contracts, including source
   replacement adaptations and missing lifecycle/hydration APIs. Inherited
   navigation now has direct methods and async component coverage.
   Mount/update/unmount callbacks and cleanup now have native/SwiftUI coverage.
   Virtualized removal now emits unmount and preserves suspended editor state.
   The shared CodeView callback and per-item collapse are implemented and tested.
   Custom-slot-only updates, advanced editor behavior and interactive
   verification remain pending.
4. Audit malformed input and error behavior, especially externally constructed
   metadata passed to rendering functions and other public consumers. Resolution
   source lookups now match 24 upstream cases (seven errors), with separate
   integer-extreme rejection tests. This does not prove all metadata consumers
   cannot trap, nor establish complete error-message parity.
5. Verify combined custom views, theme changes, wrapping, edits, asynchronous
   loading, and review virtualization in the demo. Test user-facing focus,
   keyboard and accessibility behavior alongside visible layout.
6. Obtain a reproducible crash or stronger runtime evidence for the reported
   scrolling failure; measure physical-scroll frame pacing independently of
   synthetic bitmap paint timings.

## Current validation evidence

- Earlier integration: **469 tests in 97 suites passed, 20.282 seconds**
  (`/tmp/swift-diffs-prediction-suffix-release.log`); Release demo build passed
  (`/tmp/swift-diffs-prediction-suffix-demo.log`). Predictive insertion suffixes
  now preserve token backgrounds and strikes across multiline and horizontally
  cropped rendering; inspected images and color-profile-aware pixel checks
  verify those decorations and removal after a style change. Shared-highlighter
  exports now have an explicit native contract map. The running demo was not
  restarted. Overall parity, systematic runtime verification and the original
  scrolling crash remain open.

- Previous integration: **468 tests in 96 suites passed, 21.034 seconds**
  (`/tmp/swift-diffs-host-final-release.log`); Release demo build passed
  (`/tmp/swift-diffs-host-final-demo.log`). Includes ten host-customization tests
  and five native navigation tests. Native word/paragraph destinations are
  compared against NSTextView; modifier routing, folded/wrapped movement,
  multi-caret deletion/undo, renderer-triggered document mutations and pending
  clipboard cleanup are verified. Final callbacks cannot install geometry from
  before their own document edit. The running demo was not restarted.
  Remaining gates: per-export contract review, systematic visual/physical input
  validation, and the original large-JSON scrolling-crash investigation.

- Previous integration: **462 tests in 95 suites passed, 15.598 seconds**
  (`/tmp/swift-diffs-host-release.log`); Release demo build passed
  (`/tmp/swift-diffs-host-demo.log`). Host customization adds asynchronous
  clipboard reads, selection-action popovers and virtualized custom collaborator
  carets. Nine new tests cover callbacks, cancellation, native mouse input,
  placement, resizing and reentrancy; 55 focused editor tests also passed.
  Single-column and split-column popover bitmaps were inspected. Demo controls
  are under Editable diff → Widgets; the running app was not restarted.
  Remaining navigation/API review and systematic physical runtime verification
  remain open, including the original scrolling crash.

- Previous integration: **453 tests in 94 suites passed, 15.503 seconds**
  (`/tmp/swift-diffs-prediction-integrated-release.log`); Release demo build passed
  (`/tmp/swift-diffs-prediction-integrated-demo.log`). Predictive editing now has
  cancellable providers, eager/subtle modes, virtualized ghost presentation,
  split/wrapped spacers, paint-gated acceptance and grouped undo. Nine native
  integration tests cover lifecycle, IME, filtering and long horizontal ghosts.
  Multiline, wrapped, deletion and replacement bitmaps were inspected. The demo's
  Predictions menu is built, but its executable was not launched or restarted.
  Host widgets/clipboard, remaining navigation/API review and systematic runtime
  verification remain open, including the original scrolling crash.


- Previous integration: **444 tests in 93 suites passed, 15.394 seconds**
  (`/tmp/swift-diffs-prediction-foundation-release.log`); Release demo build passed
  (`/tmp/swift-diffs-prediction-foundation-demo.log`). Adds bounded predictive
  request/history/path helpers and response validation, plus an astral-literal
  regex fix shared with search. Upstream comparisons cover 211 requests, 1,191
  history transactions and 216 patterns. Provider scheduling and ghost rendering
  are not yet connected; see EDIT-PREDICTION.md. The updated demo was not launched.


- Previous integration: **439 tests in 92 suites passed, 15.252 seconds**
  (`/tmp/swift-diffs-state-final.log`); Release demo build passed
  (`/tmp/swift-diffs-state-final-demo.log`). Adds initial-state import with
  independent draft/history snapshots, native undo/redo registration, keyed
  precedence, file identity, partial viewport, empty folds, provisional IME and
  SwiftUI attachment coverage. Document access and replay metadata are covered;
  actual upstream fixtures now compare 38 histories / 2,782 operations. The
  demo exposes Session save/restore; its updated executable was not launched.
  Predictive editing, custom editor widgets, systematic interactive verification
  and the original reported scrolling crash remain open.


- Previous integration: **427 tests in 90 suites passed, 15.182 seconds**
  (`/tmp/swift-diffs-input-final.log`); Release demo build passed
  (`/tmp/swift-diffs-input-final-demo.log`). Includes multiple local selections,
  Option-drag, Command-D, paired clipboard, view-state restoration, custom keymaps,
  coalesced and capped undo, history snapshots, configurable native history limits
  and provisional IME redo invalidation. Source-derived fixtures cover 771
  selection cases and 2,775 history operations. The multiple-caret bitmap was
  inspected; the updated demo was built, not launched. The full Debug run hit
  17 timeout/readiness assertions under unoptimized megabyte workloads; the final
  optimized run passes all tests without loosening their bounds.
  Physical scrolling and the original reported crash remain unverified.

- Previous integration: 409 tests in 87 suites passed, 15.283 seconds
  (`/tmp/swift-diffs-editor-stream-final.log`); Release demo build passed
  (`/tmp/swift-diffs-editor-stream-final-demo.log`). Adds bounded syntax-aware
  bracket matching, selected-text surrounding, focus/blur, independent active
  lines and adaptive streaming. All tokenization entry points now retain default
  syntax classifications consistently; explicit stream options still override
  defaults. Earlier metadata-consistency failures are superseded by this run.
  The updated demo was built, not launched. Physical scrolling and the original
  reported crash remain unverified.

- Previous integration: 398 tests in 85 suites passed, 19.857 seconds
  (`/tmp/swift-diffs-stream-editor-full.log`); Release demo build passed
  (`/tmp/swift-diffs-stream-editor-demo.log`). Includes declarative review editing,
  keyed draft/history retention, external source replacement, diagnostics,
  collaborator selections, atomic edit batches and the owned streaming view.
  Wrapped overlay snapshots were inspected; the updated demo was not launched.


- Declarative review editing: 384 tests in 82 suites passed, 20.425 seconds
  (`/tmp/swift-diffs-managed-editing-full.log`); Release demo build passed
  (`/tmp/swift-diffs-managed-editing-demo.log`). Lazy edit factories, default
  rejection, accept/reject callbacks and demo edit controls are implemented.
  The updated demo has not been launched for interactive verification.


- Review/component controls: 380 tests in 81 suites passed, 14.976 seconds
  (`/tmp/swift-diffs-component-controls-full.log`); Release demo build passed
  (`/tmp/swift-diffs-component-controls-demo.log`). Per-item collapse, shared
  lifecycle callbacks and component configuration APIs are now implemented.

- Reentrant review reconciliation: reproduced and fixed a suspended-editor /
  duplicate-attachment failure when unmount replaces a review containing a
  reused view. Full Release suite passed 371 tests in 78 suites, 20.772 seconds
  (`/tmp/swift-diffs-reentrant-reuse-full.log`); Release demo build succeeded
  (`/tmp/swift-diffs-reentrant-reuse-demo.log`).

- Virtualized cleanup: 370 tests in 78 suites passed, 20.346 seconds
  (`/tmp/swift-diffs-virtual-lifecycle-full.log`); Release demo build succeeded
  (`/tmp/swift-diffs-virtual-lifecycle-demo.log`). Retired snapshots release
  presentation, editor undo survives remount, and unmount may replace the review.

- Presentation lifecycle: full Release suite passed 366 tests in 77 suites,
  19.803 seconds (`/tmp/swift-diffs-post-render-full.log`); Release demo build
  succeeded (`/tmp/swift-diffs-post-render-demo.log`). Tests cover reentrant
  mount/unmount callbacks and editor discard/recycle with retained undo.

- Folded-line navigation: 12,544 upstream probes and native callback/reveal tests
  pass. Full Release suite: 359 tests in 76 suites, 20.274 seconds,
  `/tmp/swift-diffs-navigation-full.log`. NativeDiffView now exposes visibility,
  nearest renderable line, and reveal APIs; the broader named API audit remains open.

- Latest targeted wheel run: `/tmp/swift-diffs-wheel-preview-verified.log`,
  one test passed, 5.237 seconds; 288 drag events and eight preview transitions.
  Bitmap paint median 2.935 ms, maximum 3.452 ms; not display frame timings.
- Earlier full run: `/tmp/swift-diffs-conflict-token-reuse-verified.log`,
  355 tests in 75 suites passed, 18.621 seconds; Release demo build passed in
  `/tmp/swift-diffs-conflict-token-reuse-demo.log`. Display updates now reuse
  conflict syntax tokens and retain pending highlighting with the latest layout.
- Prior full run: `/tmp/swift-diffs-unresolved-swiftui-verified.log`,
  353 tests in 75 suites passed, 15.035 seconds; Release demo build passed in
  `/tmp/swift-diffs-unresolved-swiftui-demo-final.log`. The owned conflict
  component is now demo-integrated, but has not been operated interactively.
- Prior full run: `/tmp/swift-diffs-unresolved-view-full.log`, 350 tests in
  75 suites passed, 18.919 seconds; Release demo build passed in
  `/tmp/swift-diffs-unresolved-view-demo.log`. The ownership component has not
  yet been integrated into or operated in the demo.
- Prior full run: `/tmp/swift-diffs-css-themes-full.log`, 345 tests in
  74 suites passed, 18.650 seconds; Release demo build passed in
  `/tmp/swift-diffs-css-themes-demo.log`. The new theme picker option has not
  been operated interactively.
- Prior full run: `/tmp/swift-diffs-resolution-validation-full.log`,
  342 tests in 73 suites passed, 19.210 seconds; Release demo build passed in
  `/tmp/swift-diffs-resolution-validation-demo.log`.
- Latest full run before the final custom-action geometry refinements:
  `/tmp/swift-diffs-custom-conflict-full.log`, 340 tests in 72 suites passed,
  19.214 seconds. Its synthetic wheel bitmap paint median was 3.232 ms and
  maximum 4.734 ms; the separate JSON jump/paint median was 7.627 ms, p95
  8.299 ms, maximum 9.032 ms. These are workload/run-specific diagnostics.
- After the custom-action minimum-height and indexed-lookup refinements:
  `/tmp/swift-diffs-custom-conflict-final.log`, 11 focused tests passed;
  `/tmp/swift-diffs-custom-conflict-demo-final.log`, Release demo build succeeded.
- DEMO-VALIDATION.md records observed artifacts and runtime limitations. Earlier
  entries are historical; later corrections supersede their narrower claims.

No completion gate above can be closed solely because the test count increases,
the build succeeds, or a root module has a native mapping.
