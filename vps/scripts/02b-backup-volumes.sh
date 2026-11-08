#!/usr/bin/env bash
# Sauvegarde du CONTENU des volumes (PVC) Longhorn : une archive tar.gz par
# PVC, faite par un pod qui monte le volume en lecture seule.
#
#   sudo bash 02b-backup-volumes.sh [namespace]     # défaut : tous les namespaces
#
# Par défaut à chaud, sans arrêt des applis : suffisant pour des maildirs
# (écritures atomiques), Redis (RDB/AOF) ou ClamAV (signatures). Pour une
# copie strictement cohérente (bases de données), STOP=1 arrête les
# Deployments/StatefulSets le temps de l'archive de chaque PVC.
#
# Variables : SC (longhorn), OUT (/root/vps-backup-volumes-<date>), STOP=1,
#             BACKUP_IMAGE, BACKUP_TIMEOUT (secondes, 7200).
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

NS_FILTER=${1:-}
SC=${SC:-longhorn}
OUT=${OUT:-/root/vps-backup-volumes-$(date +%Y%m%d-%H%M%S)}
STOP=${STOP:-0}
IMAGE=${BACKUP_IMAGE:-debian:bookworm-slim}
TIMEOUT=${BACKUP_TIMEOUT:-7200}

preflight
mkdir -p "$OUT"
chmod 700 "$OUT"

if [ -n "$NS_FILTER" ]; then SCOPE=(-n "$NS_FILTER"); else SCOPE=(-A); fi
mapfile -t PVCS < <($K get pvc "${SCOPE[@]}" -o json | jq -r --arg sc "$SC" \
  '.items[] | select(.spec.storageClassName == $sc and .status.phase == "Bound") | "\(.metadata.namespace) \(.metadata.name)"')
[ ${#PVCS[@]} -gt 0 ] || die "Aucun PVC Bound en StorageClass $SC."

echo "PVC à sauvegarder (${#PVCS[@]}) — $( [ "$STOP" = 1 ] && echo "applis ARRÊTÉES pendant l'archive" || echo "à chaud" ) :"
printf '   %s\n' "${PVCS[@]}"
df -h "$OUT" | sed 's/^/   /'
confirm "Lancer la sauvegarde vers $OUT ?"

CUR_NS="" CUR_POD="" CUR_OWNERS=""
on_exit() {
  local rc=$?
  [ -n "$CUR_POD" ] && $K -n "$CUR_NS" delete pod "$CUR_POD" --ignore-not-found --wait=false >/dev/null 2>&1
  if [ -n "$CUR_OWNERS" ] && [ -s "$CUR_OWNERS" ]; then
    warn "Interruption : redémarrage des applis de $CUR_NS"
    scale_up "$CUR_NS" "$CUR_OWNERS" && rm -f "$CUR_OWNERS"
  fi
  [ -n "$CUR_NS" ] && psa_restore "$CUR_NS" "$OUT"
  [ $rc -eq 0 ] || warn "Sauvegarde incomplète (code $rc). Archives déjà faites : $OUT"
}
trap on_exit EXIT

FAILED=()
for entry in "${PVCS[@]}"; do
  read -r ns pvc <<<"$entry"
  name="${ns}_${pvc}"
  pod="vol-bk-$(echo "$pvc" | cut -c1-40 | sed 's/[-.]*$//')"
  log "$ns/$pvc"
  CUR_NS=$ns CUR_POD=$pod

  if [ "$STOP" = 1 ]; then
    CUR_OWNERS="$OUT/$name.owners"
    record_owners "$ns" "$pvc" "$CUR_OWNERS"
    scale_down "$ns" "$CUR_OWNERS"
    wait_no_pods "$ns" "$pvc"
  fi
  psa_relax "$ns" "$OUT"

  $K -n "$ns" delete pod "$pod" --ignore-not-found --wait=true >/dev/null
  $K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $ns
  labels: {vps-backup: volume}
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 0, runAsGroup: 0}
  containers:
    - name: backup
      image: $IMAGE
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -uo pipefail
          tar --numeric-owner --xattrs --acls --warning=no-file-ignored -czf /out/$name.tar.gz -C /data . ; rc=\$?
          # 1 = fichier modifié pendant la lecture (normal à chaud) ; >1 = erreur
          [ \$rc -le 1 ] || { echo "tar en erreur (\$rc)"; exit \$rc; }
          [ \$rc -eq 1 ] && echo "AVERTISSEMENT : fichiers modifiés pendant l'archive (à chaud)"
          (cd /out && sha256sum $name.tar.gz > $name.tar.gz.sha256)
          echo "entrées : \$(find /data | wc -l) ; KiB : \$(du -sk /data | cut -f1) ; archive : \$(du -h /out/$name.tar.gz | cut -f1)"
          echo BACKUP-OK
      volumeMounts:
        - {name: data, mountPath: /data, readOnly: true}
        - {name: out, mountPath: /out}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: $pvc, readOnly: true}
    - name: out
      hostPath: {path: $OUT, type: Directory}
EOF

  deadline=$(( $(date +%s) + TIMEOUT ))
  while :; do
    phase=$($K -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
    [ "$phase" = Succeeded ] || [ "$phase" = Failed ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then phase=Timeout; break; fi
    printf '   %s… (%s)\r' "$phase" "$(du -sh "$OUT/$name.tar.gz" 2>/dev/null | cut -f1)"
    sleep 5
  done
  $K -n "$ns" logs "$pod" >"$OUT/$name.log" 2>&1 || true
  cat "$OUT/$name.log"
  if [ "$phase" != Succeeded ] || ! grep -q BACKUP-OK "$OUT/$name.log"; then
    warn "Échec pour $ns/$pvc ($phase)"
    FAILED+=("$ns/$pvc")
  fi
  $K -n "$ns" delete pod "$pod" --wait=false >/dev/null
  CUR_POD=""

  psa_restore "$ns" "$OUT"
  if [ "$STOP" = 1 ]; then
    scale_up "$ns" "$CUR_OWNERS" && rm -f "$CUR_OWNERS"
    CUR_OWNERS=""
  fi
done

echo
ls -lh "$OUT"
[ ${#FAILED[@]} -eq 0 ] || die "PVC en échec : ${FAILED[*]}"
cat <<EOF

✅ Volumes sauvegardés dans $OUT
À copier HORS du VPS, depuis ta machine :
  ssh ${SUDO_USER:-ubuntu}@<vps> 'sudo tar -cf - -C $(dirname "$OUT") $(basename "$OUT")' > $(basename "$OUT").tar
Vérifier ensuite : cd $(basename "$OUT") && sha256sum -c *.sha256
Restaurer un PVC : monter le PVC (vide) dans un pod, puis
  tar --numeric-owner -xzpf <ns>_<pvc>.tar.gz -C <montage>
EOF
