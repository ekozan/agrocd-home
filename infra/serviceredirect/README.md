# serviceredirect : services du NAS derrière Traefik

Namespace `serviceredirect`, repris par ArgoCD (App `serviceredirect`, `infra/14-serviceredirect.yaml`) ; anciennement géré par Rancher :

- Service `nasv2` (headless) + Endpoints → NAS `10.10.0.245`
- Ingress `homeserveringress` (classe `traefik`, TLS `ffd-link-tls`) : un hôte
  `*.ffd.link` par service. `home.ffd.link` pointe vers `homev2` (Home Assistant, Endpoints `10.10.0.244:8123`).

Objectif : plus d'exposition publique. Accès **local** (LAN) ou **NetBird**.

| Hôte | Port NAS | Appli | Distant (hors LAN) |
|------|----------|-------|--------------------|
| `jellyfin.ffd.link` | 8096 | Jellyfin | app → client NetBird ; navigateur → proxy |
| `jellyseerr.ffd.link` | 30042 | Jellyseerr | proxy (SSO) |
| `ente.ffd.link` | 3000 | Ente web | proxy (SSO) |
| `ente-albums.ffd.link` | 3002 | Albums partagés (**public**) | public (liens de partage) |
| `ente-api.ffd.link` | 8090 | API Ente (apps mobiles) | client NetBird ; **chemins de partage publics** (cf. § Partage Ente) |
| `s3.ffd.link` | 9000 | S3 (URL présignées Ente) | **public** si l'endpoint S3 de museum est `s3.ffd.link` (cf. § Partage Ente) |
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

`homeserveringress` utilise `local-only-cluster` (et non `local-only`) : les pairs
NetBird atteignent Traefik via le routeur du cluster, qui fait du masquerade ;
Traefik voit alors une IP de pod `10.42.x.x` (constaté dans les logs d'accès).

Un middleware s'applique à tout l'Ingress : openbao et le partage Ente (albums,
S3) ont donc leur propre Ingress. Tout est dans Git (`ingress.yaml`,
`nasv2.yaml`) et géré par l'Application ArgoCD `serviceredirect`
(`infra/14-serviceredirect.yaml`).

### Reprise par ArgoCD (noms identiques, pas de doublon d'hôtes)

Les manifests gardent les noms des objets Rancher (`nasv2`, `homeserveringress`) :
ArgoCD les **adopte** au lieu d'en créer de nouveaux, donc aucun hôte en double
et pas de coupure. À la première sync :

1. wave 0 : création des Ingress `openbao` et `ente-share` ;
2. wave 1 : `homeserveringress` perd les hôtes openbao, ente-albums et s3 (déjà
   servis par leur Ingress) et gagne `local-only`.

Les objets gardent `Delete=false` : supprimer l'Application ArgoCD ne supprime ni
le Service, ni les Endpoints, ni les Ingress.

Hors périmètre ArgoCD (reste géré à la main) : le Service et les Endpoints
`homev2` (Home Assistant, `10.10.0.244:8123`). L'Ingress y fait seulement
référence.

Avant de merger :

```bash
kubectl -n serviceredirect get svc,endpoints,ing          # état actuel
kubectl -n argocd get application serviceredirect         # absent : créé par l'app `infra`
```

Après la sync (facultatif) : retirer les métadonnées Rancher devenues inutiles
(`objectset.rio.cattle.io/*`) pour qu'il ne les réapplique pas, et éviter toute
modification via l'UI Rancher.

Retour arrière : retirer l'annotation `traefik.ingress.kubernetes.io/router.middlewares`
dans `ingress.yaml` (ou `kubectl -n serviceredirect annotate ing homeserveringress traefik.ingress.kubernetes.io/router.middlewares-`,
ArgoCD la remettra tant que le commit est en place).

### Partage Ente (liens publics)

Les destinataires d'un lien de partage n'ont ni compte ni NetBird. Ils utilisent :

- `ente-albums.ffd.link` : visionneuse web des albums partagés ;
- `ente-api.ffd.link`, **uniquement** `/public-collection/*`, `/file-link/*`, `/public-memory/*` et `/ping` (routes publiques de museum) ; le reste de l'API (compte, albums privés) reste en `local-only` ;
- `s3.ffd.link` : téléchargement des photos par URL S3 présignées.

Traefik donne la priorité à la règle la plus longue : le routeur `Host + PathPrefix` de `ente-share` l'emporte sur le routeur `Host` seul de `homeserveringress`.

L'endpoint S3 de museum est bien `s3.ffd.link` (confirmé). Protéger les liens dans Ente (mot de passe, expiration).

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

Dashboard NetBird → **Networks** : ressources `10.10.0.245/32` (NAS) et
`10.10.0.244/32` (Home Assistant), réseau routé par `netbird-k8s-router`. Puis **Reverse Proxy → Services → Add Service**, un par
ligne « proxy (SSO) » du tableau :

| Domaine | Cible | Port |
|---------|-------|------|
| `jellyseerr.proxy.ffd.link` | `10.10.0.245` | 30042 |
| `ente.proxy.ffd.link` | `10.10.0.245` | 3000 |
| `s3-console.proxy.ffd.link` | `10.10.0.245` | 9002 |
| `nas.proxy.ffd.link` | `10.10.0.245` | 80 |
| `openbao.proxy.ffd.link` | `10.10.0.245` | 14000 |
| `homebox.proxy.ffd.link` / `komga.proxy.ffd.link` | `10.10.0.245` | 30149 / 30048 |
| `home.proxy.ffd.link` | `10.10.0.244` | 8123 |
| `jellyfin.proxy.ffd.link` (optionnel) | `10.10.0.245` | 8096 |

Home Assistant : derrière un reverse proxy, `configuration.yaml` doit déclarer
`http: use_x_forwarded_for: true` et `trusted_proxies` (IP du proxy/routeur
NetBird), sinon HA répond 400. L'application mobile Home Assistant passe
par le client NetBird plutôt que par le SSO du proxy.

Protocole `http`, authentification **SSO** (Zitadel). Pour OpenBao (qui est en
HTTPS), vérifier le schéma attendu par le backend.

## 4. Vérifier

- Depuis le LAN : `curl -I https://jellyfin.ffd.link` → 200/302.
- Depuis la 4G sans NetBird : 403.
- Téléphone avec NetBird : application Jellyfin / Ente / Vaultwarden OK.
- Navigateur distant : `https://nas.proxy.ffd.link` → login SSO.
- Partage Ente : ouvrir un lien d'album depuis la 4G sans NetBird → l'album s'affiche, photos comprises ; `curl -I https://ente-api.ffd.link/` depuis la 4G → 403.
- External Secrets : `kubectl get clustersecretstore openbao-backend` → `Valid`, et
  `kubectl get externalsecret -A` sans erreur.
