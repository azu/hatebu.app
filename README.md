# Hatebu Search

公開はてなブックマークを Mac に保存し、ネイティブアプリと Alfred から素早く検索する。
見つからないときは、アプリ内で Codex と会話しながら探し直せる。
検索・更新・保存は Swift の共通ライブラリと CLI を使い、同じキャッシュを共有する。
目的・対象範囲・確認条件は [要件](docs/requirements.md)、構成と処理は [設計](docs/design.md)、実測値と未確認の範囲は [動作確認の記録](docs/verification.md)にまとめている。

## インストール

macOS 14 以降に対応する。配布 ZIP は Apple Silicon / Intel 共通。
通常検索には Codex や開発用ツールは不要。Alfred Workflow の利用には Alfred Powerpack が必要。

公開済みのバージョンを使う場合は、このリポジトリの GitHub Releases の Assets から
`HatebuSearch-<バージョン>-universal.zip`、`HatebuSearch.alfredworkflow`、`SHA256SUMS` を同じフォルダーにダウンロードする。
初回公開までは、下の「ソースからビルドする」を使う。
ダウンロードしたフォルダーで次を実行すると、ファイルが配布時と一致するかを確認できる。

```sh
shasum -a 256 -c SHA256SUMS
```

1. ZIP を展開し、`HatebuSearch.app` を Applications フォルダーへ移動する。
2. アプリを開き、設定からはてなユーザー名を追加する。公開ブックマークの取り込みが始まる。
3. アプリの設定で「Alfred Workflow を開く」を押すか、ダウンロードした `HatebuSearch.alfredworkflow` を開いて Alfred に追加する。

定期更新は登録時のアプリの場所を使うため、移動したら設定で一度無効にしてから有効にする。
更新時はアプリを終了して同じ場所へ置き換え、Workflow も再インポートする。
ブックマークと会話はアプリの外に保存するため、アプリの置き換えでは消えない。

### 初回起動を macOS に止められた場合

