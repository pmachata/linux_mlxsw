#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# I believe that this implements the scenario from RM 3751168. $swp4-$swp5 are a
# spinner that maintains about 100Gbps stream of traffic mixed from all TC's. TC
# is signalled through 802.1p VLAN tagging.
#
# What I'm observing is that for $swp2-$h2 of 100Gbps, 40Gbps and 25Gbps, I get
# the top TCs with as much traffic as is being sent, then one transitional TC to
# round up to the line rate, and the low TCs are 0. E.g. for 40Gbps:
#
#    swp2 a_octets_received_ok       104.5Gb/s
#    swp2 rx_octets_prio_0   11.9Gb/s
#    swp2 rx_octets_prio_1   12.4Gb/s
#    swp2 rx_octets_prio_2   13.0Gb/s
#    swp2 rx_octets_prio_3   13.2Gb/s
#    swp2 rx_octets_prio_4   13.2Gb/s
#    swp2 rx_octets_prio_5   13.3Gb/s
#    swp2 rx_octets_prio_6   13.6Gb/s
#    swp2 rx_octets_prio_7   13.6Gb/s
#
#    swp3 a_octets_transmitted_ok    35.8Gb/s
#    swp3 tx_octets_prio_0   0b/s
#    swp3 tx_octets_prio_1   0b/s
#    swp3 tx_octets_prio_2   0b/s
#    swp3 tx_octets_prio_3   0b/s
#    swp3 tx_octets_prio_4   0b/s
#    swp3 tx_octets_prio_5   8.5Gb/s
#    swp3 tx_octets_prio_6   13.6Gb/s
#    swp3 tx_octets_prio_7   13.7Gb/s
#
#    swp4 a_octets_received_ok       35.9Gb/s
#
# For 10Gbps link I just get flat zeroes. Sometimes a blip on an unexpected TC
# (such as TC5 sending, say, 6Gbps for a while, then going back to zero). On
# Spectrum-3 the behavior of 10Gbps link seems to be correct -- we pass almost
# 10Gbps of the top TC, and the rest is dropped (i.e. there are 0 full TCs, and
# TC 7 is already a transitional TC).
#
# I had plans to send the extra traffic from H3, but opted for the simpler
# approach where $h1-$swp1 is not limited and that's how the pressure is
# created. So $swp3-$h3 is unused.
#
#                   .-------------------------------------.
#                   |                                     |
# +-----------------|-------------------------------------|-------------------+
# |                 |                                     |                   |
# | inject -> $swp5 +   <- - - - - - redirect - - - - -   + $swp4             |
# |     i/ePOOL1   / \                                   / \   i/ePOOL1       |
# |               /   \                                 /   \                 |
# |              /     \                               /     \                |
# |    $swp5.11 + . . . + $swp5.18           $swp4.11 + . . . + $swp4.18      |
# |                                                                           |
# | i/ePOOL0: 5MB dynamic                                                     |
# | i/ePOOL1: 5MB dynamic                                                     |
# | i/ePOOL2: 5MB dynamic                                                     |
# |                                                                           |
# |                      +-------------------------+                          |
# |                      |                         |                          |
# |                      |   BR11 (802.1D)         |                          |
# |                      |                         |                          |
# |          --------------+ $swp1.11   $swp2.11 +-------------               |
# |         |            |                         |           |              |
# |         |            +-------------------------+           |              |
# |         |            +-------------------------+           |              |
# |         |            |                         |           |              |
# |         |            |   BR12 (802.1D)         |           |              |
# |         |            |                         |           |              |
# |         |  ------------+ $swp1.12   $swp2.12 +-----------  |              |
# |         | |          |                         |         | |              |
# |         | |          +-------------------------+         | |              |
# |         | |                       .                      | |              |
# |         | |                       .                      | |              |
# |         | |                       .                      | |              |
# |         | |          +-------------------------+         | |              |
# |         | |          |                         |         | |              |
# |         | |          |   BR18 (802.1D)         |         | |              |
# |         | |          |                         |         | |              |
# |         | |      -------+ $swp1.18  $swp2.18 +-----      | |              |
# |         | |     |    |                         |   |     | |              |
# |         | | ... |    |              + $swp5.18 |   | ... | |              |
# |          \ \    /    +--------------|----------+    \   / /               |
# |           \ \  /                    |                \ / /                |
# |            \| /                     |                 \|/                 |
# |             + $swp1                 + $swp3            + $swp2            |
# |             | 10gbps                |                  | 10gbps           |
# |             | i/ePOOL0              |                  | i/ePOOL0         |
# +-------------|-----------------------|------------------|------------------+
#               |                       |                  |
# +-------------|--------------------+  |  +---------------|------------------+
# | H1          |                    |  |  | H2            |                  |
# |             + $h1                |  |  |               + $h2              |
# |            / \ i/ePOOL2          |  |  |              / \ i/ePOOL2        |
# |           /   \                  |  |  |             /   \                |
# |          /     \                 |  |  |            /     \               |
# |  $h1.11 + . . . + $h1.18         |  |  |    $h2.11 + . . . + $h2.18       |
# |192.0.2.1/28       192.0.2.113/28 |  |  |192.0.2.2/28        192.0.2.114/28|
# |                                  |  |  |                                  |
# +----------------------------------+  |  +----------------------------------+
#                                       |
#                       +---------------|------------------+
#                       | H3            |                  |
#                       |               + $h3              |
#                       |               | i/ePOOL2         |
#                       |               |                  |
#                       |               + $h3.18           |
#                       |                 192.0.2.115/28   |
#                       |                                  |
#                       +----------------------------------+
#
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Scriptlets:
#
#   /mnt/share156/petrm/stuff/th.sh swp7 Bb: a_octets_{transmitted,received}_ok swp8 Bb: a_octets_{transmitted,received}_ok swp1 Bb: a_octets_{transmitted,received}_ok swp2 Bb: a_octets_{transmitted,received}_ok swp3 Bb: a_octets_{transmitted,received}_ok swp4 Bb: a_octets_{transmitted,received}_ok
#
#   watch -n 1 'devlink sb occupancy snapshot pci/0000:01:00.0 ; for i in swp{1..4}; do devlink sb occupancy show $i; done'


