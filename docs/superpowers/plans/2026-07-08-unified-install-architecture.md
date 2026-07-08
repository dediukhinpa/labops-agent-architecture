# Unified 3-repo install architecture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `labops-agent-architecture/install.sh` the single entry point that installs foundation dependencies + Claude Code (no Node.js), then clones and installs `labops-tg-plugin` and `labops-second-brain` itself — including on a clean VPS with no `gh`, no SSH keys, and both `labops-second-brain` and (potentially) other repos private — and fix every stale cross-repo reference so docs match the new order.

**Architecture:** `labops-agent-architecture/install.sh` gains three new stages inserted before its existing self-test/agent-creation flow: (1) foundation deps + Claude Code via the native installer, (2) a `GITHUB_TOKEN`-aware `clone_repo()` helper that clones `labops-tg-plugin` and `labops-second-brain` into fixed `$HOME` paths (works whether either repo is public or private — anonymous clone first, `GITHUB_TOKEN` fallback), (3) delegated execution of each sibling repo's own `install.sh`, with a confirmation gate before the root-level, system-provisioning `labops-second-brain` installer runs. `labops-tg-plugin` and `labops-second-brain` install scripts are left functionally as-is (they already work standalone) — only their docs/READMEs get fixed for naming/order consistency.

**Tech Stack:** bash (`set -euo pipefail`), git, curl, apt-get/brew, systemd.

## Global Constraints

