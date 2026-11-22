#!/usr/bin/env bash
# =============================================================================
# clean-master-node.sh — Nettoyage d'un nœud master k3s / RKE2
# =============================================================================
#
# Sections (toutes actives par défaut, filtrables via --only) :
#   images    Images containerd inutilisées, conteneurs arrêtés, sandboxes mortes
#   logs      journald, logs tournés de /var/log et /var/log/pods, logs runtime
#   etcd      Purge des snapshots etcd + défragmentation de la base etcd
#   longhorn  Volumes Longhorn orphelins (PV Released / PV absent) + données
#             orphelines (CR orphans.longhorn.io) — TOUJOURS validé élément
#             par élément, même avec --yes
#   k8s       Pods terminés (Succeeded / Failed / Evicted) sur tout le cluster
#   system    Cache du gestionnaire de paquets, coredumps
#
# Par défaut le script est en DRY-RUN : il affiche ce qui serait nettoyé et ne
# modifie rien. Ajouter --apply pour exécuter (avec confirmation par section).
#
# Exemples :
#   sudo ./clean-master-node.sh                       # rapport seul
#   sudo ./clean-master-node.sh --apply               # nettoyage interactif
#   sudo ./clean-master-node.sh --apply --only images,logs --yes
#   sudo ./clean-master-node.sh --apply --only longhorn
# =============================================================================

set -uo pipefail

# ------------------------------------------------------------------ défauts --
APPLY=0
ASSUME_YES=0
SECTIONS="images,logs,etcd,longhorn,k8s,system"
LOG_DAYS=7                 # âge minimal des logs tournés à supprimer
JOURNAL_MAX_SIZE="500M"    # taille max conservée pour journald
RUNTIME_LOG_MAX_MB=100     # au-delà, containerd.log / kubelet.log sont tronqués
ETCD_SNAPSHOT_RETENTION=5  # nombre de snapshots etcd conservés
ETCD_DEFRAG=1
LONGHORN_NS="longhorn-system"
NODE_NAME=""

# ------------------------------------------------------------------ couleurs --
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'
  C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

log()     { printf '%s\n' "$*"; }
info()    { printf '%s[i]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()      { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()     { printf '%s[✗]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
section() { printf '\n%s══ %s ══%s\n' "$C_BLD" "$*" "$C_RST"; }
dry()     { printf '%s[dry-run]%s %s\n' "$C_YEL" "$C_RST" "$*"; }

usage() {
  sed -n '2,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  cat <<EOF
Options :
  --apply                 Exécute réellement le nettoyage (sinon dry-run)
  --yes, -y               Pas de confirmation par section (sauf Longhorn)
  --only LISTE            Sections à traiter, séparées par des virgules
                          (défaut : $SECTIONS)
  --log-days N            Âge minimal des logs tournés à supprimer (défaut : $LOG_DAYS)
  --journal-max TAILLE    Taille max de journald, ex. 500M, 1G (défaut : $JOURNAL_MAX_SIZE)
  --runtime-log-max MB    Seuil de troncature containerd/kubelet log (défaut : $RUNTIME_LOG_MAX_MB)
  --etcd-retention N      Snapshots etcd conservés (défaut : $ETCD_SNAPSHOT_RETENTION)
  --no-defrag             Ne pas défragmenter etcd
  --node NOM              Nom du nœud Kubernetes (défaut : auto-détection)
  --longhorn-ns NS        Namespace Longhorn (défaut : $LONGHORN_NS)
  -h, --help              Cette aide
EOF
}

# ------------------------------------------------------------- arguments --
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)            APPLY=1 ;;
    -y|--yes)           ASSUME_YES=1 ;;
    --only)             SECTIONS="${2:?}"; shift ;;
    --log-days)         LOG_DAYS="${2:?}"; shift ;;
    --journal-max)      JOURNAL_MAX_SIZE="${2:?}"; shift ;;
    --runtime-log-max)  RUNTIME_LOG_MAX_MB="${2:?}"; shift ;;
    --etcd-retention)   ETCD_SNAPSHOT_RETENTION="${2:?}"; shift ;;
    --no-defrag)        ETCD_DEFRAG=0 ;;
    --node)             NODE_NAME="${2:?}"; shift ;;
    --longhorn-ns)      LONGHORN_NS="${2:?}"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) err "Option inconnue : $1"; usage; exit 2 ;;
  esac
  shift
