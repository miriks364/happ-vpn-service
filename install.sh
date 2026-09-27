#!/usr/bin/env bash
# ============================================================================
#  Установка VPN-сервиса: Marzban (панель) + Xray (VLESS Reality) + nginx
#  Клиенты подключаются через приложение Happ (iOS / Android / Win / macOS)
#
#  Запуск на сервере:   sudo bash install.sh
#
#  Архитектура:
#    - порт 443            -> трафик клиентов (VLESS Reality, маскировка под HTTPS)
#    - порт 8080 (внутрь)  -> панель, доступ ТОЛЬКО через SSH-туннель
#    - порт 80             -> nginx (прокси к панели; позже — Let's Encrypt)
#    - подписки клиентам   -> после привязки домена (см. setup-domain.sh)
# ============================================================================
set -euo pipefail

# ----------------------------- НАСТРОЙКИ ------------------------------------
# Название подписки, которое увидят клиенты в Happ
SUB_TITLE="${SUB_TITLE:-Premium Access}"

# Порт панели
PANEL_PORT="${PANEL_PORT:-8080}"

# Порт, на который подключаются клиенты (443 выглядит как обычный HTTPS)
VLESS_PORT="${VLESS_PORT:-443}"

# Куда маскировать "не-клиентский" трафик (нужен сайт с HTTP/2 и 443-м портом)
DEST="${DEST:-www.speedtest.net:443}"

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)}"
# ----------------------------------------------------------------------------

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
log()  { echo -e "${C}[i]${N} $*"; }
ok()   { echo -e "${G}[✓]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[x] $*${N}" >&2; exit 1; }

# --- проверка прав и ОС ------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
    warn "Рекомендуются Ubuntu 22.04+ / Debian 12+. У вас: ${PRETTY_NAME:-неизвестная ОС}."
    warn "Продолжение может не сработать. Нажмите Ctrl+C чтобы прервать (5 сек)..."
    sleep 5
  fi
else
  die "Не удалось определить ОС (/etc/os-release не найден)."
fi

# --- 1. Базовые пакеты + Docker ----------------------------------------------
log "1/7  Обновляю систему и ставлю базовые пакеты (может занять пару минут)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release openssl ufw >/dev/null
ok "Базовые пакеты установлены"

if ! command -v docker >/dev/null 2>&1; then
  log "2/7  Устанавливаю Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${ID} $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >/dev/null
  ok "Docker установлен"
else
  ok "2/7  Docker уже установлен: $(docker --version)"
fi

# --- 3. Конфигурация панели ---------------------------------------------------
log "3/7  Пишу конфигурацию панели..."
mkdir -p /var/lib/marzban /opt/marzban-service

cat > /var/lib/marzban/.env <<EOF
# --- сгенерировано install.sh $(date '+%F %T') ---
UVICORN_HOST=0.0.0.0
UVICORN_PORT=${PANEL_PORT}
DASHBOARD_PATH=/dashboard
XRAY_SUBSCRIPTION_PATH=/sub

SUDO_USERNAME=${ADMIN_USER}
SUDO_PASSWORD=${ADMIN_PASS}

XRAY_JSON=/var/lib/marzban/xray_config.json
XRAY_SUBSCRIPTION_URL_PREFIX=http://$(hostname -I | awk '{print $1}'):${PANEL_PORT}/sub
SUB_PROFILE_TITLE=${SUB_TITLE}

# TLS включится скриптом setup-domain.sh после привязки домена.
# Телеграм-уведомления (по желанию):
# TELEGRAM_ID=123456789
# TELEGRAM_API_TOKEN=xxxx
EOF
chmod 600 /var/lib/marzban/.env
ok "Конфигурация панели готова"

# --- 4. Шаблон Xray: VLESS + Reality (порт 443) -------------------------------
log "4/7  Пишу шаблон Xray (VLESS Reality, порт ${VLESS_PORT})..."
cat > /var/lib/marzban/xray_config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "api": {
    "tag": "API",
    "services": ["HandlerService", "LoggerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsInboundUplink": true, "statsInboundDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "tag": "API_INBOUND",
      "listen": "127.0.0.1",
      "port": 8088,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "VLESS_REALITY",
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": [],
          "privateKey": "",
          "shortIds": [""]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["API_INBOUND"], "outboundTag": "API" },
      {
        "type": "field",
        "ip": [
          "geoip:private",
          "149.154.160.0/20",
          "91.108.4.0/22",
          "91.108.8.0/22",
          "91.108.12.0/22",
          "91.108.16.0/22",
          "91.108.20.0/22",
          "91.108.56.0/22",
          "95.161.64.0/20"
        ],
        "outboundTag": "BLOCK"
      }
    ]
  }
}
EOF
ok "Шаблон Xray готов. Ключи Reality сгенерируете в панели одной кнопкой."

