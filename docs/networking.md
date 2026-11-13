# Networking: connecting your machines

Every machine running Claude Code has to reach the beacon to report, and every computer running
an app has to reach it to listen. How you get there depends on where your machines live.

## Everything on one network

If all your machines are on the same home or office network, use the beacon machine's LAN address:

```
http://192.168.1.50:8799
```

Give the beacon machine a fixed address (a DHCP reservation in your router) so the URL doesn't
change. Done; you don't need anything on this page.

## Machines on different networks: use Tailscale

The moment one machine lives somewhere else (a cloud VM, a laptop at a coffee shop, a desktop at
the office) you need a way across. The beacon speaks plain HTTP with a bearer token, so **don't**
forward port 8799 on your router or open it in a cloud firewall.

[Tailscale](https://tailscale.com) puts all your machines on one private network that works from
anywhere, with no ports to open. Its free personal plan covers this easily.

### 1. Install Tailscale everywhere

Install it on the beacon machine and on every machine that runs Claude Code or an app, and sign
in to the same account on each.

| Platform | Install |
|---|---|
| Linux (incl. cloud VMs) | `curl -fsSL https://tailscale.com/install.sh \| sh` then `sudo tailscale up` |
| macOS | [App Store](https://apps.apple.com/app/tailscale/id1475387142) or `brew install --cask tailscale`, then sign in from the menu bar |
| Windows | [tailscale.com/download](https://tailscale.com/download/windows), then sign in from the tray |

On a headless Linux machine, `sudo tailscale up` prints a login link; open it on any device.

### 2. Find the beacon's Tailscale address

On the beacon machine:

```sh
tailscale ip -4          # e.g. 100.101.102.103
```

Or turn on [MagicDNS](https://tailscale.com/kb/1081/magicdns) in the Tailscale admin console and
use the machine name instead, e.g. `http://homeserver:8799`.

### 3. Use it as the beacon URL

```sh
hook/install.sh --url http://100.101.102.103:8799 --token <token>
mac/install.sh  --url http://100.101.102.103:8799 --token <token>
```

On Windows, enter the same URL when `install.ps1` asks (or rerun it with `-Url`).

That address works from every machine on your tailnet, at home or away.

### Already set up with a LAN address?

Rerun the installers with the new `--url`; they keep everything else. Or edit the files directly:

| Machine | File | Key |
|---|---|---|
| Runs Claude Code | `~/.config/claude-beacon/env` | `BEACON_URL=` |
| Mac app | `~/.config/claude-beacon/client.json` | `"url"` |
| Windows app | `%APPDATA%\claude-beacon\client.json` | `"url"` |

Restart the apps after editing (Quit from their menu, then run them again).

### Checking it works

From any machine on the tailnet:

```sh
curl -s -H "Authorization: Bearer <token>" http://100.101.102.103:8799/state
```

You should get JSON listing your sessions. If it hangs, see
[troubleshooting](troubleshooting.md#the-app-shows-a-gray--cant-reach-the-beacon).

### Locking it down further (optional)

- **Tailscale ACLs** can limit which devices may reach the beacon machine on port 8799.
- **Bind to the Tailscale address only**, so the beacon isn't reachable from the LAN at all. In
  `server/compose.yaml`, change the port line to `"100.101.102.103:8799:8799"` (your address).

## Other options

- **An HTTPS reverse proxy or tunnel** (Caddy, nginx, Cloudflare Tunnel) in front of the beacon
  works too. Use HTTPS, keep the token secret, and consider an access layer such as Cloudflare
  Access, because the beacon is then reachable from the internet.
- **WireGuard, ZeroTier or a VPN you already run:** anything that gives the machines private
  addresses for each other works the same way as Tailscale.
