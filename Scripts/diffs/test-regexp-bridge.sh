#!/bin/zsh
set -eu
cd "${0:A:h:h:h}"
regex_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/shiki-diffs-regex.XXXXXX")
trap 'rm -rf "$regex_test_dir"' EXIT
clang -g -O1 -fsanitize=address,undefined -I Sources/CSDRegex/include \
    Sources/CSDRegex/Bridge.c Sources/CSDRegex/cutils.c \
    Sources/CSDRegex/libregexp.c Sources/CSDRegex/libunicode.c \
    Tests/RegexBridge/regex_sanitize.c -o "$regex_test_dir/check"
"$regex_test_dir/check"
