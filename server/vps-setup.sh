#!/bin/bash
# FÜR FORTGESCHRITTENE: Macht deinen Notizen-Server über eine eigene Domain mit HTTPS erreichbar.
# Voraussetzungen: ein gemieteter Server (VPS) mit Caddy, eine Domain, die auf diesen Server zeigt,
# und eine VPN-Verbindung (z. B. WireGuard) vom VPS zu deinem Raspberry Pi.
# Für die meisten ist Tailscale einfacher – siehe ANLEITUNG.md.
#
#   - Caddy leitet https://DOMAIN/api/* an den Pi weiter und holt das HTTPS-Zertifikat selbst.
#   - Unter /review läuft eine getrennte Demo-Instanz (z. B. für die App-Prüfung von Apple).
#   - Optional: Website aus SITE_DIR wird unter https://DOMAIN/ ausgeliefert.
#
# Aufruf auf dem VPS (als root):
#   DOMAIN=notizen.example.com PI=10.0.0.2:8787 bash vps-setup.sh
set -euo pipefail

: "${DOMAIN:?Bitte DOMAIN setzen, z. B. DOMAIN=notizen.example.com}"
: "${PI:?Bitte PI setzen (VPN-Adresse:Port des Pi), z. B. PI=10.0.0.2:8787}"
REVIEW_PORT=8792
SITE=/etc/caddy/sites/notizen.caddy
DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Bitte als root starten." >&2; exit 1; }

# --- Demo-Instanz für App Review -------------------------------------------
if ss -ltn | grep -q ":$REVIEW_PORT " && ! systemctl is-active --quiet notizen-review.service; then
    echo "Port $REVIEW_PORT ist schon belegt – bitte REVIEW_PORT im Skript ändern." >&2
    exit 1
fi
id notizen-review >/dev/null 2>&1 || \
    useradd --system --home-dir /var/lib/notizen-review --shell /usr/sbin/nologin notizen-review
install -d -m 755 /opt/notizen-review
install -m 644 "$DIR/notizen_server.py" /opt/notizen-review/notizen_server.py
install -d -o notizen-review -g notizen-review -m 700 /var/lib/notizen-review

cat > /etc/systemd/system/notizen-review.service <<EOF
[Unit]
Description=Notizen-Sync-Server (nur App Review, Demodaten)
After=network-online.target

[Service]
User=notizen-review
Group=notizen-review
ExecStart=/usr/bin/python3 /opt/notizen-review/notizen_server.py --host 127.0.0.1 --port $REVIEW_PORT --data /var/lib/notizen-review
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/notizen-review

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable notizen-review.service
systemctl restart notizen-review.service
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s /var/lib/notizen-review/token.txt ] && curl -s -o /dev/null "http://127.0.0.1:$REVIEW_PORT/api/ping" && break
    sleep 1
done
REVIEW_TOKEN="$(cat /var/lib/notizen-review/token.txt)"

# Beispielnotizen anlegen (nur beim ersten Mal, feste IDs)
NOW=$(python3 -c "import time; print(int(time.time()*1000))")
curl -s -o /dev/null -H "Authorization: Bearer $REVIEW_TOKEN" --data-binary @- \
    "http://127.0.0.1:$REVIEW_PORT/api/sync" <<EOF
{"since":0,
 "folders":[{"id":"demo-f1","name":"Privat","modifiedAt":1},
            {"id":"demo-f2","name":"Arbeit","modifiedAt":1}],
 "notes":[{"id":"demo-1","pinned":true,"modifiedAt":1,"createdAt":1,
           "text":"Willkommen bei Notizen\nDiese Notizen liegen auf einem eigenen Server und werden zwischen iPhone, iPad und Mac abgeglichen."},
          {"id":"demo-2","folderId":"demo-f1","modifiedAt":2,"createdAt":2,
           "text":"Einkaufsliste\nMilch\nBrot\nKaffee"},
          {"id":"demo-3","folderId":"demo-f2","modifiedAt":3,"createdAt":3,
           "text":"Besprechung Montag\nProjektstand, Termine, offene Fragen"}]}
EOF

# --- Webseiten --------------------------------------------------------------
SITE_DIR="${SITE_DIR:-$DIR/site}"
if [ -d "$SITE_DIR" ]; then
    rm -rf /srv/notizen-site
    cp -r "$SITE_DIR" /srv/notizen-site
    chmod -R a+rX /srv/notizen-site
fi

# --- Caddy ------------------------------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S)
cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-notizen-$STAMP"
[ -f "$SITE" ] && cp -a "$SITE" "$SITE.before-$STAMP"

cat > "$SITE" <<EOF
# Notizen-Sync: per VPN zum Raspberry Pi weitergeleitet.
# Auf dem VPS wird nichts gespeichert – außer der Demo-Instanz unter /review.
$DOMAIN {
    header {
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer
        Strict-Transport-Security "max-age=31536000"
        -Server
    }
    request_body {
        max_size 500MB
    }

    # Nur für die App-Prüfung von Apple: getrennte Instanz mit Demodaten.
    handle_path /review/* {
        reverse_proxy 127.0.0.1:$REVIEW_PORT
    }

    @api path /api/*
    handle @api {
        reverse_proxy $PI {
            transport http {
                dial_timeout 5s
            }
        }
    }

    # Produktseite, Support und Datenschutz (für den App Store)
    handle {
        encode zstd gzip
        root * /srv/notizen-site
        try_files {path} {path}/index.html
        file_server
    }
}
EOF

grep -q "^import /etc/caddy/sites/notizen.caddy" /etc/caddy/Caddyfile || \
    sed -i "1a import /etc/caddy/sites/notizen.caddy" /etc/caddy/Caddyfile

if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/tmp/caddy-validate.log 2>&1; then
    echo "Caddy-Konfiguration ungültig – stelle den alten Stand wieder her." >&2
    cat /tmp/caddy-validate.log >&2
    cp -a "/etc/caddy/Caddyfile.before-notizen-$STAMP" /etc/caddy/Caddyfile
    rm -f "$SITE"
    [ -f "$SITE.before-$STAMP" ] && cp -a "$SITE.before-$STAMP" "$SITE"
    exit 1
fi
systemctl reload caddy

echo
echo "Fertig."
if [ -z "$(dig +short A "$DOMAIN" 2>/dev/null || getent hosts "$DOMAIN")" ]; then
    echo "ACHTUNG: Für $DOMAIN gibt es noch keinen DNS-Eintrag."
    echo "         Lege beim Domain-Anbieter einen A-Eintrag  notizen -> $(curl -s -4 https://ifconfig.me || echo 'IP des VPS')  an."
    echo "         Caddy holt das Zertifikat dann von selbst."
fi
echo
echo "Adresse für die App (überall):   https://$DOMAIN"
echo "Demo-Zugang für Apple:           https://$DOMAIN/review"
echo "Demo-Token für Apple:            $REVIEW_TOKEN"
echo "Datenschutz / Support:           https://$DOMAIN/datenschutz/  ·  https://$DOMAIN/support/"
