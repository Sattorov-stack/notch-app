#!/bin/bash
# Отправить событие питомцу в чёлке.
# Использование: notch-notify.sh <агент> <событие> [сообщение]
#   события: done | permission | error | info
AGENT="${1:-ai}"
EVENT="${2:-done}"
MSG=$(printf '%s' "${3:-}" | sed 's/\\/\\\\/g; s/"/\\"/g')
curl -s -m 2 -X POST "http://127.0.0.1:47321/event" \
  -H 'Content-Type: application/json' \
  -d "{\"agent\":\"$AGENT\",\"event\":\"$EVENT\",\"message\":\"$MSG\"}" >/dev/null 2>&1 || true
