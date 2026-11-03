# Opérateur Kubernetes NetBird

App ArgoCD `netbird-operator` (`infra/14-netbird-operator.yaml`, wave 14) :
chart `oci://ghcr.io/netbirdio/helm-charts/netbird-operator` + les manifests de
ce dossier, dans le namespace `netbird`.

```
poste NetBird ──WireGuard──> pod networkrouter-k8s (routing peer, ns netbird)
                                   │  ClusterIP du Service (/32)
                                   ▼
                       Service <svc>.<ns>  ──> pods
   DNS NetBird : <svc>.<ns>.k8s.internal → ClusterIP
```

L'opérateur crée dans NetBird le Network `homelab`, la setup key et le pair du
routing peer, puis une ressource (`/32` = ClusterIP) + un enregistrement DNS
par `NetworkResource`. Il n'écrit **pas** de policies (NetBird refuse tout par
défaut) : la policy se crée dans le dashboard.

## Mise en place (une fois)

1. **AppProject** : `ghcr.io/netbirdio/helm-charts` a été ajouté aux
   `sourceRepos` de `appproject.yaml`, qui n'est pas géré par ArgoCD :
   ```bash
   kubectl apply -f appproject.yaml
   ```
2. **Clé API** : dashboard → *Team → Service Users* → créer `k8s-operator`
   (rôle **Admin**), puis un *Access token* sans expiration courte.
   ```bash
   bao kv put -mount=kv kubernetes/netbird/operator api_key='nbp_…'
   ```
3. **Zone DNS** : dashboard → *DNS → Zones* → ajouter `k8s.internal`, avec
   comme groupes de distribution les groupes des postes qui doivent résoudre
   les noms (ex. `admins`). Sans cette zone, le NetworkRouter reste non Ready
   (erreur « zone with name k8s.internal cannot be found » dans les logs de l'opérateur).
4. **Policy** : dashboard → *Access Control* → policy `<groupe des postes>` →
   `k8s-services` (TCP, ports utiles). Le groupe `k8s-services` est créé par
   l'opérateur (`networkrouter.yaml`).

Vérifier :

```bash
kubectl -n netbird get networkrouters,groups.netbird.io,deploy/netbird-operator
kubectl -n netbird get pods -l app.kubernetes.io/name=networkrouter
```

## Publier un Service

Une `NetworkResource` **dans le namespace du Service** (`serviceRef` est
local), par exemple dans le dossier de l'app concernée :

```yaml
apiVersion: netbird.io/v1alpha1
kind: NetworkResource
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    # Si l'app est synchronisée avant que les CRD n'existent
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  networkRouterRef:
    name: k8s
    namespace: netbird
  serviceRef:
    name: argocd-server
  groups:
    - name: k8s-services
```

→ joignable depuis un poste NetBird sur `argocd-server.argocd.k8s.internal`.
Le Service doit avoir une ClusterIP (ni `ExternalName`, ni headless).

**NetworkPolicy** : si le namespace cible filtre l'ingress, autoriser les pods
du routing peer, en plus de `netbird-router` / `netbird-proxy` :

```yaml
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: netbird
      podSelector:
        matchLabels:
          app.kubernetes.io/name: networkrouter
```

## Notes

- **Coexistence avec `netbird-router`** (`infra/netbird/router.yaml`) : le
  routeur manuel annonce des plages entières (10.42/16, 10.43/16) et reste la
  cible des services du reverse proxy. Les `/32` de l'opérateur sont plus
  spécifiques et passent par `networkrouter-k8s`. Ne retirer la route large
  qu'une fois les Services utiles publiés ici.
- **Webhook de pods** : l'opérateur installe un MutatingWebhook sur la
  création de *tous* les pods (injection de sidecar via `SidecarProfile`).
  Il est en `failurePolicy: Ignore` (hors `kube-system`) pour ne pas bloquer
  le cluster si l'opérateur tombe. Aucun `SidecarProfile` n'est déclaré : le
  webhook ne modifie rien.
- **Pod Security** : le routing peer tourne en `privileged` (WireGuard noyau) ;
  le namespace `netbird` est en PSA `warn`/`audit` uniquement.
- **Mises à jour** : Renovate suit le chart (`targetRevision`) et l'`image:`
  du NetworkRouter, groupée avec le serveur (groupe `netbird`).
- ⚠️ **Prune** : supprimer `infra/14-netbird-operator.yaml` supprime le
  NetworkRouter et les NetworkResource (finalizers : l'opérateur nettoie le
  Network NetBird). Supprimer d'abord les CR, puis l'app, sinon les
  finalizers restent bloqués sans opérateur.
