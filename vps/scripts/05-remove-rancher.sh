#!/usr/bin/env bash
# Retire Rancher (serveur, webhook, Fleet, CAPI, system-upgrade-controller) du
# k3s du VPS, pour l'importer ensuite dans le Rancher de la maison.
#
#   sudo bash 05-remove-rancher.sh            # SIMULATION : affiche ce qui serait fait
#   sudo APPLY=1 bash 05-remove-rancher.sh    # exécute
#
# Conservé : cert-manager (+ webhook OVH), Longhorn, Mailu, Traefik,
# kubernetes-replicator et TOUS les composants de k3s.
#
# ⚠️ k3s a ses propres CRD en *.cattle.io (helm.cattle.io, k3s.cattle.io) :
# supprimer HelmChart désinstallerait Traefik, Addon les composants intégrés
# (CoreDNS, local-path, metrics-server). Elles sont exclues explicitement.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

APPLY=${APPLY:-0}
run() {
  if [ "$APPLY" = 1 ]; then echo "+ $*"; "$@"; else echo "[simulation] $*"; fi
}

preflight
command -v helm >/dev/null || die "helm requis."

# Releases Helm de Rancher, dans l'ordre : contrôleurs d'abord (sinon ils
# recréent ce qu'on supprime), webhook et CRD en dernier.
RELEASES=(
  "cattle-system rancher"
  "cattle-fleet-local-system fleet-agent-local"
  "cattle-fleet-system fleet"
  "cattle-provisioning-capi-system rancher-provisioning-capi"
  "cattle-system system-upgrade-controller"
  "cattle-system rancher-webhook"
  "cattle-fleet-system fleet-crd"
)

# CRD de Rancher, Fleet et CAPI ; jamais celles de k3s.
mapfile -t CRDS < <($K get crd -o name | sed 's|.*/||' \
  | grep -E '\.cattle\.io$|\.cluster\.x-k8s\.io$' \
  | grep -vE '\.(k3s|helm)\.cattle\.io$' || true)

NS_RE='^(cattle-.*|fleet-.*|cluster-fleet-.*|local|p-[a-z0-9]{5}|u-[a-z0-9]{10}|user-[a-z0-9]{5})$'
mapfile -t NAMESPACES < <($K get ns -o name | sed 's|.*/||' | grep -E "$NS_RE" || true)

mapfile -t WEBHOOKS < <($K get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name \
  | grep -iE 'rancher|cattle|fleet|capi' || true)

echo "Releases Helm à désinstaller :"
for r in "${RELEASES[@]}"; do
  read -r ns rel <<<"$r"
  helm status -n "$ns" "$rel" >/dev/null 2>&1 && echo "   $ns/$rel" || echo "   $ns/$rel (absente)"
done
echo "Webhooks :";   printf '   %s\n' ${WEBHOOKS[@]+"${WEBHOOKS[@]}"}
echo "CRD (${#CRDS[@]}) :"; printf '   %s\n' ${CRDS[@]+"${CRDS[@]}"}
echo "Namespaces (${#NAMESPACES[@]}) :"; printf '   %s\n' ${NAMESPACES[@]+"${NAMESPACES[@]}"}
echo "CRD k3s conservées :"; $K get crd -o name | sed 's|.*/||' | grep -E '\.(k3s|helm)\.cattle\.io$' | sed 's/^/   /'

if [ "$APPLY" != 1 ]; then
  echo
  echo "SIMULATION terminée : vérifier les listes ci-dessus, puis relancer avec APPLY=1."
  exit 0
fi
echo
confirm "Retirer Rancher de ce cluster ?"

log "1/6 Désinstallation des releases Helm"
for r in "${RELEASES[@]}"; do
  read -r ns rel <<<"$r"
  helm status -n "$ns" "$rel" >/dev/null 2>&1 || continue
  run helm uninstall -n "$ns" "$rel" --timeout 5m || warn "échec : $ns/$rel (on continue)"
done

log "2/6 Webhooks restants (sinon l'API refuse des opérations)"
for w in ${WEBHOOKS[@]+"${WEBHOOKS[@]}"}; do
  run $K delete "$w" --ignore-not-found
done

log "3/6 Objets des CRD Rancher : retrait des finalizers puis suppression"
# Les contrôleurs ne tournent plus : leurs finalizers ne seraient jamais levés.
for crd in ${CRDS[@]+"${CRDS[@]}"}; do
  $K get "$crd" -A -o json 2>/dev/null | jq -r '.items[]
      | select((.metadata.finalizers // []) | length > 0)
      | "\(.metadata.namespace // "") \(.metadata.name)"' \
  | while read -r ns name; do
      if [ -z "$name" ]; then name=$ns ns=""; fi
      $K patch "$crd" "$name" ${ns:+-n "$ns"} --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done || true   # CRD déjà supprimée (ex. par fleet-crd) : kubectl get échoue, pipefail
  run $K delete crd "$crd" --ignore-not-found --wait=false
done

log "4/6 Namespaces Rancher"
for ns in ${NAMESPACES[@]+"${NAMESPACES[@]}"}; do
  run $K delete ns "$ns" --ignore-not-found --wait=false
done
for _ in $(seq 1 24); do
  left=$($K get ns -o name | sed 's|.*/||' | grep -cE "$NS_RE" || true)
  [ "$left" -eq 0 ] && break
  sleep 5
done
# Namespaces bloqués en Terminating : finalizer levé via l'API /finalize
for ns in $($K get ns -o json | jq -r '.items[] | select(.status.phase == "Terminating") | .metadata.name'); do
  warn "Namespace $ns bloqué : finalisation forcée"
  $K get ns "$ns" -o json | jq '.spec.finalizers = [] | .metadata.finalizers = []' \
    | $K replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null || true
done

log "5/6 Restes Rancher sur les namespaces et nœuds conservés"
# Finalizers cattle (bloqueraient une future suppression) et projet de
# l'ancien Rancher (field.cattle.io/projectId) : le Rancher maison
# rangera ces namespaces dans ses propres projets.
for kind in ns node; do
  for obj in $($K get "$kind" -o name); do
    $K get "$obj" -o json | jq -e '
        ((.metadata.finalizers // []) | any(test("cattle"))) or
        ((.metadata.annotations // {}) | has("field.cattle.io/projectId"))' >/dev/null || continue
    echo "   $obj"
    # Patch merge (pas de replace : le kubelet modifie le nœud en continu)
    patch=$($K get "$obj" -o json | jq -c '{metadata: {
        finalizers: ((.metadata.finalizers // []) | map(select(test("cattle") | not))),
        annotations: {"field.cattle.io/projectId": null},
        labels: {"field.cattle.io/projectId": null}}}') || continue
    $K patch "$obj" --type merge -p "$patch" >/dev/null || warn "échec sur $obj"
  done
done

log "6/6 État"
$K get ns
$K get pods -A | grep -vE 'Running|Completed' || true
free -h
cat <<'EOF'

✅ Rancher retiré. Mailu, Longhorn, cert-manager et Traefik doivent être intacts :
   kubectl -n mailserver get pods ; kubectl -n longhorn-system get pods
Étape suivante : Rancher maison → Cluster Management → Import Existing → Generic,
puis la commande kubectl apply affichée, sur ce VPS.
EOF
