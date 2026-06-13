# Stratégie de backup & restauration

Ce document décrit la stratégie de sauvegarde complète du cluster k3s / Rancher /
Longhorn et les procédures de restauration (disaster recovery).

La sauvegarde repose sur **trois couches complémentaires** :

| Couche | Quoi | Outil | Backend | Géré dans ce repo |
|--------|------|-------|---------|-------------------|
| 1 | **Données des volumes** (PV) | Longhorn `BackupTarget` + `RecurringJob` | S3 | `infra/longhorn-backup/` |
| 2 | **État complet du cluster** (ressources K8s + données de volumes) | Velero + node-agent (Kopia) | S3 | `infra/09-velero.yaml` |
| 3 | **État déclaratif** (manifests Helm / Applications) | Git + ArgoCD | Ce dépôt | tout le repo |

> Couche 1 = restauration fine et efficace (block-level) volume par volume.
> Couche 2 = restauration complète, autonome, même cluster vierge.
> Couche 3 = reconstruction GitOps + sauvegarde régulière de l'etcd k3s (voir plus bas).

---

## 1. Secrets à provisionner dans OpenBao / Vault

Les credentials S3 ne sont **jamais** committés : ils sont injectés via
External-Secrets depuis le `ClusterSecretStore` `openbao-backend`.

Créer les deux secrets KV (v2) suivants avant la première synchro :

### `kubernetes/longhorn/backup-s3`
| Propriété | Description |
|-----------|-------------|
| `access_key` | Access key S3 |
| `secret_key` | Secret key S3 |
| `endpoints` | URL de l'endpoint S3 (ex: `https://s3.ffd.link:9000`). Vide pour AWS natif. |

```bash
bao kv put kv/kubernetes/longhorn/backup-s3 \
  access_key="<ACCESS_KEY>" \
  secret_key="<SECRET_KEY>" \
  endpoints="https://s3.ffd.link:9000"
```

### `kubernetes/velero/s3`
| Propriété | Description |
|-----------|-------------|
| `access_key` | Access key S3 |
| `secret_key` | Secret key S3 |

```bash
bao kv put kv/kubernetes/velero/s3 \
  access_key="<ACCESS_KEY>" \
  secret_key="<SECRET_KEY>"
```

> Les deux couches peuvent partager le même utilisateur S3, mais il est
> recommandé d'utiliser **deux buckets distincts** (`longhorn` et `velero`).

---

## 2. Paramètres à adapter avant déploiement

| Fichier | Champ | À adapter |
|---------|-------|-----------|
| `infra/longhorn-backup/backuptarget.yaml` | `spec.backupTargetURL` | nom du bucket Longhorn (`s3://<bucket>@us-east-1/`) |
| `infra/09-velero.yaml` | `bucket` | nom du bucket Velero |
| `infra/09-velero.yaml` | `config.s3Url` | endpoint S3 (MinIO/TrueNAS) |

