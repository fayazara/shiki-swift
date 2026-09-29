# Language and theme resolver contracts

Reviewed against the supplied `src/highlighter/languages/*.ts` and
`src/highlighter/themes/*.ts` wrappers. The native implementation is the
`DiffHighlighter` actor in RenderingModel.swift, plus CSSVariablesTheme.swift.
These are native adaptations, not JavaScript object/Promise-shaped APIs.

| Source exports | Native contract |
| --- | --- |
| registerCustomLanguage | Actor method returns whether registration succeeded; reserved text/ansi names throw, duplicate names retain their first loader and extension mappings |
| resolveLanguage / getResolvedOrResolveLanguage | Direct resolve starts/deduplicates a loader; cached-or-resolve first checks the resolved snapshot. Both are async actor methods |
| resolveLanguages | Skips text/ansi; cached entries precede pending entries; duplicates and pending input order are retained; first failure returns without cancelling independent loads |
| hasResolvedLanguages / getResolvedLanguages | Inspect the resolved cache; get preserves requested order and throws if a name is absent, including text/ansi |
| areLanguagesAttached | Checks engine attachment, treating text/ansi as already available |
| attachResolvedLanguages | Accepts resolved grammar batches, checks declared names/aliases, uses the first cached registration, and marks names only after successful native Shiki loading |
| cleanUpResolvedLanguages | Clears resolved/attached state and token caches; retains registered loaders and pending language resolution, whose completion may repopulate the cache |
| ResolvedLanguages / AttachedLanguages | Read-only actor snapshots `resolvedLanguages` / `attachedLanguages` |
| ResolvingLanguages / RegisteredCustomLanguages | `resolvingLanguageNames` / `registeredCustomLanguageNames`; pending Task handles and loader closures remain actor-owned |
| registerCustomTheme / CustomThemeLoader | `registerCustomTheme` / `ThemeLoader`; lazy normalization, first registration wins, Bool result instead of duplicate console logging |
| resolveTheme / getResolvedOrResolveTheme | Direct resolve validates a registered or bundled loader before consulting the cache; cached-or-resolve can use a seeded resolved object without a loader |
| resolveThemes | Validates/registers fallbacks before starting loads; preserves input order and duplicates, deduplicates loaders and reports first failure without cancelling independent loads |
| hasResolvedThemes / getResolvedThemes | Actor cache queries; ordered lookup throws for missing names |
| areThemesAttached / AttachedThemes | Array-based actor query and read-only `attachedThemes` snapshot; adaptive callers supply their dark/light names |
| attachResolvedThemes | Accepts resolved values or `named:` cache references, seeds cache if absent and attaches at most once per tracked name |
| cleanUpResolvedThemes | Clears resolved/attached state, cancels pending tasks and rejects late theme results; preserves loader registrations |
| registerCustomCSSVariableTheme | Uses host-provided hex values/defaults to resolve the source-compatible CSS-variable theme factory into a native Shiki theme |

Pierre dark/light names are reserved from actor initialization, matching the
source shared-highlighter module registration. Bundled fallback names become
reserved when first requested, including earlier valid names in a bulk request
that later fails validation. Cleanup preserves these reservations. Custom
loaders registered before a bundled name is requested still win. This fixes a
native discrepancy where a later registration could replace a bundled loader
after cleanup.

Native Shiki loads grammar batches and rebuilds aliases rather than following
JavaScript Shiki's already-loaded-grammar skip path. The native loader therefore
supports adding declared aliases through a later batch; it does not reproduce
that JavaScript engine-specific alias failure. Calls have no browser Worker
context restriction: the actor owns its engine and resources and can load them
from any caller. Isolated actors have isolated registries; `.shared` supplies
the package-wide instance. JavaScript mutable maps, dynamic-import module
wrappers and promise handles are not exposed.

`registerTheme` and `registerLanguage` are additional native eager-registration
APIs. Eager resources survive actor disposal for subsequent reload. CSS theme
resolution does not implement CSS inheritance, browser media queries or live
variable mutation; callers supply concrete values and can install a new theme.
Invalid/missing values throw instead of producing an unresolved native color.

Evidence: LazyLanguageTests, LazyThemeTests, BulkResolutionTests and
CSSVariablesThemeTests cover lifecycle separation, first-loader ownership,
concurrent loads, retry, ordering, aliases/dependencies, cleanup during pending
loads and CSS theme fixtures. Two new LazyThemeTests cover bundled reservation,
cleanup/reload, early overrides, seeded-cache lookup and bulk preflight failure.
The direct TypeScript execution attempt could not run because the supplied
clone lacks `@pierre/theming`; the new registry expectations are source-reviewed
and native-tested, not represented as an executed upstream oracle.
