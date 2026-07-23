# KubeVirt lab on klube-pmx

Tier 1 + Tier 2 test environment for an **oVirt → KubeVirt migration-assessment
operator** — a read-only tool that maps oVirt VMs onto the KubeVirt resources
that would represent them and flags what will not translate cleanly.

This cluster is the *target* side. A source oVirt environment stays read-only,
and the only thing that crosses between them is a redacted JSON inventory dump.

Architecture diagram: [kubevirt-lab.mmd](kubevirt-lab.mmd).

## Why this cluster rather than a single-node k3s VM

The obvious cheap option is one nested-virt VM running k3s. This cluster wins on
the axes that actually matter for assessment work:

| | single k3s VM | klube-pmx |
|---|---|---|
| Nodes | 1 | **3** |
| Affinity-group mapping | **untestable** | testable |
| Live migration | not possible | testable |
| Storage | local-path | Rook-Ceph RBD + CephFS |
| Install path | manual | Argo app-of-apps, reproducible |
| Host dependency | someone else's maintenance window | this host |

Affinity groups matter specifically: an oVirt affinity group maps onto pod
affinity/anti-affinity rules, and you cannot validate that mapping on a
single node.

## Verified, not assumed

Everything below was read off the running cluster, because "nested virt should
work" is the assumption that costs an evening.

On the Proxmox host:

```
PVE 9.2.5 · AMD host · nested=1 already set in /sys/module/kvm_amd/parameters
3 guests · --cpu host · 8 vCPU · 24 GB · 40G OS + 100G Ceph each
```

Inside a Talos guest — `talosctl -n "$NODE" ls /dev -l`:

```
crw-rw-rw-  kvm            ← hardware acceleration is real
crw-rw-rw-  vhost-net      ← NIC offload, not userspace virtio
crw-rw-rw-  vhost-vsock    ← guest-agent channel
```

And `talosctl -n "$NODE" read /proc/cpuinfo | grep -o svm` returns `svm`, so
AMD-V survives the nesting. Cluster is Talos v1.13.6, Kubernetes v1.36.2, three
control-plane nodes, **untainted** — workloads schedule on control planes, so
nothing below needs tolerations.

### On architecture, precisely

Worth getting right, because there are two wrong versions of this in
circulation.

**CDI is not amd64-only.** Verified against the registry: every CDI component
at `v1.65.0` publishes a multi-arch index covering `amd64`, `arm64` and
`s390x`. Multi-arch landed at CDI v1.62.0. `virt-operator:v1.8.4` is the same.
The KubeVirt user guide's arm64 page still says CDI is unsupported; it is
stale. Anyone repeating "CDI does not exist on arm64" is citing that page
rather than the artifacts.

**And it is not about `/dev/kvm` on the Mac either.** Apple Silicon from M3
onward exposes nested virtualization, and Virtualization.framework gives an
arm64 Linux guest hardware acceleration. A Mac can host an accelerated arm64
KubeVirt cluster.

The actual reason this lab is amd64 is simpler: **an oVirt estate is x86_64.**
The VMs under assessment are x86_64, so an arm64 host would have to emulate
their architecture wholesale — correct, but far too slow to be worth doing.
Architecture has to match the source estate, not the laptop.

## What got installed

Two Argo Applications, `kubevirt` and `cdi`, both the same shape: a vendored
upstream release manifest in sync wave 0, and the CR that drives the operator in
wave 1.

```
app/charts/vendor.sh                    # refreshes + pins both manifests
app/charts/kubevirt/
  templates/operator.yaml               # vendored, KubeVirt v1.8.4
  templates/kubevirt-cr.yaml            # wave 1
  templates/workload-namespaces.yaml    # vm-lab
app/charts/cdi/
  templates/operator.yaml               # vendored, CDI v1.65.0
  templates/cdi-cr.yaml                 # wave 1
```

Upstream ships raw YAML rather than Helm charts, so the manifests are vendored
verbatim instead of referenced. That is deliberate: a tool targeting *known*
KubeVirt versions wants the exact manifests in-repo, and the same pinned release
can feed `test/crds/` for an envtest suite. Re-pin with:

```bash
KUBEVIRT_VERSION=v1.8.4 CDI_VERSION=v1.65.0 app/charts/vendor.sh
```

`vendor.sh` fails loudly if an upstream manifest ever contains `{{`, since these
files live in `templates/` and Helm would otherwise try to execute it.

## What CDI actually does

Kubernetes has no native way to express *"make this volume start out with an
operating system already on it."* PVCs are born empty; VMs need a disk that
already boots. CDI fills exactly that gap — and it is why this lab can **verify**
an assessment rather than only print one.

