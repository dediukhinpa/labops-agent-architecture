#!/usr/bin/env bash
# lib/agents.sh — shared helpers for resolving the agent roster and per-agent
# Telegram bot tokens WITHOUT hardcoding any lab-specific names or secrets.
#
# This file is meant to be *sourced*, not executed, so it does NOT set `set -e`.
#
#   source "$(dirname "$0")/lib/agents.sh"
#
# Provides:
#   list_agents                 -> prints one agent-id per line
#   agent_bot_token <agent>     -> prints that agent's TELEGRAM_BOT_TOKEN

# Root of the local agent lab. Override with CLAUDE_LAB if needed.
: "${CLAUDE_LAB:=$HOME/.claude-lab}"

# list_agents — print the roster, one agent-id per line.
#
# Resolution order:
#   1. If $CLAUDE_LAB/agents.conf exists, print its non-empty, non-comment lines.
#   2. Otherwise, scan $CLAUDE_LAB/*/.claude and print the parent directory
#      basename for each, excluding infra directories.
list_agents() {
  local conf="$CLAUDE_LAB/agents.conf"
  if [ -f "$conf" ]; then
    # Strip comments and blank lines; trim surrounding whitespace.
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] && printf '%s\n' "$line"
    done < "$conf"
    return 0
  fi

  local d name
  for d in "$CLAUDE_LAB"/*/.claude; do
    [ -d "$d" ] || continue
    name="$(basename "$(dirname "$d")")"
    case "$name" in
      shared|logs|mcp-servers|__pycache__) continue ;;
    esac
    printf '%s\n' "$name"
  done
}

# agent_bot_token <agent> — print the TELEGRAM_BOT_TOKEN for the given agent.
#
# Reads the first existing of:
#   /etc/labops-plugin/<agent>/channel.env
#   $CLAUDE_LAB/shared/state/<agent>/telegram/channel.env
# Returns 1 and prints to stderr if no token can be found.
agent_bot_token() {
  local agent="$1"
  if [ -z "$agent" ]; then
    echo "agent_bot_token: agent name required" >&2
    return 1
  fi

  local f token
  for f in \
    "/etc/labops-plugin/$agent/channel.env" \
    "$CLAUDE_LAB/shared/state/$agent/telegram/channel.env"; do
    [ -f "$f" ] || continue
    token="$(grep -E '^[[:space:]]*TELEGRAM_BOT_TOKEN[[:space:]]*=' "$f" | head -1)"
    [ -n "$token" ] || continue
    # Strip everything up to and including the first '='.
    token="${token#*=}"
    # Trim surrounding whitespace.
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    # Strip optional surrounding single or double quotes.
    token="${token#\"}"; token="${token%\"}"
    token="${token#\'}"; token="${token%\'}"
    if [ -n "$token" ]; then
      printf '%s\n' "$token"
      return 0
    fi
  done

  echo "agent_bot_token: no TELEGRAM_BOT_TOKEN found for agent '$agent'" >&2
  return 1
}
