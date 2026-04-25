# GdriBrain

Google Drive をストレージとした自作 Obsidian 系メモアプリ。**iOS アプリ単体**で
動作し、サーバ・Mac・Tailscale 等は一切不要。Anthropic API と Google Drive
だけを直接叩きます。

```
[iPhone]
 ├─ SwiftUI App ─┬─▶ Anthropic API (Haiku/Sonnet/Opus)
 │               └─▶ Google Drive API (drive.file)
 ├─ Share Extension (URL/画像/テキスト + VisionKit OCR)
 └─ ローカル SwiftData 索引 (Drive のキャッシュ)

                                 ▼
                         GdriBrain/notes/*.md
                         GdriBrain/attachments/*
```

| 構成要素 | 役割 |
|---|---|
| iOS App | 入力 / グラフ / 設定 / 取り込みパイプラインの全部 |
| Share Extension | URL/画像/テキストを受けて VisionKit OCR + キュー投入 |
| Anthropic API | 要約 / マージ判定 / 関連抽出 (3-tier: Haiku → Sonnet → Opus) |
| Google Drive | 真の源 (md ファイル) |
| SwiftData | iPhone ローカルの索引 (高速検索用キャッシュ) |

## モデル戦略

| Tier | モデル | 自動/手動 | 用途 |
|---|---|---|---|
| Cheap | `claude-haiku-4-5` | 自動 | タイトル / 要約 / キーワード抽出 |
| Default | `claude-sonnet-4-6` | 自動 | マージ判定、関連抽出、クラスタ要約 |
| Premium | `claude-opus-4-7` | 手動 | Notes タブのトグルで明示的に選択時のみ |

ノート1本あたりおおよそ **$0.005〜0.01** (月100本で $0.5〜1)。

## クイックスタート (3 ステップ)

### 事前準備 (一度だけ手動)

#### A. Google Cloud で OAuth クライアントを作る

1. <https://console.cloud.google.com/projectcreate> でプロジェクト作成
   (Project name: `GdriBrain` 等)
2. **APIs & Services → Library** で `Google Drive API` を検索 → **ENABLE**
3. **OAuth consent screen**:
   - User Type: **External** → CREATE
   - App name / メールを記入
   - Scopes: `ADD OR REMOVE SCOPES` → `drive.file` を検索 → 追加 → UPDATE → SAVE
   - Test users: 自分の Google アカウントを追加
   - Dashboard で **PUBLISH APP** (Production に昇格 / refresh token が
     7日で失効しなくなる。`drive.file` は非機密スコープなので即承認)
4. **Credentials → Create Credentials → OAuth client ID**:
   - Application type: **iOS**
   - Bundle ID: `com.ykitaguchi.gdribrain`
   - 表示された **Client ID** (`xxxxx.apps.googleusercontent.com`) をコピー

#### B. Anthropic API キーを発行

1. <https://console.anthropic.com/settings/keys> で API キー発行
   (`sk-ant-…` で始まる文字列)
2. アプリ専用ワークスペースを切り、そこ専用キーにすると影響範囲を最小化
   できます (任意)

### STEP 1. xcconfig に Google Client ID を入れる

```sh
cd ios
cp Config/GdriBrain.xcconfig.example Config/GdriBrain.xcconfig
# エディタで Config/GdriBrain.xcconfig を開いて Client ID を貼り付け
```

### STEP 2. Xcode で iPhone にビルド

```sh
brew install xcodegen   # 初回のみ
xcodegen generate
open GdriBrain.xcodeproj
```

Xcode で:

1. ターゲット `GdriBrain` の **Signing & Capabilities → Team** を自分の
   Developer Team に設定
2. ターゲット `ShareExtension` でも同じ Team を設定
3. iPhone を USB 接続して ▶︎

### STEP 3. iPhone で初期設定

1. 起動して **Settings タブ** を開く
2. **Anthropic API key** に `sk-ant-…` を貼り付け → **Save API key**
3. **Sign in with Google** をタップ → 認可 → 自動的にアプリに戻る
4. Settings の Status が両方 ✓ になれば完了

## 使い方

