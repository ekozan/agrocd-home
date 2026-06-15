# NetworkPolicies — segmentation réseau (durcissement #1)

Objectif : **casser le mouvement latéral est-ouest**. Sans policy, le réseau du
cluster est plat : tout pod compromis peut joindre directement PostgreSQL, le
LAPI CrowdSec, OpenBao, etc. Ces manifests posent un **default-deny en ingress**
par namespace, puis rouvrent explicitement les seuls flux légitimes.

## Choix de conception

- **Ingress uniquement** (pas d'egress). On bloque les connexions *entrantes*
  non autorisées vers chaque service, ce qui suffit à empêcher le mouvement
  latéral. L'egress reste ouvert → aucun risque de casser DNS, l'accès à
  OpenBao/ACME/Anthropic, ni le pull des charts Helm.
- **`traefik` n'est pas inclus** : c'est l'ingress controller, exposé à Internet
  par design (gain de sécurité faible, risque de casse élevé). En revanche
  chaque backend autorise explicitement `traefik → service`.
- Sélection des namespaces sources via le label automatique
  `kubernetes.io/metadata.name` (présent sur tout namespace depuis k8s 1.21),
  donc aucun label custom à ajouter.

## Périmètre couvert

| Namespace | Flux entrants autorisés |
|-----------|-------------------------|
| `crowdsec` | LAPI ← Traefik (bouncer) ; intra-namespace (agent → LAPI) |
| `matrix` | Traefik → tuwunel/livekit/lk-jwt ; média LiveKit ← Internet (7881/7882) ; intra-namespace |
| `zitadel` | Traefik → namespace ; intra-namespace (zitadel/login → PostgreSQL) |
| `gitea` | Traefik → namespace ; intra-namespace (gitea/runner → PostgreSQL/Valkey) |
| `coder` | Traefik → namespace ; intra-namespace (coder → PostgreSQL) |
| `litellm` | intra-namespace ; `coder` → :4000 *(hypothèse, à valider)* |

## ⚠️ Points à vérifier après déploiement

- **Sondes kubelet** : sur certains CNI stricts, un default-deny ingress peut
  bloquer les readiness/liveness probes (trafic issu du nœud). La plupart des
  CNI (Calico, Cilium) l'autorisent par défaut. Vérifier que les pods restent
  `Ready` après application.
- **Consommateurs de LiteLLM** : seul `coder` est autorisé par hypothèse. Si
  d'autres services appellent le proxy, ajouter leur namespace dans
  `litellm.yaml`.
- **egress** : non couvert ici. C'est l'étape suivante du durcissement réseau
  (limiter l'exfiltration), à traiter à part car plus risquée.
