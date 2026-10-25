# Machine configs, rendered the way talos/gen-config.sh does with
# `talosctl gen config`: the committed talos/patches/cluster.yaml plus
# generated patches for DNS, disk encryption, cert SANs, OIDC, install
# target and the per-node network/hostname.

locals {
  nodes = {
    for i, ip in var.node_ips : "${var.cluster_name}-m${i + 1}" => {
      ip    = ip
      vm_id = var.vm_id_base + i + 1
    }
  }
  first_node_ip = var.node_ips[0]

  cluster_endpoint = "https://${var.vip}:6443"
  installer_image  = "factory.talos.dev/${var.secureboot ? "installer-secureboot" : "installer"}/${talos_image_factory_schematic.this.id}:${var.talos_version}"

  # Upstream DNS servers (ResolverConfig, merged with the hostDNS settings
  # from patches/cluster.yaml).
  dns_patch = yamlencode({
    apiVersion  = "v1alpha1"
    kind        = "ResolverConfig"
    nameservers = [for d in var.dns_servers : { address = d }]
  })

  # Disk encryption lives in this ONE patch only (never also in
  # patches/cluster.yaml): key lists merge by appending and duplicate LUKS
  # slots fail validation. TPM-sealed with Secure Boot, nodeID otherwise.
  encryption_patch = join("---\n", [
    for volume in ["STATE", "EPHEMERAL"] : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "VolumeConfig"
      name       = volume
      encryption = {
        provider = "luks2"
        keys     = [{ (var.secureboot ? "tpm" : "nodeID") = {}, slot = 0 }]
      }
    })
  ])

  # Same as `talosctl gen config --install-disk --install-image`.
  install_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "UnattendedInstallConfig"
    installer  = { image = local.installer_image }
    provisioning = {
      diskSelector = { match = "disk.dev_path == \"${var.install_disk}\"" }
    }
  })

  # Optional DNS name for the API endpoint: Talos API and kube-apiserver SANs.
  san_patches = var.api_dns_name == null ? [] : [join("---\n", [
    yamlencode({ machine = { certSANs = [var.api_dns_name] } }),
    yamlencode({
      apiVersion    = "v1alpha1"
      kind          = "KubeAPIServerConfig"
      certExtraSANs = [var.api_dns_name]
    }),
  ])]

  # Optional kube-apiserver OIDC login through Keycloak (docs/sso.md). Talos
  # always runs kube-apiserver with --authentication-config and rejects the
  # --oidc-* flags, so OIDC is a jwt entry in KubeAuthenticationConfig.
  # Talos treats `configuration` as opaque and a patch replaces it whole,
  # so this carries the generated anonymous health-check rules as well.
  # Usernames and groups get an "oidc:" prefix: no Keycloak name can pass
  # for a built-in one (system:masters); app/charts/rbac binds the groups.
  oidc_patches = var.oidc == null ? [] : [yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeAuthenticationConfig"
    configuration = {
      anonymous = {
        enabled    = true
        conditions = [for p in ["/livez", "/readyz", "/healthz"] : { path = p }]
      }
      jwt = [{
        issuer = {
          url                  = var.oidc.issuer_url
          audiences            = [var.oidc.audience]
          certificateAuthority = file(var.oidc.ca_file)
        }
        claimMappings = {
          username = { claim = "preferred_username", prefix = "oidc:" }
          groups   = { claim = "groups", prefix = "oidc:" }
        }
      }]
    }
  })]

  common_patches = concat([
    file("${path.module}/../talos/patches/cluster.yaml"),
    local.dns_patch,
    local.encryption_patch,
    local.install_patch,
  ], local.san_patches, local.oidc_patches)

  # Static IP + VIP on the physical NIC, and the hostname. Hostname lives
  # in the HostnameConfig document, generated as `auto: stable`; auto and
  # hostname can't coexist, so the document is replaced.
  node_patches = {
    for name, node in local.nodes : name => join("---\n", [
      yamlencode({
        machine = {
          network = {
            interfaces = [{
              deviceSelector = { physical = true }
              dhcp           = false
              addresses      = ["${node.ip}/${var.prefix}"]
              routes         = [{ network = "0.0.0.0/0", gateway = var.gateway }]
              vip            = { ip = var.vip }
            }]
          }
        }
      }),
      yamlencode({ apiVersion = "v1alpha1", kind = "HostnameConfig", "$patch" = "delete" }),
      yamlencode({ apiVersion = "v1alpha1", kind = "HostnameConfig", hostname = name }),
    ])
  }
}

# Cluster secrets live only in the (gitignored, local) state.
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = local.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  docs               = false
  examples           = false
  config_patches     = concat(local.common_patches, [local.node_patches[each.key]])
}

# talosctl talks to the node IPs directly, never the VIP: the VIP depends
# on etcd, which is down exactly when you need talosctl.
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = var.node_ips
  nodes                = [local.first_node_ip]
}

# The nodes boot with their config from cloud-init (vms.tf). Applying the
# same config here waits for the Talos API to come up, and carries any
# later config change to the running nodes.
resource "talos_machine_configuration_apply" "node" {
  for_each = local.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip

  timeouts = {
    create = "20m"
    update = "20m"
  }

  depends_on = [proxmox_virtual_environment_vm.node]
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_node_ip
  endpoint             = local.first_node_ip

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_node_ip
  endpoint             = local.first_node_ip

  depends_on = [talos_machine_bootstrap.this]
}
