#!/usr/bin/env bash
# Installe le watchdog NetBird sur le VPS (root) :
#   sudo bash install.sh
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "À lancer en root." >&2; exit 1; }
systemctl cat netbird >/dev/null || { echo "Service netbird absent." >&2; exit 1; }

install -m 755 netbird-watchdog.sh /usr/local/sbin/netbird-watchdog.sh
install -m 644 netbird-watchdog.service netbird-watchdog.timer /etc/systemd/system/

# Si le client plante (OOM…), systemd le relance toujours, sans limite.
mkdir -p /etc/systemd/system/netbird.service.d
cat >/etc/systemd/system/netbird.service.d/restart.conf <<'CONF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=10
# Le noyau tue en dernier le client du tunnel en cas de manque de mémoire.
OOMScoreAdjust=-500
CONF

systemctl daemon-reload
systemctl enable netbird
systemctl enable --now netbird-watchdog.timer
systemctl list-timers netbird-watchdog.timer --no-pager
echo "Journal : journalctl -t netbird-watchdog -f"
