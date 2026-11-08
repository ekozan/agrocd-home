#!/usr/bin/env bash
# Watchdog du tunnel NetBird du VPS (lancé chaque minute par netbird-watchdog.timer).
#
# Test : une vraie requête à travers le tunnel (Rancher maison, /ping). Après
# FAILS_MAX échecs consécutifs, `systemctl restart netbird`, au plus une fois
# par COOLDOWN secondes (si la panne est côté maison, redémarrer en boucle ne
# servirait à rien). Journal : journalctl -t netbird-watchdog
set -uo pipefail

TARGET=${NB_WATCHDOG_URL:-https://rancher2.server/ping}
FAILS_MAX=${NB_WATCHDOG_FAILS:-3}
COOLDOWN=${NB_WATCHDOG_COOLDOWN:-600}
STATE=/run/netbird-watchdog
mkdir -p "$STATE"

say() { logger -t netbird-watchdog "$*"; }

status=$(timeout 15 netbird status 2>&1)
summary=$(grep -E '^(Management|Signal|Relays|Peers count):' <<<"$status" | tr '\n' ' ')

ok=1
if [ -n "$TARGET" ]; then
  code=$(curl -sk --max-time 8 -o /dev/null -w '%{http_code}' "$TARGET" || true)
  [[ $code == 2* ]] || ok=0
else
  grep -q '^Management: Connected' <<<"$status" || ok=0
  grep -q '^Signal: Connected' <<<"$status" || ok=0
fi

if [ "$ok" = 1 ]; then
  [ -s "$STATE/fails" ] && say "tunnel rétabli ($summary)"
  rm -f "$STATE/fails"
  exit 0
fi

fails=$(( $(cat "$STATE/fails" 2>/dev/null || echo 0) + 1 ))
echo "$fails" >"$STATE/fails"
say "échec $fails/$FAILS_MAX : $TARGET → HTTP ${code:-?} ; $summary"
[ "$fails" -ge "$FAILS_MAX" ] || exit 0

now=$(date +%s)
last=$(cat "$STATE/last-restart" 2>/dev/null || echo 0)
if [ $(( now - last )) -lt "$COOLDOWN" ]; then
  say "redémarrage déjà fait il y a $(( now - last )) s : on attend (panne côté maison ?)"
  exit 0
fi

say "redémarrage du client NetBird"
echo "$now" >"$STATE/last-restart"
echo 0 >"$STATE/fails"
systemctl restart netbird
