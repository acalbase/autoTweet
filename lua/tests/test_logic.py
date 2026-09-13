"""youtube_live_tweet.lua のロジック検証テスト。

OBS Studio は開発機に無いため、lupa (LuaJIT バインディング) で obslua を
最小限スタブして、スクリプト末尾のテスト用エクスポート (_G.__YLT) を通じて
ロジック関数(build_live_url / parse_live_page / percent_encode /
build_intent_url / json_unescape など)を直接検証する。

実行方法:
    pip install lupa
    python lua/tests/test_logic.py
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
import unittest

try:
    from lupa import luajit21 as lua_backend
except ImportError as e:  # pragma: no cover
    raise SystemExit(
        "lupa (luajit21) が見つかりません。`pip install lupa` を実行してください。"
    ) from e

HERE = os.path.dirname(os.path.abspath(__file__))
LUA_DIR = os.path.dirname(HERE)
SCRIPT_PATH = os.path.join(LUA_DIR, "youtube_live_tweet.lua")
FIXTURES_DIR = os.path.join(HERE, "fixtures")


def _read_utf8(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def make_runtime():
    """obslua をスタブした LuaJIT ランタイムを作り、スクリプトをロードして
    テスト用エクスポートテーブル _G.__YLT を返す。"""
    rt = lua_backend.LuaRuntime(unpack_returned_tuples=True)

    obslua_stub = r"""
    obslua = {}
    local obs = obslua

    obs.OBS_TEXT_DEFAULT = 0
    obs.OBS_TEXT_MULTILINE = 2
    obs.OBS_TEXT_INFO = 3
    obs.OBS_FRONTEND_EVENT_STREAMING_STARTED = 1
    obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED = 2
    obs.LOG_INFO = 0
    obs.LOG_WARNING = 1
    obs.LOG_ERROR = 2

    obs.script_log = function(level, msg)
        -- print(msg)
    end

    obs.obs_properties_create = function() return {} end
    obs.obs_properties_add_text = function(props, name, label, kind) return { name = name } end
    obs.obs_properties_add_bool = function(props, name, label) return { name = name } end
    obs.obs_properties_add_int = function(props, name, label, mn, mx, step) return { name = name } end
    obs.obs_properties_add_button = function(props, name, label, cb) return { name = name, cb = cb } end
    obs.obs_properties_get = function(props, name) return nil end
    obs.obs_property_set_description = function(prop, text) end

    obs.obs_data_get_string = function(settings, key)
        if settings and settings[key] ~= nil then return settings[key] end
        return ""
    end
    obs.obs_data_get_bool = function(settings, key)
        if settings and settings[key] ~= nil then return settings[key] end
        return false
    end
    obs.obs_data_get_int = function(settings, key)
        if settings and settings[key] ~= nil then return settings[key] end
        return 0
    end
    obs.obs_data_set_string = function(settings, key, value)
        if settings then settings[key] = value end
    end
    obs.obs_data_set_default_string = function(settings, key, value) end
    obs.obs_data_set_default_bool = function(settings, key, value) end
    obs.obs_data_set_default_int = function(settings, key, value) end

    obs.obs_frontend_add_event_callback = function(cb) end

    -- timer_add/timer_remove の呼び出しを記録する(テストから確認できるように)。
    _G.__YLT_TIMER_LOG = {}
    obs.timer_add = function(fn, ms)
        table.insert(_G.__YLT_TIMER_LOG, { action = "add", ms = ms })
    end
    obs.timer_remove = function(fn)
        table.insert(_G.__YLT_TIMER_LOG, { action = "remove" })
    end

    _G.__YLT_TEST = true
    """
    rt.execute(obslua_stub)

    with open(SCRIPT_PATH, "r", encoding="utf-8") as f:
        script_src = f.read()

    # 構文チェック: load できること
    load_fn = rt.eval("load")
    result = load_fn(script_src, "youtube_live_tweet.lua")
    if isinstance(result, tuple):
        chunk, err = result
    else:
        chunk, err = result, None
    if chunk is None:
        raise AssertionError(f"load() に失敗しました: {err}")

    chunk()

    ylt = rt.globals().__YLT
    if ylt is None:
        raise AssertionError("_G.__YLT が公開されていません。")
    return rt, ylt


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.rt, self.ylt = make_runtime()

    def test_version_format(self):
        version = str(self.ylt.VERSION)
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")


class BuildLiveUrlTests(unittest.TestCase):
    def setUp(self):
        self.rt, self.ylt = make_runtime()

    def test_valid_forms(self):
        cases = {
            "https://www.youtube.com/@NASA": "https://www.youtube.com/@NASA/live",
            "https://www.youtube.com/@NASA/": "https://www.youtube.com/@NASA/live",
            "https://www.youtube.com/@NASA/live": "https://www.youtube.com/@NASA/live",
            "@NASA": "https://www.youtube.com/@NASA/live",
            "UCLA_DiR1FfKNvjuUpBHmylQ": "https://www.youtube.com/channel/UCLA_DiR1FfKNvjuUpBHmylQ/live",
            "https://www.youtube.com/channel/UCLA_DiR1FfKNvjuUpBHmylQ/streams":
                "https://www.youtube.com/channel/UCLA_DiR1FfKNvjuUpBHmylQ/live",
            "  https://youtube.com/@NASA  ": "https://www.youtube.com/@NASA/live",
        }
        for input_value, expected in cases.items():
            with self.subTest(input_value=input_value):
                result = self.ylt.build_live_url(input_value)
                self.assertEqual(result, expected)

    def test_invalid_forms(self):
        for bad in ["nasa", ""]:
            with self.subTest(bad=bad):
                result = self.ylt.build_live_url(bad)
                self.assertIsNone(result)


class ParseLivePageTests(unittest.TestCase):
    def setUp(self):
        self.rt, self.ylt = make_runtime()

    def test_nasa_live_html_returns_video_id_and_title(self):
        path = os.path.join(FIXTURES_DIR, "nasa_live.html")
        html = _read_utf8(path)
        result = self.ylt.parse_live_page(html)
        self.assertIsNotNone(result, "NASA の /live ページが解析できず nil が返った")
        video_id = result["video_id"]
        title = result["title"]
        self.assertTrue(video_id, "video_id が空")
        self.assertTrue(title, "title が空")
        print(f"  [NASA] video_id={video_id!r} title={title!r}")

    def test_google_live_html_returns_nil(self):
        path = os.path.join(FIXTURES_DIR, "google_live.html")
        html = _read_utf8(path)
        result = self.ylt.parse_live_page(html)
        self.assertIsNone(result, "Google は配信中でないはずなのに結果が返った")

    def test_unicode_escape_in_title_synthetic(self):
        # \uXXXX エスケープ(サロゲートペア含む)入りの合成 JSON で確認する。
        # タイトル: "配信\uD83D\uDE00テスト" -> "配信😀テスト"
        synthetic_html = (
            'var ytInitialPlayerResponse = {"videoDetails":{'
            '"videoId":"abc123XYZ_-","title":"\\u914d\\u4fe1\\uD83D\\uDE00\\u30c6\\u30b9\\u30c8",'
            '"isLive":true}};'
        )
        result = self.ylt.parse_live_page(synthetic_html)
        self.assertIsNotNone(result)
        self.assertEqual(result["video_id"], "abc123XYZ_-")
        self.assertEqual(result["title"], "配信😀テスト")

    def test_not_live_returns_nil(self):
        synthetic_html = (
            'var ytInitialPlayerResponse = {"videoDetails":{'
            '"videoId":"abc123","title":"foo","isLive":false}};'
        )
        result = self.ylt.parse_live_page(synthetic_html)
        self.assertIsNone(result)

    def test_no_player_response_returns_nil(self):
        result = self.ylt.parse_live_page("<html><body>no data here</body></html>")
        self.assertIsNone(result)


class PercentEncodeAndIntentUrlTests(unittest.TestCase):
    def setUp(self):
        self.rt, self.ylt = make_runtime()

    def test_percent_encode_special_chars(self):
        text = "配信はじめました！\nテスト #タグ & 100%"
        encoded = self.ylt.percent_encode(text)
        self.assertIn("%0A", encoded)
        self.assertIn("%23", encoded)
        self.assertIn("%26", encoded)
        self.assertIn("%25", encoded)
        # 日本語(UTF-8)が %E3... 形式でエンコードされていること
        self.assertIn("%E3", encoded)
        # unreserved はエンコードされないこと
        plain = self.ylt.percent_encode("abc-DEF_123.~")
        self.assertEqual(plain, "abc-DEF_123.~")

    def test_build_intent_url(self):
        text = "配信はじめました！\nテスト #タグ & 100%"
        url = "https://www.youtube.com/watch?v=abc123"
        intent = self.ylt.build_intent_url(text, url)
        self.assertTrue(intent.startswith("https://x.com/intent/post?text="))
        self.assertIn("&url=", intent)
        self.assertIn("%0A", intent)
        self.assertIn("%23", intent)
        self.assertIn("%26", intent)
        self.assertIn("%25", intent)
        self.assertIn("%E3", intent)

    def test_build_intent_url_without_url(self):
        intent = self.ylt.build_intent_url("hello", None)
        self.assertEqual(intent, "https://x.com/intent/post?text=hello")


class RenderTextTests(unittest.TestCase):
    def setUp(self):
        self.rt, self.ylt = make_runtime()

    def test_basic_replacement(self):
        result = self.ylt.render_text("{title} / {url}", "hello", "https://example.com/")
        self.assertEqual(result, "hello / https://example.com/")

    def test_title_containing_placeholder_and_percent_does_not_break(self):
        # title 自体に {url} や %1 のようなパターン置換の特殊文字を含んでいても、
        # render_text の出力やその後の gsub 動作に影響してはならない。
        title = "配信中 {url} 100%1 開催！"
        url = "https://www.youtube.com/watch?v=abc123"
        result = self.ylt.render_text("{title}\n{url}", title, url)
        self.assertEqual(result, title + "\n" + url)

    def test_unknown_key_left_as_is(self):
        result = self.ylt.render_text("{title} {unknown} {url}", "T", "U")
        self.assertEqual(result, "T {unknown} U")

    def test_nil_title_and_url_become_empty_string(self):
        result = self.ylt.render_text("[{title}][{url}]", None, None)
        self.assertEqual(result, "[][]")


class FfiCurlTests(unittest.TestCase):
    """ffi 経由での CreateProcessA / WaitForSingleObject の動作確認。"""

    def setUp(self):
        self.rt, self.ylt = make_runtime()

    def test_ffi_available(self):
        self.assertTrue(bool(self.ylt.ffi_ok), "LuaJIT ffi が利用できません")

    def test_curl_exists(self):
        self.assertTrue(bool(self.ylt.curl_exists()), "C:\\Windows\\System32\\curl.exe が見つかりません")

    def test_create_process_and_wait(self):
        if not bool(self.ylt.ffi_ok):
            self.skipTest("ffi が利用できないためスキップ")

        tmp_dir = os.environ.get("TEMP", ".")
        out_path = os.path.join(tmp_dir, f"ylt_test_{int(time.time())}.html")
        if os.path.exists(out_path):
            os.remove(out_path)

        proc = self.ylt.start_curl_async("https://www.youtube.com/@NASA/live", out_path, 15)
        self.assertIsNotNone(proc, "curl.exe の起動 (CreateProcessA) に失敗しました")

        h_process = proc["hProcess"]

        deadline = time.time() + 20
        running = True
        while time.time() < deadline:
            running, failed = self.ylt.is_process_running(h_process)
            running = bool(running)
            self.assertFalse(bool(failed), "WaitForSingleObject が失敗 (WAIT_FAILED) を返しました")
            if not running:
                break
            time.sleep(0.5)

        self.assertFalse(running, "curl.exe が20秒以内に終了しませんでした (WaitForSingleObject)")

        exit_code = self.ylt.get_exit_code(h_process)
        self.assertEqual(int(exit_code), 0, "curl.exe の終了コードが 0 ではありません")

        self.assertTrue(os.path.exists(out_path), "curl.exe の出力ファイルが作成されていません")
        self.assertGreater(os.path.getsize(out_path), 0, "curl.exe の出力ファイルが空です")

        os.remove(out_path)


class ConflictAndFallbackFlowTests(unittest.TestCase):
    """状態機械そのもの(start_resolve / poll_tick)を通した検証。

    curl.exe は一切起動しない: __YLT_NOW で時刻を進めて timeout を即座に
    超過させ、poll_tick が(プロセスの有無に関係なく)タイムアウト分岐を
    先に評価して fallback へ進むことを確認する。ShellExecuteA 相当は
    __YLT_SHELLEXEC で差し替え、実際にブラウザは開かない。
    """

    def setUp(self):
        self.rt, self.ylt = make_runtime()

        self.clock = {"t": 1_000_000}

        def now_fn():
            return self.clock["t"]

        # 注意: このクラス(class)本体の中で `obj.__YLT_NOW` のような属性アクセス
        # 記法を書くと Python の name mangling (先頭ダブルアンダースコア) の対象になり、
        # 実際には別属性 (_ClassName__YLT_NOW) に代入されてしまう。
        # そのため添字アクセス(辞書スタイル)で代入する。
        self.rt.globals()["__YLT_NOW"] = now_fn

        self.shell_calls = []

        def shellexec_fn(url):
            self.shell_calls.append(url)
            return True

        self.rt.globals()["__YLT_SHELLEXEC"] = shellexec_fn

        settings = self.rt.table_from({
            "channel": "@NASA",
            "tweet_text": "{title}{url}",
            "include_url": True,
            "retry_interval": 5,
            "timeout": 30,
            "fallback_open": True,
            "last_video_id": "",
        })
        self.rt.globals().script_load(settings)
        self.rt.globals().script_update(settings)

    def test_timeout_triggers_fallback_open(self):
        self.ylt.start_resolve(False)
        job = self.ylt.get_current_job()
        self.assertIsNotNone(job, "start_resolve 後に current_job が作られていません")

        self.clock["t"] += 31  # timeout (30秒) を超過させる

        self.ylt.poll_tick()

        self.assertIsNone(self.ylt.get_current_job(), "タイムアウト後も current_job が残っています")
        self.assertEqual(len(self.shell_calls), 1, "fallback で ShellExecute 相当が1回呼ばれるはず")
        self.assertIn("https://x.com/intent/post?text=", self.shell_calls[0])
        self.assertIn("&url=", self.shell_calls[0])
        status = str(self.ylt.get_status_text())
        self.assertIn("タイトル空で開きました", status)

    def test_test_button_does_not_cancel_running_production_job(self):
        self.ylt.start_resolve(False)
        job_before = self.ylt.get_current_job()
        self.assertIsNotNone(job_before)

        self.ylt.start_resolve(True)

        job_after = self.ylt.get_current_job()
        self.assertIsNotNone(job_after, "本番ジョブが誤ってキャンセルされました")
        self.assertEqual(job_before["overall_started_at"], job_after["overall_started_at"])
        status = str(self.ylt.get_status_text())
        self.assertIn("取得中です", status)

    def test_real_streaming_started_replaces_existing_job(self):
        self.ylt.start_resolve(False)
        job_before = self.ylt.get_current_job()
        self.assertIsNotNone(job_before)

        self.clock["t"] += 1
        self.ylt.start_resolve(False)
        job_after = self.ylt.get_current_job()
        self.assertIsNotNone(job_after)
        self.assertNotEqual(job_before["overall_started_at"], job_after["overall_started_at"])


def test_syntax_check_load():
    """スクリプトが lupa(LuaJIT) の load() で構文エラーなくロードできることの確認。
    (make_runtime 内で既に実施しているが、単体テストとしても明示する。)"""
    rt, ylt = make_runtime()
    assert ylt is not None


if __name__ == "__main__":
    print("=== 構文チェック (load) ===")
    test_syntax_check_load()
    print("OK: load() でスクリプトを読み込めました。\n")

    unittest.main(verbosity=2)