You write one object, a **DataVolume**: a PVC plus a *source*. Everything else
is CDI reacting to it.

```
DataVolume (40Gi, source: imageio)
  └─ datavolume-controller (ns: cdi)
       ├─ creates an empty PVC
       └─ launches an importer pod  ← in YOUR namespace, not cdi
            ├─ pulls from oVirt ImageIO over HTTPS + token
            ├─ stages via scratch PVC when it cannot stream
            ├─ qemu-img convert: qcow2 ⟶ raw
            └─ marks the PVC Succeeded
                 └─ VirtualMachine boots that disk
```

**CDI speaks oVirt natively.** A DataVolume with `source.imageio` runs an
importer that pulls straight from an engine's ImageIO service, given a URL, a
credentials secret, the CA cert and a disk ID — no manual export step and no
intermediate file server. That makes the verification loop much cheaper to reach
than it first looks.

Two consequences worth holding onto:

- **Scratch space is a real, separate volume.** qcow2 needs random access, so CDI
  stages to a temporary PVC before writing the target. That is what
  `scratchSpaceStorageClass: ceph-block` configures, and it is why an import can
  fail on capacity even when the *target* PVC comfortably fits.
- **The importer pod runs in the DataVolume's namespace**, not in `cdi`. That is
  where its resource requests land and where its RBAC and quota apply.

For orientation: Red Hat's Migration Toolkit for Virtualization (Forklift) also
builds on CDI for its oVirt path. That is a boundary rather than a collision —
Forklift *moves* VMs and assumes you already know which are safe to move; an
assessment tool sits upstream and answers that question.

## Things that will bite

**1. ServerSideApply, and be honest about why.** The `kubevirts.kubevirt.io`
CRD minifies to **~239 KB** against the 262,144-byte client-side-apply
annotation ceiling. That is *under* the limit — 91% of it — so client-side
apply does not fail today. It leaves ~23 KB of headroom on a CRD that only
grows, and once it does tip over, the failure is
`metadata.annotations: Too long`. Same reasoning that already forced SSA for
Rook's CSI CRDs in `rook-ceph.yaml`. Turning it on now costs nothing.

(Raw YAML for that CRD is ~462 KB, but the annotation stores minified JSON, so
the YAML byte count is the wrong number to compare against the ceiling — an
easy mistake to make in both directions.)

**2. `prune: false` on both.** Pruning the KubeVirt CR tears down virt-handler
and every running VM with it. That should be a deliberate act, never a sync
side-effect.

**3. PSA on the workload namespace.** Talos enforces Pod Security Admission at
`baseline` by default. KubeVirt's own namespace ships `enforce: privileged`
upstream; CDI's does not, so `vendor.sh` injects it. The `vm-lab` namespace is
also created privileged — that is insurance for `virt-launcher`, which is the
pod type with genuinely elevated needs. Modern CDI importer pods are far more
constrained than they used to be, so treat the label as covering VM workloads
rather than as the fix for a specific import failure.

**4. Feature gates default to empty.** Not because naming a gate is dangerous —
GA'd gates stay registered and are effectively no-ops, deprecated ones emit
warnings — but because none are needed yet, and an empty list keeps the CR
honest about what the lab actually depends on. Add only what an experiment needs.

**5. Cluster eviction strategy can hang node drains.** Setting
`evictionStrategy: LiveMigrate` cluster-wide sounds right and is a trap: any VMI
that *cannot* migrate — a containerDisk VM, or any disk that is not RWX — blocks
the drain indefinitely, which means `talosctl upgrade` and every rolling node
operation stalls. The chart defaults to `LiveMigrateIfPossible`, which migrates
what it can and shuts down the rest so a drain always completes. Set it to `""`
to omit the field and leave the decision to each VM.

**6. Registries.** KubeVirt and CDI pull exclusively from `quay.io`, so Docker
Hub's anonymous rate limit is a non-issue for this stack.

## Storage

Rook-Ceph 1.19.7 provides all three classes this lab needs:

| Class | Backing | Used for |
|---|---|---|
| `ceph-block` *(default)* | RBD | CDI scratch space, VM root disks |
| `ceph-filesystem` | CephFS (RWX) | persistent vTPM / EFI NVRAM state |
| `ceph-bucket` | RGW | — |

### Use Filesystem mode, not Block — verified the hard way

`volumeMode: Block` on `ceph-block` **does not work with CDI here.** The
importer fails with `blockdev: cannot open /dev/cdi-block-volume: Permission
denied`, and the cause is structural rather than a misconfiguration:

