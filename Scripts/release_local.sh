#!/usr/bin/env bash
#
# Build the DMG locally and publish it with `gh`, for when CI cannot run.
#
# CI needs a macOS runner per artifact and those are quota-limited on free
# accounts, which makes releases stall. This does the same work on this machine:
# build -> checksum -> create/append a GitHub Release.
#
# Usage:
#   Scripts/release_local.sh v1.0.0
#   Scripts/release_local.sh v1.0.0 --arch arm64
#   Scripts/release_local.sh v1.0.0 --no-core
#   Scripts/release_local.sh v1.0.0 --draft        # build + verify, do not publish
#
# Environment:
#   APP_NAME      app/product name (default: ClashBar)
#   DMG_SUFFIX    artifact suffix (default: apple-silicon, or <arch>)
#   CODESIGN_IDENTITY  codesign identity ("-" = ad-hoc, default)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-ClashBar}"

TAG=""
HOST_ARCH="$(uname -m)"
TARGET_ARCH=""
WITH_CORE=1
DRAFT=0

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage ;;
    --arch)
      [ $# -ge 2 ] || usage
      TARGET_ARCH="$2"
      shift 2
      ;;
    --no-core)
      WITH_CORE=0
      shift
      ;;
    --draft)
      DRAFT=1
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      ;;
    *)
      [ -z "$TAG" ] || usage
      TAG="$1"
      shift
      ;;
  esac
done

[ -n "$TAG" ] || { echo "Missing release tag, e.g. v1.0.0" >&2; usage; }
[[ "$TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Tag '$TAG' is not valid (expected v1.2.3 or 1.2.3)." >&2
  exit 1
}
VERSION="${TAG#v}"
BUILD_ARCH="${TARGET_ARCH:-$HOST_ARCH}"

if [ -n "$TARGET_ARCH" ] && [ "$TARGET_ARCH" != "$HOST_ARCH" ]; then
  echo "Cross-building ${TARGET_ARCH} on ${HOST_ARCH} is untested; prefer a native run." >&2
fi

case "$BUILD_ARCH" in
  arm64) DEFAULT_SUFFIX="apple-silicon" ;;
  x86_64) DEFAULT_SUFFIX="intel" ;;
  *) DEFAULT_SUFFIX="$BUILD_ARCH" ;;
esac
DMG_SUFFIX="${DMG_SUFFIX:-$DEFAULT_SUFFIX}"
[ "$WITH_CORE" = "1" ] || DMG_SUFFIX="${DMG_SUFFIX}-no-core"

DMG_NAME="${APP_NAME}-${VERSION}-${DMG_SUFFIX}.dmg"
DMG_PATH="$ROOT/dist/$DMG_NAME"
SHA_PATH="$DMG_PATH.sha256"

cd "$ROOT"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is not clean; commit first so the artifact matches the tag." >&2
  exit 1
fi

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag $TAG does not exist locally. Create it before releasing." >&2
  exit 1
fi

echo "==> Building ${APP_NAME} ${VERSION} (${BUILD_ARCH}, core=${WITH_CORE})"
APP_VERSION="$VERSION" \
  BUILD_NUMBER="$VERSION" \
  TARGET_ARCH="$BUILD_ARCH" \
  PREPARE_MIHOMO_BINARY="$WITH_CORE" \
  BUNDLE_MIHOMO_BINARY="$WITH_CORE" \
  REQUIRE_MIHOMO_BINARY="$WITH_CORE" \
  ./Scripts/build.sh all

[ -f "$DMG_PATH" ] || { echo "Expected DMG not produced: $DMG_PATH" >&2; exit 1; }
[ -f "$SHA_PATH" ] || { echo "Expected checksum not produced: $SHA_PATH" >&2; exit 1; }

echo "==> Artifact: $DMG_NAME"
shasum -a 256 -c "$SHA_PATH" >/dev/null || { echo "Checksum mismatch." >&2; exit 1; }
echo "    checksum OK"

if [ "$DRAFT" = "1" ]; then
  echo "==> --draft given; skipping publish. Upload manually if needed:"
  echo "    gh release upload $TAG \"$DMG_PATH\" \"$SHA_PATH\""
  exit 0
fi

command -v gh >/dev/null 2>&1 || { echo "gh CLI is required to publish." >&2; exit 1; }

git push origin "refs/tags/$TAG"

RELEASE_NOTES="$(mktemp -t clashbar-notes.XXXXXX)"
trap 'rm -f "$RELEASE_NOTES"' EXIT
GITHUB_REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
  ./Scripts/generate_release_notes.sh "$TAG" "$VERSION" "$RELEASE_NOTES"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Release $TAG exists; uploading artifact"
  gh release upload "$TAG" "$DMG_PATH" "$SHA_PATH" --clobber
else
  echo "==> Creating release $TAG"
  gh release create "$TAG" "$DMG_PATH" "$SHA_PATH" \
    --title "${APP_NAME} ${VERSION}" \
    --notes-file "$RELEASE_NOTES" \
    --verify-tag
fi

echo "==> Published $(gh release view "$TAG" --json url --jq .url)"
