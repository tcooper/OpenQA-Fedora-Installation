#!/bin/bash -e

set -exuo pipefail

# Based on `os-autoinst-setup-multi-machine`` provided by osautoinst
# [upstream](https://github.com/os-autoinst/os-autoinst/blob/master/script/os-autoinst-setup-multi-machine).
#
# Notable changes are that upstream uses `zypper` instead of `dnf` and the
# multi-machine network in our `os-autoinst-distri-rocky` repository is
# different than the original. Finally, all optional blocks selecting `wicked`
# or `NetworkManager` are simplified to use only `NetworkManager`.
#
# This setup doesn't include GRE setup which is included in
# `install-openqa-multi-machine-server.sh` in this repo. Additionally, this
# script forgoes the use of legacy `network-scripts`` for configuration of network
# devices which is the case with our other
# [guide](https://github.com/lumarel/knowledgebase/blob/master/docs/testing/openqa/installation.md)
# from Rocky Testing Team member @lumarel.
#
# This script has a partner, `remove-openqa-multi-machine-support.sh`, which can be
# used to undo the configuration applied by this script in order to modify the
# number of tap workers configured or for general test/development of adding tap
# workers to instance.

# The default number of workers in openqa.rockylinux.org is 18.
instances="${instances:-18}"

# In order to help identify that tap configuration was deployed with this script the bridge name is expressly not br0
bridge="${bridge:-"br1"}"

# Detect default ethernet device or support provision at sript run-time
default_ethernet=$(ip -json route show default | jq -r '.[]|.dev')
ethernet="${ethernet:-"$default_ethernet"}"

# For consistency with alternate deployments use the trusted zone for our multi-machine worker setup
zone="${zone:-"trusted"}"

# Set the MTU of the bridge interface according to https://docs.openvswitch.org/en/latest/faq/issues
# * See https://progress.opensuse.org/issues/151310
# * Use default of 1460 (instead of 1450 as the FAQ suggests) because 1460 should be low enough but
#   is still higher than 1458 which openSUSE MM tests configure within the SUT.
mtu=${mtu:-1460}

usage() {
    cat << EOF
Usage: $(basename $0)

Options:
 -h, --help         display this help
EOF
    exit "$1"
}

opts=$(getopt -o h -l help -n "$0" -- "$@") || usage 1
eval set -- "$opts"
while true; do
    case "$1" in
        -h | --help) usage 0 ;;
        --)
            shift
            break
            ;;
        *) break ;;
    esac
done

# must run as root
if [ "$EUID" -ne 0 ]
  then echo "MUST run as root"
  exit
fi

ensure_ip_forwarding() {

    grep -q 1 /proc/sys/net/ipv4/ip_forward || echo -e 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1' > /etc/sysctl.d/ip_forward.conf

}

install_packages() {

    rpm -q openvswitch os-autoinst-openvswitch firewalld libcap NetworkManager-ovs || \
	    dnf -y install openvswitch os-autoinst-openvswitch firewalld libcap NetworkManager-ovs

}

