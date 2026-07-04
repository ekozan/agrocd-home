# Stratégie de backup & restauration

Ce document décrit la stratégie de sauvegarde du cluster k3s / Rancher /
Longhorn et les procédures de restauration (disaster recovery).

La sauvegarde repose sur des **couches complémentaires, sans doublon** : chaque
donnée a UN outil principal, choisi selon sa nature.

| Couche | Quoi | Outil | Backend | Géré dans ce repo |
|--------|------|-------|---------|-------------------|
| 1 | **PostgreSQL `pg-main`** (toutes les bases applicatives) | CNPG `barmanObjectStore` (base + WAL → **PITR**) | S3 | `infra/postgres/` |
| 2 | **Volumes Longhorn** (RocksDB Tuwunel, caches, LAPI…) | Longhorn `BackupTarget` + `RecurringJob` | S3 | `infra/longhorn-backup/` |
| 3 | **Ressources K8s** (Secrets runtime hors Git : clés LiveKit, LAPI CrowdSec, mots de passe des rôles PG…) + **volumes NFS TrueNAS en opt-in** (fichiers OxiCloud, médias Matrix) | Velero (+ node-agent Kopia) | S3 | `infra/13-velero.yaml` |
| 4 | **État déclaratif** (manifests, Applications) | Git + ArgoCD | GitHub | tout le repo |
| hors repo | Snapshots ZFS TrueNAS, snapshots etcd k3s, snapshots Raft OpenBao | TrueNAS / k3s / OpenBao | — | §7, §8 |

**Pourquoi ce découpage (vs « Velero sauvegarde tout ») :**

- `pg-main` : un snapshot de volume d'une base active n'est que
  *crash-consistent* et ne permet qu'un retour à J-1. Le backup natif CNPG
  archive les WAL en continu → restauration **à la minute près** (PITR).
  Le RecurringJob Longhorn couvre quand même le volume en 2e filet.
- Volumes Longhorn : backup **incrémental au niveau bloc**, bien plus efficace
  qu'une relecture filesystem Kopia. Velero ne les re-sauvegarde pas
  (`defaultVolumesToFsBackup: false`).
- Volumes NFS TrueNAS (`freenas-nfs-csi`) : invisibles pour Longhorn → couverts
  par Velero/Kopia en **opt-in** (annotation de pod
  `backup.velero.io/backup-volumes: <volume>`) + snapshots ZFS côté TrueNAS.
- Ressources K8s : Git décrit la *forme*, mais les Secrets générés au runtime
  (Jobs generate-once) n'existent que dans le cluster → Velero les capture.

---

## 1. Secrets à provisionner dans OpenBao / Vault

Les credentials S3 ne sont **jamais** committés : ils sont injectés via
External-Secrets depuis le `ClusterSecretStore` `openbao-backend`.
Créer les secrets KV (v2) suivants **avant** la première synchro :

```bash
# Couche 1 — CNPG (pg-main)
bao kv put kv/kubernetes/cnpg/backup-s3 \
  access_key="<ACCESS_KEY>" secret_key="<SECRET_KEY>"

# Couche 2 — Longhorn
bao kv put kv/kubernetes/longhorn/backup-s3 \
  access_key="<ACCESS_KEY>" secret_key="<SECRET_KEY>" \
  endpoints="https://s3.ffd.link:9000"

# Couche 3 — Velero
bao kv put kv/kubernetes/velero/s3 \
  access_key="<ACCESS_KEY>" secret_key="<SECRET_KEY>"
```

> Recommandé : **trois buckets distincts** (`cnpg`, `longhorn`, `velero`) et un
> utilisateur S3 dédié au backup avec des droits limités à ces buckets
> (idéalement en *object-lock/versioning* pour résister à un ransomware).
> ⚠ Si `kv/kubernetes/cnpg/backup-s3` manque au moment du sync, l'archivage
> WAL de pg-main passe en erreur (le cluster continue de servir, mais le
> backup est KO → à provisionner en premier).

