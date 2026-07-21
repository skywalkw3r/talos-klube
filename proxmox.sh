#!/usr/bin/env bash
set -euo pipefail

## Provision Talos Linux VMs on Proxmox VE over SSH (qm CLI).
## Analogous to vmware.sh, but machine configs are delivered via
## cloud-init (nocloud) snippets instead of VMware guestinfo.
##
## Required environment:
#   export PROXMOX_SSH='root@pve.example.lan'   # SSH target for the PVE node
#   export NODE_IPS='10.5.6.11,10.5.6.12,10.5.6.13'
#   export GATEWAY='10.5.6.1' PREFIX=24         # for the cloud-init static ipconfig
##
## Optional environment (defaults shown):
#   export CLUSTER_NAME=klube-pmx
#   export TALOS_VERSION=v1.13.6
#   export STORAGE=local-lvm          # VM disk storage
#   export SNIPPET_STORAGE=local      # storage with 'snippets' content enabled
#   export SNIPPET_PATH=/var/lib/vz/snippets
#   export BRIDGE=vmbr0
#   export VLAN_TAG=                  # optional 802.1q tag for a VLAN-aware bridge
#   export VMID_BASE=800              # VMIDs allocated as BASE+1..N
#   export CP_CPU=4 CP_MEM=8192 CP_DISK=40
#   export DATA_DISK=100              # blank disk (GB) per node for Rook-Ceph; 0 to skip

CLUSTER_NAME=${CLUSTER_NAME:=klube-pmx}
TALOS_VERSION=${TALOS_VERSION:=v1.13.6}
DNS_SERVERS=${DNS_SERVERS:=1.1.1.1,9.9.9.9}
STORAGE=${STORAGE:=local-lvm}
SNIPPET_STORAGE=${SNIPPET_STORAGE:=local}
SNIPPET_PATH=${SNIPPET_PATH:=/var/lib/vz/snippets}
BRIDGE=${BRIDGE:=vmbr0}
VLAN_TAG=${VLAN_TAG:=}
VMID_BASE=${VMID_BASE:=800}
CP_CPU=${CP_CPU:=4}
CP_MEM=${CP_MEM:=8192}
CP_DISK=${CP_DISK:=40}
DATA_DISK=${DATA_DISK:=100}

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_DIR="${REPO_DIR}/talos/clusterconfig"
SCHEMATIC_FILE="${REPO_DIR}/talos/.schematic-id"

pm() {
    ssh -o BatchMode=yes "${PROXMOX_SSH:?set PROXMOX_SSH, e.g. root@pve.lan}" "$@"
}

node_count() {
    echo "${NODE_IPS:?set NODE_IPS, e.g. 10.5.6.11,10.5.6.12,10.5.6.13}" | tr ',' '\n' | wc -l | tr -d ' '
}

## Resolve the Talos Image Factory schematic (qemu-guest-agent baked in).
## Schematic IDs are content-addressed, so this is deterministic.
schematic_id() {
    if [ -f "${SCHEMATIC_FILE}" ]; then
        cat "${SCHEMATIC_FILE}"
        return
    fi
    local id
    id=$(curl -fsS -X POST https://factory.talos.dev/schematics --data-binary @- <<'EOF' | sed -E 's/.*"id":"([a-f0-9]+)".*/\1/'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
EOF
    )
    [ -n "${id}" ] || { echo "failed to obtain schematic id from factory.talos.dev" >&2; exit 1; }
    echo "${id}" | tee "${SCHEMATIC_FILE}"
}

upload_image () {
    ## Download the nocloud disk image onto the PVE node (idempotent)
    local id url
    id=$(schematic_id)
    url="https://factory.talos.dev/image/${id}/${TALOS_VERSION}/nocloud-amd64.raw.xz"
    echo "image: ${url}"
    pm "test -f /var/lib/vz/talos-${TALOS_VERSION}.raw || (curl -fL '${url}' -o /var/lib/vz/talos-${TALOS_VERSION}.raw.xz && xz -d /var/lib/vz/talos-${TALOS_VERSION}.raw.xz)"
    pm "mkdir -p ${SNIPPET_PATH}"
}

create () {
    local count i name vmid cfg disk_ref
    count=$(node_count)

    for i in $(seq 1 "${count}"); do
        name="${CLUSTER_NAME}-m${i}"
        vmid=$((VMID_BASE + i))
        cfg="${CONFIG_DIR}/${name}.yaml"
        [ -f "${cfg}" ] || { echo "missing ${cfg} — run talos/gen-config.sh first" >&2; exit 1; }

        echo ""
        echo "launching control plane node: ${name} (vmid ${vmid})"
        echo ""

        # machine config -> cloud-init user-data snippet (Talos nocloud
        # platform consumes the raw machine config as user-data)
        scp -o BatchMode=yes "${cfg}" "${PROXMOX_SSH}:${SNIPPET_PATH}/talos-${name}.yaml"

        net0="virtio,bridge=${BRIDGE}"
        [ -n "${VLAN_TAG}" ] && net0="${net0},tag=${VLAN_TAG}"
        pm "qm create ${vmid} --name ${name} --machine q35 --ostype l26 \
            --cpu host --cores ${CP_CPU} --memory ${CP_MEM} --balloon 0 \
            --scsihw virtio-scsi-single --net0 ${net0} \
            --agent enabled=1 --onboot 1"

        # import the Talos disk image as the boot disk and grow it
        pm "qm importdisk ${vmid} /var/lib/vz/talos-${TALOS_VERSION}.raw ${STORAGE}" >/dev/null
        disk_ref=$(pm "qm config ${vmid}" | sed -n 's/^unused0: //p')
        pm "qm set ${vmid} --scsi0 '${disk_ref},discard=on,ssd=1,iothread=1' --boot order=scsi0"
        pm "qm disk resize ${vmid} scsi0 ${CP_DISK}G"

        # blank data disk for Rook-Ceph (skipped when DATA_DISK=0)
        if [ "${DATA_DISK}" -gt 0 ]; then
            pm "qm set ${vmid} --scsi1 ${STORAGE}:${DATA_DISK},discard=on,ssd=1"
        fi

        # cloud-init drive + our machine-config snippet. ipconfig0 makes the
        # Proxmox-generated network-config static (matching the machine
        # config) instead of DHCP; hostname comes from the VM name.
        # (if qm set fails: pvesm set ${SNIPPET_STORAGE} --content <existing>,snippets)
        node_ip=$(echo "${NODE_IPS}" | cut -d, -f${i})
        pm "qm set ${vmid} --ide2 ${STORAGE}:cloudinit \
            --cicustom user=${SNIPPET_STORAGE}:snippets/talos-${name}.yaml \
            --ipconfig0 ip=${node_ip}/${PREFIX:?set PREFIX},gw=${GATEWAY:?set GATEWAY} \
            --nameserver '${DNS_SERVERS//,/ }'"

        pm "qm start ${vmid}"
    done
}

destroy() {
    local count i name vmid
    count=$(node_count)
    for i in $(seq 1 "${count}"); do
        name="${CLUSTER_NAME}-m${i}"
        vmid=$((VMID_BASE + i))
        echo "destroying ${name} (vmid ${vmid})"
        pm "qm stop ${vmid} --skiplock 1 || true"
        pm "qm destroy ${vmid} --purge 1 || true"
        pm "rm -f ${SNIPPET_PATH}/talos-${name}.yaml"
    done
}

status() {
    pm "qm list" | grep -E "VMID|${CLUSTER_NAME}" || true
}

delete_image() {
    pm "rm -f /var/lib/vz/talos-${TALOS_VERSION}.raw"
}

"$@"
