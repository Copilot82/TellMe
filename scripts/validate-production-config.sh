#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_PATH="${TELLME_PRODUCTION_ENV_PATH:-$ROOT_DIR/.env.production}"
COMPOSE_PATH="$ROOT_DIR/compose.production.yml"

if [[ ! -f "$ENV_PATH" ]]; then
  echo "Production environment file not found: $ENV_PATH" >&2
  exit 1
fi

if grep -Eq '(^|=)(CHANGE_ME|chat\.example\.com|203\.0\.113\.10)' "$ENV_PATH"; then
  echo "Production environment still contains template values." >&2
  exit 1
fi

required_names=(
  SERVER_DOMAIN TURN_EXTERNAL_IP TURN_PRIVATE_IP POSTGRES_DB POSTGRES_USER
  POSTGRES_PASSWORD REDIS_PASSWORD JWT_SECRET JWT_REFRESH_SECRET MINIO_ACCESS_KEY
  MINIO_SECRET_KEY SERVER_SIGN_PRIVATE_KEY TURN_STATIC_SECRET TURN_SERVER_URL_UDP
  TURN_SERVER_URL_TCP
)

for variable_name in "${required_names[@]}"; do
  if ! grep -Eq "^${variable_name}=.+$" "$ENV_PATH"; then
    echo "Required variable is empty or missing: ${variable_name}" >&2
    exit 1
  fi
done

if grep -Eq '^APNS_ENABLED=true$' "$ENV_PATH"; then
  for variable_name in APNS_BUNDLE_ID APNS_KEY_ID APNS_TEAM_ID APNS_PRIVATE_KEY_PATH; do
    if ! grep -Eq "^${variable_name}=.+$" "$ENV_PATH"; then
      echo "APNs is enabled but ${variable_name} is empty or missing." >&2
      exit 1
    fi
  done

  apns_key_path="$ROOT_DIR/secrets/apns/AuthKey.p8"
  if ! grep -Eq '^APNS_PRIVATE_KEY_BASE64=.+$' "$ENV_PATH" && [[ ! -s "$apns_key_path" ]]; then
    echo "APNs is enabled but neither APNS_PRIVATE_KEY_BASE64 nor $apns_key_path is available." >&2
    exit 1
  fi
fi

docker compose --env-file "$ENV_PATH" -f "$COMPOSE_PATH" config --quiet
echo "Production configuration is structurally valid."
