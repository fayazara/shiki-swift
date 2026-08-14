from __future__ import annotations

import io
from pathlib import Path
import sys
import tarfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import import_shiki_assets as importer  # noqa: E402


class JSLiteralParserTests(unittest.TestCase):
    def test_extracts_generated_metadata_without_executing_javascript(self) -> None:
        source = r"""
          // generated fixture
          export const grammars = [
            {
              name: 'javascript',
              aliases: ['js', 'node'],
              byteSize: 42,
              source: 'https://example.test/it\'s-here',
              funding: [],
            },
          ]
        """

        self.assertEqual(
            importer.extract_exported_array(source, "grammars"),
            [
                {
                    "name": "javascript",
                    "aliases": ["js", "node"],
                    "byteSize": 42,
                    "source": "https://example.test/it's-here",
                    "funding": [],
                }
            ],
        )

    def test_rejects_executable_metadata(self) -> None:
        source = "export const themes = getThemes()"
        with self.assertRaisesRegex(importer.ImportFailure, "unsupported literal"):
            importer.extract_exported_array(source, "themes")


class ShikiRegistrationTests(unittest.TestCase):
    def metadata(self, name: str, embedded: list[str]) -> dict[str, object]:
        return {
            "name": name,
            "displayName": name.title(),
            "scopeName": f"source.{name}",
            "aliases": [f"{name}-alias"],
            "embedded": embedded,
        }

    def test_document_language_moves_all_dependencies_to_lazy(self) -> None:
        result = importer.make_language_registration(
            {"name": "markdown", "patterns": []},
            self.metadata("markdown", ["html", "css"]),
        )
        self.assertEqual(result["embeddedLangs"], [])
        self.assertEqual(result["embeddedLangsLazy"], ["html", "css"])

    def test_latex_keeps_tex_eager(self) -> None:
        result = importer.make_language_registration(
            {"name": "latex", "patterns": []},
            self.metadata("latex", ["shellscript", "tex", "python"]),
        )
        self.assertEqual(result["embeddedLangs"], ["tex"])
        self.assertEqual(result["embeddedLangsLazy"], ["shellscript", "python"])

    def test_vue_uses_shikis_exact_lazy_dependency_table(self) -> None:
        result = importer.make_language_registration(
            {"name": "vue", "patterns": []},
            self.metadata("vue", ["css", "markdown", "pug", "javascript"]),
        )
        self.assertEqual(result["embeddedLangs"], ["css", "javascript"])
        self.assertEqual(
            result["embeddedLangsLazy"],
            importer.LANGS_LAZY_EMBEDDED_PARTIAL["vue"],
        )

    def test_unnamed_injection_omits_undefined_display_name(self) -> None:
        result = importer.make_language_registration(
            {"name": "fixture-injection", "patterns": []},
            {"name": "fixture-injection", "scopeName": "fixture.injection"},
        )
        self.assertNotIn("displayName", result)


class DeterminismAndSafetyTests(unittest.TestCase):
    def test_canonical_json_is_key_sorted_and_newline_terminated(self) -> None:
        self.assertEqual(
            importer.canonical_json({"z": 1, "a": {"d": 2, "b": 1}}),
            b'{\n  "a": {\n    "b": 1,\n    "d": 2\n  },\n  "z": 1\n}\n',
        )

    def test_package_digest_includes_paths_and_contents(self) -> None:
        first = importer.package_content_digest({"a": b"bc", "ab": b"c"})
        second = importer.package_content_digest({"ab": b"c", "a": b"bc"})
        changed = importer.package_content_digest({"a": b"b", "ab": b"cc"})
        self.assertEqual(first, second)
        self.assertNotEqual(first, changed)

    def test_tar_reader_rejects_path_traversal(self) -> None:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            contents = b"bad"
            member = tarfile.TarInfo("package/../outside")
            member.size = len(contents)
            archive.addfile(member, io.BytesIO(contents))

        with self.assertRaisesRegex(importer.ImportFailure, "unsafe tar member path"):
            importer._read_tar_files(buffer.getvalue())

    def test_exact_versions_are_hard_pinned(self) -> None:
        self.assertEqual(importer.GRAMMARS_PIN.version, "1.32.3")
        self.assertEqual(importer.THEMES_PIN.version, "1.12.3")
        self.assertTrue(importer.GRAMMARS_PIN.npm_integrity.startswith("sha512-"))
        self.assertTrue(importer.THEMES_PIN.npm_integrity.startswith("sha512-"))


if __name__ == "__main__":
    unittest.main()
