# Security

## What the beacon knows

For each Claude Code session the beacon stores: a session id, the machine's hostname, the working
directory's name, the tmux session name, the conversation title, its state and a timestamp.
It never sees prompts, code, files or Claude's replies. Conversation titles can still describe
what you're working on, so treat the beacon as private.

## The security model

- One shared **bearer token** protects every endpoint except `/health`. Anyone with the token
  can read every session's state and title, mark sessions seen, and report fake sessions.
- The beacon speaks **plain HTTP**. The token travels unencrypted.

So:

- Run the beacon on a **trusted network**: your LAN, or a private network such as Tailscale
  ([docs/networking.md](docs/networking.md)). Don't expose port 8799 to the internet.
- If it has to be reachable from the internet, put it behind **HTTPS** (a reverse proxy or a
  tunnel) and preferably an access layer in front of that.
- Use a **long random token** (`openssl rand -hex 24`), and don't commit `server.env`,
  `~/.config/claude-beacon/env` or `client.json` anywhere. They're in `.gitignore`.
- To rotate the token, change it in `server/server.env`, restart the beacon, and rerun the
  installers on each machine with `--token`.

## What runs on your machines

- The **hook** runs inside Claude Code on every prompt and tool call. It reads the session's hook
  input and transcript (for the conversation title and the final message's last lines), and sends
  only the fields listed above.
- The **apps** only talk to the beacon URL you give them.

## Reporting a vulnerability

Please don't open a public issue for security problems. Use GitHub's private
[security advisory](../../security/advisories/new) form on this repository instead. You'll get a
reply within a week.
