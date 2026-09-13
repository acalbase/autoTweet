-- youtube_live_tweet.lua
-- 使い方: OBS Studio の ツール → スクリプト → ＋ でこのファイルを追加する。
-- 「YouTube チャンネルの URL」に配信したいチャンネルの URL(または @handle / UC...のID)を入力する。
-- あとは OBS で配信を開始するだけで、配信タイトル・URL入りの X 投稿画面が既定ブラウザで自動的に開く(投稿自体は手動)。

local VERSION = "1.0.0"

local obs = obslua

local ffi_ok, ffi = pcall(require, "ffi")

local kernel32 = nil
local shell32 = nil
local CREATE_NO_WINDOW = 0x08000000
local WAIT_TIMEOUT = 0x00000102
local WAIT_FAILED = 0xFFFFFFFF
local SW_SHOWNORMAL = 1

if ffi_ok then
  -- 別のスクリプトインスタンスや再読み込みで同じ型/関数が既に cdef 済みの場合、
  -- ffi.cdef は再定義エラーを投げることがあるため pcall で無視する。
  pcall(ffi.cdef, [[
    typedef struct _STARTUPINFOA {
      uint32_t cb;
      char*    lpReserved;
      char*    lpDesktop;
      char*    lpTitle;
      uint32_t dwX;
      uint32_t dwY;
      uint32_t dwXSize;
      uint32_t dwYSize;
      uint32_t dwXCountChars;
      uint32_t dwYCountChars;
      uint32_t dwFillAttribute;
      uint32_t dwFlags;
      uint16_t wShowWindow;
      uint16_t cbReserved2;
      uint8_t* lpReserved2;
      void*    hStdInput;
      void*    hStdOutput;
      void*    hStdError;
    } STARTUPINFOA;

    typedef struct _PROCESS_INFORMATION {
      void*    hProcess;
      void*    hThread;
      uint32_t dwProcessId;
      uint32_t dwThreadId;
    } PROCESS_INFORMATION;

    int CreateProcessA(
      const char* lpApplicationName,
      char* lpCommandLine,
      void* lpProcessAttributes,
      void* lpThreadAttributes,
      int bInheritHandles,
      uint32_t dwCreationFlags,
      void* lpEnvironment,
      const char* lpCurrentDirectory,
      STARTUPINFOA* lpStartupInfo,
      PROCESS_INFORMATION* lpProcessInformation
    );

    uint32_t WaitForSingleObject(void* hHandle, uint32_t dwMilliseconds);
    int GetExitCodeProcess(void* hProcess, uint32_t* lpExitCode);
    int CloseHandle(void* hObject);
    int TerminateProcess(void* hProcess, uint32_t uExitCode);

    void* ShellExecuteA(
      void* hwnd,
      const char* lpOperation,
      const char* lpFile,
      const char* lpParameters,
      const char* lpDirectory,
      int nShowCmd
    );
  ]])

  local ok1, k32 = pcall(ffi.load, "kernel32.dll")
  local ok2, s32 = pcall(ffi.load, "shell32.dll")
  if ok1 then kernel32 = k32 end
  if ok2 then shell32 = s32 end
  if (not ok1) or (not ok2) then
    ffi_ok = false
  end
end

-- ------------------------------------------------------------
-- 定数
-- ------------------------------------------------------------

local CURL_PATH = "C:\\Windows\\System32\\curl.exe"
local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
local DEFAULT_TWEET_TEXT = "配信はじめました！\n{title}"
local PLAYER_RESPONSE_MARKER = "ytInitialPlayerResponse%s*=%s*"

-- ------------------------------------------------------------
-- 汎用ユーティリティ
-- ------------------------------------------------------------

local function trim(s)
  local r = s:gsub("^%s+", "")
  r = r:gsub("%s+$", "")
  return r
end

local function rstrip_slashes(s)
  return (s:gsub("/+$", ""))
end

-- 現在時刻(秒)。テストから時刻を差し替えられるように _G.__YLT_NOW があれば
-- それを優先する(本番では常に os.time() を使う)。
local function now()
  if _G.__YLT_NOW then
    return _G.__YLT_NOW()
  end
  return os.time()
end

-- ------------------------------------------------------------
-- channel 入力 → /live URL への正規化
-- ------------------------------------------------------------

