# Claude Usage Widget - Windows インストーラー
# ~/.claude-usage-widget/ にスクリプトを配置し、スタートアップに登録する。

$ErrorActionPreference = "Stop"

$WidgetHome = Join-Path $env:USERPROFILE ".claude-usage-widget"
$SourceScript = Join-Path $PSScriptRoot "windows\claude-usage.ps1"
$DestScript = Join-Path $WidgetHome "claude-usage.ps1"
$StartupFolder = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupFolder "Claude Usage Widget.lnk"

Write-Host "Claude Usage Widget インストーラー" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""

# 1. ソースファイル確認
if (-not (Test-Path $SourceScript)) {
    Write-Host "[ERROR] $SourceScript が見つかりません。" -ForegroundColor Red
    Write-Host "リポジトリのルートから実行してください: .\install.ps1" -ForegroundColor Yellow
    exit 1
}

# 2. 認証情報の確認
$CredFile = Join-Path $env:USERPROFILE ".claude\.credentials.json"
if (-not (Test-Path $CredFile)) {
    Write-Host "[WARNING] $CredFile が見つかりません。" -ForegroundColor Yellow
    Write-Host "Claude Code を一度起動してログインしてください。" -ForegroundColor Yellow
    Write-Host "インストールは続行しますが、ウィジェットはログイン後に動作します。" -ForegroundColor Yellow
    Write-Host ""
}

# 3. ウィジェットホーム作成
if (-not (Test-Path $WidgetHome)) {
    New-Item -ItemType Directory -Path $WidgetHome -Force | Out-Null
    Write-Host "[OK] $WidgetHome を作成しました" -ForegroundColor Green
}

# 4. スクリプトコピー
Copy-Item $SourceScript $DestScript -Force
Write-Host "[OK] claude-usage.ps1 を配置しました" -ForegroundColor Green

# 5. スタートアップショートカット作成
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$DestScript`""
$Shortcut.WorkingDirectory = $WidgetHome
$Shortcut.WindowStyle = 7  # Minimized
$Shortcut.Description = "Claude Code Usage Widget"
$Shortcut.Save()
Write-Host "[OK] スタートアップに登録しました: $ShortcutPath" -ForegroundColor Green

Write-Host ""
Write-Host "インストール完了!" -ForegroundColor Green
Write-Host ""
Write-Host "今すぐ起動するには:" -ForegroundColor Cyan
Write-Host "  powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$DestScript`"" -ForegroundColor White
Write-Host ""
Write-Host "次回ログイン時から自動起動します。" -ForegroundColor Gray