## 2. Paramètres à adapter avant déploiement

| Fichier | Champ | À adapter |
|---------|-------|-----------|
| `infra/postgres/01-cluster.yaml` | `backup.barmanObjectStore.destinationPath` / `endpointURL` | bucket + endpoint CNPG |
| `infra/longhorn-backup/backuptarget.yaml` | `spec.backupTargetURL` | bucket Longhorn (`s3://<bucket>@us-east-1/`) |
| `infra/13-velero.yaml` | `bucket`, `config.s3Url` | bucket + endpoint Velero |

> Pour **AWS S3 natif** : retirer `s3Url` + `s3ForcePathStyle` (Velero),
> `endpointURL` (CNPG), et laisser `endpoints` vide (Longhorn).

## 3. Planification (fenêtres décalées)

| Heure | Couche | Job | Rétention |
|-------|--------|-----|-----------|
| 01:00 | Longhorn | `snapshot-daily` (snapshot local) | 7 |
| 02:00 | Longhorn | `backup-daily` (S3) | 14 |
| 03:00 (dim.) | Longhorn | `backup-weekly` (S3) | 8 |
| 03:30 | CNPG | `pg-main-daily` (base complète ; WAL en continu) | 30 j |
| 04:00 | Velero | `daily-full` (ressources + volumes opt-in) | 30 j (720h) |

## 4. Vérifier l'état des backups

```bash
# --- CNPG (couche 1) ---
kubectl -n database get scheduledbackup,backup
kubectl -n database describe cluster pg-main | grep -A5 "Continuous Archiving"

# --- Longhorn (couche 2) ---
kubectl -n longhorn-system get backuptarget default
kubectl -n longhorn-system get recurringjob
kubectl -n longhorn-system get backupvolume

# --- Velero (couche 3, CLI velero recommandée) ---
velero backup-location get
velero schedule get
velero backup get && velero backup describe daily-full-<timestamp> --details
```

---

## 5. Procédures de restauration

### 5.1 PostgreSQL — PITR (couche 1)

Restauration dans un **nouveau** Cluster CNPG (bootstrap `recovery`), puis
bascule des applications :

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-restore
  namespace: database
spec:
  instances: 1
  storage: { size: 10Gi, storageClass: longhorn }
  bootstrap:
    recovery:
      source: pg-main
      recoveryTarget:
        targetTime: "2026-07-04 09:45:00+02:00"   # instant voulu (PITR)
  externalClusters:
    - name: pg-main
      barmanObjectStore:
        destinationPath: s3://cnpg/pg-main
        endpointURL: https://s3.ffd.link:9000
        s3Credentials:
          accessKeyId: { name: cnpg-backup-s3, key: ACCESS_KEY_ID }
          secretAccessKey: { name: cnpg-backup-s3, key: SECRET_ACCESS_KEY }
```

Valider les données, puis soit renommer/basculer les services, soit recréer
`pg-main` par recovery et resynchroniser ArgoCD.

### 5.2 Volume Longhorn (couche 2)

UI Longhorn → **Backup** → volume → **Restore**, puis recréer le PVC lié.
Cas d'usage : perte/corruption d'un volume applicatif unique.

### 5.3 Application complète / Secrets runtime (couche 3 — Velero)

```bash
velero restore create --from-schedule daily-full --include-namespaces <ns>
velero restore get && velero restore describe <restore-name> --details
```

Cas d'usage : suppression accidentelle d'un namespace, récupération d'un
Secret généré au runtime (clé LiveKit, LAPI…), fichiers OxiCloud/médias Matrix
(volumes opt-in Kopia).

### 5.4 Disaster recovery — cluster complet

**Règle d'or : les données d'abord (Velero/CNPG/Longhorn), la forme ensuite
(ArgoCD).** Avec `selfHeal`+`prune` actifs, ArgoCD se bat contre un restore.

```
1. Réinstaller k3s + Rancher/Longhorn + ArgoCD (auto-sync PAS encore lancé)
   — ou restaurer l'etcd k3s si snapshot disponible (§8)
