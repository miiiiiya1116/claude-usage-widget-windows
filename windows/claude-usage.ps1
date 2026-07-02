# Claude Code 使用状況ウィジェット (Windows / PowerShell + WPF)
# システムトレイに使用率(%)を常時表示し、トレイアイコンのクリックで詳細パネルを開閉する。
# 追加インストール不要（Windows 標準の PowerShell 5.1 + .NET Framework で動作）。

# --- 設定 ---
$PANEL_WIDTH    = 320
$MARGIN         = 8
$MARGIN_RIGHT   = 8
$WARN           = 80
$DANGER         = 95
$REFRESH_INTERVAL_SEC = 30
$OK_INTERVAL_SEC      = 300
$BACKOFF_SEC          = 900

$WIDGET_HOME = Join-Path $env:USERPROFILE ".claude-usage-widget"
$CACHE_FILE  = Join-Path $WIDGET_HOME "usage.json"
$POS_FILE    = Join-Path $WIDGET_HOME "position.json"
$CRED_FILE   = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$ENDPOINT    = "https://api.anthropic.com/api/oauth/usage"

if (-not (Test-Path $WIDGET_HOME)) { New-Item -ItemType Directory -Path $WIDGET_HOME -Force | Out-Null }

# --- 多重起動防止 ---
# 1) 自分以外の claude-usage.ps1 プロセスを先に停止（古いコードで動いているものも含め確実に掃除）
try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*claude-usage.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

# 2) 名前付き Mutex で排他制御（同時起動のレースコンディションも防ぐ）
$script:widgetMutex = [System.Threading.Mutex]::new($false, "Global\ClaudeUsageWidget")
if (-not $script:widgetMutex.WaitOne(3000)) {
    # 3秒待っても取れなければ諦めて終了
    $script:widgetMutex.Dispose()
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ([System.Management.Automation.PSTypeName]"ClaudeUsageNativeIcon").Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ClaudeUsageNativeIcon {
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@
}

# --- トークン読み取り ---
function Get-OAuthToken {
    if (-not (Test-Path $CRED_FILE)) { return $null }
    try {
        $json = Get-Content $CRED_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
        $tok = $null
        if ($json.claudeAiOauth -and $json.claudeAiOauth.accessToken) {
            $tok = $json.claudeAiOauth.accessToken
        }
        elseif ($json.accessToken) {
            $tok = $json.accessToken
        }
        return $tok
    }
    catch {
        return $null
    }
}

# --- API 取得 ---
function Fetch-Usage {
    param([switch]$Force)
    $now = [DateTimeOffset]::UtcNow
    $cache = Load-Cache

    # スロットリング（$Force 時はスキップ）
    if (-not $Force -and $cache -and $cache.next_fetch_after) {
        try {
            $nextFetch = [DateTimeOffset]::Parse($cache.next_fetch_after)
            if ($now -lt $nextFetch) { return $cache }
        }
        catch {}
    }

    $token = Get-OAuthToken
    if (-not $token) {
        $result = New-EmptyCache
        $result.ok = $false
        $result.error = "no_credentials"
        $result.next_fetch_after = $now.AddSeconds($OK_INTERVAL_SEC).ToString("o")
        if ($cache) {
            $result.session = $cache.session
            $result.weekly = $cache.weekly
            $result.weekly_opus = $cache.weekly_opus
            $result.weekly_sonnet = $cache.weekly_sonnet
            $result.fetched_at = $cache.fetched_at
            $result.stale = $true
        }
        Save-Cache $result
        return $result
    }

    try {
        $headers = @{
            "Authorization"  = "Bearer $token"
            "anthropic-beta" = "oauth-2025-04-20"
        }
        $webResp = Invoke-WebRequest -Uri $ENDPOINT -Headers $headers -Method Get -UseBasicParsing -ErrorAction Stop
        $response = $webResp.Content | ConvertFrom-Json

        $result = @{
            ok               = $true
            stale            = $false
            error            = $null
            fetched_at       = $now.ToString("o")
            next_fetch_after = $now.AddSeconds($OK_INTERVAL_SEC).ToString("o")
            session          = Format-Slot $response.five_hour
            weekly           = Format-Slot $response.seven_day
            weekly_opus      = Format-Slot $response.seven_day_opus
            weekly_sonnet    = Format-Slot $response.seven_day_sonnet
        }
        Save-Cache $result
        return $result
    }
    catch {
        $statusCode = 0
        $retryAfter = 0
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $raHeader = $_.Exception.Response.Headers["Retry-After"]
                if ($raHeader) { $retryAfter = [int]$raHeader }
            } catch {}
        }

        $backoff = $OK_INTERVAL_SEC
        $errMsg = "network: " + $_.Exception.Message
        if ($statusCode -eq 429) {
            if ($retryAfter -gt 0) {
                $backoff = $retryAfter + 5
            } elseif ($cache -and $cache.fetched_at) {
                $backoff = $BACKOFF_SEC
            } else {
                $backoff = 120
            }
            $errMsg = "rate_limited(429)"
        }
        elseif ($statusCode -gt 0) {
            $errMsg = "http_$statusCode"
        }

        $result = New-EmptyCache
        $result.error = $errMsg
        $result.next_fetch_after = $now.AddSeconds($backoff).ToString("o")
        if ($cache) {
            $result.ok = $cache.ok
            $result.session = $cache.session
            $result.weekly = $cache.weekly
            $result.weekly_opus = $cache.weekly_opus
            $result.weekly_sonnet = $cache.weekly_sonnet
            $result.fetched_at = $cache.fetched_at
            $result.stale = $true
        }
        Save-Cache $result
        return $result
    }
}

