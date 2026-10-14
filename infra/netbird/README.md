# NetBird + reverse proxy — instance de test

| Composant | URL | Image |
|-----------|-----|-------|
| Dashboard, API, management, signal, relay (**test**) | `https://netbird2.ffd.link` | `netbirdio/{management,signal,relay}:0.80.0`, `netbirdio/dashboard:v2.94.0` |
| Reverse proxy NetBird | `https://*.proxy.ffd.link` | `netbirdio/reverse-proxy:0.80.0` |

Déployé par l'Application ArgoCD `netbird2` (`infra/13-netbird.yaml`, sync-wave
13) dans le namespace `netbird2`, en manifests bruts (ex-chart
`totmicro/netbird` 1.8.2, plus publié depuis novembre 2025 et sans gestion du
reverse proxy).

**Phase de test** : l'instance de production reste la release Helm du
namespace `netbird` (`netbird.ffd.link`), à laquelle ArgoCD ne touche pas.
L'instance de test démarre avec une base vierge. Bascule : voir la dernière
section.

| Fichier | Rôle |
|---------|------|
| `externalsecrets.yaml` | Secrets `netbird` (wave -1) et `netbird-proxy-token` (wave 1) depuis OpenBao |
| `management.yaml` | ConfigMap `management.json`, PVC SQLite, Deployment, Service |
| `signal.yaml`, `relay.yaml`, `dashboard.yaml` | Deployment + Service de chaque composant |
| `ingressroute.yaml` | Route Traefik de `netbird2.ffd.link` (TLS terminé par Traefik, wildcard `*.ffd.link`) |
| `proxy.yaml` | Reverse proxy : PVC, Deployment, Service, passthrough TLS Traefik, NetworkPolicy |

## Architecture

```
Internet ──443──> OPNsense ──> IP LoadBalancer Traefik (externalTrafficPolicy: Local)
                                  │
                                  ├─ Host netbird2.ffd.link (router HTTP, TLS Traefik)
                                  │     └─> dashboard / management / signal / relay
                                  │
                                  └─ SNI proxy.ffd.link, *.proxy.ffd.link (router TCP,
                                     TLS passthrough + PROXY protocol v2)
                                        └─> netbird-proxy:8443 (TLS Let's Encrypt du proxy)
                                               ├─ gRPC interne ─> netbird-management:80
                                               └─ WireGuard (client embarqué) ─> pairs NetBird
```

Pas d'IP LoadBalancer dédiée : tout passe par le 443 de Traefik, qui aiguille
selon le SNI. Les autres hôtes `*.ffd.link` ne sont pas concernés.

## Mise en place

### 1. Secrets du serveur dans OpenBao (avant le merge)

Le dépôt est public : `management.json` contient des placeholders `{{ .VAR }}`,
résolus par le management depuis le Secret `netbird`. Tant que
`kv/kubernetes/netbird/server` est absent ou incomplet, la sync s'arrête à la
wave -1 et rien n'est démarré. Les valeurs de la production (namespace
`netbird`) conviennent aussi au test :

```bash
CFG=$(kubectl -n netbird get configmap netbird-management -o jsonpath='{.data.management\.json}')
sec() { kubectl -n netbird get secret netbird -o jsonpath="{.data.$1}" | base64 -d; }

bao kv put -mount=kv kubernetes/netbird/server \
  datastore_encryption_key="$(jq -r .DataStoreEncryptionKey <<<"$CFG")" \
  idp_service_user_secret="$(jq -r .IdpManagerConfig.ClientConfig.ClientSecret <<<"$CFG")" \
  turn_server_password="$(jq -r '.TURNConfig.Turns[0].Password' <<<"$CFG")" \
  relay_password="$(sec relayPassword)" \
  idp_client_id="$(sec idpClientID)"
```

> La clé `datastore_encryption_key` devra être **exactement** celle de la
> production au moment de la bascule (sinon la base de production devient
> illisible) : la reprendre telle quelle évite d'y penser plus tard.

### 2. DNS

| Type | Nom | Valeur |
|------|-----|--------|
| `A` | `netbird2.ffd.link` | IP publique |
| `A` | `proxy.ffd.link` | IP publique |
| `CNAME` | `*.proxy.ffd.link` | `proxy.ffd.link` |

Un wildcard `*.ffd.link` existant couvre déjà ces noms **tant que**
`proxy.ffd.link` n'a pas d'enregistrement propre. Rien à changer sur
l'OPNsense : le 443 arrive déjà sur Traefik. Le client NetBird embarqué dans le
proxy joint Signal et le relay via `netbird2.ffd.link` : le hairpin NAT (ou un
split DNS) doit fonctionner depuis le cluster.

### 3. Zitadel

Dans l'application NetBird de Zitadel (client `301166795920835005`), ajouter
les URI de `netbird2.ffd.link` à côté de celles de `netbird.ffd.link` :

- Redirect URIs : `https://netbird2.ffd.link/auth`,
  `https://netbird2.ffd.link/silent-auth`,
  `https://netbird2.ffd.link/api/reverse-proxy/callback` (SSO des services du proxy)
- Post logout URI : `https://netbird2.ffd.link/`

### 4. Merge, puis token du proxy

Après le merge, l'app `netbird2` démarre management, signal, relay et
dashboard. Le proxy attend son Secret : son token se crée **sur le management
de test** (il est stocké dans sa base ; un token créé sur la production ne
marche pas ici).

