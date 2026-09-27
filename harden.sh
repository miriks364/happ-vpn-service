#!/usr/bin/env bash
# ============================================================================
#  Базовая защита сервера: firewall (UFW) + sshd-настройки.
#  Запуск:  sudo bash harden.sh
#  ВАЖНО: сначала убедитесь, что ваш SSH-порт нестандартный (если меняли),
#  иначе см. переменную SSH_PORT ниже.
# ============================================================================
set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
VLESS_PORT="${VLESS_PORT:-443}"
PANEL_PORT="${PANEL_PORT:-8080}"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

echo -e "${Y}Настройка файрвола (UFW):${N}"
apt-get install -y -qq ufw >/dev/null || true

ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp"    comment 'SSH'        >/dev/null
ufw allow "${VLESS_PORT}/tcp"  comment 'VLESS'      >/dev/null
ufw allow 80/tcp               comment 'http->panel' >/dev/null
# Порт панели НЕ открываем наружу — доступ только через SSH-туннель.
# Если очень хочется открыть (не рекомендуется):
#   ufw allow ${PANEL_PORT}/tcp
ufw --force enable >/dev/null

echo -e "${G}[✓] Файрвол: открыты только SSH(${SSH_PORT}), ${VLESS_PORT}/tcp (клиенты), 80.${N}"
echo -e "${G}[✓] Порт панели ${PANEL_PORT} закрыт наружу — заходим через SSH-туннель.${N}"

echo
echo -e "${Y}Проверка sshd...${N}"
if grep -qE '^#\s*PermitRootLogin' /etc/ssh/sshd_config; then
  echo "Рекомендация: создайте отдельного пользователя и отключите вход по паролю,"
  echo "оставьте только SSH-ключи. Быстрый вариант:"
  echo "  adduser vpnuser && usermod -aG sudo vpnuser"
  echo "  mkdir -p /home/vpnuser/.ssh && nano /home/vpnuser/.ssh/authorized_keys"
  echo "  затем в /etc/ssh/sshd_config:  PasswordAuthentication no"
  echo "  systemctl restart ssh"
fi

echo
echo -e "${G}Готово.${N} Проверить правила: sudo ufw status verbose"
