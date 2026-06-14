# agrocd-home

Dépôt GitOps pour la gestion déclarative d'un cluster Kubernetes via ArgoCD. Ce repo regroupe l'ensemble des applications et de l'infrastructure sous forme de manifests Helm, déployés et synchronisés automatiquement.

## Architecture globale

```
Kubernetes Cluster
├── Réseau          → Traefik 3 (ingress, OIDC, CrowdSec bouncer)
├── Secrets         → Vault / OpenBao + External-Secrets + Cert-Manager
├── Identité        → Zitadel (IdP OIDC)
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
| `3` | Certificat TLS PostgreSQL Zitadel |
| `4` | PostgreSQL Zitadel, Democratic-CSI (TrueNAS) |
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
│   ├── 00-traefik3.yaml          # Ingress controller Traefik 3 (+ plugin CrowdSec)
│   ├── 01-crowdsec.yaml          # Moteur CrowdSec (agent + LAPI)
│   ├── 02-crowdsec-bouncer.yaml  # Job d'enregistrement du bouncer + Middleware
│   └── vault.yaml                # HashiCorp Vault
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
│   ├── 04-*.yaml             # DB Zitadel + TrueNAS storage
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
| CrowdSec | `crowdsecurity.github.io/helm-charts` | 0.24.0 | crowdsec |
| Vault | `helm.releases.hashicorp.com` | 0.28.x | vault |
| Cert-Manager | `charts.jetstack.io` | 1.15.x | cert-manager |
| Trust-Manager | `charts.jetstack.io` | latest | cert-manager |
| External-Secrets | `charts.external-secrets.io` | 0.19.x | external-secrets |
| Kubernetes-Replicator | `helm.mittwald.de` | 2.10.x | kube-system |
| Zitadel | `charts.zitadel.com` | 9.5.x | zitadel |
| PostgreSQL (Zitadel) | `charts.bitnami.com/bitnami` | 15.x | zitadel |
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

## Protection CrowdSec

CrowdSec analyse les **access logs Traefik** (agent DaemonSet) et maintient les décisions de blocage dans le **LAPI**. Le **plugin bouncer** (`crowdsec-bouncer-traefik-plugin` v1.6.0) interroge le LAPI directement depuis Traefik (mode `stream`) pour autoriser ou bloquer les IP.

**Enregistrement de la clé (auto, runtime)** : le LAPI génère la clé API du bouncer. Le Job `crowdsec-bouncer-register` (hook ArgoCD `PostSync`) la récupère via `cscli` puis crée le Middleware `traefik/crowdsec` porteur de la clé. Le Middleware est créé au runtime (hors git) pour ne pas exposer la clé dans le dépôt ni entrer en conflit avec le self-heal.

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

---

## Gestion des certificats TLS

- **Let's Encrypt (ACME)** via le webhook OVH DNS-01 pour les domaines publics
- **CA auto-signée** pour la communication interne (PostgreSQL, services internes)
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
