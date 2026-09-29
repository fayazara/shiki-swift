# Releasing

## Versions

ShikiSwift uses [Semantic Versioning](https://semver.org). Tags are plain
`MAJOR.MINOR.PATCH` (for example `0.1.0`, no `v` prefix), which is what Swift
Package Manager resolves. GitHub releases are titled `vMAJOR.MINOR.PATCH`.

Before 1.0:

- A **minor** release (`0.2.0`) may change or remove public API. Say so under
  **Changed** or **Removed** in the changelog, with what callers must do.
- A **patch** release (`0.1.1`) only fixes bugs or adds API without breaking
  existing callers.

Upgrading a pinned upstream (Shiki, vscode-textmate, Oniguruma, tm-grammars,
tm-themes, @pierre/diffs) changes token output, so it is at least a minor
release.

Dependents should use `.package(url: …, from: "0.1.0")`, which accepts later
0.1.x patches but not 0.2.0.

## Checklist

1. Start from an up-to-date, clean `main`.
2. Move the **[Unreleased]** entries in `CHANGELOG.md` under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading, and update the comparison links at the
   bottom.
3. Update the version in the README's installation snippet and the demo app's
   `MARKETING_VERSION` (both build configurations in
   `shiki-swift.xcodeproj/project.pbxproj`).
4. Commit as `Release X.Y.Z`.
5. Run `Scripts/release.sh X.Y.Z`. It refuses to continue unless the tree is
   clean, you are on `main` in sync with `origin`, the tag is new, and the
   changelog has the section. It then:
   - runs the Shiki, ShikiUI, and ShikiDiffs test suites (ShikiDiffs
     sequentially, in Release);
   - builds the package for macOS and iOS and the demo app in Release;
   - creates an annotated tag, pushes it, and publishes a GitHub release whose
     notes are that version's changelog section.

   `Scripts/release.sh X.Y.Z --dry-run` runs every check without tagging or
   pushing.

To withdraw a release before anyone depends on it, delete the GitHub release
and the tag (`gh release delete X.Y.Z --cleanup-tag`). Once published and used,
never move or reuse a tag: release a new patch instead.
