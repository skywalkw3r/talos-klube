#!/usr/bin/env bash
set -euo pipefail

## End-to-end bootstrap of the Proxmox Talos cluster:
##   configs -> VMs -> etcd bootstrap -> Gateway API CRDs -> Cilium -> Argo CD -> root-app
## Requires: talosctl, kubectl, helm, curl, ssh access to the PVE node.
## See proxmox.sh and talos/gen-config.sh headers for required env vars.

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:=v1.4.1}

export TALOSCONFIG="${REPO_DIR}/talos/clusterconfig/talosconfig"
export KUBECONFIG="${REPO_DIR}/kubeconfig"

FIRST_IP=$(echo "${NODE_IPS:?set NODE_IPS}" | cut -d, -f1)

echo "==> [1/8] generating machine configs"
"${REPO_DIR}/talos/gen-config.sh"

echo "==> [2/8] uploading Talos image and creating VMs"
"${REPO_DIR}/proxmox.sh" upload_image
"${REPO_DIR}/proxmox.sh" create

echo "==> [3/8] waiting for Talos API on ${FIRST_IP}, then bootstrapping etcd"
until talosctl -n "${FIRST_IP}" version --short >/dev/null 2>&1; do
    echo "    waiting for talos api..."; sleep 10
done
until talosctl -n "${FIRST_IP}" bootstrap 2>/dev/null; do
    echo "    waiting to bootstrap etcd..."; sleep 10
done

echo "==> [4/8] fetching kubeconfig and waiting for the API server"
talosctl -n "${FIRST_IP}" kubeconfig --force "${KUBECONFIG}"
until kubectl get nodes >/dev/null 2>&1; do
    echo "    waiting for kube-apiserver (via VIP)..."; sleep 10
done
kubectl get nodes || true   # NotReady is expected — no CNI yet

echo "==> [5/8] installing Gateway API ${GATEWAY_API_VERSION} CRDs (before Cilium starts)"
kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> [6/8] installing Cilium (Argo CD adopts this release later)"
helm dependency update "${REPO_DIR}/app/charts/cilium" >/dev/null
# First pass: CiliumLoadBalancerIPPool/L2AnnouncementPolicy fail until the
# Cilium CRDs register — expected; re-applied strictly after rollout.
helm template cilium "${REPO_DIR}/app/charts/cilium" -n kube-system \
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
helm template cilium "${REPO_DIR}/app/charts/cilium" -n kube-system \
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
