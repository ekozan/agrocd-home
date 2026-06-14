# Instance PostgreSQL centralisée `pg-main`

Une seule instance CloudNativePG héberge **une base par application**, chacune
avec son **rôle propriétaire**.

## Layout

| Fichier | Rôle |
|---------|------|
| `00-secrets-init.yaml` | Job de bootstrap : génère 1 Secret `basic-auth` par rôle initial (répliqué vers le namespace de l'app) |
| `05-certificate.yaml` | Certificat serveur TLS (cert-manager `my-ca-issuer`) |
| `06-ca-bundle.yaml` | ConfigMap `pg-main-ca` (CA pour `verify-full` côté client) |
| `10-cluster.yaml` | Cluster `pg-main` + **rôles** (`spec.managed.roles`) |
| `db-<app>.yaml` | **Une base par application** (CRD `Database`) |
| `migration/` | Jobs `pg_dump`/`pg_restore` one-shot (**non** synchronisés par ArgoCD) |

> Le rôle et la base sont **deux objets distincts** : CNPG n'a pas de CRD `Role`,
> les rôles sont un sous-champ du `Cluster`. Le rôle vit donc dans
> `10-cluster.yaml`, la base dans son propre fichier `db-<app>.yaml`.

> ⚠️ L'Application ArgoCD `postgres` est en `directory.recurse: false` : seuls
> les fichiers `.yaml` **à la racine** de ce dossier sont synchronisés. Garder
> les nouvelles bases ici (pas dans un sous-dossier).

## Ajouter une nouvelle application (ex. `grafana`)

### 1. Générer le Secret du mot de passe (one-off)

CNPG ne génère pas les mots de passe des rôles managés. Le Job `00-secrets-init`
ne couvre que les rôles initiaux ; pour un ajout, créer le Secret à la main
(`Job.spec.template` est immuable, ne pas modifier le Job existant) :

```bash
kubectl -n database create secret generic grafana-db \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=grafana \
  --from-literal=password=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c32)
kubectl -n database label   secret grafana-db cnpg.io/reload=true
kubectl -n database annotate secret grafana-db \
  replicator.v1.mittwald.de/replicate-to=grafana   # namespace de l'app
```

### 2. Déclarer le rôle dans `10-cluster.yaml`

Ajouter sous `spec.managed.roles` :

```yaml
      - name: grafana
        ensure: present
        login: true
        passwordSecret:
          name: grafana-db
```

### 3. Créer le fichier de la base `db-grafana.yaml`

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

### 4. Commit + push

ArgoCD synchronise : CNPG crée le rôle (avec le mot de passe du Secret) puis la
base. L'app se connecte via le Secret `grafana-db` sur
`pg-main-rw.database.svc/grafana`.

## Variantes utiles

- **User sans nouvelle base** : étape 2 seulement.
- **Options de rôle** (`managed.roles`) : `superuser`, `createdb`, `createrole`,
  `inRoles: [...]`, `connectionLimit`, `ensure: absent` (suppression).
- **Supprimer une base** : `ensure: absent` dans `db-<app>.yaml` (protégée par
  `databaseReclaimPolicy: retain` → DROP manuel requis).
