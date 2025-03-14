#!/usr/bin/env bash
set -euo pipefail

# Check if multipass is installed
if ! command -v multipass &>/dev/null; then
    echo "Multipass is not installed. Exiting."
    exit 1
fi

# Check if yq is installed for parsing YAML
if ! command -v yq &>/dev/null; then
    echo "yq is not installed. Please install yq to parse config.yaml. Exiting."
    exit 1
fi

# Check if config.yaml exists in the current directory
CONFIG_FILE="config.yaml"
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Configuration file ${CONFIG_FILE} not found. Exiting."
    exit 1
fi

# Read configuration variables from config.yaml
gh_name=$(yq e '.gh_name' "${CONFIG_FILE}")
windows_switch_name=$(yq e '.windows_switch_name' "${CONFIG_FILE}")

# Determine the network argument based on OS.
# On Windows, use the configured switch name.
# On other OSes (Linux/macOS), fall back to the bridged manual network option.
if [[ "${OSTYPE}" == "msys"* || "${OSTYPE}" == "cygwin"* || "${OSTYPE}" == "win32"* ]]; then
    network_arg="${windows_switch_name}"
else
    network_arg="name=bridged,mode=manual"
fi

multipass_purge() {
    local INSTANCE_NAME=$1
    # Do not fail if the instance doesn't exist
    multipass delete "${INSTANCE_NAME}" --purge || true
}

create_cloud_init() {
    local INSTANCE_NAME=$1
    local STATIC_IP=$2
    local GATEWAY_IP=$3
    local DNS_SERVERS=$4

    cat >"${INSTANCE_NAME}-cloud-init.yaml" <<EOF
#cloud-config
hostname: ${INSTANCE_NAME}
package_update: true
package_upgrade: true
packages:
  - net-tools
  - ca-certificates
  - curl
ssh_import_id:
  - gh:${gh_name}
write_files:
  - path: /etc/netplan/10-netcfg.yaml
    owner: root:root
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          enp0s2:
            dhcp4: false
            addresses: [${STATIC_IP}]
            nameservers:
              addresses: [${DNS_SERVERS}]
            routes:
              - to: default
                via: ${GATEWAY_IP}
runcmd:
  - netplan apply
EOF
}

launch_instance() {
    local INSTANCE_NAME=$1

    multipass launch \
        --name "${INSTANCE_NAME}" \
        --memory 1G \
        --network "${network_arg}" \
        --cloud-init "${INSTANCE_NAME}-cloud-init.yaml" \
        --timeout 600
    rm -f "${INSTANCE_NAME}-cloud-init.yaml"
}

create_and_launch_instance() {
    local INSTANCE_NAME=$1
    local STATIC_IP=$2
    local GATEWAY_IP=$3
    local DNS_SERVERS=$4

    multipass_purge "${INSTANCE_NAME}"
    create_cloud_init "${INSTANCE_NAME}" "${STATIC_IP}" "${GATEWAY_IP}" "${DNS_SERVERS}"
    launch_instance "${INSTANCE_NAME}"
}

# Get the number of instances defined in config.yaml
num_instances=$(yq e '.instances | length' "${CONFIG_FILE}")

# Iterate over each instance and create it
for ((i = 0; i < num_instances; i++)); do
    name=$(yq e ".instances[${i}].name" "${CONFIG_FILE}")
    ip=$(yq e ".instances[${i}].ip" "${CONFIG_FILE}")
    gateway=$(yq e ".instances[${i}].gateway" "${CONFIG_FILE}")
    # Join the DNS array elements with commas
    dns=$(yq e ".instances[${i}].dns | join(\",\")" "${CONFIG_FILE}")
    create_and_launch_instance "${name}" "${ip}" "${gateway}" "${dns}"
done

multipass list
