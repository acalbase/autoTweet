"""OBS WebSocket への接続・イベント監視・自動再接続。"""
from __future__ import annotations

import logging
import time
from typing import Callable

import obsws_python as obs

logger = logging.getLogger(__name__)

_RECONNECT_INTERVAL_SEC = 10
_POLL_INTERVAL_SEC = 1


def watch(
    host: str,
    port: int,
    password: str,
    on_stream_started: Callable[[], None],
) -> None:
    """OBS に接続し、配信開始イベントを監視し続ける(無限ループ)。

    OBS が起動していない・途中で切断された場合は例外を握りつぶしてログを出し、
    _RECONNECT_INTERVAL_SEC 秒おきに再接続を試みる。呼び出し元は KeyboardInterrupt
    (Ctrl+C) で止めることを想定している。
    """
    while True:
        client = None
        try:
            logger.info("OBS WebSocket に接続しています... (%s:%s)", host, port)
            client = obs.EventClient(host=host, port=port, password=password, timeout=5)
            logger.info("OBS WebSocket に接続しました。")

            already_started = False

            def on_stream_state_changed(data):
                nonlocal already_started
                output_state = getattr(data, "output_state", "")
                output_active = getattr(data, "output_active", False)
                logger.info(
                    "StreamStateChanged: output_state=%s output_active=%s",
                    output_state,
                    output_active,
                )
                is_started = output_active and not already_started
                already_started = bool(output_active)
                if is_started:
                    logger.info("配信開始を検知しました。")
                    on_stream_started()

            client.callback.register(on_stream_state_changed)

            # 受信スレッドが生きている間は接続が保たれている。
            while client.worker.is_alive():
                time.sleep(_POLL_INTERVAL_SEC)

            logger.warning("OBS WebSocket との接続が切れました。再接続します。")
        except Exception as e:  # noqa: BLE001 - 何が起きても再接続ループを継続する
            logger.warning("OBS WebSocket に接続できません: %s: %s", type(e).__name__, e)
        finally:
            if client is not None:
                try:
                    client.disconnect()
                except Exception:  # noqa: BLE001
                    pass

        time.sleep(_RECONNECT_INTERVAL_SEC)
