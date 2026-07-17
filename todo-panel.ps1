# Live TO-DO panel: mirrors the focused agent's task list (TaskCreate/TaskUpdate) into a herdr pane
# so a dev can follow the model's plan as it works. Windows / PowerShell, no dependencies.
#
# It resolves the agent sharing this pane's tab, finds that session's transcript
# (~/.claude/projects/**/<session-id>.jsonl), replays TaskCreate (ids 1..N in order) + TaskUpdate
# (taskId -> status) into the current list, and redraws when the transcript changes. Poll-based, so
# it catches mid-turn task edits. Press q to quit.
#
# Theming: reads $HERDR_PLUGIN_CONFIG_DIR/config.toml (a flat key = value file). `theme` picks a
# preset; individual colors (`bg`, `fg`, `done`, `active`, `pending`, `accent`, hex "#rrggbb")
# override it. A `bg` paints the whole pane. Size/placement live in panel.ps1 (the opener).
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so glyphs are
# built from [char] codes rather than written as literals.

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
$esc = [char]27

# Glyphs (from code points so the source stays ASCII).
$G_CHECK = [char]0x2713; $G_PLAY = [char]0x25B6; $G_CIRC = [char]0x25CB; $G_CROSS = [char]0x2717
$MIDDOT = [char]0x00B7; $HR = [string][char]0x2500

# ---- config + theme ----
$THEMES = @{
    default  = @{ bg = ''; fg = '';        title = '#56b6c2'; done = '#6a737d'; active = '#e5c07b'; pending = '#61afef'; rule = '#3b4048' }
    midnight = @{ bg = '#11131a'; fg = '#c8d3f5'; title = '#7dcfff'; done = '#4b5263'; active = '#e0af68'; pending = '#7aa2f7'; rule = '#2a2f3d' }
    mono     = @{ bg = '#1c1c1c'; fg = '#d0d0d0'; title = '#bcbcbc'; done = '#585858'; active = '#ffffff'; pending = '#9e9e9e'; rule = '#3a3a3a' }
    forest   = @{ bg = '#0f1a12'; fg = '#cfe8d4'; title = '#8fd694'; done = '#4a5a4d'; active = '#e6c07b'; pending = '#7fb069'; rule = '#243026' }
}

function Read-Config {
    $cfg = @{}
    $dir = $env:HERDR_PLUGIN_CONFIG_DIR
    if (-not $dir) { return $cfg }
    $file = Join-Path $dir 'config.toml'
    if (-not (Test-Path $file)) { return $cfg }
    foreach ($line in (Get-Content -LiteralPath $file)) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') {
            $k = $matches[1]
            $v = $matches[2].Trim() -replace '\s+#.*$', ''
            if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { $v = $matches[1] }
            $cfg[$k] = $v
        }
    }
    $cfg
}

function Resolve-Palette($cfg) {
    $name = if ($cfg.theme) { $cfg.theme } else { 'default' }
    $p = if ($THEMES.ContainsKey($name)) { $THEMES[$name].Clone() } else { $THEMES['default'].Clone() }
    foreach ($k in 'bg', 'fg', 'title', 'done', 'active', 'pending', 'rule') {
        if ($cfg[$k]) { $p[$k] = $cfg[$k] }
    }
    $p
}

function HexRGB([string]$hex) {
    $h = $hex.TrimStart('#')
    if ($h.Length -ne 6) { return $null }
    [int]("0x" + $h.Substring(0, 2)), [int]("0x" + $h.Substring(2, 2)), [int]("0x" + $h.Substring(4, 2))
}
function Fg([string]$hex) { if (-not $hex) { return '' }; $c = HexRGB $hex; if (-not $c) { return '' }; "$esc[38;2;$($c[0]);$($c[1]);$($c[2])m" }
function Bg([string]$hex) { if (-not $hex) { return '' }; $c = HexRGB $hex; if (-not $c) { return '' }; "$esc[48;2;$($c[0]);$($c[1]);$($c[2])m" }

# ---- agent + transcript ----
function Get-TabAgent {
    $ws = $env:HERDR_WORKSPACE_ID
    if (-not $ws) { return $null }
    $panes = (& $herdr pane list --workspace $ws 2>$null | ConvertFrom-Json).result.panes
    if (-not $panes) { return $null }
    $me = $env:HERDR_PANE_ID; $tab = $env:HERDR_TAB_ID
    $p = $panes | Where-Object { $_.agent -and $_.pane_id -ne $me -and (-not $tab -or $_.tab_id -eq $tab) } | Select-Object -First 1
    if (-not $p) { return $null }
    @{ session = [string]$p.agent_session.value; agent = [string]$p.agent; pane = [string]$p.pane_id }
}