local function build_live_url(input)
  if type(input) ~= "string" then
    return nil
  end
  local s = trim(input)
  if s == "" then
    return nil
  end

  local rest = s
  local proto_rest = rest:match("^[Hh][Tt][Tt][Pp][Ss]?://(.+)$")
  if proto_rest then
    rest = proto_rest
  end

  local www_rest = rest:match("^[Ww][Ww][Ww]%.(.+)$")
  if www_rest then
    rest = www_rest
  end

  local path = rest:match("^[Yy][Oo][Uu][Tt][Uu][Bb][Ee]%.[Cc][Oo][Mm]/(.+)$")
  if not path then
    path = rest
  end

  path = rstrip_slashes(path)
  if path == "" then
    return nil
  end

  local lower_path = path:lower()
  if lower_path:sub(-5) == "/live" then
    path = path:sub(1, #path - 5)
  elseif lower_path:sub(-8) == "/streams" then
    path = path:sub(1, #path - 8)
  end
  path = rstrip_slashes(path)
  if path == "" then
    return nil
  end

  local handle = path:match("^(@[%w%.%-_]+)$")
  if handle then
    return "https://www.youtube.com/" .. handle .. "/live"
  end

  local channel_id = path:match("^[Cc][Hh][Aa][Nn][Nn][Ee][Ll]/(UC[%w%-_]+)$")
  if channel_id then
    return "https://www.youtube.com/channel/" .. channel_id .. "/live"
  end

  if path:match("^UC[%w%-_]+$") then
    return "https://www.youtube.com/channel/" .. path .. "/live"
  end

  return nil
end

-- ------------------------------------------------------------
-- YouTube ページ解析
-- ------------------------------------------------------------

-- text[start_idx] が '{' であることを前提に、対応する '}' までを
-- 文字列リテラル内の {} と \" エスケープを考慮して切り出す。
local function extract_balanced_json(text, start_idx)
  if start_idx == nil or start_idx > #text or text:sub(start_idx, start_idx) ~= "{" then
    return nil
  end

  local depth = 0
  local in_string = false
  local escape = false
  for i = start_idx, #text do
    local ch = text:sub(i, i)
    if in_string then
      if escape then
        escape = false
      elseif ch == "\\" then
        escape = true
      elseif ch == '"' then
        in_string = false
      end
    else
      if ch == '"' then
        in_string = true
      elseif ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
        if depth == 0 then
          return text:sub(start_idx, i)
        end
      end
    end
  end
  return nil
end

local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(
      0xC0 + math.floor(cp / 0x40),
      0x80 + (cp % 0x40)
    )
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + (math.floor(cp / 0x1000) % 0x40),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  end
end

-- JSON 文字列値(引用符の中身)のエスケープを解除する。
local function json_unescape(s)
  local out = {}
  local i = 1
  local n = #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "\\" and i < n then
      local nextch = s:sub(i + 1, i + 1)
      if nextch == '"' then
        out[#out + 1] = '"'
        i = i + 2
      elseif nextch == "\\" then
        out[#out + 1] = "\\"
        i = i + 2
      elseif nextch == "/" then
        out[#out + 1] = "/"
        i = i + 2
      elseif nextch == "n" then
        out[#out + 1] = "\n"
        i = i + 2
      elseif nextch == "r" then
        out[#out + 1] = "\r"
        i = i + 2
      elseif nextch == "t" then
        out[#out + 1] = "\t"
        i = i + 2
      elseif nextch == "b" then
        out[#out + 1] = "\b"
        i = i + 2
      elseif nextch == "f" then
        out[#out + 1] = "\f"
        i = i + 2
      elseif nextch == "u" then
        local hex = s:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16)
        i = i + 6
        if cp == nil then
          -- 壊れた \u エスケープはそのまま捨てる
        elseif cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
          local hex2 = s:sub(i + 2, i + 5)
          local cp2 = tonumber(hex2, 16)
          if cp2 ~= nil and cp2 >= 0xDC00 and cp2 <= 0xDFFF then
            local combined = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
            out[#out + 1] = utf8_encode(combined)
            i = i + 6
          else
            out[#out + 1] = utf8_encode(cp)
          end
        else
          out[#out + 1] = utf8_encode(cp)
        end
      else
        out[#out + 1] = nextch
        i = i + 2
      end
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out)
end

-- json_text 内から "field_name":"..." の文字列値(生のJSONエスケープ済み)を取り出す。
local function extract_json_string_field(json_text, field_name)
  local pattern = '"' .. field_name .. '"%s*:%s*"'
  local match_start, match_end = json_text:find(pattern)
  if not match_start then
    return nil
  end
  local i = match_end + 1
  local n = #json_text
  local escape = false
  local start_i = i
  while i <= n do
    local ch = json_text:sub(i, i)
    if escape then
      escape = false
    elseif ch == "\\" then
      escape = true
    elseif ch == '"' then
      return json_text:sub(start_i, i - 1)
    end
    i = i + 1
  end
  return nil
end

local function parse_live_page(html)
  if type(html) ~= "string" then
    return nil
  end

  local marker_start, marker_end = html:find(PLAYER_RESPONSE_MARKER)
  if not marker_start then
    return nil
  end

  local player_json = extract_balanced_json(html, marker_end + 1)
  if not player_json then
    return nil
  end

  local vd_prefix_start, vd_prefix_end = player_json:find('"videoDetails"%s*:%s*')
  if not vd_prefix_start then
    return nil
  end

  local video_details_json = extract_balanced_json(player_json, vd_prefix_end + 1)
  if not video_details_json then
    return nil
  end

  if not video_details_json:find('"isLive"%s*:%s*true') then
    return nil
  end

  local video_id = extract_json_string_field(video_details_json, "videoId")
  if not video_id or video_id == "" then
    return nil
  end

  local raw_title = extract_json_string_field(video_details_json, "title")
  local title = ""
  if raw_title then
    title = json_unescape(raw_title)
  end

  return { video_id = video_id, title = title }
end

-- ------------------------------------------------------------
-- X Web Intent
-- ------------------------------------------------------------

local function percent_encode(s)
  s = s or ""
  return (s:gsub("[^%w%.%-%_~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function build_intent_url(text, url_or_nil)
  local result = "https://x.com/intent/post?text=" .. percent_encode(text or "")
  if url_or_nil and url_or_nil ~= "" then
    result = result .. "&url=" .. percent_encode(url_or_nil)
  end
  return result
end

local function open_url_in_browser(url)
  -- テストから ShellExecuteA 相当を差し替えられるようにする(実ブラウザは開かない)。
  if _G.__YLT_SHELLEXEC then
    return _G.__YLT_SHELLEXEC(url) and true or false
  end
  if not ffi_ok or not shell32 then
    obs.script_log(obs.LOG_ERROR, "ffi/shell32 が利用できないため既定ブラウザを開けません。")
    return false
  end
  local result = shell32.ShellExecuteA(nil, "open", url, nil, nil, SW_SHOWNORMAL)
  local code = tonumber(ffi.cast("intptr_t", result))
  return code ~= nil and code > 32
end

-- ------------------------------------------------------------
-- curl.exe の非同期起動(コンソール窓を出さない)
-- ------------------------------------------------------------

local function curl_exists()
  local f = io.open(CURL_PATH, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function start_curl_async(live_url, out_path, curl_timeout_sec)
  if not ffi_ok or not kernel32 then
    return nil
  end

  local cmdline = string.format(
    '"%s" -s -L -m %d -A "%s" -H "Accept-Language: ja,en;q=0.8" -b "CONSENT=YES+cb" -o "%s" "%s"',
    CURL_PATH, curl_timeout_sec, USER_AGENT, out_path, live_url
  )

  local si = ffi.new("STARTUPINFOA")
  si.cb = ffi.sizeof("STARTUPINFOA")
  local pi = ffi.new("PROCESS_INFORMATION")

  local buf = ffi.new("char[?]", #cmdline + 1)
  ffi.copy(buf, cmdline)

  local ok = kernel32.CreateProcessA(nil, buf, nil, nil, 0, CREATE_NO_WINDOW, nil, nil, si, pi)
  if ok == 0 then
    return nil
  end

  kernel32.CloseHandle(pi.hThread)
  return { hProcess = pi.hProcess, started_at = now() }
end

-- 戻り値: running (実行中かどうか), failed (WaitForSingleObject 自体が失敗したか)。
-- failed が true の場合、呼び出し側は exit code が非ゼロだった場合と同じ扱い
-- (取得失敗 → リトライ)にする。
local function is_process_running(hProcess)
  local r = kernel32.WaitForSingleObject(hProcess, 0)
  if r == WAIT_TIMEOUT then
    return true, false
  elseif r == WAIT_FAILED then
    return false, true
  end
  return false, false
end

local function get_exit_code(hProcess)
  local code = ffi.new("uint32_t[1]")
  kernel32.GetExitCodeProcess(hProcess, code)
  return code[0]
end

local function read_file_all(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

-- ------------------------------------------------------------
-- スクリプトの状態
-- ------------------------------------------------------------

local channel = ""
local tweet_text = DEFAULT_TWEET_TEXT
local include_url = true
local retry_interval = 5
local timeout = 120
local fallback_open = true

local settings_ref = nil
local last_video_id = nil
local status_text = "待機中"

-- current_job:
--   live_url, force, overall_started_at, last_attempt_at, process, part_path, final_path
local current_job = nil

-- ステータスは Lua 変数 status_text にのみ保持する(obs_properties への直接参照は
-- 保持しない。プロパティ画面を開いた/テストボタンを押した時点で最新の status_text
-- を反映すれば十分で、閉じられている可能性のある props への参照を使い回すのは
-- 安全でないため)。変化のたびに同じ文言を script_log にも出す。
local function update_status(text)
  status_text = text
  obs.script_log(obs.LOG_INFO, text)
end

-- テンプレート内の {key} を1回の gsub で置換する。map に無いキーはそのまま残す。
-- 置換値を関数で返すことで、title/url に % や {url} 等が含まれていても
-- gsub の置換パターン展開の影響を受けない。
local function render_text(template, title, url)
  local map = { title = title or "", url = url or "" }
  local s = template or ""
  return (s:gsub("{(%w+)}", function(key)
    if map[key] ~= nil then
      return map[key]
    end
    return "{" .. key .. "}"
  end))
end

-- 前方宣言(下で同じローカル変数に代入する)。
local poll_tick

local function cleanup_job_process(job)
  if job.process and job.process.hProcess then
    local h = job.process.hProcess
    local wait_ok, running = pcall(is_process_running, h)
    if wait_ok and running then
      pcall(function() kernel32.TerminateProcess(h, 1) end)
      pcall(function() kernel32.WaitForSingleObject(h, 1000) end)
    end
    pcall(function() kernel32.CloseHandle(h) end)
    job.process = nil
  end
  if job.part_path then
    pcall(os.remove, job.part_path)
    job.part_path = nil
  end
  if job.final_path then
    pcall(os.remove, job.final_path)
    job.final_path = nil
  end
end

local function do_fallback(live_url, reason)
  if not fallback_open then
    update_status("取得できませんでした。" .. (reason or ""))
    obs.script_log(obs.LOG_WARNING, "ライブ情報を取得できませんでした。fallback_open が false のため何もしません。")
    return
  end

  local text = render_text(tweet_text, "", live_url or "")
  local url_param = nil
  if include_url then
    url_param = live_url
  end
  local intent = build_intent_url(text, url_param)
  local opened = open_url_in_browser(intent)
  if opened then
    update_status("取得できませんでした。タイトル空で開きました")
  else
    update_status("投稿画面を開けませんでした。")
  end
end

local function finish_job_success(job, info)
  local video_id = info.video_id
  local title = info.title or ""
  local url = "https://www.youtube.com/watch?v=" .. video_id

  if (not job.force) and last_video_id ~= nil and last_video_id == video_id then
    update_status("同じ配信のため投稿画面は開きませんでした: " .. title)
    obs.script_log(obs.LOG_INFO, "同じ video_id のため開きません: " .. video_id)
    return
  end

  local text = render_text(tweet_text, title, url)
  local url_param = nil
  if include_url then
    url_param = url
  end
  local intent = build_intent_url(text, url_param)
  local opened = open_url_in_browser(intent)
  if opened then
    last_video_id = video_id
    if settings_ref then
      obs.obs_data_set_string(settings_ref, "last_video_id", video_id)
    end
    update_status("投稿画面を開きました: " .. title)
  else
    update_status("投稿画面を開けませんでした。")
  end
end

local function start_new_attempt(job)
  local temp_dir = os.getenv("TEMP") or "."
  local final_path = temp_dir .. "\\youtube_live_tweet_" .. now() .. "_" .. tostring(math.random(1000, 9999)) .. ".html"
  local part_path = final_path .. ".part"
  local curl_timeout_sec = math.min(15, timeout)
  local proc = start_curl_async(job.live_url, part_path, curl_timeout_sec)
  job.last_attempt_at = now()
  if not proc then
    obs.script_log(obs.LOG_WARNING, "curl.exe の起動に失敗しました。")
    job.process = nil
    job.part_path = nil
    job.final_path = nil
    return
  end
  job.process = proc
  job.part_path = part_path
  job.final_path = final_path
end

poll_tick = function()
  if not current_job then
    return
  end
  local job = current_job

  -- 全体タイムアウトはプロセスの実行状況に関係なく最優先で判定する。
  if now() - job.overall_started_at >= timeout then
    obs.timer_remove(poll_tick)
    cleanup_job_process(job)
    current_job = nil
    update_status("timeout (" .. timeout .. "秒) 以内にライブ情報を取得できませんでした。")
    do_fallback(job.live_url, "")
    return
  end

  if job.process then
    local running, failed = is_process_running(job.process.hProcess)
    if running then
      local elapsed = now() - job.overall_started_at
      update_status("配信開始を検知、タイトル取得中…(" .. elapsed .. "秒)")
      return
    end

    local exit_code = 1
    if not failed then
      exit_code = get_exit_code(job.process.hProcess)
    end
    pcall(function() kernel32.CloseHandle(job.process.hProcess) end)
    job.process = nil

    local info = nil
    if exit_code == 0 and job.part_path then
      local html = read_file_all(job.part_path)
      if html then
        info = parse_live_page(html)
      end
    end
    if job.part_path then
      pcall(os.remove, job.part_path)
      job.part_path = nil
    end
    if job.final_path then
      pcall(os.remove, job.final_path)
      job.final_path = nil
    end

    if info then
      obs.timer_remove(poll_tick)
      current_job = nil
      finish_job_success(job, info)
      return
    end
  end

  if job.last_attempt_at == nil or (now() - job.last_attempt_at) >= retry_interval then
    start_new_attempt(job)
  else
    local elapsed = now() - job.overall_started_at
    update_status("配信開始を検知、タイトル取得中…(" .. elapsed .. "秒)")
  end
end

local function cancel_job()
  if current_job then
    obs.timer_remove(poll_tick)
    cleanup_job_process(current_job)
    current_job = nil
    update_status("配信停止を検知したため取得を中止しました。")
  end
end

local function start_resolve(force)
  -- テスト実行(force=true)が来た時点で、既に本番の配信開始イベント(force=false)
  -- によるジョブが進行中であれば、それを止めずに案内だけ出して戻る。
  -- 本番イベント(force=false)は従来どおり既存ジョブを常に置き換える。
  if force and current_job and (not current_job.force) then
    update_status("取得中です。完了までお待ちください")
    return
  end

  if current_job then
    obs.timer_remove(poll_tick)
    cleanup_job_process(current_job)
    current_job = nil
  end

  local live_url = build_live_url(channel)
  if not live_url then
    update_status("チャンネル URL が正しくありません")
    obs.script_log(obs.LOG_ERROR, "チャンネル URL の形式が不正です: " .. tostring(channel))
    return
  end

  if not ffi_ok or not kernel32 then
    obs.script_log(obs.LOG_ERROR, "LuaJIT ffi が利用できません。")
    update_status("ffi が利用できないため取得できません。")
    do_fallback(live_url, "")
    return
  end

  if not curl_exists() then
    obs.script_log(obs.LOG_ERROR, "curl.exe が見つかりません: " .. CURL_PATH)
    do_fallback(live_url, "curl.exe が見つかりません")
    return
  end

  current_job = {
    live_url = live_url,
    force = force,
    overall_started_at = now(),
    last_attempt_at = nil,
    process = nil,
    part_path = nil,
    final_path = nil,
  }
  update_status("配信開始を検知、タイトル取得中…(0秒)")
  obs.timer_add(poll_tick, 1000)
end

-- ------------------------------------------------------------
-- OBS フロントエンドイベント
-- ------------------------------------------------------------

local function on_frontend_event(event)
  if event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED then
    start_resolve(false)
  elseif event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED then
    cancel_job()
  end
end

-- ------------------------------------------------------------
-- OBS スクリプト API
-- ------------------------------------------------------------

function script_description()
  return "配信開始時に YouTube チャンネルの /live ページからタイトルと URL を取得し、\n" ..
    "X (旧Twitter) の投稿作成画面を既定ブラウザで開きます。\n" ..
    "実際の投稿(ツイート)はユーザーが手動で行ってください。\n" ..
    "バージョン " .. VERSION
end

function script_properties()
  local props = obs.obs_properties_create()

  obs.obs_properties_add_text(props, "channel", "YouTube チャンネルの URL", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text(props, "tweet_text", "投稿文", obs.OBS_TEXT_MULTILINE)
  obs.obs_properties_add_bool(props, "include_url", "配信 URL を付ける")
  obs.obs_properties_add_int(props, "retry_interval", "取得の間隔(秒)", 1, 60, 1)
  obs.obs_properties_add_int(props, "timeout", "最大待ち時間(秒)", 10, 600, 1)
  obs.obs_properties_add_bool(props, "fallback_open", "取得できなくても投稿画面を開く")

  obs.obs_properties_add_button(props, "test_button", "テスト: 今すぐ投稿画面を開く", function(properties, property)
    start_resolve(true)
    -- ダイアログを開いたまま押した場合、渡された properties を使ってその場で
    -- ステータス表示を最新化する(グローバルに props への参照を保持しない)。
    local status_prop = obs.obs_properties_get(properties, "status")
    if status_prop then
      obs.obs_property_set_description(status_prop, status_text)
    end
    return true
  end)

  local status_prop = obs.obs_properties_add_text(props, "status", "状態", obs.OBS_TEXT_INFO)
  if status_prop then
    obs.obs_property_set_description(status_prop, status_text)
  end

  return props
end

function script_defaults(settings)
  obs.obs_data_set_default_string(settings, "channel", "")
  obs.obs_data_set_default_string(settings, "tweet_text", DEFAULT_TWEET_TEXT)
  obs.obs_data_set_default_bool(settings, "include_url", true)
  obs.obs_data_set_default_int(settings, "retry_interval", 5)
  obs.obs_data_set_default_int(settings, "timeout", 120)
  obs.obs_data_set_default_bool(settings, "fallback_open", true)
end

function script_update(settings)
  channel = obs.obs_data_get_string(settings, "channel")
  tweet_text = obs.obs_data_get_string(settings, "tweet_text")
  include_url = obs.obs_data_get_bool(settings, "include_url")
  retry_interval = obs.obs_data_get_int(settings, "retry_interval")
  timeout = obs.obs_data_get_int(settings, "timeout")
  fallback_open = obs.obs_data_get_bool(settings, "fallback_open")
end

function script_load(settings)
  settings_ref = settings
  local saved = obs.obs_data_get_string(settings, "last_video_id")
  if saved ~= "" then
    last_video_id = saved
  end
  obs.obs_frontend_add_event_callback(on_frontend_event)
  obs.script_log(obs.LOG_INFO, "youtube_live_tweet v" .. VERSION .. " loaded")
  update_status("待機中")
end

function script_unload()
  obs.timer_remove(poll_tick)
  if current_job then
    cleanup_job_process(current_job)
    current_job = nil
  end
end

-- ------------------------------------------------------------
-- テスト用エクスポート(OBS 実行時は使われない)
-- ------------------------------------------------------------

if _G.__YLT_TEST then
  _G.__YLT = {
    VERSION = VERSION,
    build_live_url = build_live_url,
    parse_live_page = parse_live_page,
    percent_encode = percent_encode,
    build_intent_url = build_intent_url,
    json_unescape = json_unescape,
    extract_balanced_json = extract_balanced_json,
    render_text = render_text,
    curl_exists = curl_exists,
    start_curl_async = start_curl_async,
    is_process_running = is_process_running,
    get_exit_code = get_exit_code,
    ffi_ok = ffi_ok,
    -- 状態機械そのものをテストするためのフック
    start_resolve = start_resolve,
    poll_tick = poll_tick,
    cancel_job = cancel_job,
    get_current_job = function() return current_job end,
    get_status_text = function() return status_text end,
  }
end
