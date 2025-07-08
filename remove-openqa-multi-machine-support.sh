#!/bin/bash -e

set -exuo pipefail

# This script has a partner, `install-openqa-multi-machine-support.sh`, which
# can be used to apply tap worker configuration.

# This script and it's partner prefer bridge name br1 over br0 intentionally.
bridge="${bridge:-"br1"}"

# Detect default ethernet device or support provision at sript run-time
default_ethernet=$(ip -json route show default | jq -r '.[]|.dev')
ethernet="${ethernet:-"$default_ethernet"}"

# Restore standard `public` zone
zone="${zone:-"public"}"

usage() {
    cat << EOF
Usage: $(basename "${0}")

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

unconfigure_openvswitch() {

	if systemctl is-active openvswitch.service ; then

		# Stop and disable os-autoinst-openvswitch
		systemctl is-active os-autoinst-openvswitch && \
			systemctl disable --now os-autoinst-openvswitch

		# Archive os-autoinst-openvswitch config after extracting configured bridge name
		if [[ -f /etc/sysconfig/os-autoinst-openvswitch ]]; then
			bridge=$(awk -F= '/^OS_AUTOINST_USE_BRIDGE=/ {print $2}' /etc/sysconfig/os-autoinst-openvswitch)
			mv /etc/sysconfig/os-autoinst-openvswitch \
				"/etc/sysconfig/os-autoinst-openvswitch.$(date -Isec)"
	    	fi

		#  Remove configured openvswitch bridges
		ovs-vsctl br-exists "${bridge}" && \
	    		ovs-vsctl del-br "${bridge}"

		# ovs-vsctl show
		systemctl disable --now openvswitch.service
	fi
}

unconfigure_multimachine_in_networkmanager() {

	# Remove nm config for configured ovswitch bridge
	set +e
	nmcli con | grep -q -oP 'ovs-(interface|port|bridge|slave)-[\w-]+'
	res=$?
	set -e
	if [[ $res -eq 0 ]]; then
    		for el in interface slave port bridge
    		do
    			nmcli con | grep -oP "ovs-${el}-${bridge}" | xargs -r nmcli con del || true
    			nmcli con | grep -oP "ovs-${el}-[\w-]+" | xargs -r nmcli con del || true
    		done

		# Archive gre_tunnel_preup.sh
		test -f /etc/NetworkManager/dispatcher.d/gre_tunnel_preup.sh && \
			mv /etc/NetworkManager/dispatcher.d/gre_tunnel_preup.sh \
		"/etc/NetworkManager/dispatcher.d/gre_tunnel_preup.sh.$(date -Isec)"

		# Restart NetworkManager
		systemctl restart NetworkManager.service
    	fi
}

unconfigure_firewall() {

	# Archive previous firewalld zone configs
	for zone in public trusted
	do
		test -f "/etc/firewalld/zones/${zone}.xml" && \
			cp "/etc/firewalld/zones/${zone}.xml" "/etc/firewalld/zones/${zone}.xml.$(date -Isec)"
	done

	# Remove isotovideo service config
	set +e
	if firewall-cmd --info-service isotovideo ; then
		set -e
		firewall-cmd --permanent --delete-service=isotovideo
    		systemctl restart firewalld.service
	fi
	set -e

	# Restore ${ethernet} to default zone, assume public
	firewall-cmd --permanent --zone=public --change-interface="${ethernet}"
	firewall-cmd --set-default-zone=public

}

remove_default_bridge() {

	# NOTE: It's possible we don't need to do anything with this once firewall
	#       config is cleaned up.

	set +e
	if nmcli con show br0 ; then
		set -e
		nmcli con del br0
	fi
	set -e

}

uninstall_packages() {

	# NOTE: Removing these packages isn't srictly necessary but doing so
	#       will help verify the install version of this script works.

	set +e
	rpm -q openvswitch os-autoinst-openvswitch NetworkManager-ovs && \
		dnf remove -y openvswitch os-autoinst-openvswitch NetworkManager-ovs
	set -e

}


disable_ip_forwarding() {

	# NOTE: ip_forwarding is not typically enabled. This will remove the config
	#       file that restores this on reboot. It doesn't affect the running config.

	test -f /etc/sysctl.d/ip_forward.conf && \
		mv /etc/sysctl.d/ip_forward.conf "/etc/sysctl.d/ip_forward.conf.$(date -Isec)"

}

main() {
    unconfigure_openvswitch
    unconfigure_multimachine_in_networkmanager
    unconfigure_firewall
    remove_default_bridge
    disable_ip_forwarding
    uninstall_packages
}

caller 0 > /dev/null || main "$@"