done

want() { [[ ",$SECTIONS," == *",$1,"* ]]; }

# Confirmation : lit sur le terminal pour fonctionner même si stdin est redirigé.
# $1 = question ; $2 = "force" pour ignorer --yes (Longhorn).
confirm() {
  local q="$1" force="${2:-}" ans
  if [[ $ASSUME_YES -eq 1 && "$force" != "force" ]]; then return 0; fi
  if [[ ! -r /dev/tty ]]; then
    warn "Pas de terminal pour valider « $q » → ignoré."
    return 1
  fi
  read -r -p "${C_BLD}?${C_RST} $q [o/N] " ans </dev/tty || return 1
  [[ "$ans" =~ ^([oOyY]|oui|yes)$ ]]
}

# Exécute une commande (ou l'affiche en dry-run).
run() {
  if [[ $APPLY -eq 1 ]]; then
    "$@" || warn "Échec : $*"
  else
    dry "$*"
  fi
}

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
dir_size() { du -sb "$1" 2>/dev/null | awk '{print $1}'; }

# ------------------------------------------------------------ pré-requis --
if [[ $EUID -ne 0 ]]; then
  err "Ce script doit être lancé en root (sudo)."
  exit 1
fi

DISTRO=""
if [[ -d /var/lib/rancher/rke2/server || -d /var/lib/rancher/rke2/agent ]]; then
  DISTRO="rke2"
elif [[ -d /var/lib/rancher/k3s ]]; then
  DISTRO="k3s"
fi

case "$DISTRO" in
  rke2)
    DATA_DIR="/var/lib/rancher/rke2"
    export PATH="$DATA_DIR/bin:$PATH"
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
    export CONTAINER_RUNTIME_ENDPOINT="${CONTAINER_RUNTIME_ENDPOINT:-unix:///run/k3s/containerd/containerd.sock}"
    KUBECTL=(kubectl)
    CRICTL=(crictl)
    DISTRO_BIN="rke2"
    ;;
  k3s)
    DATA_DIR="/var/lib/rancher/k3s"
    KUBECTL=(k3s kubectl)
    CRICTL=(k3s crictl)
    DISTRO_BIN="k3s"
    ;;
  *)
    err "Ni k3s ni RKE2 détecté (/var/lib/rancher/{k3s,rke2})."
    exit 1
    ;;
esac

k()  { "${KUBECTL[@]}" "$@"; }
cri() { "${CRICTL[@]}" "$@"; }

HAVE_K8S=0
if k version --request-timeout=5s >/dev/null 2>&1; then HAVE_K8S=1; fi

if [[ -z "$NODE_NAME" ]]; then
  NODE_NAME="$(hostname)"
  if [[ $HAVE_K8S -eq 1 ]] && ! k get node "$NODE_NAME" >/dev/null 2>&1; then
    NODE_NAME="$(hostname -s)"
  fi
fi

disk_report() {
  df -h --output=target,size,used,avail,pcent / /var "$DATA_DIR" /var/lib/longhorn /var/log 2>/dev/null \
    | awk 'NR==1 || !seen[$1]++'
}

section "Nœud $NODE_NAME ($DISTRO) — mode $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
[[ $HAVE_K8S -eq 0 ]] && warn "API Kubernetes injoignable : sections longhorn/k8s ignorées."
info "Sections : $SECTIONS"
disk_report

