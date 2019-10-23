# SPDX-License-Identifier: GPL-2.0

# This is a template for ETS Qdisc test.
#
# This test sends from H1 several traffic streams with 802.1p-tagged packets.
# The tags are used at $swp1 to prioritize the traffic. Each stream is then
# queued at a different ETS band according to the assigned priority. After
# runnig for a while, counters at H2 are consulted to determine whether the
# traffic scheduling was according to the ETS configuration.
#
# This template is supposed to be embedded by a test driver, which implements
# statistics collection, any HW-specific stuff, and prominently configures the
# system to assure that there is overcommitment at $swp2. That is necessary so
# that the ETS traffic selection algorithm kicks in and has to schedule some
# traffic at the expense of other.
#
# A driver for veth-based testing is in sch_ets.sh, an example of a driver for
# an offloaded data path is in selftests/drivers/net/mlxsw/sch_ets.sh.
#
# +---------------------------------------------------------------------+
# | H1                                                                  |
# |     + $h1.10              + $h1.11              + $h1.12            |
# |     | 192.0.2.1/28        | 192.0.2.17/28       | 192.0.2.33/28     |
# |     |                     |                     |                   |
# |     \____________________ | ____________________/                   |
# |                          \|/                                        |
# |                           + $h1                                     |
# +---------------------------|-----------------------------------------+
#                             |
# +---------------------------|-----------------------------------------+
# | SW                        + $swp1                                   |
# |                           | >1Gbps                                  |
# |      ____________________/|\____________________                    |
# |     /                     |                     \                   |
# |  +--|----------------+ +--|----------------+ +--|----------------+  |
# |  |  + $swp1.10       | |  + $swp1.11       | |  + $swp1.12       |  |
# |  |    ingress-qos-map| |    ingress-qos-map| |    ingress-qos-map|  |
# |  |     0:0 1:1 2:2   | |     0:0 1:1 2:2   | |     0:0 1:1 2:2   |  |
# |  |                   | |                   | |                   |  |
# |  |    BR10           | |    BR11           | |    BR12           |  |
# |  |                   | |                   | |                   |  |
# |  |  + $swp2.10       | |  + $swp2.11       | |  + $swp2.12       |  |
# |  +--|----------------+ +--|----------------+ +--|----------------+  |
# |     \____________________ | ____________________/                   |
# |                          \|/                                        |
# |                           + $swp2                                   |
# |                           | 1Gbps (ethtool or HTB qdisc)            |
# |                           | qdisc ets quanta $W0 $W1 $W2            |
# |                           |           priomap 0 1 2                 |
# +---------------------------|-----------------------------------------+
#                             |
# +---------------------------|-----------------------------------------+
# | H2                        + $h2                                     |
# |      ____________________/|\____________________                    |
# |     /                     |                     \                   |
# |     + $h2.10              + $h2.11              + $h2.12            |
# |       192.0.2.2/28          192.0.2.18/28         192.0.2.34/28     |
# +---------------------------------------------------------------------+

ALL_TESTS="
	ets_set_dwrr_uniform
	ping_ipv4
	ets_dwrr_test3
	ets_set_dwrr_varying
	ets_dwrr_test3
	ets_change_class
	ets_dwrr_test3
	ets_set_dwrr_two_bands
	ets_dwrr_test2
	ets_set_dwrr_uniform	$(: Switch back to three bands)
	ets_dwrr_test3		$(: And redo the test)
"
NUM_NETIFS=4
CHECK_TC="yes"
source $lib_dir/lib.sh
source $lib_dir/sch_ets_tests.sh

PARENT=root

sip()
{
	echo 192.0.2.$((16 * $1 + 1))
}

dip()
{
	echo 192.0.2.$((16 * $1 + 2))
}

ets_start_traffic()
{
	local dst_mac=$(mac_get $h2)
	local i=$1; shift

	start_traffic $h1.1$i $(sip $i) $(dip $i) $dst_mac
}

h1_create()
{
	local i;

	simple_if_init $h1
	mtu_set $h1 9000
	for i in {0..2}; do
		vlan_create $h1 1$i v$h1 $(sip $i)/28
		ip link set dev $h1.1$i type vlan egress 0:$i
	done
}

h1_destroy()
{
	local i

	for i in {0..2}; do
		vlan_destroy $h1 1$i
	done
	mtu_restore $h1
	simple_if_fini $h1
}

h2_create()
{
	local i

	simple_if_init $h2
	mtu_set $h2 9000
	for i in {0..2}; do
		vlan_create $h2 1$i v$h2 $(dip $i)/28
	done
}

h2_destroy()
{
	local i

	for i in {0..2}; do
		vlan_destroy $h2 1$i
	done
	mtu_restore $h2
	simple_if_fini $h2
}

ets_switch_create()
{
	local i

	ip link set dev $swp1 up
	mtu_set $swp1 9000

	ip link set dev $swp2 up
	mtu_set $swp2 9000

	for i in {0..2}; do
		vlan_create $swp1 1$i
		ip link set dev $swp1.1$i type vlan ingress 0:0 1:1 2:2

		vlan_create $swp2 1$i

		ip link add dev br1$i type bridge
		ip link set dev $swp1.1$i master br1$i
		ip link set dev $swp2.1$i master br1$i

		ip link set dev br1$i up
		ip link set dev $swp1.1$i up
		ip link set dev $swp2.1$i up
	done
}

ets_switch_destroy()
{
	local i

	tc qdisc del dev $swp2 root

	for i in {0..2}; do
		ip link del dev br1$i
		vlan_destroy $swp2 1$i
		vlan_destroy $swp1 1$i
	done

	mtu_restore $swp2
	ip link set dev $swp2 down

	mtu_restore $swp1
	ip link set dev $swp1 down
}

setup_prepare()
{
	h1=${NETIFS[p1]}
	swp1=${NETIFS[p2]}

	swp2=${NETIFS[p3]}
	h2=${NETIFS[p4]}

	put=$swp2
	hut=$h2

	vrf_prepare

	h1_create
	h2_create
	switch_create
}

cleanup()
{
	pre_cleanup

	switch_destroy
	h2_destroy
	h1_destroy

	vrf_cleanup
}

ping_ipv4()
{
	ping_test $h1.10 $(dip 0) " vlan 10"
	ping_test $h1.11 $(dip 1) " vlan 11"
	ping_test $h1.12 $(dip 2) " vlan 12"
}

__xxx()
{
	local n=$1; shift

	local is=$(seq 0 $((n - 1)))
	local i

	for i in $is; do
		ets_start_traffic $i
	done

	read -p Ready.

	for i in $is; do
		stop_traffic
	done
}

xxx()
{
	__xxx 0
}

xxx3()
{
	__xxx 3
}

ets_run()
{
	trap cleanup EXIT

	setup_prepare
	setup_wait

	tests_run

	exit $EXIT_STATUS
}