2. Injecter à la main le secret S3 de Velero (chicken-and-egg : OpenBao
   n'est pas encore là) puis installer Velero seul
3. velero restore → Secrets runtime + volumes NFS opt-in
4. Restaurer pg-main par recovery CNPG (§5.1) et les volumes Longhorn (§5.2)
5. kubectl apply -f appproject.yaml init.yaml infra.yaml dev.yaml chat.yaml
   → ArgoCD adopte l'existant et complète depuis Git
```

> Neutraliser l'auto-sync d'une app le temps d'un restore :
> `kubectl -n argocd patch application <app> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`
> (le bloc `automated` reste dans Git ; un sync le rétablit).

### 5.5 Protection des PVC contre le prune (`Prune=false`)

Les PVC de données suivis par ArgoCD portent
`argocd.argoproj.io/sync-options: Prune=false` : une suppression d'app dans le
repo ne détruit pas le volume.

| PVC | Où |
|-----|-----|
| Gitea (dépôts git) | `infra/06 gitea.yaml` → `persistence.annotations` |
| Tuwunel `tuwunel-data` / `tuwunel-media` | `chat/tuwunel.yaml` |
| OxiCloud `oxicloud-storage` | `infra/oxicloud/oxicloud.yaml` |

> Les PVC issus d'un `volumeClaimTemplate` (StatefulSets Bitnami, pg-main via
> CNPG) ne sont pas suivis par ArgoCD : ils survivent déjà au prune. Les PVC de
> cache (euro-office, crowdsec-web-ui) sont volontairement non protégés
> (reconstructibles).

---

## 6. OpenBao — le backup le plus critique (hors repo)

Sans OpenBao, **aucune** restauration ci-dessus n'est possible (tous les
credentials S3 et secrets applicatifs en dépendent). OpenBao tournant hors de
ce repo :

- backend Raft : `bao operator raft snapshot save backup.snap` (cron quotidien
  sur son hôte, snapshot chiffré poussé vers un stockage **hors site**) ;
- conserver les **unseal/recovery keys hors ligne** (coffre/papier), jamais
  dans le cluster ;
- tester une restauration complète (unseal compris) au moins une fois.

## 7. Données TrueNAS (ZFS, hors repo)

Les datasets NFS (fichiers OxiCloud, médias Matrix) et le bucket S3 (MinIO)
vivent sur TrueNAS. En complément de Velero :

- **Periodic Snapshot Tasks** ZFS : horaires (rétention 24 h) + quotidiens
  (30 j) — snapshots immuables côté serveur, résistants à un ransomware
  côté client NFS ;
- **Replication Task** (`zfs send`) vers une seconde machine ou un cloud :
  c'est la copie hors site de la règle 3-2-1.

## 8. Snapshots etcd k3s (hors repo)

```yaml
# /etc/rancher/k3s/config.yaml (sur les nœuds server)
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 14
etcd-s3: true
etcd-s3-endpoint: s3.ffd.link:9000
etcd-s3-bucket: k3s-etcd
etcd-s3-access-key: <ACCESS_KEY>
etcd-s3-secret-key: <SECRET_KEY>
```

```bash
k3s etcd-snapshot save            # manuel
k3s etcd-snapshot ls              # lister
k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>  # restaurer
```

## 9. Tester régulièrement

Un backup non testé n'est pas un backup :

- **Mensuel** : `velero restore` d'un namespace dans un namespace temporaire ;
- **Trimestriel** : recovery CNPG vers un cluster `pg-restore-test` +
  restauration d'un volume Longhorn depuis S3 ;
- surveiller les CRD `Backup`/`Restore`/`RecurringJob` en état `Failed`
  (et la condition `ContinuousArchiving` du Cluster pg-main).
