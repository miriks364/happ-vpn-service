#!/usr/bin/env bash
# ============================================================================
#  happ-encode.sh — превращает обычную ссылку-подписку в зашифрованную
#  подписку вида  happ://crypto:...  (официальный способ для Happ).
#
#  Зачем: клиент вставляет её в Happ и НЕ видит адрес вашего сервера и
#  параметры — только подключается. Подмена/пересылка конфига усложняется.
#
#  Использование на сервере:
#    bash happ-encode.sh "https://ваш-домен:8443/sub/токен"
#
#  Ссылку-подписку берём в панели: пользователь -> "Ссылка-подписка".
#  ВНИМАНИЕ: подписки нормально обновляются у клиентов только после
#  привязки домена (см. setup-domain.sh) — нужен настоящий HTTPS.
# ============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Использование: bash happ-encode.sh <ссылка-подписка из панели>"
  exit 1
fi

SUB_URL="$1"

echo "[i] Шифрую подписку через официальный API Happ..."
RESPONSE="$(curl -sS -X POST -H "Content-Type: application/json" \
  -d "{\"url\":\"${SUB_URL}\"}" \
  "https://crypto.happ.su/api-v2.php")" || {
    echo "[x] Не удалось связаться с api.happ. Проверьте интернет на сервере."
    exit 1
  }

if [[ -z "$RESPONSE" ]]; then
  echo "[x] API вернул пустой ответ."
  exit 1
fi

# API может вернуть либо саму строку, либо JSON {"url":"happ://..."}
if command -v python3 >/dev/null 2>&1; then
  ENCODED="$(python3 - "$RESPONSE" <<'EOF'
import json, sys
raw = sys.argv[1].strip()
try:
    data = json.loads(raw)
    if isinstance(data, dict):
        print(data.get("encrypted_link") or data.get("url") or data.get("link") or data.get("result") or raw)
    else:
        print(raw)
except Exception:
    print(raw)
EOF
)"
else
  ENCODED="$RESPONSE"
fi

if [[ "$ENCODED" != happ://* ]]; then
  echo "[x] Ответ не похож на зашифрованную подписку: ${ENCODED}"
  echo "    Убедитесь, что отдаёте именно ссылку-подписку из панели."
  exit 1
fi

echo
echo -e "\033[0;32m[✓] Готово! Отправьте клиенту эту строку:\033[0m"
echo
echo "$ENCODED"
echo
echo "Клиент: в Happ «+» -> «Вставить из буфера обмена» -> выбрать сервер -> подключиться."
