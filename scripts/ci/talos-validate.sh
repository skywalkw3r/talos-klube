#!/usr/bin/env bash
# Run talos/gen-config.sh with dummy addressing for every SECUREBOOT x
# API_DNS_NAME combination and `talosctl validate --mode metal` each rendered
# node config. Needs talosctl on PATH and network access to factory.talos.dev
# (gen-config.sh resolves the Image Factory schematic through proxmox.sh).
#
# gen-config.sh writes into talos/ (secrets.yaml, clusterconfig/,
# .schematic-id — all gitignored). This script refuses to run over existing
# ones so it can never clobber a real cluster's configs, and removes what it
# generated on exit.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TALOS_DIR="${REPO_DIR}/talos"
OUT="${TALOS_DIR}/clusterconfig"

export NODE_IPS=${NODE_IPS:-10.5.6.11,10.5.6.12,10.5.6.13}
export VIP=${VIP:-10.5.6.10}
export GATEWAY=${GATEWAY:-10.5.6.1}
export CLUSTER_NAME=${CLUSTER_NAME:-klube-pmx}
DUMMY_DNS_NAME=api.klube.example.com

for f in "${OUT}" "${TALOS_DIR}/secrets.yaml"; do
    if [ -e "${f}" ]; then
        echo "refusing to run: ${f} exists (a real cluster's config?) — use a clean clone" >&2
        exit 1
    fi
done
created_schematic=$([ -e "${TALOS_DIR}/.schematic-id" ] && echo 0 || echo 1)
cleanup() {
    rm -rf "${OUT}" "${TALOS_DIR}/secrets.yaml"
    if [ "${created_schematic}" = 1 ]; then rm -f "${TALOS_DIR}/.schematic-id"; fi
}
trap cleanup EXIT

expected=$(echo "${NODE_IPS}" | tr ',' '\n' | wc -l | tr -d ' ')
for secureboot in 1 0; do
    for dns_name in "" "${DUMMY_DNS_NAME}"; do
        echo "==> gen-config.sh SECUREBOOT=${secureboot} API_DNS_NAME=${dns_name:-<unset>}"
        rm -rf "${OUT}"
        SECUREBOOT=${secureboot} API_DNS_NAME=${dns_name} "${TALOS_DIR}/gen-config.sh" >/dev/null

        installer=$([ "${secureboot}" = 1 ] && echo installer-secureboot || echo installer)
        n=0
        for cfg in "${OUT}/${CLUSTER_NAME}"-m*.yaml; do
            [ -e "${cfg}" ] || break
            n=$((n + 1))
            echo "    talosctl validate --mode metal --config $(basename "${cfg}")"
            talosctl validate --mode metal --config "${cfg}"
            grep -qF "factory.talos.dev/${installer}/" "${cfg}" || {
                echo "ERROR: ${cfg} does not install from factory.talos.dev/${installer}/" >&2; exit 1; }
            if [ -n "${dns_name}" ]; then
                grep -qF -- "- ${dns_name}" "${cfg}" || {
                    echo "ERROR: ${cfg} is missing the API_DNS_NAME cert SAN" >&2; exit 1; }
            fi
        done
        if [ "${n}" != "${expected}" ]; then
            echo "ERROR: expected ${expected} node configs, got ${n}" >&2
            exit 1
        fi
    done
done
echo ""
echo "all Talos configs valid"
