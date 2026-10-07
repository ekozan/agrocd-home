# Chart kasm-helm (copie locale)

Copie du chart officiel [kasmtech/kasm-helm](https://github.com/kasmtech/kasm-helm)
(`charts/kasm-helm`, version **1.1190.6** / Kasm 1.19.0), sans `docs/` ni `tests/`.

## Patches homelab

Tous marqués `PATCH homelab` dans le code :

- `templates/_helpers.tpl` : les ressources des initContainers d'attente
  (`<composant>-is-ready` : 200m, `db-is-ready` : 500m) étaient codées en dur
  et gonflaient la réservation CPU de chaque pod. Elles deviennent
  surchargeables via la value `initContainerResources`.
- `values.yaml` : ajout de `initContainerResources: {}` (vide = comportement amont).

## Mise à jour

1. Copier `charts/kasm-helm/{Chart.yaml,values.yaml,values.schema.json,templates}`
   de la nouvelle branche `release/<version>` amont.
2. Réappliquer les patches ci-dessus (`grep -rn "PATCH homelab"` sur l'ancienne copie).
3. Vérifier : `helm template kasm dev/kasm/chart -n kasm -f <values>`.
