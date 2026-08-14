# Shiki asset importer

`import_shiki_assets.py` converts the exact Shiki asset inputs used by this
port into deterministic, Foundation-decodable JSON. It mirrors the local Shiki
generators at:

- `../shiki/packages/langs/scripts/langs.ts`
- `../shiki/packages/themes/scripts/themes.ts`

The importer is deliberately offline. It never invokes `npm`, executes package
JavaScript, or makes a network request. Supply either already-extracted npm
package directories or tarballs acquired separately.

## Pinned inputs

Only these immutable inputs are accepted:

- `tm-grammars@1.32.3`
- `tm-themes@1.12.3`

Tarballs are checked against their npm SHA-512 integrity values. Extracted
directories are checked against a SHA-256 digest covering every relative path
and byte in the package, as well as the package name, version, and file count.
Modified, incomplete, or merely version-compatible inputs fail before output is
written.

## Usage

With npm tarballs:

```sh
python3 Scripts/import_shiki_assets.py \
  --tm-grammars /path/to/tm-grammars-1.32.3.tgz \
  --tm-themes /path/to/tm-themes-1.12.3.tgz \
  --output /path/to/generated-assets
```

With extracted package directories (a `node_modules` package is fine):

```sh
python3 Scripts/import_shiki_assets.py \
  --tm-grammars /path/to/node_modules/tm-grammars \
  --tm-themes /path/to/node_modules/tm-themes \
  --output /path/to/generated-assets
```

The first run requires a nonexistent output path. To update an output previously
created by this importer, add `--replace`. The importer refuses to replace an
unmarked directory.

To make CI verify committed resources without changing them:

```sh
python3 Scripts/import_shiki_assets.py \
  --tm-grammars /path/to/tm-grammars-1.32.3.tgz \
  --tm-themes /path/to/tm-themes-1.12.3.tgz \
  --output /path/to/generated-assets \
  --check
```

## Output contract

The output directory contains:

- `grammars/<id>.json`: canonical JSON `LanguageRegistration` data. Each raw
  TextMate grammar is enriched with Shiki's `displayName`, `aliases`,
  `embeddedLangs`, and `embeddedLangsLazy` behavior.
- `themes/<id>.json`: canonical raw VS Code/TextMate theme JSON.
- `language-manifest.json`: canonical IDs, aliases, eager/lazy embedded-language
  dependencies, injection targets, scope names, and resource paths.
- `theme-manifest.json`: theme IDs in Shiki order, display names, light/dark
  types, and resource paths.
- `provenance.json`: package pins and per-asset source revision, upstream hash,
  source URL, byte size, and license status.
- `licenses/`: the unmodified `LICENSE` and third-party `NOTICE` from both npm
  packages.
- `asset-manifest.json`: input pins, counts, and SHA-256/byte-size records for
  every other generated file.

Object keys and resource filenames are sorted deterministically; semantic array
ordering from Shiki and the packages is retained. No generation timestamp or
machine-specific input path is recorded, so tarball and extracted-directory
inputs produce identical bytes.

Some upstream metadata is intentionally incomplete. The pinned packages contain
one synthetic grammar without source-revision provenance (`ts-tags`) and some
grammars without per-asset license declarations. `provenance.json` makes these
gaps explicit in `missingAssetProvenance` and
`missingAssetLicenseDeclarations`; package-level license and notice artifacts
are still always emitted. Missing package license/notice files or malformed
declared metadata are hard errors.

## Tests

The tests use only dry in-memory fixtures and make no network requests:

```sh
python3 -m unittest discover -s Scripts/tests -v
```

