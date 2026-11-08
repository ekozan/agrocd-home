#!/usr/bin/env bash
# Migre UN PVC Longhorn vers local-path en gardant le MÊME NOM de PVC :
# aucun Deployment / StatefulSet / chart à modifier.
#
#   sudo bash 03-migrate-pvc.sh <namespace> <pvc> [--yes]
#
# Étapes :
#   1. PV Longhorn d'origine passé en Retain (il ne sera jamais supprimé ici)
#   2. Arrêt des Deployments/StatefulSets qui montent le PVC (replicas notés)
#   3. Pod de copie (root) : archive data.tar.gz dans /root/vps-migration/<ns>_<pvc>/,
#      copie vers un PVC local-path temporaire, vérification (nb de fichiers + md5)
#   4. Bascule : le PVC d'origine est recréé, même nom, lié au nouveau PV local-path
#   5. Redémarrage des applications
#
# Échec avant l'étape 4 : rien n'a changé, les applis sont relancées sur Longhorn.
# Retour arrière après l'étape 4 : 04-rollback-pvc.sh <namespace> <pvc>.
#
# Variables : TARGET_SC (local-path), COPY_IMAGE, COPY_TIMEOUT (secondes, 3600),
#             VERIFY=0 pour sauter le md5 (gros volumes), WORKDIR (/root/vps-migration).
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

[ $# -ge 2 ] || die "usage : $0 <namespace> <pvc> [--yes]"
NS=$1 PVC=$2
[ "${3:-}" = --yes ] && YES=1
TARGET_SC=${TARGET_SC:-local-path}
COPY_IMAGE=${COPY_IMAGE:-debian:bookworm-slim}
COPY_TIMEOUT=${COPY_TIMEOUT:-3600}
VERIFY=${VERIFY:-1}
STATE="$WORKDIR/${NS}_${PVC}"
TMP_PVC="${PVC}-mig"
POD="pvc-mig-$(echo "$PVC" | cut -c1-40 | sed 's/[-.]*$//')"

preflight
$K get sc "$TARGET_SC" >/dev/null 2>&1 || die "StorageClass $TARGET_SC absente."
[ -e "$STATE/swapped" ] && die "$NS/$PVC déjà migré (état : $STATE). Retour arrière : 04-rollback-pvc.sh $NS $PVC"

PVC_JSON=$($K -n "$NS" get pvc "$PVC" -o json) || die "PVC $NS/$PVC introuvable."
SC=$(jq -r '.spec.storageClassName // ""' <<<"$PVC_JSON")
OLD_PV=$(jq -r '.spec.volumeName // ""' <<<"$PVC_JSON")
SIZE=$(jq -r '.status.capacity.storage // .spec.resources.requests.storage' <<<"$PVC_JSON")
[ "$SC" = "$TARGET_SC" ] && die "$NS/$PVC est déjà en $TARGET_SC."
[ "$(jq -r .status.phase <<<"$PVC_JSON")" = Bound ] || die "$NS/$PVC n'est pas Bound."
jq -e '.spec.accessModes | index("ReadWriteMany")' <<<"$PVC_JSON" >/dev/null \
  && die "$NS/$PVC est en ReadWriteMany : local-path ne le gère pas."
[ "$(jq -r '.spec.volumeMode // "Filesystem"' <<<"$PVC_JSON")" = Block ] \
  && die "$NS/$PVC est en volumeMode Block : non géré."

mkdir -p "$STATE"
chmod 700 "$STATE"
OWNERS="$STATE/owners.txt"
record_owners "$NS" "$PVC" "$OWNERS"

LH_ACTUAL=$($K -n longhorn-system get volumes.longhorn.io "$OLD_PV" -o jsonpath='{.status.actualSize}' 2>/dev/null || echo "?")
cat <<EOF

PVC        : $NS/$PVC  ($SC, $SIZE)  → $TARGET_SC
PV d'origine (conservé) : $OLD_PV   (Longhorn actualSize : $LH_ACTUAL octets)
Applications arrêtées pendant la copie :
$(sed 's/^/   /' "$OWNERS")
Archive    : $STATE/data.tar.gz
Espace libre :
$(df -h "$WORKDIR" /var/lib/rancher 2>/dev/null | sort -u | sed 's/^/   /')
Il faut environ 2× la taille utilisée (copie + archive).
EOF
confirm "Lancer la migration ?"

STAGE=pre-swap
on_exit() {
  local rc=$?
  [ $rc -eq 0 ] && return
  if [ "$STAGE" = pre-swap ]; then
    warn "Échec AVANT la bascule : nettoyage et redémarrage sur le volume d'origine."
    $K -n "$NS" logs "$POD" >"$STATE/copy.log" 2>&1 || true
    $K -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    $K -n "$NS" delete pvc "$TMP_PVC" --ignore-not-found >/dev/null 2>&1 || true
    scale_up "$NS" "$OWNERS" && rm -f "$OWNERS"
    psa_restore "$NS" "$STATE"
    warn "Rien n'a changé pour $NS/$PVC. Logs : $STATE/copy.log"
  else
    warn "Échec PENDANT la bascule (étape : $STAGE). Applis arrêtées, rien n'est perdu :"
    warn "  PVC d'origine : $STATE/orig-pvc.json  PV Longhorn : $OLD_PV  PV local-path : $(cat "$STATE/new-pv" 2>/dev/null)"
    warn "  Corriger puis : 04-rollback-pvc.sh $NS $PVC (retour Longhorn)."
  fi
}
trap on_exit EXIT

log "1/5 PV d'origine en Retain"
$K get pv "$OLD_PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' >"$STATE/old-pv-policy"
echo "$OLD_PV" >"$STATE/old-pv"
printf '%s\n' "$PVC_JSON" >"$STATE/orig-pvc.json"
pv_retain "$OLD_PV"

log "2/5 Arrêt des applications"
scale_down "$NS" "$OWNERS"
wait_no_pods "$NS" "$PVC"

log "3/5 Copie vers un PVC $TARGET_SC temporaire"
psa_relax "$NS" "$STATE"
$K -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null
if $K -n "$NS" get pvc "$TMP_PVC" >/dev/null 2>&1; then
  [ "$($K -n "$NS" get pvc "$TMP_PVC" -o jsonpath='{.metadata.labels.vps-migration}')" = tmp ] \
    || die "Un PVC $NS/$TMP_PVC existe déjà et n'a pas été créé par ce script."
  $K -n "$NS" delete pvc "$TMP_PVC" --wait=true >/dev/null
fi
rm -f "$STATE/data.tar.gz" "$STATE/src.md5" "$STATE/verify.log"

$K apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $TMP_PVC
  namespace: $NS
  labels: {vps-migration: tmp}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $TARGET_SC
  resources: {requests: {storage: $SIZE}}
---
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
  labels: {vps-migration: copy}
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 0, runAsGroup: 0}
  containers:
    - name: copy
      image: $COPY_IMAGE
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -euo pipefail
          echo "[1/3] archive -> data.tar.gz"
          tar --numeric-owner --xattrs --acls -czf /backup/data.tar.gz -C /src .
          echo "[2/3] copie"
          cp -a /src/. /dst/
          echo "[3/3] vérification"
          s=\$(find /src | wc -l); d=\$(find /dst | wc -l)
          echo "entrées : src=\$s dst=\$d"
          echo "KiB     : src=\$(du -sk /src | cut -f1) dst=\$(du -sk /dst | cut -f1)"
          [ "\$s" = "\$d" ] || { echo "ÉCART du nombre de fichiers"; exit 1; }
          if [ "$VERIFY" = 1 ]; then
            (cd /src && find . -type f -print0 | xargs -0 -r md5sum > /backup/src.md5)
            (cd /dst && md5sum -c --quiet /backup/src.md5 > /backup/verify.log 2>&1) \
              || { echo "ÉCART md5 :"; head -20 /backup/verify.log; exit 1; }
            echo "md5 OK (\$(wc -l < /backup/src.md5) fichiers)"
          fi
          echo COPY-OK
      volumeMounts:
        - {name: src, mountPath: /src, readOnly: true}
        - {name: dst, mountPath: /dst}
        - {name: backup, mountPath: /backup}
  volumes:
    - name: src
      persistentVolumeClaim: {claimName: $PVC, readOnly: true}
    - name: dst
      persistentVolumeClaim: {claimName: $TMP_PVC}
    - name: backup
      hostPath: {path: $STATE, type: DirectoryOrCreate}