ALL_TESTS="
	ping_ipv4
	traffic
"

lib_dir=$(dirname $0)/../../../net/forwarding

NUM_NETIFS=8
source $lib_dir/lib.sh
source $lib_dir/devlink_lib.sh

_1KB=1000
_500KB=$((500 * _1KB))
_1MB=$((1000 * _1KB))
_5MB=$((5 * _1MB))
_10MB=$((10 * _1MB))
_20MB=$((20 * _1MB))
POOL_SIZE=$_10MB

_Mbps=1
_Gbps=1000
SPEED=$((10 * _Gbps))

ipool0=0
epool0=4
ipool1=1
epool1=5
ipool2=2
epool2=6

ipaddr()
{
	local host=$1; shift
	local vlan=$1; shift

	echo 192.0.2.$((16 * (vlan - 11) + host))
}

pools_setup()
{
	devlink_pool_size_thtype_save $ipool0
	devlink_pool_size_thtype_set $ipool0 dynamic $POOL_SIZE
	defer_prio devlink_pool_size_thtype_restore $ipool0

	devlink_pool_size_thtype_save $epool0
	devlink_pool_size_thtype_set $epool0 dynamic $POOL_SIZE
	defer_prio devlink_pool_size_thtype_restore $epool0

	devlink_pool_size_thtype_save $ipool1
	devlink_pool_size_thtype_set $ipool1 dynamic $POOL_SIZE
	defer_prio devlink_pool_size_thtype_restore $ipool1

	devlink_pool_size_thtype_save $epool1
	devlink_pool_size_thtype_set $epool1 dynamic $POOL_SIZE
	defer_prio devlink_pool_size_thtype_restore $epool1

	devlink_pool_size_thtype_save $ipool2
	devlink_pool_size_thtype_set $ipool2 dynamic $POOL_SIZE
	defer_prio devlink_pool_size_thtype_restore $ipool2

	devlink_pool_size_thtype_save $epool2
	devlink_pool_size_thtype_set $epool2 dynamic $POOL_SIZE
	defer_prio devlink_pool_size_thtype_restore $epool2
}

