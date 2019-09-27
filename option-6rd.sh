#!/bin/vbash
#
# 6RD DHCP configuration script
#
# Based on many existing scripts, such as:
#  1) dhclient-6rd by Nathan Lutchansky for Ubuntu 10.04
#  2) Alexandre Beloin  http://beloin.net/doc/6rd.txt
#
# This script is public domain.
#

#
# ************************* Installation Instructions *************************
#
# 1) Place this script in /etc/dhcp3/dhclient-exit-hooks.d/option-6rd to assign IPv6 adresses
# 2) Script asumes eth0 - ISP link, switch0 - LAN link
# 3) apt-get install ipv6calc
# 4) You must edit /run/dhclient_eth0.conf to add the option-6rd definition:
#
# option option-6rd code 212 = { integer 8, integer 8, integer 16, integer 16,
# integer 16, integer 16, integer 16, integer 16,
# integer 16, integer 16, array of ip-address };
#
#
# *****************************************************************************
#

PATH=/sbin:/usr/local/bin:$PATH
source /opt/vyatta/etc/functions/script-template


log_6rd() {
	#$new_ip_address, and the interface name is passed in $interface
	WANIF=$interface
	LANIF="switch0"
	WANIP4=$new_ip_address

	if [ -z "$new_option_6rd" ]; then
		logger -p daemon.error -t option-6rd "no 6RD parameters available"
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
	srd_prefix="`printf "%x:%x:%x:%x:%x:%x:%x:%x" ${srd_vals[@]:2:8} | sed -E s/\(:0\)+$/::/`"
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
	ifname_ip6addr="$(echo "$delagated_prefix" | awk '{split($0,a,"/"); print a[1]}')1/$(echo "$delagated_prefix" | awk '{split($0,a,"/"); print a[2]}')"
	lan_ip6addr="$(echo "$delagated_prefix" | awk '{split($0,a,"/"); print a[1]}')1/64" # Need to change if using subnet (if Delagated prefix < 64)
	lan_ip6net="$(echo "$delagated_prefix" | awk '{split($0,a,"/"); print a[1]}')/64" # Need to change if using subnet (if Delagated prefix < 64)


	if [ -f /config/telia-6rd-cleanup ]; then
		CLEANUP=/config/telia-6rd-cleanup
	else
		CLEANUP=/dev/null
	fi

	/bin/vbash $CLEANUP


	configure

    # firewall setup
    set firewall ipv6-name internet6-in enable-default-log
    set firewall ipv6-name internet6-in rule 10 action accept
    set firewall ipv6-name internet6-in rule 10 description 'Allow established connections'
    set firewall ipv6-name internet6-in rule 10 log disable
    set firewall ipv6-name internet6-in rule 10 state established enable
    set firewall ipv6-name internet6-in rule 10 state related enable
    set firewall ipv6-name internet6-in rule 20 action drop
    set firewall ipv6-name internet6-in rule 20 log enable
    set firewall ipv6-name internet6-in rule 20 state invalid enable
    set firewall ipv6-name internet6-in rule 30 action accept
    set firewall ipv6-name internet6-in rule 30 log disable
    set firewall ipv6-name internet6-in rule 30 protocol icmpv6

	# tunnel common settings
    set interfaces tunnel tun0 description 'Telia 6rd Tunnel'
    set interfaces tunnel tun0 encapsulation sit
    set interfaces tunnel tun0 firewall in ipv6-name internet6-in
    set interfaces tunnel tun0 firewall local ipv6-name internet6-in
    set interfaces tunnel tun0 local-ip 0.0.0.0
    set interfaces tunnel tun0 mtu 1472
    set interfaces tunnel tun0 multicast enable
    set interfaces tunnel tun0 remote-ip "$srd_braddr"
    set interfaces tunnel tun0 ttl 255

    # set tunnel ipv6-address
    set interfaces tunnel tun0 address "$ifname_ip6addr"

    # set routes
    set protocols static route6 "$lan_ip6net" blackhole
    set protocols static interface-route6 ::/0 next-hop-interface tun0


    # lan setup
    set interfaces switch switch0 address "$lan_ip6addr"

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

    commit
	save
	configure_exit

	/bin/cat > /config/telia-6rd-cleanup <<EOF
	source /opt/vyatta/etc/functions/script-template
	configure
	delete interfaces tunnel tun0 remote-ip "$srd_braddr"
	delete protocols static route6 "$lan_ip6net" blackhole
    delete protocols static interface-route6 ::/0 next-hop-interface tun0
	delete interfaces switch switch0 address "$lan_ip6addr"
	commit
	save
	configure_exit
EOF

}

case $reason in
	BOUND|RENEW|REBIND|REBOOT)
		log_6rd
		;;
esac
