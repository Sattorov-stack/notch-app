#!/bin/bash
# Запустить ОДИН раз. Создаёт постоянный сертификат подписи «NotchApp Local Signing»
# в связке ключей «Вход». После этого разрешения macOS (Универсальный доступ,
# Автоматизация, Запись экрана) не слетают при каждой пересборке приложения.
# Сертификат действует только на этом Mac и подписывает только твои сборки.
set -e
NAME="NotchApp Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "Сертификат «${NAME}» уже есть. Дальше: ./build_app.sh"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

PASS=$(uuidgen)
LEGACY=""
/usr/bin/openssl version | grep -q "^OpenSSL 3" && LEGACY="-legacy"
/usr/bin/openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout pass:"$PASS"

security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign

echo
echo "✓ Сертификат «${NAME}» создан."
echo "  Теперь собери приложение: ./build_app.sh"
echo "  Если macOS спросит доступ к ключу для codesign — введи пароль и нажми «Разрешать всегда»."
