#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# +-----------------------+    +---------------------+  +---------------------+
# | H1 (vrf)              |    | H2 (vrf)            |  | H3 (vrf)            |
# |                       |    |                     |  |                     |
# |    + $h1.10           |    |              $h2 +  |  |              $h2 +  |
# |    | 192.0.2.1/28     |    |    192.0.2.34/28 |  |  |    192.0.2.66/28 |  |
# |    | 2001:db8:1::1/64 |    | 2001:db8:2::2/64 |  |  | 2001:db8:3::2/64 |  |
# |    |                  |    |                  |  |  |                  |  |
# |    + $h1              |    |                  |  |  |                  |  |
# +----|------------------+    +------------------|--+  +------------------|--+
#      |                                          |                        |
# +----|------------------------------------------|------------------------|--+
# |    |                                    $swp2 +                  $swp3 +  |
# |    |                            192.0.2.33/28            192.0.2.65/28    |
# |    |                         2001:db8:2::1/64         2001:db8:3::1/64    |
# |    |                                                                      |
# | +--|---------------------------------------------+                        |
# | |  + $swp1                                       |                        |
# | |     vid 10                                     |                        |
# | |                                                |                        |
# | |  + vx10 (vxlan)         + vx10 (vxlan)         |     + lo10 (dummy)     |
# | |    local 192.0.2.100      local 2001:db8:4::1  |       192.0.2.100/28   |
# | |    group 233.252.0.1      group ff0e::1:2:3    |       2001:db8:4::1/64 |
# | |    id 1000                id 1000              |                        |
# | |    vid 10 pvid untagged   vid 10 pvid untagged |                        |
# | |                                                |                        |
# | | BR1 (802.1q)                                   |                        |
# | +------------------------------------------------+                        |
# |                                                                           |
# |                                                                    Switch |
# +---------------------------------------------------------------------------+
ALL_TESTS="
	ipv4_nomcroute
	ipv4_mcroute
	ipv4_mcroute_starg
	ipv4_mcroute_noroute
	ipv4_mcroute_fdb
	ipv4_mcroute_mcdev
	ipv4_mcroute_nomcdev

	ipv6_nomcroute
	ipv6_mcroute
	ipv6_mcroute_starg
	ipv6_mcroute_noroute
	ipv6_mcroute_fdb
	ipv6_mcroute_mcdev
	ipv6_mcroute_nomcdev
"

NUM_NETIFS=6
source lib.sh

: "${VXPORT:=4789}"
: "${GROUP4:=233.252.0.1}"
: "${GROUP6:=ff0e::1:2:3}"
: "${IPMR:=lo}"

h1_create()
{
	simple_if_init $h1
	defer simple_if_fini $h1

	ip_link_add $h1.10 up master v$h1 link $h1 type vlan id 10
	ip_addr_add $h1.10 192.0.2.1/28
	ip_addr_add $h1.10 2001:db8:1::1/64
}

install_capture()
{
	local dev=$1; shift

	tc qdisc add dev $dev clsact
	defer tc qdisc del dev $dev clsact

	tc filter add dev $dev ingress proto ip pref 104 \
	   flower skip_hw ip_proto udp dst_port $VXPORT \
	   action pass
	defer tc filter del dev $dev ingress proto ip pref 104

	tc filter add dev $dev ingress proto ipv6 pref 106 \
	   flower skip_hw ip_proto udp dst_port $VXPORT \
	   action pass
	defer tc filter del dev $dev ingress proto ipv6 pref 106
}

h2_create()
{
	simple_if_init $h2 192.0.2.34/28 2001:db8:2::2/64
	defer simple_if_fini $h2 192.0.2.34/28 2001:db8:2::2/64

	install_capture $h2
}

h3_create()
{
	simple_if_init $h3 192.0.2.66/28 2001:db8:3::2/64
	defer simple_if_fini $h3 192.0.2.66/28 2001:db8:3::2/64

	install_capture $h3
}

vx_create()
{
	local name=$1; shift

	ip_link_add "$name" up type vxlan dstport "$VXPORT" \
		nolearning noudpcsum tos inherit ttl 16 \
		"$@"
	ip_link_set_master "$name" br1
	bridge_vlan_add vid 10 dev "$name" pvid untagged

	# Wait for all the ARP, IGMP etc. noise to settle down.
	sleep 10
}

