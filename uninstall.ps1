# Claude Usage Widget - Windows アンインストーラー
# スタートアップショートカットと ~/.claude-usage-widget/ を削除する。

$ErrorActionPreference = "Stop"

$WidgetHome = Join-Path $env:USERPROFILE ".claude-usage-widget"
$StartupFolder = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupFolder "Claude Usage Widget.lnk"

Write-Host "Claude Usage Widget アンインストーラー" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# 1. 実行中のプロセスを停止
$running = Get-Process powershell -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*claude-usage.ps1*" -and $_.Id -ne $PID }
if ($running) {
    $running | Stop-Process -Force
    Write-Host "[OK] 実行中のウィジェットを停止しました" -ForegroundColor Green
}

# 2. スタートアップショートカット削除
if (Test-Path $ShortcutPath) {
    Remove-Item $ShortcutPath -Force
    Write-Host "[OK] スタートアップ登録を解除しました" -ForegroundColor Green
} else {
    Write-Host "[SKIP] スタートアップショートカットは存在しません" -ForegroundColor Gray
}

# 3. ウィジェットホーム削除
if (Test-Path $WidgetHome) {
    Remove-Item $WidgetHome -Recurse -Force
    Write-Host "[OK] $WidgetHome を削除しました" -ForegroundColor Green
} else {
    Write-Host "[SKIP] $WidgetHome は存在しません" -ForegroundColor Gray
}

Write-Host ""
Write-Host "アンインストール完了!" -ForegroundColor Green
