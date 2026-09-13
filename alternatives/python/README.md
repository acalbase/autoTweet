# youtube-live-tweet (Python 版)

OBS で YouTube 配信を開始した瞬間に、配信タイトルと配信URLを埋め込んだ
X (旧Twitter) の投稿作成画面 (Web Intent) を既定ブラウザで自動的に開くツールです。
最後の「ポストする」ボタンは人が押します。X API・YouTube Data API は使いません
(どちらも登録不要な方式です)。

> 通常はインストール不要な PowerShell 版(`../powershell/`)を推奨します。
> こちらは Python 版で、参考実装として残しています。

## 動作の流れ

1. `main.py` を常駐実行しておくと、OBS WebSocket 経由で配信状態を監視します。
2. OBS で配信を開始すると `StreamStateChanged` イベントを検知します。
3. YouTube の対象チャンネルの `/live` ページを取得し、配信中になったタイミングで
   動画ID・タイトルを取得します(数十秒かかることがあるため、一定間隔でリトライします)。
4. 取得できたら、投稿文にタイトル・URLを埋め込んだ X の投稿作成画面を既定ブラウザで開きます。
   内容を確認して、手動で「ポストする」を押してください。
5. 同じ配信を検知して二重に投稿画面を開かないよう、最後に処理した動画IDを
   `state.json` に保存します。

## 前提条件

- Python 3.12 以上がインストールされていること(`python` コマンドで実行できること)。
- Windows 11。

## OBS 側の設定

1. OBS のメニューから「ツール」→「WebSocket サーバー設定」を開く。
2. 「WebSocket サーバーを有効にする」にチェックを入れる。
3. ポート番号を確認する(デフォルト `4455`)。設定を変えていなければそのままで OK。
4. パスワードを設定した場合は、そのパスワードを `config.json` の `obs.password` に記入する。
   パスワードを設定していない場合は空文字 `""` のままで構いません。

## config.json の書き方

`config.example.json` をコピーして `config.json` を作成し、内容を編集してください。

```json
{
  "obs": { "host": "localhost", "port": 4455, "password": "" },
  "youtube": { "channel": "@your_handle" },
  "tweet": {
    "text": "配信はじめました！\n{title}",
    "include_url": true
  },
  "resolve": { "retry_interval_sec": 5, "timeout_sec": 120 },
  "fallback_open_when_unresolved": true
}
```

| 項目 | 説明 |
| --- | --- |
| `obs.host` / `obs.port` | OBS WebSocket サーバーのホスト・ポート。通常は変更不要。 |
| `obs.password` | OBS WebSocket サーバーのパスワード。設定していなければ空文字。 |
| `youtube.channel` | 監視対象チャンネル。`@handle` 形式、または `UC...` のチャンネルID形式のいずれかを指定。 |
| `tweet.text` | 投稿文のテンプレート。`{title}`(配信タイトル)、`{url}`(配信URL)のプレースホルダが使えます。 |
| `tweet.include_url` | `true` の場合、Web Intent の `url` パラメータに配信URLを渡します(text 内の `{url}` にも展開されます)。 |
| `resolve.retry_interval_sec` | YouTube 側の反映待ちのリトライ間隔(秒)。 |
| `resolve.timeout_sec` | リトライを諦めるまでの時間(秒)。 |
| `fallback_open_when_unresolved` | タイムアウトしてもライブ情報が取得できなかった場合に、タイトル空・チャンネルの `/live` URL で投稿画面を開くかどうか。 |

## インストール

```bat
pip install -r requirements.txt
```

## 動作確認 (`--test`)

OBS を起動せずに、YouTube 取得〜投稿画面表示までを1回だけ試せます。
**実際に配信中のときに実行**すると、投稿画面が開きます。

```bat
python main.py --test
```

## 通常起動

```bat
run.bat
```

OBS の起動前後どちらで実行しても構いません(OBS が起動していない間は
10秒おきに再接続を試み続けます)。Ctrl+C で終了します。

## Windows 起動時に自動実行する

1. `Win + R` を押し、`shell:startup` と入力して Enter。スタートアップフォルダが開きます。
2. `run.bat` のショートカットを作成し、そのフォルダに配置する。

これで Windows ログイン時に自動的に監視が始まります。

## 制限事項

- 最後の投稿ボタンは手動です(自動投稿はしません)。
- ブラウザで X (Twitter) にログインしている必要があります。
- YouTube のページ構造が変わると取得に失敗する可能性があります。その場合は
  `fallback_open_when_unresolved` が `true` であれば、タイトル空・チャンネルの
  `/live` URL で投稿画面が開くので、手動で内容を修正してください。
