#!/usr/bin/env bash
set -euo pipefail

## Bootstrap the Proxmox Talos cluster:
##   configs -> VMs -> etcd bootstrap -> Gateway API CRDs -> Cilium -> Argo CD -> root-app
##
##   ./bootstrap.sh [tofu]   default. Run after `tofu -chdir=tofu apply`, which
##                           does steps 1-4 (image, VMs, machine configs, etcd).
##                           Exports kubeconfig + talosconfig from the tofu
##                           outputs, then runs steps 5-8.
##   ./bootstrap.sh shell    fallback without OpenTofu: steps 1-4 with
##                           talos/gen-config.sh + proxmox.sh (qm over SSH),
##                           then the same steps 5-8. Needs `source talos/env`;
##                           see the proxmox.sh and gen-config.sh headers.
##
## Requires: kubectl, helm, curl; plus tofu (tofu mode) or talosctl and ssh
## access to the PVE node (shell mode). LB_START/LB_STOP come from the env
## in both modes (talos/env).

MODE=${1:-tofu}
REPO_DIR=$(cd "$(dirname "$0")" && pwd)
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:=v1.6.3}
TOFU=${TOFU:=tofu}

export TALOSCONFIG="${REPO_DIR}/talos/clusterconfig/talosconfig"
export KUBECONFIG="${REPO_DIR}/kubeconfig"

## Steps 1-4 done by OpenTofu: write its client configs where the rest of
## the repo expects them (both paths gitignored).
from_tofu() {
    echo "==> [1-4/8] provisioned by OpenTofu; exporting kubeconfig and talosconfig"
    local out
    out=$(mktemp -d)
    # written 0600 to a temp dir first, so a failed export never clobbers
    # a working kubeconfig
    if ! ( umask 077
           "${TOFU}" -chdir="${REPO_DIR}/tofu" output -raw kubeconfig > "${out}/kubeconfig" &&
           "${TOFU}" -chdir="${REPO_DIR}/tofu" output -raw talosconfig > "${out}/talosconfig" ); then
        rm -rf "${out}"
        echo "no tofu outputs: run 'tofu -chdir=tofu apply' first (or ./bootstrap.sh shell)" >&2
        exit 1
    fi
    mkdir -p "$(dirname "${TALOSCONFIG}")"
    mv "${out}/kubeconfig" "${KUBECONFIG}"
    mv "${out}/talosconfig" "${TALOSCONFIG}"
    rm -rf "${out}"
}

## Fallback: steps 1-4 the imperative way.
from_shell() {
    local first_ip
    first_ip=$(echo "${NODE_IPS:?set NODE_IPS}" | cut -d, -f1)

    echo "==> [1/8] generating machine configs"
    "${REPO_DIR}/talos/gen-config.sh"

    echo "==> [2/8] uploading Talos image and creating VMs"
    "${REPO_DIR}/proxmox.sh" upload_image
    "${REPO_DIR}/proxmox.sh" create

    echo "==> [3/8] waiting for Talos API on ${first_ip}, then bootstrapping etcd"
    until talosctl -n "${first_ip}" version --short >/dev/null 2>&1; do
        echo "    waiting for talos api..."; sleep 10
    done
    until talosctl -n "${first_ip}" bootstrap 2>/dev/null; do
        echo "    waiting to bootstrap etcd..."; sleep 10
    done

    echo "==> [4/8] fetching kubeconfig"
    talosctl -n "${first_ip}" kubeconfig --force "${KUBECONFIG}"
}

case "${MODE}" in
    tofu) from_tofu ;;
    shell) from_shell ;;
    *) echo "usage: $0 [tofu|shell]" >&2; exit 2 ;;
esac

echo "==> waiting for the API server"
until kubectl get nodes >/dev/null 2>&1; do
    echo "    waiting for kube-apiserver (via VIP)..."; sleep 10
done
kubectl get nodes || true   # NotReady is expected — no CNI yet

echo "==> [5/8] installing Gateway API ${GATEWAY_API_VERSION} CRDs (before Cilium starts)"
kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> [6/8] installing Cilium (Argo CD adopts this release later)"
helm dependency update "${REPO_DIR}/app/charts/cilium" >/dev/null
# Offline `helm template` has no cluster capabilities, and the Cilium
# chart gates its GatewayClass on them — declare Gateway API explicitly.
HELM_CAPS="--api-versions gateway.networking.k8s.io/v1 --api-versions gateway.networking.k8s.io/v1/GatewayClass"
# ServiceMonitor CRDs arrive later with kube-prometheus-stack, so leave the
# monitors out of the bootstrap render; Argo CD adds them once CRDs exist.
HELM_CAPS="${HELM_CAPS} --set cilium.prometheus.serviceMonitor.enabled=false \
--set cilium.operator.prometheus.serviceMonitor.enabled=false \
--set cilium.hubble.metrics.serviceMonitor.enabled=false"
# First pass: CiliumLoadBalancerIPPool/L2AnnouncementPolicy fail until the
# Cilium CRDs register — expected; re-applied strictly after rollout.
# shellcheck disable=SC2086 # HELM_CAPS is a flag list, word-split on purpose
helm template cilium "${REPO_DIR}/app/charts/cilium" -n kube-system ${HELM_CAPS} \
    | kubectl apply --server-side -f - || echo "    (partial apply expected on first pass)"
kubectl -n kube-system rollout status ds/cilium --timeout=10m
# the operator registers Cilium CRDs after the agents come up — wait for
# the ones the strict re-apply and LB pool need
for crd in ciliuml2announcementpolicies.cilium.io ciliumloadbalancerippools.cilium.io; do
    until kubectl get crd "${crd}" >/dev/null 2>&1; do
        echo "    waiting for CRD ${crd}..."; sleep 5
    done
    kubectl wait --for=condition=established "crd/${crd}" --timeout=120s
done
# shellcheck disable=SC2086 # HELM_CAPS is a flag list, word-split on purpose
helm template cilium "${REPO_DIR}/app/charts/cilium" -n kube-system ${HELM_CAPS} \
    | kubectl apply --server-side -f -

# LB pool comes from env, not git — keeps site addressing out of the repo
if [ -n "${LB_START:-}" ] && [ -n "${LB_STOP:-}" ]; then
    kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  blocks:
    - start: ${LB_START}
      stop: ${LB_STOP}
EOF
else
    echo "    WARNING: LB_START/LB_STOP unset — no LoadBalancer IP pool applied"
fi

echo "==> [7/8] waiting for nodes Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodes -o wide

echo "==> [8/8] installing Argo CD and handing the cluster to GitOps"
helm dependency update "${REPO_DIR}/app/charts/argo-cd" >/dev/null
kubectl create namespace argo-cd --dry-run=client -o yaml | kubectl apply -f -
helm template argo-cd "${REPO_DIR}/app/charts/argo-cd" -n argo-cd --include-crds \
    | kubectl apply --server-side -f -
kubectl -n argo-cd rollout status deploy/argo-cd-argocd-server --timeout=10m
kubectl apply -f "${REPO_DIR}/app/bootstrap/root-app-proxmox.yaml"

echo ""
echo "cluster is up. next steps:"
echo "  argo cd admin password:  kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "  argo cd ui:              kubectl -n argo-cd port-forward svc/argo-cd-argocd-server 8080:80"
echo "  hubble ui:               kubectl -n kube-system port-forward svc/hubble-ui 12000:80"
echo "  wireguard status:        kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status"
echo "  NOTE: argo pulls from GitHub main — push your changes before expecting sync."
