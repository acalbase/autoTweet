# youtube-live-tweet

OBS で配信開始を押すと、配信タイトルと URL 入りの X (旧Twitter) 投稿画面が自動で開く OBS スクリプトです。投稿(ツイート)は自分で押します。

## 特徴

- インストール不要 — OBS のスクリプト機能だけで動く単一ファイル
- 設定ファイル不要
- X API・YouTube API 不要(登録・課金なし)
- 最後のポストは自分で押すので誤投稿しない

## 使い方

1. [Releases](../../releases) から zip をダウンロードして展開する
2. OBS の「ツール」→「スクリプト」→「＋」で `youtube_live_tweet.lua` を選ぶ
3. 「YouTube チャンネルの URL」を入力する

詳しい手順・画面例は [`docs/manual.html`](docs/manual.html) を参照してください。

## 設定項目

| 項目 | 説明 |
| --- | --- |
| YouTube チャンネルの URL | 監視対象チャンネルの URL(`https://www.youtube.com/@handle` など)、または `@handle` / `UC...` のチャンネルID形式 |
| 投稿文(`{title}` `{url}`) | 投稿文のテンプレート。`{title}`(配信タイトル)、`{url}`(配信URL)のプレースホルダが使える |
| 配信 URL を付ける | Web Intent の `url` パラメータに配信URLを付けるかどうか |
| 取得の間隔(秒) | YouTube 側の反映待ちのリトライ間隔 |
| 最大待ち時間(秒) | リトライを諦めるまでの時間 |
| 取得できなくても開く | タイムアウトしてもライブ情報が取得できなかった場合に、タイトル空・チャンネルの `/live` URL で投稿画面を開くかどうか |
| テストボタン | OBS を配信状態にせずに、今すぐ投稿画面を開いて動作確認できる |
| 状態 | 現在の取得状況を表示する読み取り専用の表示欄 |

## 動作環境

- Windows 10 / 11
- OBS Studio 28 以上
- `curl.exe`(Windows 標準搭載のため追加インストール不要)

macOS / Linux は未対応です。

## 仕組み

1. OBS の配信開始イベントを検知する
2. `curl.exe` でチャンネルの `/live` ページを取得し、タイトルと動画 URL を抜き出す
3. X の投稿作成画面(Web Intent)を既定ブラウザで開く

## 困ったときは

まず OBS の「ツール」→「スクリプト」画面下部の「スクリプトログ」ボタンでログを確認してください。

解決しない場合は [Issues](../../issues) に、以下を添えて報告してください。

- OBS のバージョン
- スクリプトログの内容
- チャンネル URL の形式(`@handle` / `UC...` など)

## 開発者向け

- テスト: `pip install lupa` の後、`python lua/tests/test_logic.py`
- 配布 zip 作成: `scripts/make-release.ps1`
- `alternatives/` は OBS Lua 版の前に作った参考実装(メンテナンス対象外)

## ライセンス

MIT License(詳細は [`LICENSE`](LICENSE) を参照)
