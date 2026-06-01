#!/bin/bash
set -euo pipefail

# Bump version, commit, tag, and push — triggering the CI release pipeline.
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 0.2.0

VERSION="${1:-}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "$VERSION" ]]; then
    echo "Usage: ./scripts/release.sh <version>"
    echo "  Example: ./scripts/release.sh 0.2.0"
    exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version must be semver (e.g. 0.2.0), got: $VERSION"
    exit 1
fi

# Preflight: must be on main
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
    echo "ERROR: Must be on main branch (currently on '$BRANCH')"
    exit 1
fi

# Preflight: clean working tree
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: Working tree has uncommitted changes. Commit or stash first."
    exit 1
fi

# Preflight: tag must not already exist (local or remote)
if git tag | grep -qx "v${VERSION}"; then
    echo "ERROR: Tag v${VERSION} already exists locally."
    exit 1
fi
if git ls-remote --tags origin "refs/tags/v${VERSION}" | grep -q "v${VERSION}"; then
    echo "ERROR: Tag v${VERSION} already exists on origin."
    exit 1
fi

# Preflight: new version must be greater than current
CURRENT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

version_gt() {
    IFS='.' read -ra a <<< "$1"
    IFS='.' read -ra b <<< "$2"
    for i in 0 1 2; do
        local av=${a[$i]:-0} bv=${b[$i]:-0}
        if (( av > bv )); then return 0; fi
        if (( av < bv )); then return 1; fi
    done
    return 1  # equal is not greater
}

if ! version_gt "$VERSION" "$CURRENT"; then
    echo "ERROR: New version ($VERSION) must be greater than current ($CURRENT)"
    exit 1
fi

# Bump Info.plist versions
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "==> Bumping version: $CURRENT → $VERSION (build $CURRENT_BUILD → $NEW_BUILD)"

/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $NEW_BUILD" Info.plist

# Commit, tag, push
git add Info.plist
git commit -m "Release v${VERSION}"
git tag "v${VERSION}"

echo "==> Pushing commit and tag to origin..."
git push origin main
git push origin "v${VERSION}"

echo ""
echo "==> Done. CI is now building and publishing the v${VERSION} release."
echo "    Monitor: https://github.com/execsumo/heard/actions"
