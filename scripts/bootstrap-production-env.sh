#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_PATH="$ROOT_DIR/.env.production.example"
ENV_PATH="$ROOT_DIR/.env.production"

if [[ -e "$ENV_PATH" ]]; then
  echo "Refusing to overwrite existing $ENV_PATH" >&2
  exit 1
fi

for command_name in openssl sed mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 1
  fi
done

temporary_path="$(mktemp "${TMPDIR:-/tmp}/tellme-production-env.XXXXXX")"
cleanup() {
  rm -f "$temporary_path"
}
trap cleanup EXIT

cp "$TEMPLATE_PATH" "$temporary_path"
chmod 600 "$temporary_path"

replace_literal() {
  local placeholder="$1"
  local value="$2"
  sed -i.bak "s|${placeholder}|${value}|g" "$temporary_path"
  rm -f "${temporary_path}.bak"
}

replace_literal CHANGE_ME_POSTGRES "$(openssl rand -hex 32)"
replace_literal CHANGE_ME_REDIS "$(openssl rand -hex 32)"
replace_literal CHANGE_ME_JWT "$(openssl rand -hex 48)"
replace_literal CHANGE_ME_REFRESH "$(openssl rand -hex 48)"
replace_literal CHANGE_ME_MINIO "$(openssl rand -hex 32)"
replace_literal CHANGE_ME_ED25519_SEED "$(openssl rand -base64 32 | tr -d '\n')"
replace_literal CHANGE_ME_TURN "$(openssl rand -hex 32)"

mv "$temporary_path" "$ENV_PATH"
trap - EXIT
chmod 600 "$ENV_PATH"

echo "Created $ENV_PATH with generated secrets."
echo "Edit SERVER_DOMAIN, TURN IP addresses and APNs values before deployment."
