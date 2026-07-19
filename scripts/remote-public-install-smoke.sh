#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${TELLME_REMOTE_SSH_HOST:-server-public}"
RUN_ID="${TELLME_PUBLIC_SMOKE_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
PROJECT_NAME="${TELLME_PUBLIC_SMOKE_PROJECT:-tellme-public-smoke-${RUN_ID}}"
REMOTE_WORKDIR="${TELLME_PUBLIC_SMOKE_WORKDIR:-/tmp/tellme-public-install-${RUN_ID}}"
HTTP_PORT="${TELLME_PUBLIC_SMOKE_HTTP_PORT:-18080}"
HTTPS_PORT="${TELLME_PUBLIC_SMOKE_HTTPS_PORT:-18443}"
TURN_PORT="${TELLME_PUBLIC_SMOKE_TURN_PORT:-13478}"
TURN_TLS_PORT="${TELLME_PUBLIC_SMOKE_TURN_TLS_PORT:-15349}"
TURN_MIN_PORT="${TELLME_PUBLIC_SMOKE_TURN_MIN_PORT:-55000}"
TURN_MAX_PORT="${TELLME_PUBLIC_SMOKE_TURN_MAX_PORT:-55050}"

case "$REMOTE_WORKDIR" in
  /tmp/tellme-public-install-*) ;;
  *)
    echo "Refusing unsafe remote work directory: $REMOTE_WORKDIR" >&2
    exit 1
    ;;
esac

ssh "$SSH_HOST" "mkdir -p '$REMOTE_WORKDIR'"
rsync -az --delete \
  --exclude '.git/' \
  --exclude '.env' \
  --exclude '.env.production' \
  --exclude 'backend-rust/target/' \
  --exclude 'messenger/.e2e-artifacts/' \
  --exclude 'messenger/.e2e-derived-data/' \
  --exclude 'messenger/.e2e-headless/' \
  --exclude 'messenger/.e2e-user-scenarios/' \
  "$ROOT_DIR/" \
  "$SSH_HOST:$REMOTE_WORKDIR/"

ssh "$SSH_HOST" bash -s -- \
  "$REMOTE_WORKDIR" "$PROJECT_NAME" "$HTTP_PORT" "$HTTPS_PORT" \
  "$TURN_PORT" "$TURN_TLS_PORT" "$TURN_MIN_PORT" "$TURN_MAX_PORT" <<'REMOTE'
set -Eeuo pipefail

workdir="$1"
project="$2"
http_port="$3"
https_port="$4"
turn_port="$5"
turn_tls_port="$6"
turn_min_port="$7"
turn_max_port="$8"

cd "$workdir"

cleanup() {
  docker compose --env-file .env.production -p "$project" -f compose.production.yml \
    down --volumes --remove-orphans --rmi local >/dev/null 2>&1 || true
  cd /tmp
  rm -rf "$workdir"
}
trap cleanup EXIT

bash scripts/bootstrap-production-env.sh >/dev/null
sed -i \
  -e 's/chat\.example\.com/localhost/g' \
  -e 's/203\.0\.113\.10/127.0.0.1/g' \
  -e "s/^HTTP_PORT=.*/HTTP_PORT=${http_port}/" \
  -e "s/^HTTPS_PORT=.*/HTTPS_PORT=${https_port}/" \
  -e "s/^TURN_LISTENING_PORT=.*/TURN_LISTENING_PORT=${turn_port}/" \
  -e "s/^TURN_TLS_PORT=.*/TURN_TLS_PORT=${turn_tls_port}/" \
  -e "s/^TURN_MIN_PORT=.*/TURN_MIN_PORT=${turn_min_port}/" \
  -e "s/^TURN_MAX_PORT=.*/TURN_MAX_PORT=${turn_max_port}/" \
  -e "s|^STUN_SERVER=.*|STUN_SERVER=stun:localhost:${turn_port}|" \
  -e "s|^TURN_SERVER_URL_UDP=.*|TURN_SERVER_URL_UDP=turn:localhost:${turn_port}?transport=udp|" \
  -e "s|^TURN_SERVER_URL_TCP=.*|TURN_SERVER_URL_TCP=turn:localhost:${turn_port}?transport=tcp|" \
  .env.production

bash scripts/validate-production-config.sh
docker compose --env-file .env.production -p "$project" -f compose.production.yml up -d --build

ready=0
for _ in $(seq 1 90); do
  if curl -kfsS --resolve "localhost:${https_port}:127.0.0.1" \
    "https://localhost:${https_port}/ready" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "$ready" != "1" ]]; then
  docker compose --env-file .env.production -p "$project" -f compose.production.yml ps >&2
  docker compose --env-file .env.production -p "$project" -f compose.production.yml logs --no-color >&2
  exit 1
fi

health="$(curl -kfsS --resolve "localhost:${https_port}:127.0.0.1" "https://localhost:${https_port}/health")"
config="$(curl -kfsS --resolve "localhost:${https_port}:127.0.0.1" "https://localhost:${https_port}/api/config")"
case "$health" in
  *'"status":"ok"'*) ;;
  *) echo "Unexpected health response: $health" >&2; exit 1 ;;
esac
case "$config" in
  *'"server_domain":"localhost"'*'"call_signaling":"e2e_message_payload"'*) ;;
  *) echo "Unexpected public config response: $config" >&2; exit 1 ;;
esac

migration_count="$(
  docker compose --env-file .env.production -p "$project" -f compose.production.yml exec -T postgres \
    sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM schema_migrations;"'
)"
migration_count="${migration_count//[[:space:]]/}"
if [[ -z "$migration_count" || "$migration_count" -lt 16 ]]; then
  echo "Expected at least 16 migrations, got: ${migration_count:-missing}" >&2
  exit 1
fi

turn_secret="$(sed -n 's/^TURN_STATIC_SECRET=//p' .env.production)"
docker compose --env-file .env.production -p "$project" -f compose.production.yml exec -T coturn \
  turnutils_uclient -t -c -I -Y alloc -n 1 -m 1 -u healthcheck -W "$turn_secret" \
  -p "$turn_port" 127.0.0.1 >/dev/null
docker compose --env-file .env.production -p "$project" -f compose.production.yml exec -T coturn \
  turnutils_uclient -c -I -Y alloc -n 1 -m 1 -u healthcheck -W "$turn_secret" \
  -p "$turn_port" 127.0.0.1 >/dev/null

unhealthy="$(docker compose --env-file .env.production -p "$project" -f compose.production.yml ps \
  --format json | grep -Ec '"Health":"(unhealthy|starting)"|"State":"(exited|dead)"' || true)"
if [[ "$unhealthy" != "0" ]]; then
  docker compose --env-file .env.production -p "$project" -f compose.production.yml ps >&2
  exit 1
fi

docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' \
  "${project}-server-1" "${project}-postgres-1" "${project}-redis-1" \
  "${project}-minio-1" "${project}-caddy-1" "${project}-coturn-1" || true

echo "Public installation smoke passed: project=${project}, migrations=${migration_count}, TLS=local-CA, TURN=tcp+udp"
REMOTE
