# CLI Cheatsheet — talosctl + kubectl

For the klube-pmx stack: Talos Linux, Cilium (Gateway API, Hubble),
Argo CD, Rook-Ceph. Talos has **no SSH and no shell** — everything you'd
normally do on a node happens through `talosctl` against the node's API.

## Session setup

```sh
cd talos-klube
source talos/env                                    # site config (gitignored)
export TALOSCONFIG=$PWD/talos/clusterconfig/talosconfig
export KUBECONFIG=$PWD/kubeconfig
```

`talosctl` targets come from the talosconfig (`config endpoint` / `config node`
are pre-set by `gen-config.sh`). Add `-n <node-ip>` to aim at a specific node.

---

## talosctl — the node has no SSH, this is your SSH

### Health & inspection

| Command | What it does |
|---|---|
| `talosctl health` | Full cluster health check (etcd, apid, kubelet, nodes) |
| `talosctl dashboard` | Live TUI — the same view as the VM console, per node |
| `talosctl -n $IP get members` | Cluster members as Talos sees them |
| `talosctl -n $IP services` | All system services + state (apid, etcd, kubelet…) |
| `talosctl -n $IP service kubelet status` | One service in detail |
| `talosctl -n $IP get securitystate` | **SecureBoot enforced?** |
| `talosctl -n $IP get volumestatus` | Disk/partition state incl. LUKS encryption |
| `talosctl -n $IP get hostname` / `get addresses` / `get routes` / `get links` | Network identity |
| `talosctl -n $IP get extensions` | Loaded system extensions (qemu-guest-agent…) |
| `talosctl time` | NTP sync status |

### Logs & debugging (journalctl/dmesg/tcpdump equivalents)

| Command | What it does |
|---|---|
| `talosctl -n $IP logs kubelet` (`-f` to follow) | Service logs — also `etcd`, `apid`, `machined` |
| `talosctl -n $IP dmesg -f` | Kernel log, follow mode |
| `talosctl -n $IP events` | Node event stream (config applies, reboots…) |
| `talosctl -n $IP containers -k` | List k8s containers (`crictl ps` equivalent) |
| `talosctl -n $IP logs -k <container-id>` | A container's logs straight from the runtime |
| `talosctl -n $IP netstat` | Open sockets on the node |
| `talosctl -n $IP pcap -i eth0` | Packet capture (pipe to Wireshark) |
| `talosctl -n $IP list /var/log` / `read <file>` | Browse/read node files (read-only) |
| `talosctl -n $IP support` | must-gather-style support bundle |
| `talosctl -n $IP usage /var` | Disk usage |

### Machine config (the MachineConfig-operator equivalent)

| Command | What it does |
|---|---|
| `talosctl -n $IP get machineconfig -o yaml` | Current live config |
| `talosctl -n $IP patch machineconfig -p '{"machine":{...}}'` | Live merge-patch (auto no-reboot when possible) |
| `talosctl -n $IP apply-config --file talos/clusterconfig/<node>.yaml` | Apply a full regenerated config |
| `talosctl -n $IP apply-config --dry-run --file …` | Preview what would change |

Gotchas learned the hard way (Talos ≥ 1.12):
- **Hostname** lives in the `HostnameConfig` document, *not*
  `machine.network.hostname` (that field is rejected when the doc exists).
- **Disk-encryption keys** must come from exactly one patch — key lists
  merge by *appending*, and duplicate LUKS slots fail validation.

### Lifecycle, etcd & upgrades

| Command | What it does |
|---|---|
| `talosctl -n $IP reboot` / `shutdown` | Graceful (drains etcd properly) |
| `talosctl -n $IP reset --reboot` | Wipe node back to maintenance mode (destructive) |
| `talosctl -n $IP etcd members` / `etcd status` | Quorum health |
| `talosctl -n $IP etcd snapshot backup.db` | **etcd backup — cron this off-cluster** |
| `talosctl -n $IP upgrade --image factory.talos.dev/installer-secureboot/<schematic>:<ver>` | OS upgrade, one node at a time, one minor at a time |
| `talosctl upgrade-k8s --to <version>` | Kubernetes upgrade, whole cluster |
| `talosctl -n $IP kubeconfig --force ./kubeconfig` | (Re)fetch kubeconfig |