# --- 5. nginx: порт 80 -> панель (443 отдаём клиентам!) ------------------------
log "5/7  Настраиваю nginx (порт 443 остаётся у Xray для клиентов)..."
apt-get install -y -qq nginx >/dev/null

cat > /etc/nginx/sites-available/marzban <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/marzban /etc/nginx/sites-enabled/marzban
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 && systemctl enable --now nginx && systemctl reload nginx
ok "nginx настроен"

# --- 6. Запуск Marzban ----------------------------------------------------------
log "6/7  Запускаю Marzban (docker compose pull может занять время)..."

cat > /opt/marzban-service/docker-compose.yml <<EOF
services:
  marzban:
    image: gozargah/marzban:latest
    container_name: marzban
    restart: always
    env_file: /var/lib/marzban/.env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
EOF

cat > /opt/marzban-service/marzban-cli.sh <<'EOF'
#!/usr/bin/env bash
# Обёртка над marzban-cli (управление пользователями из консоли)
docker compose -f /opt/marzban-service/docker-compose.yml exec -T marzban marzban-cli "$@"
EOF
chmod +x /opt/marzban-service/marzban-cli.sh
ln -sf /opt/marzban-service/marzban-cli.sh /usr/local/bin/marzban-cli

cd /opt/marzban-service
docker compose pull --quiet || docker compose pull
docker compose up -d

# --- 7. Ждём запуск --------------------------------------------------------------
log "7/7  Жду запуска панели..."
for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:${PANEL_PORT}/dashboard" -o /dev/null; then
    ok "Панель отвечает."
    break
  fi
  sleep 2
done

SERVER_IP="$(hostname -I | awk '{print $1}')"
cat > /root/marzban-setup.txt <<EOF
============================================================
 ВАШ VPN-СЕРВИС УСТАНОВЛЕН  ($(date '+%F %T'))
============================================================

 Логин панели:    ${ADMIN_USER}
 Пароль панели:   ${ADMIN_PASS}

 Панель открывается ТОЛЬКО через SSH-туннель:
   на своём компьютере выполните:
   ssh -L 8443:127.0.0.1:${PANEL_PORT} root@${SERVER_IP}
   затем в браузере:  http://127.0.0.1:8443/dashboard

 ДАЛЕЕ (подробно в README):
 1) В панели: Inbounds -> создать входящее подключение:
      Protocol: VLESS | Security: Reality | Port: ${VLESS_PORT}
      Ключи: кнопка "генерация" прямо в форме создания.
 2) Users -> Add User -> имя, лимит трафика, срок.
 3) Раздача клиенту:
      - сразу:        кнопка "показать конфигурацию" -> скопировать
                      ссылку вида vless://... или QR-код -> в Happ;
      - подпиской:    после привязки домена
                      (см. setup-domain.sh) -> happ-encode.sh.

 Служебные файлы:
   /var/lib/marzban/.env              - настройки панели (логин/пароль)
   /var/lib/marzban/xray_config.json  - шаблон Xray
   /var/lib/marzban/marzban.db        - база данных (для бэкапов!)
============================================================
EOF
chmod 600 /root/marzban-setup.txt

echo
echo -e "${G}============================================================${N}"
echo -e "${G} ГОТОВО! Сервис установлен.${N}"
echo -e "${G}============================================================${N}"
echo
echo -e " Логин:    ${Y}${ADMIN_USER}${N}"
echo -e " Пароль:   ${Y}${ADMIN_PASS}${N}   (сохраните!)"
echo
echo -e " Доступ к панели — только через SSH-туннель:"
echo -e "   ${C}ssh -L 8443:127.0.0.1:${PANEL_PORT} root@${SERVER_IP}${N}"
echo -e "   затем в браузере: ${C}http://127.0.0.1:8443/dashboard${N}"
echo
echo -e " Все детали сохранены в ${C}/root/marzban-setup.txt${N}"
echo -e " Пошаговая инструкция — в README из комплекта."
echo
