#!/usr/bin/env bash
# Inventaire du VPS (k3s mono-nœud) — LECTURE SEULE, ne modifie rien.
#
# À lancer en root sur le VPS :
#   sudo bash 01-collect-info.sh [dossier_de_sortie]
#
# Produit un dossier + une archive .tar.gz, et affiche un résumé (summary.txt)
# à copier-coller. Aucun Secret Kubernetes n'est exporté ; les tokens trouvés
# dans la config k3s sont masqués.
set -uo pipefail

OUT=${1:-/root/vps-inventory-$(date +%Y%m%d-%H%M%S)}
K=${KUBECTL:-kubectl}
# k3s : kubectl lit /etc/rancher/k3s/k3s.yaml tout seul, pas helm.
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
mkdir -p "$OUT"
chmod 700 "$OUT"

# run <fichier> <commande...> : sortie + erreurs dans $OUT/<fichier>.txt
run() {
  local name=$1
  shift
  { echo "\$ $*"; "$@"; } >"$OUT/$name.txt" 2>&1 || true
}
# Masque les valeurs de token/password/secret dans un flux texte
redact() { sed -E 's/((token|password|secret|agent-token)[A-Za-z_-]*[\t =:"]+)[^ \t"]+/\1<MASQUÉ>/Ig'; }

echo "==> Système"
run os          cat /etc/os-release
run uname       uname -a
run cpu-mem     sh -c 'nproc; echo; free -h; echo; uptime'
run disks       sh -c 'df -hT -x tmpfs -x devtmpfs -x overlay; echo; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT'
run du-k3s      sh -c 'du -sh /var/lib/rancher/k3s/storage /var/lib/longhorn /var/lib/rancher/k3s/server/db/* /var/lib/rancher/k3s/agent/containerd 2>/dev/null'
run tools       sh -c 'for t in jq sqlite3 helm rsync iscsiadm; do printf "%-10s %s\n" "$t" "$(command -v $t || echo ABSENT)"; done'

echo "==> k3s"
run k3s-version k3s --version
run k3s-datastore sh -c 'ls -la /var/lib/rancher/k3s/server/db/ 2>&1; echo; [ -d /var/lib/rancher/k3s/server/db/etcd ] && echo "DATASTORE=etcd" || echo "DATASTORE=sqlite"'
{ echo "\$ systemctl cat k3s"; systemctl cat k3s 2>&1; } | redact >"$OUT/k3s-service.txt"
{ echo "\$ cat /etc/rancher/k3s/config.yaml"; cat /etc/rancher/k3s/config.yaml 2>&1; } | redact >"$OUT/k3s-config.txt"
run etcd-snapshots sh -c 'k3s etcd-snapshot ls 2>&1 || true'

echo "==> Cluster"
run nodes        $K get nodes -o wide
run node-describe $K describe nodes
run top          sh -c "$K top nodes; echo; $K top pods -A --sort-by=memory"
run namespaces   $K get ns --show-labels
run storageclass $K get sc
run local-path-config $K -n kube-system get configmap local-path-config -o jsonpath='{.data.config\.json}'
run pv           $K get pv -o wide
run pvc          $K get pvc -A -o wide
run helm         helm list -A
run workloads    $K get deploy,sts,ds,cronjob -A -o wide
run ingress      $K get ingress,ingressroute,ingressroutetcp -A
run svc-lb       sh -c "$K get svc -A | grep -E 'LoadBalancer|NAME'"
run rancher      sh -c "$K get deploy -n cattle-system; echo; $K get ns | grep -E 'cattle|fleet'; echo; $K get clusters.management.cattle.io 2>&1 | head"

echo "==> Pods ↔ PVC"
$K get pods -A -o json 2>/dev/null | jq -r '
  .items[]
  | select(any(.spec.volumes[]?; .persistentVolumeClaim))
  | [.metadata.namespace, .metadata.name,
     ((.metadata.ownerReferences // [{}])[0] | "\(.kind // "-")/\(.name // "-")"),
     ([.spec.volumes[] | .persistentVolumeClaim.claimName // empty] | join(","))]
  | @tsv' | column -t >"$OUT/pods-pvc.txt" 2>&1

echo "==> Longhorn"
run longhorn-volumes  $K -n longhorn-system get volumes.longhorn.io -o wide
run longhorn-settings $K -n longhorn-system get settings.longhorn.io default-replica-count default-data-path backup-target deleting-confirmation-flag
run longhorn-backuptarget $K -n longhorn-system get backuptargets.longhorn.io -o wide
run longhorn-pods     $K -n longhorn-system get pods -o wide

# Résumé : PVC Longhorn à migrer + taille réellement utilisée
{
  echo "######## RÉSUMÉ VPS ($(hostname), $(date -Is)) ########"
  echo
  cat "$OUT/k3s-version.txt" | sed -n 2p
  grep "^DATASTORE=" "$OUT/k3s-datastore.txt"
  echo "CPU : $(nproc)"
  free -h | sed -n 2p
  echo
  echo "--- Disques"
  df -h / /var/lib/rancher /var/lib/longhorn 2>/dev/null | awk 'NR==1 || !seen[$0]++'
  echo
  echo "--- Occupation"
  sed 1d "$OUT/du-k3s.txt"
  echo
  echo "--- Outils"
  sed 1d "$OUT/tools.txt"
  echo
  echo "--- StorageClasses"
  sed 1d "$OUT/storageclass.txt"
  echo
  echo "--- PVC (toutes)"
  $K get pvc -A -o custom-columns='NS:.metadata.namespace,PVC:.metadata.name,SC:.spec.storageClassName,SIZE:.status.capacity.storage,MODES:.spec.accessModes,VOLMODE:.spec.volumeMode,PV:.spec.volumeName,STATUS:.status.phase' 2>&1
  echo
  echo "--- Volumes Longhorn (actualSize = espace disque réel, snapshots compris)"
  $K -n longhorn-system get volumes.longhorn.io -o custom-columns='VOLUME:.metadata.name,PVC:.status.kubernetesStatus.pvcName,NS:.status.kubernetesStatus.namespace,SIZE:.spec.size,ACTUAL:.status.actualSize,REPLICAS:.spec.numberOfReplicas,STATE:.status.state,ROBUST:.status.robustness' 2>&1
  echo
  echo "--- Pods qui utilisent un PVC (ns, pod, propriétaire, pvc)"
  cat "$OUT/pods-pvc.txt"
  echo
  echo "--- Helm"
  sed 1d "$OUT/helm.txt"
  echo
  echo "--- Rancher"
  sed 1d "$OUT/rancher.txt"
  echo
  echo "--- Namespaces avec Pod Security Admission"
  $K get ns -o json 2>/dev/null | jq -r '.items[] | select(.metadata.labels["pod-security.kubernetes.io/enforce"]) | "\(.metadata.name)\t\(.metadata.labels["pod-security.kubernetes.io/enforce"])"'
} >"$OUT/summary.txt" 2>&1

tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
chmod 600 "$OUT.tar.gz"

cat "$OUT/summary.txt"
echo
echo "Détails : $OUT/  —  archive : $OUT.tar.gz"