EOF

deadline=$(( $(date +%s) + COPY_TIMEOUT ))
while :; do
  phase=$($K -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
  case $phase in
    Succeeded) break ;;
    Failed) $K -n "$NS" logs "$POD" || true; die "La copie a échoué." ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || { $K -n "$NS" describe pod "$POD" | tail -20; die "Délai de copie dépassé (COPY_TIMEOUT=$COPY_TIMEOUT)."; }
  printf '   %s… (%s)\r' "$phase" "$(du -sh "$STATE/data.tar.gz" 2>/dev/null | cut -f1)"
  sleep 5
done
$K -n "$NS" logs "$POD" | tee "$STATE/copy.log"
grep -q COPY-OK "$STATE/copy.log" || die "Copie non confirmée."

NEW_PV=$($K -n "$NS" get pvc "$TMP_PVC" -o jsonpath='{.spec.volumeName}')
[ -n "$NEW_PV" ] || die "PV local-path introuvable."
echo "$NEW_PV" >"$STATE/new-pv"
pv_retain "$NEW_PV"   # avant toute suppression de PVC : les données doivent survivre

log "4/5 Bascule : $NS/$PVC → $NEW_PV"
STAGE=swap
$K -n "$NS" delete pod "$POD" --wait=true >/dev/null
$K -n "$NS" delete pvc "$TMP_PVC" --wait=false >/dev/null
wait_pvc_gone "$NS" "$TMP_PVC"
$K -n "$NS" delete pvc "$PVC" --wait=false >/dev/null
wait_pvc_gone "$NS" "$PVC"
pv_unclaim "$NEW_PV"
recreate_pvc "$STATE/orig-pvc.json" "$NEW_PV" "$TARGET_SC" >/dev/null
wait_pvc_bound "$NS" "$PVC"
touch "$STATE/swapped"
STAGE=post-swap

log "5/5 Redémarrage des applications"
psa_restore "$NS" "$STATE"
scale_up "$NS" "$OWNERS"
mv "$OWNERS" "$STATE/owners.done"
trap - EXIT

$K -n "$NS" get pvc "$PVC" -o wide
cat <<EOF

✅ $NS/$PVC est maintenant sur $TARGET_SC ($NEW_PV, reclaimPolicy Retain).
   Ancien PV Longhorn conservé : $OLD_PV (Released) — retour arrière :
     bash 04-rollback-pvc.sh $NS $PVC
   Archive des données : $STATE/data.tar.gz
EOF