function Format-Slot($raw) {
    if (-not $raw) { return $null }
    if ($null -eq $raw.utilization) { return $null }
    return @{ pct = [double]$raw.utilization; resets_at = $raw.resets_at }
}

function New-EmptyCache {
    return @{
        ok = $false; stale = $false; error = $null
        fetched_at = $null; next_fetch_after = $null
        session = $null; weekly = $null; weekly_opus = $null; weekly_sonnet = $null
    }
}

function Load-Cache {
    if (-not (Test-Path $CACHE_FILE)) { return $null }
    try { return Get-Content $CACHE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Save-Cache($data) {
    try { $data | ConvertTo-Json -Depth 4 | Set-Content $CACHE_FILE -Encoding UTF8 }
    catch {}
}

# --- 位置管理 ---
function Load-Position {
    if (Test-Path $POS_FILE) {
        try {
            $p = Get-Content $POS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $p.x -and $null -ne $p.y) {
                $minimized = $false
                if ($null -ne $p.minimized) { $minimized = [bool]$p.minimized }
                return @{ x = [int]$p.x; y = [int]$p.y; minimized = $minimized }
            }
        }
        catch {}
    }
    return Get-InitialPosition
}

function Get-InitialPosition {
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $x = [Math]::Max($workArea.Left, $workArea.Right - $PANEL_WIDTH - $MARGIN_RIGHT)
    $y = $workArea.Top + $MARGIN
    return @{ x = [int]$x; y = [int]$y; minimized = $false }
}

function Save-Position($pos) {
    try {
        $payload = @{
            x = [int]$pos.x
            y = [int]$pos.y
            minimized = [bool]$pos.minimized
        }
        $payload | ConvertTo-Json | Set-Content $POS_FILE -Encoding UTF8
    }
    catch {}
}

# --- 表示ヘルパー ---
function Get-BarColor($pct) {
    if ($pct -ge $DANGER) { return "#FFFF5A52" }
    if ($pct -ge $WARN)   { return "#FFFFAE42" }
    return "#FF4A8CFF"
}

function Get-Countdown($resetsAt) {
    if (-not $resetsAt) { return [string][char]0x2014 }
    try {
        $diff = [DateTimeOffset]::Parse($resetsAt) - [DateTimeOffset]::Now
        if ($diff.TotalSeconds -le 0) { return [string]([char]0x307E + [char]0x3082 + [char]0x306A + [char]0x304F + [char]0x30EA + [char]0x30BB + [char]0x30C3 + [char]0x30C8) }
        $h = [Math]::Floor($diff.TotalHours)
        $m = $diff.Minutes
        if ($h -gt 0) { return ($([char]0x3042) + [string]([char]0x3068) + " " + $h + [string]([char]0x6642) + [string]([char]0x9593) + $m + [string]([char]0x5206)) }
        return ($([char]0x3042) + [string]([char]0x3068) + " " + $m + [string]([char]0x5206))
    }
    catch { return [string][char]0x2014 }
}

function Get-ResetClock($resetsAt) {
    if (-not $resetsAt) { return [string][char]0x2014 }
    try {
        $d = [DateTimeOffset]::Parse($resetsAt).LocalDateTime
        $wdNames = @([string][char]0x65E5, [string][char]0x6708, [string][char]0x706B, [string][char]0x6C34, [string][char]0x6728, [string][char]0x91D1, [string][char]0x571F)
        $wd = $wdNames[[int]$d.DayOfWeek]
        $min = $d.Minute.ToString("D2")
        return ("{0}/{1}({2}) {3}:{4} " -f $d.Month, $d.Day, $wd, $d.Hour, $min) + [string]([char]0x30EA + [char]0x30BB + [char]0x30C3 + [char]0x30C8)
    }
    catch { return [string][char]0x2014 }
}

# --- トレイアイコン描画 ---
function ConvertTo-DrawingColor($argbHex) {
    $h = $argbHex.TrimStart('#')
    $a = [Convert]::ToInt32($h.Substring(0, 2), 16)
    $r = [Convert]::ToInt32($h.Substring(2, 2), 16)
    $g = [Convert]::ToInt32($h.Substring(4, 2), 16)
    $b = [Convert]::ToInt32($h.Substring(6, 2), 16)
    return [System.Drawing.Color]::FromArgb($a, $r, $g, $b)
}

function New-TrayIcon($text, $argbHex) {
    $size = 32
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
            $g.Clear([System.Drawing.Color]::Transparent)
            $bgColor = ConvertTo-DrawingColor $argbHex
            $brush = New-Object System.Drawing.SolidBrush($bgColor)
            $g.FillEllipse($brush, 0, 0, $size, $size)

            # トレイアイコンは実際には16px前後に縮小されて表示されるため、
            # 32px canvas 上でも縮小後に欠けないようテキスト幅を測って収まる最大フォントサイズを選ぶ
            $fmt = New-Object System.Drawing.StringFormat
            $fmt.Alignment = [System.Drawing.StringAlignment]::Center
            $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
            $maxWidth = $size - ($size * 0.10)
            $font = $null
            for ($fs = [Math]::Ceiling($size * 0.85); $fs -ge 5; $fs--) {
                $candidate = New-Object System.Drawing.Font("Segoe UI", $fs, [System.Drawing.FontStyle]::Bold)
                $measured = $g.MeasureString($text, $candidate)
                if ($measured.Width -le $maxWidth) {
                    $font = $candidate
                    break
                }
                $candidate.Dispose()
            }
            if (-not $font) { $font = New-Object System.Drawing.Font("Segoe UI", 5, [System.Drawing.FontStyle]::Bold) }

            $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
            $g.DrawString($text, $font, [System.Drawing.Brushes]::White, $rect, $fmt)
            $font.Dispose()
            $brush.Dispose()
        }
        finally { $g.Dispose() }

        $hIcon = $bmp.GetHicon()
        try {
            $tempIcon = [System.Drawing.Icon]::FromHandle($hIcon)
            $ownedIcon = $tempIcon.Clone()
            $tempIcon.Dispose()
            return $ownedIcon
        }
        finally {
            [ClaudeUsageNativeIcon]::DestroyIcon($hIcon) | Out-Null
        }
    }
    finally {
        $bmp.Dispose()
    }
}

