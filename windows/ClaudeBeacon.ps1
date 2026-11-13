<#
  claude-beacon Windows tray client.

  Polls the beacon's /state every few seconds and shows tray icons, each a colored disc with a
  count (a faint ring when the count is zero). The default layout is two icons:

    Needs you   sessions idle or asking you something. Gray when they are all just idle,
                amber when at least one is asking you (question, permission prompt, plan).
                A white rim on gray = one finished since you last looked.
    Working     green, sessions working.

  Other layouts (right-click > Settings > Icons): Asking + Idle + Working, Asking + Working,
  Needs you only, Asking only. Settings also covers notifications, hiding empty icons and
  starting at login; they are saved in client.json next to the URL and token.

  A Windows notification pops up once when a session finishes or starts asking you something.
  Sessions are named by their /rename name, else Claude's auto-generated title, with the tmux
  session they run in alongside.

  Left-click any icon for the status panel: every session with its state; click a row to mark it
  seen, or "Mark all seen". Marking seen drops the white rim / mutes amber, but the counts stay,
  because those sessions are still idle or waiting; a session clears when it works again.
  Right-click for the session list as a menu, Settings, and Quit.

  Config: %APPDATA%\claude-beacon\client.json
    {
      "url": "http://host:8799", "token": "...",      required
      "layout": "needs-you+working",                  needs-you+working | asking+idle+working |
                                                      asking+working | needs-you | asking
      "notify": "all",                                all (finished + asking) | asking | off
      "hideEmpty": false,                             hide an icon while its count is zero
      "pollSeconds": 3
    }
  Runs on Windows PowerShell 5.1 (built into Windows 10/11); no modules needed.
#>
param(
    [string]$ConfigPath = (Join-Path $env:APPDATA 'claude-beacon\client.json'),
    [int]$PollSeconds = 3
)

$Version = '0.9'   # host shown when sessions span machines
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http

# One instance per user.
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeBeaconTray', [ref]$created)
if (-not $created) { exit 0 }

