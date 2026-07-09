#!/usr/bin/env bash
#
# labops-agent-architecture — установщик.
#
# Ставит ПЕРВОГО агента — Developer (Разработчик) — end-to-end: воркспейс + второй
# мозг + Telegram + голос + автостарт, со встроенным скиллом create-agent, которым
# Developer дальше поднимает остальных агентов. В конце — self-test (gate).
#
# Ставит САМУ АРХИТЕКТУРУ: tmux/git/curl/jq/unzip, Claude Code (нативно, без
# Node.js), и клонирует (но НЕ устанавливает) соседние репозитории:
#   • labops-second-brain — общий мозг (для токена агента)
#   • labops-tg-plugin    — Telegram-канал (бот, голос)
# Каждый из соседних репозиториев ставится СВОИМ install.sh отдельной командой
# оператора — см. вывод скрипта после клонирования, либо README → Quickstart.
#
# Использование:
#   ./install.sh              # ОДНА команда: деплой + клонирование siblings + self-test +
#                             # авторизация Claude Code (claude setup-token, если ещё не
#                             # входили) + создание Developer (интерактивно). Если siblings
#                             # ещё не установлены их собственными install.sh — агент
#                             # стартует в деградированном режиме, см. README → Quickstart.
#   ./install.sh --test-only  # только self-test
#   ./install.sh --no-agent   # подготовить + склонировать siblings, но авторизацию и
#                             # агента не выполнять (для ручного/отложенного запуска:
#                             #  claude setup-token && bash skills/create-agent/new-agent.sh)
#
# Env overrides:
#   GITHUB_TOKEN=ghp_xxx      # нужен на чистом VPS для клонирования приватных labops-*
#   SKIP_SECOND_BRAIN=1       # не клонировать labops-second-brain
#   SKIP_TG_PLUGIN=1          # не клонировать labops-tg-plugin

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
  echo "    Модель подключается через подписку (Max/Pro) — авторизация будет запрошена ниже, перед созданием агента, если ещё не входили."
else
  die "установка Claude Code не удалась — установите вручную: curl -fsSL https://claude.ai/install.sh | bash"
fi

if command -v systemctl >/dev/null 2>&1; then ok "systemd найден"; else
  warn "systemd (systemctl) не найден — автозапуск недоступен (Linux+systemd обязателен для сервиса)."
  warn "на macOS/без systemd агент можно запускать вручную, но не как службу."
fi
command -v python3 >/dev/null 2>&1 && ok "python3" || warn "python3 не найден (часть шагов деградирует)"

# ── Клонирование соседних репозиториев (если их ещё нет) ─────────
# GITHUB_TOKEN нужен только для приватного labops-second-brain на чистой
# машине без gh и без настроенного SSH-ключа. Токен передаётся через -c
# http.extraHeader только для ЭТОГО вызова git — не пишется в .git/config
# и не оседает на диске.
clone_repo() {
  local name="$1" url="$2" dest="$3"
  if [ -d "$dest/.git" ]; then
    ok "$name уже на месте: $dest"
    return 0
  fi
  say "Клонирую $name → $dest"
  local err_log; err_log="$(mktemp)"
  if git clone --depth=1 "$url" "$dest" 2>"$err_log"; then
    ok "$name склонирован"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    warn "$name недоступен анонимно (приватный?) — пробую с GITHUB_TOKEN"
    local auth_header
    auth_header="Authorization: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
    if git -c http.extraHeader="$auth_header" clone --depth=1 "$url" "$dest" 2>"$err_log"; then
      ok "$name склонирован (по GITHUB_TOKEN)"
    else
      cat "$err_log" >&2
      die "$name: клонирование не удалось даже с GITHUB_TOKEN — проверьте, что токен выпущен для аккаунта-владельца репозитория и имеет право Contents:Read на $name."
    fi
  else
    cat "$err_log" >&2
    die "$name недоступен анонимно (репозиторий приватный?) и GITHUB_TOKEN не задан.
    На чистом сервере без gh/SSH экспортируйте токен и перезапустите:
      GITHUB_TOKEN=ghp_xxx ./install.sh
    Либо склонируйте вручную и перезапустите install.sh:
      git clone $url $dest"
  fi
  rm -f "$err_log"
}

if [ "$MODE" != "test" ]; then

SB="${SECOND_BRAIN_DIR:-$HOME/labops-second-brain}"
if [ "${SKIP_SECOND_BRAIN:-0}" != "1" ]; then
  clone_repo "labops-second-brain" "https://github.com/dediukhinpa/labops-second-brain.git" "$SB"
else
  warn "labops-second-brain пропущен (SKIP_SECOND_BRAIN=1) — токен агента придётся ввести вручную"
  SB=""
fi

TG="${TG_PLUGIN_DIR:-$HOME/labops-tg-plugin}"
if [ "${SKIP_TG_PLUGIN:-0}" != "1" ]; then
  clone_repo "labops-tg-plugin" "https://github.com/dediukhinpa/labops-tg-plugin.git" "$TG"
else
  warn "labops-tg-plugin пропущен (SKIP_TG_PLUGIN=1) — Telegram-канал будет пропущен"
  TG=""
fi

# ── Соседние репозитории склонированы, но НЕ установлены ──────────
# Каждый ставится своим install.sh отдельной командой оператора:
if [ -n "$TG" ]; then
  say "labops-tg-plugin склонирован ($TG) — установите отдельной командой:"
  echo "    cd $TG && ./install.sh"
fi

if [ -n "$SB" ]; then
  say "labops-second-brain склонирован ($SB) — root-провижининг (Postgres+pgvector, Caddy, systemd, ~1.3ГБ модель embeddings). Установите одним из двух способов:"
  echo "    Вариант 1 — вручную:"
  echo "      sudo bash $SB/scripts/install.sh"
  echo "    Вариант 2 — отдать Claude Code агенту (спросит подтверждение на разрушительных шагах):"
  echo "      cd $SB && claude"
  echo "      # в сессии: «Прочитай и выполни инструкции из AGENT.md — разверни Second Brain,"
  echo "      #            Path A (VPS + inbox-agent). Подтверждай со мной каждый деструктивный шаг.»"
fi

fi  # [ "$MODE" != "test" ]

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
  echo "    claude setup-token   # один раз, подписка Max/Pro (если ещё не входили)"
  echo "    bash skills/create-agent/new-agent.sh"
  exit 0
fi

say "3. Первый агент — Developer (Разработчик)"
echo "  Developer — кодер и «прораб»: он же дальше поднимает остальных агентов"
echo "  своим скиллом create-agent. Сейчас проведём его настройку."
echo

# Авторизация Claude Code — нужна ДО создания агента (иначе агент не достучится
# до модели). Проверяем по факту наличия credentials, а не спрашиваем на слово.
if [ -f "$HOME/.claude/.credentials.json" ]; then
  ok "Claude Code уже авторизован"
else
  say "Авторизация Claude Code (подписка Max/Pro)"
  echo "  Сейчас запустится 'claude setup-token' — войдите один раз."
  claude setup-token || die "авторизация не завершена — перезапустите ./install.sh, когда будете готовы войти."
  ok "авторизация пройдена"
fi

[ -n "$TG" ] && [ ! -d "$TG/plugin/node_modules" ] && \
  warn "labops-tg-plugin ещё не установлен ($TG) — Telegram-канал будет недоступен, пока не выполните: cd $TG && ./install.sh"
[ -n "$SB" ] && [ ! -x "$SB/.venv/bin/python" ] && \
  warn "labops-second-brain ещё не установлен ($SB) — токен агента придётся ввести вручную позже, см. вывод выше"
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
