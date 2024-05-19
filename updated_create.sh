#!/usr/bin/env bash
# Create a VM from a template VM on one of our hosts.
# shellcheck disable=SC1091,SC2029

shopt -s nullglob extglob
set -eo pipefail

. automation/scripts/_utils.sh

# Hostname must be SSH'able.
TARGET_HOSTNAME="${1:-"poweredge1-local"}"

# Number of cores to assign the new VM.
CORES="${2:-4}"

# Memory to give the new VM (for some reason, libvirt expects KiB, so I accept MiB like virt-manager and convert).
MEMORY="${3:-4096}"
MEMORY="$(( MEMORY * 2 ** 10 ))" # convert from MiB -> KiB

# "worker" or "master" - this flag determines what node assignments are granted by RKE.
NODE_TYPE="${4:-worker}"

# RKE config in /cluster
CLUSTER_RKE_CONFIG="${5:-"cluster/rivendell-cluster.yaml"}"

# Name of the virsh domain to use as a template for cloning. This is also referenced for VD paths.
TARGET_HOST_TEMPLATE_NAME="${6:-"ubuntu-template"}"

# Defaults to /cloud-init/network-config.template.
NETWORK_CONFIG_TEMPLATE="${7:-"cloud-init/network-config.template"}"

# Defaults to /cloud-init/meta-data.template.
METADATA_TEMPLATE="${8:-"cloud-init/meta-data.template"}"

# Config listing IP ranges available on the LAN for the specified cluster.
IPRANGE_CONFIG="${9:-"automation/iprange.yaml"}"

if [ "$NODE_TYPE" != "worker" ] && [ "$NODE_TYPE" != "master" ]; then
    _error "Node type must be one of either \"worker\" or \"master\""
    exit 1
fi

## Use 'automation/iprange.yaml' in conjunction with the cluster's RKE manifest
## 'cluster/{clusterName}-cluster.yaml' to determine a free IP. If none are free,
## exit with an error.
get_available_IP() {
    if [ $# -ne 1 ]; then
        _error "Function \"get_available_IP\" expected 1 argument: cluster name"
        exit 1
    fi

    local cluster_name min_ip max_ip ip_as_int _ip reserved_ips reserved_ip ip_int_range

    cluster_name="$1"
    
    # Load IP range only once
    local iprange_data
    iprange_data=$(yq ".clusters.\"${cluster_name}\"" "$IPRANGE_CONFIG")
    min_ip=$(echo "$iprange_data" | yq '.lan_ip_range.min')
    max_ip=$(echo "$iprange_data" | yq '.lan_ip_range.max')

    # Convert IP addresses to integer
    ip_to_int() {
        local a b c d
        IFS=. read -r a b c d <<<"$1"
        echo "$((a * 256 ** 3 + b * 256 ** 2 + c * 256 + d))"
    }

    min_ip_int=$(ip_to_int "$min_ip")
    max_ip_int=$(ip_to_int "$max_ip")

    reserved_ips=($(yq ".clusters.\"${cluster_name}\".reserved_ips[]" "$IPRANGE_CONFIG"))

    for ip_as_int in $(seq "$min_ip_int" "$max_ip_int"); do
        _ip=$(printf "%d.%d.%d.%d" "$((ip_as_int >> 24 & 255))" "$((ip_as_int >> 16 & 255))" "$((ip_as_int >> 8 & 255))" "$((ip_as_int & 255))")
        if [[ ! " ${reserved_ips[@]} " =~ " ${_ip} " ]]; then
            echo "$_ip"
            return 0
        fi
    done

    _error "No available IPs in range ${min_ip} - ${max_ip}"
    exit 1
}

clone_vm() {
    local cluster_name new_ip instance_name destination_iso_path
    cluster_name="$1"
    new_ip="$(get_available_IP "$cluster_name")"
    instance_name="${TARGET_HOST_TEMPLATE_NAME}-${new_ip//./-}"
    destination_iso_path="/var/lib/libvirt/images/seed-${instance_name}.iso"

    # Clone VM
    _info "Cloning $TARGET_HOST_TEMPLATE_NAME to $instance_name"
    virsh -q -c qemu+ssh://"$TARGET_HOSTNAME"/system         vol-clone --pool default --vol "${TARGET_HOST_TEMPLATE_NAME}.qcow2"         --newname "${instance_name}.qcow2"

    _info "Creating new domain $instance_name"
    virsh -q -c qemu+ssh://"$TARGET_HOSTNAME"/system         create <(virt-install --connect qemu+ssh://"$TARGET_HOSTNAME"/system             --name "$instance_name"             --memory "$MEMORY"             --vcpus "$CORES"             --disk path=/var/lib/libvirt/images/"${instance_name}.qcow2"             --import --noautoconsole)

    # Update domain memory
    virsh -q -c qemu+ssh://"$TARGET_HOSTNAME"/system         setmem "$instance_name" "$MEMORY" --config &&         _info "Successfully updated memory count of domain $instance_name -> $MEMORY MiB"

    ## Initialization

    # Start the new domain
    _info "Starting new domain $instance_name"
    virsh -q -c qemu+ssh://"$TARGET_HOSTNAME"/system start "$instance_name" &&     _info "Domain $instance_name successfully started"

    # Wait for the VM to become available on the specified IP and SSHd listening on port 22
    i=1
    while ! ping -q -c 1 -w 2 "$new_ip" >/dev/null; do
        _info "Waiting for VM to become pingable at $new_ip, attempt $i"
        (( i+=1 ))
        sleep 5
    done

    i=1
    while [ "$(nmap -p 22 -Pn "$new_ip" | grep -o open)" != "open" ]; do
        _info "Waiting for VM to be listening on SSH port 22 at $new_ip, attempt $i"
        (( i+=1 ))
        sleep 5
    done

    # Update repository state to track this new IP to avoid duplicate IPs
    update_state "$new_ip" "$cluster_name" "$instance_name"

    ## Post-initialization

    # Run ansible for final domain configuration before adding it to a cluster
    ssh-keygen -f "$HOME"/.ssh/known_hosts -R "$new_ip" &>/dev/null || true
    while ! ssh -o 'StrictHostKeyChecking=accept-new' -F ~/.ssh/config "$new_ip" exit &>/dev/null; do sleep 1; done
    ansible "$cluster_name"

    # Clean up seed.iso for the next VM run, so we don't hit permissions problems with scp
    _info "Cleaning up ISO $destination_iso_path on host $TARGET_HOSTNAME"
    ssh "$TARGET_HOSTNAME" rm -f "$destination_iso_path"

    # RKE
    if [ "$NODE_TYPE" = "worker" ]; then
        # If the member just created was a worker node, only touch workers, leave the masters alone
        ./scripts/rke/update-nodes.sh "$CLUSTER_RKE_CONFIG"
    else
        # If a master was just added, touch all nodes in the cluster config
        ./scripts/rke/up.sh "$CLUSTER_RKE_CONFIG"
    fi

    _info "Finished VM creation with IP $new_ip."
}

main() {
    if [ $# -lt 1 ]; then
        _error "Usage: $0 <cluster_name> [<target_hostname>] [<cores>] [<memory>] [<node_type>] [<cluster_rke_config>] [<target_host_template_name>] [<network_config_template>] [<metadata_template>] [<iprange_config>]"
        exit 1
    fi

    local cluster_name="$1"
    shift

    clone_vm "$cluster_name" "$@"
}

main "$@"
