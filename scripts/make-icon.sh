#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SVG="Resources/icon.svg"
ICONSET="Resources/AppIcon.iconset"
ICNS="Resources/AppIcon.icns"

if [[ ! -f "$SVG" ]]; then
  echo "error: $SVG not found" >&2
  exit 1
fi

rm -rf "$ICONSET" "$ICNS"
mkdir -p "$ICONSET"

# SVG → 各サイズの PNG を NSImage で描画
swift - <<'SWIFT'
import Foundation
import AppKit

let svg = URL(fileURLWithPath: "Resources/icon.svg")
let data = try Data(contentsOf: svg)
guard let image = NSImage(data: data) else { fatalError("SVG load failed") }

let sizes: [(name: String, size: CGFloat)] = [
    ("16x16",     16),  ("16x16@2x",   32),
    ("32x32",     32),  ("32x32@2x",   64),
    ("128x128",  128),  ("128x128@2x", 256),
    ("256x256",  256),  ("256x256@2x", 512),
    ("512x512",  512),  ("512x512@2x", 1024),
]
for (name, size) in sizes {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: "Resources/AppIcon.iconset/icon_\(name).png"))
}
SWIFT

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "✅ $ICNS"
