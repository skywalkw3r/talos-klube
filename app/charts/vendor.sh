#!/usr/bin/env bash
# Re-vendor the pinned KubeVirt + CDI upstream release manifests.
#
# Upstream ships raw YAML, not Helm charts, so the operator manifests live in
# each chart's templates/ verbatim and are refreshed here. Pinning is
# deliberate: a migration-assessment tool has to target *known* KubeVirt
# versions, and the same pinned release feeds the operator's envtest CRDs.
#
#   ./vendor.sh                       # use the versions below
#   KUBEVIRT_VERSION=v1.8.4 ./vendor.sh
set -euo pipefail

KUBEVIRT_VERSION=${KUBEVIRT_VERSION:=v1.8.4}
CDI_VERSION=${CDI_VERSION:=v1.65.0}

cd "$(dirname "$0")"

fetch() {
    local url=$1 dest=$2
    echo "==> ${dest} <- ${url}"
    curl -fsSL --max-time 120 -o "${dest}" "${url}"
    # Vendored files land in templates/; anything Helm would treat as an action
    # would break the render, so fail loudly rather than at sync time.
    if grep -q '{{' "${dest}"; then
        echo "ERROR: ${dest} contains '{{' and cannot be vendored into templates/ verbatim" >&2
        exit 1
    fi
}

fetch "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml" \
      kubevirt/templates/operator.yaml

fetch "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml" \
      cdi/templates/operator.yaml

# KubeVirt's own Namespace ships with enforce=privileged; CDI's does not. Talos
# enforces Pod Security Admission at 'baseline' by default, which is below what
# CDI's import/upload path needs. Inject the label rather than hand-editing a
# vendored file, so it survives the next re-vendor.
python3 - cdi/templates/operator.yaml <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()
if 'pod-security.kubernetes.io/enforce' in src:
    print("==> cdi namespace: PSA label already present upstream, no patch needed")
    sys.exit(0)
patched, n = re.subn(
    r'(kind: Namespace\nmetadata:\n  labels:\n)(    cdi\.kubevirt\.io: "")',
    r'\1    pod-security.kubernetes.io/enforce: "privileged"\n\2',
    src, count=1)
if n != 1:
    sys.exit("ERROR: could not locate the cdi Namespace labels block to patch")
open(path, 'w').write(patched)
print("==> cdi namespace: injected pod-security.kubernetes.io/enforce=privileged")
PY

echo
echo "Vendored KubeVirt ${KUBEVIRT_VERSION}, CDI ${CDI_VERSION}."
echo "Remember to bump versions.kubevirt / versions.cdi in root-app/values.yaml to match."
