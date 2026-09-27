#!/usr/bin/env bash
# ============================================================================
#  health.sh — быстрая проверка: всё ли живо.
#  Запуск:  bash health.sh
# ============================================================================
set -uo pipefail

PANEL_PORT="${PANEL_PORT:-8080}"
VLESS_PORT="${VLESS_PORT:-443}"

ok()  { echo -e "\033[0;32m[✓]\033[0m $*"; }
bad() { echo -e "\033[0;31m[x]\033[0m $*"; }

echo "--- Docker-контейнер ---"
if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q marzban; then
  ok "marzban: $(docker ps --format '{{.Names}}: {{.Status}}' | grep marzban)"
else
  bad "Контейнер marzban не запущен. Логи: docker compose -f /opt/marzban-service/docker-compose.yml logs --tail=50"
fi

echo "--- Панель (локально, порт ${PANEL_PORT}) ---"
if curl -sk -o /dev/null "http://127.0.0.1:${PANEL_PORT}/dashboard"; then
  ok "Панель отвечает по http://127.0.0.1:${PANEL_PORT}/dashboard"
elif curl -sk -o /dev/null "https://127.0.0.1:${PANEL_PORT}/dashboard"; then
  ok "Панель отвечает по https://127.0.0.1:${PANEL_PORT}/dashboard (TLS включён — домен привязан)"
else
  bad "Панель не отвечает на порту ${PANEL_PORT}"
fi

echo "--- Клиентский порт ${VLESS_PORT} ---"
if ss -ltn 2>/dev/null | grep -q ":${VLESS_PORT} "; then
  ok "Порт ${VLESS_PORT} слушается"
else
  bad "Порт ${VLESS_PORT} НЕ слушается — клиенты не подключатся"
fi

echo "--- nginx ---"
if systemctl is-active --quiet nginx 2>/dev/null; then
  ok "nginx активен"
else
  bad "nginx не активен: systemctl status nginx"
fi

echo "--- Дисковое пространство ---"
df -h / | tail -1 | awk '{print "     занято " $5 " из " $2}'
