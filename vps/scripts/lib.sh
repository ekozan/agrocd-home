# Fonctions communes à 03-migrate-pvc.sh et 04-rollback-pvc.sh (sourcé).
# shellcheck shell=bash

K=${KUBECTL:-kubectl}
# k3s : kubectl lit /etc/rancher/k3s/k3s.yaml tout seul, pas helm.
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
WORKDIR=${WORKDIR:-/root/vps-migration}

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf '\n!!  %s\n' "$*" >&2; exit 1; }

confirm() {
  [ "${YES:-}" = 1 ] && return 0
  local a
  read -r -p "$1 [o/N] " a
  [[ $a =~ ^[oOyY]$ ]] || die "Annulé."
}

preflight() {
  [ "$(id -u)" = 0 ] || die "À lancer en root sur le VPS (le pod de copie écrit dans $WORKDIR via hostPath)."
  command -v jq >/dev/null || die "jq requis : apt install -y jq"
  $K version >/dev/null 2>&1 || die "kubectl ne joint pas le cluster."
}

# Pods (noms) du namespace $1 qui montent le PVC $2
pods_using_pvc() {
  $K -n "$1" get pods -o json | jq -r --arg c "$2" \
    '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c)) | .metadata.name'
}

# Contrôleurs (Deployment/x, StatefulSet/x) des pods qui montent le PVC,
# écrits avec leur nombre de replicas dans le fichier $3.
# Un fichier existant est conservé : en cas de relance après interruption, on
# ne veut pas enregistrer « 0 replica ».
record_owners() {
  local ns=$1 pvc=$2 file=$3 pod ref kind name
  if [ -s "$file" ]; then
    warn "Contrôleurs repris de $file (exécution précédente interrompue)."
    return 0
  fi
  local refs=()
  for pod in $(pods_using_pvc "$ns" "$pvc"); do
    ref=$($K -n "$ns" get pod "$pod" -o json | jq -r '(.metadata.ownerReferences // [{}])[0] | "\(.kind // "none") \(.name // "-")"')
    read -r kind name <<<"$ref"
    case $kind in
      ReplicaSet)
        ref=$($K -n "$ns" get rs "$name" -o json | jq -r '(.metadata.ownerReferences // [{}])[0] | "\(.kind // "none") \(.name // "-")"')
        read -r kind name <<<"$ref"
        [ "$kind" = Deployment ] || die "Pod $pod : ReplicaSet $name sans Deployment. Arrête-le à la main puis relance."
        ;;
      StatefulSet) ;;
      *) die "Pod $pod géré par '$kind/$name' (Job, DaemonSet, pod nu…) : arrête-le à la main (ex. suspendre la CronJob), puis relance." ;;
    esac
    refs+=("$kind/$name")
  done
  local tmp="$file.tmp"
  : >"$tmp"
  for ref in $(printf '%s\n' ${refs[@]+"${refs[@]}"} | sort -u); do
    echo "$ref $($K -n "$ns" get "$ref" -o jsonpath='{.spec.replicas}')" >>"$tmp"
  done
  mv "$tmp" "$file"
}

scale_down() {
  local ns=$1 file=$2 ref rep
  while read -r ref rep; do
    echo "   $ref : $rep → 0"
    $K -n "$ns" scale "$ref" --replicas=0
  done <"$file"
}

scale_up() {
  local ns=$1 file=$2 ref rep
  [ -s "$file" ] || return 0
  while read -r ref rep; do
    echo "   $ref : 0 → $rep"
    $K -n "$ns" scale "$ref" --replicas="$rep" || warn "échec du scale de $ref"
  done <"$file"
  while read -r ref rep; do
    [ "$rep" -gt 0 ] && { $K -n "$ns" rollout status "$ref" --timeout=300s || warn "$ref pas encore prêt, à vérifier"; }
  done <"$file"
}

wait_no_pods() {
  local ns=$1 pvc=$2
  for _ in $(seq 1 60); do
    [ -z "$(pods_using_pvc "$ns" "$pvc")" ] && return 0
    sleep 5
  done
  die "Des pods utilisent encore $ns/$pvc après 5 min : $(pods_using_pvc "$ns" "$pvc" | tr '\n' ' ')"
}

wait_pvc_gone() {
  local ns=$1 pvc=$2
  for _ in $(seq 1 60); do
    $K -n "$ns" get pvc "$pvc" >/dev/null 2>&1 || return 0
    sleep 2
  done
  die "Le PVC $ns/$pvc n'est pas supprimé (finalizer ?)."
}

wait_pvc_bound() {
  local ns=$1 pvc=$2
  for _ in $(seq 1 60); do
    [ "$($K -n "$ns" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound ] && return 0
    sleep 2
  done
  die "Le PVC $ns/$pvc n'est pas Bound."
}

pv_retain() { $K patch pv "$1" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null; }

# Rend un PV « Released » de nouveau disponible pour un nouveau PVC
pv_unclaim() {
  $K patch pv "$1" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null 2>&1 || true
}

# Recrée le PVC décrit par le JSON $1 (PVC d'origine), lié au PV $2, classe $3
recreate_pvc() {
  local json=$1 pv=$2 sc=$3
  jq --arg pv "$pv" --arg sc "$sc" '
    {apiVersion: "v1", kind: "PersistentVolumeClaim",
     metadata: (.metadata
       | {name, namespace, labels, ownerReferences,
          annotations: ((.annotations // {}) | with_entries(select(.key
             | test("^(pv\\.kubernetes\\.io/|volume\\.beta\\.kubernetes\\.io/|volume\\.kubernetes\\.io/|kubectl\\.kubernetes\\.io/last-applied)") | not)))}
       | with_entries(select(.value != null and .value != {}))),
     spec: {accessModes: .spec.accessModes,
            resources: {requests: {storage: .spec.resources.requests.storage}},
            storageClassName: $sc, volumeName: $pv,
            volumeMode: (.spec.volumeMode // "Filesystem")}}' "$json" | $K create -f -
}

# Pod Security Admission : le pod de copie tourne en root avec un hostPath,
# refusé en baseline/restricted. On passe le namespace en privileged le temps
# de la copie, puis on remet la valeur d'origine.
psa_relax() {
  local ns=$1 state=$2 cur
  cur=$($K get ns "$ns" -o json | jq -r '.metadata.labels["pod-security.kubernetes.io/enforce"] // ""')
  if [ -n "$cur" ] && [ "$cur" != privileged ]; then
    echo "$cur" >"$state/psa-enforce"
    warn "Namespace $ns en PSA '$cur' → privileged pendant la copie."
    $K label ns "$ns" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
  fi
}

psa_restore() {
  local ns=$1 state=$2
  [ -s "$state/psa-enforce" ] || return 0
  $K label ns "$ns" pod-security.kubernetes.io/enforce="$(cat "$state/psa-enforce")" --overwrite >/dev/null
  rm -f "$state/psa-enforce"
}