switch_create()
{
	# br1
	ip_link_add br1 type bridge vlan_filtering 1 \
			    vlan_default_pvid 0 mcast_snooping 0
	ip_link_set_addr br1 $(mac_get $swp1)
	ip_link_set_up br1

	# IPMR
	if [[ $IPMR != lo ]]; then
		ip_link_add "$IPMR" up type dummy
	fi
	ip_addr_add "$IPMR" 192.0.2.100/28
	ip_addr_add "$IPMR" 2001:db8:4::1/64

	ip route add table local multicast 224.0.0.0/4 dev "$IPMR"
	defer ip route del table local multicast 224.0.0.0/4 dev "$IPMR"

	ip -6 route add table local multicast ff00::/8 dev "$IPMR"
	defer ip -6 route del table local multicast ff00::/8 dev "$IPMR"

	# $swp1
	ip_link_set_up $swp1
	ip_link_set_master $swp1 br1
	bridge_vlan_add vid 10 dev $swp1

	# $swp2
	ip_link_set_up $swp2
	ip_addr_add $swp2 192.0.2.33/28
	ip_addr_add $swp2 2001:db8:2::1/64

	# $swp3
	ip_link_set_up $swp3
	ip_addr_add $swp3 192.0.2.65/28
	ip_addr_add $swp3 2001:db8:3::1/64
}

setup_prepare()
{
	h1=${NETIFS[p1]}
	swp1=${NETIFS[p2]}

	swp2=${NETIFS[p3]}
	h2=${NETIFS[p4]}

	swp3=${NETIFS[p5]}
	h3=${NETIFS[p6]}

	vrf_prepare
	defer vrf_cleanup

	forwarding_enable
	defer forwarding_restore

	h1_create
	h2_create
	h3_create
	switch_create
}

adf_install_broken_sg()
{
	adf_mcd_start "$IPMR" || exit $EXIT_STATUS

	mc_cli add $swp2 192.0.2.100 $GROUP4 $swp1 $swp3
	defer mc_cli remove $swp2 192.0.2.100 $GROUP4 $swp1 $swp3

	mc_cli add $swp2 2001:db8:4::1 $GROUP6 $swp1 $swp3
	defer mc_cli remove $swp2 2001:db8:4::1 $GROUP6 $swp1 $swp3
}

adf_install_sg()
{
	adf_mcd_start "$IPMR" || exit $EXIT_STATUS

	mc_cli add "$IPMR" 192.0.2.100 $GROUP4 $swp2 $swp3
	defer mc_cli remove "$IPMR" 192.0.2.33 $GROUP4 $swp2 $swp3

	mc_cli add "$IPMR" 2001:db8:4::1 $GROUP6 $swp2 $swp3
	defer mc_cli remove "$IPMR" 2001:db8:4::1 $GROUP6 $swp2 $swp3
}

adf_install_starg()
{
	adf_mcd_start "$IPMR" || exit $EXIT_STATUS

	mc_cli add "$IPMR" 0.0.0.0 $GROUP4 $swp2 $swp3
	defer mc_cli remove "$IPMR" 0.0.0.0 $GROUP4 $swp2 $swp3

	mc_cli add "$IPMR" :: $GROUP6 $swp2 $swp3
	defer mc_cli remove "$IPMR" :: $GROUP6 $swp2 $swp3
}

do_test()
{
	local sip=$1; shift
	local dip=$1; shift
	local flags=$1; shift
	local pref=$1; shift
	local expect_h2=$1; shift
	local expect_h3=$1; shift
	local what=$1; shift

	local mac=$(mac_get $h2)

	RET=0

	local t0_h2=$(tc_rule_stats_get $h2 $pref ingress)
	local t0_h3=$(tc_rule_stats_get $h3 $pref ingress)

	$MZ $flags $h1 -Q 10 -c 10 -d 100msec -p 64 -a own -b $mac \
	    -A "$sip" -B "$dip" -t udp sp=1234,dp=2345 -q
	sleep 1

	local t1_h2=$(tc_rule_stats_get $h2 $pref ingress)
	local t1_h3=$(tc_rule_stats_get $h3 $pref ingress)

	local d_h2=$((t1_h2 - t0_h2))
	local d_h3=$((t1_h3 - t0_h3))

	((d_h2 == expect_h2))
	check_err $? "Expected $expect_h2 packets on H2, got $d_h2"

	((d_h3 == expect_h3))
	check_err $? "Expected $expect_h3 packets on H3, got $d_h3"

	log_test "VXLAN MC flood $what"
}

ipv4_nomcroute()
{
	# Install a misleading (S,G) rule to attempt to trick the system into
	# pushing the packets elsewhere.
	adf_install_broken_sg
	vx_create vx10 id 1000 \
		local 192.0.2.100 group $GROUP4 dev "$swp2"
	do_test 192.0.2.1 192.0.2.2 "" 104 10 0 "IPv4 nomcroute"
}