function Find-Transcript([string]$sessionId) {
    if (-not $sessionId) { return $null }
    $root = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path $root)) { return $null }
    $f = Get-ChildItem -Path $root -Recurse -File -Filter "$sessionId.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.FullName } else { $null }
}

function Read-Tasks([string]$path) {
    $tasks = New-Object System.Collections.Generic.List[object]
    $byId = @{}
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        if ($line.IndexOf('TaskCreate') -lt 0 -and $line.IndexOf('TaskUpdate') -lt 0) { continue }
        $obj = $null; try { $obj = $line | ConvertFrom-Json } catch { continue }
        $content = $obj.message.content
        if ($content -isnot [System.Array]) { continue }
        foreach ($b in $content) {
            if ($b.type -ne 'tool_use') { continue }
            if ($b.name -eq 'TaskCreate') {
                $id = [string]($tasks.Count + 1)
                $t = [pscustomobject]@{ id = $id; subject = [string]$b.input.subject; activeForm = [string]$b.input.activeForm; status = 'pending' }
                $tasks.Add($t); $byId[$id] = $t
            }
            elseif ($b.name -eq 'TaskUpdate') {
                $id = [string]$b.input.taskId
                if ($byId.ContainsKey($id) -and $b.input.status) { $byId[$id].status = [string]$b.input.status }
            }
        }
    }
    $tasks
}

# ---- render ----
# Each row is @{ plain = '<text no ANSI>'; styled = '<text with color>' } so padding uses plain len.
# $inputBuf: when not $null, the footer is a note-entry line. $status: a transient message.
function Render($tasks, $agent, $ws, $pal, $inputBuf, $status) {
    $bg = Bg $pal.bg
    $fg = Fg $pal.fg
    # "reset" keeps the theme background: a bare \e[0m would clear the bg, leaving black gaps after
    # every colored span. Re-applying $bg after the reset keeps the whole line on the theme color.
    $reset = "$esc[0m$bg"
    $dim = "$esc[2m"
    try { $W = [Console]::WindowWidth } catch { $W = 44 }
    try { $H = [Console]::WindowHeight } catch { $H = 24 }
    if ($W -lt 10) { $W = 44 }; if ($H -lt 4) { $H = 24 }

    $rows = New-Object System.Collections.Generic.List[object]
    $done = @($tasks | Where-Object { $_.status -eq 'completed' }).Count
    $total = $tasks.Count
    $who = @($agent, $ws | Where-Object { $_ }) -join " $MIDDOT "
    $rows.Add(@{ plain = " TO-DOs $who"; styled = " $(Fg $pal.title)$esc[1mTO-DOs$reset$fg $dim$who$reset$fg" })
    $rows.Add(@{ plain = ' ' + ($HR * ($W - 2)); styled = " $(Fg $pal.rule)$($HR * ($W - 2))$reset$fg" })
    if ($total -eq 0) {
        $rows.Add(@{ plain = '  (no tasks yet - the agent has not planned this turn)'; styled = "  $dim(no tasks yet - the agent has not planned this turn)$reset$fg" })
    }
    else {
        foreach ($t in $tasks) {
            switch ($t.status) {
                'completed'   { $g = "$(Fg $pal.done)$G_CHECK$reset$fg"; $label = $t.subject; $s = "$dim$label$reset$fg" }
                'in_progress' { $g = "$(Fg $pal.active)$G_PLAY$reset$fg"; $label = if ($t.activeForm) { $t.activeForm } else { $t.subject }; $s = "$(Fg $pal.active)$esc[1m$label$reset$fg" }
                'cancelled'   { $g = "$(Fg $pal.done)$G_CROSS$reset$fg"; $label = $t.subject; $s = "$dim$label$reset$fg" }
                default       { $g = "$(Fg $pal.pending)$G_CIRC$reset$fg"; $label = $t.subject; $s = "$(Fg $pal.pending)$label$reset$fg" }
            }
            $num = "{0,2}" -f $t.id
            $rows.Add(@{ plain = "  X $num $label"; styled = "  $g $dim$num$reset$fg $s" })
        }
        $rows.Add(@{ plain = ''; styled = '' })
        $rows.Add(@{ plain = "  $done/$total done"; styled = "  $dim$done/$total done$reset$fg" })
    }
    $rows.Add(@{ plain = ''; styled = '' })
    if ($null -ne $inputBuf) {
        $cur = [char]0x2588
        $rows.Add(@{ plain = "  note> $inputBuf"; styled = "  $(Fg $pal.active)note>$reset$fg $inputBuf$(Fg $pal.active)$cur$reset$fg" })
        $rows.Add(@{ plain = '  Enter send to agent   Esc cancel'; styled = "  $dim Enter send to agent   Esc cancel$reset$fg" })
    }
    elseif ($status) {
        $rows.Add(@{ plain = "  $status"; styled = "  $(Fg $pal.title)$status$reset$fg" })
        $rows.Add(@{ plain = '  q close   s note to agent'; styled = "  $dim q close   s note to agent$reset$fg" })
    }
    else {
        $rows.Add(@{ plain = '  q close   s note to agent'; styled = "  $dim q close   s note to agent$reset$fg" })
    }

    $out = [System.Text.StringBuilder]::new()
    [void]$out.Append("$bg$esc[2J$esc[H") # set bg, clear to it, home
    $n = $rows.Count
    for ($i = 0; $i -lt $n; $i++) {
        $plain = [string]$rows[$i].plain
        $styled = [string]$rows[$i].styled
        $pad = $W - $plain.Length; if ($pad -lt 0) { $pad = 0 }
        [void]$out.Append("$bg$fg$styled" + (' ' * $pad) + $reset)
        if ($i -lt $n - 1) { [void]$out.Append("`n") }  # no trailing newline: never scroll
    }
    [void]$out.Append("$bg$esc[0J$reset")  # paint the rest of the pane with the theme bg
    [Console]::Write($out.ToString())
}

