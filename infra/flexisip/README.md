# Flexisip — proxy SIP et notifications push devant FreePBX

FreePBX tourne sur une VM ESXi et ne sait pas envoyer de notifications push.
Résultat : sur mobile, un softphone en veille ne sonne pas. Flexisip (proxy SIP
de Belledonne, l'éditeur de Linphone) se place devant le PBX et réveille les
téléphones par APNs / Firebase.

```
Linphone ──sips:5061──► Flexisip (cluster, sip.ffd.link) ──sip:5060──► FreePBX (ESXi, pbx.ffd.link)
   ▲                        │  REGISTER relayé, la liaison n'est retenue
   └── push APNs / FCM ◄────┘  qu'après le 200 OK du PBX (reg-on-response)

   Média RTP : direct entre le poste et FreePBX (aucun relais dans le cluster)
```

Ce que ça change côté FreePBX : **rien**. Les comptes, mots de passe et le
dialplan restent sur le PBX ; Flexisip ne fait que relayer les REGISTER et
mémoriser où joindre chaque poste.

---

## ⚠️ Le push ne marche pas avec le Linphone du store

Un jeton push appartient à l'application qui l'a obtenu :

- **Android** : le jeton est émis pour le projet **Firebase** de l'application.
  L'application Linphone du Play Store est enregistrée dans le projet de
  Belledonne — seul leur serveur peut lui envoyer un push.
- **iOS** : le jeton est lié au **bundle id** et au certificat APNs
  correspondant, là encore ceux de Belledonne.

Pour du push auto-hébergé, il faut donc **recompiler l'application** avec le
[SDK Linphone](https://gitlab.linphone.org/BC/public/linphone-sdk), ton propre
bundle id / `google-services.json`, puis fournir ici le certificat APNs et le
compte de service Firebase correspondants.

Sans cela, ce déploiement reste utile — TLS de bout en bout, enregistrement
multi-appareils, `fork-late`, un seul point d'entrée SIP public — mais un appel
entrant ne réveillera pas une application mise en veille par le système.

---

## 1. Pré-requis

### DNS

| Nom | Cible |
|-----|-------|
| `sip.ffd.link` | IP du LoadBalancer `flexisip-sip` (MetalLB) |
| `pbx.ffd.link` | IP de la VM FreePBX (ESXi) |

Figer l'IP MetalLB (elle est écrite dans la config de tous les postes) en
décommentant l'annotation dans `flexisip.yaml` :

```yaml
metallb.universe.tf/loadBalancerIPs: "10.10.x.y"
```

```bash
kubectl -n flexisip get svc flexisip-sip -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

### Image

Le registre de Belledonne n'était pas joignable depuis l'environnement de
préparation : **vérifier le tag avant le premier sync**.

```bash
docker pull gitlab.linphone.org:4567/bc/public/flexisip:2.6.1
```

### Côté FreePBX

- Autoriser l'IP de Flexisip (celle du LoadBalancer, ou celle des nœuds du
  cluster) dans *Connectivity → Firewall* si le module est actif.
- Les extensions restent des extensions PJSIP classiques ; l'authentification
  ne bouge pas. Vérifier que `rtp_symmetric`, `force_rport` et
  `rewrite_contact` sont actifs (valeurs par défaut FreePBX) : le média arrive
  depuis l'adresse réelle du poste, pas depuis Flexisip.
- Le PBX doit accepter les REGISTER relayés par Flexisip : c'est du SIP
  standard, mais si le PBX filtre par IP, ajouter celle du proxy.

---

## 2. Routage vers le PBX

Deux endroits, dans le ConfigMap `flexisip-config` :

```ini
# flexisip.conf
transports=sips:sip.ffd.link:5061;maddr=0.0.0.0 sip:sip.ffd.link:5060;maddr=0.0.0.0
```

`maddr` est l'adresse d'écoute réelle (le pod ne peut pas se lier à l'IP du
LoadBalancer) ; la partie hôte de l'URI est le nom **annoncé** aux clients, qui
doit correspondre au certificat TLS.

```ini
# routes.conf — <route SIP>   <filtre>
<sip:pbx.ffd.link:5060;transport=udp>   true
```

Tout ce que le module `Router` n'a pas dirigé vers un poste enregistré part
vers le PBX. Si ton PBX écoute en TLS : `<sips:pbx.ffd.link:5061>`.

> Si des boucles apparaissent (requêtes renvoyées au PBX qui en viennent),
> restreindre le filtre plutôt que de le laisser à `true`, par exemple sur le
> domaine de la requête : `request.uri.domain == 'pbx.ffd.link'`.

---

## 3. Activer le push

1. Obtenir les identifiants de **ton** application (cf. avertissement ci-dessus) :
   - iOS : certificat APNs au format PEM (certificat + clé privée concaténés),
     nommé `<appid>.prod.pem`, plus `<appid>.voip.prod.pem` pour PushKit
     (indispensable aux appels entrants) ;
   - Android : le fichier JSON du compte de service Firebase et le numéro du
     projet.
2. Les déposer dans OpenBao :
   ```
   kv/kubernetes/flexisip/apns      { prod_pem, voip_prod_pem }
   kv/kubernetes/flexisip/firebase  { service_account }
   ```
3. Renommer `push-credentials.yaml.example` en `push-credentials.yaml` (le
   fichier `.example` est ignoré par ArgoCD) et adapter les noms de fichiers à
   ton app id.
4. Décommenter dans `flexisip.conf` :
   ```ini
   firebase-service-accounts=<numéro de projet>:/etc/flexisip/firebase/firebase.json
   ```
5. Redémarrer : `kubectl -n flexisip rollout restart deploy/flexisip`.

Les volumes sont déclarés `optional: true` : tant que les Secrets n'existent
pas, Flexisip démarre normalement, sans push.

Côté client, le fichier de provisionnement Linphone
(`infra/linphone/provisioning.yaml`) pose déjà `push_notification_allowed=1` :
c'est ce qui fait ajouter les paramètres `pn-provider` / `pn-prid` / `pn-param`
au Contact du REGISTER, seule source d'information de Flexisip pour joindre
APNs ou FCM.

---

## 4. Vérifications

```bash
kubectl -n flexisip logs -f deploy/flexisip
kubectl -n flexisip get svc flexisip-sip

# Postes enregistrés (le registre est en mémoire, il repart à zéro au redémarrage)
kubectl -n flexisip exec deploy/flexisip -- flexisip_cli.py REGISTRAR_DUMP
```

| Symptôme | Piste |
|----------|-------|
| Aucun enregistrement | DNS `sip.ffd.link`, NetworkPolicy `allow-sip-from-lan`, `routes.conf` (le REGISTER doit atteindre le PBX) |
| REGISTER rejeté 401/403 | c'est le PBX qui répond : identifiants de l'extension |
| Erreur TLS côté client | le nom joint doit être `sip.ffd.link` (certificat wildcard) |
| Appel entrant qui ne sonne que app ouverte | comportement attendu sans identifiants push valides (cf. avertissement) |
| Son unidirectionnel | réglages NAT/RTP du PBX (External Address, plage RTP, redirections) — le média ne passe pas par le cluster |
| Boucle de routage | filtre de `routes.conf` trop large, ou `aliases` incomplet dans `flexisip.conf` |

---

## 5. Limites et choix assumés

- **Instance unique, registre en mémoire** (`db-implementation=internal`) : un
  redémarrage force les postes à se ré-enregistrer (quelques secondes). Pour de
  la haute disponibilité, passer le registre sur Redis
  (`redis-server-domain`/`redis-server-port`) et augmenter les réplicas.
- **Pas de relais média** : `module::MediaRelay` est désactivé, sinon il
  faudrait publier toute une plage de ports UDP par un Service Kubernetes, qui
  ne sait pas exposer de plage. Le RTP va donc directement du poste au PBX, qui
  doit rester joignable des clients.
- **Authentification déléguée** au PBX (`reg-on-response=true`) : aucun compte
  n'est dupliqué, mais Flexisip ne peut rien faire tant que le PBX est
  injoignable.
- **Serveur de présence non déployé** (`--server proxy`) : la présence Linphone
  demanderait un serveur supplémentaire et une base.
