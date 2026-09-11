# インストールと更新の補足

## 初回起動を止められた場合

README のインストールコマンドは、ダウンロードしたアプリと同梱 CLI・Workflow の隔離属性を `xattr` で取り除く。
別の方法で配置した場合は、ダウンロード元を確認してから、実際のアプリのパスを指定する。

```sh
xattr -dr com.apple.quarantine "$HOME/Applications/HatebuSearch.app"
```

現在の配布は ad-hoc 署名を使っている。
macOS のシステム設定 → プライバシーとセキュリティ →「このまま開く」からも起動を許可できる。
[Apple の案内](https://support.apple.com/ja-jp/102445)

## アプリと Workflow の更新

アプリを終了してから、README のインストールコマンドをもう一度実行する。
Alfred Workflow もアプリの設定から再インポートする。
ブックマークと会話はアプリの外に保存されるため、アプリを置き換えても残る。

定期更新は登録時のアプリの場所を使う。
アプリを別の場所に移した場合は、設定で定期更新を一度無効にしてから有効にする。

## 配布ファイルを照合する

同じ Release の `HatebuSearch-universal.zip`、`HatebuSearch.alfredworkflow`、`SHA256SUMS` を同じフォルダーに置いて実行する。

```sh
shasum -a 256 -c SHA256SUMS
```
