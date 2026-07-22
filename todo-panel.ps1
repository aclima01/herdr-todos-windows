# Live TO-DO panel: mirrors the focused agent's task list (TaskCreate/TaskUpdate) into a herdr pane
# so a dev can follow the model's plan as it works. Windows / PowerShell, no dependencies.
#
# It resolves the agent sharing this pane's tab, finds that session's transcript
# (~/.claude/projects/**/<session-id>.jsonl), and replays TaskCreate (ids 1..N in order) +
# TaskUpdate (taskId -> status). Reads are incremental: a byte high-watermark means each poll only
# parses the newly-appended lines, not the whole file.
#
# Keys: q close; s send a note to the agent; j/k or arrows and PageUp/PageDown scroll; g re-follows
# the active task.
#
# Theming: $HERDR_PLUGIN_CONFIG_DIR/config.toml (flat key = value). `theme` picks a preset; per-
# color hex overrides win. A `bg` paints the whole pane. Size/placement live in panel.ps1.
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so glyphs are
# built from [char] codes rather than written as literals.

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
$esc = [char]27

# Glyphs (from code points so the source stays ASCII).
$G_CHECK = [char]0x2713; $G_PLAY = [char]0x25B6; $G_CIRC = [char]0x25CB; $G_CROSS = [char]0x2717
$MIDDOT = [char]0x00B7; $HR = [string][char]0x2500; $G_UP = [char]0x2191; $G_DOWN = [char]0x2193
$G_GEAR = [char]0x2699; $G_BLOCK = [char]0x26D4; $G_NOW = [char]0x203A  # working / blocked / activity

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
    foreach ($k in 'bg', 'fg', 'title', 'done', 'active', 'pending', 'rule') { if ($cfg[$k]) { $p[$k] = $cfg[$k] } }
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
    @{ session = [string]$p.agent_session.value; agent = [string]$p.agent; pane = [string]$p.pane_id
        status = [string]$p.agent_status; activity = [string]$p.terminal_title }
}

function Find-Transcript([string]$sessionId) {
    if (-not $sessionId) { return $null }
    $root = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path $root)) { return $null }
    $f = Get-ChildItem -Path $root -Recurse -File -Filter "$sessionId.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $f.FullName } else { $null }
}

# ---- incremental task reader (byte high-watermark) ----
$script:T_tasks = New-Object System.Collections.Generic.List[object]
$script:T_byId = @{}
$script:T_offset = [long]0
$script:T_path = ''
$script:EmptyReason = @()   # why the list is empty (diagnostic), set by the poll loop
$script:AgentStatus = ''    # working | idle | blocked (from pane list), set by the poll loop
$script:AgentActivity = ''  # the agent's current terminal_title, set by the poll loop
$script:PlanPath = ''       # latest plan file (~/.claude/plans/*.md) named by the transcript
$script:PlanMtime = [datetime]::MinValue
$script:PlanTasks = @()     # parsed plan steps, shown only while there are no real tasks
$script:FromPlan = $false

function Reset-Tasks {
    $script:T_tasks = New-Object System.Collections.Generic.List[object]
    $script:T_byId = @{}
    $script:T_offset = [long]0
    $script:PlanPath = ''; $script:PlanTasks = @(); $script:PlanMtime = [datetime]::MinValue
}