bind_shbuffer()
{
	local dev=$1; shift
	local ipool=$1; shift
	local epool=$1; shift

	local tc

	devlink_port_pool_th_save $dev $ipool
	devlink_port_pool_th_set $dev $ipool 12
	defer devlink_port_pool_th_restore $dev $ipool

	devlink_port_pool_th_save $dev $epool
	devlink_port_pool_th_set $dev $epool 14
	defer devlink_port_pool_th_restore $dev $epool

	for tc in {0..7}; do
		devlink_tc_bind_pool_th_save $dev $tc ingress
		devlink_tc_bind_pool_th_set $dev $tc ingress $ipool 8
		defer devlink_tc_bind_pool_th_restore $dev $tc ingress

		devlink_tc_bind_pool_th_save $dev $tc egress
		devlink_tc_bind_pool_th_set $dev $tc egress $epool 10
		defer devlink_tc_bind_pool_th_restore $dev $tc egress
	done

	dcb buffer set dev $dev prio-buffer 0:0 1:1 2:2 3:3 4:4 5:5 6:6 7:7
	defer dcb buffer set dev $dev prio-buffer all:0
}

set_pfifo()
{
	local dev=$1; shift

	tc qdisc add dev $dev root handle 1: pfifo
	defer tc qdisc del dev $dev root handle 1:
}

set_ets()
{
	local dev=$1; shift

	tc qdisc add dev $dev root handle 1: ets strict 8 priomap 7 6 5 4 3 2 1 0
	defer tc qdisc del dev $dev root
}

set_ets_tbf()
{
	local dev=$1; shift
	local band

	set_ets $dev

	for band in {1..8}; do
		tc qdisc replace dev $dev parent 1:$band handle 1$band: \
			tbf rate 15000Mbit burst 128K limit 1M
	done
}

set_ets_pfifo()
{
	local dev=$1; shift
	local band

	set_ets $dev

	for band in {1..8}; do
		tc qdisc replace dev $dev parent 1:$band handle 1$band: pfifo
	done
}

host_create()
{
	local dev=$1; shift
	local host=$1; shift
	local rhost=$1; shift
	local rmac=$1; shift

	local vlan

	mtu_set $dev 10000
	defer mtu_restore $dev

	simple_if_init $dev
	defer simple_if_fini $dev

	for vlan in "$@"; do
		ip_link_add $dev.$vlan link $dev up type vlan id $vlan \
			egress-qos-map 0:$((vlan - 11))
		ip_link_set_master $dev.$vlan v$dev
		ip_addr_add $dev.$vlan $(ipaddr $host $vlan)/28

		ip neigh replace $(ipaddr $rhost $vlan) dev $dev.$vlan \
			lladdr $rmac nud permanent
		defer ip neigh del $(ipaddr $rhost $vlan) dev $dev.$vlan
	done

	set_pfifo $dev
	bind_shbuffer $dev $ipool2 $epool2
}

h1_create()
{
	host_create $h1 1 2 $h2mac {11..18}
}

h2_create()
{
	host_create $h2 2 1 $h1mac {11..18}

	ethtool -s $h2 speed $SPEED autoneg off
	defer ethtool -s $h2 autoneg on
}

h3_create()
{
	host_create $h3 3 2 $h2mac 18
}

switch_create()
{
	local vlan

	# swp1

	mtu_set $swp1 10000
	defer mtu_restore $swp1

	# ethtool -s $swp1 speed $SPEED autoneg off
	# defer ethtool -s $swp1 autoneg on

	ip_link_set_up $swp1

	for vlan in {11..18}; do
		ip_link_add $swp1.$vlan link $swp1 up type vlan id $vlan
	done


	set_pfifo $swp1
	bind_shbuffer $swp1 $ipool0 $epool0

	if ! :; then
	tc qdisc add dev $swp1 clsact
	defer tc qdisc del dev $swp1 clsact

	for vlan in {11..18}; do
		tc filter add dev $swp1 ingress pref 88$vlan \
			proto ipv4 flower skip_sw ip_proto udp dst_port 88$vlan \
			action pass hw_stats immediate
		defer tc filter del dev $swp1 ingress pref 88$vlan
	done
	fi

	# swp2

	mtu_set $swp2 10000
	defer mtu_restore $swp2

	ethtool -s $swp2 speed $SPEED autoneg off
	defer ethtool -s $swp2 autoneg on

	ip_link_set_up $swp2

	for vlan in {11..18}; do
		ip_link_add $swp2.$vlan link $swp2 up type vlan id $vlan
	done

	set_ets_pfifo $swp2
	bind_shbuffer $swp2 $ipool0 $epool0

	# swp3

	mtu_set $swp3 10000
	defer mtu_restore $swp3

	ethtool -s $swp3 speed $SPEED autoneg off
	defer ethtool -s $swp3 autoneg on

	ip_link_set_up $swp3
	ip_link_add $swp3.18 link $swp3 up type vlan id 18

	set_pfifo $swp3
	bind_shbuffer $swp3 $ipool0 $epool0

	# swp4

	mtu_set $swp4 10000
	defer mtu_restore $swp4

	ip link set dev $swp4 up
	defer ip link set dev $swp4 down

	for vlan in {11..18}; do
		ip_link_add $swp4.$vlan link $swp4 up type vlan id $vlan \
			egress-qos-map 0:$((vlan - 11))
	done

	set_ets_tbf $swp4
	bind_shbuffer $swp4 $ipool1 $epool1

	# swp5

	mtu_set $swp5 10000
	defer mtu_restore $swp5

	ip link set dev $swp5 up
	defer ip link set dev $swp5 down

	for vlan in {11..18}; do
		ip_link_add $swp5.$vlan link $swp5 up type vlan id $vlan \
			egress-qos-map 0:$((vlan - 11))
	done

	set_ets_tbf $swp5
	bind_shbuffer $swp5 $ipool1 $epool1

	# bridges

	for vlan in {11..18}; do
		ip_link_add br$vlan type bridge vlan_filtering 0
		ip link set dev br$vlan addrgenmode none
		ip_link_set_up br$vlan

		ip_link_set_master $swp1.$vlan br$vlan
		ip_link_set_master $swp2.$vlan br$vlan

		bridge fdb replace $h1mac dev $swp1.$vlan master static sticky
		defer bridge fdb del $h1mac dev $swp1.$vlan master

		bridge fdb replace $h2mac dev $swp2.$vlan master static sticky
		defer bridge fdb del $h2mac dev $swp2.$vlan master
	done
}

