"""現在配信中の動画(ID, タイトル)の取得。YouTube Data API は使わない。"""
from __future__ import annotations

import html
import json
import logging
import re
import time
from dataclasses import dataclass

import requests

logger = logging.getLogger(__name__)

_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

_HEADERS = {
    "User-Agent": _USER_AGENT,
    "Accept-Language": "ja,en;q=0.8",
}

_COOKIES = {"CONSENT": "YES+cb"}

_CANONICAL_RE = re.compile(
    r'<link\s+rel="canonical"\s+href="https://www\.youtube\.com/watch\?v=([\w-]+)"'
)
_TITLE_RE = re.compile(r'<meta\s+name="title"\s+content="([^"]*)"')
_IS_LIVE_RE = re.compile(r'"isLive"\s*:\s*true')
_PLAYER_RESPONSE_MARKER = "ytInitialPlayerResponse = "
_VIDEO_DETAILS_MARKER = '"videoDetails"'
_IS_LIVE_FALLBACK_WINDOW = 2000


@dataclass
class LiveInfo:
    video_id: str
    title: str
    url: str


def _extract_balanced_json(text: str, start: int) -> str | None:
    """text[start] が '{' であることを前提に、対応する '}' までを切り出す。"""
    if start >= len(text) or text[start] != "{":
        return None

    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue

        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return None


class _PlayerResponseNotExtractable(Exception):
    """ytInitialPlayerResponse の JSON 切り出し/解析に失敗した(=正規表現フォールバックに進むべき)。"""


def _resolve_via_player_response(html_text: str) -> LiveInfo | None:
    """ytInitialPlayerResponse の JSON を切り出して解析する。

    JSON の切り出し/解析自体に失敗した場合は _PlayerResponseNotExtractable を投げる
    (呼び出し側が正規表現フォールバックに切り替える)。
    JSON は解析できたが配信中でないと判定できた場合は None を返す(フォールバックしない)。
    """
    marker_pos = html_text.find(_PLAYER_RESPONSE_MARKER)
    if marker_pos == -1:
        raise _PlayerResponseNotExtractable("ytInitialPlayerResponse マーカーが見つかりません")

    json_start = marker_pos + len(_PLAYER_RESPONSE_MARKER)
    json_text = _extract_balanced_json(html_text, json_start)
    if json_text is None:
        raise _PlayerResponseNotExtractable("JSON の切り出しに失敗しました")

    try:
        player_response = json.loads(json_text)
    except json.JSONDecodeError as e:
        raise _PlayerResponseNotExtractable(f"JSON の解析に失敗しました: {e}") from e

    video_details = player_response.get("videoDetails")
    if not isinstance(video_details, dict):
        logger.info("videoDetails が見つかりませんでした (配信中ではない)")
        return None

    if not video_details.get("isLive"):
        logger.info("videoDetails.isLive が true ではありません (配信中ではない)")
        return None

    video_id = video_details.get("videoId")
    if not video_id:
        return None

    title = html.unescape(video_details.get("title", ""))
    url = f"https://www.youtube.com/watch?v={video_id}"
    logger.info("配信を検出しました: video_id=%s title=%r", video_id, title)
    return LiveInfo(video_id=video_id, title=title, url=url)


def _resolve_via_regex_fallback(html_text: str) -> LiveInfo | None:
    canonical_match = _CANONICAL_RE.search(html_text)
    if not canonical_match:
        logger.info("canonical の watch URL が見つかりませんでした (配信中ではない可能性)")
        return None

    # isLive:true の判定は videoDetails 直後の範囲に限定する。
    video_details_pos = html_text.find(_VIDEO_DETAILS_MARKER)
    if video_details_pos == -1:
        logger.info("videoDetails が見つかりませんでした (配信中ではない可能性)")
        return None

    window = html_text[video_details_pos : video_details_pos + _IS_LIVE_FALLBACK_WINDOW]
    if not _IS_LIVE_RE.search(window):
        logger.info("isLive:true が見つかりませんでした (配信中ではない)")
        return None

    video_id = canonical_match.group(1)

    title_match = _TITLE_RE.search(html_text)
    title = html.unescape(title_match.group(1)) if title_match else ""

    url = f"https://www.youtube.com/watch?v={video_id}"
    logger.info("配信を検出しました (fallback): video_id=%s title=%r", video_id, title)
    return LiveInfo(video_id=video_id, title=title, url=url)


def resolve_live(channel_live_url: str) -> LiveInfo | None:
    """チャンネルの /live URL を取得し、配信中であれば LiveInfo を返す。

    配信中でない場合や取得に失敗した場合は None を返す(例外は投げない)。
    """
    try:
        resp = requests.get(
            channel_live_url,
            headers=_HEADERS,
            cookies=_COOKIES,
            timeout=15,
        )
        resp.raise_for_status()
        html_text = resp.text
    except requests.RequestException as e:
        logger.warning("YouTube /live の取得に失敗しました: %s", e)
        return None

    try:
        return _resolve_via_player_response(html_text)
    except _PlayerResponseNotExtractable as e:
        logger.info("ytInitialPlayerResponse を利用できないため正規表現フォールバックを使います: %s", e)
        return _resolve_via_regex_fallback(html_text)


def wait_for_live(
    channel_live_url: str,
    retry_interval_sec: int,
    timeout_sec: int,
) -> LiveInfo | None:
    """resolve_live を retry_interval_sec 間隔で timeout_sec まで繰り返す。"""
    deadline = time.monotonic() + timeout_sec
    while True:
        info = resolve_live(channel_live_url)
        if info is not None:
            return info

        if time.monotonic() >= deadline:
            logger.warning("timeout_sec (%s秒) 以内にライブ情報を取得できませんでした", timeout_sec)
            return None

        time.sleep(retry_interval_sec)
