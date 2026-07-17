# Agent TO-DOs for Windows

A live panel that mirrors the focused agent's **task list** into a herdr split pane, so you can
follow the model's plan as it works — which steps are done, which one it's on, and what's left.

```
 TO-DOs  claude · my-project
 ----------------------------------------------
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

## Roadmap

- **Steer the model (v2).** A note box in the panel that sends an adjustment back to the agent's
  input via `herdr agent send` ("do #3 before #2", "add a task for the timeout case"), so the panel
  becomes a two-way guide, not just a mirror.
- Incremental transcript tailing (a high-watermark) instead of a full replay each change.

## License

MIT
