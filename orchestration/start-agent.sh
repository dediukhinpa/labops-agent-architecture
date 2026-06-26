#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/agents.sh"

AGENT="$1"
SESSION="labops-$AGENT"
WORKSPACE="/home/agent/.claude-lab/$AGENT"

# Per-agent webhook port (config, not secret): deterministically derived from the
# agent's position in the roster (lib/agents.sh), starting at WEBHOOK_BASE_PORT.
WEBHOOK_BASE_PORT="${WEBHOOK_BASE_PORT:-8089}"
TELEGRAM_WEBHOOK_PORT=""
idx=0
while IFS= read -r _a; do
  if [ "$_a" = "$AGENT" ]; then
    TELEGRAM_WEBHOOK_PORT=$(( WEBHOOK_BASE_PORT + idx ))
    break
  fi
  idx=$(( idx + 1 ))
done < <(list_agents)

if [ -z "$TELEGRAM_WEBHOOK_PORT" ]; then
  echo "Unknown agent: $AGENT" >&2; exit 1
fi

# Secrets (chmod 600, never hardcoded). Fail fast if absent.
SECRETS="/home/agent/.claude-lab/$AGENT/.claude/secrets"
read_secret() {
  local path="$SECRETS/$1"
  [ -r "$path" ] || { echo "missing/unreadable secret: $path" >&2; exit 1; }
  cat "$path"
}
TELEGRAM_BOT_TOKEN="$(read_secret telegram-bot-token)"
TELEGRAM_WEBHOOK_TOKEN="$(read_secret telegram-webhook-token)"

TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-$CLAUDE_LAB/shared/state/$AGENT/telegram}"
# Allowlist приходит из channel.env (никогда не хардкодится).
TELEGRAM_ALLOWED_USER_IDS="$(agent_channel_var "$AGENT" TELEGRAM_ALLOWED_USER_IDS 2>/dev/null || true)"

# Load Groq API key for voice transcription
GROQ_API_KEY=$(cat "/home/agent/.claude-lab/$AGENT/.claude/secrets/groq-api-key" 2>/dev/null || echo "")

tmux kill-session -t "$SESSION" 2>/dev/null || true

# Reap any leaked channel-server (bun) for THIS agent. kill-session kills claude,
# but its child bun reparents to PID 1; on a bad-luck race it lands in an EPIPE
# exception loop (the uncaughtException handler writes to the dead parent's log
# socket, which itself EPIPEs → re-enters the handler) and spins at ~90% CPU. On
# this 2-core box one such orphan starves the live sessions → frozen turns →
# watchdog restart → another orphan → cascade. The server's own orphan-watchdog
# (5s poll, server.ts:1010) loses that race intermittently, so reap explicitly
# here. The path match is agent-specific — never touches another agent's bun, and
# the new session's bun is spawned only after this point.
pkill -9 -f "\.claude-lab/$AGENT/\.claude/plugins/labops-channel/plugin/src/server\.ts" 2>/dev/null || true

tmux new-session -d -s "$SESSION" -c "$WORKSPACE" \
  -e TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
  -e TELEGRAM_STATE_DIR="$TELEGRAM_STATE_DIR" \
  -e TELEGRAM_ALLOWED_USER_IDS="$TELEGRAM_ALLOWED_USER_IDS" \
  -e TELEGRAM_WORKSPACE_ROOT="$WORKSPACE" \
  -e TELEGRAM_WEBHOOK_PORT="$TELEGRAM_WEBHOOK_PORT" \
  -e TELEGRAM_WEBHOOK_TOKEN="$TELEGRAM_WEBHOOK_TOKEN" \
  -e GROQ_API_KEY="$GROQ_API_KEY" \
  -e PATH="/home/agent/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  /usr/local/bin/claude \
    --dangerously-skip-permissions \
    --dangerously-load-development-channels server:labops-channel

DEADLINE=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  PANE=$(tmux capture-pane -pt "$SESSION" -S -30 2>/dev/null || true)
  if echo "$PANE" | grep -q "Listening for channel"; then
    echo "[start-agent] $AGENT listening (webhook :$TELEGRAM_WEBHOOK_PORT)"
    exit 0
  fi
  if echo "$PANE" | grep -q "I am using this for local development"; then
    tmux send-keys -t "$SESSION" Enter
  fi
  sleep 1
done

echo "[start-agent] WARNING: $AGENT did not reach Listening in 30s" >&2
exit 0