ipv6_nomcroute()
{
	# Like for IPv4, install a misleading (S,G).
	adf_install_broken_sg
	vx_create vx10 id 1000 \
		local 2001:db8:4::1 group $GROUP6 dev "$swp2"
	do_test 2001:db8:1::1 2001:db8:1::2 -6 106 10 0 "IPv6 nomcroute"
}

ipv4_mcroute()
{
	adf_install_sg
	vx_create vx10 id 1000 \
		local 192.0.2.100 group $GROUP4 dev "$IPMR" mcroute
	do_test 192.0.2.1 192.0.2.2 "" 104 10 10 "IPv4 mcroute"
}

ipv6_mcroute()
{
	adf_install_sg
	vx_create vx10 id 1000 \
		local 2001:db8:4::1 group $GROUP6 dev "$IPMR" mcroute
	do_test 2001:db8:1::1 2001:db8:1::2 -6 106 10 10 "IPv6 mcroute"
}

ipv4_mcroute_starg()
{
	adf_install_starg
	vx_create vx10 id 1000 \
		local 192.0.2.100 group $GROUP4 dev "$IPMR" mcroute
	do_test 192.0.2.1 192.0.2.2 "" 104 10 10 "IPv4 mcroute (*,G)"
}

ipv6_mcroute_starg()
{
	adf_install_starg
	vx_create vx10 id 1000 \
		local 2001:db8:4::1 group $GROUP6 dev "$IPMR" mcroute
	do_test 2001:db8:1::1 2001:db8:1::2 -6 106 10 10 "IPv6 mcroute (*,G)"
}

ipv4_mcroute_noroute()
{
	vx_create vx10 id 1000 \
		local 192.0.2.100 group $GROUP4 dev "$IPMR" mcroute
	do_test 192.0.2.1 192.0.2.2 "" 104 0 0 "IPv4 mcroute, no route"
}

ipv6_mcroute_noroute()
{
	vx_create vx10 id 1000 \
		local 2001:db8:4::1 group $GROUP6 dev "$IPMR" mcroute
	do_test 2001:db8:1::1 2001:db8:1::2 -6 106 0 0 "IPv6 mcroute, no route"
}

ipv4_mcroute_fdb()
{
	adf_install_sg
	vx_create vx10 id 1000 \
		local 192.0.2.100 dev "$IPMR" mcroute
	bridge fdb add dev vx10 \
		00:00:00:00:00:00 self static dst $GROUP4
	do_test 192.0.2.1 192.0.2.2 "" 104 10 10 "IPv4 mcroute FDB"
}

ipv6_mcroute_fdb()
{
	adf_install_sg
	vx_create vx10 id 1000 \
		local 2001:db8:4::1 dev "$IPMR" mcroute
	bridge -6 fdb add dev vx10 \
		00:00:00:00:00:00 self static dst $GROUP6
	do_test 2001:db8:1::1 2001:db8:1::2 -6 106 10 10 "IPv6 mcroute FDB"
}

# For mcdev / nomcdev tests, use $swp2 as the VXLAN bound device and expect H3
# to not get hit. But with nomcdev, expect $IPMR to get picked up for TX and
# packets be MC-routed to H3 as well.
ipv4_mcroute_mcdev()
{
	adf_install_sg
	vx_create vx10 id 1000 \
		local 192.0.2.100 group $GROUP4 dev $swp2 mcroute mcdev
	do_test 192.0.2.1 192.0.2.2 "" 104 10 0 "IPv4 dev swp mcroute mcdev"
}

ipv4_mcroute_nomcdev()
{
	adf_install_sg
	vx_create vx10 id 1000 \
		local 192.0.2.100 group $GROUP4 dev $swp2 mcroute nomcdev
	do_test 192.0.2.1 192.0.2.2 "" 104 10 10 "IPv4 dev swp mcroute nomcdev"
}

ipv6_mcroute_mcdev()
{
	adf_install_sg
	vx_create vx10 id 1000 \
		local 2001:db8:4::1 group $GROUP6 dev $swp2 mcroute mcdev
	do_test 2001:db8:1::1 2001:db8:1::2 -6 106 10 0 "IPv6 mcroute mcdev"
}

ipv6_mcroute_nomcdev()
{
	adf_install_sg
	vx_create vx10 id 1000 \
		local 2001:db8:4::1 group $GROUP6 dev $swp2 mcroute nomcdev
	do_test 2001:db8:1::1 2001:db8:1::2 -6 106 10 10 "IPv6 mcroute nomcdev"
}

trap cleanup EXIT

setup_prepare
setup_wait
tests_run

exit $EXIT_STATUS
