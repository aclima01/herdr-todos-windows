# Live TO-DO panel: mirrors the focused agent's task list (TaskCreate/TaskUpdate) into a herdr pane
# so a dev can follow the model's plan as it works. Windows / PowerShell, no dependencies.
#
# It resolves the agent sharing this pane's tab, finds that session's transcript
# (~/.claude/projects/**/<session-id>.jsonl), replays TaskCreate (ids 1..N in order) + TaskUpdate
# (taskId -> status) into the current list, and redraws when the transcript changes. Poll-based, so
# it catches mid-turn task edits (status-change events would be too coarse). Press q to quit.
#
# Source is pure ASCII on purpose: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, which
# corrupts multi-byte literals, so glyphs are built from [char] codes at runtime instead.

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
$esc = [char]27

function Ansi([string]$code) { "$esc[$code" + "m" }
$RESET = Ansi '0'; $DIM = Ansi '2'; $BOLD = Ansi '1'
$GREEN = Ansi '32'; $YELLOW = Ansi '93'; $CYAN = Ansi '36'; $GREY = Ansi '90'

# Glyphs (built from code points so the source stays ASCII).
$G_CHECK = [char]0x2713   # check
$G_PLAY = [char]0x25B6    # in-progress
$G_CIRC = [char]0x25CB    # pending
$G_CROSS = [char]0x2717   # cancelled
$MIDDOT = [char]0x00B7    # separator
$HR = [string][char]0x2500

# The agent that shares this panel's tab (excluding this pane). Returns @{ session; agent } or $null.
function Get-TabAgent {
    $ws = $env:HERDR_WORKSPACE_ID
    if (-not $ws) { return $null }
    $panes = (& $herdr pane list --workspace $ws 2>$null | ConvertFrom-Json).result.panes
    if (-not $panes) { return $null }
    $me = $env:HERDR_PANE_ID
    $tab = $env:HERDR_TAB_ID
    $p = $panes |
        Where-Object { $_.agent -and $_.pane_id -ne $me -and (-not $tab -or $_.tab_id -eq $tab) } |
        Select-Object -First 1
    if (-not $p) { return $null }
    @{ session = [string]$p.agent_session.value; agent = [string]$p.agent }
}

function Find-Transcript([string]$sessionId) {
    if (-not $sessionId) { return $null }
    $root = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path $root)) { return $null }
    $f = Get-ChildItem -Path $root -Recurse -File -Filter "$sessionId.jsonl" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($f) { $f.FullName } else { $null }
}

# Replay the transcript's Task tool calls into the ordered task list.
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
                $t = [pscustomobject]@{
                    id = $id; subject = [string]$b.input.subject
                    activeForm = [string]$b.input.activeForm; status = 'pending'
                }
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

function Render([object]$tasks, [string]$agent, [string]$ws) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("$esc[2J$esc[H")  # clear + home
    $done = @($tasks | Where-Object { $_.status -eq 'completed' }).Count
    $total = $tasks.Count
    $who = @($agent, $ws | Where-Object { $_ }) -join " $MIDDOT "
    [void]$sb.AppendLine("$BOLD$CYAN TO-DOs$RESET $DIM$who$RESET")
    [void]$sb.AppendLine("$GREY " + ($HR * 46) + $RESET)
    if ($total -eq 0) {
        [void]$sb.AppendLine("$DIM  (no tasks yet - the agent has not planned this turn)$RESET")
    }
    else {
        foreach ($t in $tasks) {
            switch ($t.status) {
                'completed' { $glyph = "$GREEN$G_CHECK$RESET"; $text = "$DIM$($t.subject)$RESET" }
                'in_progress' {
                    $glyph = "$YELLOW$G_PLAY$RESET"
                    $label = if ($t.activeForm) { $t.activeForm } else { $t.subject }
                    $text = "$BOLD$YELLOW$label$RESET"
                }
                'cancelled' { $glyph = "$GREY$G_CROSS$RESET"; $text = "$GREY$($t.subject)$RESET" }
                default { $glyph = "$GREY$G_CIRC$RESET"; $text = $t.subject }
            }
            $num = "{0,2}" -f $t.id
            [void]$sb.AppendLine("  $glyph $GREY$num$RESET $text")
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("$DIM  $done/$total done$RESET")
    }
    [void]$sb.Append("$GREY`n  q to close$RESET")
    [Console]::Write($sb.ToString())
}

# --- main loop (skipped when dot-sourced for tests) ---
if ($MyInvocation.InvocationName -eq '.') { return }
[Console]::Write("$esc[?25l")  # hide cursor
try {
    $lastRender = ''
    $lastMtime = [datetime]::MinValue
    $lastPath = ''
    $tasks = @()
    while ($true) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq 'q') { break }
            if (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'C') { break }
        }
        $agentInfo = Get-TabAgent
        $agent = if ($agentInfo) { $agentInfo.agent } else { '' }
        $path = if ($agentInfo) { Find-Transcript $agentInfo.session } else { $null }

        if ($path -and (Test-Path $path)) {
            $mtime = (Get-Item $path).LastWriteTimeUtc
            if ($path -ne $lastPath -or $mtime -ne $lastMtime) {
                $tasks = Read-Tasks $path
                $lastMtime = $mtime; $lastPath = $path
            }
            $key = "$path|$mtime|$agent"
        }
        else {
            $tasks = @()
            $key = "none|$agent"
        }

        if ($key -ne $lastRender) {
            Render $tasks $agent $env:HERDR_WORKSPACE_ID
            $lastRender = $key
        }
        Start-Sleep -Milliseconds 1000
    }
}
finally {
    [Console]::Write("$esc[?25h$esc[0m")  # show cursor, reset
}
