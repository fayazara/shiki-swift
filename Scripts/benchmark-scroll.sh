#!/bin/bash
# A hidden AppKit viewport: no app launch or user input automation.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
swift build -c release
build_dir="$(swift build -c release --show-bin-path)"
benchmark_dir="$(mktemp -d "${TMPDIR:-/tmp}/shiki-scroll-benchmark.XXXXXX")"
trap 'rm -rf "$benchmark_dir"' EXIT
# Use the current build map rather than accidentally linking stale object files.
/usr/bin/python3 - "$build_dir" "$benchmark_dir/objects" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
objects = []
for target in ['Shiki', 'ShikiCore']:
    entries = json.loads((root / (target + '.build') / 'output-file-map.json').read_text())
    objects += [value['object'] for key, value in entries.items() if key and 'object' in value]
objects += [str(path) for path in (root / 'COniguruma.build').rglob('*.o')]
pathlib.Path(sys.argv[2]).write_text('\n'.join('"' + path + '"' for path in objects))
PY
# Compile the viewport sources alongside the harness to inspect internal work
# counters without requiring a testing-enabled production module.
xcrun swiftc -O -parse-as-library \
    -I "$build_dir/Modules" \
    -Xcc "-fmodule-map-file=$build_dir/COniguruma.build/module.modulemap" \
    -Xcc "-I$repo_root/Sources/COniguruma/include" \
    Scripts/benchmark-scroll.swift \
    Sources/ShikiUI/ShikiVirtualizedCodeView.swift \
    Sources/ShikiUI/ShikiTextDocument.swift \
    Sources/ShikiUI/ShikiRGBAColor.swift \
    @"$benchmark_dir/objects" -o "$benchmark_dir/benchmark"
"$benchmark_dir/benchmark" "$@"
