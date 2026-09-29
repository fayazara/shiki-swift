# Browser-to-native contract boundaries

The requested deliverable is an AppKit library, not a browser embedded in a
macOS window. These mappings identify where upstream browser machinery lands.
They are **not** a blanket completion disposition for every export in a group.
Public methods still need an individual contract reference in the named audit.

| Upstream mechanism | Native mechanism already present | Outstanding boundary |
| --- | --- | --- |
| DOM/HAST code, gutter, row and separator nodes | DiffRenderPlan rows and CoreText DiffCanvas; NativeDiffView is the public host | No public HAST/HTML tree output; node-producing helper contracts need explicit disposition |
| Header, annotation, gutter and conflict action slots | AppKit NSView renderers with native layout and hit testing | Some slot-only lifecycle events remain unaudited |
| CSS theme variables and stylesheets | ShikiTheme, DiffPalette, concrete native color resolution, DiffRenderOptions | Arbitrary CSS cascades and unsafe stylesheet injection are not implemented; appearance must map to typed options/views |
| React component identity, properties and selection | NSViewRepresentable views, Coordinators, SwiftUI Binding and CodeViewController | Complete hook/context and shared callback correspondence remains under review |
| requestAnimationFrame / resize observers | AppKit invalidation/layout, frame-size observers and display links for scroll animation | Public queue/dequeue callbacks are not exposed as a standalone render scheduler |
| Web Worker preparation | DiffHighlighter actor, cancellable preparation tasks, stale-result guards and token caches | Browser worker protocol/statistics and pool configuration are not a native public API |
| SSR HTML and DOM hydration | Preparing HighlightedDiff off the UI actor and installing it on a native view | No HTML serialization or DOM adoption; public preload/hydration signature map is unfinished |
| JavaScript mutable maps and reference identity | Actor-owned registries, exact UTF-16 identifiers, Swift value structs and explicit reference wrappers | No direct mutation of loader tasks or internal engine maps |
| String-detach buffers | Swift owned strings and copy-on-write value storage | No same-named byte-detach buffer API; source/cache retention is tested separately |
| Browser scroll synchronization | One NSScrollView for both diff columns | Real device momentum/frame pacing still needs evidence |

For implementation priorities, use IMPLEMENTATION-REMAINING.md. A browser helper
without a same-named Swift declaration is not automatically a missing native UI
feature; conversely, a general native mechanism is not proof that every public
upstream contract has been ported.
