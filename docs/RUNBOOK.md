# Runbook

How to debug the most common failures. General approach: **find the layer that fails** —
DNS → network/firewall → Traefik → container → application — and check each one with a command instead of guessing.

```bash
cd /opt/homelab
docker compose ps                      # is everything up and healthy?
docker compose logs --tail=100 <svc>   # what does the service say?
docker logs traefik 2>&1 | grep -i error
```

---

## Site doesn't open / certificate error

1. **DNS:** `dig +short app.<domain>` must return the server IP.
2. **Port reachable from outside:** `curl -vI http://app.<domain>` from your laptop.
   If it times out, check the AWS security group and `sudo ufw status`.
3. **Certificate:** `docker logs traefik 2>&1 | grep -i acme`
   - `Timeout during connect` → port 80 is closed or DNS points elsewhere.
     Let's Encrypt validates over HTTP on port 80.
   - `too many certificates` / `rateLimited` → switch `ACME_CA_SERVER` to staging, fix the problem, then switch back.
     Recreate the volume to drop old data: `docker compose down traefik && docker volume rm homelab_letsencrypt`.
4. Check what certificate is actually served:
   `openssl s_client -connect app.<domain>:443 -servername app.<domain> </dev/null | openssl x509 -noout -issuer -dates`

## 404 page not found (from Traefik)

The request reached Traefik, but no router matches it.

- Wrong `Host()` in the labels, or `DOMAIN` in `.env` doesn't match the hostname you typed.
- The container is missing `traefik.enable=true` or isn't running.
- Look at the Traefik dashboard → HTTP Routers.

## 502 Bad Gateway

Traefik found the router but can't reach the container.

- Wrong port in `traefik.http.services.<name>.loadbalancer.server.port`.
- The container isn't on the `proxy` network.
- The app listens on `127.0.0.1` instead of `0.0.0.0` inside the container.
- Test from inside the network: `docker run --rm --network proxy curlimages/curl -s http://app:8000/health`

## Traefik fails with "is a directory" / basic auth doesn't work

`traefik/users.htpasswd` didn't exist on first start, so Docker created an **empty directory** in its place.

```bash
docker compose stop traefik
sudo rm -rf traefik/users.htpasswd
htpasswd -nbB admin 'password' > traefik/users.htpasswd
docker compose up -d traefik
```

## wg-easy login fails / password hash is mangled

The bcrypt hash contains `$`. In `.env` it must be wrapped in **single quotes**:
`WG_PASSWORD_HASH='$2a$12$...'`. Check what the container sees:
`docker exec wg-easy printenv PASSWORD_HASH`.

## VPN connects but no traffic (no handshake)

- `sudo wg show` inside the container: `docker exec wg-easy wg show`. "latest handshake" missing → packets don't arrive.
- UDP 51820 must be open in **both** the security group and UFW.
- `WG_HOST` must be the public IP or a hostname that resolves to it.
  After changing it, regenerate the client configs.
- Check that forwarding is on: `docker exec wg-easy sysctl net.ipv4.ip_forward`.

## Prometheus target is DOWN

Open Grafana → Explore → `up`, or check from the Prometheus container:

```bash
docker exec prometheus wget -qO- http://app:8000/metrics | head
```

- `no such host` → the target isn't on the `monitoring` network.
- Config change has no effect → reload it: `docker compose kill -s SIGHUP prometheus`.
- Validate the config: `docker exec prometheus promtool check config /etc/prometheus/prometheus.yml`.

## Grafana shows "No data"

- Datasource: Connections → Data sources → Prometheus → *Save & test*.
- The time range is too short for `rate(...[5m])`. Wait 5 minutes after a fresh start.
- Run the panel query in Explore to see the raw result.

## Disk is full

```bash
df -h /
sudo du -xh / --max-depth=2 2>/dev/null | sort -h | tail -15
docker system df                     # images, containers, volumes, build cache
docker image prune -a -f             # remove unused images
sudo journalctl --vacuum-size=200M   # shrink the system journal
```

## Server is slow / container killed (OOM)

```bash
free -h
docker stats --no-stream
sudo dmesg -T | grep -i -E 'killed process|out of memory'
```

The whole stack needs ~1.5 GB. On a 1 GB instance, rely on swap or drop cAdvisor.

## A port is reachable although UFW should block it

Docker writes its own iptables rules for published ports and **bypasses UFW**. Never publish internal services with
`ports:`. Use internal networks and route through Traefik. Check what's really listening: `sudo ss -tulpn`.

## Deploy failed in GitHub Actions

- `Host key verification failed` → `SSH_KNOWN_HOSTS` is outdated (e.g. the server was recreated).
  Run `ssh-keyscan -t ed25519 <ip>` again.
- `Permission denied (publickey)` → the CI public key isn't in `/home/deploy/.ssh/authorized_keys`.
- `Connection timed out` → port 22 isn't open for GitHub runner IPs (`ssh_allowed_cidrs`).
- `denied` on image pull → the GHCR package isn't linked to the repo. Check package settings → *Manage Actions access*.
- `App did not become healthy` → `deploy.sh` already rolled back. Read the app logs it printed.
