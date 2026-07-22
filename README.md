# Agent TO-DOs for Windows

A live panel that mirrors the focused agent's **task list** into a herdr split pane, so you can
follow the model's plan as it works — which steps are done, which one it's on, and what's left.

The header also shows the agent's **live status** (a colored glyph: `working` / `idle` / `blocked`,
with a red highlight when it's **blocked** and waiting on you), and a "Now" line with what it is
currently working on (from the agent's terminal title). All of it comes free from `herdr pane list`.

```
 TO-DOs  claude  working · my-project
 ----------------------------------------------
  >  Wiring the database ping check          (Now: current activity)
  v  1  Confirm the TO-DO data source
  v  2  Build the live renderer
  v  3  Wire the manifest + toggle
  >  4  Validating the panel live in herdr
  o  5  Write README and publish

  3/5 done
```

(In the terminal the glyphs are real checks/arrows/circles and the rows are colored.)

## How it works

Claude Code records its plan as `TaskCreate` / `TaskUpdate` tool calls in the session transcript
(`~/.claude/projects/**/<session-id>.jsonl`). The panel:

1. Finds the agent sharing its tab (via `herdr pane list`) and reads that agent's session id.
2. Locates the transcript and replays the Task calls into the current list (`TaskCreate` in order
   assigns ids `1..N`; `TaskUpdate` sets each task's status).
3. Redraws whenever the transcript changes — poll-based, so it catches mid-turn edits.

An `in_progress` task shows its `activeForm` (the present-continuous label), like the Claude Code
spinner. Press `q` to close. Pure PowerShell, no dependencies.

**Plan fallback.** When the agent has no task list yet but the session has an approved plan
(plan-mode writes it to `~/.claude/plans/*.md`, and the transcript names the file), the panel
mirrors the plan's steps instead, tagged `plan` in the footer: checkbox items (`- [ ]` / `- [x]`)
carry their status and update live as the file changes; otherwise numbered steps show as pending.
The moment real tasks appear they take over.

## Requirements

- Herdr `0.7.0` or newer, on **Windows** (herdr's Windows preview).
- Windows PowerShell 5.1 (built in) and a truecolor terminal.
- The herdr Claude integration installed (`herdr integration install claude`) so herdr knows each
  pane's agent session — that link is what the panel follows.

## Install

```powershell
herdr plugin install aclima01/herdr-todos-windows
```

Or, for local development from this folder:

```powershell
herdr plugin link .
```

## Use

Open the panel as a right split beside your agent (toggles closed if already open):

```powershell
herdr plugin action invoke aclima.herdr-todos-windows.toggle
```

Bind it to a key in your herdr `config.toml`:

```toml
[[keys.command]]
key = "prefix+d"
type = "plugin_action"
command = "aclima.herdr-todos-windows.toggle"
```

## Configuration

Drop a `config.toml` in the plugin's config dir
(`%APPDATA%\herdr\plugins\config\aclima.herdr-todos-windows\config.toml`). It is read when the
panel opens, so re-open it to apply changes.

```toml
# Colors: a named preset, or override individual colors below.
theme = "midnight"          # default | midnight | mono | forest

# Per-color overrides (hex "#rrggbb"); any of these wins over the preset:
# bg      = "#11131a"       # pane background ("" = terminal default / transparent)
# fg      = "#c8d3f5"       # normal text
# title   = "#7dcfff"       # the "TO-DOs" header
# done    = "#4b5263"       # completed rows
# active  = "#e0af68"       # the in-progress row
# pending = "#7aa2f7"       # not-started rows
# rule    = "#2a2f3d"       # the divider line

# Layout:
placement = "split"         # split | popup | tab | zoomed
direction = "right"         # split direction: right | down

# Auto-open the panel when a worktree is created or an agent is detected (split/tab only).
# It never stacks a second panel. Set false to only open it yourself with the toggle.
auto_open = true

# Size:
#   split  -> width = columns (right split) or height = rows (down split); the panel resizes
#             itself to that target right after opening.
#   popup  -> width / height are the floating window's dimensions.
width  = 44
# height = 20
```

## Steer the model

The panel is two-way, not just a mirror. Press **`s`**, type a note, and **Enter** to drop it into
the agent's input via `herdr agent send` — e.g. *"do #3 before #2"* or *"add a task for the timeout
case"* — then the agent pane takes focus so you review and hit enter. The note fills the input; it
never submits on its own. `Esc` cancels.

## Keys

| Key | Action |
| --- | --- |
| `s` | Send a note to the agent's input |
| `j` / `k` · arrows | Scroll the list |
| `PageUp` / `PageDown` | Scroll a page |
| `g` / `Home` | Re-follow the active task |
| `q` | Close the panel |

The list auto-follows the in-progress task; once you scroll it stays put until the active task
changes or you press `g`. When the list is taller than the pane it windows with a `x-y/N` position
indicator. Transcript reads are incremental (a byte high-watermark), so a long session stays cheap.

## Roadmap

- Reflect task dependencies (blocks / blockedBy) and cancellations more richly.

## License

MIT
