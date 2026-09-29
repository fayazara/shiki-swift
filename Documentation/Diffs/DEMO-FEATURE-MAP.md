# Demo feature map

These are implemented paths in the demo source. Builds and automated native
checks do not constitute an interactive sign-off for every path.

| Feature | Demo path |
| --- | --- |
| Split/unified diffs, word/character changes, context size | Swift refactor or TypeScript component; display/comparison controls |
| Installed monospaced fonts, Pierre Light startup, theme choice | Appearance controls |
| Classic/bars/none indicators; empty striped partner cells | Diff indicators control; additions/deletions in Swift refactor |
| Collapsed context and custom separators | Patch with collapsed context; separator picker and expansion controls |
| Saved context expansion | Patch with collapsed context → Load full patch contents; expand rows, Save expanded context / Collapse expanded context / Restore expanded context |
| Partial-source hydration | Patch with collapsed context; load-full-files control |
| Headers, status glyphs, prefix/suffix/metadata slots | Header controls; Renamed/New/Deleted file samples |
| Merge conflict actions and custom controls | Merge conflicts; current/incoming/both and conflict control mode |
| Plain files | Highlighted file |
| Large document, long lines, Unicode and line endings | Large JSON · 1 MB, Long lines, Unicode & line endings |
| Default/custom annotations and gutter actions | Annotations and Gutter utility toggles |
| Token clicks, hover, popovers, controlled selection | Interaction controls in ordinary diff samples |
| Mixed file/diff review, appends, selection, smooth navigation | Multi-file review; Add 20 files / Select last file / Glide controls |
| Per-item and bulk collapse | Multi-file review; Collapse all / Expand all / Toggle first file |
| Declarative editing and completion decisions | Multi-file review; Automatically edit first file / Accept edits when editing ends |
| Keyed drafts and undo across sessions | Multi-file review; Remember drafts and undo, end and restart automatic editing |
| Retained imperative editing | Multi-file review; Edit first file / Save edit / Discard |
| Attached native text input, search, undo and diff-region updates | Editable diff; editing and apply/discard controls, standard shortcuts |
| Diagnostic underlines and native popovers | Editable diff; Diagnostic markers; hover the highlighted source range |
| Matching brackets and surrounding selected text | Editable diff → Typing; bracket toggle and surround mode |
| Multiple local carets and paired clipboard | Editable diff; Option-click/drag, Command-D, typing, copy/paste and Escape |
| Coalesced typing/deletion and IME undo | Editable diff; type or delete repeatedly, then Command-Z / Shift-Command-Z |
| Predictive edits and eager/subtle presentation | Editable diff → Predictions; local insertion/multiline/replacement/deletion examples, Option reveal, Tab accept and Escape dismiss |
| Initial editor state and independent snapshots | Editable diff → Session → Save draft snapshot / Restore saved snapshot |
| Custom keyboard bindings | Editable diff → Typing → Custom shortcut: ⌘D duplicates line |
| External collaborator selection | Editable diff; Collaborator selection |
| Standalone AppKit text editing | Native editor; native find/selection/input methods |
| Snapshot streaming | Streaming code → File snapshots |
| Library-owned streaming lifecycle | Streaming code → Managed stream; Stop / Replay; line labels start at 42 |
| Adaptive streaming | Managed stream → Appearance; switch Light/Dark/System during or after streaming |
| Token recall and immutable tokenizer branches | Streaming code → Token recalls / Tokenizer branches |
| Lazy custom grammar and extension resolution | Custom language |

## Still not available as complete demo features

Editable diff → Widgets exposes selection actions, collaborator name labels and
a delayed clipboard reader. EDITOR-HOST-CUSTOMIZATION.md records their contracts. Independent active-line and focus controls are exposed through the native API; a dedicated demo control is not yet added. Physical
scroll momentum, the originally reported crash, IME candidate windows and the
full accessibility experience remain runtime verification gaps.
