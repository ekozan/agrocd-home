# agrocd-home

Dépôt GitOps pour la gestion déclarative d'un cluster Kubernetes via ArgoCD. Ce repo regroupe l'ensemble des applications et de l'infrastructure sous forme de manifests Helm, déployés et synchronisés automatiquement.

## Architecture globale

```
Kubernetes Cluster
├── Réseau          → Traefik 3 (ingress, OIDC, CrowdSec bouncer)
├── Secrets         → Vault / OpenBao + External-Secrets + Cert-Manager
├── Identité        → Zitadel (IdP OIDC)
├── Base de données → CloudNativePG (instance unique `pg-main`, bases multiples)
├── Stockage        → Democratic-CSI (TrueNAS NFS/SMB)
├── Git & CI/CD     → Gitea + Gitea Act Runner
├── Dev             → Coder (IDE cloud)
├── AI/LLM          → LiteLLM (proxy API multi-modèles)
├── Chat            → Tuwunel (homeserver Matrix léger en Rust)
└── Bureautique     → OxiCloud (stockage) + Euro-Office (édition docs / WOPI)
```

### Domaines exposés

| Service | URL |
|---------|-----|
| Gitea | `https://git.ffd.link` |
| Coder | `https://coder.ffd.link` |
| Zitadel | `https://idp.ffd.link` |
| Vault | `https://vault.server` |
| Tuwunel (Matrix) | `https://matrix.ffd.link` |
| CrowdSec (UI web) | `https://crowdsec.ffd.link` (LAN uniquement) |
| MatrixRTC (Element Call) | `https://matrix-rtc.ffd.link` (média via LoadBalancer MetalLB : UDP `7882` / TCP `7881`) |
| Well-known fédération | `https://ffd.link/.well-known/matrix` |
| OxiCloud (stockage) | `https://cloud.ffd.link` |
| Euro-Office (édition docs) | `https://office.ffd.link` |

---

## Prérequis

| Outil | Version minimale |
|-------|-----------------|
| Kubernetes | 1.26+ |
| ArgoCD | 2.x (déployé dans le namespace `argocd`) |
| kubectl | compatible avec le cluster |
| Helm | 3.x (pour debug local uniquement) |

> ArgoCD doit être déjà installé et fonctionnel sur le cluster avant d'appliquer ce repo.

---

## Installation

### 1. Cloner le dépôt

```bash
git clone https://github.com/ekozan/agrocd-home.git
cd agrocd-home
```

### 2. Configurer les secrets dans Vault

Avant de déployer, les secrets suivants doivent être présents dans Vault / OpenBao :

