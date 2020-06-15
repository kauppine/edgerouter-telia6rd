# Edgerouter X Telia 6RD setup

Not maintained anymore as I don't have access to a 6rd tunnel.

## Description

Telia provides 6RD options by using IPv4 DHCP and "option-6rd" DHCP-option. By default, Ubiquiti Edgerouter does not query that option and therefore has to be configured either through CLI or GUI.
Additionally, this repository provides a DHCP post-hook script, which setups the tunnel and firewall after the parameters have been acquired from the operator.

The LAN client's IPv6-addresses are configured using SLAAC and the router will provide its own IPv6-address as a nameserver address via router advertisements.

Currently supports /56 and /64 prefixes, if /56 is used then :xx00::1/128 is used for the internet interface and :xx01::1/64 for the local. If the prefix is /64, then ::1/128 is configured for the internet interface and ::1/64 for the lan.
If there is a better solution, let me know. Pull request are welcomed.

This project assumes that eth0 is the WAN-interface and switch0 is the LAN-interface.

Tested on v.2.0.8

This project relies on the work of Harry Sintonen and cpcowart. See references for their IPv6 RD projects.

### Known issues

* The script won't persist over firmware upgrades and needs to be redownloaded. Other than that, the configuration is saved.

## Setup

### Prequisites

Package ```ipv6calc``` is required for the DHCP-script.
Ubiquiti has a good description on how to add Debian packages to Edgerouter:
<https://help.ubnt.com/hc/en-us/articles/205202560-EdgeRouter-Add-Debian-Packages-to-EdgeOS>

### Process

Run the following commands in Edgerouter shell to download the script to correct folder and set the DHCP-client options:

```bash
sudo curl https://raw.githubusercontent.com/kauppine/edgerouter-telia6rd/master/option-6rd.sh -o /etc/dhcp3/dhclient-exit-hooks.d/option-6rd
configure
set interfaces ethernet eth0 dhcp-options global-option "option option-6rd code 212 = { integer 8, integer 8, integer 16, integer 16, integer 16, integer 16, integer 16, integer 16, integer 16, integer 16, array of ip-address };"
set interfaces ethernet eth0 dhcp-options client-option "request option-6rd;"
commit
save
```

This should restart the DHCP-client, get the 6RD-options and setup the 6RD-tunnel.

## References

<https://sintonen.fi/debian-6rd/>

<https://github.com/cpcowart/ubiquiti-scripts/>
