#!/usr/bin/env bash
# Fait passer les pulls d'images des nœuds k3s par le cache Zot du NAS.
# À lancer en root sur CHAQUE nœud (server et agents). Idempotent.
#
# Le NAS est joint par IP : un pull d'image déjà en cache ne fait aucune
# requête DNS. Si le cache ne répond pas, containerd retombe tout seul sur le
# registre d'origine (endpoint par défaut toujours essayé en dernier).
#
# Usage : sudo ./k3s-registries.sh
#         sudo ZOT_URL=http://10.10.0.245:5000 ./k3s-registries.sh
set -euo pipefail

ZOT_URL="${ZOT_URL:-http://10.10.0.245:5000}"
REGISTRIES=(docker.io quay.io ghcr.io registry.k8s.io)
FILE=/etc/rancher/k3s/registries.yaml

[ "$(id -u)" -eq 0 ] || { echo "À lancer en root." >&2; exit 1; }

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ZOT_URL/v2/" || true)
case "$code" in
  200|401) echo "Cache joignable ($ZOT_URL, HTTP $code)." ;;
  *) echo "ATTENTION : $ZOT_URL/v2/ ne répond pas (HTTP '$code'). On configure quand même :" \
          "containerd passera par les registres d'origine tant que le cache est absent." >&2 ;;
esac

mkdir -p "$(dirname "$FILE")"
if [ -f "$FILE" ] && ! grep -q "node-setup/k3s-registries.sh" "$FILE"; then
  cp "$FILE" "$FILE.pre-zot"
  echo "Ancien $FILE sauvegardé dans $FILE.pre-zot."
fi

{
  echo "# Géré par node-setup/k3s-registries.sh (agrocd-home) — ne pas éditer"
  echo "mirrors:"
  for r in "${REGISTRIES[@]}"; do
    cat <<EOF
  $r:
    endpoint:
      - "$ZOT_URL"
    # Zot range chaque registre sous un préfixe (docker.io/library/nginx…).
    rewrite:
      "^(.*)\$": "$r/\$1"
EOF
  done
} > "$FILE"

if systemctl is-enabled --quiet k3s 2>/dev/null; then
  systemctl restart k3s && echo "k3s (server) redémarré."
elif systemctl is-enabled --quiet k3s-agent 2>/dev/null; then
  systemctl restart k3s-agent && echo "k3s-agent redémarré."
fi
echo "Fait. Vérification : crictl pull docker.io/library/busybox:latest puis consulter les logs de Zot."
