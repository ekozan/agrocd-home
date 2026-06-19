# Instance PostgreSQL centralisée `pg-main`

Une seule instance CloudNativePG héberge **une base par application**, chacune
avec son **rôle propriétaire**.

## Layout

| Fichier | Rôle |
|---------|------|
| `00-secrets-init.yaml` | Hook PostSync : génère tout Secret `basic-auth` manquant à partir de `spec.managed.roles` (répliqué vers le namespace de l'app) |
| `00-certificate.yaml` | Certificat serveur TLS (cert-manager `my-ca-issuer`) |
| `00-ca-bundle.yaml` | ConfigMap `pg-main-ca` (CA pour `verify-full` côté client) |
| `01-cluster.yaml` | Cluster `pg-main` + **rôles** (`spec.managed.roles`) |
| `02-db-<app>.yaml` | **Une base par application** (CRD `Database`) |
| `migration/` | Jobs `pg_dump`/`pg_restore` one-shot (**non** synchronisés par ArgoCD) |

> Le préfixe numérique des fichiers = la valeur de `argocd.argoproj.io/sync-wave`
> (0 = secrets + cert + CA, 1 = cluster, 2 = bases).

> Le rôle et la base sont **deux objets distincts** : CNPG n'a pas de CRD `Role`,
> les rôles sont un sous-champ du `Cluster`. Le rôle vit donc dans
> `01-cluster.yaml`, la base dans son propre fichier `02-db-<app>.yaml`.

> ⚠️ L'Application ArgoCD `postgres` est en `directory.recurse: false` : seuls
> les fichiers `.yaml` **à la racine** de ce dossier sont synchronisés. Garder
> les nouvelles bases ici (pas dans un sous-dossier).

## Ajouter une nouvelle application (ex. `grafana`)

> Le mot de passe est généré **automatiquement** : le hook PostSync
> `pg-secret-init` lit `spec.managed.roles` du Cluster et crée tout Secret
> `<rôle>-db` manquant à chaque sync. Aucune commande manuelle à lancer.
> (Convention : le Secret est répliqué vers le namespace homonyme du rôle —
> `grafana` → ns `grafana`. Si le namespace de l'app diffère du nom du rôle,
> ajuster l'annotation `replicator.v1.mittwald.de/replicate-to`.)

### 1. Déclarer le rôle dans `01-cluster.yaml`

Ajouter sous `spec.managed.roles` :

```yaml
      - name: grafana
        ensure: present
        login: true
        passwordSecret:
          name: grafana-db
```

### 2. Créer le fichier de la base `02-db-grafana.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: grafana
  namespace: database
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  name: grafana
  owner: grafana
  cluster:
    name: pg-main
  databaseReclaimPolicy: retain
```

### 3. Commit + push

ArgoCD synchronise : le hook `pg-secret-init` génère le Secret `grafana-db`
manquant, puis CNPG crée le rôle (avec ce mot de passe) et la base. L'app se
connecte via le Secret `grafana-db` sur `pg-main-rw.database.svc/grafana`.

## Variantes utiles

- **User sans nouvelle base** : étape 1 seulement (rôle dans `01-cluster.yaml`).
- **Options de rôle** (`managed.roles`) : `superuser`, `createdb`, `createrole`,
  `inRoles: [...]`, `connectionLimit`, `ensure: absent` (suppression).
- **Supprimer une base** : `ensure: absent` dans `02-db-<app>.yaml` (protégée par
  `databaseReclaimPolicy: retain` → DROP manuel requis).