現在の配布はローカル実行用の ad-hoc 署名だけで、Developer ID 署名・Apple の公証を付けていない。
ダウンロード元を確認したうえで、まず一度起動し、システム設定 → プライバシーとセキュリティ →「このまま開く」を使う。
[Apple の案内](https://support.apple.com/ja-jp/102445)

それでもダウンロードしたアプリの隔離属性が原因で開けない場合は、対象のアプリだけからその属性を取り除く。
次のパスは Applications に配置した場合のもの。別の場所なら実際のパスに置き換える。

```sh
xattr -dr com.apple.quarantine "/Applications/HatebuSearch.app"
```

このコマンドはアプリ内の同梱 CLI と Workflow も対象にする。実行後、アプリを開き直す。
Alfred へすでに追加した Workflow 内の CLI が同じ理由で止められる場合は、この操作の後にアプリの設定から Workflow を再インポートする。
属性がない場合はこの操作は不要。「No such xattr」と表示された場合も属性がない状態なので、繰り返す必要はない。

### ソースからビルドする

Swift 5.9 以降、Xcode Command Line Tools、Python 3 が必要。

```sh
bash scripts/build.sh
```

`dist/HatebuSearch.app` と `dist/HatebuSearch.alfredworkflow` ができる。上と同じ手順で配置する。
どちらの成果物にも同じ `hatebu` CLI が含まれる。通常のビルドは実行した Mac の CPU 向け。
Apple Silicon / Intel 共通の配布ファイルは、Xcode を選択した環境で次のように作る。

```sh
bash scripts/build.sh --universal
bash scripts/archive.sh
```

`dist/release/` にアプリ ZIP、Workflow、`SHA256SUMS` を生成する。

## 検索する

アプリは入力のたびに検索し、検索中も前の結果を残す。
古い検索が遅れて終わっても、新しい入力の結果を上書きしない。
キャッシュが古ければ結果を表示したまま裏で更新し、完了後に表示へ反映する。
更新に失敗した場合も前回のキャッシュを使える。

Alfred では `hb 検索語` を使う。Enter でページを開き、Command + Enter で候補と検索語をアプリへ渡す。
アプリを閉じていても検索とバックグラウンド更新が動く。
[Alfred Script Filter](https://www.alfredapp.com/help/workflows/inputs/script-filter/)

| 入力例 | 検索内容 |
| --- | --- |
| `JavaScript テスト` | 両方の語を含むタイトル・URL・コメント・タグ |
| `"静的解析"` | フレーズで検索 |
| `tag:設計` | タグが一致する記事 |
| `site:github.com` | 指定ドメインとそのサブドメイン |
| `after:2025-01-01 before:2026-01-01` | 登録日時による範囲指定。開始を含み、終了は含まない。日付境界は UTC |

全角英数字と英字の大小の違いを吸収し、1〜2 文字の日本語も検索できる。
通常検索はネットワークや AI の応答を待たない。
一致した語をタイトル・コメント・タグ・ドメイン内でハイライトする。
新しい検索結果と AI の最終候補は未選択で表示する。検索欄のまま ↓ で先頭を選び、続く ↑↓ で移動し、Enter で開く。
未選択の Enter では開かず、日本語変換中は変換操作を優先する。
Cmd+F で検索欄、Cmd+R で更新、Cmd+, で設定、Option+Cmd+S でサイドバーの開閉を行う。

## Codex と探し直す

普段使っている Codex CLI をインストールし、`codex login` 済みの状態でアプリの会話欄から送信する。
見つからなければ設定で Codex の実行ファイルを選ぶ。API キーの設定は不要。
入力した条件と公開ブックマークの候補を Codex へ渡し、Codex は同じ CLI で保存済みデータを追加検索する。
記事本文の取得や Web 全体の検索は行わない。

会話欄の上部に「検索中」「検索完了 · N 件」と経過時間を表示する。
「使ったツール」でツール名、検索語、件数、成否を確認し、詳細を開くと実行コマンドも読める。
途中の候補も開いたりコピーしたりできる。終了通知を受信できなかった操作は「結果未確認」と表示する。
停止・失敗しても、それまでの候補と会話は保存する。
実行中に条件を入力して「この条件で探し直す」を押すと、停止完了後に同じ会話で続きを送信する。
送信は Cmd+Enter。通常検索は会話の実行中も使える。

`codex exec --json` と会話 ID を指定した `codex exec resume` を使う。
ユーザー設定の追加 MCP は読み込まず、既存の認証保存先と `CODEX_HOME` は引き継ぐ。
アプリは認証情報を読み取ったり複製したりしない。
[Codex 非対話実行](https://learn.chatgpt.com/docs/non-interactive-mode)

## CLI

ビルド後の CLI はアプリの `Contents/MacOS/hatebu` にある。通常ビルドでは `.build/release/hatebu` からも使える。

```sh
hatebu source add YOUR_HATENA_ID
hatebu sync
hatebu search '日本語 検索' --format json
hatebu search 'tag:設計' --format text
hatebu show BOOKMARK_ID
hatebu status
hatebu sync --full
hatebu alfred --limit 40 -- '検索語'
```

`search` と `show` は読み取り専用。`alfred` は検索結果を即座に返し、必要なときに別プロセスで同期を始める。
`sync --if-stale` は 15 分以内に成功していれば取得を省略する。
設定の定期更新を有効にすると、macOS の LaunchAgent から 15 分ごとにこのコマンドを実行する。

既定のデータ保存先は `~/Library/Application Support/HatebuSearch/`。
CLI の `--data-dir PATH`、または環境変数 `HATEBU_DATA_DIR` で変更できる。
アプリも `--data-dir PATH` に対応する。
SQLite のデータと JSON の会話履歴をここへ保存し、別の取り込みキャッシュは作らない。

## 取得と制約

認証用 Cookie を付けずに、はてなの公開 `search.data` を取得する。
初回は続きのページも取得し、その後は前回取得開始時刻の 120 秒前から差分を取得する。
7 日ごと、または手動操作で全件を照合し、編集・削除を反映する。
通常の差分取得だけでは、過去のブックマークの編集・削除は即座に反映されない。
途中ページや保存処理の失敗時は、キャッシュと前回の取得位置を維持する。
古い特殊な URL も検索できるが、直接開く操作は HTTP / HTTPS の Web ページに限る。

この実装は `search.data` の現在の応答形式に依存するため、提供元の形式変更には対応が必要。
取得方法は [hatebupwa](https://github.com/azu/hatebupwa) と [search.data の形式説明](https://github.com/azu/hatebu-mydata-parser/blob/master/doc/search.data-format.md)を参考にしている。
非公開ブックマーク、asocial-bookmark、Claude 連携は対象に含めていない。

## 開発と確認

```sh
bash scripts/test.sh
bash scripts/build.sh
```

検索条件、日本語の部分一致、古い結果の抑止、同期中の検索、更新失敗時の復旧、ページ継続、Alfred JSON、Codex の途中イベント・停止・会話再開を検証する。
Codex のテストでは実際の子プロセスとパイプを使い、応答だけを疑似 CLI で再現する。
テストには実アカウントやネットワークへの依存を入れていない。

## CI と公開

[GitHub Actions の設定](.github/workflows/ci.yml)で、PR・`main` への push・手動実行時に
Apple Silicon / Intel のテストと共通バイナリのビルドを行う。
配布ファイルは `release-assets` という成果物として 14 日間保存する。

`VERSION` と同じ番号の `v` タグを GitHub に push すると、同じ検証を通したファイルを GitHub Releases へ公開する。
たとえば `VERSION` が `0.1.1` ならタグは `v0.1.1`。通常の push や手動実行では公開しない。
公開用の書き込み権限は最後のジョブだけに与え、テスト・ビルドには与えない。
公開先は、この Workflow を実行しているリポジトリになる。

公開前に `VERSION` を更新し、その変更を含めたコミットへタグを付ける。
次は公開を実行するためのコマンド例であり、タグの push が公開のきっかけになる。

```sh
git tag v0.1.1
git push origin v0.1.1
```

タグと `VERSION` が違えばビルドを止める。既存タグを勝手に作成・移動しないよう、
公開コマンドには [`gh release create --verify-tag`](https://cli.github.com/manual/gh_release_create) を使う。
すでに公開したバージョンは上書きせず、新しい番号で公開する。

AI の対話設計は、[Microsoft Design](https://microsoft.design/articles/ux-design-for-agents/) の実行状況と制御の可視化、[Google PAIR](https://pair.withgoogle.com/guidebook-v2/chapter/feedback-controls/) の操作中に条件を調整できる原則を参考にしている。