function Apply-Line([string]$line) {
    # Two schemes exist across Claude Code versions: the newer TaskCreate/TaskUpdate (incremental),
    # and the older TodoWrite (one tool call rewrites the whole list). Support both. Plan-mode
    # attachments name the plan file (~/.claude/plans/*.md); track the latest as a fallback source.
    $hasTask = ($line.IndexOf('TaskCreate') -ge 0 -or $line.IndexOf('TaskUpdate') -ge 0 -or $line.IndexOf('TodoWrite') -ge 0)
    $hasPlan = ($line.IndexOf('planFilePath') -ge 0)
    if (-not $hasTask -and -not $hasPlan) { return }
    $obj = $null; try { $obj = $line | ConvertFrom-Json } catch { return }
    if ($hasPlan -and $obj.attachment -and $obj.attachment.planFilePath) {
        $script:PlanPath = [string]$obj.attachment.planFilePath
        $script:PlanMtime = [datetime]::MinValue   # force a re-read on the next poll
    }
    if (-not $hasTask) { return }
    $content = $obj.message.content
    if ($content -isnot [System.Array]) { return }
    foreach ($b in $content) {
        if ($b.type -ne 'tool_use') { continue }
        if ($b.name -eq 'TaskCreate') {
            $id = [string]($script:T_tasks.Count + 1)
            $t = [pscustomobject]@{ id = $id; subject = [string]$b.input.subject; activeForm = [string]$b.input.activeForm; status = 'pending' }
            $script:T_tasks.Add($t); $script:T_byId[$id] = $t
        }
        elseif ($b.name -eq 'TaskUpdate') {
            $id = [string]$b.input.taskId
            if ($script:T_byId.ContainsKey($id) -and $b.input.status) { $script:T_byId[$id].status = [string]$b.input.status }
        }
        elseif ($b.name -eq 'TodoWrite') {
            # Whole-list rewrite. Replace the task list (keep the byte offset — only the list resets).
            $list = New-Object System.Collections.Generic.List[object]
            $map = @{}
            if ($b.input.todos -is [System.Array]) {
                $i = 0
                foreach ($td in $b.input.todos) {
                    $i++
                    $subj = if ($td.content) { [string]$td.content } else { [string]$td.subject }
                    $af = if ($td.activeForm) { [string]$td.activeForm } else { '' }
                    $st = if ($td.status) { [string]$td.status } else { 'pending' }
                    $t = [pscustomobject]@{ id = [string]$i; subject = $subj; activeForm = $af; status = $st }
                    $list.Add($t); $map[$t.id] = $t
                }
            }
            $script:T_tasks = $list; $script:T_byId = $map
        }
    }
}

# Parse an approved plan's markdown into task-shaped steps. Checkbox items carry status
# (- [ ] pending, - [x] done) and win when present; otherwise numbered items count, all pending.
function Read-PlanTasks([string]$path) {
    $boxes = New-Object System.Collections.Generic.List[object]
    $nums = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*[-*]\s*\[([ xX])\]\s+(.+)$') {
            $mark = $matches[1]; $body = $matches[2]        # capture before any further -match
            $st = if ($mark -eq 'x') { 'completed' } else { 'pending' }   # -eq is case-insensitive
            $boxes.Add(@{ s = $body; st = $st })
        }
        elseif ($line -match '^\s*\d+[\.\)]\s+(.+)$') { $nums.Add(@{ s = $matches[1]; st = 'pending' }) }
    }
    $src = if ($boxes.Count) { $boxes } else { $nums }
    $out = @(); $i = 0
    foreach ($e in $src) {
        $i++
        $subj = ([string]$e.s -replace '\*\*([^*]+)\*\*', '$1' -replace '`([^`]+)`', '$1').Trim()
        if ($subj.Length -gt 120) { $subj = $subj.Substring(0, 120) }
        $out += [pscustomobject]@{ id = [string]$i; subject = $subj; activeForm = ''; status = [string]$e.st }
    }
    $out
}

# Parse only the bytes appended since the last call. Returns $true when new complete lines applied.
# A new transcript path, or a shrunken file (rotation), resets the accumulated state.
function Update-Tasks([string]$path) {
    if ($path -ne $script:T_path) { $script:T_path = $path; Reset-Tasks }
    $changed = $false
    $fs = $null
    try { $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite) } catch { return $false }
    try {
        $len = $fs.Length
        if ($len -lt $script:T_offset) { Reset-Tasks }         # truncated / rotated
        $count = $len - $script:T_offset
        if ($count -le 0) { return $false }
        if ($count -gt 20000000) { $count = 20000000 }         # cap a single read; the rest follows next poll
        [void]$fs.Seek($script:T_offset, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ([int]$count)
        $read = $fs.Read($buf, 0, [int]$count)
        $lastNL = -1
        for ($i = $read - 1; $i -ge 0; $i--) { if ($buf[$i] -eq 10) { $lastNL = $i; break } }
        if ($lastNL -lt 0) { return $false }                   # only a partial line so far; wait
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $lastNL + 1)
        $script:T_offset += ($lastNL + 1)
        foreach ($line in ($text -split "`n")) { if ($line) { Apply-Line $line; $changed = $true } }
    }
    finally { $fs.Close() }
    $changed
}

