"""X (Twitter) の Web Intent URL 生成とブラウザ起動。"""
from __future__ import annotations

import logging
import webbrowser
from urllib.parse import quote, urlencode

logger = logging.getLogger(__name__)

_INTENT_BASE = "https://x.com/intent/post"


def build_intent_url(text: str, url: str | None) -> str:
    params = {"text": text}
    if url:
        params["url"] = url
    query = urlencode(params, quote_via=quote)
    return f"{_INTENT_BASE}?{query}"


def open_in_browser(intent_url: str) -> None:
    logger.info("既定ブラウザで投稿画面を開きます: %s", intent_url)
    webbrowser.open(intent_url)