```bash
# Affiché une seule fois : garder « Token: nbx_… » (40 caractères), pas le Token ID
kubectl -n netbird2 exec deploy/netbird-management -- \
  /go/bin/netbird-mgmt admin token create --name proxy-k3s
```

Sur l'OPNsense : `cscli bouncers add netbird-proxy -o raw` (affiche la clé).

```bash
bao kv put -mount=kv kubernetes/netbird/proxy \
  token='nbx_…' crowdsec_api_key='<clé du bouncer>'
# Forcer la relecture d'OpenBao sans attendre le refreshInterval
kubectl -n netbird2 annotate externalsecret netbird-proxy-token force-sync="$(date +%s)" --overwrite
```

Gestion ultérieure : `… netbird-mgmt admin token list` / `admin token revoke <token-id>`.

### 5. Vérifier

```bash
kubectl -n netbird2 get externalsecret          # netbird et netbird-proxy-token : Ready
kubectl -n netbird2 logs deploy/netbird-management | head
kubectl -n netbird2 logs deploy/netbird-proxy -f
```

- `https://netbird2.ffd.link` : login Zitadel ; le premier utilisateur crée le
  compte (base vierge).
- Un client de test : `netbird up --management-url https://netbird2.ffd.link`
  (sur une machine ou un profil NetBird dédié : un client ne parle qu'à un
  management à la fois).
- Dashboard : **Reverse Proxy → Services → Add Service**, `proxy.ffd.link`
  apparaît avec le badge **Cluster** ; la page **Clusters** affiche **Private**
  et la prise en charge CrowdSec.

## Exposer un service

- **Public** (SSO Zitadel, PIN, mot de passe) : cible **Peer** ou **Resource**.
  Le proxy joint le backend par le tunnel WireGuard, il faut donc un pair (ou
  routing peer) qui atteint ce backend.
- **NetBird-Only** (joignable seulement par les pairs NetBird) : cible
  **Proxy Cluster** et hôte `<svc>.<ns>.svc.cluster.local`. Le proxy tourne
  dans le cluster et joint le service directement, sans pair supplémentaire.
  Nécessite `NB_PROXY_PRIVATE=true` (activé).
- **CrowdSec** : à activer par service (Access Control → enforce/observe). En
  `enforce`, tant que le bouncer n'a pas fait sa première synchro avec le LAPI,
  tout est refusé : commencer par `observe`.

## Notes

- **Pas de CrowdSec Traefik sur `*.proxy.ffd.link`** : en passthrough, Traefik ne
  voit pas le HTTP (ni bouncer, ni AppSec, ni access logs → pas de détection par
  l'agent). Seule la réputation IP du proxy s'applique.
- **Domaine personnalisé** (CNAME vers `proxy.ffd.link`) : l'ajouter au `match` de
  l'IngressRouteTCP, sinon Traefik le traite comme un hôte HTTP inconnu.
- **IP client réelle** : `NB_PROXY_TRUSTED_PROXIES=10.42.0.0/16` suppose le CIDR
  de pods par défaut de k3s/RKE2 (`kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'`).
  Le proxy exige un header PROXY de ces IP ; la NetworkPolicy réserve donc le
  8443 à Traefik.
- **Mises à jour** : Renovate suit les `image:` ; management, signal, relay et
  reverse proxy arrivent dans une seule PR (groupe `netbird`) pour garder le
  proxy au même tag que le management. Le dashboard est versionné à part.
- **Modifier `management.json`** : incrémenter l'annotation
  `netbird.ffd.link/config-revision` du Deployment dans le même commit, sinon
  le management garde l'ancienne config jusqu'à son prochain redémarrage.
- **Services TCP/UDP** (ports dédiés) : non exposés (`NB_PROXY_SUPPORTS_CUSTOM_PORTS=false`).
  Il faudrait un Service LoadBalancer pour ces ports + un port forward OPNsense.
- ⚠️ **Prune** : supprimer `infra/13-netbird.yaml` supprime l'Application et,
  par son finalizer, les ressources de `netbird2`. Le PVC du management (base
  SQLite) est conservé (`Prune=false,Delete=false`). Pour retirer seulement le
  proxy, supprimer `proxy.yaml`.

## Bascule en production (plus tard)

Une fois le test validé, ArgoCD reprend la release Helm **en place** : les
manifests gardent les noms et les sélecteurs du chart, donc ArgoCD adopte les
Deployments, Services et surtout le PVC `netbird-management` de la production
(les données restent où elles sont, rien à copier). Passer de Helm à ArgoCD
ne pose pas de problème en soi, à condition de :

1. Repasser les manifests en namespace `netbird` / hôte `netbird.ffd.link` et
   l'Application en `netbird` (même nom que la release Helm).
2. Ne **jamais** faire `helm uninstall` ni « Delete » dans Rancher (cela
   supprimerait le PVC) ; après la première sync ArgoCD, faire seulement
   oublier la release à Helm :
   ```bash
   kubectl -n netbird delete secret -l owner=helm,name=netbird
   kubectl -n netbird delete sa netbird-management netbird-signal netbird-relay netbird-dashboard
   ```
3. Recréer le token du proxy sur le management de production (même commande,
   namespace `netbird`) et le mettre dans OpenBao.
4. Supprimer l'instance de test : le namespace `netbird2` (son PVC SQLite est
   conservé par `Delete=false`, à supprimer à la main).
