#!/bin/bash
# macOS Release benchmark using the package's own compiled targets.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
swift build -c release
build_dir="$(swift build -c release --show-bin-path)"
benchmark_dir="$(mktemp -d "${TMPDIR:-/tmp}/shiki-benchmark.XXXXXX")"
trap 'rm -rf "$benchmark_dir"' EXIT
xcrun swiftc -O -parse-as-library \
    -I "$build_dir/Modules" \
    -Xcc "-fmodule-map-file=$build_dir/COniguruma.build/module.modulemap" \
    -Xcc "-I$repo_root/Sources/COniguruma/include" \
    Scripts/benchmark.swift \
    "$build_dir"/Shiki.build/*.o "$build_dir"/ShikiCore.build/*.o \
    "$build_dir"/ShikiUI.build/*.o "$build_dir"/COniguruma.build/*.o \
    -o "$benchmark_dir/benchmark"
"$benchmark_dir/benchmark"
