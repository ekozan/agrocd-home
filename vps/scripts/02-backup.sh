#!/usr/bin/env bash
# Sauvegarde du VPS AVANT migration : base k3s, identité du serveur (token,
# CA), manifests de toutes les ressources, values Helm.
#
# Les DONNÉES des volumes sont archivées par 03-migrate-pvc.sh, application
# arrêtée (copie cohérente) : /root/vps-migration/<ns>_<pvc>/data.tar.gz.
#
# À lancer en root sur le VPS :
#   sudo bash 02-backup.sh [dossier]
#
# ⚠️ Contient les Secrets du cluster et le token k3s : dossier en 700, à copier
# hors du VPS (commande affichée à la fin) puis à garder en lieu sûr.
set -euo pipefail

BK=${1:-/root/vps-backup-$(date +%Y%m%d-%H%M%S)}
K=${KUBECTL:-kubectl}
K3S=/var/lib/rancher/k3s
umask 077
mkdir -p "$BK"/{datastore,manifests/namespaced,manifests/cluster,helm}

[ "$(id -u)" = 0 ] || { echo "À lancer en root." >&2; exit 1; }

echo "==> 1/4 Base de données k3s"
if [ -d "$K3S/server/db/etcd" ]; then
  k3s etcd-snapshot save --name pre-migration --dir "$BK/datastore"
elif [ -f "$K3S/server/db/state.db" ]; then
  if command -v sqlite3 >/dev/null; then
    # Copie à chaud cohérente (API backup de SQLite, compatible WAL)
    sqlite3 "$K3S/server/db/state.db" ".backup '$BK/datastore/state.db'"
    sqlite3 "$BK/datastore/state.db" 'PRAGMA integrity_check;'
  else
    echo "   sqlite3 absent (apt install sqlite3) : copie brute state.db + WAL."
    echo "   Pour une copie garantie cohérente : systemctl stop k3s, relancer ce script, systemctl start k3s."
    cp -a "$K3S/server/db/state.db"* "$BK/datastore/"
  fi
else
  echo "   Aucune base trouvée dans $K3S/server/db" >&2
fi

echo "==> 2/4 Identité du serveur (token, CA, config)"
# Sans le token et les certificats (server/tls), une restauration de la base
# est inutilisable. server/db est exclu (déjà sauvegardé ci-dessus).
tar -czf "$BK/k3s-server.tar.gz" -C "$K3S" --exclude=server/db server
tar -czf "$BK/etc-rancher.tar.gz" -C /etc rancher
cp -a /etc/systemd/system/k3s.service* "$BK/" 2>/dev/null || true

echo "==> 3/4 Manifests"
# Ressources namespacées listables (hors événements, métriques, objets
# éphémères), un fichier par type et par namespace.
mapfile -t NS_RES < <($K api-resources --verbs=list,get --namespaced -o name \
  | grep -vE '^(events(\.events\.k8s\.io)?|pods\.metrics\.k8s\.io|endpointslices\.discovery\.k8s\.io|endpoints|leases\.coordination\.k8s\.io|localsubjectaccessreviews.*|.*reviews\..*)$')
for ns in $($K get ns -o jsonpath='{.items[*].metadata.name}'); do
  mkdir -p "$BK/manifests/namespaced/$ns"
  for r in "${NS_RES[@]}"; do
    out=$($K -n "$ns" get "$r" -o yaml 2>/dev/null) || continue
    grep -q '^items: \[\]' <<<"$out" && continue
    printf '%s\n' "$out" >"$BK/manifests/namespaced/$ns/$r.yaml"
  done
done
for r in namespaces persistentvolumes storageclasses customresourcedefinitions \
  clusterroles clusterrolebindings ingressclasses priorityclasses \
  mutatingwebhookconfigurations validatingwebhookconfigurations nodes; do
  $K get "$r" -o yaml >"$BK/manifests/cluster/$r.yaml" 2>/dev/null || true
done

echo "==> 4/4 Helm (releases + values)"
if command -v helm >/dev/null; then
  helm list -A >"$BK/helm/releases.txt"
  helm list -A -o json | jq -r '.[] | "\(.namespace) \(.name)"' | while read -r ns rel; do
    helm get values -a -n "$ns" "$rel" -o yaml >"$BK/helm/${ns}_${rel}.values.yaml" 2>/dev/null || true
  done
else
  echo "   helm absent : les releases restent dans les Secrets sh.helm.release.* (manifests)."
fi

cat >"$BK/RESTORE.md" <<'EOF'
# Restauration (résumé)
- Volumes : /root/vps-migration/<ns>_<pvc>/data.tar.gz (créés par 03-migrate-pvc.sh)
  → monter un PVC vide dans un pod et `tar -xzpf data.tar.gz -C <montage>`.
- Ressources : `kubectl apply -f manifests/namespaced/<ns>/<type>.yaml`
  (retirer status/uid/resourceVersion si besoin).
- Cluster complet :
  - etcd   : k3s server --cluster-reset --cluster-reset-restore-path=<snapshot> (token identique)
  - sqlite : systemctl stop k3s ; restaurer k3s-server.tar.gz + datastore/state.db
             dans /var/lib/rancher/k3s/server/{,db/} ; systemctl start k3s
EOF

du -sh "$BK"
echo
echo "Sauvegarde : $BK"
echo "À copier HORS du VPS, depuis ta machine :"
echo "  rsync -a root@$(hostname -f 2>/dev/null || hostname):$BK ./"
