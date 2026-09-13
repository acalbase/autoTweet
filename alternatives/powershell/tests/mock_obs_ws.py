"""OBS WebSocket v5 のモックサーバー(開発者向け・PowerShell 版の動作確認用)。

使い方:
    pip install websockets
    python mock_obs_ws.py

ポート 4455 で1接続だけ待ち受け、以下の順でシーケンスを実行してサーバーを終了する。
  1. 接続時に Hello (op=0) を送信 (challenge/salt はランダム生成)。
  2. Identify (op=1) を受信。password "testpass" で計算した auth と一致すれば
     Identified (op=2) を返す。不一致なら close code 4009 で切断する。
  3. 3秒後に StreamStateChanged (outputActive=true) を送信。
  4. 更に3秒後に StreamStateChanged (outputActive=false) を送信。
  5. 更に3秒後に接続を閉じてサーバーを終了する。
"""
import asyncio
import base64
import hashlib
import json
import os

import websockets

PASSWORD = "testpass"
PORT = 4455


def make_auth(password: str, salt: str, challenge: str) -> str:
    secret = base64.b64encode(
        hashlib.sha256((password + salt).encode("utf-8")).digest()
    ).decode("utf-8")
    auth = base64.b64encode(
        hashlib.sha256((secret + challenge).encode("utf-8")).digest()
    ).decode("utf-8")
    return auth


async def handler(websocket):
    global _done
    challenge = base64.b64encode(os.urandom(24)).decode("utf-8")
    salt = base64.b64encode(os.urandom(24)).decode("utf-8")
    expected_auth = make_auth(PASSWORD, salt, challenge)

    hello = {
        "op": 0,
        "d": {
            "obsWebSocketVersion": "5.5.0",
            "rpcVersion": 1,
            "authentication": {
                "challenge": challenge,
                "salt": salt,
            },
        },
    }
    print("[mock] sending Hello")
    await websocket.send(json.dumps(hello))

    try:
        raw = await websocket.recv()
    except websockets.exceptions.ConnectionClosed:
        print("[mock] connection closed before Identify")
        _done.set()
        return

    identify = json.loads(raw)
    print("[mock] received Identify:", identify)
    auth = identify.get("d", {}).get("authentication")

    if auth == expected_auth:
        print("[mock] auth OK, sending Identified")
        await websocket.send(json.dumps({"op": 2, "d": {"negotiatedRpcVersion": 1}}))
    else:
        print("[mock] auth FAILED, closing with 4009")
        await websocket.close(code=4009, reason="Authentication failed")
        _done.set()
        return

    await asyncio.sleep(3)
    print("[mock] sending StreamStateChanged outputActive=true")
    await websocket.send(
        json.dumps(
            {
                "op": 5,
                "d": {
                    "eventType": "StreamStateChanged",
                    "eventIntent": 64,
                    "eventData": {
                        "outputActive": True,
                        "outputState": "OBS_WEBSOCKET_OUTPUT_STARTED",
                    },
                },
            }
        )
    )

    await asyncio.sleep(3)
    print("[mock] sending StreamStateChanged outputActive=false")
    await websocket.send(
        json.dumps(
            {
                "op": 5,
                "d": {
                    "eventType": "StreamStateChanged",
                    "eventIntent": 64,
                    "eventData": {
                        "outputActive": False,
                        "outputState": "OBS_WEBSOCKET_OUTPUT_STOPPED",
                    },
                },
            }
        )
    )

    await asyncio.sleep(3)
    print("[mock] closing connection")
    await websocket.close()
    _done.set()


_done = None


async def main():
    global _done
    _done = asyncio.Event()
    print(f"[mock] listening on ws://localhost:{PORT}/")
    async with websockets.serve(handler, "localhost", PORT):
        await _done.wait()
    print("[mock] server stopped")


if __name__ == "__main__":
    asyncio.run(main())
