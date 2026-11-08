#!/usr/bin/env bash
# Retour arrière d'une migration faite par 03-migrate-pvc.sh : le PVC
# <namespace>/<pvc> est recréé (même nom) sur son ancien PV Longhorn.
#
#   sudo bash 04-rollback-pvc.sh <namespace> <pvc> [--yes]
#
# ⚠️ Les écritures faites depuis la migration restent sur le PV local-path
# (conservé, reclaimPolicy Retain) mais ne sont PAS recopiées sur Longhorn.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

[ $# -ge 2 ] || die "usage : $0 <namespace> <pvc> [--yes]"
NS=$1 PVC=$2
[ "${3:-}" = --yes ] && YES=1
STATE="$WORKDIR/${NS}_${PVC}"

preflight
[ -s "$STATE/orig-pvc.json" ] && [ -s "$STATE/old-pv" ] || die "Pas d'état de migration dans $STATE."
OLD_PV=$(cat "$STATE/old-pv")
ORIG_SC=$(jq -r '.spec.storageClassName' "$STATE/orig-pvc.json")
$K get pv "$OLD_PV" >/dev/null || die "Ancien PV $OLD_PV introuvable : retour impossible (restaurer data.tar.gz)."
CUR_PV=$($K -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
[ "$CUR_PV" = "$OLD_PV" ] && die "$NS/$PVC est déjà sur $OLD_PV."

OWNERS="$STATE/rollback-owners.txt"
if $K -n "$NS" get pvc "$PVC" >/dev/null 2>&1; then
  record_owners "$NS" "$PVC" "$OWNERS"
else
  # Bascule interrompue : PVC absent, applis déjà arrêtées par 03.
  [ -s "$STATE/owners.txt" ] && cp "$STATE/owners.txt" "$OWNERS"
fi

cat <<EOF

PVC       : $NS/$PVC
Actuel    : ${CUR_PV:-<absent>}  (conservé)
Retour sur: $OLD_PV ($ORIG_SC)
Applications arrêtées puis relancées :
$(sed 's/^/   /' "$OWNERS" 2>/dev/null)
EOF
confirm "Revenir sur le volume Longhorn d'origine ?"

log "Arrêt des applications"
[ -s "$OWNERS" ] && scale_down "$NS" "$OWNERS"
wait_no_pods "$NS" "$PVC"

log "Bascule vers $OLD_PV"
[ -n "$CUR_PV" ] && pv_retain "$CUR_PV"
if $K -n "$NS" get pvc "$PVC" >/dev/null 2>&1; then
  $K -n "$NS" delete pvc "$PVC" --wait=false >/dev/null
  wait_pvc_gone "$NS" "$PVC"
fi
pv_unclaim "$OLD_PV"
recreate_pvc "$STATE/orig-pvc.json" "$OLD_PV" "$ORIG_SC" >/dev/null
wait_pvc_bound "$NS" "$PVC"

log "Redémarrage des applications"
scale_up "$NS" "$OWNERS"
psa_restore "$NS" "$STATE"

mv "$STATE" "$STATE.rollback-$(date +%Y%m%d-%H%M%S)"
$K -n "$NS" get pvc "$PVC" -o wide
echo
echo "✅ $NS/$PVC est revenu sur $OLD_PV. PV local-path conservé : ${CUR_PV:-aucun} (à supprimer à la main si inutile)."