- **Memo タブ**: 短文入力 → Save → Drive に YAML 付き md
- **Safari** で記事を開く → 共有 → GdriBrain → link 種別の md
- **スクショ撮影** → 共有 → GdriBrain → OCR テキスト + 画像が attachments/ に
- **Notes タブ**: 一覧 + 複数選択 → 右上のメニューから **Summarise selected**
  - "Use Opus 4.7 (premium)" トグルで深い分析モード
- **Graph タブ**: ノード関係の可視化 (Cytoscape.js)

似た内容を投稿すると Sonnet が「既存ノートに統合するか」自動判定します。

## セキュリティ

| レイヤ | 対策 |
|---|---|
| API キー保存 | iOS Keychain (`AccessibleWhenUnlockedThisDeviceOnly`) |
| iCloud バックアップ | 含まれない (上記アクセシビリティで除外) |
| App Group 共有 | API キーは **共有しない** (Share Extension からは到達不能) |
| 入力 UI | `SecureField` でマスク入力 |
| 表示 | 部分マスク (`sk-ant-•••••••••a3f`) |
| 通信 | URLSession の TLS 1.2+ (デフォルト) |
| ログ | API キーを含むダンプは出さない |

**漏洩時の対応**: <https://console.anthropic.com/settings/keys> で当該キーを
即 revoke + 新規発行 → アプリの Settings タブで貼り直し。被害は Anthropic
クレジット消費だけ (Drive は別途 Google 認証が必要)。

## トラブルシュート

| 症状 | 対処 |
|---|---|
| Memo Save で `not set` のエラー | Settings で API キーを保存したか確認 |
| `not authorised` | Settings で "Sign in with Google" をやり直す |
| `redirect_uri_mismatch` | Google Cloud の OAuth client Bundle ID が `com.ykitaguchi.gdribrain` か |
| Refresh token が 7 日で切れる | OAuth consent screen で **PUBLISH APP** したか |
| `429` / Rate limit | 短時間に大量投稿した直後に出る。少し待つ |
| Notes タブが空 | 索引 (SwiftData) は Drive のキャッシュ — まだ何も投稿していなければ空 |
| Graph に古いエッジが残る | アプリ再起動で再計算 (関連エッジは on-the-fly) |

## ディレクトリ構成

```
GdriBrain/
├── README.md
├── ios/
│   ├── project.yml                          ← XcodeGen 定義
│   ├── Config/
│   │   └── GdriBrain.xcconfig.example       ← 実体は手動コピー (gitignore)
│   ├── GdriBrain/
│   │   ├── App/                             ← App / AppState / RootView
│   │   ├── Auth/                            ← Keychain + GoogleOAuth
│   │   ├── Networking/                      ← AnthropicClient + DriveAPI + Queue
│   │   ├── Models/                          ← Draft 等
│   │   ├── Pipeline/                        ← NotesPipeline + Tokenize + Markdown + Graph
│   │   ├── Storage/                         ← SwiftData (LocalIndex)
│   │   └── Features/                        ← Memo / Notes / Graph / Settings
│   └── ShareExtension/                      ← Share Sheet 拡張 + VisionKit OCR
└── docs/
    └── architecture.md                      ← 設計判断の背景
```

## 設計判断のポイント

- **iOS 単体で完結**: Mac / Tailscale / バックエンドゼロ。常時起動する物理機が
  存在しないので運用が劇的に楽
- **Drive がフラット**: `notes/` と `attachments/` だけ。サブカテゴリ階層は
  分類軸が変わったときに必ず破綻するので避ける (詳細 `docs/architecture.md`)
- **3-tier モデル戦略**: 量の出る要約は Haiku、判断系は Sonnet、明示要求時のみ
  Opus。コストとレイテンシをデフォルトで小さく保つ
- **マージ判定は Jaccard で候補を絞ってから Sonnet**: 全ノートを毎回 LLM に
  渡すのは線形に高くなる。トークン重複で粗く絞る
- **API キーは Share Extension に渡さない**: Share Extension はキューに積む
  だけ。攻撃面を最小化
- **SwiftData**: iOS 17+ ネイティブ、依存ゼロ、SwiftUI と相性が良い

詳細は `docs/architecture.md` を参照。