# ---- main loop (skipped when dot-sourced for tests) ----
if ($MyInvocation.InvocationName -eq '.') { return }
$pal = Resolve-Palette (Read-Config)
$ws = $env:HERDR_WORKSPACE_ID

# Note-entry mode (v2 "steer"): type a note and send it to the agent's input via `herdr agent
# send` (fills without submitting, then focuses the agent, like reviewr's Send). Returns a status.
function Send-Note($agentPane, $agent, $tasks) {
    $buf = ''
    while ($true) {
        Render $tasks $agent $ws $pal $buf ''
        $ik = [Console]::ReadKey($true)
        if ($ik.Key -eq 'Enter') {
            if ($buf.Trim()) {
                & $herdr agent send $agentPane $buf 2>$null | Out-Null
                & $herdr agent focus $agentPane 2>$null | Out-Null
                return "note sent to $agent"
            }
            return ''
        }
        if ($ik.Key -eq 'Escape') { return '' }
        if ($ik.Key -eq 'Backspace') { if ($buf.Length) { $buf = $buf.Substring(0, $buf.Length - 1) }; continue }
        if ($ik.KeyChar -and [int]$ik.KeyChar -ge 32) { $buf += $ik.KeyChar }
    }
}

[Console]::Write("$esc[?25l$esc[2J")  # hide cursor, clear once
try {
    $lastRender = ''; $lastMtime = [datetime]::MinValue; $lastPath = ''; $tasks = @()
    $agentPane = ''; $status = ''; $statusAt = [datetime]::MinValue
    while ($true) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq 'q') { break }
            if (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'C') { break }
            if ($k.KeyChar -eq 's' -and $agentPane) {
                $status = Send-Note $agentPane $agent $tasks
                $statusAt = [datetime]::Now
                $lastRender = ''  # force redraw out of input mode
            }
        }
        $agentInfo = Get-TabAgent
        $agent = if ($agentInfo) { $agentInfo.agent } else { '' }
        $agentPane = if ($agentInfo) { $agentInfo.pane } else { '' }
        $path = if ($agentInfo) { Find-Transcript $agentInfo.session } else { $null }
        if ($path -and (Test-Path $path)) {
            $mtime = (Get-Item $path).LastWriteTimeUtc
            if ($path -ne $lastPath -or $mtime -ne $lastMtime) { $tasks = Read-Tasks $path; $lastMtime = $mtime; $lastPath = $path }
            $key = "$path|$mtime|$agent|$status"
        }
        else { $tasks = @(); $key = "none|$agent|$status" }
        if ($status -and ([datetime]::Now - $statusAt).TotalSeconds -gt 5) { $status = ''; $lastRender = '' }
        if ($key -ne $lastRender) { Render $tasks $agent $ws $pal $null $status; $lastRender = $key }
        Start-Sleep -Milliseconds 1000
    }
}
finally { [Console]::Write("$esc[?25h$esc[0m") }
