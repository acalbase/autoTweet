<#
  make-release.ps1

  lua/youtube_live_tweet.lua の VERSION を読み取り、
  dist/youtube-live-tweet-v<VERSION>.zip を作成する。
  PowerShell 5.1 互換。

  使い方:
    powershell -File scripts\make-release.ps1
#>

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LuaPath = Join-Path $RepoRoot "lua\youtube_live_tweet.lua"
$ManualPath = Join-Path $RepoRoot "docs\manual.html"
$LicensePath = Join-Path $RepoRoot "LICENSE"
$DistDir = Join-Path $RepoRoot "dist"

if (-not (Test-Path $LuaPath)) {
    throw "lua/youtube_live_tweet.lua が見つかりません: $LuaPath"
}

$luaContent = Get-Content -Path $LuaPath -Raw -Encoding UTF8
$match = [regex]::Match($luaContent, 'local\s+VERSION\s*=\s*"(\d+\.\d+\.\d+)"')
if (-not $match.Success) {
    throw "youtube_live_tweet.lua から VERSION を読み取れませんでした。"
}
$Version = $match.Groups[1].Value
Write-Host "Version: $Version"

if (-not (Test-Path $DistDir)) {
    New-Item -ItemType Directory -Path $DistDir | Out-Null
}

$ZipName = "youtube-live-tweet-v$Version.zip"
$ZipPath = Join-Path $DistDir $ZipName

if (Test-Path $ZipPath) {
    Remove-Item -Path $ZipPath -Force -Confirm:$false
}

# 一時フォルダに集めてから圧縮する(zip 直下にファイルが並ぶようにするため)
$StagingDir = Join-Path $env:TEMP ("ylt-release-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $StagingDir | Out-Null

try {
    Copy-Item -Path $LuaPath -Destination (Join-Path $StagingDir "youtube_live_tweet.lua")
    Copy-Item -Path $ManualPath -Destination (Join-Path $StagingDir "manual.html")
    Copy-Item -Path $LicensePath -Destination (Join-Path $StagingDir "LICENSE")

    $ReadmeLines = @(
        "manual.html を開いて手順に従ってください。",
        "OBS の ツール→スクリプト→＋ で youtube_live_tweet.lua を追加してください。",
        "配布元・最新版: https://github.com/acalbase/autoTweet",
        "ライセンス: MIT",
        ""
    )
    $ReadmeText = $ReadmeLines -join "`r`n"
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText((Join-Path $StagingDir "README.txt"), $ReadmeText, $Utf8Bom)

    Compress-Archive -Path (Join-Path $StagingDir "*") -DestinationPath $ZipPath -Force
}
finally {
    Remove-Item -Path $StagingDir -Recurse -Force -Confirm:$false
}

Write-Host "Created: $ZipPath"
