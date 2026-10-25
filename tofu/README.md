# tofu/ — Proxmox + Talos with OpenTofu

Provisions the cluster declaratively with the
[`bpg/proxmox`](https://search.opentofu.org/provider/bpg/proxmox/latest) and
[`siderolabs/talos`](https://search.opentofu.org/provider/siderolabs/talos/latest)
providers. It covers steps 1–4 of `bootstrap.sh`: Image Factory image, VMs,
machine configs and the etcd bootstrap. After that, `../bootstrap.sh` runs
the platform half (Gateway API CRDs → Cilium → Argo CD → root-app).

| File | What it does |
|---|---|
| `image.tf` | Image Factory schematic (qemu-guest-agent), nocloud image downloaded by the PVE node into `import` storage |
| `talos.tf` | `talos_machine_secrets`, per-node `talos_machine_configuration`, apply, bootstrap, kubeconfig |
| `vms.tf` | cloud-init user-data snippets (= the machine config) and the control-plane VMs |
| `outputs.tf` | node IDs/IPs, schematic, installer image; `kubeconfig`, `talosconfig`, `machine_configurations` (sensitive) |

The machine configs match what `talos/gen-config.sh` renders with
`talosctl gen config`, document for document: the committed
[`talos/patches/cluster.yaml`](../talos/patches/cluster.yaml) is read with
`file()`, and the generated patches (DNS, LUKS2 encryption, install target,
cert SANs, per-node network and hostname) are built in `talos.tf`.

## Proxmox host prerequisites

These are one-off and documented here rather than automated:

- **Nested virtualization** on the host (`kvm_intel nested=1` / `kvm_amd nested=1`) for KubeVirt.
- **Content types**: `import` on `image_datastore` and `snippets` on `snippet_datastore`
  (both default to `local`):
  `pvesm set local --content <existing>,import,snippets`
- **SSH**: the provider uploads the snippets over SSH as `pve_ssh_username`
  (default `root`), using the keys in your ssh-agent (`ssh-add -l`). The PVE
  API can't upload snippets.
- **API token**, exported as `PROXMOX_VE_API_TOKEN='user@pve!token=<secret>'`.
  It needs a role with these privileges (the same set kvm-lab uses):

  ```sh
  pveum role add TalosKlube -privs "Datastore.Audit Datastore.AllocateSpace Datastore.AllocateTemplate \
    Sys.Audit Sys.Modify Sys.AccessNetwork VM.Allocate VM.Audit VM.PowerMgmt VM.Console \
    VM.Config.CPU VM.Config.Memory VM.Config.Disk VM.Config.Network VM.Config.Options \
    VM.Config.HWType VM.Config.Cloudinit VM.Config.CDROM VM.GuestAgent.Audit SDN.Use SDN.Audit"
  pveum role add TalosKlubeImages -privs Datastore.Allocate   # delete the image on destroy
  pveum user add talos-klube@pve
  pveum acl modify / -user talos-klube@pve -role TalosKlube
  # an ACL on a more specific path replaces what's inherited, so give the storage both roles
  pveum acl modify /storage/local -user talos-klube@pve -roles TalosKlube,TalosKlubeImages
  pveum user token add talos-klube@pve tofu --privsep 0
  ```

## Use

```sh
cd tofu
cp site.auto.tfvars.example site.auto.tfvars && $EDITOR site.auto.tfvars   # gitignored
export PROXMOX_VE_API_TOKEN='talos-klube@pve!tofu=<secret>'
tofu init
tofu apply            # image -> VMs -> machine configs -> etcd bootstrap
cd .. && ./bootstrap.sh   # kubeconfig/talosconfig from the outputs, then Cilium + Argo CD
```

`talos_machine_configuration_apply` waits up to 20 minutes for each node's
Talos API. The first Secure Boot boot enrolls keys and reboots, so the wait
is expected.

State is local (`tofu/terraform.tfstate`, gitignored) and holds the
cluster secrets and the admin kubeconfig. Treat it like
`talos/secrets.yaml`: back it up somewhere private and never commit it.

## Day 2

- **Config changes** (patches, DNS, SANs): edit, then `tofu apply`. The
  config is pushed to the running nodes (`apply_mode` auto: no reboot
  unless the change needs one). The cloud-init snippet is updated too, but
  Talos only reads it on first boot.
- **Talos upgrades**: set `talos_version`, then `tofu apply` (new image and
  installer reference in the configs), then upgrade the nodes one at a time
  with `talosctl upgrade --image "$(tofu output -raw installer_image)"`.
  Existing boot disks are not re-imported.
- **Debug a rendered config**:
  `tofu output -json machine_configurations | jq -r '.["klube-pmx-m1"]' | talosctl validate --mode metal --config /dev/stdin`

## Teardown

The PVE protection flag (on by default) blocks deleting the VMs, and
`tofu destroy` stops before touching a protected VM. Turn protection off
first:

```sh
tofu apply -var protection=false
tofu destroy
```