if (-not (Test-Path $ConfigPath)) {
    [System.Windows.Forms.MessageBox]::Show("Missing config: $ConfigPath`n`nCreate it with:`n{ `"url`": `"http://my-server:8799`", `"token`": `"...`" }",
        'Claude Beacon') | Out-Null
    exit 1
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$script:baseUrl = $config.url.TrimEnd('/')

$Layouts = [ordered]@{
    'needs-you+working'   = @{ label = 'Needs you + Working';       slots = @('attention', 'work') }
    'asking+idle+working' = @{ label = 'Asking + Idle + Working';   slots = @('asking', 'idle', 'work') }
    'asking+working'      = @{ label = 'Asking + Working';          slots = @('asking', 'work') }
    'needs-you'           = @{ label = 'Needs you only';            slots = @('attention') }
    'asking'              = @{ label = 'Asking only';               slots = @('asking') }
}
$NotifyModes = [ordered]@{
    'all'    = 'When a session finishes or asks you'
    'asking' = 'Only when a session asks you'
    'off'    = 'Off'
}

function Get-Setting([string]$name, $default) {
    if ($config.PSObject.Properties[$name] -and $null -ne $config.$name) { return $config.$name }
    return $default
}
$script:settings = @{
    layout    = [string](Get-Setting 'layout' 'needs-you+working')
    notify    = [string](Get-Setting 'notify' 'all')
    hideEmpty = [bool](Get-Setting 'hideEmpty' $false)
}
if (-not $Layouts.Contains($script:settings.layout)) { $script:settings.layout = 'needs-you+working' }
if (-not $NotifyModes.Contains($script:settings.notify)) { $script:settings.notify = 'all' }
if (-not $PSBoundParameters.ContainsKey('PollSeconds')) { $PollSeconds = [int](Get-Setting 'pollSeconds' $PollSeconds) }

function Save-Settings {
    $out = [ordered]@{}
    foreach ($p in $config.PSObject.Properties) { $out[$p.Name] = $p.Value }
    foreach ($k in $script:settings.Keys) { $out[$k] = $script:settings[$k] }
    # no BOM, so the same file stays readable by strict JSON parsers
    [System.IO.File]::WriteAllText($ConfigPath, ($out | ConvertTo-Json))
}

$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Beacon.lnk'
function Set-StartAtLogin([bool]$on) {
    if (-not $on) { Remove-Item $StartupLink -ErrorAction SilentlyContinue; return }
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($StartupLink)
    $sc.TargetPath = (Get-Command powershell.exe).Source
    $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $sc.WorkingDirectory = Split-Path $PSCommandPath
    $sc.WindowStyle = 7
    $sc.Description = 'Claude Beacon tray client'
    $sc.Save()
}

$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromSeconds(5)
$script:http.DefaultRequestHeaders.Authorization =
    New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $config.token)

$script:snapshot = $null        # last /state payload
$script:online = $false
$script:pending = $null         # in-flight GET /state task
$script:notified = @{}          # "session_id|updated|state" -> $true, so each change notifies once
$script:firstPoll = $true
$script:icons = @{}             # cached icons by key
$script:iconKeys = @{}          # tray name -> icon key currently shown

$Amber = [System.Drawing.Color]::FromArgb(245, 170, 0)
$AmberSeen = [System.Drawing.Color]::FromArgb(150, 115, 40)
$Green = [System.Drawing.Color]::FromArgb(40, 170, 80)
$Gray = [System.Drawing.Color]::FromArgb(125, 125, 125)
$GraySeen = [System.Drawing.Color]::FromArgb(90, 90, 90)
$Palette = @{ amber = $Amber; amberseen = $AmberSeen; green = $Green; gray = $Gray; grayseen = $GraySeen }

# ---------- icon drawing ----------
# Draw the digits as an outline and center its actual ink bounds on the 32x32 icon. DrawString
# with centered alignment pads the text box (font leading, side bearings), which left the number
# visibly low and to the left.
function Draw-Number($g, [string]$n, $color) {
    $em = if ($n.Length -gt 1) { 17 } else { 22 }
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $family = New-Object System.Drawing.FontFamily('Segoe UI')
    $path.AddString($n, $family, [int][System.Drawing.FontStyle]::Bold, $em,
        (New-Object System.Drawing.PointF(0, 0)), [System.Drawing.StringFormat]::GenericTypographic)
    $b = $path.GetBounds()
    $m = New-Object System.Drawing.Drawing2D.Matrix
    $m.Translate([single](16 - $b.X - $b.Width / 2), [single](16 - $b.Y - $b.Height / 2))
    $path.Transform($m)
    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillPath($brush, $path)
    $brush.Dispose(); $m.Dispose(); $family.Dispose(); $path.Dispose()
}

function New-BeaconIcon([string]$key) {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $parts = $key -split '-'

    if ($parts[0] -eq 'offline') {
        $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 110, 110))
        $g.FillEllipse($b, 1, 1, 30, 30); $b.Dispose()
        Draw-Number $g '!' ([System.Drawing.Color]::White)
    } else {
        $color = $Palette[$parts[0]]
        if ($parts[1] -eq '0') {
            # nothing in this state: faint ring of the state's color, so the slot stays put
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110, $color), 3)
            $g.DrawEllipse($pen, 4, 4, 24, 24); $pen.Dispose()
        } else {
            $b = New-Object System.Drawing.SolidBrush($color)
            $g.FillEllipse($b, 0, 0, 32, 32); $b.Dispose()
            if ($parts[2] -eq 'rim') {
                $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3)
                $g.DrawEllipse($pen, 1.5, 1.5, 29, 29); $pen.Dispose()
            }
            Draw-Number $g $parts[1] ([System.Drawing.Color]::White)
        }
    }
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

function Get-BeaconIcon([string]$key) {
    if (-not $script:icons.ContainsKey($key)) { $script:icons[$key] = New-BeaconIcon $key }
    return $script:icons[$key]
}

# ---------- helpers ----------
function Get-Sessions { if ($script:snapshot) { @($script:snapshot.sessions) } else { @() } }
function Get-Working { @(Get-Sessions | Where-Object { $_.state -eq 'working' }) }
function Get-Asking { @(Get-Sessions | Where-Object { $_.state -eq 'needs_input' }) }
function Get-Idle { @(Get-Sessions | Where-Object { $_.state -eq 'done' }) }
function Test-Fresh($s) { ($s.state -eq 'needs_input' -or $s.state -eq 'done') -and -not $s.acked }

# Long name: what the session is.  Short name: where it runs (fits tooltips and toast titles).
function Get-Name($s) {
    if ($s.title) { return $s.title }
    if ($s.label) { return $s.label }
    return $s.project
}
function Get-Short($s) {
    if ($s.label) { return $s.label }
    if ($s.title) { return $s.title }
    return $s.project
}
function Get-Where($s) {
    $bits = @()
    if ($s.label -and $s.title) { $bits += "tmux $($s.label)" }
    if ($s.project) { $bits += $s.project }
    # name the machine once sessions come from more than one
    if ($s.host -and @(Get-Sessions | ForEach-Object { $_.host } | Select-Object -Unique).Count -gt 1) { $bits += $s.host }
    return $bits -join ' - '
}
function Get-StateText($s) {
    $what = switch ($s.state) {
        'needs_input' { 'asking you' }
        'done' { 'idle' }
        'working' { 'working' }
        default { $s.state }
    }
    if ($s.acked) { $what += ', seen' }
    return $what
}

function Format-Count([int]$n) { if ($n -gt 9) { '9+' } else { [string]$n } }

function Format-Age([int]$s) {
    if ($s -lt 60) { return "${s}s" }
    if ($s -lt 3600) { return "$([math]::Floor($s / 60))m" }
    return "$([math]::Floor($s / 3600))h"
}

function Format-Session($s) {
    $where = if ($s.label -and $s.title) { "  [$($s.label)]" } else { '' }
    return "$(Get-Name $s)$where  -  $(Get-StateText $s)  ($(Format-Age $s.age))"
}

function Join-Names($list, [int]$max = 50) {
    $t = (@($list) | ForEach-Object { Get-Short $_ }) -join ', '
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max - 3) + '...' }
    return $t
}

function Send-Ack([string]$sessionId) {
    $body = if ($sessionId) { (@{ session_id = $sessionId } | ConvertTo-Json -Compress) } else { '{}' }
    $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
    # fire and forget; the next poll picks up the new state
    $null = $script:http.PostAsync("$($script:baseUrl)/ack", $content)
    $script:nextPollNow = $true
}

function Set-TrayText($tray, [string]$text) {
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }   # NotifyIcon limit
    if ($tray.Text -ne $text) { $tray.Text = $text }
}

function Set-TrayIcon([string]$name, [string]$key) {
    if ($script:iconKeys[$name] -ne $key) {
        $script:trays[$name].Icon = Get-BeaconIcon $key
        $script:iconKeys[$name] = $key
    }
}

# For one slot: the icon key, tooltip text and session count.
function Get-SlotView([string]$slot, $asking, $idle, $working) {
    $freshIdle = @($idle | Where-Object { -not $_.acked }).Count -gt 0
    $freshAsk = @($asking | Where-Object { -not $_.acked }).Count -gt 0
    switch ($slot) {
        'attention' {
            $list = @($asking) + @($idle)
            $n = $list.Count
            $color = if ($asking.Count -and $freshAsk) { 'amber' } elseif ($asking.Count) { 'amberseen' } elseif ($freshIdle) { 'gray' } else { 'grayseen' }
            $rim = if ($color -like 'gray*' -and $freshIdle) { '-rim' } else { '' }
            $key = if ($n) { "$color-$(Format-Count $n)$rim" } else { 'gray-0' }
            $parts = @()
            if ($asking.Count) { $parts += "$($asking.Count) asking" }
            if ($idle.Count) { $parts += "$($idle.Count) idle" }
            $text = if ($n) { "Needs you ($($parts -join ', ')): $(Join-Names $list)" } else { 'Claude: nothing needs you' }
        }
        'asking' {
            $n = $asking.Count
            $key = if (-not $n) { 'amber-0' } elseif ($freshAsk) { "amber-$(Format-Count $n)" } else { "amberseen-$(Format-Count $n)" }
            $text = if ($n) { "Asking you ($n): $(Join-Names $asking)" } else { 'Claude: nothing asking you' }
        }
        'idle' {
            $n = $idle.Count
            $key = if (-not $n) { 'gray-0' } elseif ($freshIdle) { "gray-$(Format-Count $n)-rim" } else { "grayseen-$(Format-Count $n)" }
            $text = if ($n) { "Idle ($n): $(Join-Names $idle)" } else { 'Claude: nothing idle' }
        }
        'work' {
            $n = $working.Count
            $key = if ($n) { "green-$(Format-Count $n)" } else { 'green-0' }
            $text = if ($n) { "Working ($n): $(Join-Names $working)" } else { 'Claude: nothing working' }
        }
    }
    return @{ key = $key; text = $text; count = $n }
}

function Update-Tray {
    if (-not $script:online) {
        foreach ($name in @($script:trays.Keys)) {
            Set-TrayIcon $name 'offline'
            Set-TrayText $script:trays[$name] 'Claude: cannot reach the beacon'
            $script:trays[$name].Visible = $true
        }
        return
    }

    # @() matters: Windows PowerShell 5.1 gives a single object no .Count, so 1 session read as 0
    $asking = @(Get-Asking)
    $idle = @(Get-Idle)
    $working = @(Get-Working)

    $names = @($script:trays.Keys)
    $shown = 0
    foreach ($name in $names) {
        $v = Get-SlotView $name $asking $idle $working
        Set-TrayIcon $name $v.key
        Set-TrayText $script:trays[$name] $v.text
        $visible = -not $script:settings.hideEmpty -or $v.count -gt 0
        # never hide every icon: the last one stays so Settings and Quit remain reachable
        if (-not $visible -and $name -eq $names[-1] -and $shown -eq 0) { $visible = $true }
        if ($script:trays[$name].Visible -ne $visible) { $script:trays[$name].Visible = $visible }
        if ($visible) { $shown++ }
    }
}

function Show-Changes {
    # notify once per (session, state change): finished -> idle, or started asking
    $fresh = @()
    $live = @{}
    foreach ($s in (Get-Sessions | Where-Object { Test-Fresh $_ })) {
        $k = "$($s.session_id)|$($s.updated)|$($s.state)"
        $live[$k] = $true
        if (-not $script:notified.ContainsKey($k)) {
            # on startup, only announce questions; sessions already idle aren't news
            if (-not $script:firstPoll -or $s.state -eq 'needs_input') { $fresh += $s }
        }
    }
    $script:notified = $live
    $script:firstPoll = $false
    switch ($script:settings.notify) {
        'off' { return }
        'asking' { $fresh = @($fresh | Where-Object { $_.state -eq 'needs_input' }) }
    }
    if ($fresh.Count -eq 0) { return }

    $asking = @($fresh | Where-Object { $_.state -eq 'needs_input' })
    $finished = @($fresh | Where-Object { $_.state -eq 'done' })
    $script:balloonSession = if ($fresh.Count -eq 1) { $fresh[0].session_id } else { $null }
    $icon = if ($asking.Count) { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }

    if ($fresh.Count -eq 1) {
        $title = if ($asking.Count) { "$(Get-Short $fresh[0]) is asking you" } else { "$(Get-Short $fresh[0]) finished" }
        $msg = if ($fresh[0].title) { "$($fresh[0].title)`n$($fresh[0].project)" } else { $fresh[0].project }
    } else {
        $title = "$($fresh.Count) Claude sessions need a look"
        $lines = @()
        if ($asking.Count) { $lines += "Asking you: $(Join-Names $asking 120)" }
        if ($finished.Count) { $lines += "Finished: $(Join-Names $finished 120)" }
        $msg = $lines -join "`n"
    }
    $from = @($script:trays.Values | Where-Object { $_.Visible })[0]
    if ($from) { $from.ShowBalloonTip(10000, $title, $msg, $icon) }
}