- Credentials TrueNAS (Democratic-CSI) : NFS et SMB
- Clés API LLM (Anthropic, etc.) pour LiteLLM
- Client secret Zitadel pour Tuwunel (injecté via ExternalSecret → Secret `tuwunel-oidc-secret`, clé `TUWUNEL_OIDC_CLIENT_SECRET`)
- *(Element Call : la clé/secret d'API LiveKit est générée automatiquement dans le cluster par un Job de bootstrap — aucun secret à fournir.)*
- Certificats TLS si non gérés par Cert-Manager

### 3. Appliquer les ArgoCD Applications

Les applications ArgoCD racines sont à appliquer dans cet ordre :

```bash
# 0. AppProject restreint (DOIT précéder les Applications qui le référencent)
kubectl apply -f appproject.yaml

# 1. Couche init : Traefik + Vault
kubectl apply -f init.yaml

# 2. Infrastructure complète (certificats, identité, stockage, Git…)
kubectl apply -f infra.yaml

# 3. Services dev (Coder, LiteLLM)
kubectl apply -f dev.yaml

# 4. Chat (Matrix + Element Web)
kubectl apply -f chat.yaml
```

> **Bureautique (OxiCloud + Euro-Office)** : déployée par la couche **infra**
> (`infra/10-oxicloud.yaml`, `infra/11-euro-office.yaml`), donc déjà couverte par
> l'étape 2. Prérequis manuels (secrets OpenBao + app OIDC Zitadel) :
> voir `infra/oxicloud/README.md`.

ArgoCD prend ensuite le relais et synchronise automatiquement chaque ressource.

---

## Ordre de déploiement (`sync-wave`)

L'infrastructure est déployée en vagues successives grâce à l'annotation `argocd.argoproj.io/sync-wave` :

| Wave | Composants |
|------|-----------|
| `-1` | Namespaces (`external-secrets`, `democratic-csi`) |
| `0` | Traefik, Vault |
| `1` | Cert-Manager, Trust-Manager, External-Secrets, Kubernetes-Replicator |
| `2` | Issuers ACME (OVH webhook), Secret Stores (Vault/OpenBao) |
| `3` | Certificat TLS PostgreSQL Zitadel, **Opérateur CloudNativePG** |
| `4` | **Instance PostgreSQL centralisée `pg-main` (+ bases)**, PostgreSQL Zitadel (legacy), Democratic-CSI (TrueNAS) |
| `5` | Zitadel (IdP) |
| `6` | Gitea |
| `7` | Gitea Act Runner |
| `8` | Network Policies |
| `9` | CrowdSec UI |
| `10` | OxiCloud (`cloud.ffd.link`) |
| `11` | Euro-Office (`office.ffd.link`) |

Les services dev (Coder, LiteLLM) et chat (Matrix) sont gérés indépendamment via `dev.yaml` et `chat.yaml`.

---

## Structure du repo

```
agrocd-home/
├── init.yaml                  # ArgoCD App → ./init
├── infra.yaml                 # ArgoCD App → ./infra
├── dev.yaml                   # ArgoCD App → ./dev
├── chat.yaml                  # ArgoCD App → ./chat
│
├── init/
│   ├── 00-traefik3.yaml          # Ingress controller Traefik 3 (+ plugin CrowdSec)
│   ├── 01-crowdsec-secret.yaml   # Job generate-once du secret LAPI (déterministe)
│   ├── 01-crowdsec.yaml          # Moteur CrowdSec (agent + LAPI)
│   ├── 02-crowdsec-bouncer.yaml  # Job d'enregistrement du bouncer + Middleware
│   ├── 03-traefik-middlewares.yaml # Middlewares local-only (ipAllowList) + oidc-auth
│   └── vault.yaml                # HashiCorp Vault
│
├── infra/
│   ├── init/                 # Namespaces
│   ├── post-certmanager/     # CA auto-signée + bundle
│   ├── post-externalsecrets/ # Secret stores (OpenBao, democratic-csi)
│   ├── pre-zitadel/          # Certificat PostgreSQL
│   ├── post-zitadel/         # (réservé)
│   ├── network-policies/     # NetworkPolicies (default-deny + allow ciblés)
│   ├── crowdsec-ui/          # UI web locale CrowdSec (crowdsec-web-ui)
│   ├── 00-init.yaml          # Init namespaces
│   ├── 01-*.yaml             # Cert-Manager, External-Secrets, Replicator
│   ├── 02-*.yaml             # Post-cert-manager, Post-external-secrets
│   ├── 03-pre-zitadel.yaml
│   ├── 03-cnpg-operator.yaml # Opérateur CloudNativePG
│   ├── 04-postgres.yaml      # App → ./infra/postgres (instance pg-main)
│   ├── postgres/             # Cluster pg-main + rôles + bases (Database CRD)
│   │   ├── README.md              # Guide : ajouter un user/base
│   │   ├── 00-secrets-init.yaml   # Hook PostSync : génère les secrets de rôle manquants
│   │   ├── 00-certificate.yaml    # Cert serveur TLS (cert-manager my-ca-issuer)
│   │   ├── 00-ca-bundle.yaml      # ConfigMap pg-main-ca (CA pour verify-full)
│   │   ├── 01-cluster.yaml        # Cluster CNPG pg-main + rôles managés
│   │   ├── 02-db-<app>.yaml       # Une base par app (zitadel/coder/gitea/litellm)
│   │   └── migration/             # Jobs pg_dump/pg_restore (NON synchro ArgoCD)
│   │                              # (préfixe = sync-wave : 0/1/2)
│   ├── 04-*.yaml             # DB Zitadel (legacy) + TrueNAS storage
│   ├── 05-zitadel.yaml
│   ├── 06-gitea.yaml
│   ├── 07-gitea-act-runner.yaml
│   ├── 08-network-policies.yaml
│   ├── 09-crowdsec-ui.yaml   # App ArgoCD → ./infra/crowdsec-ui
│   ├── 10-oxicloud.yaml      # App ArgoCD → ./infra/oxicloud (cloud.ffd.link)
│   ├── oxicloud/             # OxiCloud (NS, ExternalSecrets, PVC NFS, Deployment, Service, Ingress) + README bureautique
│   ├── 11-euro-office.yaml   # App ArgoCD → ./infra/euro-office (office.ffd.link)
│   └── euro-office/          # Euro-Office (NS, ExternalSecret JWT, DB pg-main, PVC, Deployment, Service, Ingress)
│
├── dev/
│   ├── coder.yaml
│   ├── coder-db.yaml
│   ├── litellm.yaml
│   └── litellm-secret.yaml
│
└── chat/
    ├── tuwunel.yaml            # Tuwunel — manifests bruts (NS, ConfigMap, PVC, Deployment, Service, Ingress, ExternalSecret)
    └── element-call.yaml       # MatrixRTC — LiveKit (SFU) + lk-jwt-service + Ingress + LoadBalancer média (MetalLB)
```

> **Convention de nommage** : les fichiers dans `infra/` sont préfixés par leur numéro de wave (`00-`, `01-`, etc.) avec un tiret. Éviter les espaces dans les noms de fichiers.

---

## Composants et versions Helm

| Application | Chart | Version | Namespace |
|-------------|-------|---------|-----------|
| Traefik 3 | `traefik.github.io/charts` | 34.3.0 | kube-system |
| CrowdSec | `crowdsecurity.github.io/helm-charts` | 0.24.0 | crowdsec |
| Vault | `helm.releases.hashicorp.com` | 0.28.x | vault |
| Cert-Manager | `charts.jetstack.io` | 1.15.x | cert-manager |
| Trust-Manager | `charts.jetstack.io` | latest | cert-manager |
| External-Secrets | `charts.external-secrets.io` | 0.19.x | external-secrets |
| Kubernetes-Replicator | `helm.mittwald.de` | 2.10.x | kube-system |
| Zitadel | `charts.zitadel.com` | 9.5.x | zitadel |
| CloudNativePG (opérateur) | `cloudnative-pg.github.io/charts` | 0.28.3 (PG op. 1.29.1) | cnpg-system |
| PostgreSQL `pg-main` | image `ghcr.io/cloudnative-pg/postgresql` | 16 | database |
| PostgreSQL (Zitadel, *legacy*) | `charts.bitnami.com/bitnami` | 15.x | zitadel |
| Gitea | `dl.gitea.com/charts/` | 12.4.0 | gitea |
| Gitea Act Runner | `dl.gitea.com/charts/` | 0.1.0 | gitea |
| Democratic-CSI | `democratic-csi.github.io/charts/` | 0.15.1 | democratic-csi |
| Coder | `helm.coder.com/v2` | 2.34.0 | coder |
| PostgreSQL (Coder) | `charts.bitnami.com/bitnami` | 15.5.x | coder |
| LiteLLM | OCI `docker.litellm.ai/berriai/litellm-helm` | 0.1.2 | litellm |
**Manifests bruts (sans Helm)**

| Application | Image | Version | Namespace |
|-------------|-------|---------|-----------|
| Tuwunel | `ghcr.io/matrix-construct/tuwunel` | v1.7.1 | matrix |
| OxiCloud | `diocrafts/oxicloud` | 0.8.0 | oxicloud |
| Euro-Office | `ghcr.io/euro-office/documentserver` | v9.3.2 | euro-office |

---

## Consolidation PostgreSQL (CloudNativePG)

Objectif : remplacer les multiples PostgreSQL Bitnami (un par application, et
images `bitnamilegacy/*` désormais non maintenues) par **une instance unique
CloudNativePG `pg-main`** hébergeant **une base par application**, chacune avec
son **rôle propriétaire dédié**.

```
namespace cnpg-system → opérateur CloudNativePG
namespace database    → Cluster pg-main
                        ├── base zitadel  (rôle zitadel)
                        ├── base coder    (rôle coder)
                        ├── base gitea    (rôle gitea)
                        ├── base litellm  (rôle litellm)
                        ├── base oxicloud (rôle oxicloud)
                        └── base euro-office (rôle euro-office, sans TLS)
```

- **Identifiants** : un Secret `basic-auth` par rôle, à mot de passe aléatoire.
  Le hook PostSync `pg-secret-init` lit `spec.managed.roles` du Cluster et
  régénère **tout secret manquant** à chaque sync (puis réplication
  kubernetes-replicator vers le namespace de l'app). Ajouter un rôle suffit à
  obtenir son secret. Le superuser `postgres` est géré par CNPG
  (`pg-main-superuser`).
- **TLS** : le certificat serveur de `pg-main` est émis par **cert-manager**
  (`my-ca-issuer`, voir `infra/postgres/00-certificate.yaml`) et injecté via
  `spec.certificates`. Les certificats client/réplication restent gérés par CNPG.
- **Vérification côté client** : trust-manager publie la CA interne **seule**
  dans un ConfigMap `pg-main-ca` (clé `ca.crt`, voir
  `infra/postgres/00-ca-bundle.yaml`) présent dans chaque namespace. Une appli
  le monte en fichier et l'utilise en `sslrootcert` pour vérifier le serveur :

  ```
  host=pg-main-rw.database.svc.cluster.local sslmode=verify-full
  sslrootcert=/etc/pg-ca/ca.crt
  ```
  ```yaml
  # extrait pod : monter la CA
  volumes:
    - name: pg-ca
      configMap: { name: pg-main-ca }
  volumeMounts:
    - name: pg-ca
      mountPath: /etc/pg-ca
      readOnly: true
  ```
- **Service** d'accès en lecture/écriture : `pg-main-rw.database.svc:5432`.

### Phase 1 — Mise en place (déployée par ArgoCD)

`infra/03-cnpg-operator.yaml` + `infra/04-postgres.yaml` déploient l'opérateur,
le Cluster, les rôles et les bases (vides). **Les anciennes instances et la
config des applications ne sont pas modifiées.**

### Phase 2 — Migration des données puis bascule (manuelle)

1. **Migrer** les données : voir `infra/postgres/migration/README.md`
   (Jobs `pg_dump`/`pg_restore` non synchronisés par ArgoCD).
2. **Rebrancher** chaque application sur `pg-main-rw.database.svc`, base et
   secret `<app>-db` correspondants :
   - **Zitadel** (`infra/05 zitadel.yaml`) → `Database.Postgres.Host: pg-main-rw.database.svc`,
     user `zitadel` (secret `zitadel-db`), admin `postgres` (secret `pg-main-superuser`).
   - **Gitea** (`infra/06 gitea.yaml`) → `postgresql.enabled: false` et configurer
     `gitea.config.database` vers `pg-main-rw.database.svc` (base/role `gitea`).
   - **Coder** (`dev/coder.yaml`) → `CODER_PG_CONNECTION_URL` vers la base `coder`
     (construire l'URL depuis `coder-db`).
   - **LiteLLM** (`dev/litellm.yaml`) → base externe `litellm` (désactiver le
     PostgreSQL embarqué du chart).
3. **Supprimer** les anciennes instances : `infra/04 zitadel db.yaml`,
   `dev/coder-db.yaml`, et les sous-charts `postgresql` de Gitea/LiteLLM.
   ⚠️ Le `prune` ArgoCD est actif : supprimer ces fichiers détruit les anciens
   PostgreSQL — ne le faire qu'**après** validation de la migration.

---

## Protection CrowdSec

CrowdSec analyse les **access logs Traefik** (agent DaemonSet) et maintient les décisions de blocage dans le **LAPI**. Le **plugin bouncer** (`crowdsec-bouncer-traefik-plugin` v1.6.0) interroge le LAPI directement depuis Traefik (mode `stream`) pour autoriser ou bloquer les IP.

**Enregistrement de la clé (auto, runtime)** : le LAPI génère la clé API du bouncer. Le Job `crowdsec-bouncer-register` (hook ArgoCD `PostSync`) la récupère via `cscli` puis crée le Middleware `traefik/crowdsec` porteur de la clé. Le Middleware est créé au runtime (hors git) pour ne pas exposer la clé dans le dépôt ni entrer en conflit avec le self-heal.

**Page de blocage personnalisée (ban IP + AppSec)** : les requêtes bloquées reçoivent une page HTML (`banHTMLFilePath`) au lieu d'un 403 brut. La page est définie dans le ConfigMap `crowdsec-ban-page` (`init/02-crowdsec-bouncer.yaml`), montée dans les pods Traefik via les `volumes` du chart (`init/00-traefik3.yaml`) sous `/etc/traefik/crowdsec/ban.html`.

Le plugin n'expose qu'**une seule** option de page, mais le fichier est rendu comme un **template Go** recevant `{{ .RemediationReason }}` (`LAPI` = ban IP, `APPSEC` = blocage WAF) et `{{ .ClientIP }}`. La page branche donc l'affichage pour montrer un message distinct selon l'origine du blocage (un second fichier ne serait jamais servi par le plugin). Modifier le ConfigMap suffit à changer la page (penser à recharger les pods Traefik).

**Secret LAPI déterministe** : le chart randomise `registrationToken` / `csLapiSecret` à chaque render, mais sous ArgoCD (`helm template` sans accès cluster) son `lookup` de stabilisation renvoie vide → churn permanent. Le Job `crowdsec-lapi-secret-gen` (wave 0, idempotent) génère ces valeurs **une seule fois** dans le Secret `crowdsec-lapi-secrets`, référencé par le chart via `secrets.externalSecret.name`. Le render redevient déterministe → `selfHeal: true` peut rester actif sans rotation intempestive des credentials.

**Couverture** : le middleware est appliqué sur **toutes les routes publiques** exposées par Traefik.

| Route | Fichier |
|-------|---------|
| `git.ffd.link` (Gitea) | `infra/06 gitea.yaml` |
| `idp.ffd.link` (Zitadel) | `infra/05 zitadel.yaml` |
| `coder.ffd.link` (+ wildcard) | `dev/coder.yaml` |
| `matrix.ffd.link` (Tuwunel) | `chat/tuwunel.yaml` |
| `ffd.link/.well-known/matrix` | `chat/tuwunel.yaml` |
| `matrix-rtc.ffd.link` (MatrixRTC) | `chat/element-call.yaml` |
| `cloud.ffd.link` (OxiCloud) | `infra/oxicloud/oxicloud.yaml` |
| `office.ffd.link` (Euro-Office) | `infra/euro-office/euro-office.yaml` |

> LiteLLM n'expose pas d'Ingress public (accès interne uniquement) → hors périmètre.

**Whitelists anti-faux-positifs** (`init/01-crowdsec.yaml`, parsers `s02-enrich`) : certaines applications génèrent un fort volume de requêtes légitimes qui ressemblent à du crawl/probing. Des whitelists ciblées évitent les bans intempestifs **sans désactiver la détection brute-force** (les réponses `401`/`403` restent analysées) :

| Whitelist | Trafic couvert |
|-----------|----------------|
| `my/matrix-whitelist` | Fédération/clients Matrix (`/_matrix/`, `/_synapse/`, well-known) |
| `my/office-whitelist` | Sync OxiCloud compatible Nextcloud/ownCloud (`/remote.php/`, `/ocs/`, `/status.php`) + assets/API du document server Euro-Office (`/web-apps/`, `/coauthoring/`, `/hosting/`…) |

> Ces whitelists agissent au niveau du **bouncer/LAPI** (sur les logs Traefik).
> Le **WAF AppSec** (inspection inline) est géré séparément (voir ci-dessous).

### WAF AppSec — packs du hub (OWASP CRS + virtual patching)

La config AppSec active est `custom/full-appsec` (`appsec.configs`). Plutôt que
des règles maison, elle s'appuie sur les **packs WAF prêts à l'emploi** du hub
CrowdSec, installés via `COLLECTIONS` / `APPSEC_RULES` du composant AppSec :

| Pack (hub) | Mode | Rôle |
|------------|------|------|
| `crowdsecurity/appsec-virtual-patching` (`vpatch-*`) | **inband** (bloque) | Virtual patching CVE — quasi zéro faux positif |
| `crowdsecurity/appsec-generic-rules` (`generic-*`, `base-config`) | **inband** (bloque) | Patterns d'attaque génériques + body processors |
| `crowdsecurity/appsec-crs` (`crowdsecurity/crs`) | **out-of-band** (alerte) | OWASP Core Rule Set complet (XXE, traversal, RCE, method enforcement…) |
| `crowdsecurity/crs-exclusion-plugin-nextcloud` | datafiles | Exclusions CRS officielles Nextcloud/WebDAV (anti-FP synchro) |

**Fonctionnement** : les règles *inband* (vpatch/generic) bloquent immédiatement.
Le CRS tourne en *out-of-band* (n'interrompt pas la requête mais émet une alerte
via le hook `on_match`/`SendAlert`) ; le scénario `crowdsecurity/crowdsec-appsec-outofband`
(fourni par `appsec-crs`) corrèle ces alertes et bannit l'IP au-delà d'un seuil
— c'est le compromis couverture/faux-positifs recommandé par CrowdSec.

> **Notes** :
> - Les exclusions Nextcloud du plugin CRS sont **incluses automatiquement** par
>   le CRS dès que ses datafiles sont présents → pas de FP sur `/remote.php/`,
>   `/ocs/`, etc. (en plus du whitelist bouncer `my/office-whitelist` ci-dessus).
> - **Emplacement** : configs/règles AppSec sous `appsec.configs` / `appsec.rules`
>   (chart crowdsec) — **pas** sous `config.*`, sinon non montées dans le
>   composant AppSec. Les règles du hub s'installent via `COLLECTIONS` (collections)
>   et `APPSEC_RULES` (appsec-rules individuelles), pas par fichier inline.
> - `base-config` ne fait que configurer les *body processors* (par Content-Type) ;
>   il n'impose pas d'allowlist de méthodes → les verbes WebDAV passent nativement.

**Activer la protection sur une route** : référencer le middleware dans l'Ingress / IngressRoute.

```yaml
# Ingress
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: traefik-crowdsec@kubernetescrd
```

```yaml
# IngressRoute
spec:
  routes:
    - kind: Rule
      match: Host(`exemple.ffd.link`)
      middlewares:
        - name: crowdsec
          namespace: traefik
```

**UI web locale (`crowdsec-web-ui`)** : une interface auto-hébergée ([TheDuffman85/crowdsec-web-ui](https://github.com/TheDuffman85/crowdsec-web-ui), `infra/crowdsec-ui/`, déployée par l'App ArgoCD `infra/09-crowdsec-ui.yaml`) interroge le LAPI local pour visualiser et gérer alertes/décisions, sans envoyer de données à un SaaS. Elle est exposée sur `https://crowdsec.ffd.link` mais **restreinte au LAN** : l'appli n'a pas d'authentification intégrée, on la protège donc par les middlewares `crowdsec` (bouncer + AppSec) **et** `local-only` (réseaux `10.10.0.0/16` / `10.5.0.0/16`).

Connexion au LAPI via un **compte machine** `crowdsec-web-ui` enregistré par le Job `crowdsec-ui-register` (ressource ArgoCD en `sync-wave 1`, exécutée **avant** le Deployment afin que le Secret existe quand le pod le monte — un hook `PostSync` provoquerait un interblocage). Le mot de passe est généré **une seule fois** dans le Secret `crowdsec-web-ui-credentials` (render déterministe, compatible `selfHeal`). Le cache SQLite de l'UI est persisté sur un PVC Longhorn (`/app/data`). Une NetworkPolicy dédiée autorise les pods Traefik à joindre l'UI sur le port `3000` (le namespace `crowdsec` étant en `default-deny-ingress`).

**Administration (CLI)** : pour les opérations non couvertes par l'UI, tout reste gérable via `cscli` dans le pod LAPI.

```bash
# Raccourci vers le pod LAPI
LAPI=$(kubectl -n crowdsec get pod -l type=lapi -o jsonpath='{.items[0].metadata.name}')

# Alertes et décisions actives
kubectl -n crowdsec exec "$LAPI" -- cscli alerts list
kubectl -n crowdsec exec "$LAPI" -- cscli decisions list

# Bloquer / débloquer une IP manuellement
kubectl -n crowdsec exec "$LAPI" -- cscli decisions add --ip 1.2.3.4 --duration 4h
kubectl -n crowdsec exec "$LAPI" -- cscli decisions delete --ip 1.2.3.4

# État : bouncers enregistrés, métriques, collections installées
kubectl -n crowdsec exec "$LAPI" -- cscli bouncers list
kubectl -n crowdsec exec "$LAPI" -- cscli metrics
kubectl -n crowdsec exec "$LAPI" -- cscli collections list
```

**UI web (optionnel) — enrôlement Console** : pour disposer d'une interface graphique (alertes, décisions, métriques, blocklists), on enrôle l'instance dans la [Console CrowdSec](https://app.crowdsec.net). L'enrôlement est stocké sur le PVC du LAPI (`lapi.persistentVolume.data`) et survit donc aux redémarrages.

```bash
# 1. Sur https://app.crowdsec.net : Security Engines → Add Security Engine
#    → copier la clé d'enrôlement (cabc...)

# 2. Enrôler depuis le pod LAPI
LAPI=$(kubectl -n crowdsec get pod -l type=lapi -o jsonpath='{.items[0].metadata.name}')
kubectl -n crowdsec exec "$LAPI" -- \
  cscli console enroll -n "agrocd-home" -t "k8s homelab" <CLE_ENROLEMENT>

# 3. Accepter l'instance dans la Console (app.crowdsec.net)

# 4. Redémarrer le LAPI pour appliquer
kubectl -n crowdsec rollout restart deploy/crowdsec-lapi
```

> Seules des métadonnées sont envoyées au SaaS CrowdSec. L'enrôlement est manuel/ponctuel ; pour un ré-enrôlement automatique au (re)déploiement, utiliser plutôt les variables `lapi.env` (`ENROLL_KEY` via Secret, `ENROLL_INSTANCE_NAME`, `ENROLL_TAGS`).

---

## Middlewares Traefik réutilisables

Définis dans `init/03-traefik-middlewares.yaml` (namespace `traefik`, comme le middleware `crowdsec`). Référençables depuis n'importe quel Ingress grâce à `allowCrossNamespace: true`.

| Middleware | Rôle | Référence |
|------------|------|-----------|
| `crowdsec` | Bouncer + AppSec WAF CrowdSec | `traefik-crowdsec@kubernetescrd` |
| `local-only` | Accès restreint aux réseaux locaux `10.10.0.0/16` et `10.5.0.0/16` | `traefik-local-only@kubernetescrd` |
| `oidc-auth` | Login OIDC via Zitadel (plugin `traefik-oidc-auth`) | `traefik-oidc-auth@kubernetescrd` |

**Appliquer sur une route** (les middlewares se chaînent, séparés par des virgules) :

```yaml
metadata:
  annotations:
    # CrowdSec + accès local uniquement
    traefik.ingress.kubernetes.io/router.middlewares: traefik-crowdsec@kubernetescrd,traefik-local-only@kubernetescrd
```

**`oidc-auth` — pré-requis** :

1. Créer une application **OIDC de type PKCE** (code flow + PKCE, client public sans secret) dans Zitadel, avec l'URL de redirection `https://<host-protégé>/oidc/callback` pour chaque hôte protégé.
2. Renseigner dans OpenBao sous `kv/kubernetes/traefik/zitadel` :
   - `client_id` : ID du client OIDC (le flux PKCE ne nécessite **pas** de `client_secret`)
   - `plugin_secret` : clé ≥ 32 caractères pour chiffrer le cookie de session

   L'ExternalSecret `traefik-oidc` matérialise ces valeurs dans le Secret `traefik-oidc-secret`, résolu au runtime par le plugin via `urn:k8s:secret:traefik-oidc-secret:<clé>`.

---

## Gestion des certificats TLS

- **Let's Encrypt (ACME)** via le webhook OVH DNS-01 pour les domaines publics
- **CA auto-signée** pour la communication interne (PostgreSQL `pg-main` via
  `my-ca-issuer`, services internes)
- Trust-Manager distribue automatiquement le bundle CA dans tous les namespaces

---

## Vérifier l'état de synchronisation

```bash
# Voir toutes les ArgoCD Applications
kubectl get applications -n argocd

# Détail d'une application
kubectl describe application infra -n argocd

# Forcer une synchronisation
argocd app sync infra
```

---

## Contribuer

Ce repo suit un workflow GitOps strict :

1. Toute modification se fait via une PR sur la branche `main`
2. ArgoCD détecte le changement et synchronise automatiquement (auto-sync + self-heal activés)
3. Les suppressions sont propagées automatiquement (prune activé)

> **Attention** : le prune est activé. Supprimer un fichier du repo supprime la ressource Kubernetes correspondante.

---

## Améliorations envisagées

| Priorité | Action |
|----------|--------|
| Rapide | Uniformiser le nommage des fichiers `infra/` (remplacer les espaces par des tirets) |
| Rapide | Supprimer ou remplir `infra/post-zitadel/createApp.yaml` (actuellement vide) |
| Moyen terme | Ajouter un `App of Apps` racine pour bootstrapper le cluster en un seul `kubectl apply` |
| Optionnel | Extraire les Helm values dans des fichiers dédiés (`infra/values/zitadel.yaml`, etc.) pour améliorer la lisibilité des diffs Git |
