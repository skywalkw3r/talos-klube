#!/usr/bin/env bash
# Install pinned CLI tools into BIN_DIR, verifying each download against the
# checksum its upstream release publishes. Used by .github/workflows/validate.yml
# and runnable locally (linux/darwin, amd64/arm64):
#
#   BIN_DIR=/tmp/ci-bin HELM_VERSION=v4.3.1 scripts/ci/install-tools.sh helm
#
# Versions come from the environment (the workflow pins them); talosctl
# defaults to the TALOS_VERSION default in talos/gen-config.sh so the two
# can't drift.
set -euo pipefail

: "${BIN_DIR:?set BIN_DIR, the directory to install into}"
REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "${BIN_DIR}"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    arm64 | aarch64) ARCH=arm64 ;;
    *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# verify FILE EXPECTED_SHA256
verify() {
    local got
    got=$(sha256 "$1")
    [ -n "$2" ] && [ "${got}" = "$2" ] || {
        echo "checksum mismatch for $1: got ${got}, want ${2:-<none published>}" >&2
        exit 1
    }
}

# The default TALOS_VERSION in talos/gen-config.sh, i.e. what the repo deploys.
talos_version() {
    sed -nE 's/^TALOS_VERSION=\$\{TALOS_VERSION:=(v[0-9.]+)\}$/\1/p' "${REPO_DIR}/talos/gen-config.sh"
}

install_helm() {
    local v=${HELM_VERSION:?set HELM_VERSION} f
    f="helm-${v}-${OS}-${ARCH}.tar.gz"
    curl -fsSL -o "${TMP}/${f}" "https://get.helm.sh/${f}"
    verify "${TMP}/${f}" "$(curl -fsSL "https://get.helm.sh/${f}.sha256sum" | cut -d' ' -f1)"
    tar -xzf "${TMP}/${f}" -C "${TMP}"
    install -m 0755 "${TMP}/${OS}-${ARCH}/helm" "${BIN_DIR}/helm"
}

install_yq() {
    local v=${YQ_VERSION:?set YQ_VERSION} f url
    f="yq_${OS}_${ARCH}"
    url="https://github.com/mikefarah/yq/releases/download/${v}"
    curl -fsSL -o "${TMP}/${f}" "${url}/${f}"
    verify "${TMP}/${f}" "$(curl -fsSL "${url}/checksums-bsd" | sed -nE "s/^SHA256 \(${f}\) = ([0-9a-f]{64})$/\1/p")"
    install -m 0755 "${TMP}/${f}" "${BIN_DIR}/yq"
}

install_shellcheck() {
    # ShellCheck publishes no checksums; the workflow pins the linux.x86_64
    # tarball's digest in SHELLCHECK_SHA256. Without it (local runs on other
    # platforms) the download is only protected by TLS.
    local v=${SHELLCHECK_VERSION:?set SHELLCHECK_VERSION} arch f
    arch=$([ "${ARCH}" = amd64 ] && echo x86_64 || echo aarch64)
    f="shellcheck-${v}.${OS}.${arch}.tar.xz"
    curl -fsSL -o "${TMP}/${f}" "https://github.com/koalaman/shellcheck/releases/download/${v}/${f}"
    if [ -n "${SHELLCHECK_SHA256:-}" ]; then verify "${TMP}/${f}" "${SHELLCHECK_SHA256}"; fi
    tar -xJf "${TMP}/${f}" -C "${TMP}"
    install -m 0755 "${TMP}/shellcheck-${v}/shellcheck" "${BIN_DIR}/shellcheck"
}

install_talosctl() {
    local v f url
    v=${TALOS_VERSION:-$(talos_version)}
    [ -n "${v}" ] || { echo "could not read TALOS_VERSION from talos/gen-config.sh" >&2; exit 1; }
    f="talosctl-${OS}-${ARCH}"
    url="https://github.com/siderolabs/talos/releases/download/${v}"
    curl -fsSL -o "${TMP}/${f}" "${url}/${f}"
    verify "${TMP}/${f}" "$(curl -fsSL "${url}/sha256sum.txt" | awk -v f="${f}" '$2 == f { print $1 }')"
    install -m 0755 "${TMP}/${f}" "${BIN_DIR}/talosctl"
}

install_talhelper() {
    local v=${TALHELPER_VERSION:?set TALHELPER_VERSION} f url
    f="talhelper_${OS}_${ARCH}.tar.gz"
    url="https://github.com/budimanjojo/talhelper/releases/download/${v}"
    curl -fsSL -o "${TMP}/${f}" "${url}/${f}"
    verify "${TMP}/${f}" "$(curl -fsSL "${url}/checksums.txt" | awk -v f="${f}" '$2 == f { print $1 }')"
    tar -xzf "${TMP}/${f}" -C "${TMP}" talhelper
    install -m 0755 "${TMP}/talhelper" "${BIN_DIR}/talhelper"
}

[ $# -gt 0 ] || { echo "usage: $0 helm|yq|shellcheck|talosctl|talhelper..." >&2; exit 1; }
for tool in "$@"; do
    case "${tool}" in
        helm | yq | shellcheck | talosctl | talhelper) "install_${tool}" ;;
        *) echo "unknown tool: ${tool}" >&2; exit 1 ;;
    esac
    echo "installed ${tool} -> ${BIN_DIR}/${tool}"
done
# on GitHub Actions, put BIN_DIR on PATH for the job's later steps
if [ -n "${GITHUB_PATH:-}" ]; then echo "${BIN_DIR}" >> "${GITHUB_PATH}"; fi