function Update-TrayIcon($sessionSlot) {
    if (-not $script:trayIcon) { return }
    $text = [string][char]0x3F
    $argbHex = "#FF808080"
    if ($sessionSlot -and $null -ne $sessionSlot.pct) {
        $pctVal = [Math]::Round([double]$sessionSlot.pct)
        $text = [string]$pctVal
        $argbHex = Get-BarColor $pctVal
    }
    $newIcon = New-TrayIcon $text $argbHex
    $oldIcon = $script:trayIcon.Icon
    $script:trayIcon.Icon = $newIcon
    if ($oldIcon) { $oldIcon.Dispose() }
}

function Update-TrayTooltip($data) {
    if (-not $script:trayIcon) { return }
    $lines = @("Claude")
    if ($data -and $data.session -and $null -ne $data.session.pct) {
        $sessionLine = [string]([char]0x30BB + [char]0x30C3 + [char]0x30B7 + [char]0x30E7 + [char]0x30F3) + " " + [Math]::Round([double]$data.session.pct) + "%"
        if ($data.session.resets_at) {
            $sessionLine += [string]([char]0xFF08) + (Get-Countdown $data.session.resets_at) + [string]([char]0xFF09)
        }
        $lines += $sessionLine
    }
    if ($data -and $data.weekly -and $null -ne $data.weekly.pct) {
        $lines += ([string]([char]0x9031 + [char]0x9593) + " " + [Math]::Round([double]$data.weekly.pct) + "%")
    }
    if ($data -and $data.weekly_opus -and $null -ne $data.weekly_opus.pct) {
        $lines += ("Opus " + [Math]::Round([double]$data.weekly_opus.pct) + "%")
    }
    $text = ($lines -join "`n")
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $script:trayIcon.Text = $text
}

