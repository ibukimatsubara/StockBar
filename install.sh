#!/usr/bin/env bash
set -euo pipefail

# StockBar をビルドして .app バンドルを /Applications に配置するスクリプト。

APP_NAME="StockBar"
BUNDLE_ID="com.mibuki.stockbar"
INSTALL_DIR="/Applications"
APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"

cd "$(dirname "$0")"
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0-dev)"

echo "==> Building release binary"
swift build -c release

BIN_PATH=".build/release/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "error: release binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> Stopping running instances"
pkill -f "/${APP_NAME}$" 2>/dev/null || true
sleep 1

echo "==> Constructing .app bundle"
TMP_APP="$(mktemp -d)/${APP_NAME}.app"
mkdir -p "${TMP_APP}/Contents/MacOS"
mkdir -p "${TMP_APP}/Contents/Resources"
cp "${BIN_PATH}" "${TMP_APP}/Contents/MacOS/${APP_NAME}"

cat > "${TMP_APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>     <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>         <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "==> Installing to ${APP_PATH}"
if [[ -w "${INSTALL_DIR}" ]]; then
  rm -rf "${APP_PATH}"
  cp -R "${TMP_APP}" "${APP_PATH}"
else
  echo "    (requires sudo for ${INSTALL_DIR})"
  sudo rm -rf "${APP_PATH}"
  sudo cp -R "${TMP_APP}" "${APP_PATH}"
fi

# ad-hoc 署名（Gatekeeper の "壊れている" 表示回避）
codesign --force --deep --sign - "${APP_PATH}" >/dev/null 2>&1 || true

echo "==> Launching"
open "${APP_PATH}"

echo ""
echo "✅ Installed: ${APP_PATH}"
echo ""
echo "ログイン時に自動起動するには:"
echo "  システム設定 → 一般 → ログイン項目 → 「開いた時」の + ボタンから ${APP_NAME} を追加"
