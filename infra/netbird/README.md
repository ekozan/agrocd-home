# NetBird + reverse proxy

| Composant | URL | Image |
|-----------|-----|-------|
| Dashboard, API, management, signal, relay | `https://netbird.ffd.link` | `netbirdio/{management,signal,relay}:0.80.0`, `netbirdio/dashboard:v2.94.0` |
| Reverse proxy NetBird | `https://*.nb.ffd.link` | `netbirdio/reverse-proxy:0.80.0` |

Déployé par l'Application ArgoCD `netbird` (`infra/13-netbird.yaml`, sync-wave 13),
en manifests bruts (ex-chart `totmicro/netbird` 1.8.2, plus publié depuis
novembre 2025 et sans gestion du reverse proxy).

| Fichier | Rôle |
|---------|------|
| `externalsecrets.yaml` | Secrets `netbird` et `netbird-proxy-token` depuis OpenBao (wave -1) |
| `management.yaml` | ConfigMap `management.json`, PVC SQLite, Deployment, Service |
| `signal.yaml`, `relay.yaml`, `dashboard.yaml` | Deployment + Service de chaque composant |
| `ingressroute.yaml` | Route Traefik de `netbird.ffd.link` (TLS terminé par Traefik, wildcard `*.ffd.link`) |
| `proxy.yaml` | Reverse proxy : PVC, Deployment, Service, passthrough TLS Traefik, NetworkPolicy |

## Architecture

```
Internet ──443──> OPNsense ──> IP LoadBalancer Traefik (externalTrafficPolicy: Local)
                                  │
                                  ├─ Host netbird.ffd.link (router HTTP, TLS Traefik)
                                  │     └─> dashboard / management / signal / relay
                                  │
                                  └─ SNI nb.ffd.link, *.nb.ffd.link (router TCP,
                                     TLS passthrough + PROXY protocol v2)
                                        └─> netbird-proxy:8443 (TLS Let's Encrypt du proxy)
                                               ├─ gRPC interne ─> netbird-management:80
                                               └─ WireGuard (client embarqué) ─> pairs NetBird
```

Pas d'IP LoadBalancer dédiée : tout passe par le 443 de Traefik, qui aiguille
selon le SNI. Les autres hôtes `*.ffd.link` ne sont pas concernés.

## Mise en place (une fois, **avant** de merger)

L'ordre compte : les ExternalSecrets passent en wave -1. Tant qu'OpenBao n'a
pas les valeurs, la sync de l'app s'arrête là et rien d'autre n'est modifié.

### 1. Secrets du serveur dans OpenBao

Le dépôt est public : les secrets qui étaient en clair dans `management.json`
sont remplacés par des placeholders `{{ .VAR }}`, résolus par le management
depuis le Secret `netbird`. Copier les valeurs **actuellement en service**
dans OpenBao (`kv/kubernetes/netbird/server`) :

```bash
CFG=$(kubectl -n netbird get configmap netbird-management -o jsonpath='{.data.management\.json}')
sec() { kubectl -n netbird get secret netbird -o jsonpath="{.data.$1}" | base64 -d; }

# Garde-fou : la ConfigMap ne doit pas déjà contenir les placeholders
grep -q '{{' <<<"$CFG" && echo "STOP : ConfigMap déjà migrée"
# Le relay et le management doivent partager le même secret
[ "$(sec relayPassword)" = "$(jq -r .Relay.Secret <<<"$CFG")" ] && echo "relay OK" || echo "relay : secrets différents"

bao kv put -mount=kv kubernetes/netbird/server \
  datastore_encryption_key="$(jq -r .DataStoreEncryptionKey <<<"$CFG")" \
  idp_service_user_secret="$(jq -r .IdpManagerConfig.ClientConfig.ClientSecret <<<"$CFG")" \
  turn_server_password="$(jq -r '.TURNConfig.Turns[0].Password' <<<"$CFG")" \
  relay_password="$(sec relayPassword)" \
  idp_client_id="$(sec idpClientID)"
```

