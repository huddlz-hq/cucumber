#!/bin/bash
# release.sh - Automate the Cucumber release process

set -e  # Exit immediately if a command exits with a non-zero status

# Check if a version parameter was provided
if [ -z "$1" ]; then
  echo "Usage: ./scripts/release.sh <version>"
  echo "Example: ./scripts/release.sh 0.2.0"
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

echo "Creating release $VERSION_TAG..."

# Update version in mix.exs
sed -i '' "s/@version \"[0-9.]*\"/@version \"$VERSION\"/g" mix.exs

# Update CHANGELOG.md
today=$(date +"%Y-%m-%d")
changelog_entry="## v$VERSION ($today)\n\n* [Add changes here]\n\n"
sed -i '' "s/# Changelog/# Changelog\n\n$changelog_entry/" CHANGELOG.md

# Open the changelog for editing
echo "Opening CHANGELOG.md for editing..."
${EDITOR:-vi} CHANGELOG.md

# Build and test
echo "Running tests..."
mix test || { echo "Tests failed"; exit 1; }

echo "Building docs..."
mix docs || { echo "Doc generation failed"; exit 1; }

# Commit version bump
git add mix.exs CHANGELOG.md
git commit -m "Bump version to $VERSION"

# Publish to Hex
echo "Publishing to Hex.pm..."
mix hex.publish

# Create a git tag (only after successful publishing)
git tag $VERSION_TAG

# Push changes and tag to GitHub
echo "Pushing changes and tag to GitHub..."
git push origin main
git push origin $VERSION_TAG

echo "Release $VERSION_TAG complete!"
echo "Don't forget to create a GitHub release at: https://github.com/huddlz-hq/cucumber/releases/new?tag=$VERSION_TAG"