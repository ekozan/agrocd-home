# Cache d'images Zot (NAS TrueNAS SCALE 24.10)

Cache « pull-through » pour docker.io, quay.io, ghcr.io et registry.k8s.io, hébergé
sur le NAS (`10.10.0.245:5000`), hors du cluster.

| Fichier | Rôle |
|---|---|
| [`config.json`](config.json) | Configuration Zot : sync à la demande, rétention, accès anonyme en lecture |
| [`compose.yaml`](compose.yaml) | App TrueNAS (*Install via YAML*) |
| [`credentials.example.json`](credentials.example.json) | Modèle d'identifiants des registres amont (le vrai fichier n'est **pas** dans Git) |
| [`../k3s-registries.sh`](../k3s-registries.sh) | Redirige containerd des nœuds k3s vers le cache |

## Fonctionnement

```
nœud k3s ──(IP, sans DNS)──▶ Zot 10.10.0.245:5000 ──(1er pull seulement)──▶ docker.io / quay.io / ghcr.io / registry.k8s.io
    └──────────── repli automatique si Zot ne répond pas ────────────▶ registre d'origine
```

- **Pull-through** : Zot télécharge une image la première fois qu'on la lui demande, la stocke
  dans `/mnt/Erebor/apps/zot/data`, puis la sert. Le catalogue est vide tant que rien n'a été
  demandé.
- **Sans DNS côté nœuds** : les nœuds joignent Zot par IP. Le conteneur Zot utilise lui-même
  1.1.1.1 / 9.9.9.9 (`dns:` dans `compose.yaml`), donc il ne dépend pas du resolver du NAS.
- **Repli** : si Zot est arrêté, containerd essaie ensuite le registre d'origine. Le cache ne peut
  donc pas bloquer le cluster.
- **Préfixes** : chaque registre est rangé sous son nom (`docker.io/library/nginx`,
  `quay.io/argoproj/argocd`…). Le `rewrite` de `registries.yaml` ajoute ce préfixe.
- **Rétention** : les tags qui n'ont pas été téléchargés depuis 30 jours sont supprimés, et le
  nettoyage automatique (GC) tourne toutes les 24 h. Une image supprimée est récupérée à
  nouveau à la demande suivante.
- **Accès** : lecture anonyme seulement. Seul le compte `admin` (fichier `htpasswd`) peut pousser
  ou supprimer, pour éviter qu'une machine du LAN dépose une image piégée sous un nom officiel
  (ex. `docker.io/library/nginx`).

## Installation sur le NAS (shell TrueNAS, en root)

1. Dossiers et configuration :

   ```bash
   mkdir -p /mnt/Erebor/apps/zot/config /mnt/Erebor/apps/zot/data
   ```

   ```bash
   curl -fsSL -o /mnt/Erebor/apps/zot/config/config.json https://raw.githubusercontent.com/ekozan/agrocd-home/main/node-setup/zot/config.json
   ```

2. Compte `admin` (bcrypt, exigé par Zot) :

   ```bash
   docker run --rm httpd:2.4-alpine htpasswd -nbB admin 'MOT_DE_PASSE' > /mnt/Erebor/apps/zot/config/htpasswd
   ```

