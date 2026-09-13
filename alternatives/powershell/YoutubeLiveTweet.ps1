# YoutubeLiveTweet.ps1
#
# OBS で YouTube 配信を開始した瞬間に、配信タイトルと配信URLを埋め込んだ
# X (旧Twitter) の投稿作成画面 (Web Intent) を既定ブラウザで開く。
# Windows 10/11 標準の PowerShell 5.1 のみで動作する(追加インストール不要)。
#
# PowerShell 5.1 互換のため &&, ||, ?:, ??, ?. は使用しない。

param(
    [switch]$Test
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------------------------------------------------
# パス
# ------------------------------------------------------------

$script:ConfigPath = Join-Path $PSScriptRoot 'config.json'
$script:StatePath = Join-Path $PSScriptRoot 'state.json'
$script:LogPath = Join-Path $PSScriptRoot 'live-tweet.log'

# ------------------------------------------------------------
# ログ
# ------------------------------------------------------------

function Invoke-LogRotationIfNeeded {
    try {
        if (Test-Path $script:LogPath) {
            $item = Get-Item $script:LogPath
            if ($item.Length -gt 1MB) {
                $rotated = "$script:LogPath.1"
                if (Test-Path $rotated) {
                    Remove-Item $rotated -Force
                }
                try {
                    Rename-Item -Path $script:LogPath -Destination $rotated -Force -ErrorAction Stop
                } catch {
                    # ローテーション失敗は無視して続行する
                }
            }
        }
    } catch {
        # ローテーションチェック自体の失敗も無視して続行する
    }
}

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [string]$Message
    )
    Invoke-LogRotationIfNeeded
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp [$Level] $Message"
    try {
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    } catch {
        # ログ書き込み失敗は致命的ではないので無視する
    }
    Write-Host $line
}

function Initialize-Log {
    Invoke-LogRotationIfNeeded
}

# ------------------------------------------------------------
# 設定の読み込み・検証
# ------------------------------------------------------------

function Get-ChannelLiveUrl {
    param([string]$Channel)
    $c = $Channel.Trim()
    if ($c.StartsWith('@')) {
        return "https://www.youtube.com/$c/live"
    }
    return "https://www.youtube.com/channel/$c/live"
}

