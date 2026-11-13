# Changelog

## 0.9.0 (unreleased)

First public version.

- **Beacon server:** one dependency-free Python file. Tracks session states, persists them across
  restarts, pushes changes over Server-Sent Events. `compose.yaml` to run it in Docker.
- **Hook** for Claude Code (Linux, macOS, WSL): reports working, idle and asking states, the
  session's `/rename` name or auto title, tmux session, project and host. Sets the terminal tab's
  progress indicator (OSC 9;4), including through tmux. `hook/install.sh` installs it in one step; `--name` sets a friendly machine name.
- **Mac menu bar app:** colored count dots, session list, notifications, settings, start at
  login, optional light beside the notch. `mac/install.sh` builds and installs it.
- **Windows tray app:** colored count icons, left-click session panel, notifications, settings,
  start at login. `windows/install.ps1` installs it.
- Layouts: Needs you + Working (default), Asking + Idle + Working, Asking + Working, Needs you
  only, Asking only.
