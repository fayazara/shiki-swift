# Remaining implementation plan

This replaces open-ended module-by-module expansion as the working order.
The target remains the requested native 1:1 port; a passing build alone does not
close a row. Browser APIs require a documented native equivalent, not a silent
exclusion or a fabricated DOM API.

| Order | Deliverable | Exit evidence | State |
| --- | --- | --- | --- |
| 1 | Review item controls: per-item collapse, retained edit sessions, item callback ownership | Native integration and demo controls for mixed file/diff reviews, scroll/wrap, edit/collapse/expand | Per-item collapse, retained editor tests and shared lifecycle callback implemented; demo controls added |
| 2 | Component controls: options, annotations, rerender, prepared-state installation, cleanup | File, diff, conflict and stream method map with examples and verified behavior | Component controls and owned streaming implemented; COMPONENT-CONTRACTS.md maps prepared state and native differences; adaptive streaming, bracket matching, automatic surrounding, focus and independent active lines are implemented; host customization, initial-state import and predictive editing are implemented; full physical input/runtime validation remains open |
| 3 | Shared review callbacks and declarative edit ownership | Source-matched signatures/adapters; demo shows item identity and session outcomes | Shared callbacks, declarative editing, keyed retention and external replacement implemented and tested |
| 4 | Public utility/renderer/highlighter contract map | Every named export assigned implementation, native adaptation or concrete missing work with source evidence | Inventory and focused component/editor maps exist; per-export assignments remain incomplete |
| 5 | Demo feature coverage | Each native user-facing feature linked to an operable demo path; no compile-only claims | DEMO-FEATURE-MAP.md links implemented controls; live selection actions, snapshot restore and prediction acceptance verified; broader interactive sign-off remains |
| 6 | Visual parity | Side-by-side reference checks for themes, headers, indicators, folds, padding, conflicts, selection, wrapping and custom content | Major visuals implemented; systematic verification incomplete |
| 7 | Scroll crash and runtime performance | Reproduction/fix or clearly bounded investigation; real scroll/frame evidence separate from bitmap timings | Entire JSON file and repeated scroll reversals exercised without crash; original cause and physical frame pacing remain unresolved |
| 8 | Final delivery audit | All preceding rows supported by current evidence; package/demo build and regression suite pass | Open |

Do not count exports or tests as a percentage of completed behavior. If a
contract audit uncovers a missing implementation, add it to the matching row
with a concrete acceptance case rather than starting an unrelated polish cycle.

## Declarative editing contract

`CodeViewItem.edit` requests a lazily created editor through the host's native
factory. Collapse/virtualization suspend it; edit=false completes it; removal
and reset notify without reinserting the item. Completion defaults to reject.
The host receives resolved metadata and the owning item, and accepted prepared
snapshots are published through onItemsChange after asynchronous highlighting.
This adapts upstream's synchronous nextItem construction to HighlightedDiff.
Explicit retention keys now restore draft/history/annotations/selection across
separate sessions through EditStateManager. External changes update mounted and
offscreen editors and notify the owning item. Native completion remains async
because accepted snapshots are highlighted before publishing. Custom
selection/caret widgets and asynchronous clipboard reads are implemented;
EDITOR-HOST-CUSTOMIZATION.md records their native lifecycle adaptations. This
row does not claim complete input/runtime verification.

Multiple local selections, view-state restoration, custom keymaps and bounded
undo grouping are now implemented; EDITOR-INPUT.md maps their native contracts
and source-backed evidence. Initial-state import now restores documents, history,
selections, annotations, baselines, folds and viewport through AppKit and SwiftUI.

Predictive requests, history, cancellation, ghost layout, eager/subtle modes and
accept/dismiss controls are implemented and exposed in the demo. See
EDIT-PREDICTION.md for source comparisons and native integration evidence.

## Remaining attached-editor implementation

1. Finish the per-export contract review. Native word/paragraph navigation,
   public document convenience methods and replay metadata are implemented.
   EDITOR-INPUT.md records source shortcut handling and native segmentation
   comparisons; physical IME and bidirectional input remain runtime checks.
2. Complete the systematic visual/input pass using the existing demo controls.
   Host customization now has selection-action, custom-caret and delayed-paste
   examples. Keep physical frame pacing and the original scrolling crash as separate
   runtime gates; synthetic scroll/bitmap timings do not close them.

## Standalone header gap closed

The source `stickyHeader` default is now matched by DiffRenderOptions: false
scrolls a standalone header with the code; true pins it. File, conflict and
SwiftUI hosts forward the same option, and CodeView retains review-owned header
geometry. The demo exposes a Sticky header toggle. AppKit content insets keep
code coordinates stable; editor snapshots store nonnegative logical offsets.

StandaloneHeaderTests cover mode transitions, custom heights, empty documents,
search placement and viewport round trips. The full Release suite passed 474
tests in 98 suites (21.236 s). Live validation confirmed both modes on the Swift
example and expanded 12,004-line JSON, including whole-file reverse scrolling.
This closes this specific option; it does not close physical frame pacing or
the original unexplained crash.

## Renderer extension gap

RENDERER-CONTRACTS.md maps concrete renderer methods and identifies the missing
arbitrary row injection and line-decoration hooks. Built-in conflict/annotation
rows are implemented, but do not provide a complete host extension API. The
acceptance criteria there keep this as implementation work rather than silently
classifying it as a DOM-only feature. Expanded-context snapshots/replacement are
now implemented, including pending-editor and virtualized review ownership.
