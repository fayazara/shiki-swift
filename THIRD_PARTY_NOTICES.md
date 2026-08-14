# Third-party notices

This native port is source-compatible work derived from and tested against the
following pinned projects and data sets. Their original license texts are kept
with the source or generated resources.

| Component | Pinned version or revision | License location |
| --- | --- | --- |
| Shiki | 4.4.3, `48cd2cc695ed2e3357c3f9c370578ea843d6d9a3` | `LICENSES/Shiki.txt` |
| `@shikijs/vscode-textmate` | 10.0.2, `19dc9b889aa47df91027e857cdad518760b5a026` | `LICENSES/vscode-textmate.txt` |
| `vscode-oniguruma` behavioral reference | 1.7.0, `716aeaa229e4ae2e3b0057377b55743e9a3e995b` | `LICENSES/vscode-oniguruma.txt` |
| Oniguruma native source | 6.9.8, `08d36110c5670c815ad6d6f969e578049d209080` | `Sources/COniguruma/LICENSE.txt` |
| `tm-grammars` assets | 1.32.3 | `Sources/Shiki/Resources/licenses/tm-grammars-LICENSE.txt` and `tm-grammars-NOTICE.txt` |
| `tm-themes` assets | 1.12.3 | `Sources/Shiki/Resources/licenses/tm-themes-LICENSE.txt` and `tm-themes-NOTICE.txt` |

`Sources/Shiki/Resources/provenance.json` records the upstream source,
revision, hash, byte size, and available per-asset license declaration for each
bundled grammar and theme. Some upstream grammar metadata has no per-asset
license declaration; those gaps are explicit in the provenance file and the
aggregated package notices are retained verbatim.
