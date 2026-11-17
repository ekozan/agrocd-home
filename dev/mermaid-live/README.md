# Mermaid Live Editor

Éditeur de diagrammes Mermaid (site statique servi par nginx, port 8080).
Les diagrammes restent dans le navigateur (URL / stockage local) : aucune donnée
côté serveur, pas de PVC.

## Accès : `mermaid.proxy.ffd.link` (reverse proxy NetBird)

Pas d'Ingress Traefik : le Service est en ClusterIP et `*.proxy.ffd.link` se
configure dans le dashboard NetBird (pas dans Git), comme Kelos.

Après la première sync :

```bash
kubectl -n mermaid-live get pods
kubectl -n mermaid-live get svc mermaid-live -o jsonpath='{.spec.clusterIP}{"\n"}'
```

Dans le dashboard NetBird :

1. **Networks** → réseau routé par `netbird-k8s-router` → ressource hôte
   `<ClusterIP>/32`.
2. **Reverse Proxy → Services → Add Service** : `mermaid.proxy.ffd.link`, cible
   cette ressource, `http` port `80`, authentification **SSO** (Zitadel).

⚠️ La ClusterIP ne change que si le Service est supprimé puis recréé ; dans ce
cas, mettre à jour la ressource du Network.

## Mise à jour

L'image est épinglée par digest (seuls `latest` et `nightly` existent sur
ghcr.io). Renovate propose les changements de digest.
