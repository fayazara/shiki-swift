# Attached editor input and history

The native editor uses the same visible AppKit/CoreText canvas as the diff.
It does not overlay an NSTextView or allocate a view per selection.

## Multiple selections

`getSelections()` and `setSelections(_:)` use zero-based UTF-16 positions. The
last selection is primary. Overlaps merge, retaining the most recently added
selection's order and direction; touching nonempty ranges stay separate.
Option-click adds a caret and Option-drag extends the added selection. Command-D
first expands collapsed carets to words, then adds an unoccupied exact match,
wrapping at EOF. Escape keeps only the primary selection, then collapses it.

Typing, surrounding, IME candidates, deletion, indentation, comments, line
commands and undo/redo operate across all local selections. Secondary geometry
uses the same wrapped CoreText fragments and visible-line interval lookup as
other overlays. Copy writes plain text and upstream's
`application/vnd.pierre.diffs-selections+json` pasteboard data. Paired paste maps
selections in document order; unmatched/plain text repeats at each selection.

`getViewState()` and `setViewState(_:)` capture/restore selections and native
scroll coordinates. A supplied viewport is preserved instead of revealing the
caret, including through asynchronous rendering and suspension. View state
requires an attached editor to restore. Empty selections survive keyed retention.
Word expansion uses Foundation word segmentation; exact Intl.Segmenter behavior
for every locale is not established.

## Keyboard customization

`EditorKeymap` compiles upstream shortcut strings when constructed. Later groups
win and custom bindings precede defaults. Only global and macOS groups apply;
Windows/Linux groups can remain in shared configuration. AppKit event characters
win over physical ANSI key fallback; navigation/function keys use virtual codes.
Malformed shortcut strings are ignored. Caps Lock and numeric-pad flags are not
shortcut modifiers. Marked-text events stay with the AppKit input method.

```swift
editor.keymap = EditorKeymap([
    .init(platform: .mac, bindings: ["cmd+d": .copyLineDown, "F6": .toggleComment])
])
editor.performCommand(.findNextMatch)
```

`EditableFileDiffView(keymap:)` forwards changes. The Editable diff demo exposes
its custom Command-D override under Typing and lists multi-caret shortcuts in
the keyboard popover. Native integration covers actual NSEvent routing; physical
keyboard layouts and candidate windows still require interactive verification.

## Undo history

`TextDocument` uses `EditStack`, with a default capacity of 100 entries. Its
coalescing rules match upstream: adjacent typing and same-direction deletions
can merge; newline-changing transactions, explicit boundaries and replay break
groups. Multi-caret edits must all agree on the mode and geometry. The first
selection/annotation state and latest resulting state are retained.

`DiffEditor` bridges that history to NSUndoManager, limits it to 100 user-visible
groups, and treats a complete IME composition as one group. An IME group can
contain several document transactions. Paste, programmatic edits, line commands
and explicit `breakUndoCoalescing()` establish boundaries. Suspension also closes
the native input group. Change callbacks run after undo registration, allowing
an immediate undo from the callback. Provisional IME text reports undo available,
invalidates redo, and is committed before programmatic replay. Keyed retention
preserves both redo and undo.

`TextDocument.history` and `EditStack.getState()` return independent Swift
copy-on-write values. Supply `EditStack(state:)` to a TextDocument initializer to
transfer developer-edited history into another document. This is a native value
adaptation, not JavaScript's mutable live object. The caller must supply text and
version consistent with imported history.
`beginEditing(historyMaxEntries:)` and `EditableFileDiffView(historyMaxEntries:)`
configure the native group capacity at construction (minimum one); keyed
retention preserves the saved capacity.

## Initial editor state

`editor.getEditState()` captures a Swift value snapshot. Pass
`EditorInitialState(snapshot)` to `beginEditing(initialState:)` or
`EditableFileDiffView(initialState:)`. The latter reads it only on attachment;
`onEditorAttached` exposes the active editor. The demo's Editable diff → Session
menu saves and restores a snapshot by remounting the editor.

