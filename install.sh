#!/usr/bin/env bash
#
# labops-agent-architecture — установщик.
#
# Ставит ПЕРВОГО агента — Developer (Разработчик) — end-to-end: воркспейс + второй
# мозг + Telegram + голос + автостарт, со встроенным скиллом create-agent, которым
# Developer дальше поднимает остальных агентов. В конце — self-test (gate).
#
# Зависимости (поставьте сначала):
#   • labops-second-brain — общий мозг (для токена агента)
#   • labops-tg-plugin    — Telegram-канал (бот, голос)
#
# Использование:
#   ./install.sh              # self-test + создать агента Developer (интерактивно)
#   ./install.sh --test-only  # только self-test
#   ./install.sh --no-agent   # подготовить, но агента не создавать

set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${CLAUDE_LAB:-$HOME/.claude-lab}"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
say()  { printf "\n${C}▶ %s${N}\n" "$*"; }
ok()   { printf "${G}✓ %s${N}\n" "$*"; }
warn() { printf "${Y}⚠ %s${N}\n" "$*"; }
die()  { printf "${R}✗ %s${N}\n" "$*" >&2; exit 1; }

MODE="full"
[ "${1:-}" = "--test-only" ] && MODE="test"
[ "${1:-}" = "--no-agent" ] && MODE="prep"

echo "════════════════════════════════════════════"
echo "  labops-agent-architecture · установка"
echo "════════════════════════════════════════════"

# ── 1. Окружение и зависимости ───────────────────────────────────
say "1. Окружение"
command -v bash >/dev/null || die "нужен bash"

# root не нуждается в sudo, а на голых серверах его вообще может не быть.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo"
fi

# Ставит системный пакет через доступный пакетный менеджер.
# Linux → apt-get (sudo, если не root). macOS → brew.
install_via_pkgmgr() {
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    warn "$pkg не найден — устанавливаю через apt-get${SUDO:+ (sudo)}"
    $SUDO apt-get update -y
    $SUDO apt-get install -y "$pkg"
  elif command -v brew >/dev/null 2>&1; then
    warn "$pkg не найден — устанавливаю через brew"
    brew install "$pkg"
  else
    die "$pkg не найден и не найден ни apt-get, ни brew — установите $pkg вручную."
  fi
}

for c in git curl jq unzip; do
  command -v "$c" >/dev/null 2>&1 || install_via_pkgmgr "$c"
  command -v "$c" >/dev/null 2>&1 && ok "$c" || die "$c не удалось установить — установите вручную."
done

if ! command -v tmux >/dev/null 2>&1; then
  install_via_pkgmgr tmux
fi
command -v tmux >/dev/null 2>&1 || die "нужен tmux (рантайм агента живёт в tmux-сессии), автоустановка не удалась"
ok "tmux $(tmux -V 2>/dev/null | awk '{print $2}')"

if ! command -v claude >/dev/null 2>&1; then
  warn "claude не найден — устанавливаю (curl -fsSL https://claude.ai/install.sh | bash), без Node.js"
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
fi
if command -v claude >/dev/null 2>&1; then
  ok "claude найден"
  echo "    Модель подключается через подписку: если ещё не входили — 'claude setup-token' (Max/Pro)."
else
  die "установка Claude Code не удалась — установите вручную: curl -fsSL https://claude.ai/install.sh | bash"
fi

if command -v systemctl >/dev/null 2>&1; then ok "systemd найден"; else
  warn "systemd (systemctl) не найден — автозапуск недоступен (Linux+systemd обязателен для сервиса)."
  warn "на macOS/без systemd агент можно запускать вручную, но не как службу."
fi
command -v python3 >/dev/null 2>&1 && ok "python3" || warn "python3 не найден (часть шагов деградирует)"

# мягкая проверка соседних репозиториев
SB=""; for d in "${SECOND_BRAIN_DIR:-}" /opt/second_brain "$HOME/labops-second-brain"; do
  [ -n "$d" ] && [ -d "$d/services" ] && SB="$d" && break; done
[ -n "$SB" ] && ok "labops-second-brain: $SB" || warn "labops-second-brain не найден — токен агента придётся ввести вручную (или поставьте репозиторий)"
TG=""; for d in "${TG_PLUGIN_DIR:-}" "$HOME/labops-tg-plugin" "$LAB_DIR/shared/plugins/labops-tg-plugin"; do
  [ -n "$d" ] && [ -d "$d/plugin" ] && TG="$d" && break; done
[ -n "$TG" ] && ok "labops-tg-plugin: $TG" || warn "labops-tg-plugin не найден — Telegram-канал будет пропущен (поставьте репозиторий)"

# скрипты должны быть исполняемыми
chmod +x "$REPO_DIR"/test.sh "$REPO_DIR"/orchestration/*.sh "$REPO_DIR"/skills/create-agent/*.sh \
         "$REPO_DIR"/agent-template/install.sh 2>/dev/null || true

# ── 2. Self-test (gate) ──────────────────────────────────────────
say "2. Self-test репозитория"
bash "$REPO_DIR/test.sh" || die "self-test провален — установка остановлена."

[ "$MODE" = "test" ] && { ok "только self-test — готово."; exit 0; }

# ── 3. Первый агент — Developer ──────────────────────────────────
if [ "$MODE" = "prep" ]; then
  say "Подготовка завершена (--no-agent). Чтобы создать первого агента:"
  echo "    bash skills/create-agent/new-agent.sh"
  exit 0
fi

say "3. Первый агент — Developer (Разработчик)"
echo "  Developer — кодер и «прораб»: он же дальше поднимает остальных агентов"
echo "  своим скиллом create-agent. Сейчас проведём его настройку."
echo
export AGENT_NAME="${AGENT_NAME:-Developer}"
export AGENT_ROLE="${AGENT_ROLE:-Разработчик}"
export AGENT_ROLE_DESCRIPTION="${AGENT_ROLE_DESCRIPTION:-Автономный разработчик: пишет код, ревьюит архитектуру, гоняет тесты и помогает оператору создавать новых агентов.}"
[ -n "$SB" ] && export SECOND_BRAIN_DIR="$SB"
[ -n "$TG" ] && export TG_PLUGIN_DIR="$TG"

bash "$REPO_DIR/skills/create-agent/new-agent.sh"

# убедимся, что у Developer есть скилл create-agent (чтобы ставить следующих)
DEV_WS="$LAB_DIR/$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')/.claude"
if [ -d "$DEV_WS" ] && [ ! -e "$DEV_WS/skills/create-agent" ]; then
  mkdir -p "$DEV_WS/skills"
  ln -s "$REPO_DIR/skills/create-agent" "$DEV_WS/skills/create-agent" 2>/dev/null \
    && ok "скилл create-agent подключён в воркспейс Developer"
fi

say "Готово."
echo "  Developer создан. Напишите ему в Telegram, либо запустите вручную:"
echo "    source $DEV_WS/agent.env && claude --project $DEV_WS"
echo "  Чтобы добавить следующего агента — попросите Developer «заведи нового агента»"
echo "  (он применит скилл create-agent) или запустите:"
echo "    bash skills/create-agent/new-agent.sh"
