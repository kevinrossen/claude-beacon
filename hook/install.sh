#!/usr/bin/env bash
# Install the claude-beacon hook for Claude Code on this machine (Linux or macOS).
# Run it on every machine where you run Claude Code; all of them report to one beacon.
#
#   hook/install.sh --url http://my-server:8799 --token <BEACON_TOKEN>
#   hook/install.sh --name laptop   # friendlier machine name in the apps (default: hostname)
#   hook/install.sh                 # asks for URL and token if not configured yet
#   hook/install.sh --uninstall
#
# Needs bash, curl and jq (macOS 15+ ships jq; otherwise brew/apt install jq).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hook_dst="$HOME/.claude/hooks/beacon-hook.sh"
env_file="$HOME/.config/claude-beacon/env"
settings="$HOME/.claude/settings.json"
cmd='$HOME/.claude/hooks/beacon-hook.sh'   # literal: Claude Code runs hooks through a shell

url="" token="" name="" uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) url=$2; shift 2 ;;
    --token) token=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

for tool in jq curl; do
  command -v "$tool" >/dev/null || { echo "needs $tool (brew install $tool / apt install $tool)" >&2; exit 1; }
done

backup() { [ -f "$settings" ] && cp "$settings" "$settings.bak-beacon-$(date +%Y%m%d%H%M%S)"; return 0; }

if [ "$uninstall" = 1 ]; then
  if [ -f "$settings" ]; then
    backup
    tmp=$(mktemp)
    jq --arg cmd "$cmd" '
      if .hooks == null then . else
        .hooks |= (with_entries(.value |= map(select(any(.hooks[]?; .command == $cmd) | not)))
                   | with_entries(select(.value | length > 0)))
      end' "$settings" > "$tmp" && mv "$tmp" "$settings"
  fi
  rm -f "$hook_dst"
  echo "Removed the hook. Config left at $env_file."
  exit 0
fi

# 1. the hook script
mkdir -p "$(dirname "$hook_dst")"
cp "$here/beacon-hook.sh" "$hook_dst"
chmod +x "$hook_dst"

# 2. where to report
if [ -n "$url$token" ] || [ ! -f "$env_file" ]; then
  if [ -f "$env_file" ]; then
    # shellcheck disable=SC1090
    . "$env_file"
    url=${url:-${BEACON_URL:-}}; token=${token:-${BEACON_TOKEN:-}}
  fi
  while [ -z "$url" ]; do read -rp "Beacon URL, e.g. http://my-server:8799: " url; done
  while [ -z "$token" ]; do read -rp "Beacon token (BEACON_TOKEN from the server's env file): " token; done
  mkdir -p "$(dirname "$env_file")"
  umask 077
  printf 'BEACON_URL=%s\nBEACON_TOKEN=%s\n' "${url%/}" "$token" > "$env_file"
fi
# optional friendly machine name, kept in the env file
if [ -n "$name" ]; then
  tmp=$(mktemp)
  grep -v '^BEACON_HOST=' "$env_file" > "$tmp" || true
  printf 'BEACON_HOST=%s\n' "$name" >> "$tmp"
  cat "$tmp" > "$env_file" && rm -f "$tmp"
fi
# shellcheck disable=SC1090
. "$env_file"

# 3. register the hook in Claude Code's settings (idempotent; other hooks untouched)
mkdir -p "$(dirname "$settings")"
[ -f "$settings" ] || echo '{}' > "$settings"
backup
tmp=$(mktemp)
jq --arg cmd "$cmd" '
  def entry($m): {hooks: [{type: "command", command: $cmd, timeout: 5}]}
                 + (if $m == "" then {} else {matcher: $m} end);
  def has_cmd: any(.[]?; any(.hooks[]?; .command == $cmd));
  def add($ev; $m): .hooks[$ev] = ((.hooks[$ev] // []) | if has_cmd then . else . + [entry($m)] end);
  .hooks = (.hooks // {})
  | add("UserPromptSubmit"; "") | add("PostToolUse"; "") | add("Stop"; "")
  | add("Notification"; "") | add("SessionEnd"; "")
  | add("PreToolUse"; "AskUserQuestion|ExitPlanMode")' "$settings" > "$tmp" && mv "$tmp" "$settings"

# 4. tmux: let the tab indicator through
if command -v tmux >/dev/null && ! grep -qs 'allow-passthrough' "$HOME/.tmux.conf"; then
  printf '\n# claude-beacon: let Claude Code hooks set the terminal tab progress state (OSC 9;4)\nset -g allow-passthrough all\n' >> "$HOME/.tmux.conf"
  tmux set -g allow-passthrough all 2>/dev/null || true
  echo "Added 'set -g allow-passthrough all' to ~/.tmux.conf."
fi

# 5. can we reach the beacon?
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $BEACON_TOKEN" "$BEACON_URL/state" || true)
case "$code" in
  200) echo "Installed. Beacon at $BEACON_URL is reachable; new Claude Code sessions on ${BEACON_HOST:-$(hostname -s)} will report to it." ;;
  401) echo "Installed, but the beacon rejected the token (401). Fix BEACON_TOKEN in $env_file." ;;
  *)   echo "Installed, but $BEACON_URL is not reachable from here (HTTP ${code:-none}). Sessions report once it is." ;;
esac
echo "Already-running Claude Code sessions pick up the hook when they next start."
