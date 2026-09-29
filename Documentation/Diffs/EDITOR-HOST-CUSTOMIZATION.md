# Attached editor host customization

The implementation follows `src/editor/Editor.ts`, `selectionAction.ts`,
`popover.ts` and `editor.css` in the supplied @pierre/diffs checkout.

## Clipboard reads

Set `DiffEditor.clipboard` or `EditableFileDiffView(clipboard:)` to an
`EditorClipboardProvider`. Its Sendable `readText` closure is async and throwing.
A nil type requests plain text. Multiple selections also request
`EditorClipboardProvider.selectionType`
(`application/vnd.pierre.diffs-selections+json`). A JSON string array with the
right count maps to selections in document order. Invalid metadata falls back
to repeating plain text. Newlines normalize to the document's EOL, and paste is
one undo group. Copy and cut continue writing to AppKit's pasteboard.

```swift
editor.clipboard = EditorClipboardProvider { type in
    try await clipboardService.readText(type: type)
}
editor.paste(nil)
```

Explicit `pasteSelection(from:)` still reads its supplied NSPasteboard directly.
`isReadingClipboard` reports a pending custom read. Replacing the provider,
moving the selection, modifying the document (including edit then undo),
replacing the external source, suspending or completing the session cancels the
read. Identity checks discard stale results even when a provider ignores Task
cancellation. Current read errors reach `onError`; cancellation does not.
This is a deliberate native lifecycle guard beyond upstream's Promise handler.
Providers run off the main actor; use `MainActor.run` when reading NSPasteboard.

## Selection actions

Enable `enabledSelectionAction` and supply an identity-retained
`EditorSelectionActionRenderer`. Its callback receives `SelectionActionContext`
and returns an NSView. SwiftUI callers can return NSHostingView.

```swift
editor.enabledSelectionAction = true
editor.selectionActionRenderer = EditorSelectionActionRenderer { context in
    NSHostingView(rootView: Button("Uppercase") {
        do {
            try context.replaceSelectionText(context.getSelectionText().uppercased())
            context.close()
        } catch { /* Display the host's error UI. */ }
    })
}
```

Mouse and keyboard selections may open the widget. Programmatic selections do
not open a new widget; an already mounted widget reads the live primary
selection. The widget is suppressed during dragging, marked text and collapsed
selection, and removed when the focus row leaves the viewport. Forward
selections prefer below the head; backward selections prefer above it. The
opposite endpoint is the fallback. Placement retains upstream's four-pixel flip
hysteresis, eight-pixel inset, 640-point width cap, rounded nine-point surface
and theme-derived background/border. Geometry uses the wrapped source row and
the additions column in split mode.

The context exposes `selection`, `textDocument`, `getSelectionText`,
`replaceSelectionText`, `applyEdits`, `close` and `isActive`. Replacement edits
only the primary selection, with the prior multi-selection state restored by
undo. `applyEdits` accepts document-wide edits. `textDocument` is a Swift
copy-on-write snapshot, not a JavaScript mutable reference. Expired contexts
return nil/empty values or false and cannot modify or close a newer widget.
Closing, source replacement, suspension, completion and renderer replacement
invalidate the context. Renderer callbacks may synchronously close themselves
or replace the editor configuration without installing stale content.

Content frame changes trigger remeasurement. After changing only intrinsic
content size, call `editor.invalidateWidgetLayout()`. Oversized content is
constrained to the available viewport; hosts should supply a view that responds
to its assigned width. Native shadow rendering replaces CSS box-shadow.

## Custom collaborator carets

Set `caretRenderer` to an `EditorCaretRenderer`. It receives the external
`EditorCaret` and returns a native view whose origin is the focus position.
Selection highlights remain drawn by the canvas; the custom renderer replaces
the default caret bar. Returning nil hides the bar while keeping the highlight.

Only visible focus positions mount views. Scrolling removes offscreen views;
surviving views retain their identity while edits remap their positions.
`setCarets` or replacing the renderer rebuilds visible content. Visible-line
interval queries and a cached source-row lookup avoid scanning all carets or
render rows on every scroll. The caller owns custom label/bar design and any
interaction inside its view.

## Demo and evidence

Editable diff → Widgets exposes selection actions (uppercase/lowercase/close),
diagnostics, collaborator selections/name labels, and a 250 ms delayed system
clipboard reader. Retained renderer/provider values avoid recreating callbacks
on every SwiftUI update.

`EditorHostCustomizationTests` covers paired paste/EOL/undo, malformed metadata,
explicit pasteboards, provider/selection/session changes, edit-then-undo, errors,
live and expired action contexts, actual native mouse drag selection, split
viewport constraints, dynamic height changes, reentrant renderers (including document edits inside render callbacks),
clipboard pending-state cleanup and virtualization across 500 collaborator carets. Placement hysteresis is tested
directly. Native bitmaps were inspected at
`/tmp/swift-diffs-selection-action.png` and
`/tmp/swift-diffs-selection-action-split.png`.

These tests do not establish physical display frame pacing, IME candidate-window
behavior, or completion of the original 1 MB scrolling-crash investigation.
