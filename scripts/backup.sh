#!/usr/bin/env bash
# Back up the stateful Docker volumes and the .env file.
#
# Usage:  sudo bash /opt/homelab/scripts/backup.sh
# Cron:   0 3 * * * root /opt/homelab/scripts/backup.sh >> /var/log/homelab-backup.log 2>&1
#
# Prometheus data is skipped on purpose: metrics are easy to lose and large.
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/homelab}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/homelab}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
PROJECT="homelab"
VOLUMES=(letsencrypt wg-data uptime-kuma-data grafana-data)
# Services using SQLite are stopped briefly so the copy is consistent.
STOP_SERVICES=(uptime-kuma grafana)

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="${BACKUP_DIR}/${timestamp}"
mkdir -p "$target"
chmod 700 "$BACKUP_DIR"

cd "$STACK_DIR"

restart_services() { docker compose start "${STOP_SERVICES[@]}" >/dev/null; }
trap restart_services EXIT

echo "==> Stopping ${STOP_SERVICES[*]} for a consistent snapshot"
docker compose stop "${STOP_SERVICES[@]}" >/dev/null

for vol in "${VOLUMES[@]}"; do
  echo "==> Backing up volume ${PROJECT}_${vol}"
  docker run --rm \
    -v "${PROJECT}_${vol}:/data:ro" \
    -v "${target}:/backup" \
    alpine:3 tar czf "/backup/${vol}.tar.gz" -C /data .
done

cp .env "${target}/env.backup"
chmod 600 "${target}/env.backup"

restart_services
trap - EXIT

echo "==> Removing backups older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} +

du -sh "$target"
echo "==> Backup written to ${target}"
# Next step: copy ${target} off the server (e.g. aws s3 sync). A backup on the
# same disk does not survive losing the server.