function Sync-TrayIcon($data) {
    $sessionSlot = $null
    if ($data -and $data.session) { $sessionSlot = $data.session }
    Update-TrayIcon $sessionSlot
    Update-TrayTooltip $data
}

# --- WPF UI 構築 ---
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Usage Widget"
        WindowStyle="None" AllowsTransparency="True" Topmost="True"
        ShowInTaskbar="False" ResizeMode="NoResize"
        Width="320" SizeToContent="Height"
        Background="Transparent">
    <Border Name="PanelBorder" CornerRadius="10"
            Background="#D01C1C1E" BorderBrush="#14FFFFFF" BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="24" ShadowDepth="6" Opacity="0.35" Color="Black"/>
        </Border.Effect>
        <StackPanel Margin="12,8,12,8">
            <Grid Name="Header" Margin="0,0,0,6" Cursor="SizeAll">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="TitleText" Grid.Column="0"
                           Text="CLAUDE" FontSize="11" FontWeight="Bold"
                           Foreground="#D9E8E8EA" VerticalAlignment="Center"/>
                <TextBlock Name="MiniTotalText" Grid.Column="1"
                           Text="" FontSize="11" FontWeight="SemiBold"
                           Foreground="#D9E8E8EA" VerticalAlignment="Center"
                           Margin="8,0,0,0" Visibility="Collapsed"/>
                <TextBlock Name="MinimizeBtn" Grid.Column="2"
                           Text="-" FontSize="12" FontWeight="Bold"
                           Foreground="#99E8E8EA" VerticalAlignment="Center"
                           Margin="8,0,0,0" Cursor="Hand" ToolTip="最小化"/>
                <TextBlock Name="StatusText" Grid.Column="3"
                           Text="" FontSize="10" Foreground="#80E8E8EA"
                           VerticalAlignment="Center" Margin="8,0,0,0"/>
            </Grid>
            <StackPanel Name="DetailPanel">
            <Grid Margin="0,0,0,2">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="SessionLabel" Grid.Column="0"
                           FontSize="12" FontWeight="SemiBold" Foreground="#E8E8EA"/>
                <TextBlock Name="SessionPct" Grid.Column="1"
                           FontSize="12" Foreground="#D9E8E8EA"/>
            </Grid>
            <Border Height="5" CornerRadius="2.5" Background="#24FFFFFF" Margin="0,0,0,2">
                <Border Name="SessionBar" Height="5" CornerRadius="2.5"
                        Background="#FF4A8CFF" HorizontalAlignment="Left" Width="0"/>
            </Border>
            <TextBlock Name="SessionSub" FontSize="11" Foreground="#99E8E8EA" Margin="0,0,0,6"/>
            <Grid Margin="0,0,0,2">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="WeeklyLabel" Grid.Column="0"
                           FontSize="12" FontWeight="SemiBold" Foreground="#E8E8EA"/>
                <TextBlock Name="WeeklyPct" Grid.Column="1"
                           FontSize="12" Foreground="#D9E8E8EA"/>
            </Grid>
            <Border Height="5" CornerRadius="2.5" Background="#24FFFFFF" Margin="0,0,0,2">
                <Border Name="WeeklyBar" Height="5" CornerRadius="2.5"
                        Background="#FF4A8CFF" HorizontalAlignment="Left" Width="0"/>
            </Border>
            <TextBlock Name="WeeklySub" FontSize="11" Foreground="#99E8E8EA" Margin="0,0,0,0"/>
            <Grid Name="OpusRow" Margin="0,6,0,2" Visibility="Collapsed">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="OpusLabel" Grid.Column="0"
                           FontSize="12" FontWeight="SemiBold" Foreground="#E8E8EA"/>
                <TextBlock Name="OpusPct" Grid.Column="1"
                           FontSize="12" Foreground="#D9E8E8EA"/>
            </Grid>
            <Border Name="OpusBarContainer" Height="5" CornerRadius="2.5"
                    Background="#24FFFFFF" Margin="0,0,0,2" Visibility="Collapsed">
                <Border Name="OpusBar" Height="5" CornerRadius="2.5"
                        Background="#FF4A8CFF" HorizontalAlignment="Left" Width="0"/>
            </Border>
            <TextBlock Name="OpusSub" FontSize="11"
                       Foreground="#99E8E8EA" Visibility="Collapsed"/>
            </StackPanel>
        </StackPanel>
    </Border>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# 名前付き要素の取得