# =============================================================================
# 1. IMAGES / CONTENEURS
# =============================================================================
clean_images() {
  section "Images & conteneurs (containerd)"
  local cd_dir="$DATA_DIR/agent/containerd"
  info "Taille de $cd_dir : $(human "$(dir_size "$cd_dir")")"

  local exited sandboxes
  exited=$(cri ps -a --state exited -q 2>/dev/null | wc -l)
  sandboxes=$(cri pods --state notready -q 2>/dev/null | wc -l)

  # Estimation des images inutilisées : images dont l'ID n'est référencé
  # par aucun conteneur (même arrêté).
  local used all unused=0
  used=$(cri ps -a -o json 2>/dev/null | grep -oE '"imageRef": *"[^"]+"' \
           | sed -E 's/.*"(sha256:)?([0-9a-f]{64})".*/\2/' | sort -u)
  all=$(cri images -q 2>/dev/null | sed 's/^sha256://' | sort -u)
  if [[ -n "$all" ]]; then
    unused=$(comm -23 <(echo "$all") <(echo "$used") | grep -c . || true)
  fi
  info "Conteneurs arrêtés : $exited — sandboxes NotReady : $sandboxes — images non utilisées (≈) : $unused / $(echo "$all" | grep -c .)"

  if [[ $((exited + sandboxes + unused)) -eq 0 ]]; then ok "Rien à nettoyer."; return; fi
  if [[ $APPLY -eq 1 ]] && ! confirm "Supprimer conteneurs arrêtés, sandboxes mortes et images inutilisées ?"; then
    info "Section ignorée."; return
  fi

  if [[ $exited -gt 0 ]]; then
    if [[ $APPLY -eq 1 ]]; then cri ps -a --state exited -q | xargs -r "${CRICTL[@]}" rm >/dev/null || true
    else dry "crictl rm \$(crictl ps -a --state exited -q)"; fi
  fi
  if [[ $sandboxes -gt 0 ]]; then
    if [[ $APPLY -eq 1 ]]; then cri pods --state notready -q | xargs -r "${CRICTL[@]}" rmp >/dev/null || true
    else dry "crictl rmp \$(crictl pods --state notready -q)"; fi
  fi
  run "${CRICTL[@]}" rmi --prune
  [[ $APPLY -eq 1 ]] && ok "Taille de $cd_dir après : $(human "$(dir_size "$cd_dir")")"
}

# =============================================================================
# 2. LOGS
# =============================================================================
clean_logs() {
  section "Logs"

  # --- journald
  if command -v journalctl >/dev/null 2>&1; then
    info "journald : $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | head -1)"
  fi

  # --- fichiers tournés (/var/log + /var/log/pods)
  local rotated
  rotated=$(find /var/log -xdev -type f \
              \( -name '*.gz' -o -name '*.xz' -o -name '*.zst' -o -name '*.old' \
                 -o -regex '.*\.[0-9]+' -o -regex '.*/pods/.*\.log\.[0-9-]+.*' \) \
              -mtime +"$LOG_DAYS" 2>/dev/null)
  local rot_count rot_size=0
  rot_count=$(echo -n "$rotated" | grep -c . || true)
  if [[ $rot_count -gt 0 ]]; then
    rot_size=$(echo "$rotated" | tr '\n' '\0' | du -cb --files0-from=- 2>/dev/null | tail -1 | awk '{print $1}')
  fi
  info "Logs tournés > ${LOG_DAYS} j : $rot_count fichier(s), $(human "$rot_size")"

  # --- logs runtime volumineux (écrits en append → troncature sûre)
  local runtime_logs=() f
  for f in "$DATA_DIR/agent/containerd/containerd.log" \
           "$DATA_DIR/agent/logs/kubelet.log" \
           /var/log/k3s.log /var/log/rke2.log; do
    [[ -f "$f" ]] || continue
    if [[ $(stat -c %s "$f") -gt $((RUNTIME_LOG_MAX_MB * 1024 * 1024)) ]]; then
      runtime_logs+=("$f")
      info "Log runtime volumineux : $f ($(human "$(stat -c %s "$f")"))"
    fi
  done

  if [[ $APPLY -eq 1 ]] && ! confirm "Nettoyer journald (> $JOURNAL_MAX_SIZE / > ${LOG_DAYS} j), logs tournés et logs runtime ?"; then
    info "Section ignorée."; return
  fi

  if command -v journalctl >/dev/null 2>&1; then
    run journalctl --rotate
    run journalctl --vacuum-size="$JOURNAL_MAX_SIZE" --vacuum-time="${LOG_DAYS}d"
  fi
  if [[ $rot_count -gt 0 ]]; then
    if [[ $APPLY -eq 1 ]]; then echo "$rotated" | tr '\n' '\0' | xargs -0 -r rm -f --
    else echo "$rotated" | head -10 | sed 's/^/    /'; [[ $rot_count -gt 10 ]] && log "    … (+$((rot_count - 10)))"; dry "rm -f <$rot_count fichiers>"; fi
  fi
  for f in "${runtime_logs[@]}"; do run truncate -s 0 "$f"; done
  ok "Logs traités."
}

