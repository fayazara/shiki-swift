# Unresolved-file component contract audit

Source: local @pierre/diffs `src/components/UnresolvedFile.ts` and inherited
`src/components/FileDiff.ts`. This is a focused contract map, not a claim of
complete component parity.

| Upstream contract | Native surface and evidence | Remaining difference or work |
| --- | --- | --- |
| Own parsed source, actions and marker rows | `NativeUnresolvedFileView.state`, `render(file:)`; `UnresolvedFileViewTests` covers automatic resolution and stable action identities. | Native state is one atomic value, rather than three optional render properties. |
| Automatic resolution callback after source commit | `.automatic(onResolve:)`, `performResolution`; callback reads committed source. | Plain presentation callback precedes resolution callback; asynchronous syntax presentation emits a later update. Cross-component lifecycle ordering remains under audit. |
| Controlled action callback without implicit commit | `.controlled(onAction:)`, pure `resolveConflict`, then `render(state:)`; tested. | Upstream optional fileDiff argument to resolveConflict is not exposed by the component. |
| Action and resolution callbacks mutually exclusive | `UnresolvedFileBehavior` enum makes the invalid combination unrepresentable. | Intentional Swift type-system adaptation of upstream runtime error. |
| Unified layout and no inline change highlighting | Forced for all owned conflict renders, including after final resolution; tests cover source updates and final state. | Cross-feature visual review remains open. |
| File source initialization and replacement | Explicit native `render(file:)` starts a new source identity; SwiftUI retains resolved state while its input is unchanged. | Upstream permits file-only initialization once and rejects later different source in both modes; native intentionally exposes replacement. This is a documented behavioral adaptation, not exact render-call parity. |
| `setOptions` / annotations | `render(state:options:annotations:)` and SwiftUI inputs preserve source identities, reuse tokens, and retain pending highlighting. | `setOptions`, `setLineAnnotations` and `rerender` now exposed and tested without restoring resolved conflicts. |
| `isLineRenderable`, `getNearestRenderableLine`, `revealLine` | Direct methods on the owned view delegate to the current native diff. Shared upstream fixtures cover metadata semantics; component test covers preview-to-highlight retention, source reset and cleanup. | Native errors are Swift throws. Lines are one-based on the new-file side, not conflict-source marker offsets. |
| Other inherited interaction and rendering methods | Exposed through owned `diffView`: selection, hovered line, expansion, scrolling, headers, annotations, custom gutter/separator/action controls. | Per-method inherited lifecycle parity is not proven merely by exposing the child. |
| `cleanUp` | Cancels pending work, invalidates captured actions, clears presentation/state, and supports reuse; tested. | Lifecycle tests cover exactly-once unmount and callback replacement during teardown. Broader virtualization integration remains open. |
| `onPostRender(node, instance, phase)` | `onPostRender(instance, PostRenderPhase)` on native and SwiftUI conflict views; the NSView is both container and instance. Mount/update/unmount include asynchronous highlight presentation. | Inherited custom-slot-only updates need separate audit; shared CodeView lifecycle callbacks now have integration coverage. |
| `hydrate` with prerendered HTML and container | Not implemented as HTML hydration. | Requires explicit native precomputed-presentation contract; `render(state:)` alone does not reproduce SSR or DOM adoption. |
| Public type and instance ID | Swift type and object identity. | Any required string ID/dispatch adaptation is still unmapped. |

The new-file line-navigation contract is independent of bitmap draw timing and
physical display refresh. Passing it does not resolve the reported scrolling
crash or establish momentum performance.
