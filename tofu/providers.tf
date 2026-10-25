# The API token is read from the environment, never from a file in this repo:
#   export PROXMOX_VE_API_TOKEN='talos-klube@pve!tofu=<secret>'
# tofu/README.md lists the privileges it needs.
provider "proxmox" {
  endpoint = var.pve_endpoint
  insecure = var.pve_insecure_tls

  # The PVE API can't upload snippets, so the cloud-init user-data (the
  # machine config) is copied over SSH, using the keys in your ssh-agent.
  ssh {
    agent    = true
    username = var.pve_ssh_username

    dynamic "node" {
      for_each = var.pve_ssh_address == null ? [] : [1]
      content {
        name    = var.pve_node
        address = var.pve_ssh_address
      }
    }
  }
}

# Talks to Image Factory and to the nodes' Talos API; no configuration needed.
provider "talos" {}