function Get-LiveTweetConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Log -Level ERROR -Message 'config.json が見つかりません。config.example.json をコピーして config.json を作ってください。'
        exit 1
    }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log -Level ERROR -Message "config.json の JSON 解析に失敗しました: $($_.Exception.Message)"
        exit 1
    }

    if ($null -eq $raw.obs) {
        Write-Log -Level ERROR -Message 'config.json に obs がありません。'
        exit 1
    }
    if ($null -eq $raw.tweet) {
        Write-Log -Level ERROR -Message 'config.json に tweet がありません。'
        exit 1
    }
    if ($null -eq $raw.resolve) {
        Write-Log -Level ERROR -Message 'config.json に resolve がありません。'
        exit 1
    }
    if ($null -eq $raw.youtube -or [string]::IsNullOrWhiteSpace([string]$raw.youtube.channel)) {
        Write-Log -Level ERROR -Message 'config.json に youtube.channel がありません。'
        exit 1
    }

    $channel = [string]$raw.youtube.channel
    if (-not ($channel.StartsWith('@') -or $channel.StartsWith('UC'))) {
        Write-Log -Level ERROR -Message "youtube.channel の形式が不正です: $channel (@handle 形式または UC... のチャンネルID形式を指定してください)"
        exit 1
    }

    $obsHost = 'localhost'
    if ($raw.obs.host) { $obsHost = [string]$raw.obs.host }

    $obsPort = 4455
    if ($null -ne $raw.obs.port) {
        try {
            $obsPort = [int]$raw.obs.port
        } catch {
            Write-Log -Level ERROR -Message "obs.port は整数で指定してください: $($raw.obs.port)"
            exit 1
        }
    }
    if ($obsPort -lt 1 -or $obsPort -gt 65535) {
        Write-Log -Level ERROR -Message "obs.port は 1〜65535 の整数で指定してください: $obsPort"
        exit 1
    }

    $obsPassword = ''
    if ($raw.obs.password) { $obsPassword = [string]$raw.obs.password }

    $tweetText = '{title}'
    if ($null -ne $raw.tweet.text) { $tweetText = [string]$raw.tweet.text }

    $includeUrl = $true
    if ($null -ne $raw.tweet.include_url) {
        if ($raw.tweet.include_url -isnot [bool]) {
            Write-Log -Level ERROR -Message 'tweet.include_url は true/false で指定してください。'
            exit 1
        }
        $includeUrl = [bool]$raw.tweet.include_url
    }

    $retryIntervalSec = 5
    if ($null -ne $raw.resolve.retry_interval_sec) {
        try {
            $retryIntervalSec = [int]$raw.resolve.retry_interval_sec
        } catch {
            Write-Log -Level ERROR -Message "resolve.retry_interval_sec は整数で指定してください: $($raw.resolve.retry_interval_sec)"
            exit 1
        }
    }
    if ($retryIntervalSec -lt 1) {
        Write-Log -Level ERROR -Message 'resolve.retry_interval_sec は 1 以上の整数で指定してください。'
        exit 1
    }

    $timeoutSec = 120
    if ($null -ne $raw.resolve.timeout_sec) {
        try {
            $timeoutSec = [int]$raw.resolve.timeout_sec
        } catch {
            Write-Log -Level ERROR -Message "resolve.timeout_sec は整数で指定してください: $($raw.resolve.timeout_sec)"
            exit 1
        }
    }
    if ($timeoutSec -lt 1) {
        Write-Log -Level ERROR -Message 'resolve.timeout_sec は 1 以上の整数で指定してください。'
        exit 1
    }

    $fallbackOpenWhenUnresolved = $true
    if ($null -ne $raw.fallback_open_when_unresolved) {
        if ($raw.fallback_open_when_unresolved -isnot [bool]) {
            Write-Log -Level ERROR -Message 'fallback_open_when_unresolved は true/false で指定してください。'
            exit 1
        }
        $fallbackOpenWhenUnresolved = [bool]$raw.fallback_open_when_unresolved
    }

    return @{
        Obs                        = @{
            Host     = $obsHost
            Port     = $obsPort
            Password = $obsPassword
        }
        Channel                    = $channel
        ChannelLiveUrl             = Get-ChannelLiveUrl -Channel $channel
        TweetText                  = $tweetText
        IncludeUrl                 = $includeUrl
        RetryIntervalSec           = $retryIntervalSec
        TimeoutSec                 = $timeoutSec
        FallbackOpenWhenUnresolved = $fallbackOpenWhenUnresolved
    }
}

# ------------------------------------------------------------
# YouTube 取得
# ------------------------------------------------------------

$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$script:PlayerResponseMarker = 'ytInitialPlayerResponse = '

function Get-BalancedJson {
    param(
        [string]$Text,
        [int]$Start
    )
    if ($Start -ge $Text.Length -or $Text[$Start] -ne '{') {
        return $null
    }

    $depth = 0
    $inString = $false
    $escape = $false
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inString) {
            if ($escape) {
                $escape = $false
            } elseif ($ch -eq '\') {
                $escape = $true
            } elseif ($ch -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($ch -eq '"') {
            $inString = $true
        } elseif ($ch -eq '{') {
            $depth++
        } elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($Start, $i - $Start + 1)
            }
        }
    }
    return $null
}

function Get-LiveInfoFallback {
    param([string]$HtmlText)

    $videoDetailsPos = $HtmlText.IndexOf('"videoDetails":{')
    if ($videoDetailsPos -lt 0) {
        return $null
    }

    $windowEnd = [Math]::Min($HtmlText.Length, $videoDetailsPos + 2000)
    $window = $HtmlText.Substring($videoDetailsPos, $windowEnd - $videoDetailsPos)

    if ($window -notmatch '"isLive"\s*:\s*true') {
        return $null
    }

    $videoIdMatch = [regex]::Match($window, '"videoId"\s*:\s*"([^"]+)"')
    if (-not $videoIdMatch.Success) {
        return $null
    }
    $videoId = $videoIdMatch.Groups[1].Value

    $title = ''
    $titleMatch = [regex]::Match($HtmlText, '<meta\s+name="title"\s+content="([^"]*)"')
    if ($titleMatch.Success) {
        $title = [System.Net.WebUtility]::HtmlDecode($titleMatch.Groups[1].Value)
    }

    return @{
        VideoId = $videoId
        Title   = $title
        Url     = "https://www.youtube.com/watch?v=$videoId"
    }
}

