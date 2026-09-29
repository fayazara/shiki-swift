# Shared highlighter contract

Reviewed against `src/highlighter/shared_highlighter.ts` in the supplied
@pierre/diffs 1.4.2 checkout. Native implementation lives in `RenderingModel.swift`.

| Upstream export | Native contract |
| --- | --- |
| getSharedHighlighter | `DiffHighlighter.getSharedHighlighter(languages:themes:)` preloads resources and returns the shared actor |
| preloadHighlighter | `DiffHighlighter.shared.preload(languages:themes:)`; isolated actors expose the same preload method |
| getHighlighterIfLoaded | Actor method with optional required language/theme arrays; checks attachment without initiating loads |
| isHighlighterLoaded | Actor property; reads whether the underlying Shiki engine exists |
| isHighlighterNull | `!isHighlighterLoaded`; native actor identity may exist before its engine does |
| isHighlighterLoading | Engine construction is synchronous inside the actor, with no separately observable Promise state; resource resolution is asynchronous and is awaited by preload/prepare |
| disposeHighlighter | Actor method releases its engine and caches, invalidates pending preparation, and retains custom registrations for later reload |

Upstream's optional argument to its state predicates can inspect arbitrary
highlighter/Promise/undefined values. Native callers inspect the actor instance
they own. The port does not expose a fabricated Promise or an always-false
loading flag. A loaded engine does not imply a particular resource is attached;
use `getHighlighterIfLoaded(languages:themes:)`, `areLanguagesAttached` and
`areThemesAttached` for that distinction. Reading readiness never constructs
the engine or starts a resource load.

The source can choose a JavaScript or WASM regex engine. The native port uses
the supplied shiki-swift dependency's native Oniguruma engine; it has no browser
engine-selection option. Both bundled Pierre theme names are reserved at actor initialization; their
engine resources load during engine construction. Language preload deduplicates requests and bypasses grammar
resolution for text/ANSI. Cached resources attach immediately; unresolved
languages/themes begin asynchronously and attach after ordered completion.

Disposal uses a lifecycle generation to reject preparation that resumes from an
old async loader. Registered loaders survive. Prepared value documents remain
usable. Existing stream configurations retain their own native engine ownership,
so disposal does not invalidate an already-created stream; subsequent requests
on the actor reload. This ownership model differs from disposing a shared
JavaScript object in place.

Evidence: `LazyLanguageTests` covers readiness, settings-aware lookup, duplicate
loads, resource attachment and grammar/cache invalidation. `LazyThemeTests`
covers registration, reload, failures, concurrent resolution and stale theme
results after cleanup/disposal. `StreamConfigurationTests` covers retained
stream configuration after disposal. The full Release suite also runs these
tests. This mapping covers these seven exports; it does not close the separate
worker transport or renderer contracts. Resource wrappers are reviewed
separately in RESOURCE-RESOLVER-CONTRACTS.md.
