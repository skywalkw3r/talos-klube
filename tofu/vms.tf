# Control-plane VMs, built the way proxmox.sh builds them with qm.

# Machine config -> cloud-init user-data snippet: Talos' nocloud platform
# reads the raw machine config as user-data on first boot.
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = local.nodes

  node_name    = var.pve_node
  datastore_id = var.snippet_datastore
  content_type = "snippets"

  source_raw {
    data      = data.talos_machine_configuration.node[each.key].machine_configuration
    file_name = "talos-${each.key}.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name        = each.key
  description = "talos-klube control plane (Talos ${var.talos_version})"
  tags        = ["talos-klube", var.cluster_name]
  node_name   = var.pve_node
  vm_id       = each.value.vm_id

  machine       = "q35"
  bios          = var.secureboot ? "ovmf" : "seabios"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]

  on_boot         = true
  protection      = var.protection
  stop_on_destroy = true

  # The qemu-guest-agent extension is in the schematic.
  agent {
    enabled = true
  }

  cpu {
    type  = "host" # nested virt for KubeVirt
    cores = var.cp_cpu
  }

  memory {
    dedicated = var.cp_memory
    floating  = 0 # no ballooning
  }

  operating_system {
    type = "l26"
  }

  # OVMF with EMPTY efivars (setup mode): the Talos Secure Boot UKI
  # auto-enrolls the Sidero signing keys on first boot, then reboots with
  # Secure Boot enforced. The vTPM seals the disk encryption keys against
  # measured boot.
  dynamic "efi_disk" {
    for_each = var.secureboot ? [1] : []
    content {
      datastore_id      = var.vm_datastore
      type              = "4m"
      pre_enrolled_keys = false
    }
  }

  dynamic "tpm_state" {
    for_each = var.secureboot ? [1] : []
    content {
      datastore_id = var.vm_datastore
      version      = "v2.0"
    }
  }

  # Boot disk: imported from the Talos image and grown to cp_disk.
  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    import_from  = proxmox_download_file.talos.id
    size         = var.cp_disk
    file_format  = "raw"
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Blank data disk for Rook-Ceph (skipped when data_disk = 0).
  dynamic "disk" {
    for_each = var.data_disk > 0 ? [1] : []
    content {
      datastore_id = var.vm_datastore
      interface    = "scsi1"
      size         = var.data_disk
      file_format  = "raw"
      discard      = "on"
      ssd          = true
    }
  }

  network_device {
    model   = "virtio"
    bridge  = var.bridge
    vlan_id = var.vlan_id
  }

  # Cloud-init drive. The static ipconfig makes the Proxmox-generated
  # network-config match the machine config instead of DHCP; the hostname
  # in meta-data comes from the VM name.
  initialization {
    datastore_id      = var.vm_datastore
    interface         = "ide2"
    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.prefix}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  # The protection flag blocks deleting the VM, but the provider stops the
  # VM before it tries. Fail first, so a protected cluster keeps running.
  provisioner "local-exec" {
    when    = destroy
    command = self.protection ? "echo '${self.name}: protection is on; run `tofu apply -var protection=false` first' >&2; exit 1" : "true"
  }
}