function Resolve-Live {
    param([string]$ChannelLiveUrl)

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $cookie = New-Object System.Net.Cookie('CONSENT', 'YES+cb', '/', '.youtube.com')
    $session.Cookies.Add($cookie)

    try {
        $resp = Invoke-WebRequest -Uri $ChannelLiveUrl -UseBasicParsing -TimeoutSec 15 `
            -UserAgent $script:UserAgent `
            -Headers @{ 'Accept-Language' = 'ja,en;q=0.8' } `
            -WebSession $session
    } catch {
        Write-Log -Level WARN -Message "YouTube /live の取得に失敗しました: $($_.Exception.Message)"
        return $null
    }

    $htmlText = $resp.Content

    $markerPos = $htmlText.IndexOf($script:PlayerResponseMarker)
    if ($markerPos -ge 0) {
        $jsonStart = $markerPos + $script:PlayerResponseMarker.Length
        $jsonText = Get-BalancedJson -Text $htmlText -Start $jsonStart
        if ($jsonText) {
            try {
                $playerResponse = $jsonText | ConvertFrom-Json
                $videoDetails = $playerResponse.videoDetails
                if ($null -eq $videoDetails) {
                    return $null
                }
                if ($videoDetails.isLive -ne $true) {
                    return $null
                }
                $videoId = $videoDetails.videoId
                if (-not $videoId) {
                    return $null
                }
                $title = ''
                if ($videoDetails.title) { $title = [string]$videoDetails.title }
                return @{
                    VideoId = $videoId
                    Title   = $title
                    Url     = "https://www.youtube.com/watch?v=$videoId"
                }
            } catch {
                Write-Log -Level INFO -Message "ytInitialPlayerResponse の解析に失敗したため正規表現フォールバックを使います: $($_.Exception.Message)"
                return Get-LiveInfoFallback -HtmlText $htmlText
            }
        }
    }

    Write-Log -Level INFO -Message 'ytInitialPlayerResponse を利用できないため正規表現フォールバックを使います。'
    return Get-LiveInfoFallback -HtmlText $htmlText
}

function Wait-ForLive {
    param(
        [string]$ChannelLiveUrl,
        [int]$RetryIntervalSec,
        [int]$TimeoutSec
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $info = Resolve-Live -ChannelLiveUrl $ChannelLiveUrl
        if ($info) {
            return $info
        }
        if ((Get-Date) -ge $deadline) {
            Write-Log -Level WARN -Message "timeout_sec ($TimeoutSec 秒) 以内にライブ情報を取得できませんでした。"
            return $null
        }
        Start-Sleep -Seconds $RetryIntervalSec
    }
}

# ------------------------------------------------------------
# X Web Intent
# ------------------------------------------------------------

function New-IntentUrl {
    param(
        [string]$Text,
        [string]$Url
    )
    $result = 'https://x.com/intent/post?text=' + [Uri]::EscapeDataString($Text)
    if ($Url) {
        $result += '&url=' + [Uri]::EscapeDataString($Url)
    }
    return $result
}

function Open-Intent {
    param([string]$IntentUrl)
    Write-Log -Level INFO -Message "Intent URL: $IntentUrl"
    Start-Process $IntentUrl
}

# ------------------------------------------------------------
# state.json
# ------------------------------------------------------------

function Get-LastVideoId {
    if (-not (Test-Path $script:StatePath)) {
        return $null
    }
    try {
        $state = Get-Content -Path $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return $state.last_video_id
    } catch {
        Write-Log -Level WARN -Message "state.json の読み込みに失敗しました: $($_.Exception.Message)"
        return $null
    }
}

function Set-LastVideoId {
    param([string]$VideoId)
    try {
        (@{ last_video_id = $VideoId } | ConvertTo-Json) | Set-Content -Path $script:StatePath -Encoding UTF8
    } catch {
        Write-Log -Level WARN -Message "state.json の保存に失敗しました: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 投稿処理
# ------------------------------------------------------------

$script:Processing = $false

function Invoke-StreamStarted {
    param(
        $Config,
        [switch]$SkipStateCheck
    )

    if ($script:Processing) {
        Write-Log -Level INFO -Message '処理中のため今回のイベントは無視します。'
        return
    }
    $script:Processing = $true
    try {
        try {
            Write-Log -Level INFO -Message 'ライブ情報の取得を開始します...'
            $info = Wait-ForLive -ChannelLiveUrl $Config.ChannelLiveUrl -RetryIntervalSec $Config.RetryIntervalSec -TimeoutSec $Config.TimeoutSec

            if ($info) {
                if (-not $SkipStateCheck) {
                    $lastVideoId = Get-LastVideoId
                    if ($lastVideoId -and ($lastVideoId -eq $info.VideoId)) {
                        Write-Log -Level INFO -Message "同じ配信のため開きません (video_id=$($info.VideoId))"
                        return
                    }
                }

                $text = $Config.TweetText.Replace('{title}', $info.Title).Replace('{url}', $info.Url)
                $url = $null
                if ($Config.IncludeUrl) { $url = $info.Url }
                $intentUrl = New-IntentUrl -Text $text -Url $url
                Open-Intent -IntentUrl $intentUrl
                Set-LastVideoId -VideoId $info.VideoId
                return
            }

            if ($Config.FallbackOpenWhenUnresolved) {
                Write-Log -Level WARN -Message 'ライブ情報を取得できなかったため fallback で投稿画面を開きます。'
                $text = $Config.TweetText.Replace('{title}', '').Replace('{url}', $Config.ChannelLiveUrl)
                $url = $null
                if ($Config.IncludeUrl) { $url = $Config.ChannelLiveUrl }
                $intentUrl = New-IntentUrl -Text $text -Url $url
                Open-Intent -IntentUrl $intentUrl
            } else {
                Write-Log -Level WARN -Message 'ライブ情報を取得できませんでした。fallback_open_when_unresolved が false のため何もしません。'
            }
        } catch {
            Write-Log -Level ERROR -Message "配信開始処理中にエラーが発生しました: $($_.Exception.Message)"
        }
    } finally {
        $script:Processing = $false
    }
}

# ------------------------------------------------------------
# OBS WebSocket v5 クライアント
# ------------------------------------------------------------

$script:LastCloseStatus = $null

function Receive-WsMessage {
    param([System.Net.WebSockets.ClientWebSocket]$Ws)

    $buffer = New-Object byte[] 8192
    $segment = New-Object System.ArraySegment[byte] (, $buffer)
    $ms = New-Object System.IO.MemoryStream
    try {
        while ($true) {
            $task = $Ws.ReceiveAsync($segment, [System.Threading.CancellationToken]::None)
            while (-not $task.IsCompleted) {
                Start-Sleep -Milliseconds 100
            }
            if ($task.Exception) {
                throw $task.Exception
            }
            $result = $task.Result

            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                $script:LastCloseStatus = $result.CloseStatus
                return $null
            }

            $ms.Write($buffer, 0, $result.Count)

            if ($result.EndOfMessage) {
                break
            }
        }
        return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    } finally {
        $ms.Dispose()
    }
}

function Send-WsMessage {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Ws,
        [string]$Json
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $segment = New-Object System.ArraySegment[byte] (, $bytes)
    $task = $Ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
    while (-not $task.IsCompleted) {
        Start-Sleep -Milliseconds 100
    }
    if ($task.Exception) {
        throw $task.Exception
    }
}

function Get-ObsAuthString {
    param(
        [string]$Password,
        [string]$Salt,
        [string]$Challenge
    )
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $secretBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Password + $Salt))
        $secret = [Convert]::ToBase64String($secretBytes)
        $authBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($secret + $Challenge))
        return [Convert]::ToBase64String($authBytes)
    } finally {
        $sha256.Dispose()
    }
}

function Start-ObsWatch {
    param($Config)

    while ($true) {
        $ws = $null
        try {
            Write-Log -Level INFO -Message "OBS WebSocket に接続しています... ($($Config.Obs.Host):$($Config.Obs.Port))"
            $ws = New-Object System.Net.WebSockets.ClientWebSocket
            $uri = New-Object Uri("ws://$($Config.Obs.Host):$($Config.Obs.Port)/")
            $connectTask = $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
            while (-not $connectTask.IsCompleted) {
                Start-Sleep -Milliseconds 100
            }
            if ($connectTask.Exception) {
                throw $connectTask.Exception
            }
            if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                throw (New-Object Exception('OBS WebSocket への接続に失敗しました。'))
            }

            # Hello (op=0)
            $script:LastCloseStatus = $null
            $helloRaw = Receive-WsMessage -Ws $ws
            if (-not $helloRaw) {
                throw (New-Object Exception('Hello を受信できませんでした。'))
            }
            $hello = $helloRaw | ConvertFrom-Json

            $authField = $null
            if ($hello.d.authentication) {
                $challenge = $hello.d.authentication.challenge
                $salt = $hello.d.authentication.salt
                if (-not $Config.Obs.Password) {
                    Write-Log -Level ERROR -Message 'OBS 側で認証が有効です。config の obs.password を設定してください。'
                } else {
                    $authField = Get-ObsAuthString -Password $Config.Obs.Password -Salt $salt -Challenge $challenge
                }
            }

            $identifyData = @{
                rpcVersion        = 1
                eventSubscriptions = 64
            }
            if ($authField) {
                $identifyData.authentication = $authField
            }
            $identifyMsg = @{ op = 1; d = $identifyData }
            $identifyJson = $identifyMsg | ConvertTo-Json -Compress -Depth 5
            Send-WsMessage -Ws $ws -Json $identifyJson

            $script:LastCloseStatus = $null
            $identifiedRaw = Receive-WsMessage -Ws $ws
            if (-not $identifiedRaw) {
                if ([int]$script:LastCloseStatus -eq 4009) {
                    Write-Log -Level WARN -Message 'OBS 側で認証に失敗しました (close code 4009)。config の obs.password を確認してください。'
                } else {
                    Write-Log -Level WARN -Message "Identify に失敗しました (close code=$($script:LastCloseStatus))。"
                }
                throw (New-Object Exception('Identify に失敗しました。'))
            }
            $identified = $identifiedRaw | ConvertFrom-Json
            if ($identified.op -ne 2) {
                throw (New-Object Exception("Identified 以外の応答を受信しました (op=$($identified.op))"))
            }
            Write-Log -Level INFO -Message '接続完了 (OBS WebSocket に接続し、認証・Identify が完了しました)。'

            $alreadyStarted = $false
            while ($true) {
                $script:LastCloseStatus = $null
                $msgRaw = Receive-WsMessage -Ws $ws
                if (-not $msgRaw) {
                    Write-Log -Level WARN -Message '接続が切れました → 再接続します。'
                    break
                }

                $msg = $msgRaw | ConvertFrom-Json
                if (($msg.op -eq 5) -and ($msg.d.eventType -eq 'StreamStateChanged')) {
                    $outputActive = [bool]$msg.d.eventData.outputActive
                    $outputState = $msg.d.eventData.outputState
                    Write-Log -Level INFO -Message "StreamStateChanged outputActive=$outputActive outputState=$outputState"

                    if ($outputActive -and (-not $alreadyStarted)) {
                        Write-Log -Level INFO -Message '配信開始を検知しました。'
                        Invoke-StreamStarted -Config $Config
                    }
                    $alreadyStarted = $outputActive
                }
            }
        } catch {
            Write-Log -Level WARN -Message "OBS WebSocket に接続できません: $($_.Exception.Message)"
        } finally {
            if ($ws) {
                try { $ws.Dispose() } catch {}
            }
        }
        Start-Sleep -Seconds 10
    }
}

# ------------------------------------------------------------
# エントリポイント
# ------------------------------------------------------------

function Start-Main {
    Initialize-Log

    $script:Mutex = $null
    if (-not $Test) {
        $script:Mutex = New-Object System.Threading.Mutex($false, 'Global\YoutubeLiveTweet')
        if (-not $script:Mutex.WaitOne(0)) {
            Write-Log -Level WARN -Message 'すでに起動しています。終了します。'
            exit 2
        }
    }

    try {
        $config = Get-LiveTweetConfig -Path $script:ConfigPath

        if ($Test) {
            Write-Log -Level INFO -Message '-Test モード: OBS には接続せず、今すぐライブ情報の取得を試みます。'
            Invoke-StreamStarted -Config $config -SkipStateCheck
        } else {
            Write-Log -Level INFO -Message 'OBS の監視を開始します。Ctrl+C で終了します。'
            Start-ObsWatch -Config $config
        }
    } finally {
        if ($script:Mutex) {
            try {
                $script:Mutex.ReleaseMutex()
            } catch {}
            $script:Mutex.Dispose()
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-Main
}
