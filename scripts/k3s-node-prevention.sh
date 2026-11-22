#!/usr/bin/env bash
# =============================================================================
# k3s-node-prevention.sh — Garde-fous d'un nœud k3s (suite incident 22/11)
# =============================================================================
#
# Écrit des fichiers de configuration « drop-in » (sans toucher aux fichiers
# principaux) pour éviter qu'un disque plein ne fasse tomber le cluster :
#
#   /etc/rancher/k3s/config.yaml.d/90-prevention.yaml
#     - kube-controller-manager : terminated-pod-gc-threshold=500
#         (sans ça, les pods morts ne sont purgés qu'au-delà de 12 500 : le
#          22/11, 10 047 pods Traefik évincés ont saturé etcd et l'API)
#     - kubelet : nettoyage des images dès 75 % (au lieu de 85 %),
#                 rotation des logs de conteneurs (20 Mi × 3 fichiers)
#     (clés suffixées « + » : AJOUTÉES aux arguments existants, rien n'est écrasé)
#
#   /etc/systemd/journald.conf.d/90-size.conf
#     - journald limité à 500 Mo (3,9 Go constatés sur kube2)
#
# Par défaut : DRY-RUN (affiche ce qui serait écrit). --apply pour écrire.
# Le script ne redémarre PAS k3s : la config k3s ne s'applique qu'au prochain
# redémarrage, à faire UN NŒUD À LA FOIS (cf. message final). journald est
# rechargé immédiatement (sans impact).
#
#   sudo ./k3s-node-prevention.sh            # aperçu
#   sudo ./k3s-node-prevention.sh --apply    # écrit les fichiers
# =============================================================================

set -euo pipefail

APPLY=0
POD_GC_THRESHOLD=500
IMAGE_GC_HIGH=75
IMAGE_GC_LOW=60
LOG_MAX_SIZE="20Mi"
LOG_MAX_FILES=3
JOURNAL_MAX="500M"

for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $a" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "À lancer en root (sudo)." >&2; exit 1; }
[[ -d /etc/rancher/k3s ]] || { echo "k3s non détecté (/etc/rancher/k3s absent)." >&2; exit 1; }

IS_SERVER=0
systemctl is-enabled --quiet k3s 2>/dev/null && IS_SERVER=1

K3S_DROPIN=/etc/rancher/k3s/config.yaml.d/90-prevention.yaml
JOURNAL_DROPIN=/etc/systemd/journald.conf.d/90-size.conf

k3s_conf() {
  echo "# Géré par scripts/k3s-node-prevention.sh (agrocd-home) — incident du 22/11"
  if [[ $IS_SERVER -eq 1 ]]; then
    echo "kube-controller-manager-arg+:"
    echo "  - \"terminated-pod-gc-threshold=${POD_GC_THRESHOLD}\""
  fi
  cat <<EOF
kubelet-arg+:
  - "image-gc-high-threshold=${IMAGE_GC_HIGH}"
  - "image-gc-low-threshold=${IMAGE_GC_LOW}"
  - "container-log-max-size=${LOG_MAX_SIZE}"
  - "container-log-max-files=${LOG_MAX_FILES}"
EOF
}

journal_conf() {
  cat <<EOF
# Géré par scripts/k3s-node-prevention.sh (agrocd-home)
[Journal]
SystemMaxUse=${JOURNAL_MAX}
EOF
}

# Écrit un fichier seulement s'il change ; renvoie 0 si modifié.
write_file() {
  local path="$1" content="$2"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
    echo "[=] $path déjà à jour"
    return 1
  fi
  echo "[~] $path :"
  printf '%s\n' "$content" | sed 's/^/      /'
  if [[ $APPLY -eq 1 ]]; then
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    echo "    → écrit"
  fi
  return 0
}

echo "== Nœud $(hostname) — $([[ $IS_SERVER -eq 1 ]] && echo master || echo agent) — mode $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"

# Conflits possibles avec la config principale (mêmes options déjà définies).
if grep -qsE "terminated-pod-gc-threshold|image-gc-(high|low)-threshold|container-log-max" \
     /etc/rancher/k3s/config.yaml /etc/systemd/system/k3s*.service; then
  echo "[!] Certaines de ces options existent déjà dans config.yaml ou le service k3s :"
  grep -nsE "terminated-pod-gc-threshold|image-gc-(high|low)-threshold|container-log-max" \
     /etc/rancher/k3s/config.yaml /etc/systemd/system/k3s*.service | sed 's/^/      /'
  echo "    Vérifier qu'elles ne se contredisent pas avant de redémarrer k3s."
fi

K3S_CHANGED=0
write_file "$K3S_DROPIN" "$(k3s_conf)" && K3S_CHANGED=1 || true
if write_file "$JOURNAL_DROPIN" "$(journal_conf)" && [[ $APPLY -eq 1 ]]; then
  systemctl restart systemd-journald && journalctl --vacuum-size="$JOURNAL_MAX" >/dev/null 2>&1 || true
  echo "    → journald rechargé : $(journalctl --disk-usage 2>/dev/null)"
fi

if [[ $APPLY -eq 0 ]]; then
  echo
  echo "Dry-run : rien n'a été écrit. Relancer avec --apply."
elif [[ $K3S_CHANGED -eq 1 ]]; then
  cat <<'EOF'

La configuration k3s s'appliquera au prochain redémarrage de k3s.
À faire UN NŒUD À LA FOIS, cluster calme, en vérifiant etcd entre chaque :

  sudo systemctl restart k3s
  # attendre que le nœud soit Ready :
  sudo k3s kubectl get nodes
  # santé d'etcd locale (masters) :
  sudo curl -s --cacert /var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
    --cert /var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
    --key /var/lib/rancher/k3s/server/tls/etcd/server-client.key \
    https://127.0.0.1:2379/health

Vérifier ensuite que les options sont actives (k3s les journalise au démarrage) :
  sudo journalctl -u k3s -b --no-pager | grep -oE "(terminated-pod-gc-threshold|image-gc-high-threshold|container-log-max-size)=[^ ]+" | sort -u
EOF
fi
