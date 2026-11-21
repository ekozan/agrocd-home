# Cache d'images Zot (NAS TrueNAS SCALE 24.10)

Cache « pull-through » pour docker.io, quay.io, ghcr.io et registry.k8s.io, hébergé
sur le NAS (`10.10.0.245:5000`), hors du cluster.

- Une image est téléchargée sur internet **une seule fois**, puis servie par le NAS.
- Les nœuds joignent le cache **par IP** : une image déjà en cache se télécharge sans DNS.
- Si le cache tombe, containerd repasse directement par les registres d'origine.
- **Rétention** : les tags qui n'ont pas été téléchargés depuis 30 jours sont supprimés, et le
  nettoyage automatique (GC) tourne toutes les 24 h. Une image supprimée est récupérée à
  nouveau à la demande suivante.
- **Accès** : lecture anonyme seulement. Seul le compte `admin` peut pousser ou supprimer, pour
  éviter qu'une machine du LAN dépose une image piégée sous un nom officiel.

## Installation sur le NAS (shell TrueNAS, en root)

```bash
mkdir -p /mnt/Erebor/apps/zot/config /mnt/Erebor/apps/zot/data
```

Copier `config.json` de ce dossier dans `/mnt/Erebor/apps/zot/config/`.

Mot de passe du compte `admin` (bcrypt, exigé par Zot) :

```bash
docker run --rm httpd:2.4-alpine htpasswd -nbB admin 'MOT_DE_PASSE' > /mnt/Erebor/apps/zot/config/htpasswd
```

Identifiants des registres amont : partir de `credentials.example.json`. Gardez seulement les
entrées que vous utilisez. S'il n'y en a aucune, mettez `{}` : les pulls se font alors en anonyme.

```bash
echo '{}' > /mnt/Erebor/apps/zot/config/credentials.json
```

Droits pour l'utilisateur `apps` (568) :

```bash
chown -R 568:568 /mnt/Erebor/apps/zot
```

```bash
chmod 600 /mnt/Erebor/apps/zot/config/credentials.json /mnt/Erebor/apps/zot/config/htpasswd
```

Ensuite : **Apps → Discover Apps → ⋮ → Install via YAML**, nom `zot`, puis coller `compose.yaml`.

Test depuis un poste du LAN :

```bash
curl -s http://10.10.0.245:5000/v2/_catalog
```

## Côté nœuds k3s

Une fois Zot démarré, lancer sur chaque nœud :

```bash
sudo ./node-setup/k3s-registries.sh
```

Après un pull, le dépôt apparaît dans `/v2/_catalog` (par exemple `docker.io/library/busybox`).
