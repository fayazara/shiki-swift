#!/usr/bin/env python3
"""Import the exact Shiki grammar/theme inputs into deterministic JSON assets.

This script intentionally has no network code and no third-party dependencies.
It accepts either npm tarballs or already-extracted npm package directories.
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = 1
GENERATED_BY = "Scripts/import_shiki_assets.py"


class ImportFailure(RuntimeError):
    """An actionable input or generation failure."""


@dataclass(frozen=True)
class PackagePin:
    name: str
    version: str
    npm_integrity: str
    content_sha256: str
    expected_file_count: int


# npm integrity values are also pinned in the local Shiki pnpm-lock.yaml. The
# content digests cover every path and byte in each extracted npm package, so a
# directory input is held to the same immutable package contents as a tarball.
GRAMMARS_PIN = PackagePin(
    name="tm-grammars",
    version="1.32.3",
    npm_integrity=(
        "sha512-7h+UR4PPD4KY5Bu6olRkylEoEkrO8lK0Q6cHgThgq/"
        "IJWyiMj3iCcGlvJaLLplXW9PmOniOKnhajsBnM5/btfQ=="
    ),
    content_sha256="5e6b7b3591b86bb7bd22146d0188b6480d4b1c3ee356f6cc482220a004311d99",
    expected_file_count=266,
)

THEMES_PIN = PackagePin(
    name="tm-themes",
    version="1.12.3",
    npm_integrity=(
        "sha512-DiuwChs9cpdGmu71483ld0+IsBQQxLpNFsUvz8WizzmiycQXJLNYHj0IgUlhrslk9"
        "BexmFn6lSLaAiyll5QD5Q=="
    ),
    content_sha256="ad9430f4da404b23ecac2760da5490f8425e869cf5a74ff873a5193463f2ffce",
    expected_file_count=71,
)


# These tables intentionally mirror packages/langs/scripts/langs.ts in the
# adjacent local Shiki checkout. Their ordering is part of the generated data.
LANGS_LAZY_EMBEDDED_ALL: dict[str, list[str]] = {
    "markdown": [],
    "mdx": [],
    "wikitext": [],
    "asciidoc": [],
    "latex": ["tex"],
}

LANGS_LAZY_EMBEDDED_PARTIAL: dict[str, list[str]] = {
    "vue": [
        "markdown",
        "pug",
        "stylus",
        "sass",
        "scss",
        "less",
        "jsx",
        "tsx",
        "coffee",
        "jsonc",
        "json5",
        "yaml",
        "toml",
        "graphql",
    ],
    "vue-html": [],
    "svelte": [
        "coffee",
        "stylus",
        "sass",
        "scss",
        "less",
        "pug",
        "markdown",
    ],
    "pug": ["sass", "scss", "stylus", "coffee"],
    "haml": ["ruby", "sass", "coffee", "markdown"],
    "astro": ["sass", "scss", "stylus", "less"],
}

VALID_SHIKI_FILENAME = re.compile(r"^[A-Za-z0-9_-]+$")


@dataclass(frozen=True)
class LoadedPackage:
    pin: PackagePin
    files: Mapping[str, bytes]
    package_json: Mapping[str, Any]
    content_sha256: str


class JSLiteralParser:
    """Parser for the data-only JavaScript literals used by tm-* index.js."""

    _number = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
    _identifier = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")

    def __init__(self, source: str, offset: int = 0) -> None:
        self.source = source
        self.offset = offset

    def parse(self) -> Any:
        self._skip_trivia()
        return self._parse_value()

    def _error(self, message: str) -> ImportFailure:
        line = self.source.count("\n", 0, self.offset) + 1
        previous_newline = self.source.rfind("\n", 0, self.offset)
        column = self.offset - previous_newline
        return ImportFailure(f"JavaScript metadata parse error at {line}:{column}: {message}")

    def _skip_trivia(self) -> None:
        while self.offset < len(self.source):
            if self.source[self.offset].isspace():
                self.offset += 1
                continue
            if self.source.startswith("//", self.offset):
                newline = self.source.find("\n", self.offset + 2)
                self.offset = len(self.source) if newline < 0 else newline + 1
                continue
            if self.source.startswith("/*", self.offset):
                end = self.source.find("*/", self.offset + 2)
                if end < 0:
                    raise self._error("unterminated block comment")
                self.offset = end + 2
                continue
            return

    def _parse_value(self) -> Any:
        self._skip_trivia()
        if self.offset >= len(self.source):
            raise self._error("expected a value")
        character = self.source[self.offset]
        if character == "{":
            return self._parse_object()
        if character == "[":
            return self._parse_array()
        if character in "'\"":
            return self._parse_string()
        number = self._number.match(self.source, self.offset)
        if number:
            token = number.group(0)
            self.offset = number.end()
            return float(token) if any(c in token for c in ".eE") else int(token)
        identifier = self._parse_identifier()
        if identifier == "true":
            return True
        if identifier == "false":
            return False
        if identifier == "null":
            return None
        raise self._error(f"unsupported literal {identifier!r}")

    def _parse_object(self) -> dict[str, Any]:
        self.offset += 1
        result: dict[str, Any] = {}
        self._skip_trivia()
        if self._consume("}"):
            return result
        while True:
            self._skip_trivia()
            if self.offset >= len(self.source):
                raise self._error("unterminated object")
            if self.source[self.offset] in "'\"":
                key = self._parse_string()
            else:
                key = self._parse_identifier()
            if not isinstance(key, str) or not key:
                raise self._error("object key must be a non-empty string")
            if key in result:
                raise self._error(f"duplicate object key {key!r}")
            self._skip_trivia()
            self._expect(":")
            result[key] = self._parse_value()
            self._skip_trivia()
            if self._consume("}"):
                return result
            self._expect(",")
            self._skip_trivia()
            if self._consume("}"):
                return result

    def _parse_array(self) -> list[Any]:
        self.offset += 1
        result: list[Any] = []
        self._skip_trivia()
        if self._consume("]"):
            return result
        while True:
            result.append(self._parse_value())
            self._skip_trivia()
            if self._consume("]"):
                return result
            self._expect(",")
            self._skip_trivia()
            if self._consume("]"):
                return result

    def _parse_identifier(self) -> str:
        match = self._identifier.match(self.source, self.offset)
        if not match:
            raise self._error("expected an identifier")
        self.offset = match.end()
        return match.group(0)

    def _parse_string(self) -> str:
        quote = self.source[self.offset]
        self.offset += 1
        output: list[str] = []
        simple_escapes = {
            "'": "'",
            '"': '"',
            "\\": "\\",
            "/": "/",
            "b": "\b",
            "f": "\f",
            "n": "\n",
            "r": "\r",
            "t": "\t",
            "v": "\v",
            "0": "\0",
        }
        while self.offset < len(self.source):
            character = self.source[self.offset]
            self.offset += 1
            if character == quote:
                return "".join(output)
            if character in "\r\n":
                raise self._error("unescaped newline in string")
            if character != "\\":
                output.append(character)
                continue
            if self.offset >= len(self.source):
                raise self._error("unterminated string escape")
            escaped = self.source[self.offset]
            self.offset += 1
            if escaped in simple_escapes:
                output.append(simple_escapes[escaped])
            elif escaped == "x":
                output.append(chr(self._parse_hex_escape(2)))
            elif escaped == "u":
                output.append(chr(self._parse_hex_escape(4)))
            elif escaped == "\n":
                continue
            elif escaped == "\r":
                if self.offset < len(self.source) and self.source[self.offset] == "\n":
                    self.offset += 1
            else:
                # JavaScript's non-escape character rule: '\q' has value 'q'.
                output.append(escaped)
        raise self._error("unterminated string")

    def _parse_hex_escape(self, length: int) -> int:
        end = self.offset + length
        token = self.source[self.offset:end]
        if len(token) != length or not re.fullmatch(r"[0-9A-Fa-f]+", token):
            raise self._error("invalid hexadecimal string escape")
        self.offset = end
        return int(token, 16)

    def _consume(self, token: str) -> bool:
        if self.source.startswith(token, self.offset):
            self.offset += len(token)
            return True
        return False

    def _expect(self, token: str) -> None:
        if not self._consume(token):
            raise self._error(f"expected {token!r}")


def extract_exported_array(source: str, export_name: str) -> list[dict[str, Any]]:
    marker = re.search(
        rf"\bexport\s+const\s+{re.escape(export_name)}\s*=",
        source,
    )
    if not marker:
        raise ImportFailure(f"index.js does not export const {export_name}")
    value = JSLiteralParser(source, marker.end()).parse()
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise ImportFailure(f"index.js export {export_name} must be an array of objects")
    return value


def package_content_digest(files: Mapping[str, bytes]) -> str:
    digest = hashlib.sha256()
    for relative_path in sorted(files):
        path_bytes = relative_path.encode("utf-8")
        contents = files[relative_path]
        digest.update(path_bytes)
        digest.update(b"\0")
        digest.update(str(len(contents)).encode("ascii"))
        digest.update(b"\0")
        digest.update(contents)
    return digest.hexdigest()


def _read_tar_files(raw_tarball: bytes) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    try:
        archive = tarfile.open(fileobj=io.BytesIO(raw_tarball), mode="r:*")
    except tarfile.TarError as error:
        raise ImportFailure(f"input is not a readable npm tarball: {error}") from error
    with archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise ImportFailure(f"unsafe tar member path: {member.name!r}")
            if member.isdir():
                continue
            if not member.isreg():
                raise ImportFailure(f"unsupported non-regular tar member: {member.name!r}")
            parts = tuple(part for part in path.parts if part not in ("", "."))
            if len(parts) < 2 or parts[0] != "package":
                raise ImportFailure(
                    f"npm tar member must be rooted at package/: {member.name!r}"
                )
            relative = PurePosixPath(*parts[1:]).as_posix()
            if relative in files:
                raise ImportFailure(f"duplicate tar member: {relative!r}")
            extracted = archive.extractfile(member)
            if extracted is None:
                raise ImportFailure(f"could not read tar member: {member.name!r}")
            files[relative] = extracted.read()
    return files


def _read_directory_files(input_path: Path) -> dict[str, bytes]:
    root = input_path.resolve()
    if not (root / "package.json").is_file() and (root / "package/package.json").is_file():
        root = root / "package"
    if not (root / "package.json").is_file():
        raise ImportFailure(f"package.json not found in extracted package directory {input_path}")

    files: dict[str, bytes] = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ImportFailure(f"nested symlinks are not allowed in package input: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ImportFailure(f"unsupported package filesystem entry: {path}")
        relative = path.relative_to(root).as_posix()
        files[relative] = path.read_bytes()
    return files


def load_package(input_path: Path, pin: PackagePin) -> LoadedPackage:
    if not input_path.exists():
        raise ImportFailure(f"{pin.name} input does not exist: {input_path}")
    if input_path.is_file():
        tarball = input_path.read_bytes()
        actual_integrity = "sha512-" + base64.b64encode(
            hashlib.sha512(tarball).digest()
        ).decode("ascii")
        if actual_integrity != pin.npm_integrity:
            raise ImportFailure(
                f"{pin.name} tarball integrity mismatch; expected {pin.npm_integrity}, "
                f"got {actual_integrity}"
            )
        files = _read_tar_files(tarball)
    elif input_path.is_dir():
        files = _read_directory_files(input_path)
    else:
        raise ImportFailure(f"{pin.name} input must be a directory or tarball: {input_path}")

    actual_content_digest = package_content_digest(files)
    if len(files) != pin.expected_file_count or actual_content_digest != pin.content_sha256:
        raise ImportFailure(
            f"{pin.name}@{pin.version} extracted contents do not match the exact pin "
            f"(expected {pin.expected_file_count} files and sha256 {pin.content_sha256}; "
            f"got {len(files)} files and sha256 {actual_content_digest})"
        )

    package_json = _decode_json(files, "package.json", pin.name)
    if package_json.get("name") != pin.name or package_json.get("version") != pin.version:
        raise ImportFailure(
            f"expected {pin.name}@{pin.version}, got "
            f"{package_json.get('name')}@{package_json.get('version')}"
        )
    for required in ("index.js", "LICENSE", "NOTICE"):
        contents = files.get(required)
        if not contents:
            raise ImportFailure(f"{pin.name}@{pin.version} is missing non-empty {required}")
    if not isinstance(package_json.get("license"), str) or not package_json["license"]:
        raise ImportFailure(f"{pin.name}@{pin.version} has no package license declaration")
    if not package_json.get("repository"):
        raise ImportFailure(f"{pin.name}@{pin.version} has no repository provenance")

    return LoadedPackage(pin, files, package_json, actual_content_digest)


def _decode_json(
    files: Mapping[str, bytes], relative_path: str, package_name: str
) -> dict[str, Any]:
    contents = files.get(relative_path)
    if contents is None:
        raise ImportFailure(f"{package_name} is missing {relative_path}")
    try:
        decoded = json.loads(contents)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ImportFailure(f"invalid JSON in {package_name}/{relative_path}: {error}") from error
    if not isinstance(decoded, dict):
        raise ImportFailure(f"{package_name}/{relative_path} must contain a JSON object")
    return decoded


def _decode_index(package: LoadedPackage) -> str:
    try:
        return package.files["index.js"].decode("utf-8")
    except UnicodeDecodeError as error:
        raise ImportFailure(f"{package.pin.name}/index.js is not UTF-8: {error}") from error


def _required_string(item: Mapping[str, Any], key: str, context: str) -> str:
    value = item.get(key)
    if not isinstance(value, str) or not value:
        raise ImportFailure(f"{context} is missing non-empty {key}")
    return value


def _string_list(item: Mapping[str, Any], key: str, context: str) -> list[str]:
    value = item.get(key, [])
    if not isinstance(value, list) or not all(isinstance(entry, str) for entry in value):
        raise ImportFailure(f"{context}.{key} must be an array of strings")
    return list(value)


def make_language_registration(
    content: Mapping[str, Any], metadata: Mapping[str, Any]
) -> dict[str, Any]:
    """Apply the same registration enrichment and lazy split as Shiki."""
    context = f"grammar metadata {metadata.get('name')!r}"
    name = _required_string(metadata, "name", context)
    registration = copy.deepcopy(dict(content))
    content_name = registration.get("name")
    registration["name"] = content_name or name
    registration["scopeName"] = registration.get("scopeName") or _required_string(
        metadata, "scopeName", context
    )
    display_name = metadata.get("displayName")
    if display_name is None:
        # Some injection registrations deliberately have no display name. In
        # the TypeScript generator this property is undefined and therefore
        # omitted by JSON.stringify.
        registration.pop("displayName", None)
    elif isinstance(display_name, str) and display_name:
        registration["displayName"] = display_name
    else:
        raise ImportFailure(f"{context}.displayName must be a non-empty string when present")

    if "embedded" in metadata:
        registration["embeddedLangs"] = _string_list(metadata, "embedded", context)
    else:
        registration.pop("embeddedLangs", None)
    if "aliases" in metadata:
        registration["aliases"] = _string_list(metadata, "aliases", context)
    else:
        registration.pop("aliases", None)

    if name in LANGS_LAZY_EMBEDDED_ALL:
        eager = list(LANGS_LAZY_EMBEDDED_ALL[name])
        original = _string_list(registration, "embeddedLangs", context)
        registration["embeddedLangsLazy"] = [item for item in original if item not in eager]
        registration["embeddedLangs"] = eager
    elif name in LANGS_LAZY_EMBEDDED_PARTIAL:
        lazy = list(LANGS_LAZY_EMBEDDED_PARTIAL[name])
        original = _string_list(registration, "embeddedLangs", context)
        registration["embeddedLangsLazy"] = lazy
        registration["embeddedLangs"] = [item for item in original if item not in lazy]

    return registration


def _validate_asset_provenance(metadata: Mapping[str, Any], context: str) -> None:
    _required_string(metadata, "name", context)
    for key in ("source", "sourceApi", "sha", "lastUpdate", "hash"):
        value = metadata.get(key)
        if value is not None and (not isinstance(value, str) or not value):
            raise ImportFailure(f"{context}.{key} must be a non-empty string when present")
    byte_size = metadata.get("byteSize")
    if not isinstance(byte_size, int) or byte_size < 0:
        raise ImportFailure(f"{context}.byteSize must be a non-negative integer")
    for optional in ("license", "licenseUrl"):
        value = metadata.get(optional)
        if value is not None and (not isinstance(value, str) or not value):
            raise ImportFailure(f"{context}.{optional} must be a non-empty string when present")


def _provenance_entry(
    metadata: Mapping[str, Any], resource: str, kind: str, package: LoadedPackage
) -> dict[str, Any]:
    context = f"{kind} provenance {metadata.get('name')!r}"
    _validate_asset_provenance(metadata, context)
    declared_license = metadata.get("license")
    declared_license_url = metadata.get("licenseUrl")
    source_fields = ("source", "sourceApi", "sha", "lastUpdate", "hash")
    populated_source_fields = sum(bool(metadata.get(key)) for key in source_fields)
    if populated_source_fields == len(source_fields):
        source_status = "declared-upstream"
    elif populated_source_fields:
        source_status = "partially-declared-upstream"
    else:
        source_status = "not-declared-upstream"
    if declared_license and declared_license_url:
        license_status = "declared-upstream"
    elif declared_license or declared_license_url:
        license_status = "partially-declared-upstream"
    else:
        license_status = "not-declared-upstream"
    return {
        "id": metadata["name"],
        "kind": kind,
        "license": {
            "spdx": declared_license,
            "status": license_status,
            "url": declared_license_url,
            "packageLicense": package.package_json["license"],
            "packageLicenseFiles": [
                f"licenses/{package.pin.name}-LICENSE.txt",
                f"licenses/{package.pin.name}-NOTICE.txt",
            ],
        },
        "resource": resource,
        "source": metadata.get("source"),
        "sourceApi": metadata.get("sourceApi"),
        "sourceByteSize": metadata["byteSize"],
        "sourceHash": metadata.get("hash"),
        "sourceLastUpdate": metadata.get("lastUpdate"),
        "sourceRevision": metadata.get("sha"),
        "sourceStatus": source_status,
    }


def _compact_json_byte_size(value: Any) -> int:
    return len(
        json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    )


def build_languages(
    package: LoadedPackage,
) -> tuple[dict[str, Any], dict[str, bytes], list[dict[str, Any]]]:
    index = _decode_index(package)
    grammar_metadata = extract_exported_array(index, "grammars")
    injection_metadata = extract_exported_array(index, "injections")

    metadata_by_name: dict[str, tuple[str, dict[str, Any]]] = {}
    metadata_collections = (
        ("grammar", grammar_metadata),
        ("injection", injection_metadata),
    )
    for kind, collection in metadata_collections:
        for metadata in collection:
            name = _required_string(metadata, "name", f"{kind} metadata")
            if name in metadata_by_name:
                raise ImportFailure(f"duplicate grammar/injection metadata name {name!r}")
            metadata_by_name[name] = (kind, metadata)

    grammar_paths = sorted(
        path
        for path in package.files
        if path.startswith("grammars/") and path.endswith(".json")
    )
    resources: dict[str, bytes] = {}
    entries: list[dict[str, Any]] = []
    provenance: list[dict[str, Any]] = []
    seen_metadata: set[str] = set()

    for source_path in grammar_paths:
        content = _decode_json(package.files, source_path, package.pin.name)
        content_name = content.get("name")
        if not isinstance(content_name, str) or content_name not in metadata_by_name:
            raise ImportFailure(
                f"{package.pin.name}/{source_path} has unknown metadata name {content_name!r}"
            )
        kind, metadata = metadata_by_name[content_name]
        if content_name in seen_metadata:
            raise ImportFailure(f"multiple grammar files resolve to {content_name!r}")
        seen_metadata.add(content_name)
        registration = make_language_registration(content, metadata)
        expected_size = metadata.get("byteSize")
        actual_size = _compact_json_byte_size(content)
        if expected_size != actual_size:
            raise ImportFailure(
                f"{source_path} byteSize metadata mismatch: expected "
                f"{expected_size}, got {actual_size}"
            )

        output_path = f"grammars/{content_name}.json"
        resources[output_path] = canonical_json(registration)
        aliases = _string_list(registration, "aliases", f"registration {content_name!r}")
        embedded = _string_list(
            registration, "embeddedLangs", f"registration {content_name!r}"
        )
        embedded_lazy = _string_list(
            registration, "embeddedLangsLazy", f"registration {content_name!r}"
        )
        entry: dict[str, Any] = {
            "aliases": aliases,
            "embeddedIn": _string_list(
                metadata, "embeddedIn", f"metadata {content_name!r}"
            ),
            "embeddedLangs": embedded,
            "embeddedLangsLazy": embedded_lazy,
            "id": content_name,
            "injectTo": _string_list(
                metadata, "injectTo", f"metadata {content_name!r}"
            ),
            "kind": kind,
            "resource": output_path,
            "scopeName": registration["scopeName"],
        }
        if "displayName" in registration:
            entry["displayName"] = registration["displayName"]
        entries.append(entry)
        provenance.append(_provenance_entry(metadata, output_path, kind, package))

    missing = sorted(set(metadata_by_name) - seen_metadata)
    if missing:
        raise ImportFailure(f"metadata has no corresponding grammar JSON: {', '.join(missing)}")

    entries.sort(key=lambda item: item["id"])
    provenance.sort(key=lambda item: item["id"])
    canonical_ids = {entry["id"] for entry in entries}
    alias_map: dict[str, str] = {}
    exported_alias_names: list[str] = []
    for entry in entries:
        for alias in entry["aliases"]:
            alias_map[alias] = entry["id"]
            if VALID_SHIKI_FILENAME.fullmatch(alias) and alias not in canonical_ids:
                exported_alias_names.append(alias)

    manifest = {
        "aliases": alias_map,
        "languageAliasNames": sorted(exported_alias_names),
        "languageNames": sorted(canonical_ids),
        "languages": entries,
        "package": {"name": package.pin.name, "version": package.pin.version},
        "schemaVersion": SCHEMA_VERSION,
    }
    return manifest, resources, provenance


def build_themes(
    package: LoadedPackage,
) -> tuple[dict[str, Any], dict[str, bytes], list[dict[str, Any]]]:
    metadata_items = extract_exported_array(_decode_index(package), "themes")
    resources: dict[str, bytes] = {}
    entries: list[dict[str, Any]] = []
    provenance: list[dict[str, Any]] = []
    expected_paths: set[str] = set()

    for metadata in metadata_items:
        name = _required_string(metadata, "name", "theme metadata")
        context = f"theme metadata {name!r}"
        _validate_asset_provenance(metadata, context)
        theme_type = _required_string(metadata, "type", context)
        if theme_type not in ("dark", "light"):
            raise ImportFailure(f"{context}.type must be dark or light")
        source_path = f"themes/{name}.json"
        if source_path in expected_paths:
            raise ImportFailure(f"duplicate theme metadata name {name!r}")
        expected_paths.add(source_path)
        content = _decode_json(package.files, source_path, package.pin.name)
        actual_size = _compact_json_byte_size(content)
        if metadata.get("byteSize") != actual_size:
            raise ImportFailure(
                f"{source_path} byteSize metadata mismatch: expected "
                f"{metadata.get('byteSize')}, got {actual_size}"
            )
        display_name = content.get("displayName")
        content_type = content.get("type")
        if not isinstance(display_name, str) or not display_name:
            raise ImportFailure(f"{source_path} has no displayName")
        if content_type not in ("dark", "light"):
            raise ImportFailure(f"{source_path} has invalid or missing type")

        output_path = source_path
        resources[output_path] = canonical_json(content)
        entries.append(
            {
                "displayName": display_name,
                "id": name,
                "resource": output_path,
                "type": content_type,
            }
        )
        provenance.append(_provenance_entry(metadata, output_path, "theme", package))

    actual_paths = {
        path
        for path in package.files
        if path.startswith("themes/") and path.endswith(".json")
    }
    extras = sorted(actual_paths - expected_paths)
    if extras:
        raise ImportFailure(f"theme JSON has no corresponding metadata: {', '.join(extras)}")

    manifest = {
        "package": {"name": package.pin.name, "version": package.pin.version},
        "schemaVersion": SCHEMA_VERSION,
        "themeNames": [entry["id"] for entry in entries],
        "themes": entries,
    }
    return manifest, resources, provenance


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            indent=2,
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def _package_provenance(package: LoadedPackage) -> dict[str, Any]:
    package_json = package.package_json
    return {
        "contentSHA256": package.content_sha256,
        "fileCount": len(package.files),
        "homepage": package_json.get("homepage"),
        "license": package_json["license"],
        "licenseFiles": [
            f"licenses/{package.pin.name}-LICENSE.txt",
            f"licenses/{package.pin.name}-NOTICE.txt",
        ],
        "name": package.pin.name,
        "npmIntegrity": package.pin.npm_integrity,
        "repository": package_json["repository"],
        "version": package.pin.version,
    }


def build_output_files(
    grammar_package: LoadedPackage, theme_package: LoadedPackage
) -> dict[str, bytes]:
    language_manifest, grammar_resources, grammar_provenance = build_languages(grammar_package)
    theme_manifest, theme_resources, theme_provenance = build_themes(theme_package)
    output: dict[str, bytes] = {}
    output.update(grammar_resources)
    output.update(theme_resources)
    output["language-manifest.json"] = canonical_json(language_manifest)
    output["theme-manifest.json"] = canonical_json(theme_manifest)

    for package in (grammar_package, theme_package):
        output[f"licenses/{package.pin.name}-LICENSE.txt"] = package.files["LICENSE"]
        output[f"licenses/{package.pin.name}-NOTICE.txt"] = package.files["NOTICE"]

    all_asset_provenance = grammar_provenance + theme_provenance
    missing_license_ids = sorted(
        entry["id"]
        for entry in all_asset_provenance
        if entry["license"]["status"] == "not-declared-upstream"
    )
    missing_provenance_ids = sorted(
        entry["id"]
        for entry in all_asset_provenance
        if entry["sourceStatus"] != "declared-upstream"
    )
    output["provenance.json"] = canonical_json(
        {
            "assets": all_asset_provenance,
            "missingAssetLicenseDeclarations": missing_license_ids,
            "missingAssetProvenance": missing_provenance_ids,
            "packages": [
                _package_provenance(grammar_package),
                _package_provenance(theme_package),
            ],
            "schemaVersion": SCHEMA_VERSION,
        }
    )

    file_records = [
        {
            "bytes": len(contents),
            "path": path,
            "sha256": hashlib.sha256(contents).hexdigest(),
        }
        for path, contents in sorted(output.items())
    ]
    output["asset-manifest.json"] = canonical_json(
        {
            "counts": {
                "grammars": len(grammar_resources),
                "themes": len(theme_resources),
            },
            "files": file_records,
            "generatedBy": GENERATED_BY,
            "inputs": [
                {
                    "contentSHA256": grammar_package.content_sha256,
                    "name": grammar_package.pin.name,
                    "npmIntegrity": grammar_package.pin.npm_integrity,
                    "version": grammar_package.pin.version,
                },
                {
                    "contentSHA256": theme_package.content_sha256,
                    "name": theme_package.pin.name,
                    "npmIntegrity": theme_package.pin.npm_integrity,
                    "version": theme_package.pin.version,
                },
            ],
            "schemaVersion": SCHEMA_VERSION,
        }
    )
    return output


def _existing_output_is_generated(output: Path) -> bool:
    marker = output / "asset-manifest.json"
    try:
        value = json.loads(marker.read_bytes())
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return False
    return isinstance(value, dict) and value.get("generatedBy") == GENERATED_BY


def write_output(files: Mapping[str, bytes], output: Path, replace: bool) -> None:
    output = output.resolve()
    if output == Path(output.anchor) or output == Path.home().resolve():
        raise ImportFailure(f"refusing unsafe output path: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        if not replace:
            raise ImportFailure(f"output already exists; pass --replace to update it: {output}")
        if not output.is_dir() or not _existing_output_is_generated(output):
            raise ImportFailure(
                "refusing to replace an output not marked as generated by "
                f"{GENERATED_BY}: {output}"
            )

    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp-", dir=output.parent))
    try:
        for relative_path, contents in files.items():
            destination = staging / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(contents)
        if output.exists():
            backup = Path(tempfile.mkdtemp(prefix=f".{output.name}.old-", dir=output.parent))
            backup.rmdir()
            os.replace(output, backup)
            try:
                os.replace(staging, output)
            except BaseException:
                os.replace(backup, output)
                raise
            shutil.rmtree(backup)
        else:
            os.replace(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def check_output(files: Mapping[str, bytes], output: Path) -> None:
    if not output.is_dir():
        raise ImportFailure(f"generated output directory does not exist: {output}")
    actual_files: dict[str, bytes] = {}
    root = output.resolve()
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ImportFailure(f"generated output contains a symlink: {path}")
        if path.is_file():
            actual_files[path.relative_to(root).as_posix()] = path.read_bytes()
    missing = sorted(set(files) - set(actual_files))
    extra = sorted(set(actual_files) - set(files))
    changed = sorted(
        path for path in set(files) & set(actual_files) if files[path] != actual_files[path]
    )
    if missing or extra or changed:
        details: list[str] = []
        if missing:
            details.append("missing: " + ", ".join(missing))
        if extra:
            details.append("extra: " + ", ".join(extra))
        if changed:
            details.append("changed: " + ", ".join(changed))
        raise ImportFailure("generated assets are out of date (" + "; ".join(details) + ")")


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Offline deterministic importer for tm-grammars@1.32.3 and "
            "tm-themes@1.12.3"
        )
    )
    parser.add_argument(
        "--tm-grammars",
        required=True,
        type=Path,
        metavar="PATH",
        help="extracted tm-grammars package directory or .tgz",
    )
    parser.add_argument(
        "--tm-themes",
        required=True,
        type=Path,
        metavar="PATH",
        help="extracted tm-themes package directory or .tgz",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        metavar="DIRECTORY",
        help="generated asset directory",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--replace",
        action="store_true",
        help="replace a directory previously created by this importer",
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help="verify that DIRECTORY is byte-for-byte current without writing",
    )
    return parser.parse_args(arguments)


def run(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    try:
        grammar_package = load_package(options.tm_grammars, GRAMMARS_PIN)
        theme_package = load_package(options.tm_themes, THEMES_PIN)
        files = build_output_files(grammar_package, theme_package)
        if options.check:
            check_output(files, options.output)
            action = "verified"
        else:
            write_output(files, options.output, options.replace)
            action = "wrote"
        grammar_count = sum(path.startswith("grammars/") for path in files)
        theme_count = sum(path.startswith("themes/") for path in files)
        print(
            f"{action} {grammar_count} grammars and {theme_count} themes at "
            f"{options.output.resolve()}"
        )
        return 0
    except (ImportFailure, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