setup_prepare()
{
	netifs_map   h1 swp1 \
		   swp2 h2   \
		   swp3 h3   \
		   swp4 swp5 \

	h1mac=$(mac_get $h1)
	h2mac=$(mac_get $h2)

	vrf_prepare
	defer vrf_cleanup

	pools_setup

	h1_create
	h2_create
	h3_create
	switch_create
}

traffic()
{
	local vlan

	defer_scope_push

	echo Starting traffic.
	defer echo Stopped traffic.

	tc qdisc add dev $swp5 clsact
	defer tc qdisc del dev $swp5 clsact

	tc qdisc add dev $swp4 clsact
	defer tc qdisc del dev $swp4 clsact

	for vlan in {11..18}; do
		if ! :; then
			tc filter add dev $swp5 ingress pref 88$vlan \
				proto ipv4 flower ip_proto udp dst_port 88$vlan \
				action mirred egress redirect dev $swp4
			defer tc filter del dev $swp5 ingress pref 88$vlan
		fi

		tc filter add dev $swp5 egress pref 77$vlan \
			proto ipv4 flower ip_proto udp dst_port 77$vlan \
			action mirred egress mirror dev $h1
		defer tc filter del dev $swp5 egress pref 77$vlan

		tc filter add dev $swp4 ingress pref 77$vlan \
			proto ipv4 flower ip_proto udp dst_port 77$vlan \
			action mirred egress redirect dev $swp5
		defer tc filter del dev $swp4 ingress pref 77$vlan

		if ! :; then
			tc filter add dev $swp4 egress pref 88$vlan \
				proto ipv4 flower ip_proto udp dst_port 88$vlan \
				action mirred egress mirror dev $h2
			defer tc filter del dev $swp4 egress pref 88$vlan
		fi
	done

	sleep 1

	local pkt
	for pkt in {1..20}; do
	for vlan in {11..18}; do
		$MZ $swp5.$vlan -q -c 1 -p 800 \
		    -A $(ipaddr 1 $vlan) -B $(ipaddr 2 $vlan) \
		    -a $h1mac -b $h2mac -t udp dp=77$vlan
		$MZ $swp4.$vlan -q -c 1 -p 800 \
		    -A $(ipaddr 2 $vlan) -B $(ipaddr 1 $vlan) \
		    -a $h2mac -b $h1mac -t udp dp=88$vlan
	done
	sleep 0.2
	done

	read -p Ready.

	defer_scope_pop
}

ping_ipv4()
{
	local vlan

	for vlan in {11..18}; do
		ping_test $h1 $(ipaddr 2 $vlan) ": VLAN $vlan"
	done
}

pause()
{
	read -p Ready.
}

bail_on_lldpad "configure DCB" "configure Qdiscs"

trap cleanup EXIT

setup_prepare
setup_wait

tests_run

exit $EXIT_STATUS
