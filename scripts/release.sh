#!/usr/bin/env bash
set -euo pipefail

# StockBar をリリースビルドして DMG を作り、git tag + GitHub Release を作成する。
# 使い方: ./scripts/release.sh
# バージョンは VERSION ファイルから読む。

cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
TAG="v${VERSION}"
APP_NAME="StockBar"
BUNDLE_ID="com.mibuki.stockbar"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "==> Preparing release ${TAG}"

# git の状態確認
if ! git diff-index --quiet HEAD --; then
  echo "error: working tree has uncommitted changes. commit or stash first." >&2
  git status --short
  exit 1
fi

if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "error: tag ${TAG} already exists. bump VERSION first." >&2
  exit 1
fi

echo "==> Building release binary"
swift build -c release

mkdir -p "${DIST_DIR}"
rm -rf "${APP_BUNDLE}" "${DMG_PATH}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>           <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "${APP_BUNDLE}" >/dev/null 2>&1 || true

echo "==> Creating DMG"
STAGING="$(mktemp -d)"
cp -R "${APP_BUNDLE}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "${STAGING}" \
  -ov -format UDZO \
  "${DMG_PATH}" >/dev/null
rm -rf "${STAGING}"
echo "    ${DMG_PATH}"

echo "==> Tagging ${TAG}"
git tag -a "${TAG}" -m "Release ${TAG}"
git push origin "${TAG}"

echo "==> Creating GitHub Release"
NOTES_FILE="$(mktemp)"
cat > "${NOTES_FILE}" <<NOTES
## Install

1. Download \`${APP_NAME}-${VERSION}.dmg\` below.
2. Open it and drag \`${APP_NAME}.app\` into \`Applications\`.
3. First launch: right-click the app → **Open** (signed ad-hoc, so Gatekeeper warns once).

Or via CLI:
\`\`\`bash
xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app
open /Applications/${APP_NAME}.app
\`\`\`

## Changes
$(git log --pretty=format:'- %s' "$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo HEAD~10)..HEAD" 2>/dev/null || git log --pretty=format:'- %s' -10)
NOTES

gh release create "${TAG}" "${DMG_PATH}" \
  --title "${TAG}" \
  --notes-file "${NOTES_FILE}" \
  --latest

rm -f "${NOTES_FILE}"

echo ""
echo "🚀 Released ${TAG}"
echo "    https://github.com/ibukimatsubara/${APP_NAME}/releases/tag/${TAG}"