# ---------- polling ----------
function Invoke-Poll {
    if ($script:pending) {
        if (-not $script:pending.IsCompleted) { return }
        $task = $script:pending
        $script:pending = $null
        $ok = $false
        if ($task.Status -eq 'RanToCompletion' -and $task.Result.IsSuccessStatusCode) {
            try {
                # SendAsync buffers the body by default, so this .Result doesn't block
                $script:snapshot = $task.Result.Content.ReadAsStringAsync().Result | ConvertFrom-Json
                $ok = $true
            } catch { }
        }
        if ($task.Status -eq 'RanToCompletion') { $task.Result.Dispose() }
        $script:online = $ok
        Update-Tray
        if ($ok) { Show-Changes }
        if ($script:panel.Visible) { Update-Panel }
        return
    }
    $script:pending = $script:http.GetAsync("$($script:baseUrl)/state")
}

# ---------- UI ----------
function Add-Section($menu, [string]$title, $list) {
    if (@($list).Count -eq 0) { return }
    $h = $menu.Items.Add($title)
    $h.Enabled = $false
    foreach ($s in $list) {
        $item = $menu.Items.Add('    ' + (Format-Session $s))
        if (Test-Fresh $s) {
            $item.Font = New-Object System.Drawing.Font($item.Font, [System.Drawing.FontStyle]::Bold)
            $item.ToolTipText = 'Click to mark seen'
            $item.Tag = $s.session_id
            $item.add_Click({ Send-Ack $this.Tag })
        } elseif ($s.state -eq 'working') {
            $item.Enabled = $false
        }
    }
}

