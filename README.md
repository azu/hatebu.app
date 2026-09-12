# Hatebu Search

公開はてなブックマークを Mac に保存して、アプリと Alfred から素早く検索する。
見つからないときは、アプリ内で Codex と会話しながら探し直せる。

## インストール

macOS 14 以降。Apple Silicon / Intel 共通。
次をターミナルへ貼り付けると、`~/Applications` にインストールして起動する。更新時は先にアプリを終了する。

```sh
curl -fL https://github.com/azu/hatebu.app/releases/latest/download/HatebuSearch-universal.zip -o /tmp/HatebuSearch.zip &&
ditto -x -k /tmp/HatebuSearch.zip "$HOME/Applications" &&
xattr -dr com.apple.quarantine "$HOME/Applications/HatebuSearch.app" &&
open "$HOME/Applications/HatebuSearch.app"
```

設定からはてなユーザー名を追加すると、公開ブックマークの取り込みが始まる。
Alfred を使う場合は、設定の「Alfred Workflow を開く」から追加する（Powerpack が必要）。
[起動できない場合・更新の補足](docs/troubleshooting.md)

## 使い方

**アプリ**：検索欄に入力すると結果が変わる。各行の「開く」で記事を開く。↓ で先頭を選び、↑↓ で移動、Enter でも開ける。
⌘F で検索欄へ移動、⌘R で更新、⌥⌘S でサイドバーを開閉する。

**Alfred**：`hb 検索語` で検索し、Enter で開く。⌘Enter で検索語と候補をアプリへ渡す。
アプリを閉じていても、同じ保存済みデータを検索できる。

**Codex**：普段の Codex CLI で `codex login` を済ませ、アプリ右側に覚えている内容を入力して ⌘Enter で送信する。
「去年読んだ日本語の解説」「この候補に近い記事」などの条件で探し直せる。途中の検索や候補を確認しながら、停止・条件追加もできる。

| 検索例 | 意味 |
| --- | --- |
| `JavaScript テスト` | 両方の語を含むタイトル・URL・コメント・タグ |
| `"静的解析"` | フレーズ検索 |
| `tag:設計` | タグで絞り込む |
| `site:github.com` | ドメインとそのサブドメインで絞り込む |
| `after:2025-01-01 before:2026-01-01` | 登録日で絞り込む。開始を含み、終了を含まない。日付境界は UTC |

保存済みの結果を先に表示し、古いデータは裏で更新する。一致した語はハイライトする。

## CLI

アプリに同梱した CLI を、次のように使える。

```sh
hatebu() { "$HOME/Applications/HatebuSearch.app/Contents/MacOS/hatebu" "$@"; }

hatebu search '日本語 検索' --format json
hatebu search 'tag:設計' --format text
hatebu status
```

| コマンド | 動作 |
| --- | --- |
| `hatebu source add USER` | はてなユーザーを登録 |
| `hatebu sync` | 公開ブックマークを更新 |
| `hatebu sync --if-stale` | 前回成功から 15 分以上経過していれば更新 |
| `hatebu sync --full` | 全件を照合し、過去の編集・削除も反映 |
| `hatebu search QUERY --limit 40 --user USER` | 件数とユーザーを指定して検索 |
| `hatebu show ID --format json` | ブックマークの詳細を取得 |
| `hatebu alfred --limit 40 -- QUERY` | Alfred 用 JSON を返し、必要なら別プロセスで更新 |

`search` と `show` は読み取り専用。
保存先は `~/Library/Application Support/HatebuSearch/`。`--data-dir PATH` または `HATEBU_DATA_DIR` で変更できる。

[要件](docs/requirements.md) · [設計](docs/design.md) · [開発・公開](docs/development.md) · [動作確認](docs/verification.md)