- Install order is fixed: `labops-agent-architecture` → `labops-tg-plugin` → `labops-second-brain`. This is the opposite of the CURRENT documented order (sibling repos first) — every doc that states the old order must be corrected, not left as an alternative.
- Claude Code must be installed WITHOUT Node.js/npm — use the native installer (`curl -fsSL https://claude.ai/install.sh | bash`, already verified working in this session), not `npm i -g @anthropic-ai/claude-code`.
- Clone targets are fixed paths that already match existing detection defaults elsewhere in the codebase — do not invent new ones:
  - `labops-tg-plugin` → `$HOME/labops-tg-plugin` (matches `new-agent.sh` detection default AND the fact that `new-agent.sh` symlinks `$TG_PLUGIN_DIR` into each agent's workspace — changing this path would break that symlink).
  - `labops-second-brain` → `$HOME/labops-second-brain` (matches `new-agent.sh` detection default; the repo's own installer rsyncs itself into `/opt/second_brain` regardless of clone source, so this is just the source checkout location).
- Repo visibility is not stable: as of this session `labops-tg-plugin` and `labops-agent-architecture` are public and `labops-second-brain` is public too (verified via anonymous `git ls-remote`), but the operator intends to make **all three** private going forward. Do not hardcode "repo X is public" anywhere in code or docs — `clone_repo()` must try anonymous clone first and fall back to `GITHUB_TOKEN` on failure for **every** repo, and the top-level bootstrap command (cloning `labops-agent-architecture` itself, before `install.sh` even exists locally) must also use the token form so it keeps working the day that repo goes private too. The clone step must work on a bare VPS with only `git` installed — no `gh` CLI, no pre-provisioned SSH key. Auth is via a `GITHUB_TOKEN` env var the operator exports before running the one-shot command; never write the token into any `.git/config` or persist it to disk.
- `labops-second-brain`'s own installer (`scripts/install.sh`) requires root, creates a dedicated OS user, installs Postgres+Caddy system-wide, and downloads a ~1.3 GB model — this is materially heavier/more destructive than the other two. The orchestrator must gate running it behind an explicit confirmation (bypassable with `--yes` / `AUTO_YES=1` for non-interactive runs), it must not run silently by default without the operator seeing what's about to happen.
- Every doc/README edit must be a real find-and-replace against the exact current text (quoted below) — do not paraphrase-and-hope.
- Git commits in Russian (per repo convention already used — see recent tg-plugin commit `d30266c`).

---

### Task 1: Foundation deps + Claude Code (no Node.js) in `labops-agent-architecture/install.sh`

**Files:**
- Modify: `/home/myaiagent/labops-agent-architecture/install.sh:36–51`

**Interfaces:**
- Produces: `install_via_pkgmgr()` bash function, `SUDO` variable — both reused by Task 2/3 additions in the same file.

Current lines 36–51 (the block being replaced):

```bash
# ── 1. Окружение и зависимости ───────────────────────────────────
say "1. Окружение"
command -v bash >/dev/null || die "нужен bash"
if command -v claude >/dev/null 2>&1; then
  ok "claude найден"
  echo "    Модель подключается через подписку: если ещё не входили — 'claude setup-token' (Max/Pro)."
else
  warn "Claude Code (claude) не в PATH — нужен для запуска агента: npm i -g @anthropic-ai/claude-code"
  warn "после установки авторизуйте модель разово: 'claude setup-token'"
fi
command -v tmux >/dev/null 2>&1 && ok "tmux найден" || die "нужен tmux (рантайм агента живёт в tmux-сессии): apt-get install tmux"
if command -v systemctl >/dev/null 2>&1; then ok "systemd найден"; else
  warn "systemd (systemctl) не найден — автозапуск недоступен (Linux+systemd обязателен для сервиса)."
  warn "на macOS/без systemd агент можно запускать вручную, но не как службу."
fi
for c in curl jq python3; do command -v "$c" >/dev/null 2>&1 && ok "$c" || warn "$c не найден (часть шагов деградирует)"; done
```

- [ ] **Step 1: Replace the block above with auto-install logic**

```bash
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
```

- [ ] **Step 2: Syntax check**

Run: `bash -n /home/myaiagent/labops-agent-architecture/install.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Manual smoke check of the new block in isolation**

Run (on this VPS, where tmux/claude/git/curl/jq/unzip already exist — this exercises the "already installed" branch, the cheapest safe check):
```bash
bash -c 'set -euo pipefail; source <(sed -n "36,80p" /home/myaiagent/labops-agent-architecture/install.sh | sed "1d")' 2>&1 | tail -20
```
Expected: prints `✓ git`, `✓ curl`, `✓ jq`, `✓ unzip`, `✓ tmux x.x`, `✓ claude найден`, `✓ systemd найден`, `✓ python3` — no `die`.

- [ ] **Step 4: Commit**

```bash
cd ~/labops-agent-architecture
git add install.sh
git commit -m "install.sh: доустанавливаем tmux/git/curl/jq/unzip/claude вместо остановки

Claude Code теперь ставится нативным installer'ом (curl -fsSL
https://claude.ai/install.sh), без Node.js/npm — раньше скрипт только
предупреждал и требовал npm i -g @anthropic-ai/claude-code вручную."
```

---

### Task 2: `GITHUB_TOKEN`-aware clone helper + auto-clone siblings

**Files:**
- Modify: `/home/myaiagent/labops-agent-architecture/install.sh:53–59` (current sibling-detection block)

**Interfaces:**
- Consumes: `SUDO`, `install_via_pkgmgr()` from Task 1 (not directly, but same file scope).
- Produces: `clone_repo()` function, `SB` and `TG` variables populated with clone destinations (same variable names the rest of the script — lines 85–86 — already consumes via `export SECOND_BRAIN_DIR="$SB"` / `export TG_PLUGIN_DIR="$TG"`). Do not rename `SB`/`TG` — Task 3 and the existing lines 85–86 depend on these exact names.

Current lines 53–59 (the block being replaced):

```bash
# мягкая проверка соседних репозиториев
SB=""; for d in "${SECOND_BRAIN_DIR:-}" /opt/second_brain "$HOME/labops-second-brain"; do
  [ -n "$d" ] && [ -d "$d/services" ] && SB="$d" && break; done
[ -n "$SB" ] && ok "labops-second-brain: $SB" || warn "labops-second-brain не найден — токен агента придётся ввести вручную (или поставьте репозиторий)"
TG=""; for d in "${TG_PLUGIN_DIR:-}" "$HOME/labops-tg-plugin" "$LAB_DIR/shared/plugins/labops-tg-plugin"; do
  [ -n "$d" ] && [ -d "$d/plugin" ] && TG="$d" && break; done
[ -n "$TG" ] && ok "labops-tg-plugin: $TG" || warn "labops-tg-plugin не найден — Telegram-канал будет пропущен (поставьте репозиторий)"
```

- [ ] **Step 1: Replace with clone-if-missing logic**

```bash
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
```

Note: this changes `SB`/`TG` semantics from "detected existing path or empty" to "the fixed target path, always set (unless explicitly skipped)" — since `clone_repo` guarantees the repo exists at that path by the time it returns (or the script has already `die`d). This is intentional: lines 85–86 (`[ -n "$SB" ] && export SECOND_BRAIN_DIR="$SB"`) keep working unchanged since `$SB`/`$TG` are non-empty in the success case.

- [ ] **Step 2: Syntax check**

Run: `bash -n /home/myaiagent/labops-agent-architecture/install.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Manual test — public repo clone-if-missing**

```bash
rm -rf /tmp/clone-test-tg && \
bash -c '
source <(sed -n "/^clone_repo() {/,/^}/p" /home/myaiagent/labops-agent-architecture/install.sh)
clone_repo "labops-tg-plugin" "https://github.com/dediukhinpa/labops-tg-plugin.git" "/tmp/clone-test-tg"
' 2>&1
ls /tmp/clone-test-tg/install.sh && echo "OK: файл на месте"
rm -rf /tmp/clone-test-tg
```
Expected: `✓ labops-tg-plugin склонирован`, then `OK: файл на месте`.

- [ ] **Step 4: Manual test — private repo without token fails with actionable message**

```bash
unset GITHUB_TOKEN
rm -rf /tmp/clone-test-sb && \
bash -c '
source <(sed -n "/^clone_repo() {/,/^}/p" /home/myaiagent/labops-agent-architecture/install.sh)
clone_repo "labops-second-brain" "https://github.com/dediukhinpa/labops-second-brain.git" "/tmp/clone-test-sb"
' ; echo "exit code: $?"
```
Expected: exit code 1, stderr shows the `die` message mentioning `GITHUB_TOKEN=ghp_xxx ./install.sh`.

- [ ] **Step 5: Manual test — private repo WITH token succeeds (only if a valid dediukhinpa token is available in the session)**

```bash
rm -rf /tmp/clone-test-sb && \
GITHUB_TOKEN="$GITHUB_TOKEN" bash -c '
source <(sed -n "/^clone_repo() {/,/^}/p" /home/myaiagent/labops-agent-architecture/install.sh)
clone_repo "labops-second-brain" "https://github.com/dediukhinpa/labops-second-brain.git" "/tmp/clone-test-sb"
'
git -C /tmp/clone-test-sb config --get-regexp http.extraHeader; echo "extraHeader leaked: $?"
rm -rf /tmp/clone-test-sb
```
Expected: `✓ labops-second-brain склонирован (по GITHUB_TOKEN)`; the `git config --get-regexp` must print nothing and exit non-zero ("extraHeader leaked: 1") — confirms the token was NOT persisted into `.git/config`.

- [ ] **Step 6: Commit**

```bash
cd ~/labops-agent-architecture
git add install.sh
git commit -m "install.sh: клонируем labops-tg-plugin и labops-second-brain сами

Раньше install.sh только предупреждал об отсутствии соседних репо и
требовал ставить их руками. Теперь клонирует оба в фиксированные пути
(~/labops-tg-plugin, ~/labops-second-brain) идемпотентно. Приватный
labops-second-brain поддержан через GITHUB_TOKEN (для чистого VPS без
gh/SSH) — токен передаётся только на время git clone, в .git/config не
попадает. SKIP_SECOND_BRAIN=1 / SKIP_TG_PLUGIN=1 — чтобы пропустить."
```

---

### Task 3: Delegate to sibling install.sh scripts, with confirmation gate for second-brain

**Files:**
- Modify: `/home/myaiagent/labops-agent-architecture/install.sh` — insert a new stage after the Task 2 block (which ends right before the existing `# скрипты должны быть исполняемыми` comment at old line 61) and before the existing `chmod +x` line.

**Interfaces:**
- Consumes: `SB`, `TG` from Task 2.
- Produces: nothing new consumed downstream; this is a leaf stage.

- [ ] **Step 1: Insert delegated-install stage**

Insert immediately after the Task 2 block, before the existing line `# скрипты должны быть исполняемыми`:

```bash
# ── Установка соседних репозиториев их же install.sh ──────────────
if [ -n "$TG" ] && [ -x "$TG/install.sh" ]; then
  say "Устанавливаю labops-tg-plugin ($TG)"
  ( cd "$TG" && ./install.sh ) || die "labops-tg-plugin/install.sh провалился — установка остановлена."
  ok "labops-tg-plugin установлен"
fi

if [ -n "$SB" ] && [ -x "$SB/scripts/install.sh" ]; then
  say "labops-second-brain: root-провижининг (Postgres+pgvector, Caddy, systemd, ~1.3ГБ модель embeddings)"
  PROCEED="${AUTO_YES:-0}"
  if [ "$PROCEED" != "1" ] && [ -t 0 ]; then
    read -r -p "Установить labops-second-brain сейчас? Потребуется sudo. [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] && PROCEED=1
  fi
  if [ "$PROCEED" = "1" ]; then
    $SUDO bash "$SB/scripts/install.sh" || die "labops-second-brain/scripts/install.sh провалился — установка остановлена."
    ok "labops-second-brain установлен"
  else
    warn "labops-second-brain НЕ установлен (пропущено оператором) — запустите позже вручную: sudo bash $SB/scripts/install.sh"
  fi
fi
```

Also update the flag-parsing block near the top (current lines 28–30) to recognize `--yes`:

Current:
```bash
MODE="full"
[ "${1:-}" = "--test-only" ] && MODE="test"
[ "${1:-}" = "--no-agent" ] && MODE="prep"
```

Replace with:
```bash
MODE="full"
[ "${1:-}" = "--test-only" ] && MODE="test"
[ "${1:-}" = "--no-agent" ] && MODE="prep"
[ "${1:-}" = "--yes" ] && AUTO_YES=1
```

- [ ] **Step 2: Syntax check**

Run: `bash -n /home/myaiagent/labops-agent-architecture/install.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Manual dry check of the gating logic (no real install triggered)**

```bash
bash -c '
TG=""; SB="/tmp/does-not-exist"
say() { :; }; ok() { echo "OK: $*"; }; warn() { echo "WARN: $*"; }; die() { echo "DIE: $*"; exit 1; }
SUDO=""
'"$(sed -n '/# ── Установка соседних репозиториев/,/^fi$/p' /home/myaiagent/labops-agent-architecture/install.sh | tail -n +1)"'
'
```
Expected: since `$TG` is empty and `$SB/scripts/install.sh` does not exist, both `if` blocks are skipped — no output, exit 0. This confirms the stage no-ops safely when siblings are absent/skipped (e.g. `SKIP_TG_PLUGIN=1`, `SKIP_SECOND_BRAIN=1`).

- [ ] **Step 4: Update usage comment at top of file**

Current lines 13–16:
```bash
# Использование:
#   ./install.sh              # self-test + создать агента Developer (интерактивно)
#   ./install.sh --test-only  # только self-test
#   ./install.sh --no-agent   # подготовить, но агента не создавать
```

Replace with:
```bash
# Использование:
#   ./install.sh              # деплой + siblings + self-test + Developer (интерактивно)
#   ./install.sh --test-only  # только self-test
#   ./install.sh --no-agent   # подготовить, но агента не создавать
#   ./install.sh --yes        # не спрашивать подтверждение перед установкой labops-second-brain
#
# Env overrides:
#   GITHUB_TOKEN=ghp_xxx      # нужен на чистом VPS для клонирования приватного labops-second-brain
#   SKIP_SECOND_BRAIN=1       # не клонировать/не ставить labops-second-brain
#   SKIP_TG_PLUGIN=1          # не клонировать/не ставить labops-tg-plugin
#   AUTO_YES=1                # то же самое, что --yes
```

- [ ] **Step 5: Commit**

```bash
cd ~/labops-agent-architecture
git add install.sh
git commit -m "install.sh: ставим tg-plugin и second-brain их же install.sh

tg-plugin ставится сразу. second-brain — root-провижининг (Postgres,
Caddy, systemd, ~1.3ГБ модель), поэтому перед ним спрашиваем
подтверждение; --yes/AUTO_YES=1 для неинтерактивного прогона."
```

---

### Task 4: Fix `labops-agent-architecture` docs (README x2, warning strings)

**Files:**
- Modify: `/home/myaiagent/labops-agent-architecture/README.md:106–128, 396–419`
- Modify: `/home/myaiagent/labops-agent-architecture/README.ru.md` (mirror sections — read file first to find exact current Russian text at the equivalent Quickstart/Installation sections before editing, since exact line numbers weren't captured this round; search for the same `npm i -g @anthropic-ai/claude-code` string and the `# 1. Bring up the sibling repos first` code block, which will have a Russian-text equivalent nearby).
- Modify: `/home/myaiagent/labops-agent-architecture/skills/create-agent/new-agent.sh:57`
- Modify: `/home/myaiagent/labops-agent-architecture/agent-template/install.sh:71`
- Modify: `/home/myaiagent/labops-agent-architecture/agent-template/docs/SETUP-GUIDE.md:27`

- [ ] **Step 1: README.md Quickstart — replace lines 106–128**

Current (line 106):
```
1. **Dependencies:** `claude` (Claude Code) + a one-time `claude setup-token` (Max/Pro subscription), `tmux`, `systemd`, `curl`, `jq`. Plus the sibling repos: `labops-second-brain` (Bearer token) and `labops-tg-plugin` (chat).
2. **Install the engine and sign in:** `npm i -g @anthropic-ai/claude-code && claude setup-token`.
```

Replace with:
```
1. **One command installs everything:** `bash install.sh` — installs tmux/git/curl/jq/unzip + Claude Code (native installer, no Node.js required), then clones and installs the sibling repos itself: `labops-tg-plugin` and `labops-second-brain`.
2. **Sign in once:** `claude setup-token` (Max/Pro subscription).
```

Current code block (lines 114–128):
```bash
# 1. Bring up the sibling repos first (brain + channel)
#    see labops-second-brain/README and labops-tg-plugin/README

# 1a. Install the engine and connect the model
npm i -g @anthropic-ai/claude-code
claude setup-token       # sign in with a Max/Pro subscription (model choice is in the install dialog below)

# 2. Install the Developer agent from this repository
cd labops-agent-architecture
bash install.sh          # model → identity → scaffold → bot → voice → token → systemd → smoke

# 3. After install, the swarm is grown by the Developer agent itself
#    (it invokes the create-agent skill at the Operator's request)
```

Replace with:
```bash
# 1. Clone this repo and run its installer — it deploys tmux/curl/jq/unzip,
#    Claude Code (native, no Node.js), and clones+installs the sibling repos
#    (labops-tg-plugin, labops-second-brain) itself.
#    All three labops-* repos may be private — on a clean VPS with no gh/SSH
#    set up, export a token first (fine-grained, Contents:Read on all three
#    repos, issued from the repo-owner GitHub account) and use the
#    token-authenticated clone form below. It works the same whether the
#    repo is public or private, so this is the one command to remember.
export GITHUB_TOKEN=ghp_xxx
git -c http.extraHeader="Authorization: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)" \
  clone https://github.com/dediukhinpa/labops-agent-architecture.git
cd labops-agent-architecture
bash install.sh   # model → identity → scaffold → bot → voice → token → systemd → smoke

# 2. Sign in once (Max/Pro subscription; model choice is in the install dialog above)
claude setup-token

# 3. After install, the swarm is grown by the Developer agent itself
#    (it invokes the create-agent skill at the Operator's request)
```

- [ ] **Step 2: README.md Installation & model/auth section — replace lines 396–419**

Current:
```
**Dependencies (the script checks them):**

- an installed **`labops-second-brain`** — to issue the agent a Bearer token and bring up the MCP `memory`/`recall`/`swarm`;
- an installed **`labops-tg-plugin`** — the channel through which the agent talks on Telegram;
- **Claude Code (the engine) + a connected model** — `npm i -g @anthropic-ai/claude-code`, then a **one-time subscription sign-in**: `claude setup-token` (Max/Pro, first-party — no third-party risk). The agent's model is set in `settings.json` (the `model` field); the install dialog asks for it and recommends **`opus` (Opus 4.8)** for the Developer. Without sign-in the agent starts under systemd but can't reach the model — the smoke test catches this (the "model responds" step).
```

Replace with:
```
**Dependencies (the script installs them):**

- **Claude Code** — installed by `install.sh` itself via the native installer (no Node.js/npm); then a **one-time subscription sign-in**: `claude setup-token` (Max/Pro, first-party — no third-party risk). The agent's model is set in `settings.json` (the `model` field); the install dialog asks for it and recommends **`opus` (Opus 4.8)** for the Developer. Without sign-in the agent starts under systemd but can't reach the model — the smoke test catches this (the "model responds" step).
- **`labops-tg-plugin`** — cloned to `~/labops-tg-plugin` and installed by `install.sh` itself; the channel through which the agent talks on Telegram.
- **`labops-second-brain`** — cloned to `~/labops-second-brain` by `install.sh`; to issue the agent a Bearer token and bring up the MCP `memory`/`recall`/`swarm` you'll be asked to confirm running its root-level installer (Postgres+pgvector, Caddy, systemd, ~1.3 GB embeddings model).
- All three `labops-*` repos may be private — see the `GITHUB_TOKEN` note in Quickstart for clean-VPS installs with no `gh`/SSH configured.
```

And the code block at lines 405–419 (identical to the Quickstart one) — apply the same replacement as Step 1's code block.

- [ ] **Step 3: Mirror Steps 1–2 in README.ru.md**

Read `/home/myaiagent/labops-agent-architecture/README.ru.md`, locate the Russian Quickstart and "Установка" sections (search for `npm i -g @anthropic-ai/claude-code` and `Bring up the sibling repos` / its Russian equivalent), and apply the same restructuring: single-command install first, sibling repos cloned automatically, `GITHUB_TOKEN` note covering the case where any/all of the three `labops-*` repos are private, native Claude Code installer instead of npm.

- [ ] **Step 4: Fix warning strings that suggest npm**

`/home/myaiagent/labops-agent-architecture/skills/create-agent/new-agent.sh:57` — current:
```bash
warn "claude не в PATH — поставьте: npm i -g @anthropic-ai/claude-code, затем 'claude setup-token'"
```
Replace with:
```bash
warn "claude не в PATH — поставьте: curl -fsSL https://claude.ai/install.sh | bash, затем 'claude setup-token'"
```

`/home/myaiagent/labops-agent-architecture/agent-template/install.sh:71` — current:
```bash
warn "Claude Code CLI not found. Install: npm install -g @anthropic-ai/claude-code"
```
Replace with:
```bash
warn "Claude Code CLI not found. Install: curl -fsSL https://claude.ai/install.sh | bash"
```

`/home/myaiagent/labops-agent-architecture/agent-template/docs/SETUP-GUIDE.md:27` — current:
```
- Claude Code CLI: `npm install -g @anthropic-ai/claude-code`
```
Replace with:
```
- Claude Code CLI: `curl -fsSL https://claude.ai/install.sh | bash` (native installer, no Node.js needed)
```

- [ ] **Step 5: Verify no stale npm-install mentions remain**

Run: `grep -rn "npm i.*claude-code\|npm install -g @anthropic-ai/claude-code" /home/myaiagent/labops-agent-architecture --include="*.md" --include="*.sh"`
Expected: no output (empty).

- [ ] **Step 6: Commit**

```bash
cd ~/labops-agent-architecture
git add README.md README.ru.md skills/create-agent/new-agent.sh agent-template/install.sh agent-template/docs/SETUP-GUIDE.md
git commit -m "доки: новый порядок установки (architecture ставит siblings сама)

README/README.ru: install.sh теперь единственная команда — сам ставит
зависимости, Claude Code (без Node.js) и клонирует+ставит
labops-tg-plugin/labops-second-brain. Убраны все упоминания npm i -g
@anthropic-ai/claude-code как способа установки — везде нативный
installer."
```

---

### Task 5: Fix `labops-tg-plugin` naming/org inconsistencies

**Files:**
- Modify: `/home/myaiagent/labops-tg-plugin/docs/02-where-to-place-plugin.md`
- Modify: `/home/myaiagent/labops-tg-plugin/docs/03-installation-linux.md`
- Modify: `/home/myaiagent/labops-tg-plugin/docs/03-installation-macos.md`
- Modify: `/home/myaiagent/labops-tg-plugin/docs/03-installation.md`
- Modify: `/home/myaiagent/labops-tg-plugin/examples/channel.env.example`
- Modify: `/home/myaiagent/labops-tg-plugin/README.md:42`, `/home/myaiagent/labops-tg-plugin/README.ru.md:42`

- [ ] **Step 1: Global rename `labops-plugin-claude-code` → `labops-tg-plugin` in docs**

Run this across the four docs files (directory name in paths, not prose that's already correct):
```bash
cd ~/labops-tg-plugin
grep -rln "labops-plugin-claude-code" docs/ examples/ | xargs sed -i 's/labops-plugin-claude-code/labops-tg-plugin/g'
```

- [ ] **Step 2: Fix wrong GitHub org/repo in docs/03-installation-linux.md**

Current (line ~74, after Step 1's rename already applied to the dir name portion):
```bash
git clone https://github.com/qwwiwi/labops-tg-plugin.git
```
Replace with:
```bash
git clone https://github.com/dediukhinpa/labops-tg-plugin.git
```

And the second-brain reference (line ~295):
```
Альтернатива: используйте second_brain (qwwiwi/public-second_brain-agentos) — там MCP-серверы для memory/recall/swarm.
```
Replace with:
```
Альтернатива: используйте second_brain (dediukhinpa/labops-second-brain) — там MCP-серверы для memory/recall/swarm.
```

And the CLAUDE.md template reference (line ~107) mentioning `github.com/qwwiwi/public-second_brain-agentos/tree/main/agent-template`:
Replace `qwwiwi/public-second_brain-agentos` → `dediukhinpa/labops-second-brain` in that URL.

- [ ] **Step 3: Fix docs/06-how-claude-loads-session.md and docs/INTER-AGENT-WEBHOOKS.md cross-refs if present**

Run: `grep -rn "qwwiwi" /home/myaiagent/labops-tg-plugin`
For each hit, replace `qwwiwi/labops-plugin-claude-code` → `dediukhinpa/labops-tg-plugin` and `qwwiwi/public-second_brain-agentos` → `dediukhinpa/labops-second-brain`.

- [ ] **Step 4: Update README.md/README.ru.md Prerequisites line (stale "checks and fails" text)**

`/home/myaiagent/labops-tg-plugin/README.md:42` — current:
```
Prerequisites: `bun ≥ 1.3`, `tmux`, `claude ≥ v2.1.80` in PATH
(`install.sh` checks and fails if any is missing).
```
Replace with:
```
Prerequisites: none — `install.sh` auto-installs `bun ≥ 1.3`, `tmux`,
`claude ≥ v2.1.80` if any is missing.
```
Mirror the same change at `/home/myaiagent/labops-tg-plugin/README.ru.md:42`.

- [ ] **Step 5: Add orchestrated-install note to README.md/README.ru.md**

After the existing "Part of labops" table (README.md around line 313, README.ru.md at its mirror location), add:

```markdown
> **Installed via `labops-agent-architecture`?** Its `install.sh` clones this
> repo to `~/labops-tg-plugin` and runs this repo's `install.sh` for you —
> you don't need to clone this repo yourself. `new-agent.sh` then symlinks
> `~/labops-tg-plugin` into each new agent's workspace
> (`~/.claude-lab/<agent>/.claude/labops-tg-plugin`). Manual per-agent clone
> (below) is only needed if you're running this plugin standalone, without
> `labops-agent-architecture`.
```

- [ ] **Step 6: Verify no stale references remain**

Run: `grep -rn "qwwiwi\|labops-plugin-claude-code" /home/myaiagent/labops-tg-plugin`
Expected: no output.

- [ ] **Step 7: Commit and push**

```bash
cd ~/labops-tg-plugin
git add -A
git commit -m "доки: убрали расхождения в названии репо и чужой GitHub org

docs/02, docs/03-*, examples/channel.env.example ссылались на несуществующее
имя папки labops-plugin-claude-code и на чужой аккаунт qwwiwi — везде
заменено на реальные labops-tg-plugin / dediukhinpa. README: prerequisites
больше не говорят 'checks and fails' (install.sh теперь доустанавливает
сам), добавлена заметка про автоматическую установку через
labops-agent-architecture."
git push origin main
```

---

### Task 6: Fix `labops-second-brain` cross-references

**Files:**
- Modify: `/home/myaiagent/labops-second-brain/docs/INTER-AGENT-WEBHOOKS.md`
- Modify: `/home/myaiagent/labops-second-brain/README.md:299–304`, `/home/myaiagent/labops-second-brain/README.ru.md` (mirror)

- [ ] **Step 1: Fix wrong plugin repo reference in docs/INTER-AGENT-WEBHOOKS.md**

Current (lines 154–162):
```bash
git clone https://github.com/qwwiwi/labops-plugin-claude-code.git plugin
cd plugin && npm install
```
Replace with:
```bash
git clone https://github.com/dediukhinpa/labops-tg-plugin.git plugin
cd plugin/plugin && bun install
```
(Note the corrected subdirectory: `labops-tg-plugin`'s installable code lives under `plugin/plugin/`, not `plugin/` — the plugin repo's own `PLUGIN_DIR="$REPO_DIR/plugin"` convention — and it uses `bun`, not `npm`.)

And the doc pointer right after it:
```
Полный мануал: docs/02-where-to-place-plugin.md и docs/03-installation.md в plugin репо.
```
This is still correct (those docs exist in `labops-tg-plugin`), no change needed here.

- [ ] **Step 2: Update README.md "Dependency on the other repos" note (lines 299–304)**

Current:
```
**Dependency on the other repos:**
- If **agents already exist** on the machine ([`labops-agent-architecture`](#part-of-labops) is installed) — the installer additionally registers their tokens (`issue-agent-token.py`) without overwriting existing ones.
- If the brain is installed **first** — agent tokens are issued later, when the agents are installed.
```

Replace with:
```
**Dependency on the other repos:**
- The canonical install order is `labops-agent-architecture` → `labops-tg-plugin` → `labops-second-brain`: `labops-agent-architecture`'s `install.sh` clones this repo to `~/labops-second-brain` and runs `scripts/install.sh` for you (with a confirmation prompt, since it's a root-level provisioning step).
- If this repo (or any of the three `labops-*` repos) is private, cloning it standalone (or letting `labops-agent-architecture` clone it) on a machine with no `gh` CLI and no SSH key configured requires a `GITHUB_TOKEN` env var (fine-grained PAT, `Contents: Read` on this repo, issued from the repo-owner GitHub account).
- If **agents already exist** on the machine (`labops-agent-architecture` is installed) — the installer additionally registers their tokens (`issue-agent-token.py`) without overwriting existing ones.
```

Mirror in `README.ru.md` (locate the equivalent Russian section first).

- [ ] **Step 3: Verify**

Run: `grep -rn "qwwiwi" /home/myaiagent/labops-second-brain`
Expected: no output.

- [ ] **Step 4: Commit and push**

```bash
cd ~/labops-second-brain
git add -A
git commit -m "доки: canonical install order + GITHUB_TOKEN для клонирования на чистый VPS

INTER-AGENT-WEBHOOKS.md ссылался на чужой репо/org (qwwiwi) и на npm —
исправлено на dediukhinpa/labops-tg-plugin + bun. README: явный порядок
установки (architecture → tg-plugin → second-brain) и заметка про
GITHUB_TOKEN для приватного клонирования без gh/SSH."
git push origin main
```

---

### Task 7: Cross-repo verification sweep

**Files:** none (verification only)

- [ ] **Step 1: Confirm no repo still documents the old order**

```bash
grep -rn "Bring up the sibling repos first\|sibling repos first" \
  ~/labops-agent-architecture ~/labops-tg-plugin ~/labops-second-brain \
  --include="*.md" 2>/dev/null
```
Expected: no output (or only inside this plan file itself under `docs/superpowers/plans/`, which is fine — it documents history).

- [ ] **Step 2: Confirm no repo still tells people to `npm i -g @anthropic-ai/claude-code` as the install method**

```bash
grep -rln "npm i.*claude-code\|npm install -g @anthropic-ai/claude-code" \
  ~/labops-agent-architecture ~/labops-tg-plugin ~/labops-second-brain \
  --include="*.md" --include="*.sh" 2>/dev/null
```
Expected: no output.

- [ ] **Step 3: Confirm every repo's install.sh is syntactically valid**

```bash
bash -n ~/labops-agent-architecture/install.sh && echo "architecture OK"
bash -n ~/labops-tg-plugin/install.sh && echo "tg-plugin OK"
bash -n ~/labops-second-brain/scripts/install.sh && echo "second-brain OK"
```
Expected: all three print OK.

- [ ] **Step 4: Push `labops-agent-architecture` (last, since it references the other two by their now-fixed URLs)**

```bash
cd ~/labops-agent-architecture
git push origin main
```

- [ ] **Step 5: Report final state to the user**

Summarize: what each repo's `install.sh` now does, the exact one-liner the user runs on a clean VPS (`GITHUB_TOKEN=ghp_xxx bash -c "$(curl -fsSL https://raw.githubusercontent.com/dediukhinpa/labops-agent-architecture/main/install.sh)"` or clone+run), and flag the pre-existing gap found during research but out of this plan's scope: `new-agent.sh` does not automatically run `labops-tg-plugin`'s `install-hooks.sh` / set up the per-agent `channel-<agent>.service` — that remains a manual step per `labops-tg-plugin/docs/03-installation-linux.md`.