function Add-Choice($parent, [string]$text, [bool]$checked, [scriptblock]$onClick, $tag) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $item.Checked = $checked
    $item.Tag = $tag
    $item.add_Click($onClick)
    $parent.DropDownItems.Add($item) | Out-Null
}

function Add-SettingsMenu($menu) {
    $root = New-Object System.Windows.Forms.ToolStripMenuItem('Settings')

    $icons = New-Object System.Windows.Forms.ToolStripMenuItem('Icons')
    foreach ($k in $Layouts.Keys) {
        Add-Choice $icons $Layouts[$k].label ($k -eq $script:settings.layout) {
            $script:settings.layout = $this.Tag; Save-Settings; New-Trays
        } $k
    }
    $root.DropDownItems.Add($icons) | Out-Null

    $notify = New-Object System.Windows.Forms.ToolStripMenuItem('Notifications')
    foreach ($k in $NotifyModes.Keys) {
        Add-Choice $notify $NotifyModes[$k] ($k -eq $script:settings.notify) {
            $script:settings.notify = $this.Tag; Save-Settings
        } $k
    }
    $root.DropDownItems.Add($notify) | Out-Null

    Add-Choice $root 'Hide icons with nothing to show' $script:settings.hideEmpty {
        $script:settings.hideEmpty = -not $script:settings.hideEmpty; Save-Settings; Update-Tray
    } $null
    Add-Choice $root 'Start at login' (Test-Path $StartupLink) {
        Set-StartAtLogin (-not (Test-Path $StartupLink))
    } $null
    $root.DropDownItems.Add('-') | Out-Null
    $open = $root.DropDownItems.Add('Open config file')
    $open.add_Click({ Start-Process notepad.exe -ArgumentList "`"$ConfigPath`"" })

    $menu.Items.Add($root) | Out-Null
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowItemToolTips = $true
$menu.add_Opening({
    $menu.Items.Clear()
    if (-not $script:online) {
        $menu.Items.Add("Cannot reach $($script:baseUrl)").Enabled = $false
    } else {
        $all = @(Get-Sessions | Sort-Object age)
        if ($all.Count -eq 0) { $menu.Items.Add('No Claude sessions').Enabled = $false }
        Add-Section $menu 'Asking you' @($all | Where-Object { $_.state -eq 'needs_input' })
        Add-Section $menu 'Idle' @($all | Where-Object { $_.state -eq 'done' })
        Add-Section $menu 'Working' @($all | Where-Object { $_.state -eq 'working' })
        $menu.Items.Add('-') | Out-Null
        $dismiss = $menu.Items.Add('Mark all seen')
        $dismiss.Enabled = @($all | Where-Object { Test-Fresh $_ }).Count -gt 0
        $dismiss.add_Click({ Send-Ack $null })
    }
    $menu.Items.Add('-') | Out-Null
    Add-SettingsMenu $menu
    $menu.Items.Add("Claude Beacon $Version").Enabled = $false
    $menu.Items.Add('Quit').add_Click({
        foreach ($t in $script:trays.Values) { $t.Visible = $false }
        [System.Windows.Forms.Application]::Exit()
    })
    $_.Cancel = $false
})
# ContextMenuStrip won't open with no items; seed one so Opening fires
$menu.Items.Add('...') | Out-Null

# ---------- status panel (left-click) ----------
$Bg = [System.Drawing.Color]::FromArgb(32, 32, 32)
$RowHover = [System.Drawing.Color]::FromArgb(50, 50, 50)
$TextMain = [System.Drawing.Color]::FromArgb(240, 240, 240)
$TextDim = [System.Drawing.Color]::FromArgb(160, 160, 160)
$PanelWidth = 420
$FontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$FontSub = New-Object System.Drawing.Font('Segoe UI', 8.5)
$FontHead = New-Object System.Drawing.Font('Segoe UI Semibold', 9)

$script:panel = New-Object System.Windows.Forms.Form
$script:panel.FormBorderStyle = 'None'
$script:panel.ShowInTaskbar = $false
$script:panel.TopMost = $true
$script:panel.StartPosition = 'Manual'
$script:panel.BackColor = $Bg
$script:panel.Width = $PanelWidth
$script:panel.KeyPreview = $true
$script:panel.add_Deactivate({ $script:panel.Hide(); $script:panelHiddenAt = [DateTime]::Now })
$script:panel.add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $script:panel.Hide() } })
$script:panelHiddenAt = [DateTime]::MinValue
$script:panelSig = $null        # what the panel last drew; rebuild only when this changes
$script:ageLabels = @{}         # session_id -> @(label, where-text) so ages update in place
# paint off-screen first (DoubleBuffered is protected, so set it by reflection)
[System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($script:panel, $true, $null)

function Get-DotColor($s) {
    switch ($s.state) {
        'working' { return $Green }
        'needs_input' { if ($s.acked) { return $AmberSeen } else { return $Amber } }
        'done' { if ($s.acked) { return $GraySeen } else { return $Gray } }
        default { return $Gray }
    }
}

function New-PanelLabel([string]$text, $font, $color, [int]$x, [int]$y, [int]$w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Font = $font
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.AutoSize = $false
    $l.AutoEllipsis = $true
    $l.UseMnemonic = $false
    $l.SetBounds($x, $y, $w, $font.Height + 2)
    return $l
}

function Add-PanelRow([int]$y, $s) {
    $row = New-Object System.Windows.Forms.Panel
    $row.SetBounds(0, $y, $PanelWidth, 46)
    $row.BackColor = $Bg
    $dot = New-Object System.Windows.Forms.Panel
    $dot.SetBounds(14, 17, 12, 12)
    $dot.BackColor = Get-DotColor $s
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse(0, 0, 12, 12)
    $dot.Region = New-Object System.Drawing.Region($path)
    $title = New-PanelLabel (Get-Name $s) $FontTitle $TextMain 36 5 ($PanelWidth - 120)
    $state = New-PanelLabel (Get-StateText $s) $FontSub (Get-DotColor $s) ($PanelWidth - 84) 7 76
    $state.TextAlign = 'TopRight'
    $sub = New-PanelLabel "$(Get-Where $s)  -  $(Format-Age $s.age)" $FontSub $TextDim 36 25 ($PanelWidth - 50)
    $script:ageLabels[$s.session_id] = @($sub, (Get-Where $s))
    $row.Controls.AddRange(@($dot, $title, $state, $sub))
    if (Test-Fresh $s) {
        foreach ($c in @($row, $dot, $title, $state, $sub)) {
            $c.Tag = $s.session_id
            $c.Cursor = [System.Windows.Forms.Cursors]::Hand
            $c.add_Click({ Send-Ack $this.Tag })
            $c.add_MouseEnter({ $r = if ($this -is [System.Windows.Forms.Label] -or $this.Parent -ne $script:panel) { $this.Parent } else { $this }; $r.BackColor = $RowHover })
            $c.add_MouseLeave({ $r = if ($this -is [System.Windows.Forms.Label] -or $this.Parent -ne $script:panel) { $this.Parent } else { $this }; $r.BackColor = $Bg })
        }
    }
    $script:panel.Controls.Add($row)
    return $y + 46
}

function Add-PanelHeading([int]$y, [string]$text) {
    $script:panel.Controls.Add((New-PanelLabel $text $FontHead $TextDim 14 ($y + 8) ($PanelWidth - 28)))
    return $y + 30
}

function Get-PanelSig {
    if (-not $script:online) { return 'offline' }
    return (@(Get-Sessions | Sort-Object session_id | ForEach-Object {
        "$($_.session_id)|$($_.state)|$($_.acked)|$($_.title)|$($_.label)|$($_.project)"
    }) -join ';')
}

function Update-Panel {
    $sig = Get-PanelSig
    if ($sig -eq $script:panelSig) {
        # nothing changed but time: refresh the ages in place, no rebuild
        foreach ($s in (Get-Sessions)) {
            $entry = $script:ageLabels[$s.session_id]
            if ($entry) {
                $text = "$($entry[1])  -  $(Format-Age $s.age)"
                if ($entry[0].Text -ne $text) { $entry[0].Text = $text }
            }
        }
        return
    }
    $script:panelSig = $sig
    $script:ageLabels = @{}
    $script:panel.SuspendLayout()
    foreach ($c in @($script:panel.Controls)) { $c.Dispose() }
    $script:panel.Controls.Clear()
    $y = 4
    if (-not $script:online) {
        $y = Add-PanelHeading $y "Cannot reach $($script:baseUrl)"
    } else {
        $all = @(Get-Sessions | Sort-Object age)
        $asking = @($all | Where-Object { $_.state -eq 'needs_input' })
        $idle = @($all | Where-Object { $_.state -eq 'done' })
        $working = @($all | Where-Object { $_.state -eq 'working' })
        if ($all.Count -eq 0) { $y = Add-PanelHeading $y 'No Claude sessions' }
        if ($asking.Count) { $y = Add-PanelHeading $y "ASKING YOU ($($asking.Count))"; foreach ($s in $asking) { $y = Add-PanelRow $y $s } }
        if ($idle.Count) { $y = Add-PanelHeading $y "IDLE ($($idle.Count))"; foreach ($s in $idle) { $y = Add-PanelRow $y $s } }
        if ($working.Count) { $y = Add-PanelHeading $y "WORKING ($($working.Count))"; foreach ($s in $working) { $y = Add-PanelRow $y $s } }
        if (@($all | Where-Object { Test-Fresh $_ }).Count) {
            $link = New-Object System.Windows.Forms.LinkLabel
            $link.Text = 'Mark all seen'
            $link.Font = $FontSub
            $link.LinkColor = $TextDim; $link.ActiveLinkColor = $TextMain
            $link.LinkBehavior = 'HoverUnderline'
            $link.AutoSize = $true
            $link.Location = New-Object System.Drawing.Point(14, ($y + 8))
            $link.add_LinkClicked({ Send-Ack $null })
            $script:panel.Controls.Add($link)
            $y += 30
        }
    }
    $script:panel.Height = $y + 8
    $script:panel.ResumeLayout()
    Move-Panel
}

function Move-Panel {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $area = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
    $x = [math]::Min([math]::Max($cursor.X - $PanelWidth / 2, $area.Left + 8), $area.Right - $PanelWidth - 8)
    if (-not $script:panelX) { $script:panelX = $x }
    $script:panel.Location = New-Object System.Drawing.Point([int]$script:panelX, ($area.Bottom - $script:panel.Height - 8))
}

function Switch-Panel {
    # a click on the tray icon deactivates (hides) the panel first; don't immediately reopen it
    if ($script:panel.Visible -or ([DateTime]::Now - $script:panelHiddenAt).TotalMilliseconds -lt 300) {
        $script:panel.Hide(); return
    }
    $script:panelX = $null
    $script:panelSig = $null      # always rebuild on open (it's hidden, so nothing flickers)
    Update-Panel
    $script:panel.Show()
    $script:panel.Activate()
}

# Create the layout's icons. Windows usually adds each new tray icon to the left of the existing
# ones, so they're created right-to-left to read in the layout's order. Windows 11 decides the final
# order and may hide new icons behind the ^ arrow; drag them onto the taskbar to keep them visible.
$script:trays = [ordered]@{}
function New-Trays {
    foreach ($t in @($script:trays.Values)) { $t.Visible = $false; $t.Dispose() }
    $script:trays = [ordered]@{}
    $script:iconKeys = @{}
    $slots = $Layouts[$script:settings.layout].slots
    $created = @{}
    for ($i = $slots.Count - 1; $i -ge 0; $i--) {
        $t = New-Object System.Windows.Forms.NotifyIcon
        $t.Icon = Get-BeaconIcon 'offline'
        $t.Text = 'Claude: connecting'
        $t.ContextMenuStrip = $menu
        $t.add_MouseClick({
            if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Switch-Panel }
        })
        $t.add_BalloonTipClicked({ Send-Ack $script:balloonSession })
        $t.Visible = $true
        $created[$slots[$i]] = $t
    }
    foreach ($slot in $slots) { $script:trays[$slot] = $created[$slot] }
    Update-Tray
}
New-Trays

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$script:ticks = 0
$script:nextPollNow = $true
$pollTicks = [int]($PollSeconds * 1000 / $timer.Interval)
$timer.add_Tick({
    try {
        $script:ticks++
        if ($script:pending -or $script:nextPollNow -or $script:ticks -ge $pollTicks) {
            if (-not $script:pending) { $script:ticks = 0; $script:nextPollNow = $false }
            Invoke-Poll
        }
    } catch {
        $script:pending = $null
        $script:online = $false
        Update-Tray
    }
})
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $timer.Stop()
    foreach ($t in $script:trays.Values) { $t.Visible = $false; $t.Dispose() }
    $script:http.Dispose()
    $script:mutex.ReleaseMutex()
}
