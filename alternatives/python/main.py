"""エントリポイント。

OBS で YouTube 配信を開始した瞬間に、配信タイトルと配信URLを埋め込んだ
X (旧Twitter) の投稿作成画面 (Web Intent) を既定ブラウザで開く。
"""
from __future__ import annotations

import json
import logging
import sys
import threading
from pathlib import Path

from live_tweet import intent, obs_watcher, youtube
from live_tweet.config import Config, load_config_or_exit

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.json"
STATE_PATH = BASE_DIR / "state.json"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("live_tweet.main")

# 複数スレッドから state.json / 二重起動チェックを行うためのロック
_process_lock = threading.Lock()


def _load_last_video_id() -> str | None:
    if not STATE_PATH.exists():
        return None
    try:
        data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return data.get("last_video_id")
    except (json.JSONDecodeError, OSError) as e:
        logger.warning("state.json の読み込みに失敗しました: %s", e)
        return None


def _save_last_video_id(video_id: str) -> None:
    try:
        STATE_PATH.write_text(
            json.dumps({"last_video_id": video_id}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    except OSError as e:
        logger.warning("state.json の保存に失敗しました: %s", e)


def _build_tweet_text(template: str, title: str, url: str, include_url: bool) -> str:
    return template.format(title=title, url=url if include_url else "")


def _handle_stream_started(config: Config) -> None:
    """配信開始イベントを受けて実行する処理本体(別スレッドで呼ばれる)。"""
    if not _process_lock.acquire(blocking=False):
        logger.info("既に処理中のため、今回のイベントは無視します。")
        return
    try:
        logger.info("ライブ情報の取得を開始します...")
        info = youtube.wait_for_live(
            config.channel_live_url,
            config.resolve.retry_interval_sec,
            config.resolve.timeout_sec,
        )

        if info is not None:
            last_video_id = _load_last_video_id()
            if info.video_id == last_video_id:
                logger.info(
                    "video_id=%s は既に処理済みのため何もしません(同じ配信の再開)。",
                    info.video_id,
                )
                return

            text = _build_tweet_text(
                config.tweet.text, info.title, info.url, config.tweet.include_url
            )
            url = info.url if config.tweet.include_url else None
            intent_url = intent.build_intent_url(text, url)
            intent.open_in_browser(intent_url)
            _save_last_video_id(info.video_id)
            return

        # timeout までに取得できなかった場合
        if config.fallback_open_when_unresolved:
            logger.warning(
                "ライブ情報を取得できなかったため fallback で投稿画面を開きます。"
            )
            text = _build_tweet_text(
                config.tweet.text, "", config.channel_live_url, config.tweet.include_url
            )
            url = config.channel_live_url if config.tweet.include_url else None
            intent_url = intent.build_intent_url(text, url)
            intent.open_in_browser(intent_url)
        else:
            logger.warning(
                "ライブ情報を取得できませんでした。fallback_open_when_unresolved が "
                "false のため何もしません。"
            )
    finally:
        _process_lock.release()


def _on_stream_started_threaded(config: Config) -> None:
    """イベントハンドラ内で長時間ブロックしないよう別スレッドで処理する。"""
    threading.Thread(
        target=_handle_stream_started, args=(config,), daemon=True
    ).start()


def run_test_mode(config: Config) -> None:
    logger.info("--test モード: OBS には接続せず、今すぐライブ情報の取得を試みます。")
    _handle_stream_started(config)


def run_normal_mode(config: Config) -> None:
    logger.info("OBS の監視を開始します。Ctrl+C で終了します。")
    try:
        obs_watcher.watch(
            host=config.obs.host,
            port=config.obs.port,
            password=config.obs.password,
            on_stream_started=lambda: _on_stream_started_threaded(config),
        )
    except KeyboardInterrupt:
        logger.info("終了します。")


def main() -> None:
    config = load_config_or_exit(CONFIG_PATH)

    if "--test" in sys.argv[1:]:
        run_test_mode(config)
    else:
        run_normal_mode(config)


if __name__ == "__main__":
    main()
