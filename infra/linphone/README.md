# Téléphonie — provisionnement des clients Linphone

Le PBX **n'est pas dans le cluster** : FreePBX/Asterisk tourne sur une VM ESXi.
Ce namespace ne fournit que la **configuration des softphones Linphone**,
publiée en HTTPS et récupérée par les clients au démarrage.

```
Linphone (desktop / Android / iOS)
   │  1. GET https://linphone.ffd.link/provisioning/linphone-ffd.xml   (cluster k8s)
   │     → domaine SIP, transport, SRTP, codecs — aucun identifiant
   │  2. l'utilisateur saisit son extension + mot de passe
   ▼
FreePBX / Asterisk  (VM ESXi, hors cluster)  ── SIP 5061/TLS ── RTP
```

| Élément | Adresse |
|---------|---------|
| Fichier de provisionnement | `https://linphone.ffd.link/provisioning/linphone-ffd.xml` |
| Page d'aide (lien cliquable) | `https://linphone.ffd.link/` |
| PBX visé par le fichier | `pbx.ffd.link:5061` (TLS) — **à adapter à ta VM** |

Exposition publique assumée : un téléphone en 4G doit pouvoir récupérer sa
configuration. Le fichier ne contient aucun secret, et CrowdSec s'applique.

---

## 1. Adapter le fichier à ton FreePBX

Un seul bloc à modifier dans `provisioning.yaml`, section
`proxy_default_values` :

```xml
<entry name="reg_proxy" overwrite="true">&lt;sip:pbx.ffd.link:5061;transport=tls&gt;</entry>
<entry name="reg_identity" overwrite="true">sip:?@pbx.ffd.link</entry>
<entry name="realm" overwrite="true">asterisk</entry>
```

- `pbx.ffd.link` → nom DNS (ou IP) de la VM FreePBX. Un nom est préférable à une
  IP : indispensable si tu passes en TLS, le certificat ne pouvant pas valider
  une adresse IP.
- **Sans TLS** (installation FreePBX par défaut, UDP 5060 en clair) :
  `&lt;sip:pbx.ffd.link:5060;transport=udp&gt;`, et passer `media_encryption` à
  `none` dans la section `sip`.
- `realm` : `asterisk` est la valeur par défaut de chan_pjsip ; la vérifier si
  elle a été personnalisée sur le PBX.

Le `?` de `reg_identity` est remplacé par le nom d'utilisateur saisi dans
l'assistant Linphone.

---

## 2. Côté FreePBX (VM ESXi)

Rien n'est géré par ce dépôt — pour mémoire, ce que le fichier suppose :

### Extensions

*Applications → Extensions → Add New PJSIP Extension*

| Réglage | Valeur |
|---------|--------|
| User Extension | ex. `1001` |
| Secret | mot de passe long, unique par poste |
| Transport | `0.0.0.0-tls` si TLS, sinon `0.0.0.0-udp` |
| Media Encryption | `SRTP via in-SDP` si TLS, sinon `None` |
| NAT (`rtp_symmetric`, `force_rport`, `rewrite_contact`) | activés (défaut FreePBX) |
| Codecs | `g722`, `alaw`, `ulaw` (+ `opus` si `codec_opus` est installé) |
| Max Contacts | `2` (desktop + mobile) |

### Transport TLS (optionnel mais recommandé)

*Admin → Certificate Manager* pour importer un certificat, puis
*Settings → Asterisk SIP Settings → SIP Settings [chan_pjsip]* → ajouter un
transport `tls` sur `0.0.0.0:5061`. Le nom présenté aux clients doit
correspondre au certificat (donc au `reg_proxy` ci-dessus).

### Accès depuis l'extérieur

Si les postes se connectent hors LAN, côté VM / pare-feu :

- *Settings → Asterisk SIP Settings* : **External Address** = IP publique,
  **Local Networks** = le(s) réseau(x) LAN de l'ESXi.
- Redirections : `5061/TCP` (ou `5060/UDP`) + la plage RTP (`10000-20000/UDP`
  par défaut, réductible).
- Ne jamais exposer `5060/UDP` en clair sans fail2ban actif : ce port est
  balayé en continu par les robots SIP. Vérifier aussi
  *Allow Anonymous Inbound SIP Calls = No* et des limites d'appels sortants.

Le cluster n'intervient pas dans ce flux : aucune NetworkPolicy ni service
Kubernetes n'est concerné par le SIP.

---

## 3. Appliquer la configuration sur un poste

1. **Lien direct** (mobile) — ouvrir `https://linphone.ffd.link/` et toucher le
   bouton, qui déclenche
   `linphone-config://https://linphone.ffd.link/provisioning/linphone-ffd.xml`.
2. **Saisie manuelle** — Linphone → *Paramètres → Avancé → URL de configuration
   distante* → coller l'URL du XML, puis redémarrer l'application.
3. **Ligne de commande** (Linphone desktop) :
   `linphone --remote-provisioning https://linphone.ffd.link/provisioning/linphone-ffd.xml`

Linphone re-télécharge le fichier à chaque démarrage (`config-uri`) : modifier
le ConfigMap suffit à faire évoluer tout le parc au redémarrage suivant.

---

## 4. Provisionnement complet (avec identifiants)

Pour livrer un poste sans aucune saisie, le XML doit contenir la section
`auth_info_0` — donc **le mot de passe SIP en clair** :

```xml
<section name="auth_info_0">
  <entry name="username" overwrite="true">1001</entry>
  <entry name="userid" overwrite="true">1001</entry>
  <entry name="passwd" overwrite="true">LE_SECRET_DE_L_EXTENSION</entry>
  <entry name="realm" overwrite="true">asterisk</entry>
  <entry name="domain" overwrite="true">pbx.ffd.link</entry>
</section>
<section name="proxy_0">
  <entry name="reg_proxy" overwrite="true">&lt;sip:pbx.ffd.link:5061;transport=tls&gt;</entry>
  <entry name="reg_identity" overwrite="true">sip:1001@pbx.ffd.link</entry>
  <entry name="reg_sendregister" overwrite="true">1</entry>
</section>
```

Un tel fichier **ne doit pas être commité** : le stocker dans OpenBao
(`kv/kubernetes/linphone/provisioning/<extension>`), le projeter via un
ExternalSecret monté dans le pod nginx, et le servir sous un chemin non
devinable (`/provisioning/p/<uuid>.xml`) restreint au LAN via le middleware
`traefik-local-only@kubernetescrd`.

---

## 5. Dépannage

| Symptôme | Piste |
|----------|-------|
| Linphone ignore la configuration | vérifier le XML : `curl -s https://linphone.ffd.link/provisioning/linphone-ffd.xml \| xmllint --noout -` ; redémarrer complètement l'application (le fichier n'est lu qu'au démarrage) |
| Configuration appliquée mais pas d'enregistrement | c'est côté PBX/réseau : `pbx.ffd.link` résolu depuis le poste ? port `5061`/`5060` joignable ? `asterisk -rx "pjsip show contacts"` sur la VM |
| Erreur TLS | le nom du `reg_proxy` doit correspondre au certificat du PBX ; un certificat auto-signé est refusé par Linphone |
| 401/403 permanent | secret de l'extension, `realm`, horloge du poste |
| Son unidirectionnel | `External Address` / `Local Networks` sur la VM, redirections RTP du pare-feu |

Côté cluster :

```bash
kubectl -n linphone get pods,ingress
kubectl -n linphone logs deploy/linphone-provisioning
```
