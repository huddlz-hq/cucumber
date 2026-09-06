#!/bin/bash
# Real temporary Git repositories; Mix and push are mocked. No network or publish.
set -euo pipefail
source_dir=$(cd "$(dirname "$0")" && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
real_git=$(command -v git)
export REAL_GIT="$real_git"
mkdir "$test_dir/bin"
cat > "$test_dir/bin/git" <<'MOCK'
#!/bin/bash
if [ "$1" = push ]; then
  echo "push $*" >> "$CALLS"
  exit 0
fi
exec "$REAL_GIT" "$@"
MOCK
cat > "$test_dir/bin/mix" <<'MOCK'
#!/bin/bash
set -eu
echo "${MIX_ENV:-unset} $*" >> "$CALLS"
[ "$1" != "${FAIL_COMMAND:-}" ] || exit 1
if [ "$1" = precommit ]; then
  case "${MUTATION:-}" in
    tracked) echo changed >> README.md ;;
    untracked) echo stray > stray.txt ;;
    ignored) echo stray > lib/stray.ex ;;
    commit) "$REAL_GIT" commit --allow-empty -qm moved ;;
  esac
fi
if [ "$1" = hex.build ] && [ "$#" -gt 1 ]; then
  build=$(mktemp -d)
  tar -czf "$build/contents.tar.gz" mix.exs README.md lib
  tar -cf "$3" -C "$build" contents.tar.gz
  rm -rf "$build"
fi
MOCK
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"

setup() {
  case_name=$1
  mkdir "$test_dir/$case_name"
  cd "$test_dir/$case_name"
  git init -q -b main
  git config user.email test@example.invalid
  git config user.name 'Release test'
  mkdir scripts lib
  cp "$source_dir/release.sh" scripts/
  printf '@version "1.0.0"\n' > mix.exs
  echo source > lib/source.ex
  echo readme > README.md
  echo lib/stray.ex > .gitignore
  git add .
  git commit -qm initial
  git init --bare -q "$test_dir/$case_name-remote"
  git remote add origin "$test_dir/$case_name-remote"
  export CALLS="$test_dir/$case_name.calls"
  : > "$CALLS"
  unset MUTATION FAIL_COMMAND
}

reject() {
  if bash scripts/release.sh "${1:-1.0.0}" > "$test_dir/output" 2>&1; then
    echo "FAIL: $case_name accepted"; exit 1
  fi
  if grep -Eq 'hex.publish|^push ' "$CALLS"; then
    echo "FAIL: $case_name published or pushed"; exit 1
  fi
  echo "PASS: $case_name"
}

setup dirty_tracked; echo dirty >> README.md; reject
setup dirty_staged; echo dirty >> README.md; git add README.md; reject
setup dirty_untracked; echo stray > new.txt; reject
setup dirty_ignored_package; echo stray > lib/stray.ex; reject
setup wrong_branch; git checkout -qb feature; reject
setup wrong_version; reject 2.0.0
setup wrong_local_tag; git tag v1.0.0; git commit --allow-empty -qm next; reject
setup wrong_remote_tag
 git tag -a v1.0.0 -m release
 "$REAL_GIT" push -q origin refs/tags/v1.0.0
 git tag -d v1.0.0 >/dev/null
 git commit --allow-empty -qm next
 reject
for mutation in tracked untracked ignored commit; do
  setup "mutation_$mutation"; export MUTATION=$mutation; reject
done
for command in precommit hex.publish; do
  setup "failure_${command// /_}"
  export FAIL_COMMAND="$command"
  if [ "$command" = hex.publish ]; then
    if bash scripts/release.sh 1.0.0 > "$test_dir/output" 2>&1; then exit 1; fi
    ! grep -q '^push ' "$CALLS"
    ! git show-ref --verify --quiet refs/tags/v1.0.0
    echo "PASS: $case_name"
  else
    reject
  fi
done
setup failure_package_build
export FAIL_COMMAND="hex.build"
# Fail any invocation of this task, including the release output path.
reject
setup check_only
bash scripts/release.sh 1.0.0 --check > "$test_dir/output" 2>&1
! grep -Eq 'hex.publish|^push ' "$CALLS"
! git show-ref --verify --quiet refs/tags/v1.0.0
grep -q '^test precommit$' "$CALLS"
echo "PASS: check_only"
for tag_type in new lightweight annotated; do
  setup "success_$tag_type"
  if [ "$tag_type" = lightweight ]; then git tag v1.0.0; fi
  if [ "$tag_type" = annotated ]; then
    git tag -a v1.0.0 -m release
    "$REAL_GIT" push -q origin refs/tags/v1.0.0
  fi
  bash scripts/release.sh 1.0.0 > "$test_dir/output" 2>&1
  [ "$(git rev-parse 'v1.0.0^{commit}')" = "$(git rev-parse HEAD)" ]
  grep -q '^dev hex.publish$' "$CALLS"
  grep -q '^push push --atomic ' "$CALLS"
  echo "PASS: $case_name"
done
