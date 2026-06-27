# office — OxiCloud + Euro-Office

Suite bureautique auto-hébergée : **OxiCloud** (stockage de fichiers, alternative
Nextcloud en Rust) couplé à **Euro-Office** (serveur de documents, fork OnlyOffice)
pour l'édition en ligne via le protocole **WOPI**.

| Service | URL | Image |
|---------|-----|-------|
| OxiCloud | `https://cloud.ffd.link` | `diocrafts/oxicloud:latest` |
| Euro-Office | `https://office.ffd.link` | `ghcr.io/euro-office/documentserver:latest` |

Déployé par l'Application ArgoCD `office.yaml` (path `office/`).

## Architecture

```
Navigateur ──https──> Traefik (CrowdSec) ──> cloud.ffd.link  (OxiCloud :8086)
                                         └──> office.ffd.link (Euro-Office :80)

OxiCloud ──WOPI discovery / éditeur──> Euro-Office (svc interne :80)
Euro-Office ──rappels WOPI (Get/PutFile)──> OxiCloud (svc interne :8086)

OxiCloud ──TLS verify-full──> pg-main-rw.database.svc:5432  (base `oxicloud`)
OxiCloud ──OIDC──> Zitadel (idp.ffd.link)
```

## Composants

| Fichier | Rôle |
|---------|------|
| `00-namespaces.yaml` | Namespaces `oxicloud` (PSA restricted-warn) et `euro-office` (PSA baseline-warn) |
| `01-oxicloud.yaml` | ExternalSecrets (OIDC, WOPI), PVC fichiers (NFS RWX), Deployment, Service, Ingress |
| `02-euro-office.yaml` | ExternalSecret (JWT), PVC (Longhorn), Deployment, Service, Ingress |

Ressources hors de ce dossier :

- **Base de données** : `infra/postgres/01-cluster.yaml` (rôle `oxicloud`) +
  `infra/postgres/02-db-oxicloud.yaml` (base `oxicloud`). Le secret `oxicloud-db`
  est généré par le hook `pg-secret-init` et répliqué vers le namespace `oxicloud`.
- **NetworkPolicies** : `infra/network-policies/oxicloud.yaml` et
  `euro-office.yaml` (default-deny + allow Traefik + allow WOPI croisé).

## Prérequis manuels (avant le 1er déploiement)

### 1. Secrets OpenBao

```bash
# Clé partagée WOPI / JWT (≥ 32 caractères) — la MÊME pour les deux apps
bao kv put kv/kubernetes/office/jwt secret="$(openssl rand -hex 32)"

# Client OIDC Zitadel pour OxiCloud (voir étape 2 pour les valeurs)
bao kv put kv/kubernetes/oxicloud/zitadel \
  client_id="<CLIENT_ID>" client_secret="<CLIENT_SECRET>"
```

### 2. Application OIDC dans Zitadel

OxiCloud utilise le **code flow confidentiel** (avec `client_secret`).

1. Dans Zitadel, créer une application **Web** (OIDC, *Code*).
2. Redirect URI : `https://cloud.ffd.link/api/auth/oidc/callback`
3. Scopes : `openid profile email`
4. Reporter `client_id` / `client_secret` dans OpenBao (étape 1).

## Notes d'exploitation

- **DB / TLS** : la connection string est assemblée dans le pod
  (`PGPASSWORD` injecté depuis le secret `oxicloud-db`, interpolé via l'expansion
  `$(VAR)` Kubernetes). Le CA interne (`pg-main-ca`, monté en `/etc/pg-ca/ca.crt`)
  permet `sslmode=verify-full`.
- **`OXICLOUD_BASE_URL`** doit être figé **avant la première connexion** (impacte
  les URLs absolues et les liens de partage).
- **Persistance** : les fichiers utilisateurs sont sur NFS (TrueNAS, RWX) ; le
  volume d'Euro-Office (Longhorn) ne contient que du cache — les documents vivent
  dans OxiCloud.
- **JWT WOPI** : OxiCloud (`OXICLOUD_WOPI_SECRET`) et Euro-Office (`JWT_SECRET`)
  lisent la même clé OpenBao. Si l'éditeur renvoie une erreur de jeton, vérifier
  que cette clé est bien identique des deux côtés.
- **Euro-Office** embarque postgres/rabbitmq/redis (supervisord) → premier
  démarrage lent (~1-2 min) ; les probes `/healthcheck` tolèrent ce délai.
