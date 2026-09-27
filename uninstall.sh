#!/usr/bin/env bash
# ============================================================================
#  uninstall.sh — полное удаление сервиса.
#  Запуск:  sudo bash uninstall.sh
# ============================================================================
set -euo pipefail
[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

read -r -p "Удалить Marzban и ВСЕ данные (пользователи, настройки)? [да/нет]: " ANS
[[ "$ANS" == "да" || "$ANS" == "yes" || "$ANS" == "y" ]] || { echo "Отменено."; exit 0; }

cd /opt/marzban-service 2>/dev/null && docker compose down -v || true
rm -rf /opt/marzban-service
rm -f /etc/nginx/sites-enabled/marzban /etc/nginx/sites-available/marzban
systemctl reload nginx 2>/dev/null || true

echo "Данные в /var/lib/marzban (база пользователей) НЕ удалены на всякий случай."
read -r -p "Удалить и их тоже? [да/нет]: " ANS2
[[ "$ANS2" == "да" ]] && rm -rf /var/lib/marzban && echo "Удалено."

echo "[✓] Готово."
