#!/bin/bash

set -e

## The following commented environment variables should be set
## before running this script

# export GOVC_USERNAME='administrator@vsphere.local'
# export GOVC_PASSWORD='xxx'
# export GOVC_INSECURE=true
# export GOVC_URL='https://172.16.199.151'
# export GOVC_DATASTORE='xxx'
# export GOVC_NETWORK='PortGroup Name'

CLUSTER_NAME=${CLUSTER_NAME:=klube}
TALOS_VERSION=${TALOS_VERSION:=v1.9.0}
OVA_PATH=${OVA_PATH:="https://factory.talos.dev/image/903b2da78f99adef03cbbd4df6714563823f63218508800751560d3bc3557e40/${TALOS_VERSION}/vmware-amd64.ova"}

CONTROL_PLANE_COUNT=${CONTROL_PLANE_COUNT:=3}
CONTROL_PLANE_CPU=${CONTROL_PLANE_CPU:=8}
CONTROL_PLANE_MEM=${CONTROL_PLANE_MEM:=16384}
CONTROL_PLANE_DISK=${CONTROL_PLANE_DISK:=20G}
CONTROL_PLANE_ADDITIONAL_DISK=${CONTROL_PLANE_ADDITIONAL_DISK:=50G} # New variable for additional disk size
CONTROL_PLANE_MACHINE_CONFIG_PATH=${CONTROL_PLANE_MACHINE_CONFIG_PATH:="./controlplane.yaml"}

WORKER_COUNT=${WORKER_COUNT:=1}
WORKER_CPU=${WORKER_CPU:=4}
WORKER_MEM=${WORKER_MEM:=8192}
WORKER_DISK=${WORKER_DISK:=50G}
WORKER_MACHINE_CONFIG_PATH=${WORKER_MACHINE_CONFIG_PATH:="./worker.yaml"}

upload_ova () {
    ## Import desired Talos Linux OVA into a new content library
    govc library.create ${CLUSTER_NAME}
    govc library.import -n talos-${TALOS_VERSION} ${CLUSTER_NAME} ${OVA_PATH}
}

create () {
    ## Encode machine configs
    CONTROL_PLANE_B64_MACHINE_CONFIG=$(cat ${CONTROL_PLANE_MACHINE_CONFIG_PATH}| base64 | tr -d '\n')
    WORKER_B64_MACHINE_CONFIG=$(cat ${WORKER_MACHINE_CONFIG_PATH} | base64 | tr -d '\n')

    ## Create control plane nodes and edit their settings
    for i in $(seq 1 ${CONTROL_PLANE_COUNT}); do
        echo ""
        echo "launching control plane node: ${CLUSTER_NAME}-m${i}"
        echo ""

        govc library.deploy ${CLUSTER_NAME}/talos-${TALOS_VERSION} ${CLUSTER_NAME}-m${i}

        govc vm.change \
        -c ${CONTROL_PLANE_CPU}\
        -m ${CONTROL_PLANE_MEM} \
        -e "guestinfo.talos.config=${CONTROL_PLANE_B64_MACHINE_CONFIG}" \
        -e "disk.enableUUID=1" \
        -vm ${CLUSTER_NAME}-m${i}

        govc vm.disk.change -vm ${CLUSTER_NAME}-m${i} -disk.name disk-1000-0 -size ${CONTROL_PLANE_DISK}

        # Add additional thin provisioned disk
        govc vm.disk.create -vm ${CLUSTER_NAME}-m${i} -size ${CONTROL_PLANE_ADDITIONAL_DISK}

        if [ -z "${GOVC_NETWORK+x}" ]; then
             echo "GOVC_NETWORK is unset, assuming default VM Network";
        else
            echo "GOVC_NETWORK set to ${GOVC_NETWORK}";
            govc vm.network.change -vm ${CLUSTER_NAME}-m${i} -net "${GOVC_NETWORK}" ethernet-0
        fi

        govc vm.power -on ${CLUSTER_NAME}-m${i}
    done

    # ... (Worker node creation remains commented out as in the original script)
}

destroy() {
    for i in $(seq 1 ${CONTROL_PLANE_COUNT}); do
        echo ""
        echo "destroying control plane node: ${CLUSTER_NAME}-m${i}"
        echo ""

        govc vm.destroy ${CLUSTER_NAME}-m${i}
    done

    # ... (Worker node destruction remains commented out)
}

delete_ova() {
    govc library.rm ${CLUSTER_NAME}
}

"$@"