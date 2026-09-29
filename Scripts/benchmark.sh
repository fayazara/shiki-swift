#!/bin/bash
# macOS Release benchmark of tokenization and attribute preparation.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
swift run -c release shiki-benchmark "$@"
