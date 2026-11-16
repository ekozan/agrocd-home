# serviceredirect : services du NAS derrière Traefik

Namespace `serviceredirect`, **géré par Rancher** (pas par ArgoCD) :

- Service `nasv2` (headless) + Endpoints → NAS `10.10.0.245`
- Ingress `homeserveringress` (classe `traefik`, TLS `ffd-link-tls`) : un hôte
  `*.ffd.link` par service. `home.ffd.link` pointe vers `homev2` (Home Assistant).

Objectif : plus d'exposition publique. Accès **local** (LAN) ou **NetBird**.

| Hôte | Port NAS | Appli | Distant (hors LAN) |
|------|----------|-------|--------------------|
| `jellyfin.ffd.link` | 8096 | Jellyfin | app → client NetBird ; navigateur → proxy |
| `jellyseerr.ffd.link` | 30042 | Jellyseerr | proxy (SSO) |
| `ente.ffd.link` / `ente-albums.ffd.link` | 3000 / 3002 | Ente web / albums | proxy (SSO) |
| `ente-api.ffd.link` | 8090 | API Ente (apps mobiles) | client NetBird uniquement |
| `s3.ffd.link` | 9000 | API S3 | client NetBird uniquement |
| `s3-console.ffd.link` | 9002 | Console S3 | proxy (SSO) |
| `nas.ffd.link` | 80 | UI du NAS | proxy (SSO) |
| `vault.ffd.link` | 20080 | Vaultwarden (apps/extensions) | client NetBird uniquement |
| `openbao.ffd.link` | 14000 | OpenBao | proxy (SSO) ; **appelé par External Secrets** |
| `homebox.ffd.link` / `komga.ffd.link` | 30149 / 30048 | Homebox / Komga | proxy (SSO) |
| `home.ffd.link` | 8123 (`homev2`) | Home Assistant | app → client NetBird ; navigateur → proxy |

> Une API (apps mobiles, clients S3/Vaultwarden/Ente) ne sait pas faire le SSO
> web du proxy : elle passe par le client NetBird. Le navigateur passe par
> `<svc>.proxy.ffd.link` (SSO Zitadel).

## 1. Local only (Traefik)

Middlewares dans `init/03-traefik-middlewares.yaml` :
`local-only` (LAN `10.10/16`, `10.5/16`, pairs NetBird `100.64/10`) et
`local-only-cluster` (+ pods `10.42/16`, pour openbao : External Secrets l'appelle
depuis le cluster via `https://openbao.ffd.link`).

Un middleware s'applique à tout l'Ingress : openbao est donc sorti dans son
propre Ingress. **À faire avec `kubectl`** (pas dans l'UI Rancher, qui pourrait
écraser les modifications), **dans cet ordre** et après le merge/sync de la PR :

```bash
# 1. Ingress dédié openbao (local-only-cluster)
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openbao
  namespace: serviceredirect
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: traefik-crowdsec@kubernetescrd,traefik-local-only-cluster@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
    - host: openbao.ffd.link
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: nasv2, port: {number: 14000}}
  tls:
    - hosts: ["*.ffd.link"]
      secretName: ffd-link-tls
YAML

# 2. Retirer la règle openbao de l'Ingress principal
idx=$(kubectl -n serviceredirect get ing homeserveringress -o json \
  | jq '.spec.rules | map(.host) | index("openbao.ffd.link")')
kubectl -n serviceredirect patch ing homeserveringress --type json \
  -p "[{\"op\":\"remove\",\"path\":\"/spec/rules/$idx\"}]"

# 3. Restreindre tous les autres hôtes
kubectl -n serviceredirect annotate ing homeserveringress --overwrite \
  traefik.ingress.kubernetes.io/router.middlewares=traefik-crowdsec@kubernetescrd,traefik-local-only@kubernetescrd
```

Retour arrière : `kubectl -n serviceredirect annotate ing homeserveringress traefik.ingress.kubernetes.io/router.middlewares-`

## 2. DNS pour le LAN et les pairs NetBird

`*.ffd.link` est public : depuis l'extérieur il résout vers l'IP publique, et la
requête arriverait avec une IP source publique (403). Il faut que ces noms
résolvent vers Traefik (`10.100.0.1`) :

- **LAN** : split DNS (Unbound OPNsense) `*.ffd.link` → `10.100.0.1`.
- **Pairs NetBird (téléphone)** : dashboard NetBird → **DNS → Nameservers**
  (ou zone DNS personnalisée) pour `ffd.link` vers le résolveur du LAN, et une
  route/ressource vers `10.100.0.1/32` (même principe que le routeur
  `netbird-k8s-router`).

## 3. Accès navigateur : reverse proxy NetBird

Dashboard NetBird → **Networks** : ressource `10.10.0.245/32` (réseau routé par
`netbird-k8s-router`). Puis **Reverse Proxy → Services → Add Service**, un par
ligne « proxy (SSO) » du tableau :

| Domaine | Cible | Port |
|---------|-------|------|
| `jellyseerr.proxy.ffd.link` | `10.10.0.245` | 30042 |
| `ente.proxy.ffd.link` / `ente-albums.proxy.ffd.link` | `10.10.0.245` | 3000 / 3002 |
| `s3-console.proxy.ffd.link` | `10.10.0.245` | 9002 |
| `nas.proxy.ffd.link` | `10.10.0.245` | 80 |
| `openbao.proxy.ffd.link` | `10.10.0.245` | 14000 |
| `homebox.proxy.ffd.link` / `komga.proxy.ffd.link` | `10.10.0.245` | 30149 / 30048 |
| `jellyfin.proxy.ffd.link` (optionnel) | `10.10.0.245` | 8096 |

Protocole `http`, authentification **SSO** (Zitadel). Pour OpenBao (qui est en
HTTPS), vérifier le schéma attendu par le backend.

## 4. Vérifier

- Depuis le LAN : `curl -I https://jellyfin.ffd.link` → 200/302.
- Depuis la 4G sans NetBird : 403.
- Téléphone avec NetBird : application Jellyfin / Ente / Vaultwarden OK.
- Navigateur distant : `https://nas.proxy.ffd.link` → login SSO.
- External Secrets : `kubectl get clustersecretstore openbao-backend` → `Valid`, et
  `kubectl get externalsecret -A` sans erreur.