> Pour **AWS S3 natif** : retirer `s3Url` + `s3ForcePathStyle` côté Velero, et
> laisser `endpoints` vide côté Longhorn (la région de l'URL suffit).

---

## 3. Planification

### Longhorn (couche 1)
| Job | Tâche | Cron | Rétention |
|-----|-------|------|-----------|
| `snapshot-daily` | snapshot local | `0 1 * * *` | 7 |
| `backup-daily` | backup S3 | `0 2 * * *` | 14 |
| `backup-weekly` | backup S3 | `0 3 * * 0` | 8 |

Le groupe spécial `default` couvre automatiquement **tous** les volumes non
assignés à un autre job.

### Velero (couche 2)
| Schedule | Cron | Rétention (TTL) | Contenu |
|----------|------|-----------------|---------|
| `daily-full` | `0 4 * * *` | 720h (30 j) | toutes ressources + volumes (Kopia), hors `kube-system` |

---

## 4. Vérifier l'état des backups

```bash
# --- Longhorn ---
kubectl -n longhorn-system get backuptarget default
kubectl -n longhorn-system get recurringjob
kubectl -n longhorn-system get backup        # backups de volumes
kubectl -n longhorn-system get backupvolume

# --- Velero (CLI velero recommandée) ---
velero backup-location get
velero schedule get
velero backup get
velero backup describe daily-full-<timestamp> --details
```

---

## 5. Procédures de restauration

### 5.1 Restaurer un volume Longhorn (couche 1)

Via l'UI Longhorn → **Backup** → sélectionner le volume → **Restore**, ou en CLI :

```bash
# Lister les backups disponibles
kubectl -n longhorn-system get backupvolume

# La restauration se fait depuis l'UI Longhorn ou en créant un Volume
# référençant le backup (fromBackup). Le PVC est ensuite recréé et lié.
```

Cas d'usage : perte/corruption d'un volume applicatif unique. Rapide et ciblé.

### 5.2 Restaurer une application complète (couche 2 — Velero)

```bash
# Restauration d'un namespace entier depuis le dernier backup planifié
velero restore create --from-schedule daily-full \
  --include-namespaces <namespace>

# Suivi
velero restore get
velero restore describe <restore-name> --details
velero restore logs <restore-name>
```

Cas d'usage : suppression accidentelle d'un namespace, rollback d'un état runtime
non présent dans Git.

### 5.3 Disaster recovery — cluster complet reconstruit

1. **Réinstaller k3s + Rancher + Longhorn** (couche 3 / infra de base).
2. **Restaurer l'etcd k3s** si snapshot disponible (voir §6) — sinon repartir
   d'un cluster vierge.
3. **Réinstaller ArgoCD**, puis appliquer les Applications racines :
   ```bash
   kubectl apply -f init.yaml
   kubectl apply -f infra.yaml   # recrée External-Secrets, OpenBao, Velero, etc.
   ```
   > ⚠️ Velero a besoin des credentials S3 : s'assurer qu'OpenBao est restauré
   > et descellé, ou injecter temporairement le secret `velero-cloud-credentials`
   > à la main pour permettre la restauration.
4. **Reconnecter Velero au bucket** et restaurer l'état runtime :
   ```bash
   velero backup get                       # les backups sont re-synchronisés
   velero restore create --from-backup daily-full-<timestamp>
   ```
5. **Reconnecter Longhorn au backupstore** (le `BackupTarget` est recréé par
   GitOps) puis restaurer les volumes critiques depuis l'UI/CLI.

> Ordre recommandé : OpenBao → External-Secrets → Velero (ressources) →
> Longhorn (données volumes). ArgoCD reconstruit le reste automatiquement.

---

## 6. Snapshots etcd k3s (couche 3 — hors GitOps)

L'état du control-plane (etcd) n'est pas dans ce repo. k3s sait en faire des
snapshots automatiques, à pousser vers S3 pour survivre à la perte du nœud :

```bash
# Sur le serveur k3s — extrait de /etc/rancher/k3s/config.yaml
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 14
etcd-s3: true
etcd-s3-endpoint: s3.ffd.link:9000
etcd-s3-bucket: k3s-etcd
etcd-s3-access-key: <ACCESS_KEY>
etcd-s3-secret-key: <SECRET_KEY>
```

```bash
# Snapshot manuel
k3s etcd-snapshot save
# Lister
k3s etcd-snapshot ls
# Restaurer (cluster arrêté)
k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>
```

> Cette configuration vit sur les nœuds k3s (Rancher), pas dans ce dépôt GitOps.

---

## 7. Tester régulièrement

Un backup non testé n'est pas un backup. Recommandé :

- **Mensuel** : `velero restore` d'un namespace de test dans un namespace temporaire.
- **Trimestriel** : restauration d'un volume Longhorn depuis le backupstore S3.
- Surveiller l'échec des `RecurringJob` Longhorn et des `Schedule` Velero
  (alerting sur les CRD `Backup`/`Restore` en statut `Failed`).
