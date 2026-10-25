#!/usr/bin/env bash
# Render everything Argo CD would sync, offline:
#   1. every wrapper chart under app/charts/ (root-app also with its overlay)
#   2. the Cilium bootstrap render exactly as bootstrap.sh does it, which
#      must carry no ServiceMonitor (their CRDs don't exist yet at that point)
#   3. every upstream-chart Application in root-app — disabled ones included —
#      with its inline values, against its own repoURL/chart/targetRevision
# Needs helm and yq (mikefarah v4) on PATH. Rendered manifests are kept in
# OUT_DIR (default: a temp dir) for inspection.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
CHARTS="${REPO_DIR}/app/charts"
OUT_DIR=${OUT_DIR:-$(mktemp -d)}
mkdir -p "${OUT_DIR}"
cd "${REPO_DIR}"

render() { # render OUTFILE helm-template-args...
    local out=$1; shift
    echo "==> helm template $*"
    helm template "$@" > "${OUT_DIR}/${out}"
}

count_kind() { # count_kind FILE KIND
    KIND=$2 yq ea '[select(.kind == strenv(KIND))] | length' "$1"
}

## 1. wrapper charts
for chart in "${CHARTS}"/*/Chart.yaml; do
    dir=$(dirname "${chart}")
    name=$(basename "${dir}")
    # `dependency build` (not update) so a Chart.lock out of step with
    # Chart.yaml fails here; it needs each dependency's repo added first.
    i=0
    for url in $(yq '.dependencies[].repository' "${chart}"); do
        i=$((i + 1))
        helm repo add --force-update "${name}-dep${i}" "${url}" >/dev/null
    done
    if [ "${i}" -gt 0 ]; then
        helm dependency build "${dir}" >/dev/null
    fi
    render "${name}.yaml" "${name}" "${dir}"
done
render root-app-proxmox.yaml root-app "${CHARTS}/root-app" -f "${CHARTS}/root-app/values-proxmox.yaml"

## 2. Cilium as bootstrap.sh renders it. The flags are read from bootstrap.sh
## itself (its HELM_CAPS assignments) so this check can't drift from it.
HELM_CAPS=""
eval "$(sed -nE '/^HELM_CAPS=/,/[^\\]$/{/^[[:space:]]*#/d;p;}' bootstrap.sh)"
case "${HELM_CAPS}" in
    *serviceMonitor.enabled=false*) ;;
    *) echo "could not read the Cilium bootstrap flags (HELM_CAPS) from bootstrap.sh" >&2; exit 1 ;;
esac
# shellcheck disable=SC2086 # HELM_CAPS is a flag list, split on purpose (as in bootstrap.sh)
render cilium-bootstrap.yaml cilium "${CHARTS}/cilium" -n kube-system ${HELM_CAPS}
monitors=$(count_kind "${OUT_DIR}/cilium-bootstrap.yaml" ServiceMonitor)
echo "    cilium bootstrap render: ${monitors} ServiceMonitor(s) (default render: $(count_kind "${OUT_DIR}/cilium.yaml" ServiceMonitor))"
if [ "${monitors}" != 0 ]; then
    echo "ERROR: bootstrap.sh's Cilium render contains ServiceMonitors, which fail before kube-prometheus-stack installs their CRDs" >&2
    exit 1
fi

## 3. upstream charts referenced by root-app, every app switched on so
## disabled ones (bitwarden) keep rendering too
all="${OUT_DIR}/root-app-all-apps.yaml"
apps=$(yq '.apps | keys | .[]' "${CHARTS}/root-app/values.yaml")
set_all=()
for a in ${apps}; do set_all+=(--set "apps.${a}=true"); done
render "$(basename "${all}")" root-app "${CHARTS}/root-app" -f "${CHARTS}/root-app/values-proxmox.yaml" "${set_all[@]}"

# Anything other than a single source with inline values would be silently
# under-tested here, so refuse it until this script learns it.
unsupported=$(yq ea -N 'select(.kind == "Application" and (.spec.sources != null or (.spec.source.chart != null and (
        .spec.source.helm.valueFiles != null or .spec.source.helm.parameters != null or .spec.source.helm.fileParameters != null
    )))) | .metadata.name' "${all}")
if [ -n "${unsupported}" ]; then
    echo "ERROR: Applications this script can't render faithfully (multi-source or helm valueFiles/parameters): ${unsupported}" >&2
    exit 1
fi

upstream=$(yq ea -N 'select(.kind == "Application" and .spec.source.chart != null) | .metadata.name' "${all}")
[ -n "${upstream}" ] || { echo "ERROR: found no upstream-chart Applications in root-app" >&2; exit 1; }
for app in ${upstream}; do
    get() { APP=${app} yq ea "select(.kind == \"Application\" and .metadata.name == strenv(APP)) | $1" "${all}"; }
    repo=$(get .spec.source.repoURL)
    chart=$(get .spec.source.chart)
    version=$(get .spec.source.targetRevision)
    namespace=$(get '.spec.destination.namespace // "default"')
    release=$(get '.spec.source.helm.releaseName // .metadata.name')
    # Argo CD layers valuesObject over values; mirror that order.
    get '.spec.source.helm.values // ""' > "${OUT_DIR}/${app}.values.yaml"
    get '.spec.source.helm.valuesObject // {}' > "${OUT_DIR}/${app}.values-object.yaml"
    case "${repo}" in
        http://* | https://*) src=("${chart}" --repo "${repo}") ;;
        oci://*) src=("${repo%/}/${chart}") ;;
        *) src=("oci://${repo%/}/${chart}") ;; # Argo CD's scheme-less OCI form
    esac
    render "upstream-${app}.yaml" "${release}" "${src[@]}" --version "${version}" -n "${namespace}" \
        --include-crds -f "${OUT_DIR}/${app}.values.yaml" -f "${OUT_DIR}/${app}.values-object.yaml"
done

echo ""
echo "all renders OK; manifests in ${OUT_DIR}"
