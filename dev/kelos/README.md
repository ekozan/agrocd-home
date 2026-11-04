# Kelos

[Kelos](https://github.com/kelos-dev/kelos) orchestre des agents de code IA
(Claude Code, Codex, Gemini, OpenCode, Cursor) dans des pods éphémères, décrits
par des CRDs : `Workspace` (dépôt git), `AgentConfig`, `Task`, `TaskSpawner`
(tâches créées depuis des issues, un cron, des webhooks), `Session` (chat
interactif)…

| Élément | Valeur |
|---------|--------|
| Application ArgoCD | `kelos` (`dev/kelos.yaml`, wave 3, multi-source) |
| Chart | `oci://ghcr.io/kelos-dev/charts/kelos` 0.63.0 (CRDs incluses) |
| Namespace | `kelos-system` |
| Console | Service `kelos-console-server` (ClusterIP, port 80 → 8080) |
| Accès | `https://kelos.proxy.ffd.link` — reverse proxy NetBird uniquement |

| Fichier | Rôle |
|---------|------|
| `externalsecret.yaml` | Secret `kelos-console-auth` (token de la Console) depuis OpenBao |
| `networkpolicy.yaml` | La Console n'accepte que le proxy et le routeur NetBird |

## Mise en place (une fois, **avant** de merger)

### 1. Token de la Console dans OpenBao

```bash
bao kv put -mount=kv kubernetes/kelos/console token="$(openssl rand -hex 32)"
```

Le token est le seul identifiant de la Console (mode `staticToken`, un
utilisateur partagé) : il donne accès à toutes les ressources Kelos et à un
shell dans les pods des Sessions (workspaces et credentials montés).

### 2. AppProject

`oci://ghcr.io/kelos-dev/charts` est ajouté à `sourceRepos`. L'AppProject n'est
pas géré par ArgoCD : le réappliquer à la main.

```bash
kubectl apply -f appproject.yaml
```

### 3. Service du reverse proxy NetBird

Après la première sync, récupérer la ClusterIP de la Console :

```bash
kubectl -n kelos-system get svc kelos-console-server -o jsonpath='{.spec.clusterIP}{"\n"}'
```

Dans le dashboard NetBird :

1. **Networks** → réseau routé par `netbird-k8s-router` → ajouter la ressource
   hôte `<ClusterIP>/32` (même principe qu'ArgoCD, CrowdSec et Kasm).
2. **Reverse Proxy → Services → Add Service** : `kelos.proxy.ffd.link`, cible
   cette ressource, `http` port `80`, authentification **SSO** (Zitadel).
   Alternative : **NetBird-Only** (cible *Proxy Cluster*, hôte
   `kelos-console-server.kelos-system.svc.cluster.local:80`) pour n'y accéder
   que depuis un pair NetBird.

Ouvrir `https://kelos.proxy.ffd.link` et saisir le token. Le WebSocket de la
Console (chat des Sessions) passe par le proxy.

## Vérifier

```bash
kubectl -n kelos-system get externalsecret kelos-console-auth   # Ready
kubectl -n kelos-system get pods
kubectl get crds | grep kelos.dev
```

## Utilisation

Les agents ont besoin de credentials (clé API Anthropic / OAuth, token GitHub
ou Gitea) dans des Secrets référencés par les `Task`/`AgentConfig` : à ajouter
dans OpenBao + ExternalSecret, dans le namespace des tâches. Doc :
<https://github.com/kelos-dev/kelos/tree/main/docs>.

## Notes

- **Mises à jour** : Renovate suit le chart (`targetRevision`). Le chart passe
  sa version au contrôleur, qui l'applique aux images d'agents non taguées.
  Les CRDs utilisent un webhook de conversion : en cas d'échec de sync après
  une montée de version, relancer la sync une fois le contrôleur prêt.
- **CRDs conservées** (`crds.keep=true`) : supprimer l'app ne supprime ni les
  CRDs ni les ressources Kelos. Supprimer d'abord les Tasks/TaskSpawners, le
  contrôleur devant tourner pour lever leurs finalizers.
- **Télémétrie** du contrôleur désactivée (`telemetry.enabled=false`).
- **Multi-utilisateur** : passer la Console en mode OIDC (Zitadel, sidecar
  OAuth2 Proxy, autorisations par RoleBinding) — `consoleServer.auth.mode: oidc`,
  cf. le README du chart.