$header        = $window.FindName("Header")
$titleText     = $window.FindName("TitleText")
$miniTotalText = $window.FindName("MiniTotalText")
$minimizeBtn   = $window.FindName("MinimizeBtn")
$detailPanel   = $window.FindName("DetailPanel")
$statusText    = $window.FindName("StatusText")
$sessionLabel = $window.FindName("SessionLabel")
$sessionPct  = $window.FindName("SessionPct")
$sessionBar  = $window.FindName("SessionBar")
$sessionSub  = $window.FindName("SessionSub")
$weeklyLabel = $window.FindName("WeeklyLabel")
$weeklyPct   = $window.FindName("WeeklyPct")
$weeklyBar   = $window.FindName("WeeklyBar")
$weeklySub   = $window.FindName("WeeklySub")
$opusRow     = $window.FindName("OpusRow")
$opusLabel   = $window.FindName("OpusLabel")
$opusPct     = $window.FindName("OpusPct")
$opusBar     = $window.FindName("OpusBar")
$opusBarContainer = $window.FindName("OpusBarContainer")
$opusSub     = $window.FindName("OpusSub")

# 日本語テキスト設定（エンコーディング問題回避）
$titleText.Text   = "CLAUDE " + [string]([char]0x4F7F + [char]0x7528 + [char]0x72B6 + [char]0x6CC1)
$sessionLabel.Text = [string]([char]0x73FE + [char]0x5728 + [char]0x306E + [char]0x30BB + [char]0x30C3 + [char]0x30B7 + [char]0x30E7 + [char]0x30F3)
$weeklyLabel.Text  = [string]([char]0x9031 + [char]0x9593 + [char]0x5236 + [char]0x9650 + [char]0xFF08 + [char]0x5168 + [char]0x4F53 + [char]0xFF09)
$opusLabel.Text    = [string]([char]0x9031 + [char]0x9593) + " Opus"

# --- ウィンドウ位置 ---
$pos = Load-Position
$window.Left = $pos.x
$window.Top  = $pos.y

$script:isMinimized = $false

function Set-WidgetMinimized($minimized) {
    $script:isMinimized = [bool]$minimized
    if ($script:isMinimized) {
        $detailPanel.Visibility = "Collapsed"
        $miniTotalText.Visibility = "Visible"
        $minimizeBtn.Text = "+"
        $minimizeBtn.ToolTip = [string]([char]0x5C55 + [char]0x958B)
        $header.Margin = "0,0,0,0"
    }
    else {
        $detailPanel.Visibility = "Visible"
        $miniTotalText.Visibility = "Collapsed"
        $minimizeBtn.Text = "-"
        $minimizeBtn.ToolTip = [string]([char]0x6700 + [char]0x5C0F + [char]0x5316)
        $header.Margin = "0,0,0,6"
    }
    Save-Position @{ x = [int]$window.Left; y = [int]$window.Top; minimized = $script:isMinimized }
}