# =============================================================================
# 3. ETCD (base de données du control-plane)
# =============================================================================
etcdctl_cmd() {
  # Renvoie via la variable globale ETCDCTL un tableau de commande utilisable.
  local tls="$DATA_DIR/server/tls/etcd"
  local args=(--endpoints=https://127.0.0.1:2379
              --cacert="$tls/server-ca.crt" --cert="$tls/server-client.crt" --key="$tls/server-client.key")
  if command -v etcdctl >/dev/null 2>&1; then
    ETCDCTL=(env ETCDCTL_API=3 etcdctl "${args[@]}")
    return 0
  fi
  # RKE2 : etcd tourne en static pod → on utilise l'etcdctl du conteneur.
  local cid
  cid=$(cri ps --name '^etcd$' --state running -q 2>/dev/null | head -1)
  if [[ -n "$cid" ]]; then
    ETCDCTL=("${CRICTL[@]}" exec "$cid" etcdctl "${args[@]}")
    return 0
  fi
  return 1
}

clean_etcd() {
  section "Datastore du control-plane (etcd)"
  local db_dir="$DATA_DIR/server/db"

  if [[ -f "$db_dir/state.db" && ! -d "$db_dir/etcd" ]]; then
    info "Datastore SQLite (kine) : $db_dir/state.db = $(human "$(stat -c %s "$db_dir/state.db")")"
    warn "Un VACUUM SQLite nécessite d'arrêter $DISTRO_BIN — non automatisé :"
    log  "    systemctl stop $DISTRO_BIN && sqlite3 $db_dir/state.db 'VACUUM;' && systemctl start $DISTRO_BIN"
    return
  fi
  if [[ ! -d "$db_dir/etcd" ]]; then
    info "Pas de base etcd locale (datastore externe ?) — section ignorée."
    return
  fi

  info "Taille de $db_dir/etcd : $(human "$(dir_size "$db_dir/etcd")")"
  if [[ -d "$db_dir/snapshots" ]]; then
    local n
    n=$(find "$db_dir/snapshots" -maxdepth 1 -type f | wc -l)
    info "Snapshots locaux : $n fichier(s), $(human "$(dir_size "$db_dir/snapshots")") (conservés : $ETCD_SNAPSHOT_RETENTION)"
  fi

  local have_etcdctl=0
  if etcdctl_cmd; then
    have_etcdctl=1
    "${ETCDCTL[@]}" endpoint status -w table 2>/dev/null || warn "endpoint status indisponible"
    local alarms
    alarms=$("${ETCDCTL[@]}" alarm list 2>/dev/null)
    [[ -n "$alarms" ]] && warn "Alarmes etcd actives : $alarms"
  else
    warn "etcdctl introuvable : défragmentation impossible (installer etcdctl pour k3s)."
  fi

  if [[ $APPLY -eq 1 ]] && ! confirm "Purger les snapshots etcd (garder $ETCD_SNAPSHOT_RETENTION)$([[ $ETCD_DEFRAG -eq 1 && $have_etcdctl -eq 1 ]] && echo ' et défragmenter etcd (bloque brièvement ce membre)') ?"; then
    info "Section ignorée."; return
  fi

  run "$DISTRO_BIN" etcd-snapshot prune --snapshot-retention "$ETCD_SNAPSHOT_RETENTION"

  if [[ $ETCD_DEFRAG -eq 1 && $have_etcdctl -eq 1 ]]; then
    # Défragmente uniquement le membre local (127.0.0.1) : en HA, relancer le
    # script sur chaque master l'un après l'autre.
    run "${ETCDCTL[@]}" defrag --command-timeout=60s
    if [[ -n "${alarms:-}" ]]; then run "${ETCDCTL[@]}" alarm disarm; fi
    [[ $APPLY -eq 1 ]] && "${ETCDCTL[@]}" endpoint status -w table 2>/dev/null
  fi
  ok "etcd traité."
}

