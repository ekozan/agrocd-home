# Hardening — Ubuntu + K3s + Kubernetes

Documentation et outils de durcissement pour les nœuds Ubuntu exécutant K3s/Rancher.

## Architecture de la sécurité

```
┌─────────────────────────────────────────────────────────┐
│  NŒUD UBUNTU                                            │
│  ├── sysctl : kernel hardening (ASLR, BPF, ptrace…)    │
│  ├── SSH : clés uniquement, algos modernes              │
│  ├── UFW : ports K3s + Traefik uniquement               │
│  ├── CrowdSec (host) : agent + bouncer iptables SSH      │
│  ├── auditd : traçabilité des actions système           │
│  ├── AppArmor : confinement des processus               │
│  └── unattended-upgrades : patchs sécurité automatiques │
│                                                         │
│  K3s                                                    │
│  ├── protect-kernel-defaults                            │
│  ├── secrets-encryption (etcd chiffré AES-CBC)         │
│  ├── API audit log → /var/log/k3s-audit.log             │
│  ├── kubelet : port read-only désactivé, auth Webhook   │
│  └── controller-manager : bind 127.0.0.1               │
│                                                         │
│  Kubernetes (GitOps via ArgoCD)                         │
│  ├── NetworkPolicies default-deny par namespace         │
│  ├── CrowdSec : IDS/IPS + WAF AppSec                    │
│  ├── Vault/OpenBao : gestion des secrets                │
│  ├── External-Secrets : injection runtime               │
│  ├── Cert-Manager : TLS automatique                     │
│  ├── Zitadel : IdP OIDC (SSO)                           │
│  └── Pod Security Admission : warn + audit restricted   │
└─────────────────────────────────────────────────────────┘
```

---

## 1. Durcissement OS — Playbook Ansible

### Pré-requis

```bash
pip install ansible
# Ansible >= 2.12 recommandé
```

### Utilisation

```bash
cd hardening/ansible

# 1. Copier et adapter l'inventaire
cp inventory.ini.example inventory.ini
# Éditer inventory.ini avec vos IPs et utilisateur SSH

# 2. Dry-run (aucune modification)
ansible-playbook -i inventory.ini ubuntu-hardening.yml --check --diff

# 3. Exécution réelle
ansible-playbook -i inventory.ini ubuntu-hardening.yml

# 4. Tags disponibles pour cibler une section
ansible-playbook -i inventory.ini ubuntu-hardening.yml --tags ssh
ansible-playbook -i inventory.ini ubuntu-hardening.yml --tags firewall,crowdsec
ansible-playbook -i inventory.ini ubuntu-hardening.yml --tags sysctl
```

### Ce que fait le playbook

| Section | Tag | Description |
|---------|-----|-------------|
| Paquets | `packages` | Installe ufw/auditd/apparmor, supprime telnet/ftp/rsh |
| Kernel | `sysctl` | ASLR max, désactive ICMP redirects/RA, BPF JIT hardening, ptrace restrict |
| SSH | `ssh` | Clés uniquement, TLS 1.2+, algos modernes (ed25519/chacha20/SHA-2) |
| Pare-feu | `firewall` | UFW deny-all + ports K3s/Traefik/MetalLB uniquement |
| CrowdSec | `crowdsec` | Agent host + bouncer iptables + collections sshd/linux/base-http |
| auditd | `auditd` | Secrets/RBAC/K3s-config/ptrace/modules kernel tracés |
| Mises à jour | `updates` | Patchs sécurité automatiques quotidiens |
| AppArmor | `apparmor` | Profils en mode enforce |
| PAM | `pam` | Mots de passe ≥ 14 caractères, complexité requise |
| Limites | `limits` | Core dumps désactivés, nofile=65536 (K3s friendly) |
| NTP | `ntp` | Cloudflare + Google time servers |
| Services | `services` | Désactive avahi/cups/bluetooth/NFS/bind9… |
| Permissions | `permissions` | shadow/gshadow 0000, cron 0600/0700 |

### Architecture CrowdSec à deux niveaux

Le playbook déploie un **agent CrowdSec au niveau OS**, distinct du CrowdSec Kubernetes :

