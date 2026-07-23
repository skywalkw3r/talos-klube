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
    local url=$1 dest=$2 min_kinds=$3
    local tmp="${dest}.tmp"
    echo "==> ${dest} <- ${url}"
    # Download to a temp file so a failed or truncated transfer can never leave
    # a partial manifest in place for someone to commit.
    curl -fsSL --max-time 120 -o "${tmp}" "${url}"

    # A truncated YAML stream is still valid YAML, so length alone proves
    # nothing — assert the document actually ends cleanly and contains the
    # resources it must. An interrupted transfer fails at least one of these.
    if ! tail -c 1 "${tmp}" | od -c | grep -q '\\n'; then
        rm -f "${tmp}"; echo "ERROR: ${dest} does not end in a newline — truncated download" >&2; exit 1
    fi
    local kinds
    kinds=$(grep -c '^kind: ' "${tmp}" || true)
    if [ "${kinds}" -lt "${min_kinds}" ]; then
        rm -f "${tmp}"
        echo "ERROR: ${dest} has only ${kinds} top-level kinds, expected >= ${min_kinds} — truncated or wrong URL" >&2
        exit 1
    fi
    # Vendored files land in templates/; anything Helm would treat as an action
    # would break the render, so fail loudly rather than at sync time.
    if grep -q '{{' "${tmp}"; then
        rm -f "${tmp}"
        echo "ERROR: ${dest} contains '{{' and cannot be vendored into templates/ verbatim" >&2
        exit 1
    fi
    mv "${tmp}" "${dest}"
    echo "    ${kinds} resources, $(wc -c < "${dest}" | tr -d ' ') bytes"
}

fetch "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml" \
      kubevirt/templates/operator.yaml 10

fetch "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml" \
      cdi/templates/operator.yaml 8

# KubeVirt's own Namespace ships with enforce=privileged; CDI's does not, and
# Talos enforces Pod Security Admission at 'baseline' by default. Match what
# KubeVirt already does upstream rather than discover the gap later. Injected
# here rather than hand-edited into the vendored file, so it survives the next
# re-vendor.
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
