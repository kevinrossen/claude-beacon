#!/usr/bin/env bash
# Build and install the Claude Beacon menu bar app for the current user (macOS 13+).
#
#   mac/install.sh                                   build, install, start at login, start now
#   mac/install.sh --url http://my-server:8799 --token <BEACON_TOKEN>
#   mac/install.sh --uninstall
#
# Needs the Swift toolchain (Xcode or `xcode-select --install`).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/Library/Application Support/claude-beacon"
bin="$dest/ClaudeBeacon"
cfg="$HOME/.config/claude-beacon/client.json"
label=com.claude-beacon.menubar
plist="$HOME/Library/LaunchAgents/$label.plist"

url="" token="" uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) url=$2; shift 2 ;;
    --token) token=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

stop() {
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  pkill -x ClaudeBeacon 2>/dev/null || true
}

if [ "$uninstall" = 1 ]; then
  stop
  rm -f "$plist"
  rm -rf "$dest"
  echo "Removed. Config left at $cfg."
  exit 0
fi

command -v swift >/dev/null || { echo "Needs the Swift toolchain: xcode-select --install" >&2; exit 1; }
(cd "$here" && swift build -c release)
mkdir -p "$dest"
cp "$here/.build/release/ClaudeBeacon" "$bin"

# Config: url + token (settings the app writes are kept). plutil edits JSON in place.
if [ -n "$url$token" ] || [ ! -f "$cfg" ]; then
  mkdir -p "$(dirname "$cfg")"
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  [ -n "$url" ] || url=$(plutil -extract url raw -o - "$cfg" 2>/dev/null || true)
  [ -n "$token" ] || token=$(plutil -extract token raw -o - "$cfg" 2>/dev/null || true)
  while [ -z "$url" ]; do read -rp "Beacon URL, e.g. http://my-server:8799: " url; done
  while [ -z "$token" ]; do read -rp "Beacon token (BEACON_TOKEN from the server's env file): " token; done
  plutil -replace url -string "${url%/}" "$cfg"
  plutil -replace token -string "$token" "$cfg"
  chmod 600 "$cfg"
fi
url=$(plutil -extract url raw -o - "$cfg")
token=$(plutil -extract token raw -o - "$cfg")

# Start at login (the app's Settings > Start at login toggles this same file)
mkdir -p "$(dirname "$plist")"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$bin</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

stop
launchctl bootstrap "gui/$(id -u)" "$plist"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $token" "$url/state" || true)
case "$code" in
  200) echo "Installed and running. Look for the dots in the menu bar." ;;
  401) echo "Installed, but the beacon rejected the token (401). Fix it in $cfg (menu > Settings > Open config file)." ;;
  *)   echo "Installed, but $url is not reachable from this Mac (HTTP ${code:-none})." ;;
esac