function Update-MiniTotal($slot) {
    $dash = [string][char]0x2014
    if ($slot -and $null -ne $slot.pct) {
        $pctVal = [Math]::Round([double]$slot.pct)
        $miniTotalText.Text = "$pctVal%"
        $miniTotalText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-BarColor $pctVal))
    }
    else {
        $miniTotalText.Text = $dash
        $miniTotalText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#D9E8E8EA")
    }
}

$minimizeBtn.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Set-WidgetMinimized (-not $script:isMinimized)
})

# --- ドラッグ ---
$script:isDragging = $false
$script:dragOffset = @{ x = 0; y = 0 }

$header.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) {
        $initPos = Get-InitialPosition
        $window.Left = $initPos.x
        $window.Top  = $initPos.y
        Save-Position @{ x = $initPos.x; y = $initPos.y; minimized = $script:isMinimized }
        return
    }
    $script:isDragging = $true
    $script:dragStart = [System.Windows.Forms.Cursor]::Position
    $script:windowStart = @{ x = $window.Left; y = $window.Top }
    $header.CaptureMouse()
})

$header.Add_MouseMove({
    param($s, $e)
    if (-not $script:isDragging) { return }
    $curPos = [System.Windows.Forms.Cursor]::Position
    $dpiScale = [System.Windows.PresentationSource]::FromVisual($window).CompositionTarget.TransformFromDevice.M11
    $deltaX = ($curPos.X - $script:dragStart.X) * $dpiScale
    $deltaY = ($curPos.Y - $script:dragStart.Y) * $dpiScale
    $newX = $script:windowStart.x + $deltaX
    $newY = $script:windowStart.y + $deltaY

    # WPF の WorkArea で制限（DPI に依存しない座標）
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $panelH = $window.ActualHeight
    if ($panelH -lt 10) { $panelH = if ($script:isMinimized) { 36 } else { 150 } }
    $minX = $workArea.Left + $MARGIN
    $minY = $workArea.Top + $MARGIN
    $maxX = $workArea.Right - $PANEL_WIDTH - $MARGIN
    $maxY = $workArea.Bottom - $panelH - $MARGIN

    $window.Left = [Math]::Min([Math]::Max($minX, $newX), $maxX)
    $window.Top  = [Math]::Min([Math]::Max($minY, $newY), $maxY)
})

$header.Add_MouseLeftButtonUp({
    param($s, $e)
    if (-not $script:isDragging) { return }
    $script:isDragging = $false
    $header.ReleaseMouseCapture()
    Save-Position @{ x = [int]$window.Left; y = [int]$window.Top; minimized = $script:isMinimized }
})

