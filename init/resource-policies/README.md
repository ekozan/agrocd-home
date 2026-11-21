# Resource Policies — réservation CPU/mémoire & éviction

Politique de ressources du cluster, **sans aucun agent ni contrôleur
supplémentaire** : uniquement des mécanismes natifs Kubernetes (admission
LimitRange + scheduling/éviction kubelet). Coût runtime : zéro.

## Contenu

| Fichier | Rôle |
|---------|------|
| `limitranges.yaml` | Requests CPU/mémoire par défaut + limite mémoire par défaut, par namespace |
| `priorityclasses.yaml` | Classes de priorité pour ordonner éviction et préemption |

## Fonctionnement

### Réservation par défaut (LimitRange)

Tout conteneur déployé sans bloc `resources` reçoit automatiquement une
request CPU/mémoire (réservation vue par le scheduler) et une limite
mémoire. Pas de limite CPU par défaut : une limite CPU provoque du
throttling même quand le nœud est inoccupé, alors qu'une limite mémoire
protège réellement le nœud de l'OOM.

Trois profils selon le namespace :

| Profil | Namespaces | Request | Limite mémoire |
|--------|-----------|---------|----------------|
| Infra légère | traefik, cert-manager, external-secrets, cnpg-system, democratic-csi, crowdsec | 25m / 64Mi | 512Mi |
| Applicatif | zitadel, gitea, litellm, matrix, oxicloud (coder : limite 2Gi) | 50m / 128Mi | 1–2Gi |
| Lourd | database (pg-main), euro-office | 100m / 256Mi | 4Gi |

`argocd` et `kube-system` sont exclus volontairement (composants gérés hors
repo, une limite par défaut pourrait provoquer des OOMKill).

### Éviction des pods (QoS + PriorityClass)

Grâce aux requests par défaut, plus aucun pod n'est **BestEffort** (les
premiers sacrifiés, placés à l'aveugle). Sous pression mémoire, le kubelet
évince dans l'ordre :

1. les pods consommant **plus que leurs requests** (dépassement le plus
   important d'abord) ;
2. à dépassement comparable, la **priorité la plus basse** d'abord.

Classes disponibles, de la plus prioritaire à la moins prioritaire :

| Classe | Valeur | Workloads |
|--------|--------|-----------|
| `system-node-critical` / `system-cluster-critical` | 2e9 | CSI democratic-csi (défaut du chart), CoreDNS |
| `longhorn-critical` | 1e9 | Longhorn (créée par Longhorn, hors repo) |
| `homelab-ultra-critical` | 1e8 | Traefik, CrowdSec AppSec, pg-main + opérateur CNPG, NetBird (management, signal, relay, proxy, router) |
| `homelab-critical` | 1e6 | cert-manager, external-secrets, dashboard NetBird |
| `homelab-standard` | 1000 | Défaut global (appliqué automatiquement) |
| `homelab-low` | -1000 | CI (act-runner), jobs batch — évincé en premier, ne préempte jamais |

Le stockage reste **au-dessus** de ses consommateurs : une base ou un
ingress sans son volume ne sert à rien.

`homelab-ultra-critical` est définie dans `init/00-priorityclass-ultra.yaml`
(wave -1 de clusterinit) et non ici : cette app est en wave 12, alors que
Traefik (wave 0) et CrowdSec (wave 1) la référencent. Un pod qui référence
une PriorityClass inexistante est refusé à l'admission.

Zitadel n'est pas couvert : son chart (10.x) n'expose pas
`priorityClassName`.

## Limites connues

- Un LimitRange ne s'applique qu'aux **pods créés après** son déploiement :
  les workloads existants héritent des défauts à leur prochain rollout.
- Il ne modifie jamais un conteneur qui définit déjà ses `resources`.
- Nouveau namespace applicatif → ajouter son LimitRange ici (copier un
  profil existant).
