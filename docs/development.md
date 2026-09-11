# 開発と公開

## ビルドとテスト

macOS 14 以降、Swift 5.9 以降、Xcode Command Line Tools、Python 3 を使う。

```sh
bash scripts/test.sh
bash scripts/build.sh
```

`dist/HatebuSearch.app` と `dist/HatebuSearch.alfredworkflow` を生成する。
通常のビルドは実行した Mac の CPU 向け。CLI は `.build/release/hatebu` からも使える。

Apple Silicon / Intel 共通の配布ファイルは、Xcode を選択した環境で作る。

```sh
bash scripts/build.sh --universal
bash scripts/archive.sh
```

`dist/release/` に `HatebuSearch-universal.zip`、`HatebuSearch.alfredworkflow`、`SHA256SUMS` ができる。
アプリと Workflow のバージョン、同梱 CLI の一致、両 CPU のバイナリ、署名、アーカイブを検査する。
ファイル名をバージョン間で固定し、README のダウンロード URL を変えずに更新できるようにする。
[GitHub の最新 Release へのリンク](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)

## 検証用データ

通常の保存先を変更せずに試す場合は、データ保存先を指定する。

```sh
.build/release/hatebu --data-dir .test-data source add YOUR_HATENA_ID
.build/release/hatebu --data-dir .test-data sync
.build/release/hatebu --data-dir .test-data search '日本語'
```

`.test-data/`、`.build/`、`dist/` は Git の対象から除外する。
テストは実アカウントやネットワークに依存せず、Codex 部分は疑似 CLI を実際の子プロセスとして実行する。
実測値と未確認事項は [動作確認の記録](verification.md) に残す。

## CI と Release

[GitHub Actions](../.github/workflows/ci.yml) は PR・`main` への push・手動実行で両 CPU のテストと共通ビルドを行い、配布ファイルを `release-assets` に 14 日間保存する。
`VERSION` と同じ番号の `v` タグを push した場合は、同じ検証を通して GitHub Releases へ公開する。
公開用の書き込み権限は最後のジョブだけに与える。

公開するバージョンを `VERSION` に記載し、その変更をコミットしてからタグを push する。

```sh
git tag v0.1.1
git push origin v0.1.1
```

タグと `VERSION` が違えばビルドを止める。
既存タグを自動作成・移動しないよう、公開には [`gh release create --verify-tag`](https://cli.github.com/manual/gh_release_create) を使う。
すでに公開したバージョンは上書きせず、新しい番号で公開する。
