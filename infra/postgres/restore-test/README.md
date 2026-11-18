# Restauration de `pg-main` et test

Sauvegardes : base chaque nuit (02:00) + WAL en continu, 30 jours, vers
`s3://pg-backups/pg-main` (S3 du NAS), via le plugin Barman Cloud
(`infra/postgres/03-backup.yaml`).

> Une sauvegarde qui n'a jamais été restaurée n'est pas une sauvegarde.
> **Refaire ce test chaque trimestre** et après tout changement de
> l'ObjectStore.

Ce dossier n'est **pas** synchronisé par ArgoCD (`directory.recurse: false`).

## 0. Vérifier que les sauvegardes tournent

```bash
kubectl -n database get objectstore,scheduledbackup,backup
kubectl -n database get cluster pg-main -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}{"\n"}'
```

`ContinuousArchiving` doit être `True` et au moins un `Backup` en `completed`.

## 1. Test de restauration (sans toucher à la production)

```bash
# 1. Sauvegarde à la demande, pour tester avec des données fraîches
B=pg-main-manual-$(date +%Y%m%d%H%M)
kubectl -n database apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: $B, namespace: database }
spec:
  method: plugin
  cluster: { name: pg-main }
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
YAML
kubectl -n database wait --for=jsonpath='{.status.phase}'=completed backup/$B --timeout=10m

# 2. Restaurer dans un cluster jetable (n'archive rien)
kubectl apply -f infra/postgres/restore-test/restore-cluster.yaml
kubectl -n database wait --for=condition=Ready cluster/pg-restore-test --timeout=20m

# 3. Comparer source et restauration
infra/postgres/restore-test/verify.sh; echo "code retour : $?"

# 4. Nettoyer (supprime aussi son volume)
kubectl -n database delete cluster pg-restore-test
```

Codes retour de `verify.sh` :

| Code | Sens |
|------|------|
| 0 | Bases et nombres de lignes identiques : **test réussi** |
| 2 | Restauration légèrement en retard (écritures postérieures au dernier WAL archivé) : normal si une app écrit en continu ; relancer après une nouvelle sauvegarde à la demande |
| 1 | Base ou table manquante, ou plus de lignes que la source : **échec**, enquêter |

Consigner la date et le résultat du test (par exemple dans la PR ou le journal
d'exploitation).

## 2. Restaurer à un instant précis (PITR)

Dans `restore-cluster.yaml`, décommenter `recoveryTarget.targetTime` (UTC), par
exemple juste avant une suppression accidentelle, puis appliquer comme au § 1.
La date doit être postérieure à la fin de la plus ancienne sauvegarde de base.

## 3. Sinistre réel (perte de `pg-main`)

1. Vérifier que les clés S3 sont toujours dans OpenBao
   (`kubernetes/backup/s3`) et que l'ObjectStore existe.
2. Supprimer le Cluster `pg-main` cassé (garder l'ObjectStore et le bucket).
3. Recréer un Cluster `pg-main` avec `bootstrap.recovery` (comme
   `restore-cluster.yaml`) **et** `plugins` : pour l'archivage, utiliser un
   **`serverName` différent** (par ex. `pg-main-2`), sinon l'archivage refuse
   d'écrire dans un dossier non vide.
4. Remettre ensuite `01-cluster.yaml` en cohérence avec l'état restauré (Git est
   la source de vérité : ArgoCD reprendra la main).
5. Les secrets applicatifs (`zitadel-db`, etc.) sont régénérés par le Job
   `pg-secret-init` ; **les mots de passe des rôles doivent rester identiques**
   à ceux de la base restaurée. En cas de doute, vérifier avant de relancer
   les applications.
6. Ne pas oublier la **masterkey de Zitadel** (hors base, hors Git) : sans
   elle, les données chiffrées restaurées sont illisibles.

## Limites connues

- Le S3 du NAS est dans la même maison que le cluster : il ne protège pas d'un
  sinistre global (incendie, vol). Prévoir plus tard une réplication externe.
- `pg-main` n'a qu'une instance : l'ajout du plugin provoque un redémarrage
  court de la base.
