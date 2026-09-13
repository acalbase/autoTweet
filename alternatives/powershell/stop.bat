@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "$procs = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*-File*YoutubeLiveTweet.ps1*' -and $_.ProcessId -ne $PID }; $count = 0; foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force; $count++ }; Write-Host \"Stopped: $count\""
pause
