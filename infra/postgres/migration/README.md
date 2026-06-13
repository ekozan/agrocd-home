# Migration des données vers `pg-main` (Phase 2)

Ce dossier **n'est pas synchronisé par ArgoCD** (l'Application `postgres`
utilise `directory.recurse: false`). Une migration est une opération one-shot
que l'on déclenche et vérifie **manuellement**.

## Pré-requis (Phase 1 déjà déployée)

- L'opérateur `cloudnative-pg` tourne (`infra/03-cnpg-operator.yaml`).
- Le Cluster `pg-main` est `Cluster in healthy state` :
  ```bash
  kubectl -n database get cluster pg-main
  kubectl -n database get database   # zitadel/coder/gitea/litellm = Applied
  ```
- Les secrets de rôle existent et sont répliqués dans les namespaces apps :
  ```bash
  kubectl -n database get secret zitadel-db coder-db gitea-db litellm-db
  kubectl -n zitadel get secret zitadel-db   # idem coder/gitea/litellm
  ```
- Les **anciennes** instances PostgreSQL (Bitnami) sont **encore en place**.

## ⚠️ À vérifier AVANT de lancer

Les coordonnées des bases SOURCES suivent les conventions des charts mais
doivent être confirmées sur le cluster réel (nom de service, nom du secret et
de ses clés, nom d'utilisateur). Vérifier par exemple :

```bash
kubectl -n zitadel get svc,secret
kubectl -n coder   get svc,secret
kubectl -n gitea   get svc,secret
kubectl -n litellm get svc,secret
```

| App     | Service source (présumé)            | Secret source       | Clé mot de passe | User    | TLS |
|---------|-------------------------------------|---------------------|------------------|---------|-----|
| zitadel | `postgresql.zitadel.svc`            | `postgresql-auth`   | `postgres-password` | postgres | require |
| coder   | `postgresql.coder.svc`              | `postgresql-auth`   | `password`       | coder   | disable |
| gitea   | `gitea-postgresql.gitea.svc`        | `gitea-postgresql`  | `password`       | gitea   | disable |
| litellm | `litellm-postgresql.litellm.svc`   | `litellm-postgresql`| `password`       | llmproxy| disable |

> LiteLLM en particulier : confirmer que le chart déploie bien un PostgreSQL
> embarqué et le nom réel du service/utilisateur (`llmproxy` par défaut).

## Lancer une migration

Geler temporairement l'écriture (mettre l'app source à `replicas: 0` ou couper
le trafic) pour un dump cohérent, puis :

```bash
kubectl apply -f infra/postgres/migration/01-zitadel.yaml
kubectl -n zitadel logs -f job/migrate-zitadel
```

Répéter pour `02-coder.yaml`, `03-gitea.yaml`, `04-litellm.yaml`.

## Vérifier

```bash
# Exemple : nombre de tables migrées dans pg-main
kubectl -n database exec -it pg-main-1 -- psql -d zitadel \
  -c "\dt" -c "select count(*) from information_schema.tables;"
```

Une fois les données validées : procéder à la **bascule des applications**
(Phase 2, voir README racine), puis supprimer ces Jobs :

```bash
kubectl delete -f infra/postgres/migration/
```