# ---- render ----
function Get-VisRows { [Math]::Max(1, [Console]::WindowHeight - 7) }  # rows reserved for chrome

# Rows are @{ plain; styled } so padding uses the visible (plain) length.
function Render($tasks, $agent, $ws, $pal, $inputBuf, $status, $scroll) {
    $bg = Bg $pal.bg; $fg = Fg $pal.fg
    $reset = "$esc[0m$bg"                 # keep the theme bg after every reset (no black gaps)
    $dim = "$esc[2m"
    try { $W = [Console]::WindowWidth } catch { $W = 44 }
    try { $H = [Console]::WindowHeight } catch { $H = 24 }
    if ($W -lt 10) { $W = 44 }; if ($H -lt 4) { $H = 24 }
    $visRows = Get-VisRows

    $rows = New-Object System.Collections.Generic.List[object]
    $done = @($tasks | Where-Object { $_.status -eq 'completed' }).Count
    $total = $tasks.Count
    # Header: TO-DOs <agent> <status glyph> · <ws>
    $red = "$esc[38;2;224;108;117m"
    $sChar = ''; $sStyled = ''
    switch ($script:AgentStatus) {
        'working' { $sChar = [string]$G_GEAR; $sStyled = "$(Fg $pal.active)$G_GEAR$reset$fg" }
        'blocked' { $sChar = [string]$G_BLOCK; $sStyled = "$red$esc[1m$G_BLOCK$reset$fg" }
        'idle'    { $sChar = [string]$G_CHECK; $sStyled = "$(Fg $pal.done)$G_CHECK$reset$fg" }
        default { }
    }
    $hp = ' TO-DOs'; $hs = " $(Fg $pal.title)$esc[1mTO-DOs$reset$fg"
    if ($agent) {
        $hp += " $agent"; $hs += " $dim$agent$reset$fg"
        if ($sChar) { $hp += " $sChar"; $hs += " $sStyled" }
    }
    if ($ws) { $hp += " $MIDDOT $ws"; $hs += " $dim$MIDDOT $ws$reset$fg" }
    $rows.Add(@{ plain = $hp; styled = $hs })
    $rows.Add(@{ plain = ' ' + ($HR * ($W - 2)); styled = " $(Fg $pal.rule)$($HR * ($W - 2))$reset$fg" })

    # "Now" line: a blocked warning, or the agent's current activity (terminal_title) while working.
    if ($script:AgentStatus -eq 'blocked') {
        $rows.Add(@{ plain = "  $G_BLOCK blocked - waiting for your input"; styled = "  $red$esc[1m$G_BLOCK blocked - waiting for your input$reset$fg" })
    }
    elseif ($script:AgentStatus -eq 'working') {
        $act = ($script:AgentActivity -replace '[\x00-\x1f\x7f]', ' ' -replace '^[^\p{L}\p{N}]+\s*', '').Trim()
        if ($act) {
            $max = $W - 6
            if ($max -gt 1 -and $act.Length -gt $max) { $act = $act.Substring(0, $max) + [char]0x2026 }
            $rows.Add(@{ plain = "  $G_NOW $act"; styled = "  $(Fg $pal.active)$G_NOW$reset$fg $dim$act$reset$fg" })
        }
    }

    if ($total -eq 0) {
        if ($script:EmptyReason -and $script:EmptyReason.Count) {
            foreach ($ln in $script:EmptyReason) { $rows.Add(@{ plain = "  $ln"; styled = "  $dim$ln$reset$fg" }) }
        }
        else {
            $rows.Add(@{ plain = '  (no tasks yet - the agent has not planned this turn)'; styled = "  $dim(no tasks yet - the agent has not planned this turn)$reset$fg" })
        }
    }
    else {
        $from = $scroll
        $to = [Math]::Min($scroll + $visRows, $total)
        for ($i = $from; $i -lt $to; $i++) {
            $t = $tasks[$i]
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
        $pos = ''; $posP = ''
        if ($total -gt $visRows) {
            $up = if ($scroll -gt 0) { $G_UP } else { ' ' }
            $dn = if ($to -lt $total) { $G_DOWN } else { ' ' }
            $posP = "   $up$dn $($from + 1)-$to/$total"
            $pos = "   $(Fg $pal.pending)$up$dn$reset$fg $dim$($from + 1)-$to/$total$reset$fg"
        }
        $planP = ''; $plan = ''
        if ($script:FromPlan) { $planP = " $MIDDOT plan"; $plan = " $dim$MIDDOT$reset$fg $(Fg $pal.title)plan$reset$fg" }
        $rows.Add(@{ plain = "  $done/$total done$planP$posP"; styled = "  $dim$done/$total done$reset$fg$plan$pos" })
    }

    $rows.Add(@{ plain = ''; styled = '' })
    if ($null -ne $inputBuf) {
        $cur = [char]0x2588
        $rows.Add(@{ plain = "  note> $inputBuf"; styled = "  $(Fg $pal.active)note>$reset$fg $inputBuf$(Fg $pal.active)$cur$reset$fg" })
        $rows.Add(@{ plain = '  Enter send to agent   Esc cancel'; styled = "  $dim Enter send to agent   Esc cancel$reset$fg" })
    }
    elseif ($status) {
        $rows.Add(@{ plain = "  $status"; styled = "  $(Fg $pal.title)$status$reset$fg" })
    }
    else {
        $rows.Add(@{ plain = '  q close  s note  j/k scroll'; styled = "  $dim q close  s note  j/k scroll$reset$fg" })
    }

    $out = [System.Text.StringBuilder]::new()
    [void]$out.Append("$bg$esc[2J$esc[H")
    $n = $rows.Count
    for ($i = 0; $i -lt $n; $i++) {
        $plain = [string]$rows[$i].plain
        $styled = [string]$rows[$i].styled
        $pad = $W - $plain.Length; if ($pad -lt 0) { $pad = 0 }
        [void]$out.Append("$bg$fg$styled" + (' ' * $pad) + $reset)
        if ($i -lt $n - 1) { [void]$out.Append("`n") }
    }
    [void]$out.Append("$bg$esc[0J$reset")
    [Console]::Write($out.ToString())
}

# ---- helpers ----
function Active-Index($tasks) {
    for ($i = 0; $i -lt $tasks.Count; $i++) { if ($tasks[$i].status -eq 'in_progress') { return $i } }
    -1
}
function Clamp-Scroll([int]$scroll, [int]$total) {
    $max = [Math]::Max(0, $total - (Get-VisRows))
    if ($scroll -gt $max) { $scroll = $max }
    if ($scroll -lt 0) { $scroll = 0 }
    $scroll
}

# Note-entry (v2 "steer"): type a note, Enter sends it to the agent input via `herdr agent send`
# (fills without submitting) then focuses the agent, like reviewr's Send. Returns a status string.
function Send-Note($agentPane, $agent, $tasks, $scroll) {
    $buf = ''
    while ($true) {
        Render $tasks $agent $ws $pal $buf '' $scroll
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

# ---- main loop (skipped when dot-sourced for tests) ----
if ($MyInvocation.InvocationName -eq '.') { return }
$pal = Resolve-Palette (Read-Config)
$ws = $env:HERDR_WORKSPACE_ID
[Console]::Write("$esc[?25l$esc[2J")  # hide cursor, clear once
try {
    $lastRender = ''; $lastPoll = [datetime]::MinValue; $agent = ''; $agentPane = ''
    $status = ''; $statusAt = [datetime]::MinValue
    $scroll = 0; $follow = $true; $lastActive = -1; $view = $script:T_tasks
    while ($true) {
        $dirty = $false
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            $page = [Math]::Max(1, (Get-VisRows) - 1)
            if ($k.KeyChar -eq 'q') { throw 'quit' }
            elseif (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'C') { throw 'quit' }
            elseif ($k.KeyChar -eq 's' -and $agentPane) { $status = Send-Note $agentPane $agent $view $scroll; $statusAt = [datetime]::Now; $dirty = $true }
            elseif ($k.KeyChar -eq 'j' -or $k.Key -eq 'DownArrow') { $scroll++; $follow = $false; $dirty = $true }
            elseif ($k.KeyChar -eq 'k' -or $k.Key -eq 'UpArrow') { $scroll--; $follow = $false; $dirty = $true }
            elseif ($k.Key -eq 'PageDown') { $scroll += $page; $follow = $false; $dirty = $true }
            elseif ($k.Key -eq 'PageUp') { $scroll -= $page; $follow = $false; $dirty = $true }
            elseif ($k.KeyChar -eq 'g' -or $k.Key -eq 'Home') { $follow = $true; $dirty = $true }
        }

        if (([datetime]::Now - $lastPoll).TotalMilliseconds -ge 900) {
            $lastPoll = [datetime]::Now
            $info = Get-TabAgent
            $newAgent = if ($info) { $info.agent } else { '' }
            $agentPane = if ($info) { $info.pane } else { '' }
            if ($newAgent -ne $agent) { $agent = $newAgent; $dirty = $true }
            $path = if ($info) { Find-Transcript $info.session } else { $null }
            if ($path) { if (Update-Tasks $path) { $dirty = $true } }
            elseif ($script:T_path) { $script:T_path = ''; Reset-Tasks; $dirty = $true }
            # Diagnose an empty list so a fresh machine self-reports where the chain breaks.
            $reason = @()
            if (-not $env:HERDR_WORKSPACE_ID) { $reason = @('no herdr workspace context') }
            elseif (-not $info) { $reason = @('no Claude agent in this tab.', 'run:  herdr integration install claude') }
            elseif (-not $info.session) { $reason = @("agent '$newAgent' has no session id", '(herdr version mismatch?)') }
            elseif (-not $path) { $reason = @("agent '$newAgent': no transcript found", 'under  ~\.claude\projects') }
            if (($reason -join '|') -ne ($script:EmptyReason -join '|')) { $script:EmptyReason = $reason; $dirty = $true }
            # Live agent state for the "Now" line (free from pane list).
            $newStatus = if ($info) { $info.status } else { '' }
            $newActivity = if ($info) { $info.activity } else { '' }
            if ($newStatus -ne $script:AgentStatus -or $newActivity -ne $script:AgentActivity) {
                $script:AgentStatus = $newStatus; $script:AgentActivity = $newActivity; $dirty = $true
            }
            # Track the latest plan file; re-parse when it changes (steps can get checked off live).
            if ($script:PlanPath -and (Test-Path $script:PlanPath)) {
                $pmt = (Get-Item $script:PlanPath).LastWriteTimeUtc
                if ($pmt -ne $script:PlanMtime) { $script:PlanTasks = @(Read-PlanTasks $script:PlanPath); $script:PlanMtime = $pmt; $dirty = $true }
            }
        }

        if ($status -and ([datetime]::Now - $statusAt).TotalSeconds -gt 5) { $status = ''; $dirty = $true }

        # Real tasks win; with none, mirror the approved plan's steps (live from its file).
        $script:FromPlan = ($script:T_tasks.Count -eq 0 -and $script:PlanTasks.Count -gt 0)
        $view = if ($script:FromPlan) { $script:PlanTasks } else { $script:T_tasks }
        $total = $view.Count
        # Auto-follow the active task (until the user scrolls); re-arm follow when it changes.
        $active = Active-Index $view
        if ($active -ne $lastActive) { $follow = $true; $lastActive = $active }
        if ($follow) {
            if ($active -ge 0) {
                if ($active -lt $scroll) { $scroll = $active }
                elseif ($active -ge $scroll + (Get-VisRows)) { $scroll = $active - (Get-VisRows) + 1 }
            }
            else { $scroll = [Math]::Max(0, $total - (Get-VisRows)) }
        }
        $scroll = Clamp-Scroll $scroll $total

        $key = "$($script:T_path)|$($script:T_offset)|$agent|$status|$scroll|$total|$($script:FromPlan)|$($script:PlanMtime.Ticks)"
        if ($dirty -or $key -ne $lastRender) { Render $view $agent $ws $pal $null $status $scroll; $lastRender = $key }
        Start-Sleep -Milliseconds 60
    }
}
catch { }
finally { [Console]::Write("$esc[?25h$esc[0m") }
