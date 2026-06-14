# agrocd-home

Dépôt GitOps pour la gestion déclarative d'un cluster Kubernetes via ArgoCD. Ce repo regroupe l'ensemble des applications et de l'infrastructure sous forme de manifests Helm, déployés et synchronisés automatiquement.

## Architecture globale

```
Kubernetes Cluster
├── Réseau          → Traefik 3 (ingress, OIDC, ModSecurity)
├── Secrets         → Vault / OpenBao + External-Secrets + Cert-Manager
├── Identité        → Zitadel (IdP OIDC)
├── Base de données → CloudNativePG (instance unique `pg-main`, bases multiples)
├── Stockage        → Democratic-CSI (TrueNAS NFS/SMB)
├── Git & CI/CD     → Gitea + Gitea Act Runner
├── Dev             → Coder (IDE cloud)
├── AI/LLM          → LiteLLM (proxy API multi-modèles)
└── Chat            → Tuwunel (homeserver Matrix léger en Rust)
```

### Domaines exposés

| Service | URL |
|---------|-----|
| Gitea | `https://git.ffd.link` |
| Coder | `https://coder.ffd.link` |
| Zitadel | `https://idp.ffd.link` |
| Vault | `https://vault.server` |
| Tuwunel (Matrix) | `https://matrix.ffd.link` |
| MatrixRTC (Element Call) | `https://matrix-rtc.ffd.link` (média via LoadBalancer MetalLB : UDP `7882` / TCP `7881`) |
| Well-known fédération | `https://ffd.link/.well-known/matrix` |

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

Les trois applications ArgoCD racines sont à appliquer dans cet ordre :

```bash
# 1. Couche init : Traefik + Vault
kubectl apply -f init.yaml

# 2. Infrastructure complète (certificats, identité, stockage, Git…)
kubectl apply -f infra.yaml

# 3. Services dev (Coder, LiteLLM)
kubectl apply -f dev.yaml

# 4. Chat (Matrix + Element Web)
kubectl apply -f chat.yaml
```

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

Les services dev (Coder, LiteLLM) et chat (Matrix) sont gérés indépendamment via `dev.yaml` et `chat.yaml`.

---

## Structure du repo

```
agrocd-home/
├── init.yaml                  # ArgoCD App → ./init
├── infra.yaml                 # ArgoCD App → ./infra
├── dev.yaml                   # ArgoCD App → ./dev
│
├── init/
│   ├── 00-traefik3.yaml      # Ingress controller Traefik 3
│   └── vault.yaml            # HashiCorp Vault
│
├── infra/
│   ├── init/                 # Namespaces
│   ├── post-certmanager/     # CA auto-signée + bundle
│   ├── post-externalsecrets/ # Secret stores (OpenBao, democratic-csi)
│   ├── pre-zitadel/          # Certificat PostgreSQL
│   ├── post-zitadel/         # (réservé)
│   ├── 00-init.yaml          # Init namespaces
│   ├── 01-*.yaml             # Cert-Manager, External-Secrets, Replicator
│   ├── 02-*.yaml             # Post-cert-manager, Post-external-secrets
│   ├── 03-pre-zitadel.yaml
│   ├── 03-cnpg-operator.yaml # Opérateur CloudNativePG
│   ├── 04-postgres.yaml      # App → ./infra/postgres (instance pg-main)
│   ├── postgres/             # Cluster pg-main + rôles + bases (Database CRD)
│   │   ├── README.md              # Guide : ajouter un user/base
│   │   ├── 00-secrets-init.yaml   # Job : génère 1 secret/mot de passe par rôle
│   │   ├── 05-certificate.yaml    # Cert serveur TLS (cert-manager my-ca-issuer)
│   │   ├── 06-ca-bundle.yaml      # ConfigMap pg-main-ca (CA pour verify-full)
│   │   ├── 10-cluster.yaml        # Cluster CNPG pg-main + rôles managés
│   │   ├── db-<app>.yaml          # Une base par app (zitadel/coder/gitea/litellm)
│   │   └── migration/             # Jobs pg_dump/pg_restore (NON synchro ArgoCD)
│   ├── 04-*.yaml             # DB Zitadel (legacy) + TrueNAS storage
│   ├── 05-zitadel.yaml
│   ├── 06-gitea.yaml
│   └── 07-gitea-act-runner.yaml
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
                        └── base litellm  (rôle litellm)
```

- **Identifiants** : un Secret `basic-auth` par rôle, à mot de passe aléatoire
  généré en cluster par le Job `pg-secret-init`, puis répliqué
  (kubernetes-replicator) vers le namespace de chaque application. Le superuser
  `postgres` est géré par CNPG (`pg-main-superuser`).
- **TLS** : le certificat serveur de `pg-main` est émis par **cert-manager**
  (`my-ca-issuer`, voir `infra/postgres/05-certificate.yaml`) et injecté via
  `spec.certificates`. Les certificats client/réplication restent gérés par CNPG.
- **Vérification côté client** : trust-manager publie la CA interne **seule**
  dans un ConfigMap `pg-main-ca` (clé `ca.crt`, voir
  `infra/postgres/06-ca-bundle.yaml`) présent dans chaque namespace. Une appli
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
