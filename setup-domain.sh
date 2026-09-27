#!/usr/bin/env bash
# ============================================================================
#  setup-domain.sh — привязка своего домена + сертификат Let's Encrypt.
#  Включает "режим сервиса": подписки по настоящему HTTPS (порт 8443),
#  клиенты смогут обновлять конфиги автоматически.
#
#  Запуск:   sudo bash setup-domain.sh ваш-домен.ру [ваш@email]
#
#  Перед запуском: создайте у регистратора A-запись:
#      ваш-домен.ру  ->  IP этого сервера
# ============================================================================
set -euo pipefail
[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

DOMAIN="${1:-}"
EMAIL="${2:-}"

if [[ -z "$DOMAIN" ]]; then
  echo "Использование: sudo bash setup-domain.sh ваш-домен.ру [ваш@email]"
  exit 1
fi

PANEL_PORT="${PANEL_PORT:-8080}"
SUB_PORT="${SUB_PORT:-8443}"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
log()  { echo -e "${C}[i]${N} $*"; }
ok()   { echo -e "${G}[✓]${N} $*"; }
die()  { echo -e "${R}[x] $*${N}" >&2; exit 1; }

SERVER_IP="$(hostname -I | awk '{print $1}')"

# --- проверка DNS ------------------------------------------------------------
log "Проверяю, куда указывает домен ${DOMAIN}..."
RESOLVED="$(getent hosts "${DOMAIN}" | awk '{print $1; exit}' || true)"
if [[ -z "$RESOLVED" ]]; then
  die "Домен не резолвится. Создайте A-запись ${DOMAIN} -> ${SERVER_IP} у регистратора и подождите 5–30 минут."
elif [[ "$RESOLVED" != "$SERVER_IP" ]]; then
  warn "Домен указывает на ${RESOLVED}, а IP сервера ${SERVER_IP}."
  warn "Исправьте A-запись и запустите скрипт заново."
  exit 1
fi
ok "Домен указывает на этот сервер."

# --- certbot ------------------------------------------------------------------
log "Устанавливаю certbot и выпускаю сертификат..."
apt-get update -qq
apt-get install -y -qq certbot >/dev/null

systemctl stop nginx   # освобождаем порт 80 для проверки

if [[ -n "$EMAIL" ]]; then
  certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
else
  certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
fi
ok "Сертификат выпущен: /etc/letsencrypt/live/${DOMAIN}/"

systemctl start nginx

# --- обновляем .env панели ------------------------------------------------------
log "Включаю TLS в панели и прописываю домен в подписки..."
ENV=/var/lib/marzban/.env
cp -f "$ENV" "${ENV}.bak.$(date +%s)"

# убираем старые префиксы/настройки
sed -i '/^XRAY_SUBSCRIPTION_URL_PREFIX=/d; /^UVICORN_SSL_KEYFILE=/d; /^UVICORN_SSL_CERTFILE=/d' "$ENV"

cat >> "$ENV" <<EOF
XRAY_SUBSCRIPTION_URL_PREFIX=https://${DOMAIN}:${SUB_PORT}/sub
UVICORN_SSL_KEYFILE=/etc/letsencrypt/live/${DOMAIN}/privkey.pem
UVICORN_SSL_CERTFILE=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem
EOF
ok ".env обновлён"

# --- дописываем в nginx HTTPS-блок на порт 8443 ----------------------------------
log "Настраиваю nginx: подписки и панель по https://${DOMAIN}:${SUB_PORT}"
cat > /etc/nginx/sites-available/marzban <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # для продления сертификата
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen ${SUB_PORT} ssl;
    listen [::]:${SUB_PORT} ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass https://127.0.0.1:${PANEL_PORT};
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
nginx -t && systemctl reload nginx
ok "nginx перенастроен"

# --- файрвол --------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${SUB_PORT}/tcp" comment 'subscriptions https' >/dev/null
  ok "Файрвол: порт ${SUB_PORT} открыт"
fi

# --- автопродление сертификата ----------------------------------------------------
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/marzban.sh <<EOF
#!/usr/bin/env bash
docker compose -f /opt/marzban-service/docker-compose.yml restart
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/marzban.sh

# --- перезапуск панели --------------------------------------------------------------
log "Перезапускаю панель..."
docker compose -f /opt/marzban-service/docker-compose.yml restart

sleep 3
if curl -sk "https://127.0.0.1:${SUB_PORT}/dashboard" -o /dev/null; then
  ok "Панель доступна по https."
fi

echo
echo -e "${G}============================================================${N}"
echo -e "${G} Домен привязан!${N}"
echo -e "${G}============================================================${N}"
echo
echo -e " Подписки теперь отдаются по адресу вида:"
echo -e "   ${C}https://${DOMAIN}:${SUB_PORT}/sub/<токен>${N}"
echo
echo -e " Панель (по-прежнему через SSH-туннель):"
echo -e "   ${C}https://127.0.0.1:8443/dashboard${N}"
echo
echo -e " Раздача клиентам: ${C}bash /root/happ-vpn-service/happ-encode.sh <ссылка-подписка>${N}"
echo