---

## kubectl — daily driver

### The 90%

```sh
kubectl get nodes -o wide
kubectl get pods -A                                  # everything, all namespaces
kubectl get pods -A | grep -v Running                # what's unhappy
kubectl -n <ns> describe pod <pod>                   # events at the bottom
kubectl -n <ns> logs <pod> [-c <container>] [-f]     # -p = previous (crashloops)
kubectl -n <ns> exec -it <pod> -- sh
kubectl -n <ns> get <kind> <name> -o yaml            # the actual truth
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kubectl top nodes && kubectl top pods -A             # needs metrics (kube-prometheus-stack)
```

### Change & recover

```sh
kubectl apply --server-side -f file.yaml             # SSA — how this repo applies
kubectl -n <ns> rollout status  deploy/<name>
kubectl -n <ns> rollout restart deploy/<name>        # bounce it
kubectl -n <ns> rollout undo    deploy/<name>        # roll back
kubectl -n <ns> scale deploy/<name> --replicas=3
kubectl -n <ns> port-forward svc/<name> 8080:80
kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
#   … maintenance …  then: talosctl -n $IP reboot ; kubectl uncordon <node>
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl api-resources | grep -i <thing>              # find the kind's real name
kubectl explain <kind>.spec --recursive | less       # schema without the docs site
kubectl config set-context --current --namespace=<ns>   # stop typing -n
```

---

## This stack's specifics

### Cilium / Hubble / Gateway API

```sh
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status   # WireGuard
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list     # eBPF LB table
kubectl -n kube-system port-forward svc/hubble-ui 12000:80     # flow map UI
kubectl get ciliumloadbalancerippool                           # LB IP pools
kubectl get gatewayclass,gateway,httproute -A                  # ingress state
kubectl describe gateway <name> -n <ns>                        # listener/route conditions
```

### Argo CD

```sh
kubectl -n argo-cd get applications                            # sync/health at a glance
kubectl -n argo-cd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d                   # admin password
kubectl -n argo-cd port-forward svc/argo-cd-argocd-server 8080:80
kubectl -n argo-cd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite
```

### Rook-Ceph

```sh
kubectl -n rook-ceph get cephcluster                           # phase + HEALTH_OK/WARN/ERR
kubectl get storageclass                                       # ceph-block is default
kubectl get pvc -A                                             # who's using storage
# for `ceph status` etc., enable the toolbox (rook-ceph chart: toolbox.enabled=true), then:
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

---

## Coming from OpenShift (`oc`) — translation table

| OpenShift | Here |
|---|---|
| `oc login` | `export KUBECONFIG=…` (or OIDC later) |
| `oc project <ns>` | `kubectl config set-context --current --namespace=<ns>` |
| `oc get routes` | `kubectl get httproute -A` |
| `oc debug node/<n>` / `oc adm ssh` | `talosctl -n $IP dashboard` / `logs` / `read` — no SSH exists |
| MachineConfig / MCO | `talosctl patch machineconfig` / `apply-config` |
| `oc adm upgrade` | `talosctl upgrade` (OS) + `talosctl upgrade-k8s` |
| `oc adm must-gather` | `talosctl support` |
| `oc adm top` | `kubectl top` |
| `oc get clusterversion` | `talosctl version` + `kubectl version` |
| `oc adm cordon/drain` | `kubectl cordon/drain` (same) |
| SCC warnings | Pod Security Admission (namespace labels) |
| `oc rsh` | `kubectl exec -it` (pods only — nodes have no shell, by design) |
| etcd backup (cluster-backup.sh) | `talosctl etcd snapshot` |
| Web console | Argo CD UI + Hubble UI (+ Grafana from kube-prometheus-stack) |
