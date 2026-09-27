#!/usr/bin/env bash
# ============================================================================
#  backup.sh — бэкап базы пользователей, настроек и шаблона Xray.
#  Запуск:  sudo bash backup.sh     (файл: /root/marzban-backup-ДАТА.tar.gz)
#  Рекомендуется поставить в cron, например ежедневно в 04:00:
#    sudo crontab -e   ->   0 4 * * * /opt/marzban-service/backup.sh
# ============================================================================
set -euo pipefail
[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/marzban-backup-${STAMP}.tar.gz"

tar -czf "${OUT}" \
  -C / var/lib/marzban/marzban.db \
       var/lib/marzban/.env \
       var/lib/marzban/xray_config.json \
  2>/dev/null || {
    # если базы ещё нет (свежая установка), берём то, что есть
    tar -czf "${OUT}" -C / var/lib/marzban 2>/dev/null
  }

chmod 600 "${OUT}"
echo "[✓] Бэкап создан: ${OUT}"
ls -lh "${OUT}"

# Оставляем только последние 14 бэкапов
cd /root
ls -1t marzban-backup-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
