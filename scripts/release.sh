#!/bin/bash
# Version and changelog must already be committed. --check never publishes or pushes.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "Error: $*" >&2; exit 1; }
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != "--check" ]; }; then
  fail "Usage: ./scripts/release.sh <version> [--check]"
fi
VERSION=$1
VERSION_TAG="v$VERSION"
git check-ref-format "refs/tags/$VERSION_TAG" || fail "Invalid release tag"
RELEASE_COMMIT=$(git rev-parse HEAD)

assert_clean() {
  [ "$(git branch --show-current)" = main ] || fail "Releases must be on main"
  [ "$(git rev-parse HEAD)" = "$RELEASE_COMMIT" ] || fail "HEAD changed during validation"
  [ -z "$(git status --porcelain --untracked-files=all)" ] || fail "Commit or remove all tracked and untracked changes first"
}

assert_tag() {
  if git show-ref --verify --quiet "refs/tags/$VERSION_TAG"; then
    [ "$(git rev-parse "refs/tags/$VERSION_TAG^{commit}")" = "$RELEASE_COMMIT" ] || fail "Local tag $VERSION_TAG points to a different commit"
  fi
  # Check remote tags too, including the peeled commit of annotated tags.
  remote_tags=$(git ls-remote --tags origin "refs/tags/$VERSION_TAG" "refs/tags/$VERSION_TAG^{}")
  remote_commit=$(printf '%s\n' "$remote_tags" | awk 'NF {hash=$1} END {print hash}')
  [ -z "$remote_commit" ] || [ "$remote_commit" = "$RELEASE_COMMIT" ] || fail "Remote tag $VERSION_TAG points to a different commit"
}

assert_clean
current_version=$(sed -n 's/^[[:space:]]*@version "\([^"]*\)".*/\1/p' mix.exs)
[ "$current_version" = "$VERSION" ] || fail "Version in mix.exs ($current_version) does not match $VERSION"
assert_tag

MIX_ENV=test mix precommit

# Inspect the actual Hex file selection, including ignored files. Every packaged
# byte must come from the release commit, not a stray file under lib/ or docs/.
package_dir=$(mktemp -d)
trap 'rm -rf "$package_dir"' EXIT
MIX_ENV=dev mix hex.build --output "$package_dir/package.tar"
mkdir "$package_dir/package"
tar -xf "$package_dir/package.tar" -C "$package_dir" contents.tar.gz
tar -xzf "$package_dir/contents.tar.gz" -C "$package_dir/package"
find "$package_dir/package" -type f -print0 > "$package_dir/files"
[ -s "$package_dir/files" ] || fail "Package is empty"
while IFS= read -r -d '' file; do
  path=${file#"$package_dir/package/"}
  git show "$RELEASE_COMMIT:$path" > "$package_dir/committed" || fail "Package file is not committed: $path"
  cmp -s "$file" "$package_dir/committed" || fail "Package differs from release commit: $path"
done < "$package_dir/files"
[ -z "$(find "$package_dir/package" -type l -print)" ] || fail "Package contains symbolic links"

assert_clean
assert_tag
if [ "${2:-}" = --check ]; then
  echo "Release $VERSION_TAG validated; nothing published or pushed."
  exit 0
fi

MIX_ENV=dev mix hex.publish
# Do not tag a changed checkout even if publishing succeeded.
assert_clean
if ! git show-ref --verify --quiet "refs/tags/$VERSION_TAG"; then
  git tag "$VERSION_TAG" "$RELEASE_COMMIT"
fi
git push --atomic origin "$RELEASE_COMMIT:refs/heads/main" "refs/tags/$VERSION_TAG"
echo "Release $VERSION_TAG complete!"
echo "Create GitHub release: https://github.com/huddlz-hq/cucumber/releases/new?tag=$VERSION_TAG"