Partial `EditorInitialState` fields default to the target component. Explicit
state wins over dormant keyed state. File/diff type mismatches throw before
claiming a key. Known filename/language changes reset an unkeyed imported draft;
an explicit retention key preserves the saved file identity. Explicit empty
selections and fold expansions remain empty. A partial viewport keeps omitted
coordinates from the target.

Import restores document/history, undo and redo groups, selections, annotations,
diff baseline, folds and scroll position without replaying edits or emitting
change callbacks. A snapshot of provisional IME text creates one undoable group
in the copy without committing the original input session. Developer-modified
history invalidates stale private grouping metadata; entries without saved
selection/annotation metadata remap the current state during replay. Value
ownership keeps both editors independent rather than sharing JavaScript objects.

## Document access and replay

`positionsAt`, `normalizePosition`, `getLineLength`, `getTextSlice` and `charAt`
provide the upstream convenience operations. `getLineTextChecked` throws for an
invalid line; the existing `getLineText` remains a clamping native convenience.
`utf16CodeUnit(at:)` preserves raw surrogate units; Swift String results replace
isolated surrogates with U+FFFD. Reversed slices return an empty string.

`undoResult` and `redoResult` include selections, annotations and selection-remap
edits; the original `undo`/`redo` methods still return only the change.
`updateHistory: false` suppresses interaction metadata and explicit undo boundaries,
while the text transaction remains undoable, as in upstream.

## Validation

- 512 selection merge cases and 259 replacement cases execute the actual local
  upstream implementation (`generate-multiselection-oracle.ts`).
- 38 histories / 2,782 operations compare text, versions, history entry counts,
  forward/inverse edits, selection metadata and coalescing against actual upstream
  (`generate-history-oracle.ts`). Includes typing/deletion at multiple carets,
  surrogate boundaries, replay branching, newline boundaries and bounded eviction.
- Native tests cover Option-drag, Command-D, viewport restoration, clipboard,
  composition commit/cancel, capped history with annotations, callback replay,
  custom keymaps and keyed retention. A multiple-caret bitmap was inspected.

Predictive provider and preview evidence is documented in EDIT-PREDICTION.md.
Host customization is documented in EDITOR-HOST-CUSTOMIZATION.md. Broader
input-method behavior and physical scrolling remain to verify.


## Native word and paragraph navigation

AppKit word-left/right and word-backward/forward selectors now move every local
caret; their selection-modifying variants retain each selection's anchor and
direction. Word-forward deletion is one undo group across all selections.
Paragraph selectors operate on hard lines rather than visual wrap fragments;
repeated paragraph-forward/backward extension crosses hard-line boundaries.
Movement skips folded lines through the existing renderable-line index.

Upstream handles ordinary arrows, Home/End and primary-modifier arrows itself,
but leaves Option-word/paragraph movement to browser-native selection. The port
uses Foundation linguistic word segmentation for this native adaptation, with
comparisons against the installed NSTextView command behavior. It visits hard
lines as needed without constructing a second text view or copying the whole
document. All-locale and bidirectional visual-navigation equivalence is not
claimed.

Command-Left uses upstream's smart indentation toggle: first nonwhitespace,
then visual line start. Control-A remains visual line start. Home/End also use
visual-line bounds. Custom keymaps still take priority, and marked-text key
events remain owned by the input method. Default Option-Up/Down and
Shift-Option-Up/Down retain upstream's move/copy-line key bindings; hosts can
invoke paragraph selectors through AppKit or their own commands.

NativeEditorNavigationTests compares every grapheme-boundary cursor in six text
samples against NSTextView for word/paragraph movement, including punctuation,
emoji, combining marks, CJK, blank lines and CRLF. It also covers folded/wrapped
geometry, multi-caret selection/deletion/undo, backward selection anchors,
Option-Shift-Right opening a selection action, and Command-Left/Home routing.
