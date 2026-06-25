#!/usr/bin/env bash
#
# test.sh — self-test репозитория labops-agent-architecture.
# Прогоняется install.sh в конце установки как gate (всё должно быть зелёным).
#
# Проверяет: синтаксис всех bash-скриптов, компиляцию python, ОТСУТСТВИЕ секретов.

set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "${G}✓${N} %s\n" "$*"; pass=$((pass+1)); }
bad() { printf "${R}✗${N} %s\n" "$*"; fail=$((fail+1)); }

echo "── 1. Синтаксис bash-скриптов ──"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then :; else bad "bash -n: $f"; fi
done < <(find . -name '*.sh' -not -path '*/node_modules/*')
[ "$fail" -eq 0 ] && ok "все bash-скрипты разбираются"

echo "── 2. Компиляция python ──"
if command -v python3 >/dev/null; then
  pyfail=0
  while IFS= read -r f; do
    python3 -m py_compile "$f" 2>/dev/null || { bad "py_compile: $f"; pyfail=1; }
  done < <(find . -name '*.py' -not -path '*/__pycache__/*')
  [ "$pyfail" -eq 0 ] && ok "все python-файлы компилируются"
else
  printf "${Y}⚠${N} python3 не найден — пропуск\n"
fi

echo "── 3. Нет секретов (бот-токены / реальные ID / Tailscale) ──"
if grep -rnE '[0-9]{8,}:AA[A-Za-z0-9_-]{20,}' . --include='*.sh' --include='*.md' --include='*.py' --include='*.template' --exclude=test.sh 2>/dev/null | grep -q .; then
  bad "найдены литералы Telegram бот-токенов!"
else
  ok "бот-токенов нет"
fi
if grep -rnE '100000001|100000002|100\.97\.43\.' . --include='*.sh' --include='*.md' --include='*.py' --exclude=test.sh 2>/dev/null | grep -q .; then
  bad "найдены реальные user/chat ID или Tailscale-IP!"
else
  ok "реальных ID/Tailscale нет"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf "${G}✅ self-test пройден (%d проверок).${N}\n" "$pass"; exit 0
else
  printf "${R}❌ self-test провален: %d ошибок.${N}\n" "$fail"; exit 1
fi