> ⚠️ `datastore_encryption_key` doit être **exactement** la clé actuelle : avec
> une autre clé, les données chiffrées de la base SQLite deviennent illisibles.

### 2. Token du proxy et clé CrowdSec

```bash
# Token d'accès du proxy (affiché une seule fois). Garder la ligne
# « Token: nbx_… » (40 caractères), pas le Token ID.
kubectl -n netbird exec deploy/netbird-management -- \
  /go/bin/netbird-mgmt admin token create --name proxy-k3s
```

Sur l'OPNsense : `cscli bouncers add netbird-proxy -o raw` (affiche la clé).

```bash
bao kv put -mount=kv kubernetes/netbird/proxy \
  token='nbx_…' crowdsec_api_key='<clé du bouncer>'
```

Gestion ultérieure : `… netbird-mgmt admin token list` / `admin token revoke <token-id>`.

### 3. DNS

| Type | Nom | Valeur |
|------|-----|--------|
| `A` | `nb.ffd.link` | IP publique |
| `CNAME` | `*.nb.ffd.link` | `nb.ffd.link` |

Un wildcard `*.ffd.link` existant couvre déjà ces noms **tant que**
`nb.ffd.link` n'a pas d'enregistrement propre. Rien à changer sur l'OPNsense :
le 443 arrive déjà sur Traefik. Le client NetBird embarqué dans le proxy joint
Signal et le relay via `netbird.ffd.link` : le hairpin NAT (ou un split DNS)
doit fonctionner depuis le cluster.

### 4. Zitadel (SSO des services du proxy)

Dans l'application NetBird de Zitadel (client `301166795920835005`), ajouter la
Redirect URI `https://netbird.ffd.link/api/reverse-proxy/callback`
(`HttpConfig.AuthCallbackURL` de `management.json`).

### 5. Reprise de l'installation existante

Les manifests gardent les noms et les sélecteurs du chart : ArgoCD reprend les
ressources en place (Deployments, PVC du management, Services). Le management
redémarre (nouvelle config) ; signal, relay et dashboard aussi, une fois (plus
de ServiceAccount dédié) : les pairs se reconnectent en quelques secondes.

- **Application ArgoCD `netbird` créée à la main** : l'app `infra` la met à
  jour sur place. Après la première sync, retirer l'ancienne source restée dans
  l'objet (elle contient les values avec secrets en clair) :
  ```bash
  kubectl -n argocd patch application netbird --type json \
    -p '[{"op":"remove","path":"/spec/source"}]'
  ```
- **Release Helm (Rancher, `helm install`)** : après la première sync ArgoCD,
  faire oublier la release à Helm **sans** la désinstaller, puis supprimer les
  ServiceAccounts du chart, devenus inutiles :
  ```bash
  kubectl -n netbird delete secret -l owner=helm,name=netbird
  kubectl -n netbird delete sa netbird-management netbird-signal netbird-relay netbird-dashboard
  ```
  Ne jamais faire `helm uninstall` / « Delete » dans Rancher : cela supprimerait
  les ressources, PVC du management compris.

### 6. Vérifier

```bash
kubectl -n netbird get externalsecret          # netbird et netbird-proxy-token : Ready
kubectl -n netbird logs deploy/netbird-management | head
kubectl -n netbird logs deploy/netbird-proxy -f
```

Dans le dashboard : **Reverse Proxy → Services → Add Service**, `nb.ffd.link`
apparaît avec le badge **Cluster** ; la page **Clusters** affiche **Private** et
la prise en charge CrowdSec.

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

- **Pas de CrowdSec Traefik sur `*.nb.ffd.link`** : en passthrough, Traefik ne
  voit pas le HTTP (ni bouncer, ni AppSec, ni access logs → pas de détection par
  l'agent). Seule la réputation IP du proxy s'applique.
- **Domaine personnalisé** (CNAME vers `nb.ffd.link`) : l'ajouter au `match` de
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
  par son finalizer, les ressources NetBird. Le PVC du management (base
  SQLite) est conservé (`Prune=false,Delete=false`). Pour retirer seulement le
  proxy, supprimer `proxy.yaml`.
