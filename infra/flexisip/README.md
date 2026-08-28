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

## Comment le push fonctionne ici

Un jeton push n'est adressable que par le détenteur des identifiants de
l'application : le certificat APNs pour iOS, le projet Firebase pour Android.
Avec l'application Linphone du store, ces identifiants sont ceux de Belledonne
— impossible de les détenir.

D'où le mode retenu : **Flexisip délègue l'envoi au serveur de push de
Belledonne**. Il ne parle pas directement à Apple et Google, il poste une
requête HTTP authentifiée sur leur API (FlexiAPI) et leur infrastructure émet
le push avec les bons certificats.

```ini
[global::flexiapi]
url=https://subscribe.linphone.org/api/
api-key=<injectée depuis le Secret flexisip-flexiapi>

[module::PushNotification]
external-push-flexiapi=true
apple=false
firebase=false
```

Il faut donc **une clé d'API obtenue auprès de Belledonne** : le push pour des
comptes SIP tiers est une prestation de leur côté (les comptes
`sip.linphone.org` en bénéficient nativement, pas les autres). Tant que le
Secret `flexisip-flexiapi` n'existe pas, l'initContainer bascule
`external-push-flexiapi=false` et Flexisip démarre sans push — aucun
CrashLoop.

**Variante « certificats en propre »** : si l'application est recompilée à
partir du [SDK Linphone](https://gitlab.linphone.org/BC/public/linphone-sdk)
avec ton propre bundle id et ton propre projet Firebase, Flexisip peut pousser
en direct — remettre `apple=true` / `firebase=true`, `external-push-flexiapi=false`
et fournir les Secrets `flexisip-apns` / `flexisip-firebase`
(cf. `push-credentials.yaml.example`). Côté Android c'est gratuit (projet
Firebase + APK distribué hors store) ; côté iOS il faut un compte Apple
Developer et un certificat PushKit.

Dans les deux cas, le réveil ne fonctionne que si le client annonce ses
paramètres `pn-provider` / `pn-prid` / `pn-param` dans le Contact de son
REGISTER — c'est ce que déclenche `push_notification_allowed=1`, déjà posé par
le fichier de provisionnement (`infra/linphone/provisioning.yaml`).

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

### Mode par défaut — serveur de Belledonne

1. Obtenir une clé d'API auprès de Belledonne (le push vers l'app Linphone pour
   un serveur SIP tiers passe par leur service) et confirmer l'URL de base de
   l'API, renseignée dans `flexisip.conf` → `[global::flexiapi] url`.
2. Déposer la clé dans OpenBao :
   ```
   kv/kubernetes/flexisip/flexiapi { api_key }
   ```
3. Renommer `push-credentials.yaml.example` en `push-credentials.yaml` (le
   `.example` est ignoré par ArgoCD) en ne gardant que l'ExternalSecret
   `flexisip-flexiapi`.
4. `kubectl -n flexisip rollout restart deploy/flexisip` — le log de
   l'initContainer doit afficher « Pusher externe (FlexiAPI) activé. ».

### Variante — certificats en propre (application recompilée)

1. Déposer dans OpenBao le certificat APNs (PEM : certificat + clé privée,
   plus le `.voip.prod.pem` PushKit, indispensable aux appels entrants) et/ou
   le compte de service Firebase :
   ```
   kv/kubernetes/flexisip/apns      { prod_pem, voip_prod_pem }
   kv/kubernetes/flexisip/firebase  { service_account }
   ```
2. Garder les ExternalSecrets `flexisip-apns` / `flexisip-firebase` du modèle.
3. Dans `flexisip.conf` : `external-push-flexiapi=false`, `apple=true`,
   `firebase=true`, `apple-certificate-dir=/etc/flexisip/apn`,
   `firebase-service-accounts=<numéro de projet>:/etc/flexisip/firebase/firebase.json`.
   Les noms de fichiers du Secret APNs doivent porter l'app id
   (`<appid>.prod.pem`).

---

## 4. Vérifications

```bash
kubectl -n flexisip logs -f deploy/flexisip
kubectl -n flexisip logs deploy/flexisip -c render-config   # push délégué actif ou non
kubectl -n flexisip get svc flexisip-sip
```

### Les postes sont-ils enregistrés, avec leurs paramètres push ?

Le registre est en mémoire (il repart à zéro à chaque redémarrage) :

```bash
kubectl -n flexisip exec deploy/flexisip -- flexisip_cli.py REGISTRAR_DUMP
kubectl -n flexisip exec deploy/flexisip -- flexisip_cli.py REGISTRAR_GET sip:1001@pbx.ffd.link
```

Le Contact d'un poste mobile doit porter les paramètres de la RFC 8599 —
c'est la seule information dont dispose Flexisip pour demander un push :

| Paramètre | Contenu |
|-----------|---------|
| `pn-provider` | `apns` (iOS production), `apns.dev` (iOS développement), `fcm` (Android) |
| `pn-param` | identifiant de l'application : `<ProjectID>` pour FCM, `<TeamID>.<BundleID>` pour APNs (suffixé `.voip` pour PushKit) |
| `pn-prid` | jeton de l'instance de l'application sur cet appareil |

S'ils sont absents, le problème est côté client (`push_notification_allowed`,
ou build de l'application sans service push) — pas côté Flexisip.

### Émettre un push de test

L'image embarque l'outil `flexisip_pusher` :

```bash
# Android (certificats en propre)
kubectl -n flexisip exec deploy/flexisip -- flexisip_pusher \
  --key /etc/flexisip/firebase/firebase.json --pn-provider fcm \
  --pn-param '<ProjectID>' --pn-prid '<jeton>'

# iOS PushKit (certificats en propre)
kubectl -n flexisip exec deploy/flexisip -- flexisip_pusher \
  --prefix /etc/flexisip --pn-provider apns \
  --pn-param '<TeamID>.<BundleID>.voip' --pn-prid '<jeton>' \
  --apple-push-type PushKit
```

⚠️ Cet outil parle **directement** à Apple/Google : il ne teste donc que la
variante « certificats en propre ». En mode délégué (FlexiAPI), la
vérification passe par les logs de Flexisip et ses compteurs `count-pn-sent` /
`count-pn-failed`.

| Symptôme | Piste |
|----------|-------|
| Aucun enregistrement | DNS `sip.ffd.link`, NetworkPolicy `allow-sip-from-lan`, `routes.conf` (le REGISTER doit atteindre le PBX) |
| REGISTER rejeté 401/403 | c'est le PBX qui répond : identifiants de l'extension |
| Erreur TLS côté client | le nom joint doit être `sip.ffd.link` (certificat wildcard) |
| Appel entrant qui ne sonne que app ouverte | push inactif : Secret `flexisip-flexiapi` absent (voir le log de l'initContainer), clé d'API invalide, ou Contact sans paramètres `pn-*` |
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
