# Toggle / open / close the TO-DOs panel (Windows). Opens it as a right split beside the focused
# pane so it sits next to the agent whose plan it mirrors. Finds the panel by its "todos" label in
# the live pane list (no state file). Native JSON, no jq.
[CmdletBinding()]
param([string]$Mode = 'toggle')

$ErrorActionPreference = 'SilentlyContinue'

$herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
$pluginId = if ($env:HERDR_PLUGIN_ID) { $env:HERDR_PLUGIN_ID } else { 'aclima.herdr-todos-windows' }
function Herdr { & $herdr @args 2>$null }
function Fail([string]$msg) { [Console]::Error.WriteLine("todos: $msg"); exit 1 }

# Layout config ($HERDR_PLUGIN_CONFIG_DIR/config.toml, flat key = value): placement, direction,
# width, height. Colors live in todo-panel.ps1. Defaults: a 44-col right split.
function Read-Config {
    $cfg = @{}
    $dir = $env:HERDR_PLUGIN_CONFIG_DIR
    if ($dir) {
        $file = Join-Path $dir 'config.toml'
        if (Test-Path $file) {
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
        }
    }
    $cfg
}
$cfg = Read-Config
$placement = if ($cfg.placement) { $cfg.placement } else { 'split' }
$direction = if ($cfg.direction) { $cfg.direction } else { 'right' }

$ws = $env:HERDR_WORKSPACE_ID
$pane = $env:HERDR_PANE_ID
if (-not $ws) { Fail 'no workspace context (invoke from inside herdr)' }

$panesJson = (Herdr pane list --workspace $ws | Out-String).Trim()
if (-not $panesJson) { Fail "herdr pane list failed for $ws" }
try { $panes = ($panesJson | ConvertFrom-Json).result.panes } catch { Fail "herdr pane list failed for $ws" }

$existing = @()
if ($panes) { $existing = @($panes | Where-Object { $_.label -eq 'todos' } | ForEach-Object { $_.pane_id }) }

function Close-All {
    foreach ($p in $existing) { if ($p) { Herdr pane close $p | Out-Null } }
    "closed $($existing -join ' ') in $ws"
}

if ($Mode -eq 'close') { if ($existing.Count) { Close-All } else { "close: nothing open in $ws" }; exit 0 }
if ($Mode -eq 'toggle' -and $existing.Count) { Close-All; exit 0 }
if ($Mode -eq 'open' -and $existing.Count) { "open: already open in $ws"; exit 0 }

# Event auto-open (worktree.created / pane.agent_detected): gated by `auto_open` (default on), only
# for split/tab placement, and idempotent — never opens a second panel. Then falls through to open.
if ($Mode -eq 'event') {
    if ("$($cfg.auto_open)" -match '^(?i:false|0|no|off)$') { "event: auto_open off"; exit 0 }
    if ($placement -ne 'split' -and $placement -ne 'tab') { "event: $placement not auto-opened"; exit 0 }
    if ($existing.Count) { "event: already open in $ws"; exit 0 }
}

# Build placement args from config. herdr rules: split/zoomed attach to a target pane; tab targets
# the workspace; popup/overlay target the active pane automatically. --width/--height are honored
# ONLY for popup (a split's size is adjusted interactively with < / >, not set here).
$openArgs = @('--placement', $placement)
if ($placement -eq 'split' -or $placement -eq 'zoomed') {
    if (-not $pane -and $panes) { $pane = $panes[0].pane_id }
    if (-not $pane) { Fail "no pane to attach to in $ws" }
    $openArgs += @('--target-pane', $pane)
    if ($placement -eq 'split') { $openArgs += @('--direction', $direction) }
}
elseif ($placement -eq 'tab') { $openArgs += @('--workspace', $ws) }
elseif ($placement -eq 'popup') {
    if ($cfg.width) { $openArgs += @('--width', [string]$cfg.width) }
    if ($cfg.height) { $openArgs += @('--height', [string]$cfg.height) }
}

$openJson = (Herdr plugin pane open --plugin $pluginId --entrypoint todos `
        @openArgs --no-focus | Out-String).Trim()
$new = ''
if ($openJson) { try { $new = ($openJson | ConvertFrom-Json).result.plugin_pane.pane.pane_id } catch {} }
if (-not $new) { Fail 'herdr plugin pane open failed' }

# herdr's open takes no size for a split, so resize to the configured target afterward: `width`
# (columns) for a right split, `height` (rows) for a down split. `pane resize --amount` is a
# fraction of the split's total, and for the new (second) pane, left/up grows it, right/down shrinks.
if ($placement -eq 'split') {
    $target = if ($direction -eq 'down') { $cfg.height } else { $cfg.width }
    if ($target) {
        $lay = (Herdr pane layout --pane $new | ConvertFrom-Json).result.layout
        $mine = $lay.panes | Where-Object { $_.pane_id -eq $new } | Select-Object -First 1
        if ($mine) {
            if ($direction -eq 'down') { $cur = [int]$mine.rect.height; $tot = [int]$lay.area.height; $grow = 'up'; $shrink = 'down' }
            else { $cur = [int]$mine.rect.width; $tot = [int]$lay.area.width; $grow = 'left'; $shrink = 'right' }
            $delta = [int]$target - $cur
            if ($delta -ne 0 -and $tot -gt 0) {
                $amount = [Math]::Round([Math]::Abs($delta) / $tot, 3)
                $dir = if ($delta -gt 0) { $grow } else { $shrink }
                Herdr pane resize --pane $new --direction $dir --amount ([string]$amount) | Out-Null
            }
        }
    }
}
"opened $new in $ws"