```
┌─ NŒUD UBUNTU ──────────────────────────────────────────────────────┐
│                                                                      │
│  CrowdSec agent (host)           CrowdSec agent (K8s DaemonSet)     │
│  ├── lit : auth.log, syslog      ├── lit : access logs Traefik      │
│  ├── détecte : bruteforce SSH,   ├── détecte : scan HTTP, CVE,      │
│  │             scan ports OS     │             bruteforce web        │
│  └── bouncer : iptables règles   └── bouncer : plugin Traefik       │
│     (bloque avant TCP handshake)    (bloque avant réponse HTTP)     │
│                                                                      │
│  Les deux instances peuvent partager la Console CrowdSec            │
│  (app.crowdsec.net) pour une vue centralisée.                       │
└──────────────────────────────────────────────────────────────────────┘
```

**Commandes utiles (agent host) :**

```bash
# Décisions actives sur le nœud
sudo cscli decisions list

# Alertes SSH détectées
sudo cscli alerts list --type bruteforce

# Métriques de l'agent
sudo cscli metrics

# Bloquer manuellement une IP
sudo cscli decisions add --ip 1.2.3.4 --duration 24h

# Enrôler dans la Console CrowdSec (facultatif, même clé que le K8s ou distincte)
sudo cscli console enroll <CLE_ENROLEMENT>
```

### Points d'attention K3s

- `net.ipv4.ip_forward=1` et `net.ipv6.conf.all.forwarding=1` sont **obligatoires** pour le réseau pod → ils sont activés (pas désactivés).
- `kernel.unprivileged_bpf_disabled=1` est compatible avec Flannel (CNI par défaut de K3s). Si vous utilisez Cilium, commenter cette règle.
- UFW avec `FORWARD DROP` par défaut peut bloquer le trafic pod-to-pod. K3s gère ses propres règles iptables ; UFW ne doit pas interférer avec la chaîne `FORWARD`. Vérifier avec `kubectl exec -it <pod> -- ping <autre-pod-ip>` après déploiement.

---

## 2. Durcissement K3s

### Pré-requis

Placer les fichiers **avant** l'installation de K3s (ou avant `systemctl restart k3s`) :

```bash
sudo mkdir -p /etc/rancher/k3s

# Copier la config durcie
sudo cp hardening/k3s/config.yaml /etc/rancher/k3s/config.yaml

# Copier la politique d'audit
sudo cp hardening/k3s/audit-policy.yaml /etc/rancher/k3s/audit-policy.yaml
```

### Installation K3s avec config durcie

```bash
# Nouvelle installation (le fichier config.yaml est lu automatiquement)
curl -sfL https://get.k3s.io | sh -

# Ou sur un cluster existant
sudo systemctl restart k3s
```

### Vérifications post-déploiement

```bash
# 1. Vérifier que le chiffrement des secrets est actif
sudo k3s secrets-encrypt status
# Attendu : enabled=true, hash=... (après k3s secrets-encrypt reencrypt)

# 2. Chiffrer les secrets existants (1ère activation)
sudo k3s secrets-encrypt rotate
sudo k3s secrets-encrypt reencrypt

# 3. Vérifier les logs d'audit
sudo tail -f /var/log/k3s-audit.log | jq .

# 4. Vérifier protect-kernel-defaults (kubelet doit démarrer sans erreur)
sudo journalctl -u k3s | grep -i "kernel\|protect"

# 5. Vérifier le benchmark CIS avec kube-bench
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench
```

### Conformité CIS K3s Benchmark

| Contrôle | Param | Statut |
|----------|-------|--------|
| 1.2.1 | `anonymous-auth=false` | ✅ config.yaml |
| 1.2.6 | `audit-log-path` activé | ✅ config.yaml |
| 1.2.21 | `profiling=false` | ✅ config.yaml |
| 1.2.35 | `service-account-lookup=true` | ✅ config.yaml |
| 1.3.2 | `RotateKubeletServerCertificate` | ✅ config.yaml |
| 1.3.6 | `use-service-account-credentials` | ✅ config.yaml |
| 4.2.1 | `anonymous-auth=false` (kubelet) | ✅ config.yaml |
| 4.2.2 | `authorization-mode=Webhook` | ✅ config.yaml |
| 4.2.3 | `client-ca-file` | ✅ K3s auto |
| 4.2.4 | `read-only-port=0` | ✅ config.yaml |
| 4.2.6 | `protect-kernel-defaults=true` | ✅ config.yaml |
| 4.2.10 | `tls-min-version=VersionTLS12` | ✅ config.yaml |
| Etcd | `secrets-encryption: true` | ✅ config.yaml |

---

## 3. Durcissement Kubernetes (GitOps)

### NetworkPolicies en place

Chaque namespace applicatif applique le principe **default-deny-ingress** : tout trafic entrant est refusé sauf ce qui est explicitement autorisé.

