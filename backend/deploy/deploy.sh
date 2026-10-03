#!/usr/bin/env bash
# Deploys the Kármán API to a Linux server in isolation:
#   - dedicated system user `karman`, everything under /opt/karman
#   - systemd unit `karman.service`, listening on its own port with its own TLS cert
#   - does not touch nginx or any existing service
#
# Usage: backend/deploy/deploy.sh root@HOST [ssh-key] [port]
set -euo pipefail

TARGET="${1:?usage: deploy.sh user@host [ssh-key] [port]}"
KEY="${2:-$HOME/.ssh/id_ed25519}"
PORT="${3:-8443}"
HOST="${TARGET#*@}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$(cd "$HERE/.." && pwd)"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET")
SCP=(scp -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15)

echo "==> Inspecting $HOST"
ARCH=$("${SSH[@]}" 'uname -m')
case "$ARCH" in
  x86_64|amd64) GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) echo "unsupported arch $ARCH"; exit 1 ;;
esac
if "${SSH[@]}" "ss -ltn 2>/dev/null | awk '{print \$4}' | grep -qE '[:.]$PORT\$'"; then
  if ! "${SSH[@]}" "systemctl is-active --quiet karman 2>/dev/null"; then
    echo "port $PORT is already used by another service; pass a different port"; exit 1
  fi
fi

echo "==> Building linux/$GOARCH binary"
mkdir -p "$BACKEND/dist"
(cd "$BACKEND" && CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH go build -trimpath -ldflags "-s -w" -o dist/karman ./cmd/karman)

echo "==> Uploading"
"${SSH[@]}" 'mkdir -p /opt/karman/bin /opt/karman/data /opt/karman/tls'
"${SCP[@]}" "$BACKEND/dist/karman" "$TARGET:/opt/karman/bin/karman.new"
# The product website (landing page, privacy and support pages) served at / by the API.
SITE="$(cd "$BACKEND/../marketing/site" 2>/dev/null && pwd || true)"
if [ -n "$SITE" ] && [ -f "$SITE/index.html" ]; then
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$SITE" -czf - . | "${SSH[@]}" 'rm -rf /opt/karman/site.new && mkdir -p /opt/karman/site.new && tar --warning=no-unknown-keyword -xzf - -C /opt/karman/site.new'
fi
# Use the certificate whose pin is compiled into the app, if it was generated locally.
if [ -f "$HERE/certs/tls.crt" ] && [ -f "$HERE/certs/tls.key" ]; then
  "${SSH[@]}" 'test -f /opt/karman/tls/tls.crt' || "${SCP[@]}" "$HERE/certs/tls.crt" "$HERE/certs/tls.key" "$HERE/certs/pin.txt" "$TARGET:/opt/karman/tls/"
fi

echo "==> Installing service"
"${SSH[@]}" PORT="$PORT" HOST="$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
id karman >/dev/null 2>&1 || useradd --system --home /opt/karman --shell /usr/sbin/nologin karman
mv /opt/karman/bin/karman.new /opt/karman/bin/karman
chmod 755 /opt/karman/bin/karman
if [ -d /opt/karman/site.new ]; then rm -rf /opt/karman/site && mv /opt/karman/site.new /opt/karman/site; fi
if [ ! -f /opt/karman/tls/tls.crt ]; then
  /opt/karman/bin/karman gencert -host "$HOST" -out /opt/karman/tls | tee /opt/karman/tls/pin.txt
fi
if [ ! -f /opt/karman/karman.env ]; then
  cat > /opt/karman/karman.env <<ENV
KARMAN_ADDR=:$PORT
KARMAN_DATA_DIR=/opt/karman/data
KARMAN_TLS_CERT=/opt/karman/tls/tls.crt
KARMAN_TLS_KEY=/opt/karman/tls/tls.key
KARMAN_BUNDLE_ID=com.adilemre.karman
KARMAN_ALLOW_SANDBOX=true
KARMAN_AI_MODEL=claude-opus-5-5
KARMAN_ASK_DAILY_LIMIT=25
KARMAN_PREWARM_LANGS=en,tr
# Fill these in, then: systemctl restart karman
ANTHROPIC_API_KEY=
NASA_API_KEY=DEMO_KEY
APNS_KEY_PATH=
APNS_KEY_ID=
APNS_TEAM_ID=
KARMAN_APPLE_APP_ID=
# Optional: shown on /support
KARMAN_SUPPORT_EMAIL=
KARMAN_SITE_DIR=/opt/karman/site
ENV
fi
grep -q '^KARMAN_SITE_DIR=' /opt/karman/karman.env || echo 'KARMAN_SITE_DIR=/opt/karman/site' >> /opt/karman/karman.env
chown -R karman:karman /opt/karman
chmod 600 /opt/karman/karman.env /opt/karman/tls/tls.key
cat > /etc/systemd/system/karman.service <<UNIT
[Unit]
Description=Karman API (live Earth data, briefings, alerts)
After=network-online.target
Wants=network-online.target

[Service]
User=karman
Group=karman
EnvironmentFile=/opt/karman/karman.env
ExecStart=/opt/karman/bin/karman
Restart=always
RestartSec=3
AmbientCapabilities=
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/karman/data
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LimitNOFILE=65536
MemoryMax=600M

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable karman >/dev/null 2>&1
systemctl restart karman
# Open the port only if a host firewall is active (no other rules are changed).
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "$PORT"/tcp comment 'karman api' >/dev/null
fi
sleep 2
systemctl --no-pager --lines=5 status karman | head -12
REMOTE

echo "==> Health check"
sleep 3
curl -sk --max-time 10 "https://$HOST:$PORT/healthz" | head -c 300 && echo
echo "==> TLS pin (put into project.yml KARMAN_API_PIN):"
"${SSH[@]}" 'grep "SPKI" /opt/karman/tls/pin.txt'
