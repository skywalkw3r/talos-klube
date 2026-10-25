# Defaults mirror talos/env.example, proxmox.sh and talos/gen-config.sh.
# Site values (addresses, endpoint) go in a gitignored *.auto.tfvars —
# see site.auto.tfvars.example.

# ---- Where your Proxmox is ----------------------------------------------------

variable "pve_endpoint" {
  description = "Proxmox API URL, e.g. https://pve.example.com:8006/"
  type        = string
}

variable "pve_insecure_tls" {
  description = "Skip TLS verification (only for a self-signed node)."
  type        = bool
  default     = false
}

variable "pve_node" {
  description = "Name of the Proxmox node to create the VMs on (as shown in the web UI tree)."
  type        = string
}

variable "pve_ssh_username" {
  description = "SSH user on the PVE node, for uploading the cloud-init snippets."
  type        = string
  default     = "root"
}

variable "pve_ssh_address" {
  description = "SSH address of the PVE node (null = the address the provider resolves for pve_node)."
  type        = string
  default     = null
}

variable "image_datastore" {
  description = "Storage for the downloaded Talos image. Must allow the 'import' content type."
  type        = string
  default     = "local"
}

variable "snippet_datastore" {
  description = "Storage for the cloud-init user-data snippets. Must allow the 'snippets' content type."
  type        = string
  default     = "local"
}

variable "vm_datastore" {
  description = "Storage for VM disks, EFI vars, TPM state and the cloud-init drive."
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Network bridge the nodes attach to."
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "802.1q tag on that bridge (null = untagged)."
  type        = number
  default     = null
}

variable "vm_id_base" {
  description = "Nodes get VM IDs vm_id_base+1 .. +N."
  type        = number
  default     = 800
}

# ---- Cluster ------------------------------------------------------------------

variable "cluster_name" {
  description = "Cluster name; nodes are named <cluster_name>-m1 .. -mN."
  type        = string
  default     = "klube-pmx"
}

variable "talos_version" {
  description = "Talos release for the image, the installer and the config contract."
  type        = string
  default     = "v1.14.4"
}

variable "kubernetes_version" {
  description = "Kubernetes version baked into new machine configs (the talosctl default for talos_version)."
  type        = string
  default     = "v1.37.1"
}

variable "node_ips" {
  description = "One static IPv4 per control-plane node, e.g. [\"10.5.6.11\", \"10.5.6.12\", \"10.5.6.13\"]."
  type        = list(string)

  validation {
    condition     = length(var.node_ips) > 0 && alltrue([for ip in var.node_ips : can(cidrhost("${ip}/32", 0))])
    error_message = "node_ips must be a non-empty list of IPv4 addresses (no prefix)."
  }
}

variable "vip" {
  description = "Shared control-plane VIP; the Kubernetes API endpoint is https://<vip>:6443."
  type        = string
}

variable "api_dns_name" {
  description = "Optional DNS name for the VIP, added to the Talos and kube-apiserver cert SANs."
  type        = string
  default     = null
}

variable "oidc" {
  description = <<-EOT
    kube-apiserver OIDC login through Keycloak (docs/sso.md); null = off.
    issuer_url: https://<keycloak hostname>/auth/realms/<realm>.
    ca_file: PEM of the CA that signs Keycloak's certificate (the exported
    internal-ca.crt), relative to tofu/ or absolute.
    audience: the Keycloak client kubectl logs in with.
  EOT
  type = object({
    issuer_url = string
    ca_file    = string
    audience   = optional(string, "kubernetes")
  })
  default = null

  validation {
    condition     = var.oidc == null || startswith(try(var.oidc.issuer_url, ""), "https://")
    error_message = "oidc.issuer_url must be an https:// URL."
  }
}

variable "gateway" {
  description = "Default gateway for the nodes."
  type        = string
}

variable "prefix" {
  description = "Prefix length of the node subnet."
  type        = number
  default     = 24
}

variable "dns_servers" {
  description = "Upstream DNS servers (cloud-init and Talos ResolverConfig)."
  type        = list(string)
  default     = ["1.1.1.1", "9.9.9.9"]
}

variable "install_disk" {
  description = "Disk Talos installs to (the imported boot disk on scsi0)."
  type        = string
  default     = "/dev/sda"
}

# ---- VM sizing and security ---------------------------------------------------

variable "cp_cpu" {
  description = "vCPUs per control-plane node."
  type        = number
  default     = 4
}

variable "cp_memory" {
  description = "Memory (MiB) per control-plane node; ballooning is off."
  type        = number
  default     = 8192
}

variable "cp_disk" {
  description = "OS disk (GB) per node: Talos EPHEMERAL holds images, logs and emptyDir."
  type        = number
  default     = 40
}

variable "data_disk" {
  description = "Blank disk (GB) per node for Rook-Ceph; 0 to skip."
  type        = number
  default     = 100
}

variable "secureboot" {
  description = "UEFI Secure Boot (Sidero keys auto-enrolled) + vTPM-sealed disk encryption. false = SeaBIOS + nodeID keys."
  type        = bool
  default     = true
}

variable "protection" {
  description = "PVE protection flag on the VMs. Set false and apply before `tofu destroy`."
  type        = bool
  default     = true
}