- the RBD device nodes are `rw-------`, **root:root mode 0600**
- CDI's importer runs as **UID 107, `runAsNonRoot: true`, `capabilities: drop
  [ALL]`** — it is far more constrained than older CDI
- its pod sets **no `fsGroup`**, and Kubernetes does not apply `fsGroup` to raw
  block volumes anyway
- the CDI CR exposes **no securityContext knob** to change any of it

Not a PSA problem (the namespace *is* privileged) and not SELinux
(`/sys/fs/selinux/enforce` is `0`). There is no fix available from the CR.

`volumeMode: Filesystem` works, and is what to use. Both of these imported
cleanly end to end — download, qcow2 → raw conversion, PVC populated:

| accessModes | volumeMode | class | result |
|---|---|---|---|
| `ReadWriteOnce` | `Filesystem` | `ceph-block` | ✅ Succeeded |
| `ReadWriteMany` | `Filesystem` | `ceph-filesystem` | ✅ Succeeded |
| `ReadWriteOnce` | `Block` | `ceph-block` | ❌ Permission denied |

### Live migration works — proven, and it does not need Block

A VM booted from the RWX/CephFS import above **live-migrated from
`klube-pmx-m2` to `klube-pmx-m1` while running**, PreCopy, completing in
seconds. That settles the question a single-node lab could never answer, and
it disproves the common assumption that nested virt forecloses migration.

Two requirements, and neither is `volumeMode: Block`:

1. **RWX storage** — `accessModes: [ReadWriteMany]` on `ceph-filesystem`.
2. **`masquerade` interface binding.** This one is easy to miss. A VM with the
   default bridge binding reports
   `LiveMigratable=False / InterfaceNotLiveMigratable` and simply cannot move.
   The VM must declare `interfaces: [{name: default, masquerade: {}}]` with a
   `pod: {}` network.

That second point is a real constraint for anything generating KubeVirt specs
from oVirt inventory: **a spec that omits masquerade binding produces a VM that
can never be migrated**, and nothing about the import or the boot will warn you.

Since the Talos nodes themselves run SecureBoot + vTPM, assessing oVirt VMs that
carry a vTPM is also on the table — enable the `VMPersistentState` feature gate
in `app/charts/kubevirt/values.yaml`, which is wired to point at
`ceph-filesystem` automatically.

## The tiers, and which need what

| Tier | Runs on | Needs /dev/kvm |
|---|---|---|
| **0** — envtest: reconcile logic, mapping, conditions | laptop, seconds, CI | no |
| **1** — real KubeVirt: admission webhooks, RBAC, packaging | klube-pmx | **no** |
| **2** — booting guests: CDI import, boot, live migration | klube-pmx | yes |

Worth internalising: **Tier 1 does not need nested virt at all.** Rejecting a
malformed `VirtualMachine` spec is pure API-server work. Tier 1 is also where
the most common "passed tests, failed in cluster" gap lives, because envtest
runs no controllers and no KubeVirt webhooks. Only Tier 2 needs `/dev/kvm`.

If nested virt is ever unavailable, `useEmulation: true` in the KubeVirt chart
values still exercises the full API surface — too slowly to enjoy, fast enough
to test.

## Day-2

```bash
source talos/env                                   # site addressing, gitignored
export KUBECONFIG=$PWD/kubeconfig
export TALOSCONFIG=$PWD/talos/clusterconfig/talosconfig
NODE=$(echo "$NODE_IPS" | cut -d, -f1)

kubectl -n kubevirt get kubevirt kubevirt          # PHASE should be Deployed
kubectl get cdi cdi                                # cluster-scoped, not namespaced
kubectl -n kubevirt get pods                       # virt-api/controller/handler
kubectl get vm,vmi -n vm-lab

talosctl -n "$NODE" ls /dev -l | grep kvm          # nested virt still real?
```

Powering the lab on — it is not left running:

```bash
source talos/env
ssh "$PROXMOX_SSH" "for i in 1 2 3; do qm start \$((VMID_BASE + i)); done"
```

Give it roughly 90 seconds to reach three `Ready` nodes, then several more
minutes for Argo to reconcile everything back to Healthy. Ceph reports
`HEALTH_WARN` while OSDs catch up after a cold start, which is expected and
clears itself.

## Capacity

The Proxmox host is the constraint, not the guests — it carries other VMs
alongside these three, so the headroom that matters is host-side. Cluster-side,
the existing stack plus KubeVirt and CDI leaves ample room for the handful of
small guests this work needs. **No need to bump VM sizing**; the risk runs the
other way, toward over-committing the host.
