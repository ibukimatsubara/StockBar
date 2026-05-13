# StockBar

# 🚀 仕事の集中力低下に最適！ 📉

macOS のメニューバーに株価・指数・為替・暗号資産をローテーション表示する常駐アプリ。

- 上昇=赤 / 下落=緑（日本式）
- 複数銘柄をローテーション表示
- クリックで管理ポップオーバー（追加・削除・並び替え・個別非表示）
- 集中モード（会議・画面共有用の一括非表示）
- 切替間隔 / 更新間隔をスライダーで調整
- 市場閉場中（日本・米国とも閉場）は自動更新を停止
- データソース: Yahoo Finance（非公式チャートAPI）

## 必要環境

- macOS 13 (Ventura) 以降
- Swift 5.9+（Xcode 15 以降を入れていればOK）

## インストール

### A. DMG からインストール（推奨）

[Releases](https://github.com/ibukimatsubara/StockBar/releases/latest) から `StockBar-x.y.z.dmg` をダウンロード → 開いて `StockBar.app` を `Applications` にドラッグ。

初回起動時に「開発元を確認できません」と出る場合：

- Finder で右クリック → **開く**（一度だけ）

または、Gatekeeper の検疫属性を外して開く：

```bash
xattr -dr com.apple.quarantine /Applications/StockBar.app
open /Applications/StockBar.app
```

### B. ソースからビルド（開発用）

```bash
./install.sh
```

`swift build -c release` → `.app` バンドル生成 → `/Applications/StockBar.app` に配置 → 起動。

## ログイン時に自動起動する

`System Settings` → `General` → `Login Items & Extensions` → **Open at Login** の `+` から `/Applications/StockBar.app` を選択。

CLI でやる場合：

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/StockBar.app", hidden:true}'
```

解除する場合：

```bash
osascript -e 'tell application "System Events" to delete login item "StockBar"'
```

## アンインストール

```bash
osascript -e 'tell application "System Events" to delete login item "StockBar"' 2>/dev/null || true
pkill -f "/StockBar$" 2>/dev/null || true
rm -rf /Applications/StockBar.app
rm -f ~/Library/Preferences/StockBar.plist
```

## 銘柄コードの書き方（Yahoo Finance 形式）

| 種類 | 例 | 備考 |
|---|---|---|
| 日本株 | `7203.T` または `7203` | 4桁数字は自動で `.T` を補完 |
| 米国株 | `AAPL`, `MSFT` | そのまま |
| 指数 | `^N225`, `^IXIC`, `^GSPC` | 先頭に `^` |
| 為替 | `USDJPY=X`, `EURJPY=X` | 末尾 `=X` |
| 商品先物 | `GC=F` (金), `CL=F` (原油) | 末尾 `=F` |
| 暗号資産 | `BTC-USD`, `ETH-USD` | ハイフン区切り |

## 開発

```bash
swift run                # デバッグ実行
swift build -c release   # リリースビルドのみ
```

### リリース手順

1. `VERSION` を更新（例: `0.1.0` → `0.1.1`）してコミット&push
2. `./scripts/release.sh` を実行
   - リリースビルド → `.app` → DMG → git tag → GitHub Release を一括作成
   - 作業ツリーがクリーンで、まだ存在しないタグであることが前提

ソース構成：

```
Sources/StockBar/
  StockBarApp.swift   # @main エントリ
  AppDelegate.swift   # NSStatusItem + NSPopover の組み立て
  StockStore.swift    # 状態管理・取得・ローテーション・永続化
  YahooFinance.swift  # API クライアント
  Models.swift        # Stock / Quote
  ContentView.swift   # ポップオーバー UI（SwiftUI）
```

## 設定の保存場所

`~/Library/Preferences/StockBar.plist`（`UserDefaults`）

## ライセンス

[MIT](LICENSE) © ibukimatsubara
