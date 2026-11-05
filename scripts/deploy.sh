#!/usr/bin/env bash
# Deploy a new app image and roll back automatically if it doesn't become healthy.
#
# Usage (on the server):  bash /opt/homelab/scripts/deploy.sh ghcr.io/<user>/homelab-app:sha-abc1234
# Called by GitHub Actions over SSH, but works the same when run by hand.
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/homelab}"
NEW_IMAGE="${1:?usage: deploy.sh <app-image>}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"

cd "$STACK_DIR"

# Pre-flight checks: these files are not in git and must be created once by hand.
if [[ ! -f .env ]]; then
  echo "ERROR: ${STACK_DIR}/.env not found. Copy .env.example to .env and fill it in." >&2
  exit 1
fi
if [[ ! -f traefik/users.htpasswd ]]; then
  # If the file is missing, Docker would silently create a *directory* in its place.
  echo "ERROR: traefik/users.htpasswd not found. Create it with: htpasswd -nbB admin 'password' > traefik/users.htpasswd" >&2
  exit 1
fi

current_image="$(grep -E '^APP_IMAGE=' .env | cut -d= -f2- || true)"

set_image() {
  if grep -qE '^APP_IMAGE=' .env; then
    sed -i "s|^APP_IMAGE=.*|APP_IMAGE=$1|" .env
  else
    echo "APP_IMAGE=$1" >> .env
  fi
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) status
  while ((SECONDS < deadline)); do
    status="$(docker inspect --format '{{.State.Health.Status}}' app 2>/dev/null || echo missing)"
    [[ "$status" == "healthy" ]] && return 0
    sleep 3
  done
  return 1
}

echo "==> Deploying ${NEW_IMAGE} (previous: ${current_image:-none})"
set_image "$NEW_IMAGE"

docker compose config --quiet
docker compose pull --quiet
docker compose up -d --remove-orphans

# Bind-mounted config files don't trigger a container restart, so ask
# Prometheus to re-read its config explicitly.
docker compose kill -s SIGHUP prometheus >/dev/null 2>&1 || true

if wait_healthy; then
  echo "==> App is healthy"
  docker image prune -f >/dev/null
  docker compose ps
else
  echo "==> App did not become healthy within ${HEALTH_TIMEOUT}s, rolling back" >&2
  docker compose logs --tail=50 app >&2 || true
  if [[ -n "$current_image" && "$current_image" != "$NEW_IMAGE" ]]; then
    set_image "$current_image"
    docker compose up -d app
    echo "==> Rolled back to ${current_image}" >&2
  fi
  exit 1
fi
