#!/usr/bin/env bash
set -euo pipefail

# Function to install applications based on OS and package manager
install_application() {
  local app="$1"

  case "${OSTYPE}" in
  darwin*)
    if ! command -v brew &>/dev/null; then
      echo "Homebrew is not installed on macOS. Please install Homebrew first: https://brew.sh"
      exit 1
    fi
    brew install "${app}"
    ;;
  linux*)
    if command -v apt &>/dev/null; then
      sudo apt update
      sudo apt install -y "${app}"
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y "${app}"
    else
      echo "Unsupported Linux package manager. Please install ${app} manually."
      exit 1
    fi
    ;;
  *)
    echo "Unsupported OS type (${OSTYPE}). Please install ${app} manually."
    exit 1
    ;;
  esac
}

# Check if multipass is installed
if ! command -v multipass &>/dev/null; then
  install_application multipass
fi

# Check if yq is installed for parsing YAML
if ! command -v yq &>/dev/null; then
  install_application yq
fi

# Check if config.yaml exists in the current directory
CONFIG_FILE="config.yaml"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Configuration file ${CONFIG_FILE} not found. Exiting."
  exit 1
fi

# Read configuration variables from config.yaml and other sources
git_host=$(yq e '.git_host' "${CONFIG_FILE}")
git_username=$(yq e '.git_username' "${CONFIG_FILE}")
git_repository=$(yq e '.git_repository' "${CONFIG_FILE}")
windows_switch_name=$(yq e '.windows_switch_name' "${CONFIG_FILE}")
rsa_private=$(base64 <"$(yq e '.ssh_key' "${CONFIG_FILE}")")
rsa_public=$(base64 <"$(yq e '.ssh_key_pub' "${CONFIG_FILE}")")
vault_pass=$(cat ~/.ansible/vault_pass)

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
  - git
  - ansible
ssh_import_id:
  - gh:${git_username}
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
  - path: /root/.ansible/vault_pass
    owner: root:root
    defer: true
    permissions: 0o600
    content: "${vault_pass}"
  - path: /root/.ssh/id_rsa
    owner: root:root
    defer: true
    encoding: base64
    permissions: 0o600
    content: ${rsa_private}
  - path: /root/.ssh/id_rsa.pub
    owner: root:root
    defer: true
    encoding: base64
    permissions: 0o600
    content: ${rsa_public}
runcmd:
  - netplan apply
  - ssh-keyscan ${git_host} >> /root/.ssh/known_hosts
  - git clone git@${git_host}:${git_username}/${git_repository}.git /opt/${git_repository}
  - cd /opt/${git_repository}
  - ansible-playbook -c local localhost.yaml >> /root/.ansible/ansible.log
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
