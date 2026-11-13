# Troubleshooting

Start with the beacon's own view; it's the source of truth for every app:

```sh
curl -s -H "Authorization: Bearer <token>" http://<beacon-address>:8799/state | jq
```

If a session is right there but an app shows something else, the problem is the app. If the
session is missing or in the wrong state, the problem is the hook.

## The app shows a gray `!` (can't reach the beacon)

- From the machine running the app, run the `curl` above. If it hangs or is refused:
  - Is the beacon running? `docker compose ps` in `server/` on the beacon machine.
  - Right address? A LAN address won't work away from that network; see
    [networking](networking.md).
  - Is a firewall on the beacon machine blocking port 8799? Ports published by Docker usually
    bypass host firewalls like `ufw`; a bare `python3 beacon.py` doesn't.
- If `curl` returns `{"error": "unauthorized"}`, the token in the app's `client.json` doesn't
  match `BEACON_TOKEN` in `server/server.env`.

## A session never shows up

- Was it started **after** the hook was installed? Restart sessions that were already running.
- Is the hook registered? `jq .hooks ~/.claude/settings.json` should list `beacon-hook.sh` under
  `UserPromptSubmit`, `PostToolUse`, `Stop`, `Notification`, `SessionEnd` and `PreToolUse`.
  Rerun `hook/install.sh` if not.
- Can that machine reach the beacon? Run the `curl` above from it.
- Is `jq` installed there? The hook exits quietly without it.
- Send a test event by hand:

  ```sh
  . ~/.config/claude-beacon/env
  curl -s -X POST "$BEACON_URL/event" -H "Authorization: Bearer $BEACON_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"session_id":"test","host":"test","project":"test","state":"done"}'
  ```

  A `test` session should appear in the apps. Remove it with the same command and
  `"state":"ended"`.

## A session asked me something but showed as idle

The question was phrased without a question mark at the end ("let me know which you prefer").
See [how "asking you" is detected](how-it-works.md#how-asking-you-is-detected). It still counts
under **Needs you** in the default layout.

## A session shows "working" but it's gone

Its Claude Code process ended without a clean exit (killed, or the SSH connection dropped), so
the beacon never heard `ended`. It's removed after 6 hours of silence. To clear it now, send an
`ended` event for its `session_id` (from `/state`) with the `curl` above.

## Session names show the folder name, not a title

Names arrive with the session's next event. A session that hasn't done anything since the hook
was installed or updated still shows the old name until its next prompt.

## The terminal tab doesn't light up

- Your terminal has to support OSC 9;4: Windows Terminal, iTerm2 3.6+, Ghostty, ConEmu. macOS
  Terminal.app doesn't.
- In tmux, check `tmux show -g allow-passthrough` prints `all`. Older tmux (before 3.3) has no
  passthrough option.
- A tab you reconnect to after a session started waiting stays blank until that session's state
  changes again.
- Make sure `BEACON_TERMINAL=0` isn't set in `~/.config/claude-beacon/env`.

## Windows

- **Nothing changed after reinstalling:** right-click an icon and check the version line. If it's
  old, the new files probably landed in a nested `windows\windows` folder; delete the folder,
  copy again, rerun `install.ps1`.
- **Icons are missing:** Windows 11 hides new tray icons behind the `^` arrow. Drag them onto the
  taskbar, or enable them under Settings > Personalization > Taskbar > Other system tray icons
  (they're listed as Windows PowerShell).
- **Icons are in the wrong order:** Windows decides the order and doesn't always let you drag
  them. The colors carry the meaning, so the order doesn't matter.
- **No notifications:** check Focus Assist / Do not disturb, and that notifications for Windows
  PowerShell are allowed in Settings > System > Notifications.

## Mac

- **Build fails in `mac/install.sh`:** install the Swift toolchain with `xcode-select --install`
  (or Xcode), then rerun.
- **No notifications:** allow **Script Editor** in System Settings > Notifications.
- **App didn't start after login:** check `~/Library/LaunchAgents/com.claude-beacon.menubar.plist`
  exists (Settings > Start at login), or rerun `mac/install.sh`.
- **Start it by hand:** `"$HOME/Library/Application Support/claude-beacon/ClaudeBeacon" &`
