# Contributing

Thanks for wanting to help. Bug reports, fixes and new clients are all welcome.

## Ground rules

- **The hook must never get in Claude's way.** It runs on every prompt and tool call. It must
  exit fast, never block, never print to stdout, and never fail the agent. Network calls go in the
  background with a short timeout.
- **Keep the server dependency-free.** `server/beacon.py` is one file of standard-library Python
  so it runs anywhere with `python3`.
- **The Windows app stays a single PowerShell script** that runs on the Windows PowerShell 5.1
  built into Windows, with no modules to install.
- **Same behavior on every client.** A new setting or state should work the same way on Mac and
  Windows, using the same `client.json` key.

## Project layout

```
server/    beacon.py (the server), compose.yaml, server.env.example
hook/      beacon-hook.sh (the Claude Code hook) and install.sh
mac/       Swift package for the menu bar app, and install.sh
windows/   ClaudeBeacon.ps1 (the tray app) and install.ps1
docs/      networking, how it works, troubleshooting
examples/  example config files
```

## Developing

**Server:** `BEACON_TOKEN=dev python3 server/beacon.py`, then drive it with `curl`
(examples in [docs/troubleshooting.md](docs/troubleshooting.md)).

**Hook:** point `~/.config/claude-beacon/env` at your dev server and use Claude Code normally.
Check syntax with `bash -n hook/beacon-hook.sh`; it has to run on the bash 3.2 that ships with
macOS, so avoid bash 4+ features (associative arrays, `${var,,}`, `mapfile`).

**Mac:** `cd mac && swift build && .build/debug/ClaudeBeacon`. It reads
`~/.config/claude-beacon/client.json`.

**Windows:** run `powershell -ExecutionPolicy Bypass -File windows\ClaudeBeacon.ps1` from a
console to see errors. Remember the PowerShell 5.1 quirk: a pipeline that returns one object
gives you that object, not an array, and it has no `.Count`. Wrap results in `@()`.

## Pull requests

- One change per pull request, with a short description of what and why.
- Say how you tested it, and on which OS.
- Update the README or docs if behavior or settings change, and add a line to `CHANGELOG.md`.
- No secrets, tokens, hostnames or IP addresses from your own setup in code, docs or screenshots.

## Reporting bugs

Open an issue with the bug report template. The output of
`curl -s -H "Authorization: Bearer <token>" http://<beacon>:8799/state` (with names you'd rather
not share replaced) usually tells us where the problem is.