# --- UI 更新関数 ---
function Update-UI($data) {
    Sync-TrayIcon $data

    $dash = [string][char]0x2014
    $barMaxWidth = $PANEL_WIDTH - 24

    if (-not $data) {
        $titleText.Text = "Claude " + [string]([char]0x4F7F + [char]0x7528 + [char]0x72B6 + [char]0x6CC1) + ": " + [string]([char]0x8AAD + [char]0x307F + [char]0x8FBC + [char]0x307F + [char]0x4E2D) + "..."
        Update-MiniTotal $null
        return
    }

    if (-not $data.session -and -not $data.weekly) {
        $statusText.Text = ""
        $sessionPct.Text = $dash
        $sessionBar.Width = 0
        $errText = ""
        if ($data.error) { $errText = " (" + $data.error + ")" }
        $sessionSub.Text = [string]([char]0x30C7 + [char]0x30FC + [char]0x30BF + [char]0x53D6 + [char]0x5F97 + [char]0x5F85 + [char]0x3061) + $errText
        $weeklyPct.Text = $dash
        $weeklyBar.Width = 0
        $weeklySub.Text = ""
        Update-MiniTotal $null
        return
    }

    # ステータス表示（案3: 次回リトライ時刻 / 案4: エラー種別の詳細）
    if ($data.stale) {
        $refreshChar = [string][char]0x27F3
        $retryText = ""

        # 案3: 次回リトライまでの残り時間を計算
        if ($data.next_fetch_after) {
            try {
                $nextFetch = [DateTimeOffset]::Parse($data.next_fetch_after).LocalDateTime
                $diff = $nextFetch - [DateTime]::Now
                if ($diff.TotalSeconds -gt 0) {
                    $mins = [int]$diff.TotalMinutes
                    if ($mins -gt 0) {
                        $retryText = " (" + $mins + [string]([char]0x5206 + [char]0x5F8C) + ")"
                    } else {
                        $retryText = " (" + [string]([char]0x307E + [char]0x3082 + [char]0x306A + [char]0x304F) + ")"
                    }
                }
            } catch {}
        }

        # 案4: エラー種別ごとの表示テキスト
        if ($data.error -eq "rate_limited(429)") {
            $statusText.Text = $refreshChar + " " + [string]([char]0x5236 + [char]0x9650 + [char]0x4E2D) + $retryText
            $statusText.ToolTip = [string]([char]0x30EC + [char]0x30FC + [char]0x30C8 + [char]0x5236 + [char]0x9650 + [char]0x4E2D) + [string]([char]0xFF08) + "429" + [string]([char]0xFF09) + [string]([char]0x3002) + [string]([char]0x30AF + [char]0x30EA + [char]0x30C3 + [char]0x30AF + [char]0x3067 + [char]0x518D + [char]0x8A66 + [char]0x884C)
        }
        elseif ($data.error -eq "click_to_connect") {
            $statusText.Text = $refreshChar + " " + [string]([char]0x30AF + [char]0x30EA + [char]0x30C3 + [char]0x30AF + [char]0x3067 + [char]0x63A5 + [char]0x7D9A)
            $statusText.ToolTip = [string]([char]0x30AF + [char]0x30EA + [char]0x30C3 + [char]0x30AF + [char]0x3067) + " API " + [string]([char]0x53D6 + [char]0x5F97 + [char]0x3092 + [char]0x958B + [char]0x59CB)
        }
        elseif ($data.error -and $data.error.StartsWith("http_401")) {
            $statusText.Text = [string]([char]0x26A0) + " " + [string]([char]0x8981 + [char]0x30ED + [char]0x30B0 + [char]0x30A4 + [char]0x30F3)
            $statusText.ToolTip = [string]([char]0x8A8D + [char]0x8A3C + [char]0x5931 + [char]0x6557) + "(401)" + [string]([char]0x3002) + "claude " + [string]([char]0x3067 + [char]0x518D + [char]0x30ED + [char]0x30B0 + [char]0x30A4 + [char]0x30F3 + [char]0x3057 + [char]0x3066 + [char]0x304F + [char]0x3060 + [char]0x3055 + [char]0x3044)
        }
        elseif ($data.error -eq "no_credentials") {
            $statusText.Text = [string]([char]0x26A0) + " " + [string]([char]0x30ED + [char]0x30B0 + [char]0x30A4 + [char]0x30F3 + [char]0x306A + [char]0x3057)
            $statusText.ToolTip = "~/.claude/.credentials.json " + [string]([char]0x304C + [char]0x898B + [char]0x3064 + [char]0x304B + [char]0x308A + [char]0x307E + [char]0x305B + [char]0x3093)
        }
        elseif ($data.error -and $data.error.StartsWith("network")) {
            $statusText.Text = [string]([char]0x26A0) + " " + [string]([char]0x63A5 + [char]0x7D9A + [char]0x30A8 + [char]0x30E9 + [char]0x30FC) + $retryText
            $statusText.ToolTip = $data.error
        }
        else {
            $statusText.Text = $refreshChar + " " + [string]([char]0x66F4 + [char]0x65B0 + [char]0x5F85 + [char]0x3061) + $retryText
            $statusText.ToolTip = if ($data.error) { $data.error } else { "" }
        }
    }
    else {
        $statusText.Text = ""
        $statusText.ToolTip = $null
    }

    # セッション
    if ($data.session) {
        $pct = [Math]::Round($data.session.pct)
        $sessionPct.Text = "$pct%"
        $sessionBar.Width = [Math]::Min($pct, 100) / 100.0 * $barMaxWidth
        $sessionBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-BarColor $pct))
        $sessionSub.Text = Get-Countdown $data.session.resets_at
    }
    else {
        $sessionPct.Text = $dash
        $sessionBar.Width = 0
        $sessionSub.Text = $dash
    }

    # 週間
    if ($data.weekly) {
        $pct = [Math]::Round($data.weekly.pct)
        $weeklyPct.Text = "$pct%"
        $weeklyBar.Width = [Math]::Min($pct, 100) / 100.0 * $barMaxWidth
        $weeklyBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-BarColor $pct))
        $weeklySub.Text = Get-ResetClock $data.weekly.resets_at
    }
    else {
        $weeklyPct.Text = $dash
        $weeklyBar.Width = 0
        $weeklySub.Text = $dash
    }

    # Opus
    if ($data.weekly_opus) {
        $opusRow.Visibility = "Visible"
        $opusBarContainer.Visibility = "Visible"
        $opusSub.Visibility = "Visible"
        $pct = [Math]::Round($data.weekly_opus.pct)
        $opusPct.Text = "$pct%"
        $opusBar.Width = [Math]::Min($pct, 100) / 100.0 * $barMaxWidth
        $opusBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-BarColor $pct))
        $opusSub.Text = Get-ResetClock $data.weekly_opus.resets_at
    }
    else {
        $opusRow.Visibility = "Collapsed"
        $opusBarContainer.Visibility = "Collapsed"
        $opusSub.Visibility = "Collapsed"
    }

    Update-MiniTotal $data.session
}

