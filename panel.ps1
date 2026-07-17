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

# Open as a split beside the focused pane, else the workspace's first pane.
if (-not $pane -and $panes) { $pane = $panes[0].pane_id }
if (-not $pane) { Fail "no pane to attach to in $ws" }

$openJson = (Herdr plugin pane open --plugin $pluginId --entrypoint todos `
        --placement split --direction right --target-pane $pane --no-focus | Out-String).Trim()
$new = ''
if ($openJson) { try { $new = ($openJson | ConvertFrom-Json).result.plugin_pane.pane.pane_id } catch {} }
if (-not $new) { Fail 'herdr plugin pane open failed' }
"opened $new in $ws"
