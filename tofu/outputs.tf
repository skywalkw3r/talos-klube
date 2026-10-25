output "nodes" {
  description = "Control-plane nodes: VM ID and IP."
  value = {
    for name, node in local.nodes : name => {
      vm_id = proxmox_virtual_environment_vm.node[name].vm_id
      ip    = node.ip
    }
  }
}

output "schematic_id" {
  description = "Image Factory schematic ID (qemu-guest-agent)."
  value       = talos_image_factory_schematic.this.id
}

output "installer_image" {
  description = "Installer image in the machine configs; `talosctl upgrade --image` takes the same form."
  value       = local.installer_image
}

# bootstrap.sh writes these to ./kubeconfig and talos/clusterconfig/talosconfig
# (both gitignored); by hand: tofu output -raw kubeconfig > ../kubeconfig
output "kubeconfig" {
  description = "Admin kubeconfig (API server on the VIP)."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosctl client config (endpoints = node IPs)."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "machine_configurations" {
  description = "Rendered machine config per node, e.g. for `talosctl validate --mode metal`."
  value       = { for name, cfg in data.talos_machine_configuration.node : name => cfg.machine_configuration }
  sensitive   = true
}