# --- 案2: 手動接続ボタン（StatusText クリックで即取得）---
$statusText.Cursor = [System.Windows.Input.Cursors]::Hand
$statusText.Add_MouseLeftButtonDown({
    param($s, $e)
    $statusText.Text = [string]([char]0x27F3) + " " + [string]([char]0x53D6 + [char]0x5F97 + [char]0x4E2D) + "..."
    $statusText.ToolTip = $null
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $data = Fetch-Usage -Force
    Update-UI $data
})

Set-WidgetMinimized $pos.minimized
$window.Hide()

# --- システムトレイ ---
$script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:trayIcon.Text = "Claude"
$script:trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$exitMenuItem = $trayMenu.Items.Add([string]([char]0x7D42 + [char]0x4E86))
$script:trayIcon.ContextMenuStrip = $trayMenu

function Show-Popup {
    $window.Show()
    $window.Activate()
}

function Hide-Popup {
    $window.Hide()
}

$script:trayIcon.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($window.Visibility -eq [System.Windows.Visibility]::Visible) {
            Hide-Popup
        }
        else {
            Show-Popup
        }
    }
})

$exitMenuItem.Add_Click({
    $timer.Stop()
    $script:trayIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$window.Add_Deactivated({
    Hide-Popup
})

$window.Add_Closing({
    param($s, $e)
    $e.Cancel = $true
    Hide-Popup
})

# --- 初回表示（キャッシュだけ表示、APIは叩かない）---
$initialCache = Load-Cache
if ($initialCache) {
    $initialCache.stale = $true
    if (-not $initialCache.error) { $initialCache.error = "click_to_connect" }
    Update-UI $initialCache
} else {
    Sync-TrayIcon $null
    $statusText.Text = [string]([char]0x27F3) + " " + [string]([char]0x30AF + [char]0x30EA + [char]0x30C3 + [char]0x30AF + [char]0x3067 + [char]0x63A5 + [char]0x7D9A)
    $statusText.ToolTip = [string]([char]0x30AF + [char]0x30EA + [char]0x30C3 + [char]0x30AF + [char]0x3067) + " API " + [string]([char]0x53D6 + [char]0x5F97 + [char]0x3092 + [char]0x958B + [char]0x59CB)
}

# --- 定期更新タイマー（手動接続後 or 自動では動かさない、30秒ごとにUI更新のみ）---
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($REFRESH_INTERVAL_SEC)
$timer.Add_Tick({
    $data = Fetch-Usage
    Update-UI $data
})
$timer.Start()

[System.Windows.Forms.Application]::Run()

$script:trayIcon.Dispose()
try { $script:widgetMutex.ReleaseMutex() } catch {}
$script:widgetMutex.Dispose()
