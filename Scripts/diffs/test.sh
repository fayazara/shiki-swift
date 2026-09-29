#!/bin/zsh
set -eu
cd "${0:A:h:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/shiki-diffs-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/shiki-diffs-swift"
swift test -c release --disable-sandbox --scratch-path "${TMPDIR:-/tmp}/shiki-diffs-build" "$@"
