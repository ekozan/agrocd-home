# VPS — k3s mono-nœud : sauvegarde et migration Longhorn → local-path

Le cluster du VPS n'est **pas** piloté par l'ArgoCD de ce dépôt : ce dossier
(hors des chemins `init/`, `infra/`, `dev/`, `chat/` synchronisés) ne contient
que des scripts à lancer à la main, en root, sur le VPS.

Pourquoi quitter Longhorn sur le VPS : sur un seul nœud il n'y a qu'un réplica,
donc aucune redondance, pour un coût en RAM/CPU (manager, CSI, instance-manager)
et en performance (iSCSI). `local-path` (fourni par k3s) écrit directement sur
le disque.

| Script | Rôle | Modifie le cluster ? |
|---|---|---|
| `scripts/01-collect-info.sh` | Inventaire (système, k3s, PVC, Longhorn, Helm, Rancher) | non |
| `scripts/02-backup.sh` | Base k3s, token + CA, manifests (Secrets compris), values Helm | non |
| `scripts/02b-backup-volumes.sh` | Contenu des volumes Longhorn : une archive tar.gz + sha256 par PVC | non (`STOP=1` : arrête les applis le temps de l'archive) |
| `scripts/03-migrate-pvc.sh` | Migre **un** PVC Longhorn → local-path, même nom | oui |
| `scripts/04-rollback-pvc.sh` | Remet un PVC migré sur son volume Longhorn | oui |
| `scripts/05-remove-rancher.sh` | Retire le Rancher local du VPS (simulation par défaut, `APPLY=1`) | oui |

## 0. Récupérer les scripts sur le VPS

```bash
git clone https://github.com/ekozan/agrocd-home.git /root/agrocd-home
cd /root/agrocd-home/vps/scripts
apt install -y jq sqlite3
```

## 1. Inventaire

```bash
bash 01-collect-info.sh
```

Affiche un résumé (`summary.txt`) : version et datastore k3s (SQLite ou etcd),
disques, StorageClasses, **liste des PVC et des volumes Longhorn** avec leur
taille réelle, pods qui les utilisent, releases Helm, présence de Rancher,
namespaces en Pod Security Admission. Aucun Secret exporté, tokens masqués.

## 2. Sauvegarde (avant toute migration)

```bash
bash 02-backup.sh
```

- Base k3s : `k3s etcd-snapshot save` (etcd) ou copie à chaud SQLite (`.backup`).
- `server/` sans la base (token, CA `server/tls` : indispensables pour restaurer).
- Toutes les ressources, par namespace, **Secrets compris** → dossier en `700`.
- Values Helm de chaque release.

Puis **copier la sauvegarde hors du VPS** (commande `rsync` affichée à la fin),
par exemple vers le TrueNAS.

Les **données des volumes** : `02b-backup-volumes.sh [namespace]` (à chaud par
défaut, `STOP=1` pour arrêter les applis pendant l'archive), dans
`/root/vps-backup-volumes-<date>/`. `03-migrate-pvc.sh` refait en plus une
archive applis arrêtées juste avant chaque bascule.

## 3. Plus de nouveaux volumes Longhorn

```bash
kubectl patch storageclass longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get sc
```

Si k3s a été installé avec `--disable local-storage`, `local-path` n'existe pas :
retirer cette option (`/etc/rancher/k3s/config.yaml` ou unit systemd) et
redémarrer k3s.

Les **charts Helm** (apps Rancher comprises) qui fixent
`storageClass: longhorn` dans leurs values : passer à `local-path` (ou vide)
avant leur prochaine mise à jour, sinon Helm tentera de modifier le
`storageClassName` d'un PVC existant (champ immuable) et l'upgrade échouera.

## 4. Migrer, un PVC à la fois

Commencer par un volume peu critique.

```bash
bash 03-migrate-pvc.sh <namespace> <pvc>
```

1. PV Longhorn d'origine passé en `Retain` : **jamais supprimé par le script**.
2. Deployments / StatefulSets qui montent le PVC mis à 0 (replicas notés).
3. Pod de copie (root, `debian:bookworm-slim`) : archive `data.tar.gz`, copie
   `cp -a` vers un PVC local-path temporaire, contrôle du nombre de fichiers et
   des md5 (`VERIFY=0` pour sauter le md5 d'un très gros volume).
4. Bascule : le PVC est recréé **avec le même nom** (labels, annotations Helm
   conservés) et lié au nouveau PV local-path → rien à changer dans les
   manifests ni les charts, StatefulSets compris.
5. Applications relancées.

Échec avant la bascule : tout est remis en l'état, applis relancées sur
Longhorn. L'état de chaque migration est dans `/root/vps-migration/<ns>_<pvc>/`.

Limites : pas de `ReadWriteMany` ni de `volumeMode: Block` (local-path ne les
gère pas). Un pod géré par une Job/CronJob/DaemonSet doit être arrêté à la main
(ex. `kubectl patch cronjob X -p '{"spec":{"suspend":true}}'`). Si un outil
GitOps (Fleet, ArgoCD) gère l'appli avec auto-heal, le suspendre pendant la
migration : il remettrait les replicas.

### Retour arrière

```bash
bash 04-rollback-pvc.sh <namespace> <pvc>
```

Recrée le PVC sur l'ancien volume Longhorn. Les écritures faites depuis la
migration restent sur le PV local-path (conservé) mais ne sont pas recopiées.

## 5. Vérifier, attendre, nettoyer

Garder les anciens volumes quelques jours. Ensuite :

```bash
# Anciens PV Longhorn (Released, Retain)
kubectl get pv | grep -E 'Released.*longhorn'
kubectl delete pv <pv>
# Le volume Longhorn reste : le supprimer dans l'UI Longhorn, ou
kubectl -n longhorn-system delete volumes.longhorn.io <pv>

# Plus aucun PVC Longhorn ?
kubectl get pvc -A -o wide | grep longhorn
```

Puis désinstaller Longhorn (garde-fou à lever d'abord) :

```bash
kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag --type merge -p '{"value":"true"}'
helm uninstall longhorn -n longhorn-system     # ou « Delete » de l'app dans Rancher
kubectl delete ns longhorn-system
rm -rf /var/lib/longhorn                       # données Longhorn sur le disque
```

Les PV local-path créés par la migration sont en `Retain` : supprimer un PVC
ne supprime pas ses données (`/var/lib/rancher/k3s/storage/pvc-…`), à effacer à
la main si besoin.

## 6. Sauvegardes régulières (ensuite)

Sur local-path, la sauvegarde des données n'est plus intégrée : à mettre en
place avec Velero + node-agent (Kopia) vers S3/TrueNAS, ou au minimum
`k3s etcd-snapshot` / `02-backup.sh` + archive de
`/var/lib/rancher/k3s/storage` en cron, copiées hors du VPS.

## Rancher : VPS importé dans le Rancher maison

Le VPS n'a plus de Rancher propre : il est importé (cluster `vps-ovh`) dans
`https://rancher2.server` (Rancher maison, v2.10.1). Fait le 2026-11-08 avec
`05-remove-rancher.sh`, qui exclut les CRD de k3s (`helm.cattle.io`,
`k3s.cattle.io`) et conserve cert-manager, Longhorn, Mailu, Traefik.

L'agent (`cattle-system/cattle-cluster-agent`) joint `rancher2.server`, nom
interne, par NetBird :

| Élément | Où |
|---|---|
| Client NetBird sur l'hôte du VPS (service systemd), groupe `vps` | `netbird status` |
| Ressource `10.100.0.1/32` (IP de `rancher2.server`) routée par `netbird-k8s-router`, policy `vps → rancher` TCP 443 | dashboard NetBird |
| Résolution pour les pods : ConfigMap `kube-system/coredns-custom` (clé `rancher.server`) | `kubectl -n kube-system get cm coredns-custom -o yaml` |
| Résolution pour l'hôte : `/etc/hosts` | `10.100.0.1 rancher2.server` |

Si `10.100.0.1` change : mettre à jour ces trois endroits, puis
`kubectl -n kube-system rollout restart deploy coredns`.

NetBird ou le Rancher maison coupé : le cluster passe en *Unavailable* dans
Rancher, mais le VPS (Mailu…) continue de tourner normalement ; `kubectl` en
local sur le VPS fonctionne toujours.

Dépôts de charts à déclarer sur `vps-ovh` dans le Rancher maison :
`mailu-charts` (https://mailu.github.io/helm-charts), `cert-manager`
(https://charts.jetstack.io), `cert-manager-webhook-ovh-charts`
(https://aureq.github.io/cert-manager-webhook-ovh/).
