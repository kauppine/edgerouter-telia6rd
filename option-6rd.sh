#!/bin/vbash
#
# Edgerouter 6RD SLAAC configuration script
#
# Based on many existing scripts, such as:
#  1) dhclient-6rd by Nathan Lutchansky for Ubuntu 10.04
#  2) Alexandre Beloin  http://beloin.net/doc/6rd.txt
#  3) Harry Sintonen's work with Debian and 6RD
#
# This script is public domain.
#
#
# ************************* Installation Instructions *************************
#
# 1) Place this script in /etc/dhcp3/dhclient-exit-hooks.d/option-6rd to assign IPv6 adresses
# 2) Script asumes eth0 - ISP link, switch0 - LAN link
# 3) apt-get install ipv6calc
#
# *****************************************************************************
#

PATH=/sbin:/usr/local/bin:$PATH
source /opt/vyatta/etc/functions/script-template

# Log output and errors to syslog
exec 1> >(logger -s -t $(basename $0)) 2>&1

log_6rd() {
	#$new_ip_address, and the interface name is passed in $interface
	WANIF=$interface
	LANIF="switch0"
	WANIP4=$new_ip_address
	
	if ! ipv6calc -v; then
		logger -p daemon.error -t option-6rd "ipv6calc is not installed, quitting"
		return
	fi

	if [ -z "$new_option_6rd" ]; then
		logger -p daemon.error -t option-6rd "no 6RD parameters available, quitting"
		return
	fi

	OPTFILE="/run/dhcp-option-6rd.${WANIF}"
	if [ -e "${OPTFILE}" ]; then
		old_option_6rd="$(cat "${OPTFILE}")"
	else
		old_option_6rd=""
	fi

	if [ "${new_option_6rd}:${WANIP4}" == "${old_option_6rd}" ]; then
		logger -p daemon.error -t option-6rd "no 6RD parameter change"
		return
	fi
	echo "${new_option_6rd}:${WANIP4}" > "${OPTFILE}"


	srd_vals=(${new_option_6rd})

	srd_masklen=${srd_vals[0]}
	srd_prefixlen=${srd_vals[1]}
	srd_prefix="`printf "%x:%x:%x:%x:%x:%x:%x:%x" $(for x in $(seq 2 8) ; do echo $((${srd_vals[$x]} & (1 << 16) - 1)) ; done) | sed -E s/\(:0\)+$/::/`"
	srd_braddr=${srd_vals[10]}
	ipsep=(${new_ip_address//\./ })

	if (( srd_masklen==0 )); then
		srd_relayprefix=0.0.0.0
	elif (( srd_masklen <= 8 )); then
		masked=$((${ipsep[0]} & ~((1 << (8 - srd_masklen)) - 1)))
		srd_relayprefix=${masked}.0.0.0
	elif (( srd_masklen <= 16 )); then
		masked=$((${ipsep[1]} & ~((1 << (16 - srd_masklen)) - 1)))
		srd_relayprefix=${ipsep[0]}.${masked}.0.0
	elif (( srd_masklen <= 24 )); then
		masked=$((${ipsep[2]} & ~((1 << (24 - srd_masklen)) - 1)))
		srd_relayprefix=${ipsep[0]}.${ipsep[1]}.${masked}.0
	elif (( srd_masklen <= 32 )); then
		masked=$((${ipsep[3]} & ~((1 << (32 - srd_masklen)) - 1)))
		srd_relayprefix=${ipsep[0]}.${ipsep[1]}.${ipsep[2]}.${masked}
	else
		logger -p daemon.error -t option-6rd "invalid IPv4MaskLen $srd_masklen"
		return
	fi

	logger -t option-6rd "6RD parameters: 6rd-prefix ${srd_prefix}/${srd_prefixlen} 6rd-relay_prefix ${srd_relayprefix}/${srd_masklen} br ${srd_braddr}"
	delagated_prefix=`ipv6calc -q --action 6rd_local_prefix --6rd_prefix ${srd_prefix}/${srd_prefixlen} --6rd_relay_prefix ${srd_relayprefix}/${srd_masklen} $WANIP4`
	prefix_len=$(echo "$delagated_prefix" | awk '{split($0,a,"/"); print a[2]}')
	ifname_ip6addr="$(echo "$delagated_prefix" | awk '{split($0,a,"/"); print a[1]}')1/128"

	# Lan /64 calculation
	if ((prefix_len == 56)); then
		lan_ip6addr="$(echo "$delagated_prefix" | awk -F : '{printf "%s:%s:%s:%.2s01::1/64\n", $1, $2, $3, $4}')"
		lan_ip6net="$(echo "$delagated_prefix" | awk -F : '{printf "%s:%s:%s:%.2s01::/64\n", $1, $2, $3, $4}')"
	elif ((prefix_len == 64)); then
		lan_ip6addr="$(echo "$delagated_prefix" | awk '{split($0,a,"/"); print a[1]}')1/64"
		lan_ip6net="$(echo "$delagated_prefix" | awk '{split($0,a,"/"); print a[1]}')/64"
	else
		logger -p daemon.error -t option-6rd "Unsupported prefix length $prefix_len"
		return
	fi



	if [ -f /config/telia-6rd-cleanup ]; then
		CLEANUP=/config/telia-6rd-cleanup
	else
		CLEANUP=/dev/null
	fi

	/bin/vbash $CLEANUP


	configure

    # firewall setup, it is identical to the default Edgerouter IPv6 firewall
	set firewall ipv6-name WANv6_IN default-action drop
	set firewall ipv6-name WANv6_IN description 'WAN inbound traffic forwarded to LAN'
	set firewall ipv6-name WANv6_IN enable-default-log
	set firewall ipv6-name WANv6_IN rule 10 action accept
	set firewall ipv6-name WANv6_IN rule 10 description 'Allow established/related sessions'
	set firewall ipv6-name WANv6_IN rule 10 state established enable
	set firewall ipv6-name WANv6_IN rule 10 state related enable
	set firewall ipv6-name WANv6_IN rule 20 action drop
	set firewall ipv6-name WANv6_IN rule 20 description 'Drop invalid state'
	set firewall ipv6-name WANv6_IN rule 20 state invalid enable
	set firewall ipv6-name WANv6_LOCAL default-action drop
	set firewall ipv6-name WANv6_LOCAL description 'WAN inbound traffic to the router'
	set firewall ipv6-name WANv6_LOCAL enable-default-log
	set firewall ipv6-name WANv6_LOCAL rule 10 action accept
	set firewall ipv6-name WANv6_LOCAL rule 10 description 'Allow established/related sessions'
	set firewall ipv6-name WANv6_LOCAL rule 10 state established enable
	set firewall ipv6-name WANv6_LOCAL rule 10 state related enable
	set firewall ipv6-name WANv6_LOCAL rule 20 action drop
	set firewall ipv6-name WANv6_LOCAL rule 20 description 'Drop invalid state'
	set firewall ipv6-name WANv6_LOCAL rule 20 state invalid enable
	set firewall ipv6-name WANv6_LOCAL rule 30 action accept
	set firewall ipv6-name WANv6_LOCAL rule 30 description 'Allow IPv6 icmp'
	set firewall ipv6-name WANv6_LOCAL rule 30 protocol ipv6-icmp
	set firewall ipv6-name WANv6_LOCAL rule 40 action accept
	set firewall ipv6-name WANv6_LOCAL rule 40 description 'allow dhcpv6'
	set firewall ipv6-name WANv6_LOCAL rule 40 destination port 546
	set firewall ipv6-name WANv6_LOCAL rule 40 protocol udp
	set firewall ipv6-name WANv6_LOCAL rule 40 source port 547

	# tunnel settings

	set interfaces tunnel tun0 6rd-prefix "${srd_prefix}/${srd_prefixlen}"
	set interfaces tunnel tun0 6rd-relay_prefix "${srd_relayprefix}/${srd_masklen}"
	set interfaces tunnel tun0 description "Telia IPv6 6rd tunnel"
	set interfaces tunnel tun0 encapsulation sit 
	set interfaces tunnel tun0 local-ip "${WANIP4}" 
	set interfaces tunnel tun0 6rd-default-gw "::${srd_braddr}"
	set interfaces tunnel tun0 mtu 1472 
	set interfaces tunnel tun0 multicast disable 
	set interfaces tunnel tun0 ttl 255 
	set interfaces tunnel tun0 address "${ifname_ip6addr}"
	set interfaces tunnel tun0 firewall in ipv6-name WANv6_IN
    set interfaces tunnel tun0 firewall local ipv6-name WANv6_LOCAL

    # set routes
    set protocols static route6 "${delagated_prefix}" blackhole
    set protocols static interface-route6 ::/0 next-hop-interface tun0


    # lan address setup
    set interfaces switch switch0 address "${lan_ip6addr}"


	# SLAAC
    set interfaces switch switch0 ipv6 dup-addr-detect-transmits 1
    set interfaces switch switch0 ipv6 router-advert cur-hop-limit 64
    set interfaces switch switch0 ipv6 router-advert managed-flag false
    set interfaces switch switch0 ipv6 router-advert max-interval 30
    set interfaces switch switch0 ipv6 router-advert other-config-flag false
    set interfaces switch switch0 ipv6 router-advert prefix '::/64' autonomous-flag true
    set interfaces switch switch0 ipv6 router-advert prefix '::/64' on-link-flag true
    set interfaces switch switch0 ipv6 router-advert prefix '::/64' valid-lifetime 600
    set interfaces switch switch0 ipv6 router-advert reachable-time 0
    set interfaces switch switch0 ipv6 router-advert retrans-timer 0
    set interfaces switch switch0 ipv6 router-advert send-advert true

	# Advertise Edgerouter IPv6-address as DNS-server
	set interfaces switch switch0 ipv6 router-advert name-server "${lan_ip6addr}"

    commit
	save
	configure_exit

	/bin/cat > /config/telia-6rd-cleanup <<EOF
	#!/bin/vbash
	PATH=/sbin:/usr/local/bin:$PATH
	source /opt/vyatta/etc/functions/script-template
	configure
	delete interfaces tunnel tun0
	delete protocols static route6 "${delagated_prefix}" blackhole
    delete protocols static interface-route6 ::/0 next-hop-interface tun0
	delete interfaces switch switch0 address "${lan_ip6addr}"
	delete interfaces switch switch0 ipv6
	commit
	save
	configure_exit
EOF

}

case $reason in
	BOUND|RENEW|REBIND|REBOOT)
		log_6rd
		;;
	
	EXPIRE|FAIL|RELEASE|STOP)
		/bin/vbash /config/telia-6rd-cleanup
		;;
esac