configure_firewall() {

    systemctl is-active firewalld.service || systemctl enable --now firewalld.service

    # Backup the ${default_zone}.xml configuration in case we modify it.
    default_zone=$(firewall-cmd --get-default-zone)
    test -f /etc/firewalld/zones/"$default_zone".xml && \
	   cp -v /etc/firewalld/zones/"$default_zone".xml /etc/firewalld/zones/"$default_zone".xml.$(date -Isec)

    # Backup the ${zone}.xml configuration if it exists... we will be replacing it.
    # Instances where this would be seen is if/when we rerun this script to change the number of
    # tap workers and/or the name of bridge device we're using.
    test -f /etc/firewalld/zones/"$zone".xml && \
	    cp -v /etc/firewalld/zones/"$zone".xml /etc/firewalld/zones/"$zone".xml.$(date -Isec)

    # Backup previous isotovideo.xml service config if it exists, we will be replacing it.
    test -f /etc/firewalld/services/isotovideo.xml && \
	    cp -v /etc/firewalld/services/isotovideo.xml /etc/firewalld/services/isotovideo.xml.$(date -Isec)

    # Remove old isotovideo service
    firewall-cmd --info-service isotovideo && firewall-cmd --permanent --delete-service=isotovideo

    # For some reason here full restart of firewalld.service is required. firewall-cmd --reload will not do it.
    systemctl restart firewalld.service

    # Add new/empty isotovideo service, we'll be adding ports for each of the worker instances
    firewall-cmd --permanent --new-service isotovideo

    # For some reason here full restart of firewalld.service is required. firewall-cmd --reload will not do it.
    systemctl restart firewalld.service

    # Add a port to the isotovideo service for each worker and assign the service to our zone (usually trusted)
    for i in $(seq 1 "$instances"); do
	    firewall-cmd --permanent --service=isotovideo --add-port=$((i * 10 + 20003))/tcp
    done
    firewall-cmd --permanent --zone="$zone" --add-service=isotovideo

    # Not currently certain the $ethernet interface belongs in the trusted zone.
    # I think it belongs on the public for FedoraServer zone
    #if [[ $default_zone != "$zone" ]]; then
    #    firewall-cmd -q --permanent --remove-interface="$ethernet" --zone="$default_zone"
    #    firewall-cmd --set-default-zone="$zone"
    #fi

    # Replace the ${zone} (default name trusted) with the following content
    cat > /etc/firewalld/zones/"$zone".xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<zone target="ACCEPT">
  <short>"${zone^}"</short>
  <description>All network connections are accepted.</description>
  <service name="isotovideo"/>
  <interface name="$bridge"/>
  <interface name="ovs-system"/>
  <masquerade/>
</zone>
EOF

    # For some reason here full restart of firewalld.service is required. firewall-cmd --reload will not do it.
    systemctl restart firewalld.service

}

start_openvswitch() {

    # Enable and start the openvswitch service
    systemctl is-active openvswitch || systemctl enable --now openvswitch

}

create_gre_preup_script() {

    local location=$1

    cat > "$location" << EOF
#!/bin/sh
action="\$1"
bridge="\$2"
ovs-vsctl set bridge \$bridge rstp_enable=true
# TODO add entries according to your network topology
#ovs-vsctl --may-exist add-port \$bridge gre1 -- set interface gre1 type=gre options:remote_ip=<IP address of other host>
EOF

    chmod +x "$location"

}

setup_multi_machine_with_networkmanager() {

    # Restart NM to load ovs plugin
    systemctl restart NetworkManager

    # Delete any previous connections
    nmcli con | grep -oP 'ovs-(interface|port|bridge|slave)-[\w-]+' | xargs -r nmcli con del || true

    # Create bridge, port and interface connection
    nmcli con add type ovs-bridge con.int "$bridge"
    nmcli con add type ovs-port con.int "$bridge" con.master "$bridge"
    nmcli con add type ovs-interface con.int "$bridge" con.master "$bridge" ipv4.method manual ipv4.address 172.16.2.2/15 ethernet.mtu "$mtu" con.zone "$zone"

    # Create tap interfaces
    for i in 0 $(
        seq 1 "$instances"
        seq 64 $((64 + instances))
        seq 128 $((128 + instances))
    ); do
        nmcli con add type ovs-port con.int "tap$i" con.master "$bridge"
        nmcli con add type tun mode tap owner "$(id -u _openqa-worker)" group "$(getent group nogroup | cut -f3 -d:)" con.int "tap$i" master "tap$i"
    done

    create_gre_preup_script /etc/NetworkManager/dispatcher.d/gre_tunnel_preup.sh
}

configure_openvswitch() {
    cat > /etc/sysconfig/os-autoinst-openvswitch << EOF
OS_AUTOINST_USE_BRIDGE=${bridge}
OS_AUTOINST_BRIDGE_LOCAL_IP=172.16.2.2
OS_AUTOINST_BRIDGE_REWRITE_TARGET=172.17.0.0
EOF

    systemctl enable os-autoinst-openvswitch
    systemctl restart openvswitch os-autoinst-openvswitch

}

main() {

    ensure_ip_forwarding
    install_packages
    configure_firewall
    start_openvswitch
    setup_multi_machine_with_networkmanager
    configure_openvswitch

}

caller 0 > /dev/null || main "$@"
