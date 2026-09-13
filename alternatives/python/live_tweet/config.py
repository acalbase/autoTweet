"""config.json の読み込みと検証。"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path


class ConfigError(Exception):
    """config.json の内容が不正な場合に投げる例外。"""


@dataclass
class ObsConfig:
    host: str
    port: int
    password: str


@dataclass
class TweetConfig:
    text: str
    include_url: bool


@dataclass
class ResolveConfig:
    retry_interval_sec: int
    timeout_sec: int


@dataclass
class Config:
    obs: ObsConfig
    channel_live_url: str
    tweet: TweetConfig
    resolve: ResolveConfig
    fallback_open_when_unresolved: bool


def _build_channel_live_url(channel: str) -> str:
    channel = channel.strip()
    if channel.startswith("@"):
        return f"https://www.youtube.com/{channel}/live"
    if channel.startswith("UC"):
        return f"https://www.youtube.com/channel/{channel}/live"
    raise ConfigError(
        f"youtube.channel の形式が不正です: {channel!r} "
        "(@handle 形式または UC... のチャンネルID形式を指定してください)"
    )


def _validate_tweet_text(text: str) -> None:
    try:
        text.format(title="t", url="u")
    except (KeyError, IndexError, ValueError) as e:
        raise ConfigError(
            "tweet.text のプレースホルダは {title} {url} のみ使用できます。"
            "{ } を文字として使う場合は {{ }} と書いてください。"
            f" (詳細: {e})"
        ) from e


def load_config(path: str | Path) -> Config:
    path = Path(path)
    if not path.exists():
        raise ConfigError(
            f"{path} が見つかりません。config.example.json をコピーして config.json を作成してください。"
        )

    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise ConfigError(f"{path} の JSON 解析に失敗しました: {e}") from e

    try:
        obs_raw = raw["obs"]
        if not isinstance(obs_raw, dict):
            raise ConfigError("obs は object で指定してください。")
        obs = ObsConfig(
            host=obs_raw.get("host", "localhost"),
            port=int(obs_raw.get("port", 4455)),
            password=obs_raw.get("password", ""),
        )

        channel = raw["youtube"]["channel"]
        channel_live_url = _build_channel_live_url(channel)

        tweet_raw = raw.get("tweet", {})
        if not isinstance(tweet_raw, dict):
            raise ConfigError("tweet は object で指定してください。")

        text = tweet_raw.get("text", "{title}")
        _validate_tweet_text(text)

        include_url = tweet_raw.get("include_url", True)
        if not isinstance(include_url, bool):
            raise ConfigError("tweet.include_url は true/false で指定してください。")

        tweet = TweetConfig(text=text, include_url=include_url)

        resolve_raw = raw.get("resolve", {})
        if not isinstance(resolve_raw, dict):
            raise ConfigError("resolve は object で指定してください。")

        retry_interval_sec = int(resolve_raw.get("retry_interval_sec", 5))
        if retry_interval_sec < 1:
            raise ConfigError("resolve.retry_interval_sec は 1 以上の整数で指定してください。")

        timeout_sec = int(resolve_raw.get("timeout_sec", 120))
        if timeout_sec < 1:
            raise ConfigError("resolve.timeout_sec は 1 以上の整数で指定してください。")

        resolve = ResolveConfig(
            retry_interval_sec=retry_interval_sec,
            timeout_sec=timeout_sec,
        )

        fallback_open_when_unresolved = raw.get("fallback_open_when_unresolved", True)
        if not isinstance(fallback_open_when_unresolved, bool):
            raise ConfigError("fallback_open_when_unresolved は true/false で指定してください。")
    except ConfigError:
        raise
    except KeyError as e:
        raise ConfigError(f"config.json に必須項目 {e} がありません。") from e
    except (TypeError, ValueError, AttributeError) as e:
        raise ConfigError(f"config.json の内容が不正です: {e}") from e

    return Config(
        obs=obs,
        channel_live_url=channel_live_url,
        tweet=tweet,
        resolve=resolve,
        fallback_open_when_unresolved=fallback_open_when_unresolved,
    )


def load_config_or_exit(path: str | Path) -> Config:
    """CLI 用: 読み込みに失敗したらメッセージを表示して終了する。"""
    try:
        return load_config(path)
    except ConfigError as e:
        print(f"[エラー] {e}", file=sys.stderr)
        sys.exit(1)
