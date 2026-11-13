# How it works

## Session states

The hook reports one of four states for each Claude Code session:

| State | Shown as | Set when |
|---|---|---|
| `working` | green | You submit a prompt, or Claude finishes a tool call. |
| `needs_input` | amber ("asking you") | Claude raises a permission prompt, opens a multiple choice question (`AskUserQuestion`), asks you to approve a plan (`ExitPlanMode`), or ends its turn with a question. |
| `done` | gray ("idle") | Claude ends its turn without a question. |
| `ended` | (removed) | The session exits. |

### How "asking you" is detected

Permission prompts, `AskUserQuestion` and plan approval are exact: Claude Code fires a hook for
each. A question in plain text isn't: Claude just ends its turn, so the hook reads the final
message and guesses. If one of its last four non-empty lines ends in `?` (ignoring trailing
markdown, quotes and a short suffix like `(y/n)`), the session counts as asking you.

That catches "Want me to commit this?" and misses "Let me know which you prefer." It can also
misfire on a rhetorical question at the end of a report. Missed ones still show as idle, which is
why the default view counts idle and asking together under **Needs you**.

### Seen and unseen

Marking a session seen (clicking it, or "Mark all seen") sets a flag on the beacon. It changes
how the session is drawn (amber turns muted, gray loses its white rim) and stops repeat
notifications. The flag clears the next time the session's state changes, so the next time it
finishes or asks you, it's new again. Marking seen never stops, ends or changes a session.

### When sessions disappear

- When Claude Code exits normally, the session is removed immediately.
- A session that goes silent for 6 hours (killed process, dropped SSH connection) is removed by
  the beacon, unless it's asking you and you haven't seen it. Those wait for you indefinitely.

## Session names

The hook sends two names with every event:

- **title**: what the session is. The name set with `/rename` if there is one, otherwise the title
  Claude Code generates for the conversation. Both are read from the session's transcript.
- **label**: where it runs. The tmux session name, if the session runs inside tmux. Override it
  with `BEACON_LABEL=<name>` in the environment Claude Code starts in.

It also sends `host` (the machine's short hostname, or `BEACON_HOST` if set) and `project` (the name of the working
directory). The apps show the title first, with the rest as detail.

## The terminal tab indicator

The hook writes an [OSC 9;4](https://learn.microsoft.com/en-us/windows/terminal/tutorials/progress-bar-sequences)
progress sequence to the terminal running the session:

| State | Sequence | Windows Terminal shows |
|---|---|---|
| working | `ESC ] 9;4;3 BEL` (indeterminate) | a busy indicator on the tab |
| needs_input | `ESC ] 9;4;4;100 BEL` (paused) | a yellow bar on the tab and taskbar icon |
| done, ended | `ESC ] 9;4;0 BEL` (clear) | nothing |

Escape sequences travel over SSH like any other output, so the tab on the computer you're sitting
at lights up even when Claude runs elsewhere. Inside tmux, the hook wraps the sequence for tmux
passthrough and writes it to the session's pane, which needs `set -g allow-passthrough all`.

## Configuration reference

### Hook: `~/.config/claude-beacon/env` (machines running Claude Code)

| Key | Default | Meaning |
|---|---|---|
| `BEACON_URL` | (required) | e.g. `http://100.101.102.103:8799` |
| `BEACON_TOKEN` | (required) | the beacon's token |
| `BEACON_TERMINAL` | `1` | `0` turns off the terminal tab indicator |
| `BEACON_LABEL` | tmux session | fixed label for sessions on this machine |
| `BEACON_HOST` | short hostname | friendlier machine name shown in the apps (`hook/install.sh --name`) |

If `BEACON_URL` is empty the hook does nothing, so removing the file disables reporting.

### Apps: `client.json`

`~/.config/claude-beacon/client.json` (Mac) or `%APPDATA%\claude-beacon\client.json` (Windows).
Both apps write the settings keys back when you change them in the Settings menu.

```json
{
  "url": "http://100.101.102.103:8799",
  "token": "...",
  "layout": "needs-you+working",
  "notify": "all",
  "hideEmpty": false,
  "notch": true,
  "pollSeconds": 3
}
```

| Key | Values | Default |
|---|---|---|
| `url`, `token` | where the beacon is and its token | (required) |
| `layout` | `needs-you+working`, `asking+idle+working`, `asking+working`, `needs-you`, `asking` | `needs-you+working` |
| `notify` | `all` (finished or asking), `asking`, `off` | `all` |
| `hideEmpty` | hide an icon while its count is zero | `false` |
| `notch` | Mac only: amber light beside the notch when a session asks you | `true` |
| `pollSeconds` | Windows only: how often it checks the beacon | `3` |

### Beacon: `server/server.env`

| Key | Default | Meaning |
|---|---|---|
| `BEACON_TOKEN` | (none) | Required in practice. With no token the beacon accepts anyone. |
| `BEACON_PORT` | `8799` | Port to listen on. |
| `BEACON_STATE_FILE` | (none) | Where to persist state across restarts. `compose.yaml` sets `/data/state.json`. |
| `BEACON_STALE_SECONDS` | `21600` | Remove sessions silent this long (6 hours). |

## API

Every endpoint except `/health` needs `Authorization: Bearer <token>`.

| Method and path | Body | Does |
|---|---|---|
| `POST /event` | `{session_id, host, project, state, label?, title?}` | Record a session's state. `state` is `working`, `needs_input`, `done` or `ended`. |
| `POST /ack` | `{session_id?}` | Mark one session seen, or all idle and asking sessions if omitted. |
| `GET /state` | | Snapshot: `{waiting, idle, sessions: [...]}`. `waiting` and `idle` count unseen asking and idle sessions. |
| `GET /events` | | Server-Sent Events: the snapshot on connect and after every change, a keepalive every 15 s. |
| `GET /health` | | `{"ok": true}` |

Each session in a snapshot has `session_id`, `host`, `project`, `label`, `title`, `state`,
`acked`, `updated` (Unix time) and `age` (seconds since `updated`).

Anything that can send an HTTP request can report to the beacon or read from it, so other agents,
scripts or a status bar widget can plug in the same way.
