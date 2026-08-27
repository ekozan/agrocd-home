# Téléphonie — FreePBX (izPBX) + clients Linphone

IPBX du homelab : **Asterisk 20 + FreePBX 16** (image [izPBX](https://github.com/ugoviti/izpbx)),
avec une base **MariaDB** dédiée et un serveur de **provisionnement Linphone**.

| Composant | Adresse | Exposition |
|-----------|---------|------------|
| Administration FreePBX | `https://pbx.ffd.link` | Traefik — **LAN uniquement** (`local-only`) + CrowdSec |
| Provisionnement Linphone | `https://pbx.ffd.link/provisioning/linphone-ffd.xml` | Traefik — public, CrowdSec (aucun identifiant) |
| Signalisation SIP | `sip.ffd.link:5061` (TLS), `:5060` (UDP/TCP) | Service LoadBalancer MetalLB `freepbx-sip` |
| Média RTP/SRTP | `sip.ffd.link:10000-10019/UDP` | Service LoadBalancer MetalLB `freepbx-sip` |

> **Pourquoi deux noms DNS ?** Le SIP n'est pas de l'HTTP : il ne peut pas
> transiter par Traefik et réclame sa propre IP MetalLB. `pbx.ffd.link` pointe
> vers Traefik (interface web), `sip.ffd.link` vers le LoadBalancer SIP. Le
> certificat wildcard `*.ffd.link` couvre les deux, ce qui permet à Linphone de
> valider le TLS présenté par Asterisk.

---

## 1. Pré-requis

### Secrets OpenBao

```
kv/kubernetes/freepbx/db
  password        # mot de passe de l'utilisateur MariaDB `asterisk`
  root_password   # mot de passe root MariaDB (création de la base CDR au 1er démarrage)
```

Aucun autre secret : le certificat TLS provient du wildcard `ffd-link-tls`
(cert-manager, répliqué dans tous les namespaces par kubernetes-replicator).

### DNS

| Nom | Cible |
|-----|-------|
| `pbx.ffd.link` | IP du LoadBalancer Traefik |
| `sip.ffd.link` | IP du LoadBalancer `freepbx-sip` |

Pour figer l'IP SIP (recommandé — elle est écrite dans la config des postes),
décommenter l'annotation dans `freepbx.yaml` :

```yaml
metallb.universe.tf/loadBalancerIPs: "10.10.x.y"
```

puis récupérer l'IP attribuée :

```bash
kubectl -n freepbx get svc freepbx-sip -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

---

## 2. Premier démarrage

L'installation de FreePBX et de ses modules en base prend **10 à 20 minutes**.
La `startupProbe` tolère jusqu'à 30 minutes avant de déclarer l'échec.

```bash
kubectl -n freepbx logs -f deploy/freepbx
```

Deux points d'attention au tout premier déploiement :

1. **Compte administrateur** : à la première visite de `https://pbx.ffd.link`,
   FreePBX demande de créer le compte admin. Le faire immédiatement, avant
   toute autre chose.
2. **Transport TLS différé** : l'initContainer `asterisk-custom-conf` n'écrit
   `pjsip_custom.conf` que si `/data/etc/asterisk` existe déjà — pour ne pas
   perturber l'initialisation de l'image. Le transport TLS (5061) n'est donc
   actif qu'après **un redémarrage du pod** :

   ```bash
   kubectl -n freepbx rollout restart deploy/freepbx
   kubectl -n freepbx exec deploy/freepbx -- asterisk -rx "pjsip show transports"
   ```

   `transport-tls` doit apparaître en `bind 0.0.0.0:5061`.

---

## 3. Configuration FreePBX

### Réglages SIP globaux

*Settings → Asterisk SIP Settings*

| Réglage | Valeur |
|---------|--------|
| External Address | `sip.ffd.link` |
| Local Networks | *(vide)* — voir note ci-dessous |
| RTP Port Ranges | `10000` → `10019` |
| Allow Anonymous Inbound SIP Calls | **No** |
| Allow SIP Guests | **No** |

> **Local Networks vide, volontairement.** Aucun client SIP ne vit dans le
> réseau de pods : tous les correspondants sont « externes » et doivent
> recevoir l'adresse du LoadBalancer dans le SDP. Déclarer le LAN en réseau
> local ferait annoncer l'IP interne du pod (`10.42.x.x`), inatteignable → son
> unidirectionnel garanti.

La plage RTP doit rester identique aux trois endroits :
`APP_PORT_RTP_START/END` (Deployment), ports du Service `freepbx-sip`, et ce
réglage FreePBX.

### Extensions (une par utilisateur Linphone)

*Applications → Extensions → Add New PJSIP Extension*

| Réglage | Valeur |
|---------|--------|
| User Extension | ex. `1001` |
| Secret | mot de passe long généré (jamais réutilisé, jamais dans Git) |
| Transport | `transport-tls` (0.0.0.0:5061) |
| Media Encryption | `SRTP via in-SDP` |
| NAT / rtp_symmetric, force_rport, rewrite_contact | activés (valeurs par défaut FreePBX) |
| Codecs | `g722`, `alaw`, `ulaw` (+ `opus` si `codec_opus` est installé) |
| Max Contacts | `2` (softphone desktop + mobile) |

Vérification côté serveur :

```bash
kubectl -n freepbx exec deploy/freepbx -- asterisk -rx "pjsip show endpoints"
kubectl -n freepbx exec deploy/freepbx -- asterisk -rx "pjsip show contacts"
```

---

## 4. Provisionnement des clients Linphone

Le fichier `linphone-ffd.xml` (ConfigMap `linphone-provisioning`) porte tout ce
qui est commun au parc : proxy `sip.ffd.link:5061` en TLS, SRTP, domaine SIP,
codecs, visio désactivée. L'utilisateur ne saisit que **son extension** et
**son mot de passe SIP**.

Trois façons de l'appliquer :

1. **Lien direct** (mobile) — ouvrir `https://pbx.ffd.link/provisioning/` et
   toucher le bouton, qui déclenche
   `linphone-config://https://pbx.ffd.link/provisioning/linphone-ffd.xml`.
2. **Saisie manuelle** — Linphone → *Paramètres → Avancé → URL de configuration
   distante* → coller l'URL du XML, puis redémarrer l'application.
3. **Ligne de commande** (Linphone desktop) :
   `linphone --remote-provisioning https://pbx.ffd.link/provisioning/linphone-ffd.xml`

Linphone re-télécharge le fichier à chaque démarrage (`config-uri`) : modifier
le ConfigMap suffit à faire évoluer tout le parc.

### Provisionnement complet (avec identifiants)

Pour livrer un poste sans aucune saisie, le XML doit contenir la section
`auth_info_0` — donc **le mot de passe SIP en clair** :

```xml
<section name="auth_info_0">
  <entry name="username" overwrite="true">1001</entry>
  <entry name="userid" overwrite="true">1001</entry>
  <entry name="passwd" overwrite="true">LE_SECRET_DE_L_EXTENSION</entry>
  <entry name="realm" overwrite="true">asterisk</entry>
  <entry name="domain" overwrite="true">sip.ffd.link</entry>
</section>
<section name="proxy_0">
  <entry name="reg_proxy" overwrite="true">&lt;sip:sip.ffd.link:5061;transport=tls&gt;</entry>
  <entry name="reg_identity" overwrite="true">sip:1001@sip.ffd.link</entry>
  <entry name="reg_sendregister" overwrite="true">1</entry>
</section>
```

Un tel fichier **ne doit pas être commité** : le stocker dans OpenBao
(`kv/kubernetes/freepbx/provisioning/<extension>`), le projeter via un
ExternalSecret monté dans le pod nginx, et servir l'URL sous un chemin non
devinable (`/provisioning/p/<uuid>.xml`) restreint au LAN.

---

## 5. Exposer le SIP à l'extérieur

Par défaut, la NetworkPolicy `allow-sip-from-lan`
(`infra/network-policies/freepbx.yaml`) n'autorise que les réseaux
`10.10.0.0/16` et `10.5.0.0/16` : un softphone en mobilité ne peut pas
s'enregistrer.

Pour ouvrir, ajouter une policy dédiée limitée au **TLS** et au média :

```yaml
ingress:
  - from:
      - ipBlock: { cidr: 0.0.0.0/0 }
    ports:
      - { protocol: TCP, port: 5061 }
      - { protocol: UDP, port: 10000, endPort: 10019 }
```

Ne jamais ouvrir le `5060` en clair : il est balayé en continu par les robots
SIP. Compléments indispensables avant ouverture : secrets d'extension longs et
uniques, `Allow Anonymous Inbound SIP Calls = No`, limites d'appels sortants
(*Outbound Route → Call Limits*) et surveillance des CDR.

---

## 6. Dépannage

| Symptôme | Piste |
|----------|-------|
| Linphone ne s'enregistre pas (408/timeout) | DNS `sip.ffd.link` → IP du LB ; `kubectl -n freepbx get svc freepbx-sip` ; NetworkPolicy `allow-sip-from-lan` |
| Échec TLS côté client | `pjsip show transports` ; certificat monté sur `/certs` ; le nom utilisé doit être `sip.ffd.link` (le wildcard ne couvre pas une IP) |
| 401/403 permanent | secret de l'extension ; `realm` (`asterisk`) ; horloge du client |
| Son unidirectionnel | `External Address = sip.ffd.link`, `Local Networks` vide, plage RTP alignée (Deployment / Service / FreePBX) |
| Appel coupé après ~30 s | ACK perdu : vérifier `rewrite_contact`/`force_rport` sur l'extension |
| Plus de 10 appels simultanés | plage RTP saturée : élargir `APP_PORT_RTP_END`, les ports du Service et le réglage FreePBX |

Logs utiles :

```bash
kubectl -n freepbx logs -f deploy/freepbx
kubectl -n freepbx exec -it deploy/freepbx -- asterisk -rvvv
kubectl -n freepbx exec deploy/freepbx -- asterisk -rx "pjsip set logger on"
```

---

## 7. Limites connues et choix assumés

- **Réplique unique.** Asterisk garde ses enregistrements SIP et ses appels en
  mémoire, `/data` est un volume RWO : pas de scale-out possible. Un
  redémarrage coupe les appels en cours.
- **10 appels simultanés.** Kubernetes ne sait pas publier une plage de ports :
  les 20 ports RTP sont énumérés un par un dans le Service. Élargir la plage
  alourdit d'autant le manifest et kube-proxy.
- **MariaDB plutôt que `pg-main`.** FreePBX ne supporte que MySQL/MariaDB. La
  base reste confinée au namespace, avec ses propres secrets.
- **NFS.** InnoDB tourne avec `--innodb-use-native-aio=0` (io_submit échoue sur
  NFS). En cas de corruption ou de lenteur, envisager un stockage bloc.
- **fail2ban désactivé.** Il pilote iptables, ce qui exigerait `CAP_NET_ADMIN`
  dans le pod. La protection repose sur les NetworkPolicies (SIP au LAN) et
  CrowdSec (interface web).
- **Si le son reste unidirectionnel** malgré une configuration correcte : le
  RTP sortant du pod est SNAT-é par kube-proxy. Le repli éprouvé est de passer
  le pod en `hostNetwork: true` (une seule instance par nœud, ports SIP/RTP pris
  directement sur le nœud) — à documenter ici si ce cas se présente.
- **Image communautaire.** izPBX est le portage conteneurisé le mieux maintenu
  de FreePBX (il n'existe pas d'image officielle Sangoma) ; le tag est épinglé
  et suivi par Renovate.
