#!/bin/zsh
# Checks, tags, and publishes a ShikiSwift release. See RELEASING.md.
#
#   Scripts/release.sh 0.1.0            # check, tag, push, publish
#   Scripts/release.sh 0.1.0 --dry-run  # every check, no tag or push
set -eu
cd "${0:A:h:h}"

version=${1:-}
dry_run=false
[[ ${2:-} == --dry-run ]] && dry_run=true
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fail() { print -u2 "release: $*"; exit 1; }
step() { print "\n==> $*"; }

[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "usage: Scripts/release.sh X.Y.Z [--dry-run] (no 'v' prefix)"

step "Checking the repository"
[[ $(git branch --show-current) == main ]] || fail "not on main"
[[ -z $(git status --porcelain) ]] || fail "working tree is not clean"
git fetch --quiet --tags origin
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || fail "main is not in sync with origin/main"
if git rev-parse --quiet --verify "refs/tags/$version" >/dev/null; then fail "tag $version already exists"; fi
grep -q "^## \[$version\] - " CHANGELOG.md || fail "CHANGELOG.md has no '## [$version] - DATE' section"
grep -q "from: \"$version\"" README.md || fail "README's installation snippet does not pin $version"
grep -q "MARKETING_VERSION = $version;" shiki-swift.xcodeproj/project.pbxproj || fail "demo app MARKETING_VERSION is not $version"
command -v gh >/dev/null || fail "the GitHub CLI (gh) is required"
$dry_run || gh auth status >/dev/null 2>&1 || fail "gh is not logged in"

# The release notes are this version's changelog section, without its heading.
notes=$(mktemp -t shiki-release-notes)
trap 'rm -f "$notes"' EXIT
awk -v heading="## [$version]" '
    index($0, heading) == 1 { found = 1; next }
    found && /^## \[/ { exit }
    found && /^\[[^]]+\]: / { exit }
    found { print }
' CHANGELOG.md > "$notes"
[[ -s $notes ]] || fail "the changelog section for $version is empty"

step "Testing Shiki, ShikiCore, and ShikiUI (Release)"
swift test -c release --filter '^(ShikiCoreTests|ShikiTests|ShikiUITests)\.'

step "Testing ShikiDiffs (Release, sequential)"
swift test -c release --no-parallel --filter ShikiDiffsTests

step "Building the package for iOS"
build_dir=$(mktemp -d -t shiki-release-build)
xcodebuild -quiet -scheme ShikiDiffs -destination 'generic/platform=iOS' \
    -derivedDataPath "$build_dir/ios" build

step "Building the demo app (Release)"
xcodebuild -quiet -scheme shiki-swift -configuration Release \
    -derivedDataPath "$build_dir/app" build
rm -rf "$build_dir"

if $dry_run; then
    step "Dry run passed. Release notes would be:"
    cat "$notes"
    exit 0
fi

step "Tagging $version"
git tag -a "$version" -m "ShikiSwift $version"
git push origin "refs/tags/$version"

step "Publishing the GitHub release"
gh release create "$version" --verify-tag --title "v$version" --notes-file "$notes"
print "\nReleased $version: $(gh release view "$version" --json url --jq .url)"
