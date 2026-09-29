# Predictive editing implementation

The bounded data layer is connected to AppKit and SwiftUI editing. The demo's
Editable diff → Predictions menu supplies deterministic local insertion,
multiline, replacement and deletion examples; no network service is required.

## Implemented native contracts

- `buildEditPredictionRequest` produces the upstream excerpt and editable range:
  350 estimated editable tokens, 150 context tokens, hard limits of 512/662,
  and a 128 KiB JSON request limit. It normalizes UTF-16 cursor boundaries, caches
  line eligibility/cost, stops editable expansion at unavailable lines, and
  rejects oversized lines from their lengths without copying them.
- `recordEditPrediction` captures bounded before/after slices from transaction
  inverses, produces unified hunks, coalesces nearby edits within 1,000 ms and
  eight lines, and retains at most ten records. Captures and hunks are limited
  to 6,144 bytes. Undo/redo provide their actual forward/inverse transaction.
- `TextDocument.lastChangeTransaction` is the native value equivalent of upstream's
  weakly associated transaction metadata. Read it immediately after a successful
  apply/undo/redo; it describes the most recent transaction, including a typing
  transaction that coalesced with earlier undo history.
- `matchesEditPredictionPattern` accepts globs and ECMAScript regex/flags through
  the existing bounded regex engine. Flags include Unicode, Unicode sets, dotAll,
  sticky and multiline. Matching starts afresh each call, as upstream does.
  Invalid patterns/flags return false; a native execution limit bounds matching.
- `validateEditPredictionResponse` rejects stale versions, overlap, reversed or
  invalid positions, surrogate splits, edits outside the supplied editable range,
  more than 256 edits, and more than 128 KiB of inserted UTF-8. No-op edits are
  removed. A bounded affected-line slice validates the post-edit caret; the live
  document is unchanged and a multi-edit validation does not rebuild its full
  line index.

JavaScript's mutable objects and AbortSignal are adapted to Swift values,
Task cancellation and stale-result guards. `EditPredictProvider` accepts a
Sendable async throwing closure; it runs in a utility task. Providers should honor
Task cancellation, but results from providers that ignore it are also rejected
after the input or session changes. The native
request/history text APIs use Swift String, which replaces isolated surrogates;
well-formed Unicode retains exact UTF-16 geometry.

## Evidence

`Scripts/diffs/generate-prediction-oracle.ts` executes the supplied upstream source.
`EditPredictionTests` compares 211 request cases, 29 histories with 1,191 applied
or replayed transactions, and 216 glob/regex cases. History expectations are
SHA-256 digests of sorted-key JSON for the complete records, including retained
capture fragments, rather than a count-only assertion. Fixtures cover time/path/
source boundaries, distant edits, cancellation back to the base text, large
captures, CRLF, Unicode, and undo/redo. Separate native tests check response
validation, integer extremes and bounded work on a million-character line.

The regex tests exposed a shared non-Unicode astral-literal conversion defect.
The C bridge now supplies CESU-8 to that engine mode, preserving JavaScript's
UTF-16 literal and character-class behavior. Search regressions cover literal
emoji in both plain and regex queries; prediction fixtures compare both Unicode
and non-Unicode flags against upstream.

## Editor integration

Set `editor.editPrediction`, pass `editPrediction:` to `beginEditing`, or use the
same argument on `EditableFileDiffView`. Nil disables predictions. Keep the
provider value stable across SwiftUI updates; replacing its closure changes its
identity and cancels any previous request.

The controller debounces by 300 ms, requires a single collapsed caret, normalizes
path separators, and applies include/exclude filters with exclusion precedence.
It cancels on input, source, configuration or attachment changes. Requests defer
until the current source and caret line are presented; scrolling back retries an
unavailable caret. Provider failures and invalid responses leave the editor alone.

Same-line edits compose into one ghost group. The existing canvas draws muted
text, a deletion strike, and a moved original suffix. Continuation space uses
sparse supplemental row heights, preserving measured annotations and both split
columns. Wrapping follows the code column's CoreText line breaking. Layout is
cached across scrolling; only visible ghost fragments are painted, with a bounded
line cache and horizontal fragments for long fixed-pitch ASCII. Long ghosts extend
the horizontal scrolling range. Ghost spacer space is not editable source text.

Tab accepts only a drawn preview whose affected source remains visible. Acceptance
is one undo group and records the prediction source. Escape dismisses. Subtle mode
keeps the result hidden until Option is pressed; pressing Option again hides it.
Multi-caret and marked-text sessions suppress requests. Canceling native IME
composition restores its previous prediction history alongside the document.

`canAcceptEditPrediction`, `acceptEditPrediction()` and `dismissEditPrediction()`
let native hosts expose their own controls. The preview is not committed merely
because a provider returned a result.

`EditorPredictionIntegrationTests` covers stale providers, suspension/resume,
filtering, subtle reveal, paint-gated acceptance, undo/redo, deletion/replacement,
offscreen refusal, IME cancellation, sparse heights and long horizontal ghosts.
Multiline, split/wrapped, deletion and replacement bitmap artifacts were inspected.
These are automated native checks, not physical keyboard/trackpad verification or
a full interactive sign-off across every custom theme and review configuration.


Moved insertion suffixes preserve token backgrounds and strikethrough as well as
foreground, font traits and underline. CoreText does not draw NSAttributedString
background/strike attributes itself, so the canvas paints those runs explicitly
around glyph drawing. Enumeration is limited to each visible ghost fragment.
PredictionSuffixStyleTests uses prepared tokens with a known colored background
and strike to check multiline continuation, style replacement and a 10,000-byte
horizontally cropped preview. The native Shiki theme loader currently omits token
backgrounds for some theme rules; supplying prepared token backgrounds remains
supported by this renderer. The two rendered artifacts were inspected:
`/tmp/swift-diffs-prediction-suffix-styles.png` and
`/tmp/swift-diffs-prediction-suffix-horizontal.png`.
