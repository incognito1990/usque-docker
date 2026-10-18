#!/usr/bin/env bash
# Готовит ОДНОРАЗОВЫЙ тестовый конфиг: настоящий ключ P-256, но endpoint
# указывает на 127.0.0.1. Наружу ничего не уходит и ничего не регистрируется.
#   tests/make-test-config.sh /tmp/usque-test-config
set -euo pipefail
DIR="${1:?укажите каталог, например /tmp/usque-test-config}"
mkdir -p "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/ec.key"
openssl ec -in "$TMP/ec.key" -pubout -out "$TMP/ec.pub" 2>/dev/null
PRIV="$(openssl ec -in "$TMP/ec.key" -outform DER 2>/dev/null | base64 -w0)"

jq -n --arg pk "$PRIV" --arg pub "$(cat "$TMP/ec.pub")" '{
  private_key: $pk,
  endpoint_v4: "127.0.0.1", endpoint_v6: "::1",
  endpoint_h2_v4: "127.0.0.1", endpoint_h2_v6: "::1",
  endpoint_pub_key: $pub,
  id: "00000000-0000-0000-0000-000000000000",
  access_token: "00000000-0000-0000-0000-000000000000",
  ipv4: "172.16.0.2", ipv6: "2606:4700:100::1"
}' > "$DIR/config.json"

echo "тестовый конфиг: $DIR/config.json (endpoint 127.0.0.1 — трафика наружу нет)"
