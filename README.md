# talos-klube

Homelab Kubernetes on [Talos Linux](https://www.talos.dev), managed by an
[Argo CD](https://argo-cd.readthedocs.io) app-of-apps. Exploring how far a
fully free stack can go as an OpenShift (OCP) replacement.

Two deployment targets share one GitOps tree:

| Cluster | Platform | Networking | Status |
|---|---|---|---|
| `klube-pmx` | Proxmox VE (`proxmox.sh`) | **Cilium for everything** — CNI, kube-proxy replacement, WireGuard encryption, LB-IPAM + L2 announcements, Gateway API, Hubble | current |
| `klube` | vSphere (`vmware.sh`) | flannel + MetalLB + ingress-nginx | legacy |

## The Proxmox stack

- **Talos v1.13.6** — immutable, API-only OS; no SSH, no shell. Machine
  configs delivered via cloud-init (nocloud); STATE/EPHEMERAL partitions
  LUKS2-encrypted (nodeID-keyed). 3 converged control-plane nodes with a
  shared VIP; workloads schedule on control planes.
- **Cilium 1.19** — kube-proxy-free (eBPF, via KubePrism `localhost:7445`),
  WireGuard pod+node encryption, `bpf.masquerade`, LB-IPAM +
  `CiliumL2AnnouncementPolicy` (replaces MetalLB), Gateway API v1.4
  (replaces the retired ingress-nginx), Hubble relay/UI.
- **Argo CD 3.x** (chart 10.x) — app-of-apps rooted at
  [app/charts/root-app](app/charts/root-app); per-cluster behavior via
  values overlays ([values-proxmox.yaml](app/charts/root-app/values-proxmox.yaml)).
- **kube-prometheus-stack**, **cert-manager 1.21**, **Rook-Ceph 1.20**
  (consumes each node's blank second disk).

## Deployment flow

The full path from `bootstrap.sh` to serving traffic — Secure Boot chain,
cluster bring-up, GitOps handoff, and the runtime request path — is
diagrammed in [docs/deployment-flow.mmd](docs/deployment-flow.mmd)
(Mermaid: renders in VS Code/JetBrains, [mermaid.live](https://mermaid.live),
or `mmdc`).

## Repo layout

```
proxmox.sh                  # provision Talos VMs on Proxmox (qm over SSH)
vmware.sh                   # legacy vSphere provisioning (govc)
bootstrap.sh                # end-to-end: configs -> VMs -> Cilium -> Argo CD
talos/
  patches/cluster.yaml      # committed machine-config patch (no secrets)
  gen-config.sh             # renders per-node configs into talos/clusterconfig/ (gitignored)
app/
  bootstrap/                # per-cluster root Application manifests
  charts/root-app/          # app-of-apps: one Application template per component
  charts/cilium/            # Cilium wrapper chart + LB-IPAM/L2 policy
  charts/argo-cd/           # Argo CD wrapper chart
  cert-manager/             # ClusterIssuers (staging/production)
```

**Never commit:** `talos/secrets.yaml`, anything in `talos/clusterconfig/`,
`kubeconfig`, `talosconfig`, or rendered Helm output (embedded generated
CAs). All are gitignored — keep it that way.

## Deploying the Proxmox cluster

Prerequisites: `talosctl`, `kubectl`, `helm`, `curl`, and SSH key access to
the PVE node. DHCP is not used — pick static IPs on your VLAN.

```sh
export PROXMOX_SSH='root@pve.lan'         # SSH target for the Proxmox node
export NODE_IPS='10.5.6.11,10.5.6.12,10.5.6.13'
export VIP='10.5.6.10'                    # control plane VIP (cluster endpoint)
export GATEWAY='10.5.6.1'
# optional: STORAGE=local-lvm BRIDGE=vmbr0 VMID_BASE=800 CP_CPU=4 CP_MEM=8192 CP_DISK=40 DATA_DISK=100
# (see talos/env.example for a fill-in template)

# 1. set LB_START/LB_STOP (LoadBalancer IP range) in talos/env — the pool
#    is applied at bootstrap and deliberately never committed
# 2. push your branch — Argo CD pulls from GitHub, not your working tree
# 3. run it:
./bootstrap.sh
```

`bootstrap.sh` generates fresh cluster secrets locally, provisions the VMs,
bootstraps etcd, installs Gateway API CRDs + Cilium + Argo CD, then applies
[root-app-proxmox.yaml](app/bootstrap/root-app-proxmox.yaml) — from there
Argo CD owns the cluster. Useful afterwards:

```sh
export TALOSCONFIG=$PWD/talos/clusterconfig/talosconfig KUBECONFIG=$PWD/kubeconfig
talosctl dashboard                                   # node health
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status   # WireGuard
kubectl -n kube-system port-forward svc/hubble-ui 12000:80           # flow map
```

Teardown: `./proxmox.sh destroy`

## Day-2 notes

- **Enable Cilium ServiceMonitors** once kube-prometheus-stack is synced:
  set `prometheus.serviceMonitor.enabled: true` (and the operator's) in
  [app/charts/cilium/values.yaml](app/charts/cilium/values.yaml).
- **Expose services** with a `Gateway` + `HTTPRoute` (class `cilium`); the
  Gateway's Service gets an IP from the LB pool via L2 announcements.
  cert-manager can solve ACME via its Gateway API HTTP-01 solver.
- **Upgrades:** Renovate proposes chart/Talos bumps; `talosctl upgrade`
  one minor at a time for the OS.
- App toggles and chart versions live in
  [values.yaml](app/charts/root-app/values.yaml) (defaults = legacy vSphere
  behavior) and the per-cluster overlay files.

## TODO (OCP-parity backlog)

- OIDC auth (Keycloak/Dex) for kube-apiserver + Argo CD SSO
- Velero backups, Loki logging, Kyverno policies, Harbor registry
- talhelper + SOPS/age for encrypted-in-repo machine configs
- CI validation + Renovate (in progress)

## Legacy: vSphere

`vmware.sh` (govc) deploys the original flannel/MetalLB/ingress-nginx
cluster; machine configs were hand-generated. See `vmware.sh` header for
GOVC_* environment variables. This cluster predates the secret-handling
rules above — its history is being rotated/purged; do not reuse its
credentials or configs.
