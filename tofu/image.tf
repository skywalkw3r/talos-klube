# Talos Image Factory schematic: the same one proxmox.sh requests
# (qemu-guest-agent baked in). Schematic IDs are content-addressed, so
# this is deterministic.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = ["siderolabs/qemu-guest-agent"]
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
  architecture  = "amd64"
  # PVE only decompresses downloads into 'iso' storage; the 'import'
  # content type takes qcow2 as-is (and it's far smaller than raw).
  disk_image_format = "qcow2"
}

locals {
  image_variant = var.secureboot ? "-secureboot" : ""
  image_url     = var.secureboot ? data.talos_image_factory_urls.this.urls.disk_image_secureboot : data.talos_image_factory_urls.this.urls.disk_image
}

# Downloaded by the PVE node itself, into 'import' storage, so the boot
# disks can be created from it through the API alone.
resource "proxmox_download_file" "talos" {
  node_name    = var.pve_node
  datastore_id = var.image_datastore
  content_type = "import"
  url          = local.image_url
  file_name    = "talos-${var.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 12)}-nocloud-amd64${local.image_variant}.qcow2"
  overwrite    = false
}
