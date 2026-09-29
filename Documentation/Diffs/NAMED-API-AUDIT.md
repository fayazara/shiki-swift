# Named upstream API inventory

`upstream-api-inventory.json` inventories the supplied @pierre/diffs 1.4.2
source using TypeScript 5.9.3's parser and export checker. It expands local
re-exports instead of treating each exported module as one implemented feature.

| Entry point | Exported names | Dependency aliases with unresolved signatures |
| --- | ---: | ---: |
| root | 366 | 11 |
| edit | 64 | 0 |
| react | 159 | 9 |
| ssr | 128 | 9 |
| worker | 31 | 0 |
| worker/worker.js | 0 | 0 |
| worker/worker-portable.js | 0 | 0 |

There are 513 unique export spellings across these entry points. This is not a
count of implemented features. Repeated names across entry points can have
different contracts. The two worker script entry points have runtime side effects
and must not be considered irrelevant because they export no names.

The snapshot records declaration paths/lines, explicit types, parameters,
heritage clauses, directly declared public members, callable property parameters,
and public constructor parameter properties. It hashes 150 modules in the entry
point/re-export graph. It excludes private/protected members, but includes public
members with underscore-prefixed names because those are still publicly exposed.
Inherited members, inferred types, overload semantics, type-versus-value exposure,
and runtime behavior need separate contract review.

External named aliases remain visible in the inventory; their signatures cannot
be resolved without dependency declarations. The root's eleven are BundledLanguage,
CodeToHastOptions, codeToHtml, createCSSVariablesTheme, CreatePatchOptionsNonabortable,
DecorationItem, LanguageRegistration, ShikiTransformer, ThemedToken,
ThemeRegistration, and ThemeRegistrationResolved. This does not imply those
features are absent from Swift; for example, the CSS-variable factory already
has a native implementation and reference fixtures.

## What this changes in the parity audit

Every record starts with `nativeDisposition: unreviewed`. That means its contract
has not yet been individually mapped, not that its implementation is missing.
The existing EXPORT-AUDIT.md remains the module-level implementation map.

Component member review must include, for example:

- CodeView's item mutations, scroll subscriptions, layout accessors, and slot
  coordination methods, beyond the presence of a native multi-file viewport.
- FileDiff's cache priming, renderability/reveal methods, edit lifecycle, and
  externally exposed document-session methods.
- UnresolvedFile's inherited FileDiff contracts as well as its own render,
  hydration, options, cleanup, and resolution methods.
- React hooks/context behavior, SSR preload/output contracts, and worker
  initialization/message lifecycles, each with an explicit native adaptation.

The current port's overall completion status remains unproven. Named source
coverage now exists; native per-symbol and per-contract coverage is still open.

## Reproduction and validation

Install TypeScript 5.9.3 in a separate tooling directory, then run:

```sh
bun Scripts/diffs/inventory-upstream-api.ts /path/to/diffs /path/to/typescript/lib/typescript.js
bun Scripts/diffs/test-api-inventory.ts /path/to/typescript/lib/typescript.js
```

The generator optionally accepts a fourth argument for its output path. It does
not execute upstream code, and fails on missing local re-exports, parse errors,
or external wildcard exports it cannot enumerate. Fixture checks cover default
and external aliases, interfaces, type aliases, public/private/protected members,
constructor properties, callable fields, deterministic output, and missing-module
rejection. Regeneration of the real snapshot produced the same SHA-256:
`109c7facbe08d9dee062432430507ff607d39b036d9f98a431dac5fe2df68a8a`.

This turn changed audit tooling/artifacts only; Swift runtime and UI validation
remain the separately recorded evidence in DEMO-VALIDATION.md.

## FileDiff folded-line navigation

NativeDiffView now provides `isLineRenderable`, `getNearestRenderableLine`, and
`revealLine` for one-based addition/new-file lines. The first two query metadata
independently of viewport materialization; reveal expands through `expandHunk`
and does not scroll. Swift uses `LineNavigationDirection` and throwing methods
to represent upstream direction literals and trailing-metadata exceptions.

`generate-navigation-oracle.ts` executes the actual upstream layout helpers and
extracts/transpiles the FileDiff.revealLine method without rewriting its body.
256 fixtures contain 12,544 line probes for visibility, nearest lines and reveal
requests. They cover leading/interior/trailing folds, two-sided expansion,
thresholds, partial files, empty hunks, no hunks, and phantom document-end lines.
AppKit integration additionally checks callback dispatch and repeated reveals.
This closes these three NativeDiffView contracts only; inherited behavior on
other component owners and the remaining named API map still need review.

The same three navigation methods are now exposed on NativeUnresolvedFileView.
A component integration test verifies expansion retention across asynchronous
highlighting and reset on source replacement/cleanup. See
UNRESOLVED-FILE-API.md for the remaining owned-component contract audit,
including explicit source-replacement differences and missing lifecycle events.

NativeDiffView now implements presentation lifecycle phases and explicit
cleanup, with editor discard/recycle semantics. The owned conflict view and
both SwiftUI wrappers expose callbacks. PostRenderTests verifies reentrant
source replacement, asynchronous highlight updates and teardown. The remaining
custom-slot-only and multi-file virtualization event contracts remain open;
this does not mark the entire inherited FileDiff API complete.


## Focused native contract dispositions

`native-api-dispositions.json` records reviewed mappings separately from the
source-generated inventory, so regenerating upstream signatures does not erase
the audit. Entries apply only to the listed origin/export names. `partial`
means concrete behavior remains missing; `native-adaptation` records an exposed
native contract and its differences, not byte-identical browser output or final
runtime sign-off. Unlisted exports remain unreviewed. Component and demo paths
are summarized in COMPONENT-CONTRACTS.md and DEMO-FEATURE-MAP.md.

The explicit manifest distinguishes public package exports from
`internalModuleExports` used only inside source modules; the latter are excluded
from public coverage. EQUALITY-CONTRACTS.md maps nine equality helpers, and
RENDERER-CONTRACTS.md records the renderer operations plus the still-missing
custom row/decorating extension surface. A partial entry remains partial even
when its built-in presentation tests pass.
