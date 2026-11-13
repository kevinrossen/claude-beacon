#!/usr/bin/env bash
# Claude Code hook -> claude-beacon. Never blocks or fails the agent.
# Config: ~/.config/claude-beacon/env  (BEACON_URL, BEACON_TOKEN)
[ -r "$HOME/.config/claude-beacon/env" ] && . "$HOME/.config/claude-beacon/env"
[ -z "$BEACON_URL" ] && exit 0

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input")
sid=$(jq -r '.session_id // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
ntype=$(jq -r '.notification_type // empty' <<<"$input")
[ -z "$sid" ] && exit 0

# Did the agent's last message end by asking the user something? Heuristic: one of its
# last few non-empty lines ends in "?" (trailing markdown, quotes and a short "(y/n)"-style
# suffix ignored), which also catches a question followed by a list of options.
asks_question() {
  local msg tp
  msg=$(jq -r '.last_assistant_message // empty' <<<"$input")
  if [ -z "$msg" ]; then
    tp=$(jq -r '.transcript_path // empty' <<<"$input")
    [ -r "$tp" ] && msg=$(tail -n 60 "$tp" | jq -rs \
      '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // empty' 2>/dev/null)
  fi
  printf '%s\n' "$msg" | grep -v '^[[:space:]]*$' | tail -n 4 \
    | sed -E -e 's/[[:space:]*_`"'"'"']+$//' -e 's/[[:space:]]*[([][^()[]{1,15}[])]$//' \
             -e 's/[][[:space:]*_`"'"'"')]+$//' | grep -q '?$'
}

case "$event" in
  UserPromptSubmit|PostToolUse) state=working ;;
  PreToolUse)
    # tools that block on the user
    case "$(jq -r '.tool_name // empty' <<<"$input")" in
      AskUserQuestion|ExitPlanMode) state=needs_input ;;
      *) exit 0 ;;
    esac ;;
  Stop)
    if asks_question; then state=needs_input; else state=done; fi ;;
  Notification)
    # idle_prompt fires ~60s after Stop and auth_success is informational; neither
    # may overwrite a pending needs_input
    case "$ntype" in idle_prompt|auth_success) exit 0 ;; esac
    state=needs_input ;;
  SessionEnd)                   state=ended ;;
  *) exit 0 ;;
esac

# Terminal indicator: OSC 9;4 progress state on the terminal tab running this session.
# Windows Terminal shows it on the tab and the taskbar icon; iTerm2 3.6+, Ghostty and
# ConEmu render it too. It travels over SSH. Inside tmux it is wrapped in DCS passthrough
# (needs `set -g allow-passthrough all`) and written to this session's pane, because
# tmux drops bare OSC 9;4. Disable with BEACON_TERMINAL=0 in the env file.
#   working -> indeterminate (busy)   needs_input -> paused/yellow   done, ended -> cleared
term_signal() {
  [ "${BEACON_TERMINAL:-1}" = 0 ] && return 0
  local seq tty esc=$'\033'
  seq="${esc}]9;4;$1"$'\a'
  if [ -n "$TMUX_PANE" ] && command -v tmux >/dev/null 2>&1; then
    tty=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null)
    seq="${esc}Ptmux;${seq//$esc/$esc$esc}${esc}\\"
  else
    tty=/dev/tty
  fi
  [ -n "$tty" ] && { printf '%s' "$seq" > "$tty"; } 2>/dev/null
  return 0
}

case "$state" in
  working)     term_signal '3' ;;
  needs_input) term_signal '4;100' ;;
  *)           term_signal '0' ;;
esac

# A human name for the session: the tmux session it runs in (BEACON_LABEL overrides)
label=${BEACON_LABEL:-}
if [ -z "$label" ] && [ -n "$TMUX_PANE" ] && command -v tmux >/dev/null 2>&1; then
  label=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)
fi

# What the session is: the name given with /rename, else Claude's auto-generated title.
# Both are written into the transcript; the last entry wins.
title=""
tp=$(jq -r '.transcript_path // empty' <<<"$input")
if [ -r "$tp" ]; then
  title=$(grep -aF '"type":"custom-title"' "$tp" | tail -n 1 | jq -r '.customTitle // empty' 2>/dev/null)
  [ -z "$title" ] && title=$(grep -aF '"type":"ai-title"' "$tp" | tail -n 1 | jq -r '.aiTitle // empty' 2>/dev/null)
fi

# Machine name shown in the apps: BEACON_HOST if set, else the short hostname
host=${BEACON_HOST:-$(hostname -s)}

payload=$(jq -nc --arg s "$sid" --arg h "$host" --arg p "$(basename "${cwd:-?}")" --arg st "$state" \
  --arg l "$label" --arg t "$title" '{session_id:$s, host:$h, project:$p, state:$st, label:$l, title:$t}')

curl -s --max-time 2 -o /dev/null -X POST "$BEACON_URL/event" \
  -H "Authorization: Bearer $BEACON_TOKEN" -H 'Content-Type: application/json' \
  -d "$payload" >/dev/null 2>&1 &
exit 0