# =============================================================================
# 4. LONGHORN — validation obligatoire élément par élément
# =============================================================================
clean_longhorn() {
  section "Longhorn (volumes & données orphelins)"
  if [[ $HAVE_K8S -eq 0 ]]; then warn "API injoignable — ignoré."; return; fi
  if ! k get crd volumes.longhorn.io >/dev/null 2>&1; then info "Longhorn non installé — ignoré."; return; fi

  [[ -d /var/lib/longhorn ]] && info "Taille de /var/lib/longhorn sur ce nœud : $(human "$(dir_size /var/lib/longhorn)")"

  # ---- 4a. Volumes détachés sans PV/PVC valide (niveau cluster)
  local pvs
  pvs=$(k get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  local cols='NAME:.metadata.name,STATE:.status.state,SIZE:.spec.size,ACTUAL:.status.actualSize,PV:.status.kubernetesStatus.pvName,PVSTATUS:.status.kubernetesStatus.pvStatus,NS:.status.kubernetesStatus.namespace,PVC:.status.kubernetesStatus.pvcName,LASTPOD:.status.kubernetesStatus.lastPodRefAt'
  local candidates=() line name state size actual pv pvstatus ns pvc lastpod reason
  while read -r name state size actual pv pvstatus ns pvc lastpod; do
    [[ "$state" == "detached" ]] || continue
    reason=""
    if [[ "$pv" == "<none>" || -z "$pv" ]]; then
      reason="aucun PV associé"
    elif ! grep -qxF "$pv" <<<"$pvs"; then
      reason="PV $pv supprimé"
    elif [[ "$pvstatus" == "Released" ]]; then
      reason="PV $pv Released (PVC $ns/$pvc supprimé)"
    fi
    [[ -n "$reason" ]] || continue
    candidates+=("$name|$size|$actual|$pv|$reason|$lastpod")
  done < <(k -n "$LONGHORN_NS" get volumes.longhorn.io -o custom-columns="$cols" --no-headers 2>/dev/null)

  if [[ ${#candidates[@]} -eq 0 ]]; then
    ok "Aucun volume Longhorn orphelin."
  else
    info "${#candidates[@]} volume(s) Longhorn orphelin(s) :"
    printf '    %-42s %10s %10s  %s\n' VOLUME TAILLE UTILISÉ RAISON
    for line in "${candidates[@]}"; do
      IFS='|' read -r name size actual pv reason lastpod <<<"$line"
      printf '    %-42s %10s %10s  %s (dernier pod : %s)\n' \
        "$name" "$(human "$size")" "$(human "${actual/<none>/0}")" "$reason" "$lastpod"
    done

    if [[ $APPLY -eq 1 ]]; then
      warn "La suppression d'un volume Longhorn détruit DÉFINITIVEMENT ses données et répliques."
      for line in "${candidates[@]}"; do
        IFS='|' read -r name size actual pv reason lastpod <<<"$line"
        if confirm "Supprimer le volume Longhorn « $name » ($reason) ?" force; then
          # Re-vérification juste avant suppression (état a pu changer).
          if [[ "$(k -n "$LONGHORN_NS" get volumes.longhorn.io "$name" -o jsonpath='{.status.state}' 2>/dev/null)" != "detached" ]]; then
            warn "$name n'est plus détaché — ignoré."; continue
          fi
          if [[ "$pv" != "<none>" && -n "$pv" ]] && grep -qxF "$pv" <<<"$pvs"; then
            k delete pv "$pv" --wait=false || warn "Échec suppression PV $pv"
          fi
          k -n "$LONGHORN_NS" delete volumes.longhorn.io "$name" --wait=false \
            && ok "Volume $name supprimé." || warn "Échec suppression $name"
        else
          info "Conservé : $name"
        fi
      done
    else
      dry "kubectl delete pv <pv> ; kubectl -n $LONGHORN_NS delete volumes.longhorn.io <volume>  (validation par volume)"
    fi
  fi

  # ---- 4b. Données orphelines sur disque (répliques non référencées) de ce nœud
  if k get crd orphans.longhorn.io >/dev/null 2>&1; then
    local orphans=() o_name o_node o_data o_disk
    while read -r o_name o_node o_data o_disk; do
      [[ "$o_node" == "$NODE_NAME" ]] || continue
      orphans+=("$o_name|$o_data|$o_disk")
    done < <(k -n "$LONGHORN_NS" get orphans.longhorn.io --no-headers \
               -o custom-columns='N:.metadata.name,NODE:.spec.nodeID,DATA:.spec.parameters.DataName,DISK:.spec.parameters.DiskPath' 2>/dev/null)

    if [[ ${#orphans[@]} -eq 0 ]]; then
      ok "Aucune donnée orpheline Longhorn sur $NODE_NAME."
      info "(La détection nécessite le setting « orphan-auto-deletion » désactivé et Longhorn ≥ 1.3.)"
    else
      info "${#orphans[@]} réplique(s) orpheline(s) sur $NODE_NAME :"
      for line in "${orphans[@]}"; do
        IFS='|' read -r o_name o_data o_disk <<<"$line"
        local p="$o_disk/replicas/$o_data"
        printf '    %-50s %10s  %s\n' "$o_name" "$( [[ -d $p ]] && human "$(dir_size "$p")" || echo '?')" "$p"
      done
      if [[ $APPLY -eq 1 ]]; then
        for line in "${orphans[@]}"; do
          IFS='|' read -r o_name o_data o_disk <<<"$line"
          if confirm "Supprimer la donnée orpheline « $o_data » ($o_disk) ?" force; then
            k -n "$LONGHORN_NS" delete orphans.longhorn.io "$o_name" \
              && ok "Orphan $o_name supprimé (Longhorn efface les fichiers)." || warn "Échec $o_name"
          fi
        done
      else
        dry "kubectl -n $LONGHORN_NS delete orphans.longhorn.io <orphan>  (validation par élément)"
      fi
    fi
  fi
}

# =============================================================================
# 5. KUBERNETES — pods terminés
# =============================================================================
clean_k8s() {
  section "Pods terminés (cluster)"
  if [[ $HAVE_K8S -eq 0 ]]; then warn "API injoignable — ignoré."; return; fi
  local failed succeeded
  failed=$(k get pods -A --field-selector=status.phase==Failed --no-headers 2>/dev/null | wc -l)
  succeeded=$(k get pods -A --field-selector=status.phase==Succeeded --no-headers 2>/dev/null | wc -l)
  info "Pods Failed/Evicted : $failed — Pods Succeeded (Jobs terminés) : $succeeded"
  if [[ $((failed + succeeded)) -eq 0 ]]; then ok "Rien à nettoyer."; return; fi
  if [[ $failed -gt 0 ]]; then
    k get pods -A --field-selector=status.phase==Failed --no-headers 2>/dev/null | head -15 | sed 's/^/    /'
  fi
  if [[ $APPLY -eq 1 ]] && ! confirm "Supprimer ces pods terminés (les Jobs/CronJobs restent intacts) ?"; then
    info "Section ignorée."; return
  fi
  [[ $failed -gt 0 ]]    && run "${KUBECTL[@]}" delete pods -A --field-selector=status.phase==Failed --wait=false
  [[ $succeeded -gt 0 ]] && run "${KUBECTL[@]}" delete pods -A --field-selector=status.phase==Succeeded --wait=false
}

# =============================================================================
# 6. SYSTÈME
# =============================================================================
clean_system() {
  section "Système"
  local pm=""
  if command -v apt-get >/dev/null 2>&1; then pm="apt"
  elif command -v dnf >/dev/null 2>&1; then pm="dnf"
  elif command -v zypper >/dev/null 2>&1; then pm="zypper"; fi

  case "$pm" in
    apt)    info "Cache apt : $(human "$(dir_size /var/cache/apt/archives)")" ;;
    dnf)    info "Cache dnf : $(human "$(dir_size /var/cache/dnf)")" ;;
    zypper) info "Cache zypper : $(human "$(dir_size /var/cache/zypp)")" ;;
  esac
  local cores=/var/lib/systemd/coredump
  [[ -d $cores ]] && info "Coredumps : $(human "$(dir_size $cores)")"

  if [[ $APPLY -eq 1 ]] && ! confirm "Vider le cache paquets et les coredumps ?"; then
    info "Section ignorée."; return
  fi
  case "$pm" in
    apt)    run apt-get clean ;;
    dnf)    run dnf clean all ;;
    zypper) run zypper clean --all ;;
  esac
  if [[ -d $cores ]]; then
    if [[ $APPLY -eq 1 ]]; then find "$cores" -type f -delete; else dry "rm $cores/*"; fi
  fi
}

# ------------------------------------------------------------------ main --
want images   && clean_images
want logs     && clean_logs
want etcd     && clean_etcd
want longhorn && clean_longhorn
want k8s      && clean_k8s
want system   && clean_system

section "Espace disque final"
disk_report
[[ $APPLY -eq 0 ]] && info "Mode dry-run : rien n'a été modifié. Relancer avec --apply pour nettoyer."
exit 0
