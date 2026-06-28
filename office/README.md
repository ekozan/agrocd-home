# office — OxiCloud + Euro-Office

Suite bureautique auto-hébergée : **OxiCloud** (stockage de fichiers, alternative
Nextcloud en Rust) couplé à **Euro-Office** (serveur de documents, fork OnlyOffice)
pour l'édition en ligne via le protocole **WOPI**.

| Service | URL | Image |
|---------|-----|-------|
| OxiCloud | `https://cloud.ffd.link` | `diocrafts/oxicloud:0.8.0` |
| Euro-Office | `https://office.ffd.link` | `ghcr.io/euro-office/documentserver:v9.3.2` |

> Images **figées** sur une version précise (GitOps reproductible). Pour mettre
> à jour : bumper le tag dans `01-oxicloud.yaml` / `02-euro-office.yaml`.
>
> **OxiCloud — mainteneur** : le projet est désormais porté par **AtalayaLabs**
> (ex-DioCrafts) — repo `github.com/AtalayaLabs/OxiCloud`. En revanche l'image
> Docker reste publiée sous le namespace Docker Hub **`diocrafts/oxicloud`**
> (le `docker-compose.yml` upstream l'utilise toujours ; `atalayalabs/oxicloud`
> n'existe pas sur Docker Hub). On garde donc `diocrafts/oxicloud` tant qu'aucune
> image n'est republiée sous `atalayalabs`.

Déployé par l'Application ArgoCD `office.yaml` (path `office/`).

## Architecture

```
Navigateur ──https──> Traefik (CrowdSec) ──> cloud.ffd.link  (OxiCloud :8086)
                                         └──> office.ffd.link (Euro-Office :80)

OxiCloud ──WOPI discovery / éditeur──> Euro-Office (svc interne :80)
Euro-Office ──rappels WOPI (Get/PutFile)──> OxiCloud (svc interne :8086)

OxiCloud    ──TLS verify-full──> pg-main-rw.database.svc:5432  (base `oxicloud`)
Euro-Office ──sans TLS──────────> pg-main-rw.database.svc:5432  (base `euro-office`)
OxiCloud ──OIDC──> Zitadel (idp.ffd.link)
```

> **Euro-Office & PostgreSQL** : la **base** utilise `pg-main` (CNPG, base/rôle
> `euro-office`) via `DB_*` — ce qui désactive le PostgreSQL embarqué de l'image.
> En revanche **RabbitMQ et Redis restent embarqués** (non déportés). La connexion
> se fait **sans TLS** : le support SSL d'OnlyOffice vers une PG externe est non
> fiable (issues amont non résolues). C'est acceptable ici (trafic intra-cluster,
> NetworkPolicy, auth mot de passe) ; `pg-main` accepte le non-SSL via la règle
> `host` par défaut du `pg_hba` CNPG. Le secret `euro-office-db` est généré par
> `pg-secret-init` et répliqué vers le namespace `euro-office`.

## Composants

| Fichier | Rôle |
|---------|------|
| `00-namespaces.yaml` | Namespaces `oxicloud` (PSA restricted-warn) et `euro-office` (PSA baseline-warn) |
| `01-oxicloud.yaml` | ExternalSecrets (OIDC, WOPI), PVC fichiers (NFS RWX), Deployment, Service, Ingress |
| `02-euro-office.yaml` | ExternalSecret (JWT), DB externe (`DB_*` → pg-main), PVC (Longhorn), Deployment, Service, Ingress |

Ressources hors de ce dossier :

- **Bases de données** (cluster CNPG `pg-main`) : rôles `oxicloud` et `euro-office`
  dans `infra/postgres/01-cluster.yaml` ; bases dans `02-db-oxicloud.yaml` et
  `02-db-eurooffice.yaml`. Les secrets `oxicloud-db` / `euro-office-db` sont
  générés par le hook `pg-secret-init` et répliqués vers les namespaces homonymes.
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

## Compatibilité Nextcloud / ownCloud

OxiCloud expose une **API/WebDAV compatible Nextcloud** (`OXICLOUD_NEXTCLOUD_*`).
Les clients de synchronisation **Nextcloud** comme **ownCloud** (desktop, Android,
iOS — même lignée de protocole) peuvent donc s'y connecter :

- **URL serveur** : `https://cloud.ffd.link`
- **Identifiants** : compte OxiCloud (login/mot de passe ; le SSO OIDC reste pour
  le web).
- `OXICLOUD_NEXTCLOUD_INSTANCE_ID` (`ffd-oxicloud`) identifie l'instance auprès
  des clients — **ne pas le changer** après les premières synchros (sinon resync
  complète). `OXICLOUD_NEXTCLOUD_VERSION` est la version Nextcloud annoncée pour
  la négociation de compatibilité client.