| Namespace | Fichier | Politique |
|-----------|---------|-----------|
| `crowdsec` | `infra/network-policies/crowdsec.yaml` | deny-all + same-ns + Traefik→LAPI:8080/7422 |
| `traefik` | *(géré par le chart)* | LoadBalancer public |
| `zitadel` | `infra/network-policies/zitadel.yaml` | deny-all + same-ns + Traefik→Zitadel |
| `gitea` | `infra/network-policies/gitea.yaml` | deny-all + same-ns + Traefik→Gitea |
| `coder` | `infra/network-policies/coder.yaml` | deny-all + same-ns + Traefik→Coder |
| `litellm` | `infra/network-policies/litellm.yaml` | deny-all + same-ns + Coder→LiteLLM:4000 |
| `matrix` | `infra/network-policies/matrix.yaml` | deny-all + same-ns + Traefik + LiveKit internet |
| `database` | `infra/network-policies/database.yaml` | deny-all + same-ns + CNPG-operator + Apps→5432 |
| `vault` | `infra/network-policies/vault.yaml` | deny-all + same-ns + Traefik→8200 + ExtSecrets→8200 |

### Pod Security Admission (PSA)

Les namespaces sont actuellement configurés en **warn + audit restricted** (inventaire sans blocage). Pour passer en enforce, ajouter le label `pod-security.kubernetes.io/enforce: restricted` (ou `baseline` pour les charts Helm qui ne sont pas encore PSS-compliant).

```yaml
# Exemple : passer un namespace en enforce baseline
metadata:
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

Niveaux recommandés par namespace :

| Namespace | enforce recommandé | Raison |
|-----------|-------------------|--------|
| `crowdsec` | `restricted` | Jobs contrôlés, déjà conformes |
| `external-secrets` | `restricted` | Opérateur moderne PSS-compliant |
| `cert-manager` | `restricted` | Opérateur moderne PSS-compliant |
| `database` | `baseline` | CNPG requiert des capabilities spécifiques |
| `traefik` | `baseline` | Chart Helm, vérifier la compatibilité |
| `zitadel` | `baseline` | Chart Helm |
| `gitea` | `baseline` | Chart Helm |
| `vault` | `baseline` | Vault requiert des capabilities spécifiques |
| `coder` | `privileged` | Workspaces peuvent nécessiter des accès privilégiés |

### Amélioration envisagée : Kyverno

Pour une politique de sécurité continue et auditable, ajouter [Kyverno](https://kyverno.io) comme moteur de policies :

- `disallow-privileged-containers` — interdire les conteneurs privilégiés
- `require-resource-limits` — exiger les limits CPU/mémoire
- `disallow-latest-tag` — interdire l'image tag `:latest`
- `require-non-root-groups` — exiger `runAsNonRoot: true`
- `require-drop-all` — exiger `capabilities.drop: [ALL]`

---

## 4. Surveillance et réponse aux incidents

### Vérifier l'état de CrowdSec

```bash
LAPI=$(kubectl -n crowdsec get pod -l type=lapi -o jsonpath='{.items[0].metadata.name}')

# Alertes actives
kubectl -n crowdsec exec "$LAPI" -- cscli alerts list

# Décisions de blocage en cours
kubectl -n crowdsec exec "$LAPI" -- cscli decisions list

# Métriques (trafic analysé, IP bloquées)
kubectl -n crowdsec exec "$LAPI" -- cscli metrics

# Bloquer manuellement une IP
kubectl -n crowdsec exec "$LAPI" -- cscli decisions add --ip <IP> --duration 24h

# Débloquer
kubectl -n crowdsec exec "$LAPI" -- cscli decisions delete --ip <IP>
```

### Consulter les logs d'audit K3s

```bash
# Dernières entrées
sudo tail -100 /var/log/k3s-audit.log | jq 'select(.verb != "get" and .verb != "list" and .verb != "watch")'

# Accès aux Secrets
sudo grep '"secrets"' /var/log/k3s-audit.log | jq '{time:.requestReceivedTimestamp,user:.user.username,verb:.verb,ns:.objectRef.namespace}'

# Exécutions kubectl exec
sudo grep 'pods/exec' /var/log/k3s-audit.log | jq '{time:.requestReceivedTimestamp,user:.user.username,pod:.objectRef.name}'
```

### Consulter auditd

```bash
# Sudo et élévations de privilèges
sudo ausearch -k privileged-exec | aureport -f -i

# Modifications de la config K3s
sudo ausearch -k k3s-config | aureport -f -i

# Modifications des fichiers d'identité
sudo ausearch -k identity | aureport -f -i
```
