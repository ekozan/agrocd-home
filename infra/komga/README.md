# Komga — médiathèque BD / mangas / eBooks (`komga.ffd.link`)

Déployée par l'App ArgoCD `infra/13-komga.yaml` (sync-wave 13, dernière
vague). Manifests bruts : PVC config Longhorn, PV/PVC bibliothèque SMB,
Deployment, Service, Ingress.

Komga est un **service de confort** : son pod porte
`priorityClassName: homelab-low` (valeur `-1000`, `preemptionPolicy: Never`),
la priorité la plus basse du cluster. Il est donc le **premier évincé** sous
pression mémoire/disque et ne préempte jamais un pod déjà placé.

## Stockage

| Volume | Classe | Taille | Contenu |
|--------|--------|--------|---------|
| `komga-config` → `/config` | `longhorn` (RWO) | 500 Mi | base SQLite, index Lucene, miniatures |
| `komga-library` → `/data` | PV statique SMB (RWX) | — | bibliothèque de livres (partage existant) |

**La bibliothèque n'est pas provisionnée** : on se branche sur un **partage
SMB déjà existant**. Le montage est assuré par le pilote `node-manual` de
democratic-csi (App `infra/04-csi-node-manual.yaml`), qui ne fait *que*
monter — il ne crée ni dataset ni share côté NAS.

Deux valeurs sont à renseigner dans le PV `komga-library`
(`volumeAttributes`) avant la première synchro :

```yaml
      server: <hôte ou IP du serveur SMB>
      share: <nom du partage>
```

Les identifiants réutilisent le Secret **existant**
`democratic-csi-smb-creds` (namespace `democratic-csi`, alimenté par
l'ExternalSecret `infra/post-externalsecrets/democratic-csi-smb-creds.yaml`
depuis OpenBao : `kv/kubernetes/democratic-csi/smb-credentials`, clé
`mount_flags` au format `username=…,password=…`).

> **Pré-requis nœuds** : le montage cifs s'exécute sur le nœud →
> `cifs-utils` doit être installé sur les workers (même prérequis que
> `nfs-common` pour le CSI NFS).

Le PV est en `persistentVolumeReclaimPolicy: Retain` et pré-lié au PVC via
`claimRef` : supprimer l'app ne touche pas au contenu du partage.

### Alimenter la bibliothèque

Komga **n'accepte pas d'upload de livre depuis le navigateur** :
`POST /api/v1/books/import` ne reçoit qu'un chemin `sourceFile` côté serveur,
et l'écran *Import > Books* de l'UI parcourt le système de fichiers du
conteneur. Les fichiers se déposent donc directement sur le partage SMB
(depuis un poste, rsync, la GUI du NAS…), puis Komga les détecte au scan.
Seules les vignettes/posters s'envoient en multipart (≤ 1 Mo, défauts Spring).

## Authentification OIDC (Zitadel)

Le login local Komga reste actif ; un bouton **« FFD Link »** est ajouté sur
la page de connexion.

### 1. Application OIDC dans Zitadel

Créer une application **Web** (code flow + client secret) :

| Champ | Valeur |
|-------|--------|
| Redirect URI | `https://komga.ffd.link/login/oauth2/code/zitadel` |
| Post-logout URI | `https://komga.ffd.link/` |
| Scopes | `openid`, `profile`, `email` |

> L'identifiant d'enregistrement `zitadel` (dernier segment de l'URL de
> callback) est celui utilisé dans les variables
> `SPRING_SECURITY_OAUTH2_CLIENT_*_ZITADEL_*` du Deployment : changer l'un
> impose de changer l'autre.

### 2. Secret OpenBao

```
kv/kubernetes/komga/zitadel
  client_id     = <client id Zitadel>
  client_secret = <client secret Zitadel>
```

Lu par l'ExternalSecret `komga-oidc` (ClusterSecretStore `openbao-backend`)
→ Secret `komga-oidc` dans le namespace `komga`.

### 3. Comportement des comptes

- `KOMGA_OAUTH2_ACCOUNT_CREATION=true` : le compte Komga est créé à la
  première connexion OIDC. Sans cela, l'e-mail doit déjà exister côté Komga.
- Le rapprochement se fait sur l'**e-mail** (`USERNAMEATTRIBUTE=email`).
- Komga exige un e-mail **vérifié** côté IdP (claim `email_verified`, option
  `komga.oidc-email-verification`, activée par défaut).
- Le premier compte administrateur est celui créé au premier démarrage de
  Komga ; les comptes issus d'OIDC arrivent en utilisateur simple et sont à
  promouvoir depuis l'UI si besoin.