3. Identifiants amont : `{}` pour tout faire en anonyme. Pour ajouter des tokens, voir
   [Identifiants](#identifiants).

   ```bash
   echo '{}' > /mnt/Erebor/apps/zot/config/credentials.json
   ```

4. Droits pour l'utilisateur `apps` (568). **À refaire après chaque fichier ajouté ou
   remplacé** :

   ```bash
   chown -R 568:568 /mnt/Erebor/apps/zot
   ```

   ```bash
   chmod 600 /mnt/Erebor/apps/zot/config/credentials.json /mnt/Erebor/apps/zot/config/htpasswd
   ```

5. Vérifier la configuration **avant** de lancer l'app. Le résultat attendu est
   `config file is valid`, sans `warn` :

   ```bash
   docker run --rm -v /mnt/Erebor/apps/zot/config:/etc/zot:ro ghcr.io/project-zot/zot-linux-amd64:v2.1.23 verify /etc/zot/config.json
   ```

6. **Apps → Discover Apps → ⋮ → Install via YAML**, nom `zot`, puis coller `compose.yaml`.

7. Tests depuis le LAN. Le premier pull doit renvoyer `200`, puis l'image doit apparaître dans le
   catalogue :

   ```bash
   curl -s http://10.10.0.245:5000/v2/docker.io/library/busybox/manifests/latest -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' -o /dev/null -w '%{http_code}\n'
   ```

   ```bash
   curl -s http://10.10.0.245:5000/v2/_catalog
   ```

## Identifiants

Trois niveaux, chacun à un endroit différent :

| Qui → quoi | Où | Nécessaire ? |
|---|---|---|
| Nœuds → Zot | rien (lecture anonyme) | — |
| Zot → registres amont | `config/credentials.json` sur le NAS | Docker Hub conseillé (limites anonymes par IP), les autres sont optionnels |
| Humain → Zot (push/suppression) | `config/htpasswd` sur le NAS | seulement pour gérer le cache à la main |

Format de `credentials.json` : la clé est **exactement** le nom d'hôte présent dans `urls` de
`config.json` (`registry-1.docker.io`, `quay.io`, `ghcr.io`, `registry.k8s.io`). Un registre
absent du fichier est utilisé en anonyme.

Tokens à créer :

- **Docker Hub** : *Account settings → Personal access tokens*, permission **Public Repo
  Read-only**.
- **ghcr.io** : PAT GitHub **classic** avec uniquement `read:packages`. Les tokens
  *fine-grained* ne fonctionnent pas avec ghcr.io. Ce n'est pas le même token que celui
  d'ArgoCD.

Écrire le fichier sans que les tokens apparaissent à l'écran ni dans l'historique du shell :

```bash
read -rp "Utilisateur Docker Hub : " DU; read -rsp "Token Docker Hub : " DT; echo; read -rp "Utilisateur GitHub : " GU; read -rsp "PAT GitHub (classic) : " GT; echo
```

```bash
DU="$DU" DT="$DT" GU="$GU" GT="$GT" python3 -c 'import json,os; json.dump({"registry-1.docker.io":{"username":os.environ["DU"],"password":os.environ["DT"]},"ghcr.io":{"username":os.environ["GU"],"password":os.environ["GT"]}}, open("/mnt/Erebor/apps/zot/config/credentials.json","w"), indent=2)'
```

```bash
unset DU DT GU GT
```

```bash
chown 568:568 /mnt/Erebor/apps/zot/config/credentials.json && chmod 600 /mnt/Erebor/apps/zot/config/credentials.json
```

Zot ne lit ce fichier qu'au démarrage : **redémarrer l'app** après chaque modification. Les
tokens expirent : pensez à les renouveler.

## Côté nœuds k3s

Une fois Zot démarré, lancer sur chaque nœud :

```bash
sudo ./node-setup/k3s-registries.sh
```

Le script écrit `/etc/rancher/k3s/registries.yaml` (l'ancien fichier est sauvegardé dans
`registries.yaml.pre-zot`) puis redémarre k3s. Les pods en cours ne sont pas interrompus.
Vérification sur le nœud :

```bash
sudo k3s crictl pull docker.io/library/busybox:latest
```

### Sans accès SSH au nœud (NetBird en panne, etc.)

`kubectl` suffit. `kubectl debug node` lance un pod privilégié qui monte l'hôte dans `/host`.
Son image doit **déjà être présente** sur le nœud, puisque les pulls sont justement en panne.

1. Trouver une image locale qui contient un shell :

   ```bash
   kubectl get node <node> -o jsonpath='{range .status.images[*]}{.names[-1]}{"\n"}{end}' | grep -iE "busybox|alpine|traefik|klipper"
   ```

2. Lancer le pod de debug. Il affiche son nom, `node-debugger-<node>-xxxxx`, noté `<pod>`
   ci-dessous :

   ```bash
   kubectl debug node/<node> --image=<image-locale> --profile=sysadmin -- sleep 3600
   ```

3. Copier le script sur l'hôte :

   ```bash
   kubectl exec -i <pod> -- chroot /host sh -c 'cat > /root/k3s-registries.sh' < node-setup/k3s-registries.sh
   ```

4. Le lancer **détaché** : le redémarrage de k3s coupe la session `kubectl exec`.

   ```bash
   kubectl exec <pod> -- chroot /host sh -c 'setsid nohup bash /root/k3s-registries.sh > /root/node-setup.log 2>&1 &'
   ```

5. Lire le résultat 1 à 2 minutes plus tard. Pendant le redémarrage de k3s, `kubectl` peut
   échouer quelques dizaines de secondes :

   ```bash
   kubectl exec <pod> -- chroot /host cat /root/node-setup.log
   ```

6. Nettoyer :

   ```bash
   kubectl delete pod <pod>
   ```

## Dépannage

| Symptôme | Cause / correction |
|---|---|
| App en `Restarting`, logs `open /etc/zot/config.json: no such file or directory` | `config.json` absent de `/mnt/Erebor/apps/zot/config/` : refaire l'étape 1 |
| `permission denied` dans les logs | fichier n'appartenant pas à `568:568` : refaire l'étape 4 |
| `warn … dist-spec version differs` | `distSpecVersion` à aligner sur la version indiquée par Zot (sans gravité) |
| `401` / `unauthorized` vers un registre amont | token ou utilisateur faux dans `credentials.json`. Mettre `{}` pour repasser en anonyme, puis redémarrer l'app |
| `_catalog` vide | normal tant qu'aucune image n'a été demandée |
| Pods en `ImagePullBackOff` sur un seul nœud | problème local à ce nœud (DNS ou disque) : `kubectl cordon <node>`, supprimer les pods bloqués pour qu'ils repartent ailleurs, réparer le nœud, puis `kubectl uncordon <node>` |

Logs de l'app :

```bash
docker logs --tail 30 ix-zot-zot-1
```

Pour voir la cause d'un pull raté côté cluster, l'événement `BackOff` ne suffit pas : il faut la
section `Events` du pod :

```bash
kubectl -n <ns> describe pod <pod> | grep -A3 -iE "failed|error"
```
