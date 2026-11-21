#!/usr/bin/env bash
# Rend le DNS du cluster k3s indépendant du resolver fourni par le réseau
# (DHCP / box / OPNsense). À lancer en root sur CHAQUE nœud (server et agents).
# Idempotent : peut être relancé sans risque.
#
# Deux consommateurs de DNS sont concernés :
#   1. CoreDNS (DNS des pods) : il transfère par défaut vers le resolv.conf de
#      l'hôte. On donne à k3s un resolv.conf dédié (--resolv-conf) qui ne pointe
#      que vers des resolvers publics.
#   2. containerd (pull des images, ex. quay.io) : il tourne sur l'hôte et lit
#      /etc/resolv.conf. Aucun réglage Kubernetes ne peut changer ça : on fixe
#      donc les resolvers de l'hôte lui-même.
#
# Usage : sudo ./k3s-dns.sh            (resolvers par défaut)
#         sudo DNS_SERVERS="1.1.1.1 8.8.8.8" ./k3s-dns.sh
set -euo pipefail

DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 9.9.9.9 1.0.0.1}"
K3S_DIR=/etc/rancher/k3s
K3S_RESOLV="$K3S_DIR/resolv.conf"
K3S_DROPIN="$K3S_DIR/config.yaml.d/50-dns.yaml"

[ "$(id -u)" -eq 0 ] || { echo "À lancer en root." >&2; exit 1; }

# --- 1. resolv.conf dédié à k3s (CoreDNS + pods en dnsPolicy: Default) -------
mkdir -p "$(dirname "$K3S_DROPIN")"
{
  echo "# Géré par node-setup/k3s-dns.sh (agrocd-home) — ne pas éditer"
  # 3 serveurs max : limite de la libc et du kubelet.
  for s in $DNS_SERVERS; do echo "nameserver $s"; done | head -n 3
} > "$K3S_RESOLV"

cat > "$K3S_DROPIN" <<EOF
# Géré par node-setup/k3s-dns.sh (agrocd-home)
resolv-conf: $K3S_RESOLV
EOF

# --- 2. Resolvers de l'hôte (containerd / pull des images) --------------------
if systemctl is-active --quiet systemd-resolved; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/50-static-dns.conf <<EOF
# Géré par node-setup/k3s-dns.sh (agrocd-home)
[Resolve]
DNS=$DNS_SERVERS
FallbackDNS=8.8.8.8 149.112.112.112
# Route tous les domaines vers les serveurs ci-dessus, en plus du DNS annoncé
# par le DHCP : une panne du DNS local ne bloque plus la résolution.
Domains=~.
EOF
  systemctl restart systemd-resolved
  echo "systemd-resolved : resolvers fixés ($DNS_SERVERS)."
else
  if systemctl is-active --quiet NetworkManager; then
    mkdir -p /etc/NetworkManager/conf.d
    printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/50-static-dns.conf
    systemctl reload NetworkManager
  fi
  # Remplace un éventuel lien symbolique géré par un autre outil.
  if [ -e /etc/resolv.conf ] && [ ! -e /etc/resolv.conf.pre-k3s-dns ]; then
    cp -L /etc/resolv.conf /etc/resolv.conf.pre-k3s-dns
  fi
  rm -f /etc/resolv.conf
  cp "$K3S_RESOLV" /etc/resolv.conf
  echo "/etc/resolv.conf statique écrit (sauvegarde : /etc/resolv.conf.pre-k3s-dns)."
fi

# --- 3. Redémarrage de k3s (les pods en cours ne sont pas interrompus) -------
if systemctl is-enabled --quiet k3s 2>/dev/null; then
  systemctl restart k3s
  echo "k3s (server) redémarré."
  echo "Une fois TOUS les nœuds traités, recréer CoreDNS pour qu'il relise son resolv.conf :"
  echo "  kubectl -n kube-system rollout restart deployment coredns"
elif systemctl is-enabled --quiet k3s-agent 2>/dev/null; then
  systemctl restart k3s-agent
  echo "k3s-agent redémarré."
fi

# --- 4. Vérification ----------------------------------------------------------
if getent hosts quay.io >/dev/null; then
  echo "OK : l'hôte résout quay.io."
else
  echo "ATTENTION : l'hôte ne résout toujours pas quay.io (port 53 sortant bloqué par le pare-feu ?)." >&2
  exit 1
fi
