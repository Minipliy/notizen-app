#!/bin/bash
# Richtet den Notizen-Server als eigenen Systemdienst ein:
#   - eigener Benutzer "notizen" (ohne Anmeldung)
#   - Programm in /opt/notizen, Daten in /var/lib/notizen
#   - startet beim Hochfahren automatisch
# Aufruf auf dem Pi:  sudo bash install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte mit sudo starten:  sudo bash $0" >&2
    exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR=/opt/notizen
DATA_DIR=/var/lib/notizen
PORT="${PORT:-8787}"

if ! id notizen >/dev/null 2>&1; then
    useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin notizen
fi
install -d -o root -g root -m 755 "$APP_DIR"
install -o root -g root -m 644 "$DIR/notizen_server.py" "$APP_DIR/notizen_server.py"
install -d -o notizen -g notizen -m 700 "$DATA_DIR"

cat > /etc/systemd/system/notizen.service <<EOF
[Unit]
Description=Notizen-Sync-Server
After=network-online.target
Wants=network-online.target

[Service]
User=notizen
Group=notizen
ExecStart=/usr/bin/python3 $APP_DIR/notizen_server.py --port $PORT --data $DATA_DIR
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable notizen.service
systemctl restart notizen.service

IP="$(hostname -I | awk '{print $1}')"
# Firewall: Port nur für das Heimnetz öffnen
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow from "${IP%.*}.0/24" to any port "$PORT" proto tcp comment "Notizen"
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$DATA_DIR/token.txt" ] && break
    sleep 1
done

echo
if systemctl is-active --quiet notizen.service; then
    echo "Der Notizen-Server läuft."
else
    echo "Der Dienst läuft NICHT – Details:  journalctl -u notizen.service -n 30" >&2
fi
echo "Server-Adresse für die App:  http://$IP:$PORT"
echo "Token für die App:           $(cat "$DATA_DIR/token.txt")"
