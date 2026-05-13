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

echo "==> Generating app icon"
./scripts/make-icon.sh

echo "==> Building release binary"
swift build -c release

mkdir -p "${DIST_DIR}"
rm -rf "${APP_BUNDLE}" "${DMG_PATH}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

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
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
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

1. Download **\`${APP_NAME}-${VERSION}.dmg\`** (Assets ↓ から).
2. DMG を開いて \`${APP_NAME}.app\` を **Applications** にドラッグ.
3. ターミナルで以下を実行（**初回1回だけ必要**）:

   \`\`\`bash
   xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app && open /Applications/${APP_NAME}.app
   \`\`\`

> このアプリは Apple Developer ID で署名されていないため、上の手順を踏まずに開くと
> "${APP_NAME}" Not Opened というモーダルが出てゴミ箱送りを促されます。
> xattr で検疫属性を外せば普通に開けます（macOS の標準的な逃げ道）。

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
