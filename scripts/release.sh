#!/bin/bash
# release.sh - Publish and tag a release
#
# Prerequisites: version should already be bumped in mix.exs and CHANGELOG.md updated

set -e

if [ -z "$1" ]; then
  echo "Usage: ./scripts/release.sh <version>"
  echo "Example: ./scripts/release.sh 0.7.0"
  exit 1
fi

VERSION=$1
VERSION_TAG="v$VERSION"

# Ensure we're on the main branch
current_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$current_branch" != "main" ]; then
  echo "Error: You must be on the main branch to create a release."
  exit 1
fi

# Check if the working directory is clean
if [ -n "$(git status --porcelain)" ]; then
  echo "Error: Working directory is not clean. Please commit or stash changes first."
  exit 1
fi

# Verify version matches
current_version=$(grep '@version' mix.exs | sed 's/.*"\(.*\)".*/\1/')
if [ "$current_version" != "$VERSION" ]; then
  echo "Error: Version in mix.exs ($current_version) doesn't match $VERSION"
  echo "Please update mix.exs and CHANGELOG.md first."
  exit 1
fi

echo "Releasing $VERSION_TAG..."

# Run tests
echo "Running tests..."
mix test || { echo "Tests failed"; exit 1; }

# Build docs
echo "Building docs..."
mix docs || { echo "Doc generation failed"; exit 1; }

# Publish to Hex
echo "Publishing to Hex.pm..."
mix hex.publish

# Tag after successful publish
echo "Creating tag $VERSION_TAG..."
git tag $VERSION_TAG

# Push
echo "Pushing to GitHub..."
git push origin main
git push origin $VERSION_TAG

echo ""
echo "Release $VERSION_TAG complete!"
echo "Create GitHub release: https://github.com/huddlz-hq/cucumber/releases/new?tag=$VERSION_TAG"
