# claude-usage-widget-windows

Windows のデスクトップ右上に、**Claude Code の使用状況**（現在の5時間セッション・週間制限の使用率%とリセット時刻）を常時表示する PowerShell + WPF ウィジェットです。

## 由来

[fourn9/claude-usage-widget](https://github.com/fourn9/claude-usage-widget)（macOS / Übersicht 版）をベースにした **Windows 移植版** です。表示ロジックや API 取得の考え方は原作者 [fourn9](https://github.com/fourn9) 氏の実装に基づいており、MIT ライセンスの条件に従い配布しています（[LICENSE](LICENSE) を参照）。

```
┌──────────────────────────────────────┐
│ CLAUDE 使用状況    ⟳ クリックで接続   │
│ 現在のセッション             42%      │
│ ▓▓▓▓▓▓▓▓░░░░░░░░░░░░                  │
│ あと 2時間13分                        │
│ 週間制限（全体）             18%      │
│ ▓▓▓░░░░░░░░░░░░░░░░░░                  │
│ 6/5(金) 22:00 リセット                │
└──────────────────────────────────────┘
```

- 使用率に応じてバーの色が変わる（〜80% 青 / 80%〜 橙 / 95%〜 赤）。
- セッションは「あと◯時間◯分」、週間は「何曜日の何時にリセット」を表示。
- パネルはドラッグで好きな位置に移動でき、位置を記憶する（再起動後も維持）。
- **起動時は API を叩かない** — ステータスをクリックして手動で接続開始（429 回避）。
- **追加インストール不要**（Windows 標準の PowerShell + .NET Framework のみで動作）。

> **⚠️ 非公式ツールです。** このウィジェットは Anthropic 非公式・非ドキュメントのエンドポイント
> (`https://api.anthropic.com/api/oauth/usage`) を利用しています。Anthropic 公式の製品ではなく、
> 提供・保証もありません。予告なく動かなくなる可能性があります。**自己責任でご利用ください。**
> 表示するのは自分のアカウントの使用率（%）とリセット時刻のみで、会話内容などは一切扱いません。

---

## 仕組み

```
  PowerShell + WPF
  ┌──────────────────────────┐    30秒タイマーで再描画
  │ claude-usage.ps1         │
  │ （半透明パネル・%バー）    │
  └──────────────────────────┘
              │
              ▼
  データ取得（同一スクリプト内）
   ├─ ~/.claude/.credentials.json から OAuth トークンを読む（出力しない）
   ├─ 起動時は API を叩かない（ステータスクリックで接続開始）
   ├─ 接続後は 5分に1回だけ API を実体取得（429 を踏んだら15分バックオフ）
   └─ 結果を usage.json にキャッシュし UI を更新
```

- **起動時は API を叩かない**：PC 起動直後はキャッシュだけ表示し、ユーザーがステータスをクリックして接続を開始する。これで起動時の 429 を回避する。
- **表示と取得を分離**：画面更新は30秒ごとだが、API への実アクセスは5分に間引く。これでレート制限を踏みにくくしている。
- **トークンは読むだけ**：`~/.claude/.credentials.json` から1項目だけを読み、`Bearer` ヘッダに載せるのみ。標準出力にも**書き出さない**。

---

## 必要なもの

| 要件 | 備考 |
|------|------|
| Windows 10 以降 | PowerShell 5.1+ と .NET Framework（WPF）は標準搭載 |
| Claude Code にログイン済み | `~/.claude/.credentials.json` が存在する状態。`claude` を一度起動してログインしておく |

> 追加インストールは一切不要です。

---

## インストール

```powershell
git clone https://github.com/miiiiiya1116/claude-usage-widget-windows.git
cd claude-usage-widget-windows
.\install.ps1
```

`install.ps1` は次を自動で行います。

1. `windows/claude-usage.ps1` を `~/.claude-usage-widget/` にコピー
2. スタートアップショートカットを作成（ログイン時に自動起動）

インストール後、デスクトップ右上に半透明パネルが表示されます。
右上のステータス（「⟳ クリックで接続」）をクリックすると API 取得が始まります。

### インストール確認

以下の2つが両方 `True` を返せば、ログイン時の自動起動が正しく設定されています。

```powershell
Test-Path "$env:USERPROFILE\.claude-usage-widget\claude-usage.ps1"
Test-Path "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Claude Usage Widget.lnk"
```

### 手動起動

```powershell
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude-usage-widget\claude-usage.ps1"
```

### アンインストール

```powershell
.\uninstall.ps1
```

---

## 使い方

1. PC 起動後、ウィジェットが自動表示される（キャッシュがあれば前回の値を表示）
2. 右上のステータス「**⟳ クリックで接続**」をクリックして API 取得を開始
3. 取得成功後は自動で 5 分間隔の定期更新に移行

---

## ステータス表示

右上のステータスエリアには現在の状態が表示されます。

| 表示 | 意味 |
|------|------|
| （空白） | 正常に最新データ表示中 |
| ⟳ クリックで接続 | 起動直後。クリックで API 取得を開始 |
| ⟳ 制限中 (5分後) | API レート制限中。カッコ内は次回リトライまでの時間 |
| ⟳ 更新待ち (3分後) | 次回更新までの残り時間 |
| ⚠ 要ログイン | 認証エラー（`claude` で再ログインが必要） |
| ⚠ ログインなし | `~/.claude/.credentials.json` が見つからない |
| ⚠ 接続エラー | ネットワーク接続の問題 |

**ステータスをクリック**すると、いつでも待ち時間を無視して即座に API 取得を試みます。
マウスホバーでツールチップに詳細情報が表示されます。

---

## ドラッグ操作

パネルの「CLAUDE 使用状況」ヘッダ部分をドラッグして好きな位置に移動できます。
位置はファイルに保存され、再起動後も維持されます。ヘッダをダブルクリックで初期位置（右上）にリセット。

---

## カスタマイズ

`~/.claude-usage-widget/claude-usage.ps1` の先頭にある定数を編集します。

| 変更したいこと | 変数 |
|----------------|------|
| 色のしきい値（橙/赤になる%） | `$WARN = 80` / `$DANGER = 95` |
| パネル幅 | `$PANEL_WIDTH = 320` |
| 画面端からの余白 | `$MARGIN = 8` |
| 表示の更新間隔 | `$REFRESH_INTERVAL_SEC = 30` |
| API 取得の間隔 / バックオフ | `$OK_INTERVAL_SEC = 300` / `$BACKOFF_SEC = 900` |

---

## ライセンス

[MIT](LICENSE) — 著作権表示は [fourn9/claude-usage-widget](https://github.com/fourn9/claude-usage-widget) の LICENSE に従います。
